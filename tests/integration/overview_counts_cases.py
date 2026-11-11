"""Overview counts cases; run by overview_integration.py, built on overview_fixture.py.

The counts line (the screen's top row) and the status row under the input,
as a real terminal shows them. Rules: src/overview_view.zig countsLine,
statusLine and unconfirmedLine.
"""
from contextlib import contextmanager
import json
import os
import re
import signal
import threading

import model_fixture as fixture
from overview_fixture import world
from terminal_process import ROWS

# The test terminal is not one theme.wordmark trusts with Devanagari, so
# the counts line names rui alone.
WORDMARK = " rui"
# Live memory on the right of the counts line: `rui 42 MB` or
# `rui 42 MB · tools 1.8 GB` (sizeText: whole MB, or GB to a tenth).
SIZE = r"\d+(?:\.\d)? [MG]B"
MEMORY = re.compile(rf"rui {SIZE}(?: · tools {SIZE})?")


def top(frame):
    return frame.split("\n", 1)[0]


def counts(frame):
    """The counts line's left side: the wordmark and the counts, without the
    memory a later build may draw on the right."""
    return re.sub(rf"\s{{2,}}{MEMORY.pattern}\s*$", "", top(frame)).rstrip()


def answer(name):
    return fixture.sse_answer(name, f"{name}-r", f"{name}-m", f"{name} done")[0]


def send(w, session, text):
    w.run("session", "send", "--store", w.store, "--to", session, input=text)


@contextmanager
def released(*holds):
    """Releases every held reply on the way out, before the endpoint closes."""
    try:
        yield
    finally:
        for held in holds:
            held.set()


def top_style(screen, frame, text):
    assert text in top(frame), (text, frame)
    return screen.style(text)


def counts_by_mark():
    """? needs you, ⠹ works, ◌ queues, × failed; zeros left out; slots only
    while something queues; only ? and × coloured."""
    holds = {name: threading.Event() for name in ("w1", "w2", "q1")}
    ask = fixture.sse_tool_calls("ask-calls", [("bash", "ask-call", json.dumps(
        {"cmd": "true", "timeout_ms": None, "description": "Run ask"}, separators=(",", ":")))])
    responses = {"ask": ask, "fail": b"data: {malformed\n\ndata: [DONE]\n\n",
                 **{name: (answer(name), held) for name, held in holds.items()}}
    with world("counts-marks", responses, active_capacity=2) as w, released(*holds.values()):
        with w.overview() as screen:
            frame = screen.contains("+ New Session")
            assert counts(frame) == WORDMARK, frame

            asking = w.session("--label", "Asking", "--tools", "bash", "--permission-mode", "ask")
            failing = w.session("--label", "Failing")
            send(w, asking, "ask")
            send(w, failing, "fail")
            frame = screen.wait(lambda f: counts(f) == f"{WORDMARK}  ? 1  × 1", "? 1  × 1")
            assert "? Asking" in frame and "× Failing" in frame, frame

            for name in ("w1", "w2"):
                send(w, w.session("--label", name), name)
            # Both slots in use but nothing waits for one: no slots.
            frame = screen.wait(lambda f: counts(f) == f"{WORDMARK}  ? 1  ⠹ 2  × 1", "? 1  ⠹ 2  × 1")
            assert "slots" not in top(frame), frame

            queued = w.session("--label", "q1")
            send(w, queued, "q1")
            frame = screen.wait(lambda f: counts(f) == f"{WORDMARK}  ? 1  ⠹ 2  ◌ 1 · slots 2/2  × 1",
                                "? 1  ⠹ 2  ◌ 1 · slots 2/2  × 1")
            assert "◌ q1" in frame, frame

            # Only needs you and failures take a colour; working, queued
            # and the slots draw in one ink, every count in its mark's.
            needs, failed = (top_style(screen, frame, text) for text in ("? 1", "× 1"))
            plain = [top_style(screen, frame, text) for text in ("⠹ 2", "◌ 1", "slots 2/2")]
            assert len({cell.fg for cell in plain}) == 1, (plain, frame)
            ink = plain[0].fg
            assert needs.fg not in (None, ink) and failed.fg not in (None, ink), (needs, failed, ink, frame)
            assert needs.fg != failed.fg, (needs, failed, frame)
            for text in ("? 1", "⠹ 2", "◌ 1", "× 1"):
                assert screen.style(text, 2).fg == screen.style(text).fg, (text, frame)

            # A slot frees, the queued Session takes it: the slots go.
            # (Your own working row's mark spins, so read q1's row as
            # neither queued nor finished.)
            holds["w1"].set()
            frame = screen.wait(lambda f: counts(f) == f"{WORDMARK}  ? 1  ⠹ 2  × 1" and "✓ w1" in f
                                and not re.search(r"[◌✓] q1", f), "q1 running, slots gone")
            for held in holds.values():
                held.set()
            frame = screen.wait(lambda f: counts(f) == f"{WORDMARK}  ? 1  × 1" and "✓ q1" in f,
                                "only ? and × left")
    print("overview counts: the top row counts ? ⠹ ◌ × by mark, leaves zeros out, shows slots 2/2 only "
          "while a Session queues, and colours only ? and ×", flush=True)


