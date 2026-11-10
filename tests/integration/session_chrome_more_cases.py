"""More of the Session screen's chrome through a real terminal: the work
in the tail against history, /status while work runs, waiting Messages
through eviction, steering and stops, and read boundaries, catch-up pages
and drafts across reopening.

human_cli_integration.py runs these cases in its full and renderer modes,
and alone as `session-chrome-more`. They share session_chrome_cases.py's
fixture; each judges what a person sees on the screen.

Work in the tail: The Session screen's tail, last row and /status page agree with the work
they describe, through a real terminal at 80×24.

Each case judges every committed frame the person could see: a call row is
either in the tail (`• <description> · Ns`) or in history, never both; the
tail and `ctrl+x stop` go in the frame that shows the answer; an open
/status page follows the work and agrees with the stop key. Several cases
hold the Session's Activity page reads, so the work moves on unseen and the
next read must show all of it at once.

Waiting Messages: A Message that waited while work ran stays in the transcript after the
live view evicted it, judged on the Session screen through a real terminal.

While it waits, the Message shows as the `◌ [N ·] <newest first line>` row
at the transcript's tail, never called queued. Afterwards each Message is
its own `› <text>` row exactly once, in order, when the person scrolls back
through the whole transcript to `Start of conversation`.

The terminal is 80×TALL so that scrolling back through answers larger than
the live view takes tens of steps rather than hundreds: the transcript fills
rows 0 to TALL-6, the input sits between the rules on the next three rows,
then the facts row and the last row.

Reads: Reads the Session screen joins as the person scrolls and sends: a
transcript reached by scrolling back shows every Message and reply once, in
order, wherever live output and older pages meet; a send stays visible from
Enter until its Message's row shows; a draft survives scrolling and pages.

Each case judges the 80×24 screen a terminal shows, as
session_chrome_cases.py does: the transcript fills rows 0–18, the composer
sits between the rules on rows 19–21, the facts row is 22 and the last row 23."""
import json
import os
import select
import subprocess
import threading
import time

import canonical_fixture as canonical
import model_fixture as fixture
from human_cli_fixture import admit, draining, run, settle_screen, terminal_capture
from session_chrome_cases import (
    BOTTOM,
    LAST,
    Chrome,
    composing,
    frames_until,
    latest,
    marker,
    rows,
    tail_rows,
)
from terminal_process import open_pty, spawn


def finished(chrome, session):
    """The Session's Turn has ended, as the Host reports it."""
    work = fixture.command("session", "inspect", "--store", chrome.store, "--session", session)["work"]
    return work["state"]["kind"] == "finished"


# Work in the tail and /status.

STOP = "ctrl+x stop"


def transcript_rows(screen):
    return rows(screen)[:BOTTOM + 1]


def stopping(screen):
    return rows(screen)[LAST].rstrip().endswith(STOP)


def running_row(screen, label):
    return any(row.startswith(f"• {label} · ") for row in tail_rows(screen))


def work_state(screen):
    """The /status page's Work state row, when the page shows it."""
    shown = rows(screen)
    for index, row in enumerate(shown[:BOTTOM]):
        if row.rstrip() == " Work":
            return shown[index + 1].split("·")[0].strip()
    return None


def collect(master, until, timeout=20):
    """Every frame committed while waiting for `until()`, draining the PTY."""
    capture = terminal_capture(master)
    frames = []
    capture.listener = lambda screen, x, y: frames.append(screen)
    try:
        deadline = time.monotonic() + timeout
        while not until():
            assert time.monotonic() < deadline, ("collect", capture.completed)
            if select.select([master], [], [], 0.1)[0]:
                chunk = os.read(master, 65536)
                assert chunk, "terminal closed"
                capture.feed(chunk)
    finally:
        capture.listener = None
    return frames


def sleeping_call(name, label, seconds):
    return fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", json.dumps({
        "cmd": f"sleep {seconds}", "description": label, "timeout_ms": None}))])


def one_call_case():
    """While a Turn runs its calls, each call is one row: `• <description> ·
    Ns` in the tail while it runs, then its history row. No committed frame
    shows one call twice, in the tail and in history at once."""
    labels = ("List project files", "Fail with exit 127", "Fail with an excerpt")
    commands = ("sleep 0.4; ls", "sleep 0.4; exit 127", "sleep 0.4; echo excerpt >&2; exit 1")
    with Chrome("rui-chrome-once.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            fixture.sse_tool_calls("once-calls", [
                ("bash", f"once-{index}", json.dumps({"cmd": command, "description": label, "timeout_ms": None}))
                for index, (command, label) in enumerate(zip(commands, labels))]),
            fixture.sse_answer("once-done", "r", "m", "ONCE-DONE")[0],
        ]
        master, caller, _ = chrome.open(session, lambda screen: True)
        frames = frames_until(master, b"run three calls\r", lambda screen: latest(screen, "ONCE-DONE"), timeout=30)
        assert any(running_row(frame, label) for frame in frames for label in labels), frames
        for frame in frames:
            shown = transcript_rows(frame)
            for label in labels:
                assert sum(label in row for row in shown) <= 1, (label, frame)
            if any(running_row(frame, label) for label in labels):
                assert stopping(frame), ("a running call without the stop key", frame)
        done = settle_screen(master, quiet=0.5)
        for label in labels:
            history = [row for row in transcript_rows(done) if label in row]
            assert len(history) == 1 and not history[0].startswith("•"), (label, done)
        assert "•" not in "\n".join(transcript_rows(done)) and not stopping(done), done
        chrome.leave(master, caller)
    print("session chrome: a running call shows in the tail or in history, never both on one frame", flush=True)


def one_capture_case():
    """The tail and history come from one capture: a Turn that ends while the
    Session's reads wait shows its answer in the same frame that drops the
    call's tail row and the stop key, and its history row with them."""
    label = "Wait for the capture"
    with Chrome("rui-chrome-capture.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            sleeping_call("capture", label, 1),
            fixture.sse_answer("capture-done", "r", "m", "CAPTURE-DONE")[0],
        ]
        master, caller, _ = chrome.open(session, lambda screen: True)
        proxy, holding, _, release = hold_reads(chrome)
        try:
            os.write(master, b"wait for the capture\r")
            chrome.frame(master, b"", lambda screen: running_row(screen, label) and stopping(screen))
            holding.set()
            frames = collect(master, lambda: finished(chrome, session))
            stale = terminal_capture(master).completed
            # The work ended unseen: the screen still shows it running.
            assert running_row(stale, label) and "CAPTURE-DONE" not in stale, stale
            release.set()
            frames += frames_until(master, b"", lambda screen: "CAPTURE-DONE" in screen, timeout=20)
            for frame in frames:
                shown = "\n".join(transcript_rows(frame))
                if "CAPTURE-DONE" in shown:
                    assert "•" not in shown and not stopping(frame), ("answer beside the tail", frame)
                    assert f"✓ {label}" in shown, ("answer without its call", frame)
                else:
                    assert running_row(frame, label) and stopping(frame), ("tail gone before the answer", frame)
                    assert f"✓ {label}" not in shown, frame
        finally:
            release.set()
            proxy.close()
        chrome.leave(master, caller)
    print("session chrome: a Turn ended unseen shows its answer, its history row and no tail in one frame", flush=True)


