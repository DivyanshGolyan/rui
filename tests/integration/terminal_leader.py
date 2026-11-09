"""A session leader for each test PTY, and the handle for what it runs.

A real terminal runs a command under a shell that leads the terminal's session:
the command opens /dev/tty, runs in the foreground process group, and leaves the
terminal usable when it exits. A fixture gets the same by starting one leader per
PTY. The leader owns the PTY as its controlling terminal and runs each command the
fixture spawns on it as its foreground child, as a shell runs a job. On Darwin a
session leader's exit revokes its terminal, so the command must never be one.

`spawn` takes Popen's arguments and returns a `TerminalProcess` with the Popen
surface fixtures use. The command inherits what a Popen child would: the
fixture's environment, cwd, umask, resource limits, signal mask and ignored
signals, and exactly its stdio and `pass_fds` descriptors at their numbers.

Run as a program, this module is the leader.

Prototype on `proto/pty-leader`: it settles the plan's open questions and is not
wired into the fixtures.
"""

import errno
import fcntl
import json
import os
import resource
import select
import signal
import socket
import struct
import sys
import termios

HEADER = struct.Struct("!I")
# Signals a Popen child gets at their default action even when the fixture
# ignores them, as `restore_signals=True` does.
RESTORED = {getattr(signal, name) for name in ("SIGPIPE", "SIGXFSZ", "SIGXFZ") if hasattr(signal, name)}
# By number: names alias (Linux has RLIMIT_OFILE for RLIMIT_NOFILE).
LIMITS = sorted({getattr(resource, name) for name in dir(resource) if name.startswith("RLIMIT_")})


def frame(message):
    data = json.dumps(message).encode()
    return HEADER.pack(len(data)) + data


# ── Leader ───────────────────────────────────────────────────────────────────


def lead(control, keep_slave, forward_hangup):
    """Own the terminal on fd 0 and run the fixture's commands on it until the
    terminal hangs up or the fixture goes away, and every command has ended."""
    channel = socket.socket(fileno=control)
    try:
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    except OSError as error:
        channel.sendall(frame({"ready": False, "errno": error.errno}))
        return 1
    if not keep_slave:
        null = os.open(os.devnull, os.O_RDWR)
        os.dup2(null, 0)
        os.close(null)
    wake_read, wake_write = os.pipe()
    os.set_blocking(wake_write, False)
    flags = set()
    signal.signal(signal.SIGCHLD, lambda *_: flags.add("child"))
    signal.signal(signal.SIGHUP, lambda *_: flags.add("hangup"))
    signal.set_wakeup_fd(wake_write)
    channel.sendall(frame({"ready": True}))

    children = set()
    buffer, fds = b"", []
    hangup = closed = False
    kill_after = None

    def send(message):
        if not closed:
            try:
                channel.sendall(frame(message))
            except OSError:
                pass

    def signal_all(*signals):
        for pid in children:
            for number in signals:
                try:
                    os.killpg(pid, number)
                except OSError:
                    try:
                        os.kill(pid, number)
                    except OSError:
                        pass

    while True:
        if "child" in flags:
            flags.discard("child")
            while children:
                try:
                    pid, status = os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    break
                if pid == 0:
                    break
                children.discard(pid)
                send({"exit": pid, "status": status})
        if "hangup" in flags and not hangup:
            hangup = True
            if forward_hangup:
                signal_all(signal.SIGHUP, signal.SIGCONT)
        if (hangup or closed) and not children:
            return 0
        if kill_after is not None and os.times().elapsed >= kill_after:
            signal_all(signal.SIGKILL)
            kill_after = None
        readable, _, _ = select.select([wake_read] + ([] if closed else [channel]), [], [], 0.5)
        if wake_read in readable:
            os.read(wake_read, 512)
        if channel in readable:
            data, more, _, _ = socket.recv_fds(channel, 65536, 64)
            if not data:
                # The fixture is gone: end its commands as a closed terminal would.
                closed = True
                signal_all(signal.SIGHUP, signal.SIGCONT)
                kill_after = os.times().elapsed + 5
                continue
            buffer += data
            fds += more
            while len(buffer) >= HEADER.size:
                (size,) = HEADER.unpack_from(buffer)
                if len(buffer) < HEADER.size + size:
                    break
                request = json.loads(buffer[HEADER.size:HEADER.size + size])
                buffer = buffer[HEADER.size + size:]
                if "spawn" in request:
                    count = len(request["spawn"]["targets"])
                    sources, fds = fds[:count], fds[count:]
                    reply = start(request["spawn"], sources)
                    if "pid" in reply:
                        children.add(reply["pid"])
                    send(reply)
                elif "signal" in request:
                    pid = request["signal"]
                    if pid in children:
                        os.kill(pid, request["number"])
                    send({"signalled": pid in children})


