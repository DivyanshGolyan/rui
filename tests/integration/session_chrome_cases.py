"""The Session screen's chrome through a real terminal: the activity tail,
the last row, the `↓` marker, pages without a heading and the send state.

human_cli_integration.py runs these cases in its full and renderer modes, and
alone as `session-chrome`. Each case judges the screen the person sees, at
80×24 unless it says otherwise: the feed fills rows 0–17, row 18 is
reserved for the marker even at the end, and the input sits
between the rules on rows 19–21, the facts row is 22 and the last row 23."""
import json
import os
import select
import shutil
import subprocess
import threading
import time

import model_fixture as fixture
from host_process import dispose_all, screen_fixture_root, stop_process
from human_cli_fixture import (
    admit,
    keyed_frame,
    run,
    settle_screen,
    terminal_capture,
    terminal_exit,
)
from terminal_process import close_pty, open_pty, spawn

ROWS = 24
BOTTOM = ROWS - 6  # The permanently reserved marker row below the feed.
LAST = ROWS - 1


def rows(screen):
    return screen.split("\n")


def tail_rows(screen):
    """The feed's final block, excluding the permanently reserved chip row.
    The activity tail is an entry in that same feed, not separate chrome."""
    shown = rows(screen)[:BOTTOM]
    start = max((n for n, row in enumerate(shown) if not row.strip()), default=-1) + 1
    return shown[start:]


def marker(screen):
    """The chip in its reserved row below the feed, or None."""
    shown = rows(screen)
    row = shown[BOTTOM].rstrip() if len(shown) == ROWS else ""
    if row.endswith(" new") and "↓ " in row:
        return row[row.rindex("↓ "):]
    return "↓" if row.endswith("↓") else None


class Chrome:
    """One Host, Store and endpoint; Sessions opened in their own PTYs."""

    def __init__(self, prefix, responses):
        self.state = screen_fixture_root(prefix)
        self.home = self.state / "home"
        self.home.mkdir(mode=0o700)
        self.store = self.state / "store"
        self.workspace = self.state / "workspace"
        self.workspace.mkdir()
        self.endpoint = fixture.SuccessEndpoint(responses)
        self.thread = threading.Thread(target=self.endpoint.serve_forever, daemon=True)
        self.thread.start()
        self.host = None
        self.callers = []
        self.descriptors = []

    def __enter__(self):
        self.host = fixture.start_host(self.store, f"http://127.0.0.1:{self.endpoint.server_port}/responses")
        run(self.home, "defaults", "configure", "--store", self.store)
        return self

    def __exit__(self, kind, value, traceback):
        dispose_all(
            *(lambda caller=caller: stop_process(caller, timeout=5) for caller in self.callers),
            *(lambda fd=fd: close_pty(fd) for fd in self.descriptors),
            lambda: fixture.stop_host(self.host) if self.host is not None else None,
            self.endpoint.shutdown, self.endpoint.server_close, lambda: self.thread.join(timeout=5),
        )
        if kind is None:
            shutil.rmtree(self.state)

    def session(self):
        reply = json.loads(run(self.home, "session", "configure", "--workspace", self.workspace,
            "--provider", "codex", "--model", "gpt-6-sol", "--permission-mode", "bypass"))
        return reply["answer"]["session"]

    def answered(self, session, *inputs):
        for text in inputs:
            message = admit(self.home, "session", "send", "--to", session, input=text)
            fixture.wait_for(lambda key=message["request"]: fixture.completed_observation(self.store, key), "saved answer")

    def open(self, session, ready):
        master, slave = open_pty(80, ROWS)
        self.descriptors += [master, slave]
        caller = spawn([str(fixture.RUI), "session", "resume", "--", session],
            env={**os.environ, "HOME": str(self.home)}, cwd=str(self.workspace),
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        self.callers.append(caller)
        # Ready as human_cli_fixture.composer_ready is: the opening read done.
        screen = self.frame(master, b"", lambda screen: ready(screen) and composing(screen, "") and "Opening…" not in screen)
        return master, caller, screen

    def frame(self, master, keys, accept, timeout=15):
        return keyed_frame(master, keys, lambda screen, x, y: accept(screen), timeout)

    def leave(self, master, caller):
        os.write(master, b"\x15/exit\r")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors

    def held_call(self, name, release):
        """A Bash call that runs until `release` exists in the Workspace."""
        return fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", json.dumps({
            "cmd": f"while [ ! -e {release} ]; do sleep 0.05; done; printf done",
            "description": name, "timeout_ms": None}))])


