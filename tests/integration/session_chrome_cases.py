"""The Session screen's chrome through a real terminal: the activity tail,
the last row, the `↓` marker, pages without a heading and the send state.

human_cli_integration.py runs these cases in its full and renderer modes, and
alone as `session-chrome`. Each case judges the screen the person sees, at
80×24 unless it says otherwise. Feed capacity and the permanently reserved
marker row come from the composer's rendered upper rule, not a fixed footer
height. The chat footer follows input; persistent state can take rows below
it. Short replies replace the Footer's right slot without adding a row.
Feed/page/activity rows have one gutter column; input, footer and state
retain their own margins."""
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
    assert_chat_info_layout,
    chat_content_row,
    chat_info_open,
    chat_info_geometry,
    footer_click,
    assert_model_choice,
    composer_line,
    composer_bounds,
    chat_footer_row,
    conversation_text,
    keyed_frame,
    model_choice_frame,
    model_choice_shown,
    run,
    settle_screen,
    terminal_capture,
    terminal_exit,
)
from terminal_process import close_pty, open_pty, spawn

ROWS = 24


def rows(screen):
    return screen.split("\n")


def feed_bottom(screen):
    """Reserved marker row, immediately above the rendered input's top rule."""
    bounds = composer_bounds(screen)
    assert bounds is not None, ("composer rules", screen)
    return bounds[0] - 1


def status(screen):
    """Persistent state only, below the chat's one facts/keys row."""
    return "\n".join(composer_line(screen, index) for index in range(chat_footer_row(screen) + 1, len(rows(screen)))).strip()


def footer(screen):
    return composer_line(screen, chat_footer_row(screen))


def transcript_rows(screen):
    """Content coordinates, excluding only the feed gutter, above the input."""
    return [chat_content_row(composer_line(screen, index)) for index in range(feed_bottom(screen) + 1)]


def tail_rows(screen):
    """The feed's final block, excluding the permanently reserved chip row.
    The activity tail is an entry in that same feed, not separate chrome."""
    shown = transcript_rows(screen)[:-1]
    start = max((n for n, row in enumerate(shown) if not row.strip()), default=-1) + 1
    return shown[start:]


def marker(screen):
    """The chip in its reserved row below the feed, or None."""
    shown = rows(screen)
    row = shown[feed_bottom(screen)].rstrip() if len(shown) == ROWS else ""
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

    def session(self, permission="bypass"):
        reply = json.loads(run(self.home, "session", "configure", "--workspace", self.workspace,
            "--provider", "codex", "--model", "gpt-6-sol", "--permission-mode", permission))
        return reply["answer"]["session"]

    def answered(self, session, *inputs):
        for text in inputs:
            message = admit(self.home, "session", "send", "--to", session, input=text)
            fixture.wait_for(lambda key=message["request"]: fixture.completed_observation(self.store, key), "saved answer")

    def open(self, session, ready, *, columns=80):
        master, slave = open_pty(columns, ROWS)
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
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors

    def detach(self, master, caller):
        os.write(master, b"\x03")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors

    def held_call(self, name, release):
        """A Bash call that runs until `release` exists in the Workspace."""
        return fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", json.dumps({
            "cmd": f"while [ ! -e {release} ]; do sleep 0.05; done; printf done",
            "description": name, "timeout_ms": None}))])


def composing(screen, draft):
    """The composer shows `draft` on its row between the rules."""
    shown = [composer_line(screen, index) for index in range(len(rows(screen)))]
    bounds = composer_bounds(screen)
    return (len(shown) == ROWS and bounds is not None and bounds[1] == bounds[0] + 2
            and shown[bounds[0] + 1].rstrip() == (" › " + draft).rstrip())


