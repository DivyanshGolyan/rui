"""Processes on test PTYs, and the lifecycle for an ordinary conversation with
all streams on one PTY."""

from contextlib import contextmanager
import collections
import errno
import fcntl
import json
import os
import pty
import resource
import select
import selectors
import signal
import socket
import struct
import subprocess
import sys
import termios
import threading
import time

from host_process import WAIT_HOOKS, dispose_all, stop_process
from terminal_leader import HEADER, LIMITS, frame


# Conversations run full screen; tall enough that a short exchange stays in view.
COLUMNS, ROWS = 80, 50
# Screen observers by master descriptor.
CAPTURES = {}
PTY_MASTERS = set()
PTY_LOCK = threading.RLock()
# The master of each slave open_pty made, and the input master that answers
# go to for an output master whose process reads another PTY.
MASTERS = {}
ANSWERS = {}
# Live leaders by the PTY device they own. A device number can't name another
# PTY while its leader lives: the leader holds the slave open.
LEADERS = {}
STARTING = threading.Lock()


def register_capture(master, capture):
    with PTY_LOCK:
        CAPTURES[master] = capture


def drain_captures():
    with PTY_LOCK:
        for master in list(PTY_MASTERS):
            capture = CAPTURES.get(master)
            if capture is None:
                continue
            try:
                while select.select([master], [], [], 0)[0]:
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    capture.feed(chunk)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise


WAIT_HOOKS.append(drain_captures)