def composing(screen, draft):
    """The composer shows `draft` on its row between the rules."""
    shown = rows(screen)
    return len(shown) == ROWS and (set(shown[ROWS - 5]) == {"─"} and set(shown[ROWS - 3]) == {"─"}
            and shown[ROWS - 4].rstrip() == (" › " + draft).rstrip())


def latest(screen, text):
    return text in "\n".join(rows(screen)[:BOTTOM + 1]) and marker(screen) is None


def frames_until(master, keys, accept, timeout=15):
    """Every frame committed after `keys`, through the first that `accept`s.
    One read can commit several frames; the newest hides the ones before."""
    capture = terminal_capture(master)
    frames = []
    capture.listener = lambda screen, x, y: frames.append(screen)
    try:
        os.write(master, keys)
        deadline = time.monotonic() + timeout
        while not any(accept(frame) for frame in frames):
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([master], [], [], remaining)[0], ("frames", keys, capture.completed)
            chunk = os.read(master, 65536)
            assert chunk, ("terminal closed", keys)
            capture.feed(chunk)
    finally:
        capture.listener = None
    return frames


def activity_case():
    """Work under way shows at the transcript's tail and on the last row:
    one row per running call with its clock, the waiting Messages as one
    `◌ [N ·] <newest>` row under them, and `ctrl+x stop` at the right of the
    last row. When the work ends, each waiting Message is its own row once,
    in order, and the tail and the stop key go."""
    release = threading.Event()
    with Chrome("rui-chrome-activity.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            fixture.sse_answer("seed", "r", "m", "SEED-ANSWER")[0],
            (fixture.ResponseSpec(chrome.held_call("Held call", "release"), {}), release),
            fixture.sse_answer("held-after", "r", "m", "HELD-DONE")[0],
        ]
        chrome.answered(session, "seed")
        master, caller, _ = chrome.open(session, lambda screen: "SEED-ANSWER" in screen)
        try:
            # Idle: no tail, nothing on the last row.
            idle = settle_screen(master, quiet=0.5)
            assert rows(idle)[LAST].strip() == "" and "⠹" not in idle, idle
            os.write(master, b"HOLD-QUESTION\r")
            release.set()
            running = chrome.frame(master, b"", lambda screen: "⠹ Held call · " in screen)
            # The activity block is the feed's final entry, directly after
            # the person's row; no blank separator owns a separate tail pane.
            tail = rows(running)[BOTTOM - 1:BOTTOM]
            assert [line for line in rows(running)[:BOTTOM] if line.startswith(("⠹", "◌"))] == tail, running
            assert tail == [tail[-1]] and tail[-1].startswith("⠹ Held call · "), running
            assert rows(running)[BOTTOM - 1].startswith("⠹ Held call · ") and not rows(running)[BOTTOM].strip(), running
            assert tail[-1].removeprefix("⠹ Held call · ").rstrip("s").isdigit(), running
            # Alone at the right of the last row, inside its one-column margin.
            last = rows(running)[LAST]
            assert last.strip() == "ctrl+x stop" and len(last.rstrip()) == 79, running
            # Waiting Messages: one row, the newest's first line, counted, never called queued.
            for index in range(3):
                os.write(master, f"WAITING-{index}\nsecond line {index}\r".encode())
                count = f"{index + 1} · " if index else ""
                waiting = chrome.frame(master, b"", lambda screen, count=count, index=index:
                    f"◌ {count}WAITING-{index}" in screen and composing(screen, ""))
            tail = rows(waiting)[BOTTOM - 2:BOTTOM]
            assert [line for line in rows(waiting)[:BOTTOM] if line.startswith(("⠹", "◌"))] == tail, waiting
            assert tail[-2].startswith("⠹ Held call · ") and tail[-1] == "◌ 3 · WAITING-2", waiting
            assert rows(waiting)[BOTTOM - 1] == "◌ 3 · WAITING-2" and not rows(waiting)[BOTTOM].strip(), waiting
            assert "second line" not in waiting and "queued" not in waiting.lower(), waiting
            assert rows(waiting)[LAST].endswith("ctrl+x stop"), waiting
            (chrome.workspace / "release").write_text("")
            # The waiting Messages join the turn when its call ends.
            done = chrome.frame(master, b"", lambda screen: "HELD-DONE" in screen
                and "◌" not in screen and "⠹" not in screen, timeout=30)
            assert rows(done)[LAST].strip() == "", done
            # Each waiting Message is its own row once, in the order sent.
            order = [done.count(f"› WAITING-{i}") for i in range(3)]
            assert order == [1, 1, 1], done
            assert done.index("› WAITING-0") < done.index("› WAITING-1") < done.index("› WAITING-2"), done
            chrome.leave(master, caller)
        finally:
            release.set()
            (chrome.workspace / "release").write_text("")
    print("session chrome: the running call and its clock, ◌ 3 · the newest waiting Message, ctrl+x stop; each Message its row once after", flush=True)


