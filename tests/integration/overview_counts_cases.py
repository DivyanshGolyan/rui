from contextlib import contextmanager
import json
import os
import re
import signal
import threading

import model_fixture as fixture
from overview_fixture import world
from human_cli_fixture import conversation_text, composer_line, chat_footer_row


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
            assert frame.split("\n")[0] == " + New Session", frame
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
            assert re.fullmatch(r"◌ q1 +now", lines[queued].strip()), frame
            assert "Queued" not in frame and "workspace" not in frame, frame
            assert "slots " not in frame, frame
            for line in lines:
                if not line.startswith("   Settings"):
                    assert not re.search(r"(?:rui|tools) \d+(?:\.\d+)? (?:MB|GB)\b", line), frame
            assert screen.style("? Asking").fg != screen.style("× Failing").fg, frame
            holds["w1"].set()
            screen.wait(lambda f: "   w1" in f and "◌ q1" not in f, "queue admission")
            for held in holds.values():
                held.set()
            screen.contains("   q1")
    print("overview drawing: one-line state rows replace counts and slots", flush=True)


def pinned_settings():
    with world("drawing-settings") as w, w.overview(columns=46, rows=16) as screen:
        frame = screen.contains("Settings")
        rows = frame.split("\n")
        settings = next(i for i, line in enumerate(rows) if "Settings" in line)
        assert settings == len(rows) - 3, frame
        assert set(rows[settings - 1].strip()) <= {"─", "-"} and rows[settings - 1].strip(), frame
        assert re.search(r"0\.\d+\.\d+|unreleased", rows[settings + 1]), frame
        assert "rui " not in rows[settings + 1] and "tools " not in rows[settings + 1], frame
        assert "enter open" not in frame, frame
        assert "Type a task" not in frame and "gpt-6-luna" not in frame, frame
        before = requests(w)
        screen.keys(b"/nope\x1b[200~pasted task\x1b[201~\x1b[F\r")
        screen.contains("Notifications")
        screen.keys(b"\x1b")
        frame = screen.wait(lambda f: "Settings" in f and "Notifications" not in f, "return to list")
        assert frame.split("\n")[settings].lstrip().startswith("Settings"), frame
        assert "Type a task" not in frame and "/nope" not in frame and "pasted task" not in frame, frame
        assert "Unknown command" not in frame and requests(w) == before, frame
        assert json.loads(w.run("session", "list", "--store", w.store, "--all"))["sessions"] == [], frame
    print("overview drawing: Settings sits above memory/version and one Footer; text and paste create no draft or request", flush=True)


def requests(w):
    return {path.stem for path in (w.home / ".config/rui/requests").glob("*.json")}


def unconfirmed_status():
    with world("counts-unconfirmed", {"first": answer("first"), "lost": answer("lost")}) as w:
        session = w.session("--label", "Talk")
        send(w, session, "first")
        with w.overview() as screen:
            frame = screen.contains("   Talk")
            assert "Not confirmed" not in frame, frame
            screen.keys(b"\r")
            screen.wait(lambda f: "first done" in f and "Talk ·" in f, "the conversation")
            before = requests(w)
            os.kill(w.host.pid, signal.SIGSTOP)
            try:
                screen.keys(b"lost")
                screen.contains("lost")
                screen.keys(b"\r")
                note = "Not confirmed · ctrl+r retries original"
                frame = screen.wait(lambda f: note in conversation_text(f)
                    and conversation_text(f).count("› lost") == 1,
                    "unconfirmed note attached to the original sent Message", timeout=30)
                transcript = conversation_text(frame)
                assert transcript.count(note) == 1 and transcript.index("› lost") < transcript.index(note), frame
                assert "! Not confirmed" not in frame and "Sending" not in frame, frame
                footer = chat_footer_row(frame)
                assert note not in "\n".join(composer_line(frame, index)
                    for index in range(footer, len(frame.split("\n")))), frame
            finally:
                os.kill(w.host.pid, signal.SIGCONT)
            saved = requests(w) - before
            assert len(saved) == 1, (before, saved)
            key = saved.pop()
            screen.keys(b"\x1b")
            line = f"! Not confirmed · rui request recover {key}"
            frame = screen.wait(lambda f: line in f and "Settings" in f and "Type a task" not in f, line)
            rows = screen.rows()
            status = next(at for at, row in enumerate(rows) if line in row)
            settings = next(at for at, row in enumerate(rows) if "Settings" in row)
            assert status > settings and "Type a task" not in frame, frame
            assert rows[status].strip() == line, frame
            assert "enter open" not in frame, frame
            assert screen.style("! Not confirmed").fg is not None, frame
    print("overview counts: an unconfirmed send shows on its own row above the Footer with "
          "rui request recover and its saved key", flush=True)


def cases():
    rows_by_mark()
    unconfirmed_status()
    pinned_settings()