def open_pty(columns=COLUMNS, rows=ROWS):
    """A PTY with real geometry, as every interactive terminal reports."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
    with PTY_LOCK:
        PTY_MASTERS.add(master)
        MASTERS[slave] = master
    return master, slave


def close_pty(*fds):
    """Forget PTY ownership before releasing descriptors for reuse."""
    with PTY_LOCK:
        for fd in fds:
            CAPTURES.pop(fd, None)
            if fd in PTY_MASTERS:
                PTY_MASTERS.remove(fd)
                for slave, master in list(MASTERS.items()):
                    if master == fd:
                        del MASTERS[slave]
                for master, answer in list(ANSWERS.items()):
                    if master == fd or answer == fd:
                        del ANSWERS[master]
            MASTERS.pop(fd, None)
            os.close(fd)


def answers_to(master):
    """Where a screen observer of `master` sends the terminal's answers: the
    PTY the process reads, which `spawn` recorded."""
    def write(data):
        try:
            os.write(ANSWERS.get(master, master), data)
        except OSError as error:
            # Every slave closed: no process is left to read an answer.
            if error.errno != errno.EIO:
                raise
    return write


def spawn(args, *, stdin=None, stdout=None, stderr=None, env=None, cwd=None, pass_fds=(),
          default_signals=(), rlimits=None):
    """Run `args` as the foreground job of the session leader that owns the PTY
    among its streams, as a terminal's shell runs a program: /dev/tty is that
    PTY, and the PTY outlives the job with the job's termios.

    Takes Popen's arguments. The job inherits what a Popen child would: the
    environment, cwd, umask, resource limits, signal mask, ignored signals and
    exactly its stdio and `pass_fds` at their numbers. In place of a preexec
    function, `default_signals` resets signals the fixture ignores and `rlimits`
    maps limit numbers to (soft, hard)."""
    terminal = next((s for s in (stdin, stdout, stderr) if isinstance(s, int) and s >= 0 and os.isatty(s)), None)
    if terminal is None:
        raise ValueError("spawn runs a process on a PTY; none of its streams is one")
    if isinstance(stdout, int) and stdout in MASTERS:
        # The process reads its answers from stdin's PTY.
        if isinstance(stdin, int) and stdin in MASTERS and stdin != stdout:
            ANSWERS[MASTERS[stdout]] = MASTERS[stdin]
        else:
            ANSWERS.pop(MASTERS[stdout], None)
    leader = leader_for(terminal)
    sources, opened, ends = [], [], [None, None, None]
    for number, stream in enumerate((stdin, stdout, stderr)):
        if stream is None:
            stream = number
        elif stream == subprocess.DEVNULL:
            stream = os.open(os.devnull, os.O_RDWR)
            opened.append(stream)
        elif stream == subprocess.PIPE:
            read, write = os.pipe()
            ours, stream = (write, read) if number == 0 else (read, write)
            opened.append(stream)
            ends[number] = os.fdopen(ours, "wb" if number == 0 else "rb", buffering=0)
        sources.append(stream)
    limits = {number: resource.getrlimit(number) for number in LIMITS}
    limits.update(rlimits or {})
    umask = os.umask(0)
    os.umask(umask)
    request = {
        "args": [os.fspath(a) for a in args], "env": dict(os.environ if env is None else env),
        "cwd": None if cwd is None else os.fspath(cwd), "umask": umask, "limits": sorted(limits.items()),
        "targets": [0, 1, 2, *pass_fds], "mask": sorted(signal.pthread_sigmask(signal.SIG_BLOCK, [])),
        "ignored": [int(s) for s in signal.valid_signals() if signal.getsignal(s) == signal.SIG_IGN],
        "default_signals": [int(s) for s in default_signals],
    }
    try:
        try:
            reply = leader.request({"spawn": request}, sources + list(pass_fds))
        except LeaderGone:
            leader = leader_for(terminal, gone=leader)
            reply = leader.request({"spawn": request}, sources + list(pass_fds))
    finally:
        for fd in opened:
            os.close(fd)
    if "pid" not in reply:
        for end in ends:
            if end is not None:
                end.close()
        raise OSError(reply["errno"], os.strerror(reply["errno"]), reply["filename"])
    return TerminalProcess(leader, reply["pid"], request["args"], *ends)


def leader_for(terminal, gone=None):
    """The leader of the PTY `terminal` names, started on first use. `gone`
    is a leader found to have ended before it read a request."""
    with STARTING:
        for device, leader in list(LEADERS.items()):
            if leader is gone or leader.process.poll() is not None:
                leader.close()
                del LEADERS[device]
        device = os.fstat(terminal).st_rdev
        if device not in LEADERS:
            LEADERS[device] = Leader(terminal)
        return LEADERS[device]


class LeaderGone(Exception):
    """A leader ended through hangup before it read a request.

    A dying process closes its descriptors before it can be reaped, so for a
    moment its PTY's device number can name a new PTY while `poll()` still
    finds the old leader running. The request never started anything."""


class Leader:
    """One PTY's session leader (terminal_leader.py), as the fixture reaches it."""

    def __init__(self, terminal):
        ours, theirs = socket.socketpair()
        self.process = subprocess.Popen([sys.executable, "-I", "-S", "-c",
            "import sys; sys.path.insert(0, sys.argv[1]); import terminal_leader; "
            "sys.exit(terminal_leader.lead(int(sys.argv[2])))",
            os.path.dirname(os.path.abspath(__file__)), str(theirs.fileno())],
            stdin=terminal, stdout=subprocess.DEVNULL, start_new_session=True, pass_fds=(theirs.fileno(),))
        theirs.close()
        self.channel = ours
        self.buffer = b""
        self.statuses = {}
        self.replies = collections.deque()
        self.ended = self.reading = False
        self.turn = threading.Condition()
        self.requests = threading.Lock()
        try:
            ready = self.reply()
            if not ready["ready"]:
                raise OSError(ready["errno"], "test PTY leader could not own its terminal")
        except BaseException:
            self.channel.close()
            self.process.wait()
            raise

    def pump(self, deadline):
        """Take one message, or let another thread take one, by the deadline
        (None: no limit)."""
        with self.turn:
            if self.reading:
                self.turn.wait(None if deadline is None else max(0, deadline - time.monotonic()))
                return
            self.reading = True
        try:
            while len(self.buffer) < HEADER.size or len(self.buffer) < HEADER.size + HEADER.unpack_from(self.buffer)[0]:
                if self.ended:
                    return
                wait = None if deadline is None else max(0, deadline - time.monotonic())
                if not select.select([self.channel], [], [], wait)[0]:
                    return
                data = self.channel.recv(65536)
                self.buffer += data
                self.ended = not data
            (size,) = HEADER.unpack_from(self.buffer)
            message = json.loads(self.buffer[HEADER.size:HEADER.size + size])
            self.buffer = self.buffer[HEADER.size + size:]
            if "exit" in message:
                self.statuses[message["exit"]] = message["status"]
            else:
                self.replies.append(message)
        finally:
            with self.turn:
                self.reading = False
                self.turn.notify_all()

    def reply(self):
        while not self.replies:
            if self.ended:
                raise RuntimeError(f"test PTY leader {self.process.pid} exited")
            self.pump(None)
        return self.replies.popleft()

    def request(self, message, fds=()):
        with self.requests:
            try:
                if fds:
                    socket.send_fds(self.channel, [frame(message)], fds)
                else:
                    self.channel.sendall(frame(message))
                return self.reply()
            except (BrokenPipeError, ConnectionResetError, RuntimeError):
                # Exit 0 is only the hangup path, which the leader takes
                # between requests, never after reading one.
                if self.process.wait() != 0:
                    raise
                raise LeaderGone(self.process.pid) from None

    def status(self, pid, deadline):
        """The job's raw wait status, or None once the deadline passes."""
        while pid not in self.statuses:
            if self.ended:
                raise RuntimeError(f"test PTY leader {self.process.pid} exited ({self.process.wait()}) before reporting {pid}")
            self.pump(deadline)
            if pid not in self.statuses and deadline is not None and time.monotonic() >= deadline:
                return None
        return self.statuses[pid]

    def close(self):
        """After the leader exited: keep its last statuses, release the socket."""
        while not self.ended:
            self.pump(None)
        self.channel.close()


