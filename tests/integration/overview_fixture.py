"""The overview as a real terminal shows it: rui on a PTY with a real Host and
Store, each screen read cell by cell by libghostty-vt. The library the
overview_*_cases modules share; overview_integration.py runs them.
"""
from contextlib import contextmanager
import fcntl
import json
import os
import shutil
import struct
import subprocess
import termios
import threading

import model_fixture as fixture
import codex_fixture
from host_process import dispose_all, screen_fixture_root, stop_process, wait_for
from terminal_process import COLUMNS, ROWS, answers_to, close_pty, open_pty, spawn
from terminal_screen import ScreenCapture


class Screen:
    """One rui on one PTY. `wait` reads output until a committed frame
    satisfies a predicate; a rui that exits meanwhile fails with its last
    raw output, where a panic and its stack land."""

    def __init__(self, process, master, columns, rows):
        self.process, self.master = process, master
        self.capture = ScreenCapture(columns, rows, reply=answers_to(master))
        self.tail = bytearray()
        os.set_blocking(master, False)

    def _read(self):
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            return False
        except OSError:
            return False
        self.capture.feed(data)
        self.tail.extend(data)
        del self.tail[:-16384]
        return bool(data)

    @property
    def text(self):
        """The latest committed frame, one string with a row per line."""
        return self.capture.completed

    def rows(self):
        return self.text.split("\n")

    def style(self, text, offset=0):
        """The cell style where `text` starts in the latest frame: its
        colours, `reverse`, and the other attributes terminal_screen reads."""
        return self.capture.style(text, offset)

    def wait(self, predicate, description, timeout=15):
        """Return the first committed frame `predicate(frame)` accepts."""
        def observe():
            self._read()
            if self.process.poll() is not None:
                self._read()
                raise AssertionError("rui exited", self.process.returncode, description, self.text,
                                     bytes(self.tail[-4096:]).decode(errors="replace"))
            return self.text
        return wait_for(observe, f"overview frame: {description}", timeout, ready=predicate)

    def contains(self, marker, timeout=15):
        return self.wait(lambda frame: marker in frame, marker, timeout)

    def keys(self, data):
        """Write bytes as the terminal would send them (Enter is b"\\r")."""
        os.write(self.master, data if isinstance(data, bytes) else data.encode())

    def resize(self, columns, rows):
        """Resize the terminal as a window resize does: the PTY's size,
        which signals rui, and the observer's screen."""
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.capture.resize(columns, rows)

    def click(self, column, row, button=0):
        """A left press and release at 1-based (column, row), as SGR mouse
        reporting sends them."""
        self.keys(f"\x1b[<{button};{column};{row}M\x1b[<{button};{column};{row}m".encode())


class World:
    """A private HOME, Store and Workspace with a running Host whose model
    endpoint answers from `responses_by_input` (a Message's text to an SSE
    body, or to (body, threading.Event) to hold it until the event is set)."""

    def __init__(self, prefix, responses_by_input=None, *, active_capacity=1):
        self.root = screen_fixture_root(f"rui-overview-{prefix}.")
        self.home = self.root / "home"
        (self.home / ".config/rui").mkdir(parents=True, mode=0o700)
        codex_fixture.credentials(self.home / ".config/rui/codex.json")
        self.store = self.root / "store"
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        # A colour terminal, whatever the runner's own settings: the screen's
        # colours are part of what these cases check.
        self.env = {key: value for key, value in os.environ.items() if key != "NO_COLOR"}
        self.env.update(HOME=str(self.home), TERM="xterm-256color", COLORTERM="truecolor")
        self.endpoint = fixture.SuccessEndpoint([], responses_by_input or {})
        threading.Thread(target=self.endpoint.serve_forever, daemon=True).start()
        self.host = fixture.start_host(self.store, f"http://127.0.0.1:{self.endpoint.server_port}/responses",
                                       active_capacity=active_capacity)
        self.run("defaults", "configure", "--store", self.store, "--provider", "codex", "--model", "gpt-6-luna")

    def close(self):
        dispose_all(lambda: stop_process(self.host, timeout=5), self.endpoint.shutdown, self.endpoint.server_close,
                    lambda: shutil.rmtree(self.root, ignore_errors=True))

    def run(self, *args, expect=0, input=None):
        """One rui command in this HOME; returns stdout."""
        result = subprocess.run([str(fixture.RUI), *map(str, args)], env=self.env, cwd=self.workspace,
                                capture_output=True, text=True, timeout=20, input=input)
        assert result.returncode == expect, (args, result.stdout, result.stderr)
        return result.stdout

    def session(self, *args):
        """A new Session configured with `args` (such as "--label", "x"); its ID."""
        reply = json.loads(self.run("session", "configure", "--store", self.store, "--workspace", self.workspace,
                                    "--provider", "codex", "--model", "gpt-6-luna", *args))
        return reply["answer"]["session"]

    def inspect(self, session):
        return json.loads(self.run("session", "inspect", "--store", self.store, "--session", session))

    @contextmanager
    def overview(self, *args, columns=COLUMNS, rows=ROWS):
        """Bare `rui` (plus `args`) on a PTY of this size, until it shows
        its first list; yields the Screen. Leaves with Ctrl-D, then the
        process is stopped if it has not left."""
        master, slave = open_pty(columns, rows)
        process = None
        try:
            process = spawn([str(fixture.RUI), *map(str, args)], env=self.env, cwd=self.workspace,
                            stdin=slave, stdout=slave, stderr=slave)
            screen = Screen(process, master, columns, rows)
            screen.wait(lambda frame: "+ New Session" in frame and "Settings" in frame and "enter open" in frame,
                        "the overview's pinned rows and footer")
            yield screen
            if process.poll() is None:
                screen.keys(b"\x04")
        finally:
            dispose_all(lambda: stop_process(process, timeout=5) if process is not None else None,
                        lambda: close_pty(master), lambda: close_pty(slave))


@contextmanager
def world(prefix, responses_by_input=None, **kwargs):
    w = World(prefix, responses_by_input, **kwargs)
    try:
        yield w
    finally:
        w.close()
