"""Real frontend scenarios; each interpreter owns one HOME/Store/Host/provider."""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import time

from driver import DirectPty, defer_signals
from host_process import canonical_fixture_root, dispose_all
import model_fixture as model
import codex_integration as codex
from canonical_failure_integration import ReplyProxy


def assert_submitted(requests, expected):
    actual = [next(item["content"][0]["text"] for item in reversed(json.loads(body)["input"])
                   if item.get("role") == "user") for body in requests]
    assert actual == expected, ("exact submitted Message bytes", actual, expected)


class Fixture:
    def __init__(self, binary, output):
        self.binary, self.output = str(binary), pathlib.Path(output)
        self.root = None
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("RUI_", "XDG_")) and key not in ("TMUX", "TMUX_PANE")}
        model.RUI = pathlib.Path(binary)
        self.host = self.endpoint = self.thread = self.proxy = self.tty = self.tmux = None
        self.gates = []

    def start(self):
        with defer_signals():
            self.root = canonical_fixture_root(tempfile.mkdtemp(prefix="td4-"))
            self.home, self.store = self.root / "h", self.root / "s"
            self.home.mkdir(mode=0o700)
            self.env.update(HOME=str(self.home), TERM="xterm-256color")
            # Host fixture uses inherited HOME; one interpreter per row.
            os.environ.update(HOME=str(self.home))
        with defer_signals():
            self.endpoint = model.SuccessEndpoint([])
        self.thread = threading.Thread(target=self.endpoint.serve_forever)
        with defer_signals():
            self.thread.start()
        with defer_signals():
            self.host = model.start_host(self.store, f"http://127.0.0.1:{self.endpoint.server_port}/responses")
        (self.output / "ownership.json").write_text(json.dumps({"root": str(self.root), "host_pid": self.host.pid}))
        result = subprocess.run([self.binary, "session", "configure", "--store", str(self.store),
            "--session", "td4", "--workspace", str(self.root), "--provider", "codex", "--model", "model-a"],
            env=self.env, capture_output=True, timeout=20)
        assert result.returncode == 0, ("configuration setup", result.stdout, result.stderr)
        codex.credentials(self.home / ".config/rui/codex.json")
        # Public Configure itself captures one request; input refusal must not
        # create another, rather than pretending fixture setup created none.
        self.capture_baseline = set((self.home / ".config/rui/requests").glob("*.json"))

    def answer(self, marker, gate=None, *, text=None):
        payload = model.sse_answer(marker, marker + "-reason", marker + "-message", marker if text is None else text)[0]
        self.endpoint.responses.append(payload if gate is None else (payload, gate))
        if gate is not None:
            self.gates.append(gate)

    def terminal(self):
        with defer_signals():
            self.tty = DirectPty([self.binary, "session", "resume", "--store", str(self.store), "--", "td4"],
                                 env=self.env, cwd=self.root, output=self.output)
        self.tty.draft("", 2)
        return self.tty

    def save(self):
        # Synthetic provider requests only; never copy HOME, Store or credentials.
        if self.endpoint is not None:
            (self.output / "requests.json").write_text(json.dumps(
                [json.loads(body) for body in self.endpoint.requests], ensure_ascii=False, indent=2))
        if self.proxy is not None:
            (self.output / "message-exchanges.json").write_text(json.dumps(
                [{"request_hex": body.hex(), "reply_hex": reply.hex()} for body, reply in self.proxy.exchanges],
                indent=2))
        if self.tty is not None:
            (self.output / "screen.txt").write_text(self.tty.screen.completed)

    def close(self):
        # Release all deliberate holds first, then reap caller before restoring
        # ReplyProxy's socket path. No caller can observe its old rename gap.
        dispose_all(*(gate.set for gate in self.gates),
            lambda: self.tty.close() if self.tty is not None else None,
            lambda: self.tmux.close() if self.tmux is not None else None,
            self.save,
            lambda: self.proxy.close() if self.proxy is not None else None,
            lambda: model.stop_host(self.host) if self.host is not None else None,
            lambda: self.endpoint.shutdown() if self.thread is not None and self.thread.ident is not None else None,
            lambda: self.endpoint.server_close() if self.endpoint is not None else None,
            lambda: self.thread.join(timeout=5) if self.thread is not None and self.thread.ident is not None else None,
            self.retired)

    def retired(self):
        assert self.host is None or self.host.poll() is not None, "owned Host survived disposal"
        assert self.tty is None or self.tty.process is None or self.tty.process.poll() is not None, "owned caller survived disposal"
        assert self.tmux is None or self.tmux.clean, "tmux disposal unconfirmed; retained private root"
        assert self.thread is None or not self.thread.is_alive(), "provider thread survived disposal"
        if self.root is not None:
            shutil.rmtree(self.root)
        (self.output / "cleanup.json").write_text(json.dumps({"host_reaped": True,
            "caller_reaped": True, "provider_joined": True, "private_root_removed": True}))

    def __enter__(self):
        try:
            self.start()
        except BaseException:
            self.close()
            raise
        return self

    def __exit__(self, *exception):
        self.close()