def start(request, sources):
    """Fork and exec one command as the terminal's foreground job. Returns its pid,
    or the errno and file name that stopped it before exec."""
    error_read, error_write = os.pipe()
    everything = signal.pthread_sigmask(signal.SIG_SETMASK, signal.valid_signals())
    pid = os.fork()
    if pid == 0:
        try:
            # Above every target, so placing the targets can't overwrite it.
            floor = max(request["targets"] + sources + [error_write]) + 1
            error_write = fcntl.fcntl(error_write, fcntl.F_DUPFD_CLOEXEC, floor)
            become(request, sources, error_write)
        except OSError as error:
            message = {"errno": error.errno, "filename": error.filename}
        except BaseException as error:
            message = {"errno": errno.EINVAL, "filename": repr(error)}
        os.write(error_write, json.dumps(message).encode())
        os._exit(255)
    signal.pthread_sigmask(signal.SIG_SETMASK, everything)
    try:
        # Also from this side, so the group exists whichever runs first.
        os.setpgid(pid, pid)
    except OSError:
        pass
    os.close(error_write)
    for fd in sources:
        os.close(fd)
    failure = b""
    while chunk := os.read(error_read, 4096):
        failure += chunk
    os.close(error_read)
    if failure:
        os.waitpid(pid, 0)
        return json.loads(failure)
    return {"pid": pid}


def become(request, sources, error_write):
    """In the forked child, with every signal blocked: take the fixture's
    snapshot, the terminal's foreground and the descriptors, then exec."""
    signal.set_wakeup_fd(-1)
    ignored = set(request["ignored"]) - RESTORED - set(request["default_signals"])
    for number in signal.valid_signals():
        try:
            signal.signal(number, signal.SIG_IGN if number in ignored else signal.SIG_DFL)
        except (OSError, ValueError):
            pass
    os.setpgid(0, 0)
    # A shell's job takes the foreground before it runs; SIGTTOU is blocked.
    terminal = os.open("/dev/tty", os.O_RDWR)
    os.tcsetpgrp(terminal, os.getpid())
    os.close(terminal)
    os.umask(request["umask"])
    if request["cwd"] is not None:
        try:
            os.chdir(request["cwd"])
        except OSError as error:
            error.filename = request["cwd"]
            raise
    targets = request["targets"]
    # Through a range above every target, so no target overwrites a source.
    floor = error_write + 1
    staged = [fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, floor) for fd in sources]
    for fd, target in zip(staged, targets):
        os.dup2(fd, target)
    keep = set(targets) | {error_write}
    for name in os.listdir("/dev/fd"):
        if int(name) not in keep:
            try:
                os.close(int(name))
            except OSError:
                pass
    for number, (soft, hard) in request["limits"]:
        try:
            resource.setrlimit(number, (soft, hard))
        except (ValueError, OSError):
            pass
    args, env = request["args"], request["env"]
    program = args[0]
    paths = [program] if os.sep in program else [os.path.join(d, program) for d in os.get_exec_path(env)]
    signal.pthread_sigmask(signal.SIG_SETMASK, request["mask"])
    failure = None
    for path in paths:
        try:
            os.execve(path, args, env)
        except OSError as error:
            if failure is None or error.errno not in (errno.ENOENT, errno.ENOTDIR):
                failure = error
    failure.filename = program
    raise failure


# ── Fixture side ─────────────────────────────────────────────────────────────

if __name__ != "__main__":
    import collections
    import selectors
    import subprocess
    import threading
    import time

    # Live leaders by the PTY device they own.
    LEADERS = {}


