"""Overview groups cases; run by overview_integration.py, built on overview_fixture.py.

Each case drives a real Host into a work state, opens bare `rui` on a PTY
and reads the rows as the terminal shows them: the group headings, each
row's mark and its colour, the detail column and the age.
"""
import json
import pathlib
import re
import shlex
import threading

import model_fixture as fixture
from overview_fixture import world

PEER_PREFIX = (pathlib.Path(__file__).resolve().parents[2] / "src" / "peer_message.txt").read_text().split("{}", 1)[0]


class Replies(dict):
    """Model replies by a Message's text, each key a list served in turn and
    its last reply repeated: a tool call first, then the answer after its
    result. A peer's Message reads as its sender header, so every key
    starting with that header shares the "peer" entry."""

    def __getitem__(self, text):
        key = "peer" if text.startswith(PEER_PREFIX) else text
        replies = dict.__getitem__(self, key)
        return replies.pop(0) if len(replies) > 1 else replies[0]


def answer(text):
    return fixture.sse_answer(f"answer-{len(text)}", "reason", "message", text)[0]


def send(w, session, text):
    w.run("session", "send", "--store", w.store, "--to", session, input=text)


def wait_state(w, session, kind):
    fixture.wait_for(lambda: w.inspect(session)["work"]["state"]["kind"] == kind, f"{session} {kind}", timeout=15)


def row(frame, title):
    """The one frame row that shows `title`."""
    rows = [line for line in frame.split("\n") if title in line]
    assert len(rows) == 1, (title, frame)
    return rows[0]


def cells(screen, title):
    """The drawn cells of the row showing `title` in the latest frame."""
    for line in screen.capture.completed_cells:
        if title in "".join(cell.data for cell in line):
            return [cell for cell in line if cell.data]
    raise AssertionError(("no row", title, screen.text))


def needs_you():
    """A Session waiting on an Action leads, marked `?` in the attention
    colour, selected, its detail the waiting command's first line."""
    bash = json.dumps({"cmd": "echo first line of the command\necho second line", "timeout_ms": None,
                       "description": "Print two lines"})
    with world("groups-needs", {
        "please run the command": fixture.sse_tool_calls("ask", [("bash", "call-ask", bash)]),
        "just say hi": answer("hi"),
    }) as w:
        done = w.session("--label", "Answered already")
        send(w, done, "just say hi")
        wait_state(w, done, "finished")
        asking = w.session("--permission-mode", "ask", "--label", "Asks before running")
        send(w, asking, "please run the command")
        wait_state(w, asking, "approval")
        # Detail/row contracts use the full-screen list below the split threshold.
        with w.overview(columns=99, rows=20) as screen:
            frame = screen.contains("echo first line of the command")
            lines = frame.split("\n")
            headings = [line for line in lines if re.fullmatch(r" \S.* · \d+", line)]
            assert headings == [" Needs you · 1", " Yours · 1"], frame
            assert lines[1] == " Needs you · 1", frame
            asked = row(frame, "Asks before running")
            assert re.fullmatch(r"  \? Asks before running {2,}echo first line of the command {2,}\d+s", asked), asked
            assert len(asked) == 98, asked
            assert "second line" not in frame, frame
            assert lines.index(asked) == 2, frame
            assert re.fullmatch(r"  ✓ Answered already {2,}\d+s", row(frame, "Answered already")), frame
            mark = cells(screen, "Asks before running")[2]
            ordinary = cells(screen, "Answered already")[2]
            assert (mark.data, ordinary.data) == ("?", "✓"), (mark, ordinary)
            assert mark.fg is not None and mark.fg != ordinary.fg, (mark, ordinary)
            # The counts line's `? 1` is drawn in the attention colour too.
            assert mark.fg == screen.style("? 1").fg, (mark, screen.style("? 1"), frame)
            # The list opens on the waiting row: Enter opens that Session.
            screen.keys(b"\r")
            # Its conversation's status line names it; the card may fill
            # the view before its Message row shows.
            opened = screen.contains("Asks before running · gpt-6-luna")
            assert "Answered already" not in opened, opened
    print("overview groups: an Action's wait leads in Needs you, `?` in the attention colour, selected, with its command's first line", flush=True)