def chunks(tty, vector):
    for chunk in vector:
        tty.pause(chunk.get("delay_before", 0))
        if "resize" in chunk:
            tty.resize(*chunk["resize"])
        else:
            tty.send(bytes.fromhex(chunk["hex"]))


def editor(fixture, row):
    fixture.answer("TD4 exact answer")
    tty = fixture.terminal()
    chunks(tty, row["chunks"])
    # Each vector supplies its own submit byte(s). This makes wrong Enter,
    # swallowed suffix and accidental multi-Message behavior observable.
    tty.marker("TD4 exact answer")
    tty.draft("", 2)
    assert_submitted(fixture.endpoint.requests, [row["expected"]])
    tty.send(b"/exit\r")
    tty.finish()
    assert_submitted(fixture.endpoint.requests, [row["expected"]])


def expiry(fixture, row):
    tty = fixture.terminal()
    started = time.monotonic()
    chunks(tty, row["chunks"])
    tty.finish(expected=1)
    assert time.monotonic() - started >= 1.8, "incomplete input expired before its two-second allowance"
    errors = (fixture.output / "stderr.bin").read_bytes()
    assert b"IncompleteTerminalInput" in errors, ("incomplete sequence diagnostic", errors)
    assert fixture.endpoint.requests == [], "incomplete input submitted a Message"
    assert set((fixture.home / ".config/rui/requests").glob("*.json")) == fixture.capture_baseline, "incomplete input captured intent"


def rejection(fixture, row):
    fixture.answer("TD4 valid after rejection")
    tty = fixture.terminal()
    chunks(tty, row["chunks"])
    tty.marker("Input rejected; nothing sent.")
    assert fixture.endpoint.requests == [], "rejected input reached provider"
    assert set((fixture.home / ".config/rui/requests").glob("*.json")) == fixture.capture_baseline, "rejected input captured intent"
    tty.send(b"valid\r")
    tty.marker("TD4 valid after rejection")
    assert_submitted(fixture.endpoint.requests, ["valid"])
    tty.send(b"/exit\r")
    tty.finish()


def recovery(fixture, row):
    release = threading.Event()
    fixture.answer("TD4 original answer", release)
    fixture.answer("TD4 next answer")
    # Install before any caller starts; no concurrent frontend socket borrower.
    with defer_signals():
        fixture.proxy = ReplyProxy(fixture.host, "/v1/message",
            lambda response: b"" if len(fixture.proxy.exchanges) == 1 else response)
    tty = fixture.terminal()
    tty.send("original éZ\r".encode())
    tty.marker("Not confirmed")
    assert len(fixture.proxy.exchanges) == 1, "original not transmitted exactly once"
    original = fixture.proxy.exchanges[0][0]
    assert json.loads(original)["text"]["value"] == "original éZ", "wrong original capture"
    tty.send("next café!\x1b[D\x1b[DX".encode())
    tty.draft("next cafXé!", 11)
    release.set()
    tty.marker("TD4 original answer")
    chunks(tty, row["chunks"])
    tty.marker("Original confirmed")
    assert len(fixture.proxy.exchanges) == 2, "recovery did not replay exactly once"
    assert fixture.proxy.exchanges[1][0] == original, "recovery changed original key or bytes"
    tty.draft("next cafXé!", 11)
    tty.send(b"Y\r")
    tty.marker("TD4 next answer")
    assert len(fixture.proxy.exchanges) == 3, "next Enter did not create exactly one new intent"
    next_request = json.loads(fixture.proxy.exchanges[2][0])
    assert next_request["text"]["value"] == "next cafXYé!", next_request
    assert next_request["key"] != json.loads(original)["key"], "next draft reused original key"
    assert_submitted(fixture.endpoint.requests, ["original éZ", "next cafXYé!"])
    tty.send(b"/exit\r")
    tty.finish()


def navigation(fixture, row):
    # A real completed answer supplies enough history for page and wheel input
    # to move the viewport; an empty Session cannot distinguish ignored keys.
    fixture.answer("TD4 history end", text="\n".join(
        [f"History line {number:03d}" for number in range(100)] + ["TD4 history end"]))
    tty = fixture.terminal()
    tty.send(b"seed history\r")
    tty.marker("TD4 history end")
    tty.draft("", 2)
    captures = set((fixture.home / ".config/rui/requests").glob("*.json"))
    generation = tty.screen.generation
    chunks(tty, row["chunks"])
    tty.wait(lambda: tty.screen.completed.startswith("Browsing"), label="navigation entered browsing", after=generation)
    if row.get("status"):
        tty.marker("Session: td4")
        tty.marker("Work:")
        tty.marker("Permission:")
    generation = tty.screen.generation
    chunks(tty, row["return_chunks"])
    tty.wait(lambda: not tty.screen.completed.startswith("Browsing") and tty.screen.draft("", 2),
             label="navigation returned to live empty composer", after=generation)
    assert_submitted(fixture.endpoint.requests, ["seed history"])
    assert set((fixture.home / ".config/rui/requests").glob("*.json")) == captures, "navigation captured intent"
    tty.send(b"/exit\r")
    tty.finish()


SCENARIOS = {"editor": editor, "expiry": expiry, "rejection": rejection, "recovery": recovery,
             "navigation": navigation}