def status_opens_case():
    """/status opens from the capture the screen shows: when the work ended
    while the reads waited, the page that opens never carries the stop key
    of the work the Session still showed, and its Work says Finished."""
    label = "Wait to open status"
    with Chrome("rui-chrome-status-open.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            sleeping_call("status-open", label, 1),
            fixture.sse_answer("status-open-done", "r", "m", "STATUS-OPEN-DONE")[0],
        ]
        master, caller, _ = chrome.open(session, lambda screen: True)
        proxy, holding, _, release = hold_reads(chrome)
        try:
            os.write(master, b"wait to open status\r")
            chrome.frame(master, b"", lambda screen: running_row(screen, label) and stopping(screen))
            holding.set()
            collect(master, lambda: finished(chrome, session))
            os.write(master, b"/status\r")
            ends = time.monotonic() + 1
            frames = collect(master, lambda: time.monotonic() > ends)
            release.set()
            frames += frames_until(master, b"", lambda screen: rows(screen)[0].strip() == f"Status · {session}", timeout=20)
            for frame in frames:
                if rows(frame)[0].strip() == f"Status · {session}":
                    assert not stopping(frame), ("page opened with the stale stop key", frame)
            bottom = chrome.frame(master, b"\x1b[6~", lambda screen: work_state(screen) is not None)
            assert work_state(bottom) == "Finished" and not stopping(bottom), bottom
        finally:
            release.set()
            proxy.close()
        back = chrome.frame(master, b"\x1b", lambda screen: latest(screen, "STATUS-OPEN-DONE"))
        assert "•" not in "\n".join(transcript_rows(back)) and not stopping(back), back
        chrome.leave(master, caller)
    print("session chrome: /status opened after unseen work ends reads Finished, without ctrl+x stop", flush=True)


def status_follows_case():
    """/status opened while a call runs says the work is under way, with the
    stop key on the last row; when the work ends the open page says Finished
    and the stop key goes in the same frame, with no second /status. Esc
    returns to the latest: the answer, no tail."""
    release = threading.Event()
    with Chrome("rui-chrome-status-follows.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            (fixture.ResponseSpec(chrome.held_call("Held call", "release"), {}), release),
            fixture.sse_answer("follows-done", "r", "m", "FOLLOWS-DONE")[0],
        ]
        master, caller, _ = chrome.open(session, lambda screen: True)
        try:
            os.write(master, b"HOLD-QUESTION\r")
            release.set()
            chrome.frame(master, b"", lambda screen: running_row(screen, "Held call") and stopping(screen))
            opened = chrome.frame(master, b"/status\r", lambda screen: rows(screen)[0].strip() == f"Status · {session}")
            assert stopping(opened) and composing(opened, ""), opened
            working = chrome.frame(master, b"\x1b[6~", lambda screen: work_state(screen) is not None)
            assert work_state(working) not in (None, "Finished", "Idle") and stopping(working), working
            (chrome.workspace / "release").write_text("")
            frames = frames_until(master, b"", lambda screen: work_state(screen) == "Finished", timeout=30)
            for frame in frames:
                state = work_state(frame)
                assert state is not None, ("the page closed or moved", frame)
                assert stopping(frame) == (state != "Finished"), ("page and stop key disagree", frame)
            back = chrome.frame(master, b"\x1b", lambda screen: latest(screen, "FOLLOWS-DONE"))
            assert "•" not in "\n".join(transcript_rows(back)) and "✓ Held call" in back and not stopping(back), back
            chrome.leave(master, caller)
        finally:
            release.set()
            (chrome.workspace / "release").write_text("")
    print("session chrome: an open /status follows the work to Finished with the stop key; Esc returns with no tail", flush=True)


def compact_now(screen):
    found = [row for row in transcript_rows(screen) if row.strip().startswith("Compact at")]
    if not found or " · now " not in found[0]:
        return None
    return found[0].split(" · now ")[1].split()[0]


