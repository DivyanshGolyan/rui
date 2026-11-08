#!/usr/bin/env python3
"""Disposable real-Host picker journey; local stub only, no user Store."""
import fcntl
import json
import os
import pathlib
import signal
import sys
import subprocess
import termios
import tempfile
from types import SimpleNamespace

# Keep the controlling-session leader alive until the parent has inspected
# termios. Rui is its child; no preexec_fn runs in the threaded fixture parent.
if sys.argv[1:2] == ["--tty-supervisor"]:
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    fd = os.open("/dev/tty", os.O_RDWR)
    os.close(fd)
    child = None
    def stop_supervisor(_number, _frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop_supervisor)
    try:
        child = subprocess.Popen(sys.argv[2:])
        code = child.wait()
        print(f"UI_EXIT={code}", file=sys.stderr, flush=True)
        while True:
            signal.pause()
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)

# Fixture subprocesses inherit only a small non-secret environment. Fixture.start
# installs its own HOME and a synthetic local provider endpoint.
path = os.environ.get("PATH", "/usr/bin:/bin")
os.environ.clear()
os.environ.update(PATH=path, TERM="xterm-256color")

from driver import DirectPty, assert_file_flags, defer_signals
from scenarios import Fixture


class SupervisedPty(DirectPty):
    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=7)
            except subprocess.TimeoutExpired:
                # This supervisor owns its session and group; never signal the
                # parent process group if startup failed before setsid.
                if os.getpgid(self.process.pid) == self.process.pid:
                    os.killpg(self.process.pid, signal.SIGKILL)
                else:
                    self.process.kill()
                self.process.wait(timeout=5)
        super().close()


def finish_supervised(tty):
    tty.wait(lambda: b"UI_EXIT=" in (tty.output / "stderr.bin").read_bytes(),
             label="supervised UI exit", timeout=15)
    while tty.pump():
        pass
    errors = (tty.output / "stderr.bin").read_bytes()
    assert errors.endswith(b"UI_EXIT=0\n"), ("UI exit status", errors)
    assert tty.process.poll() is None, "terminal owner exited before restoration check"
    actual, wanted = termios.tcgetattr(tty.slave), list(tty.original)
    if sys.platform == "darwin":
        mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
        actual[3] &= ~mask
        wanted[3] &= ~mask
    assert actual == wanted, ("termios restoration", wanted, actual)
    assert_file_flags(fcntl.fcntl(tty.slave, fcntl.F_GETFL), tty.flags)
    output = (tty.output / "output.bin").read_bytes()
    for reset in (b"\x1b[?1049l", b"\x1b[?2004l", b"\x1b[?25h"):
        assert reset in output, ("missing terminal cleanup", reset)
    tty.event("retired", returncode=0, restored=True, supervisor_alive=True)


def selected(tty):
    rows = [parts[0] for line in tty.screen.completed.splitlines()
            if line.strip().startswith("> ")
            if (parts := line.strip()[2:].split())]
    return rows[0] if len(rows) == 1 else None


def framed_draft(capture, text, caret):
    """Assert exact ASCII editor content and caret inside its committed border."""
    if capture.synchronized or capture.generation == 0:
        return False
    cursor = capture.screen.cursor
    cells = capture.completed_cells
    y, x = cursor.y, cursor.x
    if y < 1 or y + 1 >= len(cells) or len(cells[y]) < 3:
        return False
    rows = ["".join(cell.data or " " for cell in cells[row]) for row in (y - 1, y, y + 1)]
    top, current, bottom = rows
    return (top.startswith("╭") and top.endswith("╮")
            and current.startswith("│") and current.endswith("│")
            and bottom.startswith("╰") and bottom.endswith("╯")
            and current[1:-1].rstrip() == text and x == 1 + caret)


def check_oracle():
    def capture(lines, x, y):
        return SimpleNamespace(synchronized=False, generation=1,
            screen=SimpleNamespace(cursor=SimpleNamespace(x=x, y=y)),
            completed_cells=[[SimpleNamespace(data=c) for c in row] for row in lines])
    correct = capture(["╭──────╮", "│draft │", "╰──────╯"], 6, 1)
    assert framed_draft(correct, "draft", 5)
    assert not framed_draft(correct, "draft", 4)
    assert not framed_draft(correct, "other", 5)
    wrong_row = capture(["╭──────╮", "│draft │", "╰──────╯", "draft   "], 6, 3)
    assert not framed_draft(wrong_row, "draft", 5)


