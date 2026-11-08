#!/usr/bin/env python3
"""Disposable real-Host picker journey; local stub only, no user Store."""
import os
import pathlib
import sys

# Fixture subprocesses inherit only a small non-secret environment. Fixture.start
# installs its own HOME and a synthetic local provider endpoint.
path = os.environ.get("PATH", "/usr/bin:/bin")
os.environ.clear()
os.environ.update(PATH=path, TERM="xterm-256color")

from driver import DirectPty, defer_signals
from scenarios import Fixture


def selected(tty):
    rows = [line.strip()[2:].split()[0] for line in tty.screen.completed.splitlines()
            if line.strip().startswith("> ")]
    return rows[0] if len(rows) == 1 else None


def main():
    binary = pathlib.Path(sys.argv[1]).resolve(strict=True)
    output = pathlib.Path(sys.argv[2]).resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.umask(0o077)
    fixture = Fixture(binary, output)
    try:
        fixture.start()
        with defer_signals():
            fixture.tty = DirectPty([str(binary), "--store", str(fixture.store)],
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
        tty.draft("draft", 5)
        tty.send(b"\x7f" * 5)
        tty.draft("", 0)
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
            tty.send(b"\r")
        tty.marker("Model default saved")
        preferences = (fixture.home / ".config/rui/preferences").read_text()
        assert f"model={chosen}\n" in preferences, "saved identity differs from selected row"
        assert "provider=" in preferences, "saved provider missing"
        tty.send(b"\x1b\r")  # Alt-Enter opens fixture's existing Session.
        tty.marker(f"Session {fixture.session}")
        tty.send(b"/model\r")
        tty.marker("new Session: /model in overview")
        assert "gpt-6-luna" in tty.screen.completed, "Session fixed model not reported"
        assert (fixture.home / ".config/rui/preferences").read_text() == preferences, "Session /model changed defaults"
        tty.send(b"\x11")
        tty.finish()
        (output / "result.txt").write_text("picker journey passed; local stub only\n")
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
