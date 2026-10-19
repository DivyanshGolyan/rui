"""Exact-byte PTY custody for synthetic frontend contract tests.

The slave stays open until the child is reaped, including on Darwin. No tmux,
terminal key names, shell quoting, or text encoding intervenes in send(bytes).
"""
import errno
import fcntl
import json
import os
import pathlib
import select
import signal
import struct
import subprocess
import sys
import termios
import time
from contextlib import contextmanager

INTEGRATION = pathlib.Path(__file__).resolve().parents[2] / "integration"
sys.path.insert(0, str(INTEGRATION))
from host_process import dispose_all, stop_process
from terminal_process import open_pty
from terminal_screen import ScreenCapture

LIMIT = 1024 * 1024


@contextmanager
def defer_signals():
    """Deliver interruption after acquisition and registration, never between.

    Caught handlers still reset normally on exec. No blocked signal mask or
    ignored disposition leaks into a newly spawned Host/caller.
    """
    previous = {}
    pending = []
    try:
        for number in (signal.SIGINT, signal.SIGHUP, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, lambda number, frame: pending.append((number, frame)))
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
        if pending and sys.exception() is None:
            number, frame = pending[0]
            handler = previous[number]
            if callable(handler):
                handler(number, frame)
            elif handler != signal.SIG_IGN:
                raise SystemExit(128 + number)


class DirectPty:
    def __init__(self, args, *, env, cwd, output, columns=80, rows=24):
        self.output = pathlib.Path(output)
        self.output.mkdir(parents=True, exist_ok=True)
        self.master = self.slave = None
        self.process = None
        self.files = []
        self.total = 0
        self.eof = set()
        self.closed = False
        try:
            with defer_signals():
                self.master, self.slave = open_pty(columns, rows)
                self.original = termios.tcgetattr(self.slave)
                self.original[6][termios.VERASE] = b"\x08"
                termios.tcsetattr(self.slave, termios.TCSANOW, self.original)
                self.flags = fcntl.fcntl(self.slave, fcntl.F_GETFL)
                self.screen = ScreenCapture(columns, rows)
                self.input = self._open("input.bin", "wb")
                self.raw = self._open("output.bin", "wb")
                self.errors = self._open("stderr.bin", "wb")
                self.events = self._open("events.jsonl", "w")
                self.process = subprocess.Popen(args, env=env, cwd=cwd, stdin=self.slave,
                                                stdout=self.slave, stderr=subprocess.PIPE)
                os.set_blocking(self.master, False)
                self.event("launch", pid=self.process.pid, columns=columns, rows=rows)
        except BaseException:
            self.close()
            raise

    def _open(self, name, mode):
        stream = open(self.output / name, mode)
        self.files.append(stream)
        return stream

    def event(self, kind, **values):
        self.events.write(json.dumps({"event": kind, "at_ns": time.monotonic_ns(), **values}) + "\n")
        self.events.flush()

    def pump(self, timeout=0):
        descriptors = [self.master, self.process.stderr.fileno()]
        ready = select.select([fd for fd in descriptors if fd not in self.eof], [], [], timeout)[0]
        for fd in ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError as error:
                if fd != self.master or error.errno != errno.EIO:
                    raise
                chunk = b""
            if not chunk:
                self.eof.add(fd)
                continue
            # Save before parsing/asserting, including a malformed final frame.
            stream = self.raw if fd == self.master else self.errors
            stream.write(chunk)
            stream.flush()
            self.total += len(chunk)
            assert self.total < LIMIT, "PTY transcript exceeds one MiB"
            if fd == self.master:
                self.screen.feed(chunk)
        return bool(ready)

    def wait(self, predicate, *, label, timeout=15, after=None):
        deadline = time.monotonic() + timeout
        while not ((after is None or self.screen.generation > after) and predicate()):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"{label}: no matching committed frame; exit={self.process.poll()}; "
                                   f"screen={self.screen.completed!r}")
            self.pump(min(remaining, 0.1))
            if self.process.poll() is not None:
                while self.pump():
                    pass
                raise AssertionError(f"{label}: caller exited {self.process.returncode}; "
                                     f"screen={self.screen.completed!r}")
        self.event("observed", label=label, generation=self.screen.generation,
                   cursor=[self.screen.screen.cursor.x, self.screen.screen.cursor.y],
                   screen=self.screen.completed)

    def marker(self, text, **kwargs):
        self.wait(lambda: self.screen.reached(text), label=text, **kwargs)

    def draft(self, text, caret, **kwargs):
        self.wait(lambda: self.screen.draft(text, caret), label=f"draft {text!r} caret {caret}", **kwargs)

    def send(self, data):
        assert isinstance(data, bytes), "send requires exact bytes"
        deadline = time.monotonic() + 10
        offset = 0
        self.event("input", hex=data.hex())
        while offset < len(data):
            if time.monotonic() >= deadline:
                raise TimeoutError("PTY master input write deadline")
            try:
                count = os.write(self.master, data[offset:offset + 1024])
            except BlockingIOError:
                self.pump(0.01)
                continue
            assert count > 0, "zero PTY input write"
            self.input.write(data[offset:offset + count])
            self.input.flush()
            offset += count
            self.pump()

    def pause(self, seconds):
        """Explicit vector delay; still drain both output channels."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump(min(0.05, max(0, deadline - time.monotonic())))

    def resize(self, columns, rows=24):
        self.screen.resize(columns, rows)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.event("resize", columns=columns, rows=rows)

    def finish(self, expected=0):
        deadline = time.monotonic() + 10
        while True:
            exited = self.process.poll() is not None
            if exited and not self.pump():
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("PTY child exit/drain deadline")
            self.pump(min(remaining, 0.1))
        assert self.process.wait(timeout=1) == expected, (
            "caller exit", self.process.returncode, expected, (self.output / "stderr.bin").read_bytes())
        actual = termios.tcgetattr(self.slave)
        wanted = list(self.original)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            wanted[3] &= ~mask
        assert actual == wanted, ("termios restoration", wanted, actual)
        assert fcntl.fcntl(self.slave, fcntl.F_GETFL) == self.flags, "slave flags not restored"
        output = (self.output / "output.bin").read_bytes()
        for reset in (b"\x1b[?1049l", b"\x1b[?2004l", b"\x1b[?25h"):
            assert reset in output, ("missing terminal cleanup", reset)
        self.event("retired", returncode=self.process.returncode, restored=True)

    def close(self):
        if self.closed:
            return
        self.closed = True
        dispose_all(
            lambda: self.pump() if self.process is not None else None,
            lambda: stop_process(self.process, timeout=5) if self.process is not None else None,
            lambda: os.close(self.master) if self.master is not None else None,
            lambda: os.close(self.slave) if self.slave is not None else None,
            *(stream.close for stream in self.files))

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self.close()