class Leader:
    """One PTY's session leader, as the fixture reaches it."""

    def __init__(self, terminal, *, keep_slave=True, forward_hangup=True):
        ours, theirs = socket.socketpair()
        flags = [] if keep_slave else ["--close-slave"]
        flags += [] if forward_hangup else ["--no-forward"]
        self.process = subprocess.Popen(
            [sys.executable, "-I", "-S", os.path.abspath(__file__), str(theirs.fileno()), *flags],
            stdin=terminal, stdout=subprocess.DEVNULL, start_new_session=True, pass_fds=(theirs.fileno(),))
        theirs.close()
        self.channel = ours
        self.buffer = b""
        self.statuses = {}
        self.replies = collections.deque()
        self.ended = False
        self.reading = False
        self.condition = threading.Condition()
        self.requests = threading.Lock()
        ready = self.reply(None)
        if not ready["ready"]:
            raise OSError(ready["errno"], "leader could not own the terminal")

    def pump(self, deadline):
        """Read one message, or wait while another thread reads one, until the
        deadline (None: no limit)."""
        with self.condition:
            if self.reading:
                self.condition.wait(None if deadline is None else max(0, deadline - time.monotonic()))
                return
            self.reading = True
        try:
            while True:
                if len(self.buffer) >= HEADER.size:
                    (size,) = HEADER.unpack_from(self.buffer)
                    if len(self.buffer) >= HEADER.size + size:
                        message = json.loads(self.buffer[HEADER.size:HEADER.size + size])
                        self.buffer = self.buffer[HEADER.size + size:]
                        break
                if self.ended:
                    return
                wait = None if deadline is None else max(0, deadline - time.monotonic())
                if not select.select([self.channel], [], [], wait)[0]:
                    return
                data = self.channel.recv(65536)
                if not data:
                    self.ended = True
                    self.process.wait()
                    continue
                self.buffer += data
            if "exit" in message:
                self.statuses[message["exit"]] = message["status"]
            else:
                self.replies.append(message)
        finally:
            with self.condition:
                self.reading = False
                self.condition.notify_all()

    def reply(self, deadline):
        while not self.replies:
            if self.ended:
                raise RuntimeError("terminal leader exited")
            self.pump(deadline)
        return self.replies.popleft()

    def request(self, message, fds=()):
        with self.requests:
            data = frame(message)
            if fds:
                socket.send_fds(self.channel, [data], list(fds))
            else:
                self.channel.sendall(data)
            return self.reply(None)

    def status(self, pid, deadline):
        """C's raw wait status, or None if the deadline passes first."""
        while pid not in self.statuses:
            if self.ended:
                raise RuntimeError(f"terminal leader exited before reporting {pid}")
            self.pump(deadline)
            if pid not in self.statuses and deadline is not None and time.monotonic() >= deadline:
                return None
        return self.statuses[pid]


def leader_for(terminal, **options):
    device = os.fstat(terminal).st_rdev
    leader = LEADERS.get(device)
    if leader is None or leader.ended or leader.process.poll() is not None:
        leader = LEADERS[device] = Leader(terminal, **options)
    return leader


