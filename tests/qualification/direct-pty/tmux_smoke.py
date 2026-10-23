"""Five short synthetic tmux rows accompanying the primary direct-key matrix."""
import json
import os
import shlex
import signal
import subprocess
import sys
import time

from driver import defer_signals
from host_process import dispose_all, stop_process
from scenarios import assert_submitted


class Tmux:
    """One foreground server and one pane wrapper that reaps the Rui caller."""
    def __init__(self, fixture):
        self.fixture = fixture
        self.socket = fixture.root / "tmux.sock"
        self.command = ["tmux", "-S", str(self.socket), "-f", "/dev/null"]
        self.server = self.log = self.pid = self.caller_pid = None
        self.clean = False

    def call(self, *args, check=True):
        result = subprocess.run([*self.command, *args], env=self.fixture.env,
                                capture_output=True, timeout=5)
        if check:
            assert result.returncode == 0, ("tmux setup/control", args, result.stderr)
        return result

    def start(self):
        fixture = self.fixture
        with defer_signals():
            self.log = open(fixture.output / "server.log", "wb")
            self.server = subprocess.Popen([*self.command, "-D"], env=fixture.env,
                                           stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 5
        while not self.socket.exists():
            assert self.server.poll() is None, "tmux server exited before socket creation"
            if time.monotonic() >= deadline:
                raise TimeoutError("tmux server socket setup")
            time.sleep(0.01)
        self.call("set-option", "-g", "remain-on-exit", "on")
        wrapper = fixture.root / "pane.py"
        wrapper.write_text(f"import sys\nsys.path.insert(0, {os.path.dirname(os.path.abspath(__file__))!r})\n" + '''import fcntl, json, os, pathlib, subprocess, termios
from driver import assert_file_flags
root = pathlib.Path(sys.argv[1])
before = termios.tcgetattr(0)
flags = fcntl.fcntl(0, fcntl.F_GETFL)
caller = subprocess.Popen(sys.argv[2:])
(root / "caller.pid").write_text(str(caller.pid))
status = caller.wait()
after = termios.tcgetattr(0)
if sys.platform == "darwin":
    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
    before[3] &= ~mask
    after[3] &= ~mask
flags_error = None
try:
    assert_file_flags(fcntl.fcntl(0, fcntl.F_GETFL), flags)
except AssertionError as error:
    flags_error = str(error)
(root / "caller-exit.json").write_text(json.dumps({"status": status,
    "restored": after == before and flags_error is None, "flags_error": flags_error}))
''')
        rui = shlex.join([sys.executable, str(wrapper), str(fixture.root), fixture.binary,
                         "session", "resume", "--store", str(fixture.store), "--", fixture.session])
        launch = fixture.root / "launch"
        shell = f"while [ ! -f {shlex.quote(str(launch))} ]; do sleep 0.01; done; exec {rui}"
        with defer_signals():
            result = self.call("new-session", "-d", "-s", "td4", "-x", "80", "-y", "24",
                               "-c", str(fixture.root), "-P", "-F", "#{pane_pid} #{pane_tty}", shell)
            self.pid = int(result.stdout.decode().strip().split()[0])
            self.call("pipe-pane", "-o", "-t", "td4:0.0", "cat > " + shlex.quote(str(fixture.output / "output.bin")))
            launch.touch()
            deadline = time.monotonic() + 5
            while not (fixture.root / "caller.pid").exists() or not (fixture.root / "caller.pid").read_text():
                if time.monotonic() >= deadline:
                    raise TimeoutError("tmux wrapper caller launch")
                time.sleep(0.01)
            self.caller_pid = int((fixture.root / "caller.pid").read_text())
            (fixture.output / "tmux-ownership.json").write_text(json.dumps({
                "server_pid": self.server.pid, "pane_pid": self.pid,
                "caller_pid": self.caller_pid, "socket": str(self.socket)}))

    def wait(self, predicate, label):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            result = self.call("capture-pane", "-p", "-t", "td4:0.0", check=False)
            if result.returncode == 0:
                (self.fixture.output / "pane.txt").write_bytes(result.stdout)
                if predicate(result.stdout.decode()):
                    return
            time.sleep(0.02)
        raise TimeoutError(f"tmux smoke {label}: no matching pane; see pane.txt")

    def caller_dead(self):
        result = self.call("display-message", "-p", "-t", "td4:0.0", "#{pane_dead}", check=False)
        return result.returncode == 0 and result.stdout.strip() == b"1"

    def finish(self):
        deadline = time.monotonic() + 10
        while not self.caller_dead():
            if time.monotonic() >= deadline:
                raise TimeoutError("tmux caller exit")
            time.sleep(0.02)
        facts = json.loads((self.fixture.root / "caller-exit.json").read_text())
        (self.fixture.output / "caller-exit.json").write_text(json.dumps(facts))
        assert facts == {"status": 0, "restored": True, "flags_error": None}, ("tmux caller exit/restoration", facts)

    def close(self):
        failure = []
        def attempt(action):
            try:
                action()
            except BaseException as error:
                failure.append(error)
                raise
        def caller():
            if self.pid is None:
                return
            deadline = time.monotonic() + 5
            if not self.caller_dead():
                try:
                    os.kill(self.caller_pid if self.caller_pid is not None else self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            while not self.caller_dead():
                if time.monotonic() >= deadline:
                    raise TimeoutError("tmux did not reap its owned caller")
                time.sleep(0.02)
        def server():
            if self.server is not None and self.server.poll() is None:
                self.call("kill-server")
        dispose_all(lambda: attempt(caller), lambda: attempt(server),
            lambda: attempt(lambda: stop_process(self.server, timeout=5)) if self.server is not None else None,
            lambda: self.log.close() if self.log is not None else None)
        self.clean = not failure
        (self.fixture.output / "tmux-cleanup.json").write_text(json.dumps({
            "clean": self.clean, "server_exit": self.server.returncode if self.server else None,
            "errors": [repr(error) for error in failure]}))


def smoke(fixture, row):
    fixture.answer("TD4 tmux answer")
    fixture.tmux = terminal = Tmux(fixture)
    terminal.start()
    terminal.wait(lambda text: "›" in text and "Opening" not in text, "empty composer")
    payload = bytes.fromhex(row["chunks"][0]["hex"])
    (fixture.output / "input.bin").write_bytes(payload)
    if row["name"] == "tmux-paste":
        terminal.call("set-buffer", "--", payload.decode())
        terminal.call("paste-buffer", "-p", "-t", "td4:0.0")
        terminal.call("send-keys", "-t", "td4:0.0", "Enter")
    else:
        if row["name"] == "tmux-resize":
            terminal.call("resize-window", "-t", "td4:0", "-x", "32", "-y", "12")
        terminal.call("send-keys", "-t", "td4:0.0", "-H", *(f"{byte:02x}" for byte in payload))
    if row["name"] == "tmux-status":
        terminal.wait(lambda text: "Browsing" in text and f"Session: {fixture.session}" in text
                      and "Permission:" in text and "Work:" in text, "status page")
        terminal.call("send-keys", "-t", "td4:0.0", "Escape")
        terminal.wait(lambda text: "Browsing" not in text and "›" in text, "status returned to live")
        assert_submitted(fixture.endpoint.requests, [])
        assert set((fixture.home / ".config/rui/requests").glob("*.json")) == fixture.capture_baseline, "status captured intent"
    else:
        terminal.wait(lambda text: "TD4 tmux answer" in text, "answer")
        assert_submitted(fixture.endpoint.requests, [row["expected"]])
    terminal.call("send-keys", "-t", "td4:0.0", "-l", "/exit")
    terminal.call("send-keys", "-t", "td4:0.0", "Enter")
    terminal.finish()
