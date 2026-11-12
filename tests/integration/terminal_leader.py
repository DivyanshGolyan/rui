"""The session leader of one test PTY.

A terminal runs a program under a shell that leads the terminal's session: the
program opens /dev/tty, runs in the foreground process group, and leaves the
terminal usable when it exits. This program is that shell for a fixture's PTY.
It owns the PTY on its stdin as its controlling terminal and runs each command
the fixture sends as a foreground job. It never runs a command as the session
leader, because on Darwin a session leader's exit revokes its terminal.

A library, not a fixture entry: only `terminal_process` starts it, through
`lead`, in a fixture that already refused root, with the PTY on fd 0 and the
leader's end of a control socket. Requests and replies are length-prefixed
JSON; a spawn request carries its descriptors by SCM_RIGHTS. The leader ends
when the PTY hangs up or the fixture goes away, once every job has ended, and
hangs up its jobs first, as a closing terminal does.
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
import termios

HEADER = struct.Struct("!I")
# Signals a Popen child gets at their default action even when the fixture
# ignores them, as `restore_signals=True` does.
RESTORED = {getattr(signal, name) for name in ("SIGPIPE", "SIGXFSZ", "SIGXFZ") if hasattr(signal, name)}
# By number: names alias (RLIMIT_OFILE is RLIMIT_NOFILE on Linux, RLIMIT_RSS is
# RLIMIT_AS on Darwin), and setting an alias would undo an override.
LIMITS = sorted({getattr(resource, name) for name in dir(resource) if name.startswith("RLIMIT_")})
# How long jobs get to end after the fixture went away before SIGKILL.
ORPHAN_GRACE = 5


def frame(message):
    data = json.dumps(message).encode()
    return HEADER.pack(len(data)) + data


def lead(control):
    channel = socket.socket(fileno=control)
    try:
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    except OSError as error:
        channel.sendall(frame({"ready": False, "errno": error.errno}))
        return 1
    wake_read, wake_write = os.pipe()
    os.set_blocking(wake_write, False)
    flags = set()
    signal.signal(signal.SIGCHLD, lambda *_: flags.add("child"))
    signal.signal(signal.SIGHUP, lambda *_: flags.add("hangup"))
    signal.set_wakeup_fd(wake_write)
    channel.sendall(frame({"ready": True}))

    jobs = set()
    buffer, received = b"", []
    hangup = orphaned = False
    kill_at = None

    def send(message):
        if not orphaned:
            try:
                channel.sendall(frame(message))
            except OSError:
                pass

    def signal_jobs(*numbers):
        for pid in jobs:
            for number in numbers:
                try:
                    os.killpg(pid, number)
                except OSError:
                    pass

    while True:
        if "child" in flags:
            flags.discard("child")
            while jobs:
                pid, status = os.waitpid(-1, os.WNOHANG)
                if pid == 0:
                    break
                jobs.discard(pid)
                send({"exit": pid, "status": status})
        if "hangup" in flags and not hangup:
            # The kernel signals only the controlling process when the master
            # closes; a terminal hangs up the jobs too.
            hangup = True
            signal_jobs(signal.SIGHUP, signal.SIGCONT)
        if (hangup or orphaned) and not jobs:
            return 0
        if kill_at is not None and os.times().elapsed >= kill_at:
            signal_jobs(signal.SIGKILL)
            kill_at = None
        readable = select.select([wake_read] + ([] if orphaned else [channel]), [], [], 0.5)[0]
        if wake_read in readable:
            os.read(wake_read, 512)
        if channel not in readable:
            continue
        data, fds, _, _ = socket.recv_fds(channel, 65536, 64)
        if not data:
            orphaned = True
            signal_jobs(signal.SIGHUP, signal.SIGCONT)
            kill_at = os.times().elapsed + ORPHAN_GRACE
            continue
        buffer += data
        received += fds
        while len(buffer) >= HEADER.size:
            (size,) = HEADER.unpack_from(buffer)
            if len(buffer) < HEADER.size + size:
                break
            request = json.loads(buffer[HEADER.size:HEADER.size + size])
            buffer = buffer[HEADER.size + size:]
            if "spawn" in request:
                count = len(request["spawn"]["targets"])
                sources, received = received[:count], received[count:]
                reply = start(request["spawn"], sources)
                if "pid" in reply:
                    jobs.add(reply["pid"])
                send(reply)
            else:
                # Only a job not yet reaped, so a reused pid is never signalled.
                pid = request["signal"]
                if pid in jobs:
                    os.kill(pid, request["number"])
                send({"signalled": pid in jobs})


def start(request, sources):
    """Fork and exec one job. Returns its pid, or the errno and file name that
    stopped it before exec."""
    error_read, error_write = os.pipe()
    previous = signal.pthread_sigmask(signal.SIG_SETMASK, signal.valid_signals())
    pid = os.fork()
    if pid == 0:
        try:
            floor = max(request["targets"] + sources + [error_write]) + 1
            error_write = fcntl.fcntl(error_write, fcntl.F_DUPFD_CLOEXEC, floor)
            become(request, sources, error_write)
        except OSError as error:
            failure = {"errno": error.errno, "filename": error.filename}
        except BaseException as error:
            failure = {"errno": errno.EINVAL, "filename": repr(error)}
        os.write(error_write, json.dumps(failure).encode())
        os._exit(255)
    signal.pthread_sigmask(signal.SIG_SETMASK, previous)
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


def step(name, call, *args):
    """One pre-exec call. Its error names the call when it names no file, so
    a failed spawn says which step refused (#1147)."""
    try:
        return call(*args)
    except OSError as error:
        error.filename = error.filename or name
        raise


def become(request, sources, error_write):
    """In the forked job, with every signal blocked: take the fixture's
    snapshot, the terminal's foreground and the descriptors, then exec."""
    signal.set_wakeup_fd(-1)
    ignored = set(request["ignored"]) - RESTORED - set(request["default_signals"])
    for number in signal.valid_signals():
        try:
            signal.signal(number, signal.SIG_IGN if number in ignored else signal.SIG_DFL)
        except (OSError, ValueError):
            pass  # SIGKILL, SIGSTOP and signals the C library reserves.
    step("setpgid", os.setpgid, 0, 0)
    # A shell's job takes the foreground before it runs; SIGTTOU is blocked.
    terminal = step("open /dev/tty", os.open, "/dev/tty", os.O_RDWR)
    step("tcsetpgrp", os.tcsetpgrp, terminal, os.getpid())
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
    staged = [fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, error_write + 1) for fd in sources]
    for fd, target in zip(staged, targets):
        os.dup2(fd, target)
    keep = set(targets) | {error_write}
    for name in os.listdir("/dev/fd"):
        if int(name) not in keep:
            try:
                os.close(int(name))
            except OSError:
                pass  # The directory listing's own descriptor.
    # After the descriptors move: a lower descriptor limit refuses the staging range.
    for number, limit in request["limits"]:
        resource.setrlimit(number, tuple(limit))
    args, env = request["args"], request["env"]
    program = args[0]
    paths = [program] if os.sep in program else [os.path.join(d, program) for d in os.get_exec_path(env)]
    signal.pthread_sigmask(signal.SIG_SETMASK, request["mask"])
    failure = None
    for path in paths:
        try:
            os.execve(path, args, env)
        except OSError as error:
            # As Popen: the first error other than a missing file wins.
            if failure is None or error.errno not in (errno.ENOENT, errno.ENOTDIR):
                failure = error
    failure.filename = program
    raise failure