class TerminalProcess:
    """A job a PTY's leader runs, with the part of Popen fixtures use."""

    def __init__(self, leader, pid, args, stdin, stdout, stderr):
        self.leader, self.pid, self.args = leader, pid, args
        self.stdin, self.stdout, self.stderr = stdin, stdout, stderr
        self.returncode = None
        self.collected = {}

    def poll(self):
        return self.settle(time.monotonic())

    def wait(self, timeout=None):
        if self.settle(None if timeout is None else time.monotonic() + timeout) is None:
            raise subprocess.TimeoutExpired(self.args, timeout)
        return self.returncode

    def settle(self, deadline):
        if self.returncode is None:
            status = self.leader.status(self.pid, deadline)
            if status is not None:
                self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def send_signal(self, number):
        if self.poll() is None:
            self.leader.request({"signal": self.pid, "number": int(number)})

    def kill(self):
        self.send_signal(signal.SIGKILL)

    def communicate(self, timeout=None):
        """Read the PIPE ends to EOF, then wait; output read before a timeout
        is kept for the next call, as Popen keeps it."""
        deadline = None if timeout is None else time.monotonic() + timeout
        ends = [end for end in (self.stdout, self.stderr) if end is not None]
        with selectors.DefaultSelector() as selector:
            for end in ends:
                self.collected.setdefault(end, [])
                if not end.closed:
                    selector.register(end, selectors.EVENT_READ)
            while selector.get_map():
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    raise subprocess.TimeoutExpired(self.args, timeout)
                for key, _ in selector.select(remaining):
                    data = os.read(key.fd, 65536)
                    if data:
                        self.collected[key.fileobj].append(data)
                    else:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
        self.wait(None if deadline is None else max(0, deadline - time.monotonic()))
        return tuple(None if end is None else b"".join(self.collected[end]) for end in (self.stdout, self.stderr))


@contextmanager
def terminal_process(args, *, env, cwd=None):
    """Borrow (process, master) until scope exit; collect and assert inside it.

    The caller owns response boundaries and explicit exit assertions. This owner
    only retires the child and descriptors, retaining the slave through collection
    and reap so Darwin does not discard unread output. Do not close borrowed handles.
    """
    master, slave = open_pty()
    process = None
    try:
        process = spawn(args, env=env, cwd=cwd, stdin=slave, stdout=slave, stderr=slave)
        yield process, master
    finally:
        dispose_all(lambda: stop_process(process, timeout=5) if process is not None else None,
                    lambda: close_pty(master), lambda: close_pty(slave))