def latest(screen, text):
    return text in "\n".join(transcript_rows(screen)) and marker(screen) is None


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
            # Idle: no tail or stop key; the footer keeps the chat identity.
            idle = settle_screen(master, quiet=0.5)
            assert footer(idle).strip().startswith("‹ ") and "ctrl+x stop" not in footer(idle) and "⠹" not in idle, idle
            os.write(master, b"HOLD-QUESTION\r")
            release.set()
            running = chrome.frame(master, b"", lambda screen: "⠹ Held call · " in screen)
            # The activity block is the feed's final entry, directly after
            # the person's row; no blank separator owns a separate tail pane.
            bottom = feed_bottom(running)
            tail = transcript_rows(running)[bottom - 1:bottom]
            assert [line for line in transcript_rows(running)[:bottom] if line.startswith(("⠹", "◌"))] == tail, running
            assert tail == [tail[-1]] and tail[-1].startswith("⠹ Held call · "), running
            assert transcript_rows(running)[bottom - 1].startswith("⠹ Held call · ") and not rows(running)[bottom].strip(), running
            assert tail[-1].removeprefix("⠹ Held call · ").rstrip("s").isdigit(), running
            # At the right of the footer, beside the chat identity.
            last = footer(running)
            assert last.strip().startswith("‹ ") and last.endswith("ctrl+x stop") and len(last.rstrip()) == 80, running
            # Waiting Messages: one row, the newest's first line, counted, never called queued.
            for index in range(3):
                os.write(master, f"WAITING-{index}\nsecond line {index}\r".encode())
                count = f"{index + 1} · " if index else ""
                waiting = chrome.frame(master, b"", lambda screen, count=count, index=index:
                    f"◌ {count}WAITING-{index}" in screen and composing(screen, ""))
            bottom = feed_bottom(waiting)
            tail = transcript_rows(waiting)[bottom - 2:bottom]
            assert [line for line in transcript_rows(waiting)[:bottom] if line.startswith(("⠹", "◌"))] == tail, waiting
            assert tail[-2].startswith("⠹ Held call · ") and tail[-1] == "◌ 3 · WAITING-2", waiting
            assert transcript_rows(waiting)[bottom - 1] == "◌ 3 · WAITING-2" and not rows(waiting)[bottom].strip(), waiting
            assert "second line" not in waiting and "queued" not in waiting.lower(), waiting
            assert footer(waiting).endswith("ctrl+x stop"), waiting
            (chrome.workspace / "release").write_text("")
            # The waiting Messages join the turn when its call ends.
            done = chrome.frame(master, b"", lambda screen: "HELD-DONE" in screen
                and "◌" not in screen and "⠹" not in screen, timeout=30)
            assert footer(done).strip().startswith("‹ ") and "ctrl+x stop" not in footer(done), done
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
        assert status(cleared[0]) == "Sending…", cleared[0]
        seen = set()
        for frame in cleared:
            last, shown = status(frame), "\n".join(transcript_rows(frame))
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
            # An empty feed draws nothing new for a scroll key, so the next
            # frames come from typing after it and clearing that again.
            typed = chrome.frame(master, keys + b"x", lambda screen: composing(screen, "x"))
            assert marker(typed) is None and "Start of conversation" not in typed, typed
            unchanged = chrome.frame(master, b"\x15", lambda screen: composing(screen, ""))
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
        bottom = feed_bottom(end)
        assert not rows(end)[bottom].strip(), end
        for keys in (b"\x1b[1;2A", b"\x1b[5~"):
            # The chip has not stolen a row: every overlapping unique content
            # line moves by exactly half the feed height, not by half plus one.
            # Rows above the loaded ones join first, so judge the frame where
            # the whole move has landed.
            end_rows = rows(end)[:bottom]
            before = {line: n for n, line in enumerate(end_rows) if line.strip() and end_rows.count(line) == 1}

            def moved(screen):
                held_rows = rows(screen)[:feed_bottom(screen)]
                after = {line: n for n, line in enumerate(held_rows) if line.strip() and held_rows.count(line) == 1}
                shared = before.keys() & after.keys()
                return bool(shared) and all(after[line] - before[line] == bottom // 2 for line in shared)

            scrolled = chrome.frame(master, keys, lambda screen: marker(screen) == "↓" and moved(screen))
            assert "second row 07" not in scrolled and composing(scrolled, "keep"), (keys, scrolled)
            assert status(scrolled) == "" and footer(scrolled).strip().startswith("‹ "), (keys, "no heading or hint", scrolled)
            assert not any(row.startswith("Browsing") for row in transcript_rows(scrolled)), scrolled
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
            assert feed_bottom(live) == bottom, (end, live)
            # Scrolling can load earlier history into the initially blank
            # prefix. Every already loaded end row (including its gaps and
            # marker slot) must return at the identical coordinate.
            first_known = next(index for index, row in enumerate(end_rows) if row.strip())
            assert rows(live)[first_known:bottom + 1] == rows(end)[first_known:bottom + 1], (end, live)
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
        assert rows(counted)[:feed_bottom(counted)] == rows(held)[:feed_bottom(held)], (held, counted)
        assert composing(counted, ""), counted
        chrome.frame(master, b"\x1b", lambda screen: latest(screen, "ARRIVED-ANSWER"), timeout=30)
        chrome.leave(master, caller)
    print("session chrome: Shift-↑ and PgUp draw ↓, draft End keeps the view, ↓ N new counts arrivals, Ctrl-End and Esc return; empty PgUp is unchanged and the chip never changes feed height", flush=True)


def pages_case():
    """Chat info opens above the input and returns to the saved feed;
    the `↓` marker says more is below; Esc returns to the latest. A page
    opened while work runs substitutes its own footer; Esc restores the live
    stop hint without changing work."""
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
            chrome.frame(master, b"kept draft", lambda screen: composing(screen, "kept draft"))
            status = chat_info_open(master)
            assert "Folder" in status and "Model" in status, status
            assert not any(row.startswith("Browsing") for row in transcript_rows(status)), status
            # Folder is read-only: three Downs reach Model, not Folder.
            choice = model_choice_frame(master, b"\x1b[B\x1b[B\x1b[B\r", query="")
            assert "kept draft" in choice, choice
            assert_chat_info_layout(choice, context=True)
            chrome.frame(master, b"\x1b", lambda screen: not model_choice_shown(screen) and "Copy last answer" in screen)
            # Context, when present, is read-only: the next selectable row is Rename.
            chrome.frame(master, b"\x1b[B\rCANCELLED-NAME", lambda screen: "CANCELLED-NAME" in screen)
            chrome.frame(master, b"\x1b", lambda screen: "CANCELLED-NAME" not in screen and "Copy last answer" in screen)
            # Refused paste retains usable name bytes, then the same editor
            # recovers and submits without closing/reopening the Rename field.
            before_name = json.loads(run(chrome.home, "session", "inspect", "--store", chrome.store,
                                         "--session", session))["session"]["label"]
            chrome.frame(master, b"\rkept-name", lambda screen: "kept-name" in screen)
            refused = chrome.frame(master, b"\x1b[200~\xff\x1b[201~\r",
                                   lambda screen: "text couldn't be entered" in screen)
            assert "kept-name" in refused and "kept draft" in refused, refused
            assert json.loads(run(chrome.home, "session", "inspect", "--store", chrome.store,
                                  "--session", session))["session"]["label"] == before_name
            chrome.frame(master, b"\x01\x0bRecovered rename\r", lambda screen:
                         "Recovered rename" in screen and "saving" not in screen
                         and "text couldn't be entered" not in screen)
            assert json.loads(run(chrome.home, "session", "inspect", "--store", chrome.store,
                                  "--session", session))["session"]["label"] == "Recovered rename"
            # Feed and draft facts can already be visible behind natural-height
            # info. Wait for its close, not a tick before lone Esc is decoded.
            returned = chrome.frame(master, b"\x1b", lambda screen:
                                    latest(screen, "SEED-ANSWER") and composing(screen, "kept draft")
                                    and "Copy last answer" not in screen and "esc close" not in screen)
            assert "Copy last answer" not in returned and not model_choice_shown(returned), returned
            assert len(chrome.endpoint.requests) == 1, chrome.endpoint.requests
            chrome.frame(master, b"\x15", lambda screen: composing(screen, ""))
            chrome.frame(master, b"", lambda screen: latest(screen, "SEED-ANSWER"))
            os.write(master, b"HOLD-QUESTION\r")
            release.set()
            chrome.frame(master, b"", lambda screen: "⠹ Held call · " in screen)
            working = chat_info_open(master)
            assert rows(working)[-1].endswith("esc close"), working
            returned = chrome.frame(master, b"\x1b", lambda screen:
                                    "⠹ Held call · " in screen and marker(screen) is None
                                    and footer(screen).endswith("ctrl+x stop")
                                    and "esc close" not in screen)
            assert footer(returned).endswith("ctrl+x stop"), returned
            (chrome.workspace / "release").write_text("")
            chrome.frame(master, b"", lambda screen: latest(screen, "PAGES-DONE"), timeout=30)
            chrome.leave(master, caller)
        finally:
            release.set()
            (chrome.workspace / "release").write_text("")
    print("session chrome: chat info has one substituted footer; Esc returns its draft and the live work stop hint; Settings > Keys owns the shortcuts", flush=True)



def info_natural_height_case():
    """The actual feed donates only the rows the open info body needs."""
    answer = "\n".join(f"FEED-{index:02d}" for index in range(1, 25))
    with Chrome("rui-chrome-info-height.", [fixture.sse_answer("feed", "r", "m", answer)[0]]) as chrome:
        session = chrome.session()
        run(chrome.home, "session", "configure", "--store", chrome.store, "--session", session,
            "--label", "Natural height")
        chrome.answered(session, "Show the saved feed")
        for width, height in ((140, 40), (46, 30), (46, 18)):
            master, slave = open_pty(width, height)
            chrome.descriptors += [master, slave]
            caller = spawn([str(fixture.RUI), "session", "resume", "--", session],
                env={**os.environ, "HOME": str(chrome.home)}, cwd=str(chrome.workspace),
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            chrome.callers.append(caller)
            chrome.frame(master, b"", lambda screen: "FEED-24" in screen and "Opening…" not in screen)
            live = chrome.frame(master, b"kept draft", lambda screen:
                                "FEED-24" in screen and "kept draft" in screen)
            # Editable words open only their shared choice at every width;
            # the fitted model and effort, not a possibly dropped name, locate it.
            draft_row = next(index for index in range(height)
                             if composer_line(live, index).rstrip() == " › kept draft")
            for field, marker in (("Model", "gpt-6-sol"), ("Effort", "low")):
                choice = chrome.frame(master, footer_click(live, marker=marker),
                                      lambda screen, field=field: field in conversation_text(screen)
                                      and "✓" in conversation_text(screen))
                assert "kept draft" in choice and "FEED-24" in choice, choice
                assert "Copy last answer" not in choice and "Permissions" not in choice, choice
                assert composer_line(choice, draft_row) == composer_line(live, draft_row), (live, choice)
                live = chrome.frame(master, b"\x1b", lambda screen:
                                    "✓" not in conversation_text(screen) and "FEED-24" in screen and "kept draft" in screen)
            # Chat info remains available through its actual hint and Alt-I,
            # rather than treating every identity word as the same action.
            columns = [rows(live)[chat_footer_row(live)].index("alt+i")]
            opened = None
            for column in columns:
                opened = chrome.frame(master, footer_click(live, column=column),
                                      lambda screen: "Copy last answer" in screen and " · info" in screen and "unavailable" not in screen)
                assert_chat_info_layout(opened, context=True)
                base = chat_info_geometry(opened)
                if height >= 30:
                    assert base["top"] > 0 and any("FEED-" in row for row in base["feed"]), opened
                # A click on the substituted footer is safe and idempotent.
                chrome.frame(master, footer_click(opened, marker=" · info") + b"\x1b[B\r",
                             lambda screen: "ask first" in screen and "run without asking" in screen)
                clicked = chrome.frame(master, b"\x1b",
                                       lambda screen: "ask first" not in screen and "Copy last answer" in screen)
                chrome.frame(master, b"\x1b[A", lambda screen: "Copy last answer" in screen)
                assert chat_info_geometry(clicked) == base, clicked
                live = chrome.frame(master, b"\x1b", lambda screen:
                                    "Copy last answer" not in screen and "FEED-24" in screen and "kept draft" in screen)
            alt = chat_info_open(master)
            assert chat_info_geometry(alt) == base, (opened, alt)
            choice = model_choice_frame(master, b"\x1b[B\x1b[B\x1b[B\r", query="")
            grown = assert_model_choice(choice, query="")
            if height >= 30:
                expanded = chat_info_geometry(choice)
                growth = len(grown["matches"]) + (grown["more"] is not None)
                assert base["top"] - expanded["top"] == growth, (alt, choice)
                assert expanded["input"] == base["input"] and expanded["footer"] == base["footer"], choice
                assert any("FEED-" in row for row in expanded["feed"]), choice
                filtered = model_choice_frame(master, b"luna", query="luna", more=False)
                shrunk = assert_model_choice(filtered, query="luna", more=False)
                short = chat_info_geometry(filtered)
                assert len(shrunk["matches"]) == 2, filtered
                assert short["top"] - expanded["top"] == growth - 2, (choice, filtered)
                assert short["input"] == base["input"], filtered
            else:
                assert "kept draft" in choice and rows(choice)[-1].endswith("esc close"), choice
            closed = chrome.frame(master, b"\x1b", lambda screen:
                                  not model_choice_shown(screen) and "Copy last answer" in screen)
            assert chat_info_geometry(closed) == base, closed
            chrome.frame(master, b"\x1b", lambda screen:
                         "Copy last answer" not in screen and "FEED-24" in screen and "kept draft" in screen)
            chrome.leave(master, caller)
        assert len(chrome.endpoint.requests) == 1, chrome.endpoint.requests
    print("session chrome: natural-height info leaves saved feed above; Model grows/shrinks by its rows; model/effort clicks keep feed and draft; the info hint and Alt-I share one transition", flush=True)


def approval_overflow_case():
    """A clipped request reports its omitted rows; both open gestures reveal
    them in the same panel, keeping the decision and any draft intact."""
    with Chrome("rui-chrome-approval-overflow.", []) as chrome:
        for count in (40, 3):
            session = chrome.session(permission="ask")
            command = "\n".join(f"printf step-{index:02d}" for index in range(count))
            chrome.endpoint.responses.append(fixture.sse_tool_calls(f"steps-{count}", [
                ("bash", f"steps-{count}-call", json.dumps({
                    "cmd": command, "description": "Review all steps", "timeout_ms": None}))]))
            request = admit(chrome.home, "session", "send", "--to", session, input="Review these steps")["request"]
            fixture.wait_for(lambda: fixture.observe(chrome.store, request)["state"] == "waiting_for_permission", "pending request")
            for width, height in ((140, 40), (46, 30)):
                for click in (False, True):
                    master, slave = open_pty(width, height)
                    chrome.descriptors += [master, slave]
                    caller = spawn([str(fixture.RUI), "session", "resume", "--", session],
                        env={**os.environ, "HOME": str(chrome.home)}, cwd=str(chrome.workspace),
                        stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                    chrome.callers.append(caller)
                    shown = chrome.frame(master, b"", lambda screen: "Allow once" in screen and "Deny" in screen)
                    if count == 3:
                        assert "step-02" in shown and "more lines" not in shown, shown
                        chrome.detach(master, caller)
                        continue
                    assert "more lines" in shown and "step-39" not in shown, shown
                    assert "shift+" not in shown, shown
                    # The draft stays the input when a continuation is opened.
                    shown = chrome.frame(master, b"kept draft", lambda screen: "kept draft" in screen)
                    if click:
                        row, line = next((index, line) for index, line in enumerate(rows(shown)) if "more lines" in line)
                        col = line.rindex("…") + 1
                        gesture = f"\x1b[<0;{col};{row + 1}M\x1b[<0;{col};{row + 1}m".encode()
                    else:
                        gesture = b"\x0f"
                    opened = chrome.frame(master, gesture, lambda screen: "step-39" in screen)
                    assert "kept draft" in opened and "more lines" not in opened, opened
                    assert fixture.observe(chrome.store, request)["state"] == "waiting_for_permission"
                    chrome.detach(master, caller)
    print("session chrome: clipped approvals report remaining rows; Ctrl-O and a click open them in place at both sizes, preserving the draft; fitting requests have no overflow state", flush=True)


def opening_case():
    """A Session reopened while Messages wait shows them as one counted
    `◌ N · <newest>` row; Ctrl-O opens the lowest tool or collapsed Message, and Esc
    returns from the Message page to the transcript."""
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
            assert footer(opened).endswith("ctrl+x stop"), opened
            (chrome.workspace / "release").write_text("")
            chrome.frame(master, b"", lambda screen: latest(screen, "HELD-DONE") and "◌" not in screen, timeout=30)
            chrome.leave(master, caller)
            master, caller, reopened = chrome.open(session, lambda screen: "HELD-DONE" in screen)
            assert "    done" not in reopened, reopened
            folded = chrome.frame(master, b"\x1b[5~\x1b[5~", lambda screen: "┄ 38 more lines" in screen)
            # The newer tool is below the old Message. Ctrl-O therefore opens
            # the tool, and only this key—not reopening the Session—opens it.
            tool = chrome.frame(master, b"\x0f", lambda screen: "    done" in screen)
            assert "Message · 40 lines" not in tool, tool
            chrome.frame(master, b"\x0f", lambda screen: "    done" not in screen)
            chrome.leave(master, caller)
            # Now put the long Message below the tool so the same nearest-in-
            # view rule selects the Message, rather than assuming tools lose.
            chrome.endpoint.responses.append(fixture.sse_answer("later-long", "r", "m", "LATER-LONG-ANSWER")[0])
            chrome.answered(session, long_text)
            master, caller, reopened = chrome.open(session, lambda screen: "LATER-LONG-ANSWER" in screen and "┄ 38 more lines" in screen)
            assert "    done" not in reopened, reopened
            whole = chrome.frame(master, b"\x0f", lambda screen: transcript_rows(screen)[0].startswith("Message · 40 lines"))
            assert "LONG line 11" in whole and marker(whole) == "↓", whole
            chrome.frame(master, b"\x1b", lambda screen: "Message · 40 lines" not in screen)
            chrome.leave(master, caller)
            assert folded
        finally:
            release.set()
            (chrome.workspace / "release").write_text("")
    print("session chrome: a reopened Session shows ◌ 2 · the newest waiting Message under the running call; Ctrl-O selects the lowest tool or Message, and reopening keeps tools folded", flush=True)


def keys_case():
    """Settings > Keys is inert and Esc closes only the topmost layer."""
    with Chrome("rui-chrome-keys.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses.append(fixture.sse_answer("keys", "r", "m", "KEYS-ANSWER")[0])
        chrome.answered(session, "keys")
        for width in (140, 46):
            master, caller, shown = chrome.open(session, lambda screen: "KEYS-ANSWER" in screen, columns=width)
            if width == 140:
                # The pinned list remains beside the chat: open Settings
                # without leaving the conversation or touching its draft.
                row, line = next((index, line) for index, line in enumerate(rows(shown)) if "Settings" in line)
                col = line.index("Settings") + 1
                gesture = f"\x1b[<0;{col};{row + 1}M\x1b[<0;{col};{row + 1}m".encode()
            else:
                chrome.frame(master, b"\x1b", lambda screen: "Settings" in screen and not any(line.startswith(" ‹ ") for line in rows(screen)))
                gesture = b"\x1b[F\r"
            chrome.frame(master, gesture, lambda screen: "Notifications" in screen and "Version" in screen)
            keys = chrome.frame(master, b"\x1b[B" * 6 + b"\r", lambda screen: "earlier message" in screen)
            expected = (
                ("enter", "send"), ("esc", "back"), ("⇧enter", "new line"),
                ("tab", "next footer field"), ("⇧tab", "previous footer field"),
                ("ctrl+x", "stop"), ("↑↓", "scroll"), ("ctrl+o", "tool output"),
                ("ctrl+p", "earlier message"), ("ctrl+r", "retry"),
                ("/", "skills"), ("alt+a", "archive"), ("ctrl+c", "leave"),
            )
            # Judge actual row-major content independently of padding. The
            # shared KeyList aligns each column after its widest key; a longer
            # meaning (such as previous footer field) expands the left column.
            columns = 2 if width == 140 else 1
            key_widths = [max(len(key) for key, _ in expected[column::columns])
                          for column in range(columns)]
            pane_rows = conversation_text(keys).split("\n")
            positions = [[] for _ in range(columns)]
            for start in range(0, len(expected), columns):
                entries = expected[start:start + columns]
                line = pane_rows[start // columns]
                assert line.split() == [word for key, meaning in entries
                                        for word in (key + " " + meaning).split()], (width, start, keys)
                after = 0
                for column, (key, meaning) in enumerate(entries):
                    label = line.index(key, after)
                    value = line.index(meaning, label + len(key))
                    positions[column].append((label, value))
                    assert value - label == key_widths[column] + 3, (width, key, keys)
                    after = value + len(meaning)
            for column in positions:
                assert len(set(column)) == 1, (width, positions, keys)
            assert positions[0][0][0] == 0, keys
            used_rows = (len(expected) + columns - 1) // columns
            assert all(not line.strip() for line in pane_rows[used_rows:]), keys
            for absent in ("/help", "Ctrl-X twice", "shift+enter or ctrl+j", "Commands", "Marks", "Esc returns", "↑↓ · enter change · esc close", "‹ Rui · settings", 'ctrl+g', 'ctrl+d', 'ctrl+n', 'ctrl+end', 'ctrl+c/d', 'pgup/pgdn', 'first session', 'latest / last', 'scroll / select'):
                assert absent not in keys, (width, absent, keys)
            # Enter and typing do not edit a setting or the hidden draft.
            settings = chrome.frame(master, b"\rx\x1b", lambda screen: "Notifications" in screen and "Version" in screen)
            assert "earlier message" not in settings, settings
            if width == 140:
                chrome.frame(master, b"\x1b", lambda screen:
                             latest(screen, "KEYS-ANSWER") and composing(screen, "")
                             and "Rui · settings" not in screen)
            else:
                chrome.frame(master, b"\x1b", lambda screen: "Settings" in screen and "Rui · settings" not in screen and not any(line.startswith(" ‹ ") for line in rows(screen)))
            chrome.leave(master, caller)
    print("session chrome: Settings > Keys has thirteen aligned entries including Tab and Shift+Tab, paired at 140 columns and one column at 46; Enter/text are inert and Esc returns one layer, preserving a wide conversation", flush=True)


def notice_case():
    """A notice replaces the Footer's right slot until the next key; question
    marks are ordinary draft text, even on an empty draft."""
    with Chrome("rui-chrome-notice.", []) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        unknown = chrome.frame(master, b"/nosuch\r", lambda screen: footer(screen).endswith("! Unknown command /nosuch"))
        assert composing(unknown, ""), unknown
        gone = chrome.frame(master, b"a", lambda screen: composing(screen, "a"))
        assert status(gone) == "" and "Unknown command" not in footer(gone) and footer(gone).strip().startswith("‹ "), gone
        os.write(master, b"\x15")
        chrome.frame(master, b"", lambda screen: composing(screen, ""))
        question = chrome.frame(master, b"?", lambda screen: composing(screen, "?"))
        assert "shift+enter or ctrl+j" not in question, question
        questions = chrome.frame(master, b"?", lambda screen: composing(screen, "??"))
        assert "shift+enter or ctrl+j" not in questions, questions
        chrome.leave(master, caller)
    print("session chrome: a notice goes at the next key; ? is ordinary text on empty and nonempty drafts", flush=True)


def main():
    send_state_case()
    activity_case()
    scroll_marker_case()
    pages_case()
    info_natural_height_case()
    approval_overflow_case()
    opening_case()
    notice_case()
    keys_case()
