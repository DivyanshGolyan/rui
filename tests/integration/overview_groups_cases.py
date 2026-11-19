import json
import pathlib
import re
import shlex
import threading

import model_fixture as fixture
from overview_fixture import world

PEER_PREFIX = (pathlib.Path(__file__).resolve().parents[2] / "src" / "peer_message.txt").read_text().split("{}", 1)[0]


class Replies(dict):

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
    rows = [line for line in frame.split("\n") if title in line]
    assert len(rows) == 1, (title, frame)
    return rows[0]


def cells(screen, title):
    for line in screen.capture.completed_cells:
        if title in "".join(cell.data for cell in line):
            return [cell for cell in line if cell.data]
    raise AssertionError(("no row", title, screen.text))


def needs_you():
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
        with w.overview(columns=99, rows=20) as screen:
            frame = screen.contains("Asks before running")
            lines = frame.split("\n")
            headings = [line for line in lines if re.fullmatch(r"   \S.* · \d+", line)]
            assert headings == [], frame
            asked = row(frame, "Asks before running")
            assert re.fullmatch(r"   ● Asks before running {2,}now", asked), asked
            assert len(asked) == 96, asked
            assert "second line" not in frame, frame
            assert lines.index(asked) < lines.index(row(frame, "Answered already")), frame
            assert "echo first line" not in frame and "workspace" not in frame, frame
            assert re.fullmatch(r"     Answered already {2,}now", row(frame, "Answered already")), frame
            mark = cells(screen, "Asks before running")[3]
            ordinary = cells(screen, "Answered already")[5]
            assert mark.data == "●" and cells(screen, "Answered already")[3].data == " ", (mark, ordinary)
            assert mark.fg is not None and mark.fg != ordinary.fg, (mark, ordinary)
            assert screen.style("Asks before running").bold, frame
            screen.keys(b"\r")
            opened = screen.contains("Asks before running · gpt-6-luna")
            assert "Answered already" not in opened, opened
    print("overview groups: an Action's wait leads the flat list, `●` in the attention colour, selected, with minute-scale state age", flush=True)


def queued_in_active():
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
                headings = [line for line in lines if re.fullmatch(r"   \S.* · \d+", line)]
                assert headings == [], frame
                assert "Queued" not in frame, frame
                working = row(frame, "First peer task")
                queued = row(frame, "Second peer task")
                assert re.fullmatch(r"   [◜◝◞◟] First peer task *", working), working
                assert re.fullmatch(r"   ◌ Second peer task +now", queued), queued
                done = row(frame, "Dispatcher")
                assert lines.index(working) < lines.index(done) < lines.index(queued), frame
                drawn = cells(screen, "Second peer task")
                queued_mark = drawn[3]
                working_mark = cells(screen, "First peer task")[3]
                assert queued_mark.data == "◌", queued_mark
                assert re.fullmatch(r"   ◌ Second peer task +now", queued), frame
                assert queued_mark.fg != working_mark.fg, frame
        finally:
            hold.set()
    print("overview groups: a queued peer row shows a dim `◌` after working and done rows, with no headings", flush=True)


def detail_column():
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
            frame = screen.wait(lambda shown: "Rate limited task" in shown and "Fails every time" in shown,
                                "the retrying and failed rows")
            shown = row(frame, "Rate limited task")
            assert re.fullmatch(r"   ◝ Rate limited task +retrying", shown), shown
            assert "retry in" not in frame and "workspace" not in frame, frame
            failure = row(frame, "Fails every time")
            assert re.fullmatch(r"   × Fails every time {2,}now", failure), (failure, code)
            assert "you" not in failure.lower(), failure
            assert "Retries ran out" not in frame, frame
            failed_mark = cells(screen, "Fails every time")[3]
            assert failed_mark.fg != cells(screen, "Rate limited task")[3].fg, frame
    print("overview groups: retrying omits age and failed rows show minute-scale state age with no detail line", flush=True)


def narrow():
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
            assert re.fullmatch(r"     Narrow title {2,}now", fits) and len(fits) == 37, (fits, frame)
            cut = row(frame, "A much")
            match = re.fullmatch(r"     (.+) +(now)", cut)
            assert match and len(cut) == 37, (cut, frame)
            room = 40 - 7 - len(match[2]) - 2
            assert match[1].rstrip() == "A much longer title that cannot fit here"[:room - 1] + "…", cut
            assert "workspace" not in frame, frame

    print("overview groups: at 40 columns a row keeps its mark, title and age, a long title cut short", flush=True)


def cases():
    needs_you()
    queued_in_active()
    detail_column()
    narrow()