def status_in_place_case():
    """An open /status page updates in place: a Message answered elsewhere
    changes `Compact at … · now N` on the page the person is reading, which
    stays where they scrolled it, with the draft kept and `↓ N new` saying
    the transcript has more."""
    answer = fixture.sse_answer("big", "r", "m", "BIG-ANSWER")[0].replace(
        b'"input_tokens":7,"output_tokens":11,"total_tokens":18', b'"input_tokens":12000,"output_tokens":345,"total_tokens":12345')
    assert b"12345" in answer
    with Chrome("rui-chrome-status-place.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [fixture.sse_answer("seed", "r", "m", "SEED-ANSWER")[0], answer]
        chrome.answered(session, "seed")
        master, caller, _ = chrome.open(session, lambda screen: "SEED-ANSWER" in screen)
        chrome.frame(master, b"/status\r", lambda screen: rows(screen)[0].strip() == f"Status · {session}")
        os.write(master, b"\x1b[1;2B\x1b[1;2B")
        scrolled = settle_screen(master, quiet=0.5)
        before = compact_now(scrolled)
        assert before is not None and rows(scrolled)[0].strip() != f"Status · {session}", scrolled
        os.write(master, b"kept")
        scrolled = chrome.frame(master, b"", lambda screen: composing(screen, "kept"))
        admit(chrome.home, "session", "send", "--to", session, input="answered elsewhere")

        def counted(screen):
            now = (compact_now(screen) or "").replace(",", "")
            return now.isdigit() and int(now) > 10000
        frames = frames_until(master, b"", counted, timeout=20)
        # The same page, where the person left it, in every frame.
        for frame in frames:
            assert rows(frame)[0] == rows(scrolled)[0] and composing(frame, "kept"), (scrolled, frame)
            assert "BIG-ANSWER" not in frame, frame
        assert before != compact_now(frames[-1]), frames[-1]
        settled = chrome.frame(master, b"", lambda screen: (marker(screen) or "").endswith(" new"), timeout=20)
        assert rows(settled)[0] == rows(scrolled)[0], settled
        chrome.frame(master, b"\x1b", lambda screen: latest(screen, "BIG-ANSWER") and composing(screen, "kept"))
        chrome.leave(master, caller)
    print("session chrome: an open /status updates Compact at · now in place, keeping its scroll and the draft", flush=True)


def long_page_case():
    """A long answer read over several windows commits at once with the end of
    the work: until a frame shows the answer, the call runs in the tail with
    the stop key; the first frame with any of the answer shows its last line
    at the bottom and no tail or stop key."""
    label = "Wait one second"
    lines = [f"long answer line {index:03} " + "w" * 52 for index in range(300)]
    with Chrome("rui-chrome-long.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            sleeping_call("long", label, 1),
            fixture.sse_answer("long-done", "r", "m", "\n\n".join(lines))[0],
        ]
        master, caller, _ = chrome.open(session, lambda screen: True)
        proxy, holding, _, release = hold_reads(chrome)
        try:
            os.write(master, b"wait one second\r")
            chrome.frame(master, b"", lambda screen: running_row(screen, label) and stopping(screen))
            holding.set()
            frames = collect(master, lambda: finished(chrome, session))
            release.set()
            frames += frames_until(master, b"", lambda screen: lines[-1] in screen, timeout=20)
        finally:
            release.set()
            proxy.close()
        for frame in frames:
            shown = "\n".join(transcript_rows(frame))
            if "long answer line" in shown:
                assert transcript_rows(frame)[-1].strip() == lines[-1] and marker(frame) is None, ("a partial page", frame)
                assert "•" not in shown and not stopping(frame), ("the answer beside a stale tail", frame)
            else:
                assert running_row(frame, label) and stopping(frame), ("the tail went before the answer", frame)
        chrome.leave(master, caller)
    print("session chrome: a long answer over several reads commits whole, with the tail and stop key gone", flush=True)


# Waiting Messages through eviction, steering and stops, on a 200-row screen.

TALL = 200


TALL_BOTTOM = TALL - 6  # The transcript's last row, where the marker sits.


TALL_LAST = TALL - 1


PAGE_UP = b"\x1b[5~"


# One answer larger than the live view's 256 KiB: it evicts every row before it.
LONG = "\n".join(f"LONG-{index:05d} " + "y" * 50 for index in range(4400))


LONG_END = "LONG-04399"


# How the long answer begins on the transcript: an older page names it by
# its raw export instead of drawing it.
ITS_ANSWER = ("LONG-", "Rui: Historical item omitted")


def tall_composing(screen, draft=""):
    """The composer shows `draft` on its row between the rules."""
    shown = rows(screen)
    return len(shown) == TALL and (set(shown[TALL - 5]) == {"─"} and set(shown[TALL - 3]) == {"─"}
            and shown[TALL - 4].rstrip() == (" › " + draft).rstrip())


def unmarked(screen):
    """The transcript's rows, with the `↓` marker cut from its last row."""
    shown = [row.rstrip() for row in rows(screen)[:TALL_BOTTOM + 1]]
    last = shown[-1]
    if last.endswith(" new") and "↓ " in last:
        last = last[:last.rindex("↓ ")]
    elif last.endswith("↓"):
        last = last[:-1]
    shown[-1] = last.rstrip()
    return shown


def tall_marker(screen):
    shown = rows(screen)[TALL_BOTTOM].rstrip()
    if shown.endswith(" new") and "↓ " in shown:
        return shown[shown.rindex("↓ "):]
    return "↓" if shown.endswith("↓") else None


def tall_tail(screen):
    """The transcript's rows after its last blank row: the tail's place."""
    shown = unmarked(screen)
    start = max((n for n, row in enumerate(shown) if not row), default=-1) + 1
    return shown[start:]


def tall_latest(screen, text):
    return text in "\n".join(unmarked(screen)) and tall_marker(screen) is None and tall_composing(screen)


def waits(screen, line, count):
    """`line` waits as the tail's last row, counted from two Messages, and
    the composer is empty for the next."""
    label = f"◌ {count} · {line}" if count > 1 else f"◌ {line}"
    return tall_composing(screen) and (tall_tail(screen) or [""])[-1] == label


def open_tall(chrome, session, ready):
    master, slave = open_pty(80, TALL)
    chrome.descriptors += [master, slave]
    caller = spawn([str(fixture.RUI), "session", "resume", "--", session],
        env={**os.environ, "HOME": str(chrome.home)}, cwd=str(chrome.workspace),
        stdin=slave, stdout=slave, stderr=subprocess.PIPE)
    chrome.callers.append(caller)
    screen = chrome.frame(master, b"", lambda screen: ready(screen) and tall_composing(screen) and "Opening…" not in screen, timeout=30)
    return master, caller, screen


def send_waiting(chrome, master, text, count):
    """Paste `text` and send it; it waits as the counted tail row, by its
    first line only, and the screen never calls it queued."""
    line = text.split("\n", 1)[0]
    screen = chrome.frame(master, b"\x1b[200~" + text.encode() + b"\x1b[201~\r", lambda screen: waits(screen, line, count))
    assert "queued" not in screen.lower(), screen
    if "\n" in text:
        assert text.split("\n")[1] not in screen, screen
    return screen


def overlap(upper, lower):
    """How many of `upper`'s last rows are `lower`'s first."""
    for size in range(min(len(upper), len(lower)), 0, -1):
        if upper[len(upper) - size:] == lower[:size]:
            return size
    return 0


def traverse(chrome, master, steps=120):
    """Page back from the latest view until row 0 says `Start of conversation`,
    joining what each settled view shows into the transcript, oldest row
    first. Once live rows were evicted, the first step back leaves the live
    view for a transcript of the older pages alone, which shares no row with
    it and ends at the latest row: from there the transcript is that
    document, and the live view it replaced is no part of it."""
    screen = settled(chrome, master)
    seen = unmarked(screen)
    for step in range(steps):
        if rows(screen)[0] == "Start of conversation":
            return seen
        screen = settled(chrome, master, PAGE_UP)
        assert tall_marker(screen) is not None and tall_composing(screen), screen
        view = unmarked(screen)
        # Blank rows at the edges join nothing: a short transcript's
        # padding sits there.
        while view and not view[-1]:
            view.pop()
        while seen and not seen[0]:
            seen.pop(0)
        size = overlap(view, seen)
        assert size or step == 0, ("a step back skipped rows", view, seen)
        seen = view[:len(view) - size] + seen if size else view
    raise AssertionError(("never reached the start", screen))


def settled(chrome, master, keys=b""):
    if keys:
        os.write(master, keys)
    while True:
        screen = settle_screen(master, quiet=0.4, timeout=30)
        if "Loading earlier messages…" not in rows(screen)[TALL_LAST]:
            return screen
        chrome.frame(master, b"", lambda screen: "Loading earlier messages…" not in rows(screen)[TALL_LAST], timeout=30)


def once_in_order_at_start(seen, *texts):
    """Each of `texts` begins exactly one row, in this order; return their rows."""
    at = []
    for text in texts:
        found = [n for n, row in enumerate(seen) if row.startswith(text)]
        assert len(found) == 1, (text, found, seen)
        at.append(found[0])
    assert at == sorted(at), (texts, at, seen)
    return at


def whole(seen):
    assert seen[0] == "Start of conversation", seen[:5]
    joined = "\n".join(seen)
    assert "◌" not in joined and "queued" not in joined.lower(), joined
    return joined


def first_row(seen, *prefixes):
    return min(n for n, row in enumerate(seen) if row.startswith(prefixes))


def evicted_case():
    """A Message sent while an answer runs waits as the tail's `◌` row, then
    gains its row; its own long answer evicts that row from the live view,
    whether the row arrived alone (its answer held) or with its answer in
    one read. The transcript still reaches it once, in order."""
    for variant in ("alone", "with-reply"):
        evicted(variant)
    print("session chrome: an evicted Message waits as ◌, then is its row once, alone or with its reply", flush=True)


def evicted(variant):
    first_release, reply_release = threading.Event(), threading.Event()
    with Chrome(f"rui-evict-{variant}.", []) as chrome:
        session = chrome.session()
        reply = fixture.sse_answer(f"evicted-{variant}", "r", "m", LONG)[0]
        chrome.endpoint.responses += [
            (fixture.sse_answer(f"before-{variant}", "r", "m", "PREDECESSOR-DONE")[0], first_release),
            (reply, reply_release) if variant == "alone" else reply,
        ]
        master, caller, _ = open_tall(chrome, session, lambda screen: True)
        proxy = None
        try:
            requests = len(chrome.endpoint.requests)
            chrome.frame(master, b"EVICTION-DRIVER\r", lambda screen: "› EVICTION-DRIVER" in screen)
            fixture.wait_for(lambda: len(chrome.endpoint.requests) > requests, "first model request", timeout=20)
            message = "EVICTED-MESSAGE\n" + "\n".join(f"evicted body {index:03d}" for index in range(300))
            send_waiting(chrome, master, message, 1)
            if variant == "alone":
                first_release.set()
                # Its row shows before its answer starts.
                chrome.frame(master, b"", lambda screen: "› EVICTED-MESSAGE" in screen and "◌" not in screen, timeout=20)
                fixture.wait_for(lambda: len(chrome.endpoint.requests) > requests + 1, "its model request", timeout=20)
                reply_release.set()
            else:
                proxy, holding, held, release = hold_reads(chrome)
                holding.set()
                fixture.wait_for(draining(master, held.is_set), "no read reached the held page", timeout=10)
                first_release.set()
                fixture.wait_for(draining(master, lambda: finished(chrome, session)), "both answers", timeout=30)
                holding.clear()
                release.set()
            chrome.frame(master, b"", lambda screen: tall_latest(screen, LONG_END) and "◌" not in screen, timeout=60)
            seen = traverse(chrome, master)
            whole(seen)
            at = once_in_order_at_start(seen, "› EVICTION-DRIVER", "PREDECESSOR-DONE", "› EVICTED-MESSAGE")
            assert at[-1] < first_row(seen, *ITS_ANSWER), seen
            chrome.leave(master, caller)
        finally:
            first_release.set()
            reply_release.set()
            if proxy is not None:
                release.set()
                proxy.close()


def steered_case():
    """A Message sent while a tool runs waits as `◌` under the running call
    and joins the turn when the call ends; its long answer evicts it, and
    the transcript reaches it once, after the call's row."""
    with Chrome("rui-evict-steer.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            chrome.held_call("Wait for steer", "steer-gate"),
            fixture.sse_answer("steered", "r", "m", LONG)[0],
        ]
        master, caller, _ = open_tall(chrome, session, lambda screen: True)
        try:
            chrome.frame(master, b"START-STEERING\r", lambda screen: "• Wait for steer · " in screen)
            screen = send_waiting(chrome, master, "STEERED-MESSAGE\nits second line", 1)
            assert tall_tail(screen)[-2].startswith("• Wait for steer · "), screen
            assert not (chrome.workspace / "steer-gate").exists()
            (chrome.workspace / "steer-gate").write_text("")
            chrome.frame(master, b"", lambda screen: tall_latest(screen, LONG_END) and "◌" not in screen and "•" not in screen, timeout=60)
            seen = traverse(chrome, master)
            whole(seen)
            call = once_in_order_at_start(seen, "› START-STEERING")[0]
            message = once_in_order_at_start(seen, "› STEERED-MESSAGE")[0]
            ran = [n for n, row in enumerate(seen) if "Wait for steer" in row]
            assert ran and call < ran[0] < message < first_row(seen, *ITS_ANSWER), seen
            chrome.leave(master, caller)
        finally:
            (chrome.workspace / "steer-gate").write_text("")
    print("session chrome: a Message steered into a running call waits as ◌, then is its row once after eviction", flush=True)


def shared_page_case():
    """One read brings a long answer, the row of the Message that waited
    behind it and that Message's reply; the long answer evicts what came
    before. The transcript reaches the Message once, after the answer and
    before its reply."""
    first_release = threading.Event()
    with Chrome("rui-evict-shared.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            (fixture.sse_answer("shared-first", "r", "m", LONG)[0], first_release),
            fixture.sse_answer("shared-second", "r", "m", "SECOND-REPLY-DONE")[0],
        ]
        master, caller, _ = open_tall(chrome, session, lambda screen: True)
        proxy, holding, held, release = hold_reads(chrome)
        try:
            requests = len(chrome.endpoint.requests)
            chrome.frame(master, b"DRIVER-QUESTION\r", lambda screen: "› DRIVER-QUESTION" in screen)
            fixture.wait_for(lambda: len(chrome.endpoint.requests) > requests, "first model request", timeout=20)
            send_waiting(chrome, master, "SHARED-MESSAGE\nits second line", 1)
            holding.set()
            fixture.wait_for(draining(master, held.is_set), "no read reached the held page", timeout=10)
            first_release.set()
            fixture.wait_for(draining(master, lambda: len(chrome.endpoint.requests) > requests + 1 and finished(chrome, session)),
                "both answers", timeout=30)
            holding.clear()
            release.set()
            screen = chrome.frame(master, b"", lambda screen: tall_latest(screen, "SECOND-REPLY-DONE") and "◌" not in screen, timeout=60)
            # Live, the Message's row is after the long answer, once.
            live = unmarked(screen)
            assert sum(row.startswith("› SHARED-MESSAGE") for row in live) == 1, screen
            seen = traverse(chrome, master)
            whole(seen)
            driver, message, _ = once_in_order_at_start(seen, "› DRIVER-QUESTION", "› SHARED-MESSAGE", "SECOND-REPLY-DONE")
            assert driver < first_row(seen, *ITS_ANSWER) < message, seen
            chrome.leave(master, caller)
        finally:
            first_release.set()
            release.set()
            proxy.close()
    print("session chrome: a Message whose row and reply share a read with an evicting answer is its row once, after it", flush=True)


STOPPED = "! Stopped before it ran · send it again to run it"


def stopped_many_case():
    """More Messages wait than one Activity page holds, as one counted `◌`
    row; a stop excludes them all. Each is then its own row once, oldest
    first, under its stopped label, before the stop's line, live and when
    the person scrolls back to the start."""
    first_release = threading.Event()
    count = 40
    with Chrome("rui-evict-stopped.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [(fixture.sse_answer("never", "r", "m", "NEVER-SHOWN")[0], first_release)]
        master, caller, _ = open_tall(chrome, session, lambda screen: True)
        try:
            requests = len(chrome.endpoint.requests)
            chrome.frame(master, b"DRIVER-QUESTION\r", lambda screen: "› DRIVER-QUESTION" in screen)
            fixture.wait_for(lambda: len(chrome.endpoint.requests) > requests, "first model request", timeout=20)
            for index in range(count):
                send_waiting(chrome, master, f"MANY-STOPPED-{index:02d}", index + 1)
            run(chrome.home, "session", "stop", "--store", chrome.store, "--session", session,
                "--record", chrome.state / "many-stop.json", "--key", "many-stop")
            screen = chrome.frame(master, b"", lambda screen: "! Session stopped." in screen and "◌" not in screen
                and not rows(screen)[TALL_LAST].strip(), timeout=30)
            labels = [f"› MANY-STOPPED-{index:02d}" for index in range(count)]
            for shown in (unmarked(screen), traverse(chrome, master)):
                at = once_in_order_at_start(shown, "› DRIVER-QUESTION", *labels, "! Session stopped.")
                assert all(shown[n - 1] == STOPPED for n in at[1:-1]), shown
                assert sum(row == STOPPED for row in shown) == count, shown
                joined = "\n".join(shown)
                assert "NEVER-SHOWN" not in joined and "queued" not in joined.lower(), shown
            chrome.leave(master, caller)
        finally:
            first_release.set()
    print(f"session chrome: {count} waiting Messages a stop excluded are each their row once, labelled, before its line", flush=True)


def opening_older_case():
    """A Message that waits behind held calls whose commentary fills more
    than the live view shows at the opening as `◌` under the running calls;
    it joins the turn in the read that brings the calls' results, and is
    then its row once, on screen and when the person scrolls to the start."""
    first_release, page_release, page_held = threading.Event(), threading.Event(), threading.Event()
    commentary = {"type": "message", "id": "opening-message", "status": "completed", "role": "assistant", "phase": "commentary",
        "content": [{"type": "output_text", "text": "\n".join(f"OPENING-LONG-{index:05d} " + "x" * 50 for index in range(4500)), "annotations": []}]}
    calls = [{"type": "function_call", "id": f"opening-tool-{index}", "status": "completed", "name": "bash", "call_id": f"opening-call-{index}",
        "arguments": json.dumps({"cmd": "touch opening-started; while [ ! -e opening-release ]; do sleep 0.05; done; printf done",
            "description": f"Opening call {index:02d}", "timeout_ms": None})} for index in range(15)]
    payloads = []
    for index, item in enumerate([commentary, *calls]):
        payloads += [{"type": "response.output_item.added", "output_index": index, "item": {"type": item["type"], "id": item["id"]}},
            {"type": "response.output_item.done", "output_index": index, "item": item}]
    payloads.append({"type": "response.completed", "response": {"id": "opening-first", "status": "completed", "model": "model-a-served",
        "output": [commentary, *calls]}})

    def hold_once(_):
        if not page_held.is_set():
            page_held.set()
            assert page_release.wait(20), "the held page was never released"
        return True
    with Chrome("rui-evict-opening.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            (fixture.ResponseSpec(fixture.encode_sse(payloads), {}), first_release),
            fixture.sse_answer("opening-final", "r", "m", "OPENING-APPLIED-DONE")[0],
        ]
        proxy = None
        try:
            admit(chrome.home, "session", "send", "--to", session, input="DRIVER-QUESTION")
            fixture.wait_for(lambda: len(chrome.endpoint.requests) >= 1, "first model request", timeout=20)
            admit(chrome.home, "session", "send", "--to", session, input="HIDDEN-WAITING-UNIQUE")
            first_release.set()
            fixture.wait_for(lambda: (chrome.workspace / "opening-started").exists(), "held calls", timeout=20)
            master, caller, opened = open_tall(chrome, session, lambda screen: "◌ HIDDEN-WAITING-UNIQUE" in screen
                and "• Opening call 00 · " in screen)
            # Under the running calls, which the tail sums past its third.
            shown = tall_tail(opened)
            assert shown[-1] == "◌ HIDDEN-WAITING-UNIQUE" and shown[-2].strip().startswith("+12 more running"), opened
            assert "OPENING-LONG-04499" in opened and opened.count("HIDDEN-WAITING-UNIQUE") == 1, opened
            assert "queued" not in opened.lower() and rows(opened)[TALL_LAST].endswith("ctrl+x stop"), opened
            # One read brings the calls' results and the Message's row.
            proxy = canonical.ReplyProxy(chrome.host, "/v1/activity-page", lambda response: response, before_forward=hold_once)
            fixture.wait_for(draining(master, page_held.is_set), "no read reached the held page", timeout=10)
            (chrome.workspace / "opening-release").write_text("")
            fixture.wait_for(draining(master, lambda: len(chrome.endpoint.requests) >= 2), "continuation", timeout=20)
            sent = json.loads(chrome.endpoint.requests[-1])["input"]
            assert any(item.get("role") == "user" and item["content"][0]["text"] == "HIDDEN-WAITING-UNIQUE" for item in sent), sent
            page_release.set()
            screen = chrome.frame(master, b"", lambda screen: tall_latest(screen, "OPENING-APPLIED-DONE")
                and "◌" not in screen and "•" not in screen, timeout=60)
            assert sum(row.startswith("› HIDDEN-WAITING-UNIQUE") for row in unmarked(screen)) == 1, screen
            seen = traverse(chrome, master)
            whole(seen)
            once_in_order_at_start(seen, "› DRIVER-QUESTION", "› HIDDEN-WAITING-UNIQUE", "OPENING-APPLIED-DONE")
            chrome.leave(master, caller)
        finally:
            page_release.set()
            first_release.set()
            (chrome.workspace / "opening-release").write_text("")
            if proxy is not None:
                proxy.close()
    print("session chrome: a Message waiting behind an opening's held calls shows as ◌, then is its row once", flush=True)


def queued_behind_answer_case():
    """A Message sent while an answer runs waits as the tail's `◌` row; its
    own long answer then evicts every row before it from the live view, and
    the transcript still reaches the Message once, after the answer it
    waited behind and before its own."""
    first_release = threading.Event()
    with Chrome("rui-evict-queued.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            (fixture.sse_answer("first", "r", "m", "FIRST-ANSWER-DONE")[0], first_release),
            fixture.sse_answer("second", "r", "m", LONG)[0],
        ]
        master, caller, _ = open_tall(chrome, session, lambda screen: True)
        try:
            requests = len(chrome.endpoint.requests)
            chrome.frame(master, b"FIRST-QUESTION\r", lambda screen: "› FIRST-QUESTION" in screen)
            fixture.wait_for(lambda: len(chrome.endpoint.requests) > requests, "first model request", timeout=20)
            send_waiting(chrome, master, "WAITED-BEHIND\nits second line", 1)
            first_release.set()
            chrome.frame(master, b"", lambda screen: tall_latest(screen, LONG_END) and "◌" not in screen, timeout=60)
            seen = traverse(chrome, master)
            whole(seen)
            at = once_in_order_at_start(seen, "› FIRST-QUESTION", "FIRST-ANSWER-DONE", "› WAITED-BEHIND")
            assert at[-1] < first_row(seen, *ITS_ANSWER), seen
            chrome.leave(master, caller)
        finally:
            first_release.set()
    print("session chrome: a Message queued behind an answer waits as ◌, then is its row once after its long answer evicts it", flush=True)


# Read boundaries, catch-up pages and drafts across reopening.

UP = b"\x1b[1;2A"  # Shift-↑: half a screen back.


START = "Start of conversation"


def shown_rows(screen):
    """The transcript's rows, the marker cut from its last."""
    shown = [row.rstrip() for row in rows(screen)[:BOTTOM + 1]]
    found = marker(screen)
    if found:
        shown[-1] = shown[-1][:-len(found)].rstrip()
    return shown


def join(read, window, skip=False):
    """`window` added under `read` where its first rows repeat read's last,
    on at least one row that is not blank. With `skip`, rows at the top of
    `window` may differ: the live rows, which can show what older pages put
    as one omitted row, end the read."""
    # The marker draws over the right end of the last row, a Message's time
    # among it, so rows match on what is left of them.
    def seen(part):
        return [row[:72] for row in part]
    while skip and read and not read[-1].strip():
        read = read[:-1]
    for start in range(len(window) if skip else 1):
        rest = window[start:]
        for overlap in range(min(len(read), len(rest)), 0, -1):
            if seen(read[-overlap:]) == seen(rest[:overlap]) and any(row.strip() for row in rest[:overlap]):
                return read + rest[overlap:]
    raise AssertionError(("no overlap between steps", read[-len(window):], window))


def transcript(chrome, master, until=None, steps=2000):
    """Scroll back to the start, then down, joining each half-screen step:
    the rows from `Start of conversation` down to the latest, or to the
    first step that shows `until`. Returns the rows; the view is left at
    the latest, or scrolled back where `until` showed."""
    top = settle_screen(master, quiet=0.3)
    unmoved = 0
    for _ in range(steps):
        if rows(top)[0] == START:
            break
        # A step at the top of what is loaded asks for the older page, which
        # joins above the rows in view without moving them: step again.
        try:
            before = rows(top)[:BOTTOM]
            top = chrome.frame(master, UP, lambda screen, before=before: rows(screen)[:BOTTOM] != before, timeout=1)
            unmoved = 0
        except AssertionError:
            unmoved += 1
            assert unmoved < 15, ("no older page joined", top)
    else:
        raise AssertionError(("never reached the start", top))
    top = settle_screen(master, quiet=0.3)
    read = shown_rows(top)
    screen = top
    # Down a row at a time, so every row of the scrolled-back view shows; the
    # step past its end returns to the latest, whose rows end the read.
    for _ in range(steps * 10):
        if until is not None and until in "\n".join(read):
            return read
        before = rows(screen)[:BOTTOM + 1]
        screen = chrome.frame(master, b"\x1b[B", lambda screen, before=before: rows(screen)[:BOTTOM + 1] != before)
        if marker(screen) is None:
            return join(read, shown_rows(screen), skip=True)
        read = join(read, shown_rows(screen))
    raise AssertionError(("never reached the latest", screen))


def once_in_order(read, *texts):
    """Each text on exactly one row, the rows in the order given."""
    found = []
    for text in texts:
        at = [n for n, row in enumerate(read) if text in row]
        assert len(at) == 1, (text, at, "\n".join(read))
        found.append(at[0])
    assert found == sorted(found), (list(zip(texts, found)), "\n".join(read))
    return found


def hold_reads(chrome, route="/v1/activity-page"):
    """A proxy before the Host: once `holding` is set, each read of `route`
    waits for `release`. Returns (proxy, holding, held, release)."""
    holding, held, release = threading.Event(), threading.Event(), threading.Event()

    def hold(_):
        if holding.is_set():
            held.set()
            release.wait(20)
        return True
    proxy = canonical.ReplyProxy(chrome.host, route, lambda response: response, before_forward=hold)
    return proxy, holding, held, release


def visible_send(frames, text):
    """From the frame that clears the composer on, each frame shows the
    send state at the left of the last row, the Message's row, or its
    waiting `◌` row at the tail: it never vanishes."""
    cleared = False
    for frame in frames:
        cleared = cleared or composing(frame, "")
        if not cleared:
            continue
        shown = shown_rows(frame)
        state = rows(frame)[LAST].split("  ")[0].strip()
        assert (state in ("Sending…", "Sent") or any(row.startswith("› " + text) for row in shown)
                or (shown[-1].startswith("◌ ") and text in shown[-1])), ("the Message vanished", text, frame)
    assert cleared, frames


def escaped_boundary_case():
    """An answer whose oversized cluster live output escapes is shorter on
    screen than in the Store; a Message sent while it ran, its reply and the
    next turn still read back in order, once each, from the start."""
    styled = "e" + "\u0301" * 2000 + " SHORT-STYLED-END"
    first_release = threading.Event()
    with Chrome("rui-reads-escaped.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            (fixture.sse_answer("escaped-first", "r", "m", styled)[0], first_release),
            fixture.sse_answer("escaped-second", "r", "m", "OK-REPLY")[0],
            fixture.sse_answer("escaped-third", "r", "m", "THIRD-REPLY")[0],
        ]
        master, caller, _ = chrome.open(session, lambda screen: True)
        proxy, holding, held, release = hold_reads(chrome)
        try:
            requests = len(chrome.endpoint.requests)
            chrome.frame(master, b"DRIVER-QUESTION\r", lambda screen: "› DRIVER-QUESTION" in screen)
            fixture.wait_for(lambda: len(chrome.endpoint.requests) > requests, "the first model request", timeout=20)
            frames = frames_until(master, b"JOINED-M\r", lambda screen: "JOINED-M" in "\n".join(rows(screen)[:BOTTOM + 1]))
            visible_send(frames, "JOINED-M")
            # One page read then holds the escaped answer's end, the joined
            # Message's row and its reply.
            holding.set()
            fixture.wait_for(draining(master, held.is_set), "a held page read", timeout=5)
            first_release.set()
            fixture.wait_for(draining(master, lambda: len(chrome.endpoint.requests) > requests + 1 and finished(chrome, session)),
                "both answers", timeout=20)
            holding.clear()
            release.set()
            chrome.frame(master, b"", lambda screen: latest(screen, "OK-REPLY"), timeout=30)
            frames = frames_until(master, b"THIRD-QUESTION\r", lambda screen: latest(screen, "THIRD-REPLY"))
            visible_send(frames, "THIRD-QUESTION")
            read = transcript(chrome, master)
            assert not any("Earlier rows left this view." in row for row in read), "\n".join(read)
            once_in_order(read, START, "› DRIVER-QUESTION", "SHORT-STYLED-END", "› JOINED-M", "OK-REPLY",
                "› THIRD-QUESTION", "THIRD-REPLY")
            chrome.leave(master, caller)
        finally:
            first_release.set()
            release.set()
            proxy.close()
    print("session chrome: an answer escaping shortens, the Message joined to it and the next turn read back once each, in order", flush=True)


def shortened_boundary_case():
    """An answer live output shortens (its styling dropped, a cluster
    escaped), then a long Message sent while it ran and a reply that alone
    nearly fills what the screen keeps live: the opening leaves the live
    view, and scrolling back joins older pages to the live rows at the
    reply's start, so every row reads once, in order, with none lost."""
    filler = "\n".join(f"FILLER-{index:03d} " + "f" * 50 for index in range(100))
    styled = " ".join(f"**bold{index}**" for index in range(12)) + "\n" + filler + "\ne" + "\u0301" * 200 + " STYLED-END"
    reply = "\n".join(f"REPLY-{index:05d} " + "y" * 50 for index in range(4100))
    long_message = "m" * 59199
    first_release = threading.Event()
    with Chrome("rui-reads-shortened.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            (fixture.sse_answer("shortened-first", "r", "m", styled)[0], first_release),
            fixture.sse_answer("shortened-second", "r", "m", reply)[0],
        ]
        master, caller, _ = chrome.open(session, lambda screen: True)
        proxy, holding, held, release = hold_reads(chrome)
        try:
            requests = len(chrome.endpoint.requests)
            chrome.frame(master, b"DRIVER-QUESTION\r", lambda screen: "› DRIVER-QUESTION" in screen)
            fixture.wait_for(lambda: len(chrome.endpoint.requests) > requests, "the first model request", timeout=20)
            frames = frames_until(master, b"\x1b[200~" + long_message.encode() + b"\x1b[201~\r",
                lambda screen: composing(screen, "") and "m" * 40 in "\n".join(rows(screen)[:BOTTOM + 1]))
            visible_send(frames, "m" * 40)
            holding.set()
            fixture.wait_for(draining(master, held.is_set), "a held page read", timeout=5)
            first_release.set()
            fixture.wait_for(draining(master, lambda: len(chrome.endpoint.requests) > requests + 1 and finished(chrome, session)),
                "both answers", timeout=20)
            holding.clear()
            release.set()
            chrome.frame(master, b"", lambda screen: latest(screen, "REPLY-04099"), timeout=30)
            read = transcript(chrome, master, until="REPLY-00012")
            assert not any("Earlier rows left this view." in row for row in read), "\n".join(read)
            once_in_order(read, START, "› DRIVER-QUESTION", "bold0", "bold11", "FILLER-000", "FILLER-099", "STYLED-END",
                "› " + "m" * 40, *(f"REPLY-{index:05d} " for index in range(12)))
            # The reply's rows follow one another, and all of the answer's.
            replies = [n for n, row in enumerate(read) if row.startswith("REPLY-")]
            assert replies == list(range(replies[0], replies[0] + len(replies))), "\n".join(read)
            fillers = [n for n, row in enumerate(read) if row.startswith("FILLER-")]
            assert [read[n][:10] for n in fillers] == [f"FILLER-{i:03d}" for i in range(100)], "\n".join(read)
            chrome.frame(master, b"\x1b", lambda screen: latest(screen, "REPLY-04099"))
            chrome.leave(master, caller)
        finally:
            first_release.set()
            release.set()
            proxy.close()
    print("session chrome: older pages join live rows at a reply after an answer live output shortens; each row once, in order", flush=True)


def answered(read, driver, message):
    """The long answer shows between its question and the Message, as its
    rows or as the row an older page puts in its place, and never after."""
    between = read[driver + 1:message]
    assert any("REPLY-04399" in row or "Historical item omitted" in row for row in between), "\n".join(read)
    assert not any("REPLY-" in row or "Historical item omitted" in row for row in read[message:]), "\n".join(read)


def held_row_case():
    """A long Message sent while a long answer runs joins that turn; when
    the answer ends its row is read while its own reply is still held, so
    a read holds that row alone after rows that left the live view. From
    Enter on the Message stays in sight; scrolling back reaches it once,
    after the answer; its reply then shows once, after it."""
    reply = "\n".join(f"REPLY-{index:05d} " + "y" * 50 for index in range(4400))
    long_message = "m" * 59199
    first_release, second_release = threading.Event(), threading.Event()
    with Chrome("rui-reads-held-row.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            (fixture.sse_answer("held-row-first", "r", "m", reply)[0], first_release),
            (fixture.sse_answer("held-row-second", "r", "m", "SILENT-SECOND-DONE")[0], second_release),
        ]
        master, caller, _ = chrome.open(session, lambda screen: True)
        try:
            requests = len(chrome.endpoint.requests)
            chrome.frame(master, b"DRIVER-QUESTION\r", lambda screen: "› DRIVER-QUESTION" in screen)
            fixture.wait_for(lambda: len(chrome.endpoint.requests) > requests, "the first model request", timeout=20)
            os.write(master, b"\x1b[200~" + long_message.encode() + b"\x1b[201~")
            chrome.frame(master, b"", lambda screen: "↑ 759 more lines" in screen)
            frames = frames_until(master, b"\r", lambda screen: composing(screen, "") and "◌ " in screen)
            first_release.set()
            frames += frames_until(master, b"", lambda screen: latest(screen, "› " + "m" * 40), timeout=30)
            visible_send(frames, "m" * 40)
            # The joined Message's own reply is asked for and held.
            fixture.wait_for(draining(master, lambda: len(chrome.endpoint.requests) > requests + 1), "the second model request", timeout=20)
            alone = settle_screen(master, quiet=1.0)
            assert "SILENT-SECOND-DONE" not in alone and latest(alone, "› " + "m" * 40), alone
            read = transcript(chrome, master, until="› " + "m" * 40)
            assert not any("Earlier rows left this view." in row for row in read), "\n".join(read)
            driver, message = once_in_order(read, START, "› DRIVER-QUESTION", "› " + "m" * 40)[1:]
            answered(read, driver, message)
            chrome.frame(master, b"\x1b", lambda screen: latest(screen, "› " + "m" * 40))
            second_release.set()
            chrome.frame(master, b"", lambda screen: latest(screen, "SILENT-SECOND-DONE"), timeout=30)
            read = transcript(chrome, master)
            driver, message = once_in_order(read, START, "› DRIVER-QUESTION", "› " + "m" * 40, "SILENT-SECOND-DONE")[1:3]
            answered(read, driver, message)
            assert not any("Earlier rows left this view." in row for row in read), "\n".join(read)
            chrome.leave(master, caller)
        finally:
            first_release.set()
            second_release.set()
    print("session chrome: a Message whose row a read holds alone after a long answer shows once, after it, and its reply once after", flush=True)


def page_before_message_case():
    """A page asked for just before a Message, while the read it needs is
    held, never opens over that Message: from Enter on, no frame shows the
    page or a scrolled-back view, the send stays in sight, and the answer
    ends the screen at the latest. Each page: /status, /details and
    /history queued behind a held scan, and /details held reading the
    Conversation itself."""
    pages = (
        ("/status", "/v1/activity-page", lambda screen: rows(screen)[0].startswith(" Status · ")),
        ("/details", "/v1/activity-page", lambda screen: "tool details" in rows(screen)[1]),
        ("/history", "/v1/activity-page", lambda screen: rows(screen)[0] == START),
        ("/details", "/v1/conversation-page", lambda screen: "tool details" in rows(screen)[1]),
    )
    with Chrome("rui-reads-page.", [fixture.sse_answer("page-seed", "r", "m", "SEED-ANSWER")[0]]) as chrome:
        session = chrome.session()
        chrome.answered(session, "seed")
        for index, (command, route, opened) in enumerate(pages):
            master, caller, _ = chrome.open(session, lambda screen: "SEED-ANSWER" in screen)
            # The page opens when asked for with nothing held.
            chrome.frame(master, command.encode() + b"\r", opened)
            chrome.frame(master, b"\x1b", lambda screen, opened=opened: latest(screen, "SEED-ANSWER") and not opened(screen))
            proxy, holding, held, release = hold_reads(chrome, route)
            try:
                holding.set()
                if route == "/v1/activity-page":
                    fixture.wait_for(draining(master, held.is_set), (command, "no scan reached the held read"), timeout=5)
                chrome.frame(master, command.encode(), lambda screen, command=command: composing(screen, command))
                chrome.frame(master, b"\r", lambda screen: composing(screen, ""))
                fixture.wait_for(draining(master, held.is_set), (command, route, "the page's read was not held"), timeout=5)
                text = f"AFTER-PAGE-{index}"
                chrome.endpoint.responses.append(fixture.sse_answer(f"page-{index}", "r", "m", f"PAGE-ANSWER-{index}")[0])
                chrome.frame(master, text.encode(), lambda screen, text=text: composing(screen, text))
                frames = frames_until(master, b"\r", lambda screen: rows(screen)[LAST].split("  ")[0].strip() in ("Sending…", "Sent"))
                holding.clear()
                release.set()
                frames += frames_until(master, b"", lambda screen, index=index: latest(screen, f"PAGE-ANSWER-{index}"), timeout=30)
                frames.append(settle_screen(master, quiet=1.0))
                visible_send(frames, text)
                for frame in frames:
                    assert not opened(frame) and marker(frame) is None, (command, route, "a page opened over the Message", frame)
                assert latest(frames[-1], f"PAGE-ANSWER-{index}") and composing(frames[-1], ""), frames[-1]
                chrome.leave(master, caller)
            finally:
                release.set()
                proxy.close()
    print("session chrome: /status, /details and /history asked for before a Message never open over it; its send stays in sight", flush=True)


def catch_up_case():
    """While page reads are held, ten turns land elsewhere; a Message sent
    then waits behind catch-up pages that end before it. From Enter on the
    send state or its row stays in sight through every page, and the
    transcript then reads each backlog turn and the Message once, in order."""
    with Chrome("rui-reads-catch-up.", []) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        proxy, holding, _, release = hold_reads(chrome)
        try:
            holding.set()
            for index in range(10):
                chrome.endpoint.responses.append(fixture.sse_answer(f"backlog-{index}", "r", "m", f"BACKLOG-ANSWER-{index}")[0])
                key = admit(chrome.home, "session", "send", "--to", session, input=f"BACKLOG-{index}")["request"]
                fixture.wait_for(draining(master, lambda key=key: fixture.completed_observation(chrome.store, key)), "backlog answer", timeout=20)
            fixture.wait_for(draining(master, lambda: finished(chrome, session)), "backlog settled", timeout=20)
            chrome.endpoint.responses.append(fixture.sse_answer("caught-up", "r", "m", "CAUGHT-UP-ANSWER")[0])
            chrome.frame(master, b"CCC", lambda screen: composing(screen, "CCC"))
            frames = frames_until(master, b"\r", lambda screen: rows(screen)[LAST].split("  ")[0].strip() == "Sent")
            release.set()
            holding.clear()
            frames += frames_until(master, b"", lambda screen: latest(screen, "CAUGHT-UP-ANSWER"), timeout=30)
            visible_send(frames, "CCC")
            read = transcript(chrome, master)
            once_in_order(read, START, *(text for index in range(10) for text in (f"› BACKLOG-{index} ", f"BACKLOG-ANSWER-{index}")),
                "› CCC ", "CAUGHT-UP-ANSWER")
            chrome.leave(master, caller)
        finally:
            release.set()
            proxy.close()
    print("session chrome: Sent stays through catch-up pages that end before the Message; the backlog and it read once, in order", flush=True)


def last_user_text(chrome):
    body = json.loads(chrome.endpoint.requests[-1])
    return next(item["content"][0]["text"] for item in reversed(body["input"]) if item.get("role") == "user")


def persistent_input_case():
    """A draft typed while the original Message is still being sent stays
    the person's through scrolling back and Esc, and through the
    original's lost reply and its Ctrl-R recovery; it is sent as edited.
    Each Message and answer then reads once, in order, before and after
    the Session is reopened: the recovered original is never doubled."""
    original, edited = "original éZ", "next cafXYé!"
    with Chrome("rui-reads-persistent.", [
        (fixture.sse_answer("persistent-a", "r", "m", "FIRST-EXACT-ANSWER")[0]),
        (fixture.sse_answer("persistent-b", "r", "m", "SECOND-EXACT-ANSWER")[0]),
    ]) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        received, admission_release = threading.Event(), threading.Event()

        def hold_first(_):
            if not received.is_set():
                received.set()
                admission_release.wait(15)
            return True
        # The first Admission is held, then its reply is lost.
        proxy = canonical.ReplyProxy(chrome.host, "/v1/message",
            lambda response: b"" if len(proxy.exchanges) == 1 else response, before_forward=hold_first)
        try:
            frames = frames_until(master, original.encode() + b"\r", lambda screen: composing(screen, "") and rows(screen)[LAST].startswith("Sending…"))
            fixture.wait_for(draining(master, received.is_set), "the original reached the Host", timeout=10)
            # A draft begun while scrolled back, finished after Esc, edited mid-line.
            scrolled = chrome.frame(master, UP, lambda screen: marker(screen) == "↓")
            assert rows(scrolled)[LAST].startswith("Sending…"), scrolled
            chrome.frame(master, b"next ", lambda screen: composing(screen, "next ") and marker(screen) == "↓")
            back = chrome.frame(master, b"\x1b", lambda screen: marker(screen) is None)
            assert composing(back, "next ") and rows(back)[LAST].startswith("Sending…"), back
            chrome.frame(master, "café!\x1b[D\x1b[DX".encode(), lambda screen: composing(screen, "next cafXé!"))
            admission_release.set()
            uncertain = chrome.frame(master, b"", lambda screen: rows(screen)[LAST].startswith("! Not confirmed"), timeout=20)
            assert "ctrl+r retries" in rows(uncertain)[LAST].lower().replace("ctrl-r", "ctrl+r"), uncertain
            assert composing(uncertain, "next cafXé!"), uncertain
            frames += frames_until(master, b"", lambda screen: "FIRST-EXACT-ANSWER" in screen, timeout=20)
            visible_send(frames, original)
            assert len(proxy.exchanges) == 1 and len(chrome.endpoint.requests) == 1
            # Ctrl-R confirms the original; the draft stays, and PgUp and Esc keep it.
            status = chrome.frame(master, b"\x12", lambda screen: "Original confirmed" in rows(screen)[LAST])
            assert composing(status, "next cafXé!"), status
            assert len(proxy.exchanges) == 2 and proxy.exchanges[1][0] == proxy.exchanges[0][0], "Ctrl-R changed the original"
            assert len(chrome.endpoint.requests) == 1, "recovery repeated provider work"
            scrolled = chrome.frame(master, b"\x1b[5~", lambda screen: marker(screen) == "↓")
            assert composing(scrolled, "next cafXé!"), scrolled
            back = chrome.frame(master, b"\x1b", lambda screen: latest(screen, "FIRST-EXACT-ANSWER"))
            assert composing(back, "next cafXé!"), back
            # The caret stayed before é.
            frames = frames_until(master, b"Y\r", lambda screen: latest(screen, "SECOND-EXACT-ANSWER"), timeout=20)
            visible_send(frames, edited)
            assert last_user_text(chrome) == edited and len(chrome.endpoint.requests) == 2
            order = (START, "› " + original + " ", "FIRST-EXACT-ANSWER", "› " + edited + " ", "SECOND-EXACT-ANSWER")
            once_in_order(transcript(chrome, master), *order)
            chrome.leave(master, caller)
        finally:
            admission_release.set()
            proxy.close()
        master, caller, _ = chrome.open(session, lambda screen: "SECOND-EXACT-ANSWER" in screen)
        once_in_order(transcript(chrome, master), *order)
        chrome.leave(master, caller)
    print("session chrome: a draft typed while the original sends survives scrolling, its lost reply and Ctrl-R; each Message once after reopening", flush=True)


def long_input_case():
    """/status opens and Esc returns; a 5,000-character draft keeps every
    row through scrolling back and Esc, is sent whole, shows from Enter on
    and then as a collapsed row (one line: no count); /status after it returns to the answer;
    the Message and its answer read once, in order."""
    long_text = "X" * 5000
    with Chrome("rui-reads-long.", [fixture.sse_answer("long", "r", "m", "LONG-INPUT-INTACT")[0]]) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        status = chrome.frame(master, b"/status\r", lambda screen: rows(screen)[0].strip() == f"Status · {session}")
        assert composing(status, "") and marker(status) == "↓", status
        chrome.frame(master, b"\x1b", lambda screen: marker(screen) is None and "Status ·" not in screen)
        os.write(master, b"\x1b[200~" + long_text.encode() + b"\x1b[201~")
        drafted = settle_screen(master, quiet=0.5)
        composer = [row for row in rows(drafted) if row.startswith(("   X", " › X"))]
        assert composer and all(set(row.strip(" ›")) == {"X"} for row in composer), drafted
        held = rows(drafted)[next(n for n, row in enumerate(rows(drafted)) if row in composer):]
        requests = len(chrome.endpoint.requests)
        for keys in (UP, b"\x1b[5~"):
            chrome.frame(master, keys, lambda screen: marker(screen) is not None or START in screen)
            back = chrome.frame(master, b"\x1b", lambda screen: marker(screen) is None and START not in screen)
            assert rows(back)[-len(held):] == held, (keys, "the draft changed", back)
        assert len(chrome.endpoint.requests) == requests, "scrolling sent the draft"
        frames = frames_until(master, b"\r", lambda screen: latest(screen, "LONG-INPUT-INTACT"), timeout=20)
        visible_send(frames, "X" * 40)
        assert last_user_text(chrome) == long_text
        shown = shown_rows(frames[-1])
        assert any(row.startswith("› XXXX") for row in shown) and "  ┄" in shown, frames[-1]
        chrome.frame(master, b"/status\r", lambda screen: rows(screen)[0].strip() == f"Status · {session}")
        chrome.frame(master, b"\x1b", lambda screen: latest(screen, "LONG-INPUT-INTACT"))
        once_in_order(transcript(chrome, master), START, "› XXXX", "LONG-INPUT-INTACT")
        chrome.leave(master, caller)
    print("session chrome: /status returns; a 5,000-character draft survives scrolling, is sent whole and shows from Enter; once in order", flush=True)


def main():
    one_call_case()
    one_capture_case()
    status_opens_case()
    status_follows_case()
    status_in_place_case()
    long_page_case()
    evicted_case()
    steered_case()
    queued_behind_answer_case()
    shared_page_case()
    stopped_many_case()
    opening_older_case()
    escaped_boundary_case()
    shortened_boundary_case()
    held_row_case()
    page_before_message_case()
    catch_up_case()
    persistent_input_case()
    long_input_case()
