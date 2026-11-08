#!/usr/bin/env python3
"""Disposable real-Host picker journey; local stub only, no user Store."""
import fcntl
import json
import os
import pathlib
import sys
import subprocess
import termios
from types import SimpleNamespace

# The native backend opens /dev/tty. Acquire the PTY as controlling terminal
# in a separate child before exec, not via preexec_fn in the threaded parent.
if sys.argv[1:2] == ["--tty-exec"]:
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    fd = os.open("/dev/tty", os.O_RDWR)
    os.close(fd)
    os.execv(sys.argv[2], sys.argv[2:])

# Fixture subprocesses inherit only a small non-secret environment. Fixture.start
# installs its own HOME and a synthetic local provider endpoint.
path = os.environ.get("PATH", "/usr/bin:/bin")
os.environ.clear()
os.environ.update(PATH=path, TERM="xterm-256color")

from driver import DirectPty, defer_signals
from scenarios import Fixture


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


def main():
    check_oracle()
    if sys.argv[1:] == ["--oracle-self-test"]:
        print("native framed draft oracle checks passed")
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
             "--to", fixture.session, "--key", "picker-page-seed"],
            input="PICKER PAGE SEED MESSAGE", text=True, env=fixture.env,
            capture_output=True, timeout=20, check=True,
        )
        assert json.loads(seeded.stdout)["answer"]["status"] == "accepted", "seed was not admitted"
        with defer_signals():
            fixture.tty = DirectPty([sys.executable, str(pathlib.Path(__file__).resolve()), "--tty-exec",
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
        tty.finish()
    finally:
        fixture.close()
    (output / "result.txt").write_text("picker journey and owned cleanup passed; local stub only\n")


if __name__ == "__main__":
    main()
