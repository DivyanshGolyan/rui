"""Two-line overview rows, pinned Settings and one Footer through a real PTY.

The historical counts group now checks the replacement presentation; archive
views remain reachable through /sessions without a clickable counts row.
"""
from contextlib import contextmanager
import json
import os
import re
import signal
import threading

import model_fixture as fixture
from overview_fixture import world


def answer(name):
    return fixture.sse_answer(name, f"{name}-r", f"{name}-m", f"{name} done")[0]


def send(w, session, text):
    w.run("session", "send", "--store", w.store, "--to", session, input=text)


@contextmanager
def released(*holds):
    try:
        yield
    finally:
        for held in holds:
            held.set()


def rows_by_mark():
    holds = {name: threading.Event() for name in ("w1", "w2", "q1")}
    ask = fixture.sse_tool_calls("ask-calls", [("bash", "ask-call", json.dumps(
        {"cmd": "true", "timeout_ms": None, "description": "Run ask"}, separators=(",", ":")))])
    responses = {"ask": ask, "fail": b"data: {malformed\n\ndata: [DONE]\n\n",
                 **{name: (answer(name), held) for name, held in holds.items()}}
    with world("drawing-marks", responses, active_capacity=2) as w, released(*holds.values()):
        with w.overview(columns=99, rows=30) as screen:
            frame = screen.contains("+ New Session")
            assert frame.split("\n")[0] == "  + New Session", frame
            asking = w.session("--label", "Asking", "--tools", "bash", "--permission-mode", "ask")
            failing = w.session("--label", "Failing")
            send(w, asking, "ask")
            send(w, failing, "fail")
            screen.wait(lambda f: "? Asking" in f and "× Failing" in f, "approval and failure rows")
            for name in ("w1", "w2"):
                send(w, w.session("--label", name), name)
            screen.wait(lambda f: "w1" in f and "w2" in f, "working rows")
            send(w, w.session("--label", "q1"), "q1")
            frame = screen.contains("◌ q1")
            lines = frame.split("\n")
            queued = next(i for i, line in enumerate(lines) if "◌ q1" in line)
            assert lines[queued].strip() == "◌ q1", frame
            assert lines[queued + 1].startswith("   Queued"), frame
            assert lines[queued + 1].rstrip().endswith("workspace"), frame
            assert "slots " not in frame and not re.search(r"rui \d+ MB", frame), frame
            assert screen.style("? Asking").fg != screen.style("× Failing").fg, frame
            holds["w1"].set()
            screen.wait(lambda f: "✓ w1" in f and "◌ q1" not in f, "queue admission")
            for held in holds.values():
                held.set()
            screen.contains("✓ q1")
    print("overview drawing: two-line state rows replace counts and slots", flush=True)


def view_name():
    with world("drawing-view", {"talk": answer("talk")}) as w:
        session = w.session("--label", "Talk")
        send(w, session, "talk")
        with w.overview(columns=99) as screen:
            screen.contains("✓ Talk")
            for view in ("archived", "all", "unarchived"):
                screen.keys(f"/sessions {view}".encode())
                screen.contains(f"/sessions {view}")
                screen.keys(b"\r")
                frame = screen.wait(lambda f, view=view: "/sessions" not in f and ("✓ Talk" in f) == (view != "archived"), view)
                assert frame.split("\n")[0] == "  + New Session", frame
                assert "Settings" in frame, frame
    print("overview drawing: /sessions reaches archive views without a view-name row", flush=True)


def pinned_settings():
    with world("drawing-settings") as w, w.overview(columns=46, rows=16) as screen:
        frame = screen.contains("Settings")
        rows = frame.split("\n")
        settings = next(i for i, line in enumerate(rows) if "Settings" in line)
        composer = next(i for i, line in enumerate(rows) if "› Type a task" in line)
        assert settings == composer - 2, frame
        assert re.fullmatch(r"─+", rows[settings - 1]), frame
        assert rows[-1].rstrip().endswith("enter start"), frame
        screen.keys(b"\x1b[F")
        screen.wait(lambda f: f.split("\n")[-1].rstrip().endswith("enter open"), "Settings selected")
        # The stub is a no-op; clicking it must not open a Session or move it.
        screen.click(4, settings + 1)
        screen.keys("draft")
        frame = screen.contains("› draft")
        assert frame.split("\n")[settings].lstrip().startswith("Settings"), frame
        assert frame.split("\n")[-1].rstrip().endswith("enter start"), frame
    print("overview drawing: Settings stays above the composer and one Footer keeps the keys", flush=True)


def requests(w):
    return {path.stem for path in (w.home / ".config/rui/requests").glob("*.json")}


def unconfirmed_status():
    """A send the conversation could not confirm shows, back in the overview,
    on the status row under the input with its saved request's recover key.
    The Host is stopped (SIGSTOP) while the send uploads, so the send's own
    inactivity deadline leaves it unconfirmed."""
    with world("counts-unconfirmed", {"first": answer("first"), "lost": answer("lost")}) as w:
        session = w.session("--label", "Talk")
        send(w, session, "first")
        with w.overview() as screen:
            frame = screen.contains("✓ Talk")
            assert "Not confirmed" not in frame, frame
            screen.keys(b"\r")
            screen.wait(lambda f: "first done" in f and "Talk ·" in f, "the conversation")
            before = requests(w)
            os.kill(w.host.pid, signal.SIGSTOP)
            try:
                screen.keys(b"lost")
                screen.contains("lost")
                screen.keys(b"\r")
                screen.contains("! Not confirmed · ctrl+r retries original", timeout=30)
            finally:
                os.kill(w.host.pid, signal.SIGCONT)
            saved = requests(w) - before
            assert len(saved) == 1, (before, saved)
            key = saved.pop()
            screen.keys(b"\x1b")
            line = f"! Not confirmed · rui request recover {key}"
            frame = screen.wait(lambda f: line in f and "Type a task" in f and "enter open" in f, line)
            rows = screen.rows()
            status = next(at for at, row in enumerate(rows) if line in row)
            composer = next(at for at, row in enumerate(rows) if "› Type a task" in row)
            assert status > composer, frame
            # The whole handle on its own row, the one Footer under it.
            assert rows[status].strip() == line, frame
            assert rows[status + 1].rstrip().endswith("enter open"), frame
            assert screen.style("! Not confirmed").fg is not None, frame
    print("overview counts: an unconfirmed send shows on its own row above the Footer with "
          "rui request recover and its saved key", flush=True)


def cases():
    rows_by_mark()
    view_name()
    unconfirmed_status()
    pinned_settings()
