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
        return self.capture.completed

    def rows(self):
        return self.text.split("\n")

    def style(self, text, offset=0):
        return self.capture.style(text, offset)

    def wait(self, predicate, description, timeout=15):
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
        os.write(self.master, data if isinstance(data, bytes) else data.encode())

    def resize(self, columns, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.capture.resize(columns, rows)

    def click(self, column, row, button=0):
        self.keys(f"\x1b[<{button};{column};{row}M\x1b[<{button};{column};{row}m".encode())


class World:

    def __init__(self, prefix, responses_by_input=None, *, active_capacity=1, host_factory=None,
                 host_options=(), store_setup=None):
        self.root = self.endpoint = self.host = None
        try:
            self.root = screen_fixture_root(f"rui-overview-{prefix}.")
            self.home = self.root / "home"
            (self.home / ".config/rui").mkdir(parents=True, mode=0o700)
            codex_fixture.credentials(self.home / ".config/rui/codex.json")
            self.store = self.root / "store"
            self.workspace = self.root / "workspace"
            self.workspace.mkdir()
            self.env = {key: value for key, value in os.environ.items() if key != "NO_COLOR"}
            self.env.update(HOME=str(self.home), TERM="xterm-256color", COLORTERM="truecolor")
            if store_setup is not None:
                store_setup(self)
            self.endpoint = fixture.SuccessEndpoint([], responses_by_input or {})
            threading.Thread(target=self.endpoint.serve_forever, daemon=True).start()
            start_host = host_factory or fixture.start_host
            self.host = start_host(self.store, f"http://127.0.0.1:{self.endpoint.server_port}/responses",
                                   *host_options, active_capacity=active_capacity)
            self.run("defaults", "configure", "--store", self.store, "--provider", "codex", "--model", "gpt-6-luna")
        except BaseException:
            self.close()
            raise

    def close(self):
        dispose_all(lambda: stop_process(self.host, timeout=5) if self.host is not None else None,
                    lambda: self.endpoint.shutdown() if self.endpoint is not None else None,
                    lambda: self.endpoint.server_close() if self.endpoint is not None else None,
                    lambda: shutil.rmtree(self.root) if self.root is not None else None)

    def run(self, *args, expect=0, input=None):
        result = subprocess.run([str(fixture.RUI), *map(str, args)], env=self.env, cwd=self.workspace,
                                capture_output=True, text=True, timeout=20, input=input)
        assert result.returncode == expect, (args, result.stdout, result.stderr)
        return result.stdout

    def session(self, *args):
        reply = json.loads(self.run("session", "configure", "--store", self.store, "--workspace", self.workspace,
                                    "--provider", "codex", "--model", "gpt-6-luna", *args))
        return reply["answer"]["session"]

    def inspect(self, session):
        return json.loads(self.run("session", "inspect", "--store", self.store, "--session", session))

    @contextmanager
    def overview(self, *args, columns=COLUMNS, rows=ROWS, keep_launch=False):
        master, slave = open_pty(columns, rows)
        process = None
        try:
            process = spawn([str(fixture.RUI), *map(str, args)], env=self.env, cwd=self.workspace,
                            stdin=slave, stdout=slave, stderr=slave)
            screen = Screen(process, master, columns, rows)
            if columns >= 100 and not args:
                launched = screen.wait(lambda frame: "+ New Session" in frame and "Settings" in frame
                                       and "Type a task" in frame and "enter open" not in frame
                                       and screen.capture.draft("", 2),
                                       "the wide launch chat beside the list")
                assert "│" in launched, launched
                if not keep_launch:
                    screen.keys(b"\x1b")
            if not keep_launch:
                screen.wait(lambda frame: "+ New Session" in frame and "Settings" in frame
                            and "Type a task" not in frame and "│" not in frame,
                            "the full overview and its pinned rows")
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