def view_name():
    """`Archived` and `All` name the view on the right only off the default."""
    with world("counts-view", {"talk": answer("talk")}) as w:
        session = w.session("--label", "Talk")
        send(w, session, "talk")
        names = ("Unarchived", "Archived", "All")
        with w.overview() as screen:
            frame = screen.contains("✓ Talk")
            assert not any(name in top(frame) for name in names), frame
            for view, name in (("archived", "Archived"), ("all", "All")):
                screen.keys(f"/sessions {view}".encode())
                screen.contains(f"/sessions {view}")
                screen.keys(b"\r")
                # The wordmark, no counts (nothing works, queues or failed),
                # and the view's name on the right, after live memory.
                frame = screen.wait(lambda f, name=name, view=view: re.fullmatch(rf"{WORDMARK}(?: {{2,}}{MEMORY.pattern})? {{2,}}{name}", top(f).rstrip())
                                    and (view != "all" or "✓ Talk" in f), name)
                assert ("Talk" in frame) == (view == "all"), frame
            screen.keys(b"/sessions unarchived")
            screen.contains("/sessions unarchived")
            screen.keys(b"\r")
            frame = screen.wait(lambda f: not top(f).rstrip().endswith("  All") and "✓ Talk" in f, "default view")
            assert not any(name in top(frame) for name in names), frame
            assert counts(frame) == WORDMARK, frame
    print("overview counts: Archived and All show on the counts line only off the default view", flush=True)


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
            frame = screen.wait(lambda f: line in f and "Type a task" in f, line)
            rows = screen.rows()
            status = next(at for at, row in enumerate(rows) if line in row)
            composer = next(at for at, row in enumerate(rows) if "› Type a task" in row)
            assert status > composer, frame
            assert rows[status].strip() == line, frame
            assert "↑↓ select" not in frame, frame
            assert screen.style("! Not confirmed").fg is not None, frame
    print("overview counts: an unconfirmed send shows on the status row under the input with "
          "rui request recover and its saved key", flush=True)


def memory():
    """Live memory on the right of the counts line, `rui N MB`; on a narrow
    screen it drops before the counts do."""
    hold = threading.Event()
    with world("counts-memory", {"work": (answer("work"), hold)}) as w, released(hold):
        send(w, w.session("--label", "Work"), "work")
        with w.overview(columns=99) as screen:
            screen.wait(lambda f: counts(f) == f"{WORDMARK}  ⠹ 1", "⠹ 1")
            frame = screen.wait(lambda f: re.search(rf"  {MEMORY.pattern}$", top(f).rstrip()), "rui N MB on the right")
            assert counts(frame) == f"{WORDMARK}  ⠹ 1", frame
            # The same screen narrowed: 14 columns hold the counts (9
            # cells) but not two spaces and memory too.
            screen.resize(14, ROWS)
            frame = screen.wait(lambda f: top(f).rstrip() == f"{WORDMARK}  ⠹ 1", "⠹ 1 alone")
            assert not MEMORY.search(top(frame)), frame
    print("overview counts: live memory shows as rui N MB on the right and drops before the counts "
          "on a narrow screen", flush=True)


def cases():
    counts_by_mark()
    view_name()
    unconfirmed_status()
    memory()