def queued_in_active():
    """A peer's Message waiting for a model slot shows a dim `◌` in Active,
    after the working row; no Queued group shows."""
    hold = threading.Event()
    replies = Replies({"dispatch two Messages": [None, answer("dispatched")],
                       "peer": [(answer("worked"), hold)]})
    with world("groups-queued", replies, active_capacity=1) as w:
        first = w.session("--label", "First peer task")
        second = w.session("--label", "Second peer task")
        dispatcher = w.session("--label", "Dispatcher")
        rui = shlex.quote(str(fixture.RUI))
        command = (f"printf 'first task' | {rui} session send --to {first} && "
                   f"printf 'second task' | {rui} session send --to {second}")
        dict.__getitem__(replies, "dispatch two Messages")[0] = fixture.sse_tool_calls("dispatch", [
            ("bash", "call-dispatch", json.dumps({"cmd": command, "timeout_ms": 20000, "description": "Dispatch"}))])
        try:
            send(w, dispatcher, "dispatch two Messages")
            wait_state(w, dispatcher, "finished")
            wait_state(w, first, "working")
            wait_state(w, second, "pending")
            with w.overview(columns=99, rows=20) as screen:
                frame = screen.wait(lambda shown: "Second peer task" in shown and "First peer task" in shown,
                                    "both peer rows")
                lines = frame.split("\n")
                headings = [line for line in lines if re.fullmatch(r" \S.* · \d+", line)]
                assert headings == [" Yours · 1", " Active · 2"], frame
                assert "Queued" not in frame, frame
                working = row(frame, "First peer task")
                queued = row(frame, "Second peer task")
                assert re.fullmatch(r"  ⠹ First peer task {2,}\d+s", working), working
                assert re.fullmatch(r"  ◌ Second peer task {2,}\d+s", queued), queued
                active = lines.index(" Active · 2")
                assert lines[active + 1:active + 3] == [working, queued], frame
                drawn = cells(screen, "Second peer task")
                queued_mark, age = drawn[2], [cell for cell in drawn if cell.data != " "][-1]
                assert age.data == "s", drawn
                working_mark = cells(screen, "First peer task")[2]
                # Dim: the queued mark takes the age's quiet colour, not the
                # working mark's ink.
                assert queued_mark.data == "◌" and queued_mark.fg == age.fg, (queued_mark, age)
                assert queued_mark.fg != working_mark.fg, (queued_mark, working_mark)
        finally:
            hold.set()
    print("overview groups: a queued peer row shows a dim `◌` in Active after the working row, with no Queued group", flush=True)


def detail_column():
    """A rate-limited row counts down to its retry; a failed row names its
    cause and nobody who started it."""
    limited = fixture.ResponseSpec(b'{"error":{"message":"slow down"}}', {"Retry-After": "40"}, status=429)
    failing = fixture.ResponseSpec(b'{"error":{"message":"unavailable"}}', {}, status=503)
    with world("groups-detail", {"rate limit me": limited, "fail every time": failing}) as w:
        failed = w.session("--label", "Fails every time")
        send(w, failed, "fail every time")
        wait_state(w, failed, "failed")
        code = w.inspect(failed)["work"]["state"]
        retrying = w.session("--label", "Rate limited task")
        send(w, retrying, "rate limit me")
        wait_state(w, retrying, "retrying")
        with w.overview(columns=99, rows=20) as screen:
            frame = screen.wait(lambda shown: "retry in" in shown and "Fails every time" in shown,
                                "the retry countdown and the failed row")
            shown = row(frame, "Rate limited task")
            match = re.fullmatch(r"  ⠹ Rate limited task {2,}Rate limited · retry in (\d+)s {2,}\d+s", shown)
            assert match and 0 < int(match[1]) <= 41, (shown, frame)
            failure = row(frame, "Fails every time")
            assert re.fullmatch(r"  × Fails every time {2,}Retries ran out {2,}\d+s", failure), (failure, code)
            assert "you" not in failure.lower(), failure
            failed_mark = cells(screen, "Fails every time")[2]
            assert failed_mark.fg == screen.style("Retries ran out").fg, frame
            # The countdown asks for attention; the failure keeps its colour.
            assert cells(screen, "Rate limited task")[2].fg == screen.style("Rate limited ·").fg, frame
    print("overview groups: a rate-limited row reads `Rate limited · retry in Ns`; a failed row names its cause only", flush=True)


def narrow():
    """At 40 columns a row keeps its mark, title and age."""
    with world("groups-narrow", {"short one": answer("ok"), "long one": answer("ok")}) as w:
        short = w.session("--label", "Narrow title")
        send(w, short, "short one")
        wait_state(w, short, "finished")
        long = w.session("--label", "A much longer title that cannot fit here")
        send(w, long, "long one")
        wait_state(w, long, "finished")
        with w.overview(columns=40, rows=16) as screen:
            frame = screen.wait(lambda shown: "Narrow title" in shown and "A much" in shown, "both narrow rows")
            fits = row(frame, "Narrow title")
            assert re.fullmatch(r"  ✓ Narrow title {2,}\d+s", fits) and len(fits) == 39, (fits, frame)
            cut = row(frame, "A much")
            # The title keeps 29 cells, its last an ellipsis; the age keeps its own.
            assert re.fullmatch(r"  ✓ A much longer title that can… +\d+s", cut) and len(cut) == 39, (cut, frame)
    print("overview groups: at 40 columns a row keeps its mark, title and age, a long title cut short", flush=True)


def cases():
    needs_you()
    queued_in_active()
    detail_column()
    narrow()