def check_supervisor():
    for mutate in (False, True):
        with tempfile.TemporaryDirectory() as directory:
            script = ("import os,termios; "
                      + ("t=termios.tcgetattr(0); t[3] ^= termios.ICANON; "
                         "termios.tcsetattr(0,termios.TCSANOW,t); " if mutate else "")
                      + "os.write(1,b'\\x1b[?1049l\\x1b[?2004l\\x1b[?25h')")
            tty = SupervisedPty([sys.executable, str(pathlib.Path(__file__).resolve()),
                                 "--tty-supervisor", sys.executable, "-c", script],
                                env=os.environ, cwd=directory,
                                output=pathlib.Path(directory) / "evidence")
            try:
                if mutate:
                    try:
                        finish_supervised(tty)
                    except AssertionError as error:
                        assert "termios restoration" in str(error), error
                    else:
                        raise AssertionError("bad termios falsely passed")
                else:
                    finish_supervised(tty)
            finally:
                tty.close()
            assert tty.process.poll() is not None, "supervisor not reaped"


def main():
    check_oracle()
    if sys.argv[1:] == ["--oracle-self-test"]:
        print("native framed draft oracle checks passed")
        return
    if sys.argv[1:] == ["--supervisor-self-test"]:
        check_supervisor()
        print("supervisor restoration and negative control passed")
        return
    binary = pathlib.Path(sys.argv[1]).resolve(strict=True)
    output = pathlib.Path(sys.argv[2]).resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.umask(0o077)
    fixture = Fixture(binary, output)
    try:
        fixture.start()
        # This unique saved Message can only be rendered after the matching
        # Session page is installed. It is sent solely to the fixture Host and
        # its loopback synthetic provider.
        fixture.answer("PICKER PAGE SEED ANSWER")
        seeded = subprocess.run(
            [str(binary), "session", "send", "--store", str(fixture.store),
             "--to", fixture.session, "--record", str(fixture.root / "picker-seed.json"),
             "--key", "picker-page-seed"],
            input="PICKER PAGE SEED MESSAGE", text=True, env=fixture.env,
            capture_output=True, timeout=20, check=False,
        )
        (output / "seed-stderr.txt").write_text(seeded.stderr)
        assert seeded.returncode == 0, f"seed command failed with exit {seeded.returncode}; see seed-stderr.txt"
        assert json.loads(seeded.stdout)["answer"]["status"] == "accepted", "seed was not admitted"
        with defer_signals():
            fixture.tty = SupervisedPty([sys.executable, str(pathlib.Path(__file__).resolve()), "--tty-supervisor",
                                    str(binary), "--store", str(fixture.store)],
                                    env=fixture.env, cwd=fixture.root, output=output)
        tty = fixture.tty
        tty.marker("Sessions")
        tty.send(b"/model\r")
        tty.marker("select · Enter choose")
        tty.wait(lambda: selected(tty) is not None, label="selected model row")
        initial = selected(tty)
        tty.send(b"\x1b[B")
        tty.wait(lambda: selected(tty) not in (None, initial), label="model cursor moved")
        tty.send(b"draft")
        tty.wait(lambda: framed_draft(tty.screen, "draft", 5), label="framed draft and caret")
        assert not framed_draft(tty.screen, "draft", 4)
        tty.send(b"\x7f" * 5)
        tty.wait(lambda: framed_draft(tty.screen, "", 0), label="empty framed draft and caret")
        tty.send(b"/model\r")
        tty.marker("select · Enter choose")
        tty.wait(lambda: selected(tty) is not None, label="model list reopened")
        initial = selected(tty)
        tty.send(b"\x1b[B")
        tty.wait(lambda: selected(tty) not in (None, initial), label="choose different model")
        chosen = selected(tty)
        tty.send(b"\r")
        tty.wait(lambda: "Use:" in tty.screen.completed or "Model default saved" in tty.screen.completed,
                 label="provider choice or saved")
        if "Use:" in tty.screen.completed:
            assert "> ChatGPT" in tty.screen.completed, "unexpected chosen sign-in"
            tty.send(b"\r")
        tty.marker("Model default saved")
        preferences = (fixture.home / ".config/rui/preferences").read_text()
        assert f"model={chosen}\n" in preferences, "saved identity differs from selected row"
        assert "provider=codex\n" in preferences, "saved provider does not match fixture sign-in"
        tty.send(b"\x1b\r")  # Alt-Enter opens fixture's existing Session.
        tty.wait(lambda: tty.screen.reached(f"Session {fixture.session}")
                 and tty.screen.reached("PICKER PAGE SEED MESSAGE"),
                 label="Session page installed with seeded Message")
        tty.send(b"/model\r")
        tty.marker("new Session: /model in overview")
        assert "gpt-6-luna" in tty.screen.completed, "Session fixed model not reported"
        assert (fixture.home / ".config/rui/preferences").read_text() == preferences, "Session /model changed defaults"
        tty.send(b"\x11")
        finish_supervised(tty)
    finally:
        fixture.close()
    (output / "result.txt").write_text("picker journey and owned cleanup passed; local stub only\n")


if __name__ == "__main__":
    main()