class TerminalProcess:
    """A command a terminal leader runs, with the Popen surface fixtures use."""

    def __init__(self, leader, pid, args, stdin, stdout, stderr):
        self.leader, self.pid, self.args = leader, pid, args
        self.stdin, self.stdout, self.stderr = stdin, stdout, stderr
        self.returncode = None
        self.collected = {}

    def poll(self):
        return self.wait_until(time.monotonic())

    def wait(self, timeout=None):
        code = self.wait_until(None if timeout is None else time.monotonic() + timeout)
        if code is None:
            raise subprocess.TimeoutExpired(self.args, timeout)
        return code

    def wait_until(self, deadline):
        if self.returncode is None:
            status = self.leader.status(self.pid, deadline)
            if status is not None:
                self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def send_signal(self, number):
        if self.poll() is None:
            self.leader.request({"signal": self.pid, "number": int(number)})

    def terminate(self):
        self.send_signal(signal.SIGTERM)

    def kill(self):
        self.send_signal(signal.SIGKILL)

    def communicate(self, input=None, timeout=None):
        deadline = None if timeout is None else time.monotonic() + timeout
        streams = {s: self.collected.setdefault(s, []) for s in (self.stdout, self.stderr) if s is not None}
        with selectors.DefaultSelector() as selector:
            if self.stdin is not None:
                if input:
                    self.stdin.write(input)
                self.stdin.close()
            for stream in streams:
                if not stream.closed:
                    selector.register(stream, selectors.EVENT_READ)
            while selector.get_map():
                wait = None if deadline is None else deadline - time.monotonic()
                if wait is not None and wait <= 0:
                    raise subprocess.TimeoutExpired(self.args, timeout)
                for key, _ in selector.select(wait):
                    data = os.read(key.fd, 65536)
                    if data:
                        streams[key.fileobj].append(data)
                    else:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
        self.wait(None if deadline is None else max(0, deadline - time.monotonic()))
        out = [self.decode(stream, b"".join(streams[stream])) if stream in streams else None
               for stream in (self.stdout, self.stderr)]
        return tuple(out)

    @staticmethod
    def decode(stream, data):
        return data.decode(stream.encoding, stream.errors) if hasattr(stream, "encoding") else data

    def __enter__(self):
        return self

    def __exit__(self, *_):
        for stream in (self.stdin, self.stdout, self.stderr):
            if stream is not None:
                stream.close()
        self.wait()


def spawn(args, *, stdin=None, stdout=None, stderr=None, env=None, cwd=None, pass_fds=(),
          text=False, encoding=None, errors=None, default_signals=(), rlimits=None, leader_options=None):
    """Run `args` on the PTY among its streams, as the foreground job of that
    PTY's leader. Takes Popen's arguments, except `preexec_fn`: pass the signals
    to reset and the resource limits to set as data."""
    args = [os.fspath(a) for a in ([args] if isinstance(args, (str, bytes, os.PathLike)) else args)]
    terminal = next((s for s in (stdin, stdout, stderr) if isinstance(s, int) and s >= 0 and os.isatty(s)), None)
    if terminal is None:
        raise ValueError("spawn needs a PTY among stdin, stdout and stderr")
    leader = leader_for(terminal, **(leader_options or {}))
    text = text or encoding is not None or errors is not None
    sources, opened, parents = [], [], [None, None, None]
    for number, stream in enumerate((stdin, stdout, stderr)):
        if hasattr(stream, "fileno"):
            stream = stream.fileno()
        if stream is None:
            stream = number
        elif stream == subprocess.DEVNULL:
            stream = os.open(os.devnull, os.O_RDWR)
            opened.append(stream)
        elif stream == subprocess.PIPE:
            read, write = os.pipe()
            ours, stream = (write, read) if number == 0 else (read, write)
            opened.append(stream)
            parents[number] = os.fdopen(ours, ("w" if number == 0 else "r") + ("" if text else "b"),
                                        **({"encoding": encoding, "errors": errors} if text else {"buffering": 0}))
        elif stream == subprocess.STDOUT:
            stream = sources[1]
        sources.append(stream)
    sources += list(pass_fds)
    limits = {number: resource.getrlimit(number) for number in LIMITS}
    limits.update(rlimits or {})
    umask = os.umask(0)
    os.umask(umask)
    request = {
        "args": args, "env": dict(os.environ if env is None else env), "cwd": None if cwd is None else os.fspath(cwd),
        "targets": [0, 1, 2] + list(pass_fds), "umask": umask, "limits": sorted(limits.items()),
        "mask": sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK, [])),
        "ignored": [int(s) for s in signal.valid_signals() if signal.getsignal(s) == signal.SIG_IGN],
        "default_signals": [int(s) for s in default_signals],
    }
    try:
        reply = leader.request({"spawn": request}, sources)
    finally:
        for fd in opened:
            os.close(fd)
    if "pid" not in reply:
        for stream in parents:
            if stream is not None:
                stream.close()
        raise OSError(reply["errno"], os.strerror(reply["errno"]), reply["filename"])
    return TerminalProcess(leader, reply["pid"], args, *parents)


if __name__ == "__main__":
    sys.exit(lead(int(sys.argv[1]), "--close-slave" not in sys.argv, "--no-forward" not in sys.argv))