def send_state_case():
    """The frame that clears the composer already says `Sending…`, and every
    frame after it shows `Sending…` or an empty status bar until the
    Message's own row shows. The status bar never says `Sent`."""
    with Chrome("rui-chrome-send.", [fixture.sse_answer("sent", "r", "m", "SENT-ANSWER")[0]]) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        os.write(master, b"SEND-ME")
        chrome.frame(master, b"", lambda screen: composing(screen, "SEND-ME"))
        frames = frames_until(master, b"\r", lambda screen: "SENT-ANSWER" in screen)
        cleared = [frame for frame in frames if composing(frame, "")]
        assert cleared, frames
        assert rows(cleared[0])[LAST] == "Sending…", cleared[0]
        seen = set()
        for frame in cleared:
            last, shown = rows(frame)[LAST].strip(), "\n".join(rows(frame)[:BOTTOM + 1])
            seen.add(last)
            if "› SEND-ME" in shown:
                break
            assert last in ("Sending…", ""), ("the status bar said something else", frame)
        assert {"Sending…"} <= seen, seen
        chrome.leave(master, caller)
    print("session chrome: Enter's clearing frame says Sending…, and nothing says Sent before the Message's row shows", flush=True)


def scroll_marker_case():
    """Shift-↑ and PgUp move the feed anchor by half a screen. The reserved
    chip row shows `↓`, then `↓ N new` as entries arrive below. Esc returns
    to the identical end frame. Empty feeds cannot scroll or show a chip;
    scrolling never edits or sends the draft or changes the feed height."""
    release = threading.Event()
    with Chrome("rui-chrome-scroll.", []) as chrome:
        empty = chrome.session()
        master, caller, opened = chrome.open(empty, lambda screen: True)
        for keys in (b"\x1b[1;2A", b"\x1b[5~"):
            unchanged = chrome.frame(master, keys, lambda screen: composing(screen, ""))
            assert marker(unchanged) is None and "Start of conversation" not in unchanged, unchanged
            assert rows(unchanged) == rows(opened), (opened, unchanged)
        chrome.leave(master, caller)

        session = chrome.session()
        chrome.endpoint.responses += [
            *[fixture.sse_answer(f"seed-{i}", "r", "m", f"answer {i:02d}\n\nsecond row {i:02d}")[0] for i in range(8)],
            (fixture.ResponseSpec(chrome.held_call("Held call", "release"), {}), release),
            fixture.sse_answer("arrived", "r", "m", "ARRIVED-ANSWER")[0],
        ]
        chrome.answered(session, *(f"input {i:02d}" for i in range(8)))
        master, caller, _ = chrome.open(session, lambda screen: "second row 07" in screen)
        requests = len(chrome.endpoint.requests)
        os.write(master, b"keep")
        end = chrome.frame(master, b"", lambda screen: composing(screen, "keep"))
        assert not rows(end)[BOTTOM].strip(), end
        for keys in (b"\x1b[1;2A", b"\x1b[5~"):
            scrolled = chrome.frame(master, keys, lambda screen: marker(screen) == "↓")
            assert "second row 07" not in scrolled and composing(scrolled, "keep"), (keys, scrolled)
            assert rows(scrolled)[LAST].strip() == "", (keys, "no heading or hint", scrolled)
            assert not any(row.startswith("Browsing") for row in rows(scrolled)), scrolled
            # The chip has not stolen a row: every overlapping unique content
            # line moves by exactly half the feed height, not by half plus one.
            end_rows, held_rows = rows(end)[:BOTTOM], rows(scrolled)[:BOTTOM]
            before = {line: n for n, line in enumerate(end_rows) if line.strip() and end_rows.count(line) == 1}
            after = {line: n for n, line in enumerate(held_rows) if line.strip() and held_rows.count(line) == 1}
            shared = before.keys() & after.keys()
            assert shared, (end, scrolled)
            assert all(after[line] - before[line] == BOTTOM // 2 for line in shared), (end, scrolled)
            # End edits this nonempty draft without moving the feed. Empty-
            # draft End and Ctrl-End delegate to the conversation's end action.
            # Older pages may still join above; judge the settled view.
            scrolled = settle_screen(master, quiet=0.5)
            os.write(master, b"\x1b[F")
            same = settle_screen(master, quiet=0.5)
            assert marker(same) == "↓" and rows(same)[:2] == rows(scrolled)[:2], (keys, same)
            back = b"\x1b[1;5F" if keys == b"\x1b[1;2A" else b"\x1b"
            live = chrome.frame(master, back, lambda screen: latest(screen, "second row 07"))
            assert composing(live, "keep"), live
            assert rows(live)[:BOTTOM + 1] == rows(end)[:BOTTOM + 1], (end, live)
        assert len(chrome.endpoint.requests) == requests, "scrolling sent input"
        # Work arrives below a scrolled-back view: the marker counts it.
        os.write(master, b"\x15HOLD-QUESTION\r")
        release.set()
        chrome.frame(master, b"", lambda screen: "⠹ Held call · " in screen)
        held = chrome.frame(master, b"\x1b[1;2A", lambda screen: marker(screen) == "↓")
        (chrome.workspace / "release").write_text("")
        counted = chrome.frame(master, b"", lambda screen: (marker(screen) or "").endswith(" new"), timeout=30)
        assert marker(counted)[2:-4].isdigit() and int(marker(counted)[2:-4]) >= 1, counted
        assert "ARRIVED-ANSWER" not in counted, counted
        assert rows(counted)[:BOTTOM] == rows(held)[:BOTTOM], (held, counted)
        assert composing(counted, ""), counted
        chrome.frame(master, b"\x1b", lambda screen: latest(screen, "ARRIVED-ANSWER"), timeout=30)
        chrome.leave(master, caller)
    print("session chrome: Shift-↑ and PgUp draw ↓, draft End keeps the view, ↓ N new counts arrivals, Ctrl-End and Esc return; empty PgUp is unchanged and the chip never changes feed height", flush=True)


def pages_case():
    """/status and /help open as Transcript pages with no heading over them;
    the `↓` marker says more is below; Esc returns to the latest. A page
    opened while work runs keeps the stop key on the last row."""
    release = threading.Event()
    with Chrome("rui-chrome-pages.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            fixture.sse_answer("seed", "r", "m", "SEED-ANSWER")[0],
            (fixture.ResponseSpec(chrome.held_call("Held call", "release"), {}), release),
            fixture.sse_answer("done", "r", "m", "PAGES-DONE")[0],
        ]
        chrome.answered(session, "seed")
        master, caller, _ = chrome.open(session, lambda screen: "SEED-ANSWER" in screen)
        try:
            status = chrome.frame(master, b"/status\r", lambda screen: rows(screen)[0].strip() == f"Status · {session}")
            assert marker(status) == "↓" and composing(status, ""), status
            assert not any(row.startswith("Browsing") for row in rows(status)), status
            chrome.frame(master, b"\x1b", lambda screen: latest(screen, "SEED-ANSWER"))
            help_page = chrome.frame(master, b"/help\r", lambda screen: rows(screen)[0] == "Marks")
            assert "ctrl+x                 stop" in help_page and "shift+↑↓               scroll" in help_page, help_page
            assert "ctrl+o                 open" in help_page and marker(help_page) == "↓", help_page
            chrome.frame(master, b"\x1b", lambda screen: latest(screen, "SEED-ANSWER"))
            os.write(master, b"HOLD-QUESTION\r")
            release.set()
            chrome.frame(master, b"", lambda screen: "⠹ Held call · " in screen)
            working = chrome.frame(master, b"/status\r", lambda screen: rows(screen)[0].strip() == f"Status · {session}")
            assert rows(working)[LAST].endswith("ctrl+x stop"), working
            chrome.frame(master, b"\x1b", lambda screen: "⠹ Held call · " in screen and marker(screen) is None)
            (chrome.workspace / "release").write_text("")
            chrome.frame(master, b"", lambda screen: latest(screen, "PAGES-DONE"), timeout=30)
            chrome.leave(master, caller)
        finally:
            release.set()
            (chrome.workspace / "release").write_text("")
    print("session chrome: /status and /help open as pages with ↓ and no heading, Esc returns; a page during work keeps ctrl+x stop", flush=True)


def opening_case():
    """A Session reopened while Messages wait shows them as one counted
    `◌ N · <newest>` row; a collapsed Message opens with Ctrl-O, and Esc
    returns to the transcript."""
    release = threading.Event()
    long_text = "\n".join(f"LONG line {i:02d}" for i in range(40))
    with Chrome("rui-chrome-opening.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses += [
            fixture.sse_answer("long", "r", "m", "LONG-ANSWER")[0],
            (fixture.ResponseSpec(chrome.held_call("Held call", "release"), {}), release),
            fixture.sse_answer("held-after", "r", "m", "HELD-DONE")[0],
        ]
        chrome.answered(session, long_text)
        try:
            admit(chrome.home, "session", "send", "--to", session, input="HOLD-QUESTION")
            release.set()
            fixture.wait_for(lambda: len(chrome.endpoint.requests) >= 2, "held request", timeout=20)
            for index in range(2):
                admit(chrome.home, "session", "send", "--to", session, input=f"WAITING-{index}")
            master, caller, opened = chrome.open(session, lambda screen: "◌ 2 · WAITING-1" in screen and "⠹ Held call · " in screen)
            tail = tail_rows(opened)
            assert tail[-2].startswith("⠹ Held call · ") and tail[-1] == "◌ 2 · WAITING-1", opened
            assert rows(opened)[LAST].endswith("ctrl+x stop"), opened
            (chrome.workspace / "release").write_text("")
            chrome.frame(master, b"", lambda screen: latest(screen, "HELD-DONE") and "◌" not in screen, timeout=30)
            chrome.leave(master, caller)
            master, caller, _ = chrome.open(session, lambda screen: "HELD-DONE" in screen)
            folded = chrome.frame(master, b"\x1b[5~\x1b[5~", lambda screen: "┄ 38 more lines" in screen)
            whole = chrome.frame(master, b"\x0f", lambda screen: rows(screen)[0].startswith("Message · 40 lines"))
            assert "LONG line 11" in whole and marker(whole) == "↓", whole
            chrome.frame(master, b"\x1b", lambda screen: "Message · 40 lines" not in screen)
            chrome.leave(master, caller)
            assert folded
        finally:
            release.set()
            (chrome.workspace / "release").write_text("")
    print("session chrome: a reopened Session shows ◌ 2 · the newest waiting Message under the running call; Ctrl-O opens a collapsed Message", flush=True)


def notice_case():
    """A notice shows on the last row until the next key; `?` on an empty
    draft shows the shortcuts and the next key closes them."""
    with Chrome("rui-chrome-notice.", []) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        unknown = chrome.frame(master, b"/nosuch\r", lambda screen: rows(screen)[LAST].startswith("! Unknown command /nosuch"))
        assert composing(unknown, ""), unknown
        gone = chrome.frame(master, b"a", lambda screen: composing(screen, "a"))
        assert rows(gone)[LAST].strip() == "", gone
        os.write(master, b"\x15")
        chrome.frame(master, b"", lambda screen: composing(screen, ""))
        shortcuts = chrome.frame(master, b"?", lambda screen: "shift+enter or ctrl+j new line" in screen)
        assert composing(shortcuts, ""), shortcuts
        closed = chrome.frame(master, b"x", lambda screen: composing(screen, "x"))
        assert "shift+enter or ctrl+j" not in closed, closed
        chrome.leave(master, caller)
    print("session chrome: a notice goes at the next key; ? shows the shortcuts and the next key closes them", flush=True)


def main():
    send_state_case()
    activity_case()
    scroll_marker_case()
    pages_case()
    opening_case()
    notice_case()
