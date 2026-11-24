from terminal_screen import VERTICAL_DIVIDER
import json
import os
import select
import shutil
import subprocess
import threading
import time

import model_fixture as fixture
import canonical_fixture
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
    bounds = composer_bounds(screen)
    assert bounds is not None, ("composer rules", screen)
    return bounds[0] - 1


def status(screen):
    return "\n".join(composer_line(screen, index) for index in range(chat_footer_row(screen) + 1, len(rows(screen)))).strip()


def footer(screen):
    return composer_line(screen, chat_footer_row(screen))


def transcript_rows(screen):
    return [chat_content_row(composer_line(screen, index)) for index in range(feed_bottom(screen) + 1)]


def tail_rows(screen):
    shown = transcript_rows(screen)[:-1]
    start = max((n for n, row in enumerate(shown) if not row.strip()), default=-1) + 1
    return shown[start:]


def marker(screen):
    shown = rows(screen)
    row = shown[feed_bottom(screen)].rstrip() if len(shown) == ROWS else ""
    if row.endswith(" new") and "↓ " in row:
        return row[row.rindex("↓ "):]
    return "↓" if row.endswith("↓") else None


class Chrome:

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

    def session(self, permission="bypass", model="gpt-6-sol"):
        flags = ("--reasoning-effort", "high") if model == "gpt-6.1-terra" else ()
        reply = json.loads(private_chrome_command(self, "session", "configure", "--store", self.store,
            "--workspace", self.workspace, "--provider", "codex", "--model", model, "--permission-mode", permission, *flags))
        return reply["answer"]["session"]

    def answered(self, session, *inputs):
        for text in inputs:
            message = admit(self.home, "session", "send", "--session", session, input=text)
            fixture.wait_for(lambda key=message["request"]: fixture.completed_observation(self.store, key), "saved answer")

    def open(self, session, ready, *, columns=80, height=ROWS):
        master, slave = open_pty(columns, height)
        self.descriptors += [master, slave]
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("RUI_STORE", "RUI_ADDRESS", "RUI_SENDER_HANDLE")}
        environment["HOME"] = str(self.home)
        caller = spawn([str(fixture.RUI), "session", "resume", "--store", str(self.store), "--", session],
            env=environment, cwd=str(self.workspace),
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        self.callers.append(caller)
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
        return fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", json.dumps({
            "cmd": f"while [ ! -e {release} ]; do sleep 0.05; done; printf done",
            "description": name, "timeout_ms": None}))])


def composing(screen, draft):
    shown = [composer_line(screen, index) for index in range(len(rows(screen)))]
    bounds = composer_bounds(screen)
    expected = {(" › " + draft).rstrip()}
    if not draft:
        expected.add(" › What shall we work on?")
    return (bounds is not None and bounds[1] == bounds[0] + 2
            and shown[bounds[0] + 1].rstrip() in expected)


def latest(screen, text):
    return text in "\n".join(transcript_rows(screen)) and marker(screen) is None


def frames_until(master, keys, accept, timeout=15):
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
            idle = settle_screen(master, quiet=0.5)
            assert footer(idle).strip().startswith("‹ ") and "ctrl+x stop" not in footer(idle) and "◝" not in idle, idle
            os.write(master, b"HOLD-QUESTION\r")
            release.set()
            running = chrome.frame(master, b"", lambda screen: "◝ Held call · " in screen)
            bottom = feed_bottom(running)
            tail = transcript_rows(running)[bottom - 1:bottom]
            assert [line for line in transcript_rows(running)[:bottom] if line.startswith(("◝", "◌"))] == tail, running
            assert tail == [tail[-1]] and tail[-1].startswith("◝ Held call · "), running
            assert transcript_rows(running)[bottom - 1].startswith("◝ Held call · ") and not rows(running)[bottom].strip(), running
            assert tail[-1].removeprefix("◝ Held call · ").rstrip("s").isdigit(), running
            last = footer(running)
            assert last.strip().startswith("‹ ") and last.endswith("ctrl+x stop") and len(last.rstrip()) == 80, running
            for index in range(3):
                os.write(master, f"WAITING-{index}\nsecond line {index}\r".encode())
                count = f"{index + 1} · " if index else ""
                waiting = chrome.frame(master, b"", lambda screen, count=count, index=index:
                    f"◌ {count}WAITING-{index}" in screen and composing(screen, "")
                    and all(f"› WAITING-{i}" not in screen
                        and f"second line {i}" not in screen for i in range(index + 1)))
                assert "Sending" not in waiting, waiting
            bottom = feed_bottom(waiting)
            tail = transcript_rows(waiting)[bottom - 2:bottom]
            assert [line for line in transcript_rows(waiting)[:bottom] if line.startswith(("◝", "◌"))] == tail, waiting
            assert tail[-2].startswith("◝ Held call · ") and tail[-1] == "◌ 3 · WAITING-2", waiting
            assert transcript_rows(waiting)[bottom - 1] == "◌ 3 · WAITING-2" and not rows(waiting)[bottom].strip(), waiting
            assert "queued" not in waiting.lower(), waiting
            for index in range(3):
                assert f"› WAITING-{index}" not in waiting, waiting
                assert f"second line {index}" not in waiting, waiting
            assert waiting.count("WAITING-2") == 1, waiting
            assert footer(waiting).endswith("ctrl+x stop"), waiting
            (chrome.workspace / "release").write_text("")
            done = chrome.frame(master, b"", lambda screen: "HELD-DONE" in screen
                and "◌" not in screen and "◝" not in screen, timeout=30)
            assert footer(done).strip().startswith("‹ ") and "ctrl+x stop" not in footer(done), done
            order = [done.count(f"› WAITING-{i}") for i in range(3)]
            assert order == [1, 1, 1], done
            assert [done.count(f"second line {i}") for i in range(3)] == [1, 1, 1], done
            assert done.index("› WAITING-0") < done.index("› WAITING-1") < done.index("› WAITING-2"), done
            chrome.leave(master, caller)
        finally:
            release.set()
            (chrome.workspace / "release").write_text("")
    print("session chrome: the running call and its clock, ◌ 3 · the newest waiting Message, ctrl+x stop; waiting Messages appear only in the queue until applied, then once as bands", flush=True)



def thinking_queue_case():
    for width, height in ((140, 40), (46, 30)):
        first_release, next_release = threading.Event(), threading.Event()
        first = fixture.sse_answer("thinking-first", "r1", "m1", "FIRST-DONE")[0]
        second = fixture.sse_answer("thinking-second", "r2", "m2", "SECOND-DONE")[0]
        with Chrome("rui-thinking-queue.", [(first, first_release), (second, next_release)]) as chrome:
            session = chrome.session()
            master, caller, _ = chrome.open(session, lambda screen: True, columns=width, height=height)
            try:
                working = chrome.frame(master, b"FIRST-QUESTION\r", lambda screen:
                    "Thinking" in screen and "FIRST-QUESTION" in screen)
                assert "MIDTURN-HI" not in working, working
                queued = chrome.frame(master, b"MIDTURN-HI\r", lambda screen:
                    "◌ MIDTURN-HI" in screen and composing(screen, ""))
                assert "Thinking" in queued, queued
                assert queued.count("MIDTURN-HI") == 1 and "› MIDTURN-HI" not in queued, queued
                first_release.set()
                taken = chrome.frame(master, b"", lambda screen:
                    "FIRST-DONE" in screen and "› MIDTURN-HI" in screen and "Thinking" in screen, timeout=30)
                assert taken.count("MIDTURN-HI") == 1 and "◌ MIDTURN-HI" not in taken, taken
                next_release.set()
                done = chrome.frame(master, b"", lambda screen: "SECOND-DONE" in screen, timeout=30)
                assert done.count("MIDTURN-HI") == 1 and "◌ MIDTURN-HI" not in done, done
                chrome.leave(master, caller)
            finally:
                first_release.set()
                next_release.set()
    print("session chrome: a mid-Thinking submission is queued once, then shown once as a taken Message at both sizes", flush=True)


def send_recovery_case():
    with Chrome("rui-chrome-send-recovery.", [fixture.sse_answer("recovered", "r", "m", "RECOVERED-ANSWER")[0]]) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        attempts = []

        def drop_first(record):
            attempts.append(record)
            return len(attempts) != 1

        proxy = canonical_fixture.ReplyProxy(chrome.host, "/v1/message", lambda response: response,
            before_forward=drop_first)
        try:
            note = "Not confirmed · ctrl+r retries original"
            failed = chrome.frame(master, b"RECOVER-ME\r", lambda screen: note in screen)
            transcript = "\n".join(transcript_rows(failed))
            assert transcript.count("› RECOVER-ME") == 1 and transcript.count(note) == 1, failed
            assert transcript.index("› RECOVER-ME") < transcript.index(note), failed
            assert note not in footer(failed) and note not in status(failed), failed
            assert "Sending" not in failed and composing(failed, ""), failed
            original = attempts[0]
            key = json.loads(original)["key"]
            record = chrome.home / ".config/rui/requests" / f"{key}.json"
            saved = record.read_bytes()
            assert json.loads(saved)["text"]["value"] == "RECOVER-ME", saved
            chrome.frame(master, b"NEXT-DRAFT", lambda screen: composing(screen, "NEXT-DRAFT"))
            frames = frames_until(master, b"\x12", lambda screen:
                "RECOVERED-ANSWER" in screen and composing(screen, "NEXT-DRAFT") and note not in screen)
            assert attempts == [original, original], attempts
            assert proxy.mutations == [("/v1/message", original), ("/v1/message", original)], proxy.mutations
            assert record.read_bytes() == saved, "recovery changed the original saved Message"
            assert json.loads(run(chrome.home, "request", "inspect", key))["observation"]["status"] == "accepted"
            for frame in frames:
                assert "Sending" not in frame, frame
                assert "\n".join(transcript_rows(frame)).count("› RECOVER-ME") <= 1, frame
            assert "\n".join(transcript_rows(frames[-1])).count("› RECOVER-ME") == 1, frames[-1]
            chrome.leave(master, caller)
        finally:
            proxy.close()
    print("session chrome: unconfirmed note stays with its Message; Ctrl-R recovers identical saved bytes/key once without losing the next draft", flush=True)


def assert_plain_panel(master, screen, *, left=None):
    capture = terminal_capture(master)
    frame = capture.frame
    assert frame.text == screen, (frame.text, screen)
    def pane_cells(index):
        cells = frame.cells[index]
        divider = next((column for column, cell in enumerate(cells) if cell.data == VERTICAL_DIVIDER), None)
        return cells[divider + 1:] if divider is not None else cells

    bounds = composer_bounds(screen)
    if bounds is None:
        return
    prompt = next(index for index in range(bounds[0] + 1, bounds[1])
                  if composer_line(screen, index).startswith((" ›", " >")))
    assert prompt > bounds[0] + 1, ("panel between lifted rule and draft", screen)
    plain = frame.colors(pane_cells(prompt)[-1])[1]
    if left is not None:
        assert composer_line(screen, chat_footer_row(screen)).split() == left.split() + ["esc"], screen
        for cell in pane_cells(chat_footer_row(screen)):
            assert frame.colors(cell)[1] == plain, screen
    backgrounds = set()
    for index in range(bounds[0] + 1, prompt):
        line = composer_line(screen, index)
        assert not any(char in line for char in ("┌┐└┘" + VERTICAL_DIVIDER)), screen
        for cell in pane_cells(index):
            backgrounds.add(frame.colors(cell)[1])
    assert plain in backgrounds and len(backgrounds) <= 2, ("plain panel plus selection bar", backgrounds, screen)


def pages_case():
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
            choice = model_choice_frame(master, b"\x1b[B\x1b[B\x1b[B\r", query="")
            assert "kept draft" in choice, choice
            assert_chat_info_layout(choice, context=True)
            assert_plain_panel(master, choice)
            chrome.frame(master, b"\x1b", lambda screen: not model_choice_shown(screen) and "Copy last answer" in screen)
            chrome.frame(master, b"\x1b[B\rCANCELLED-NAME", lambda screen: "CANCELLED-NAME" in screen)
            chrome.frame(master, b"\x1b", lambda screen: "CANCELLED-NAME" not in screen and "Copy last answer" in screen)
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
            returned = chrome.frame(master, b"\x1b", lambda screen:
                                    latest(screen, "SEED-ANSWER") and composing(screen, "kept draft")
                                    and "Copy last answer" not in screen and "esc close" not in screen)
            assert "Copy last answer" not in returned and not model_choice_shown(returned), returned
            assert len(chrome.endpoint.requests) == 1, chrome.endpoint.requests
            chrome.frame(master, b"\x15", lambda screen: composing(screen, ""))
            chrome.frame(master, b"", lambda screen: latest(screen, "SEED-ANSWER"))
            os.write(master, b"HOLD-QUESTION\r")
            release.set()
            chrome.frame(master, b"", lambda screen: "◝ Held call · " in screen)
            working = chat_info_open(master)
            assert rows(working)[-1].endswith("esc"), working
            returned = chrome.frame(master, b"\x1b", lambda screen:
                                    "◝ Held call · " in screen and marker(screen) is None
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
            assert "alt+i info" not in live, live
            columns = [width - 1]
            opened = None
            for column in columns:
                opened = chrome.frame(master, footer_click(live, column=column),
                                      lambda screen: "Copy last answer" in screen and footer(screen).endswith("esc") and "unavailable" not in screen)
                assert_chat_info_layout(opened, context=True)
                assert_plain_panel(master, opened, left="Natural height")
                base = chat_info_geometry(opened)
                if height >= 30:
                    assert base["top"] > 0 and any("FEED-" in row for row in base["feed"]), opened
                chrome.frame(master, footer_click(opened, marker="Natural height") + b"\x1b[B\r",
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
                assert "kept draft" in choice and footer(choice).endswith("esc"), choice
            closed = chrome.frame(master, b"\x1b", lambda screen:
                                  not model_choice_shown(screen) and "Copy last answer" in screen)
            assert chat_info_geometry(closed) == base, closed
            chrome.frame(master, b"\x1b", lambda screen:
                         "Copy last answer" not in screen and "FEED-24" in screen and "kept draft" in screen)
            chrome.leave(master, caller)
        assert len(chrome.endpoint.requests) == 1, chrome.endpoint.requests
    print("session chrome: natural-height info leaves saved feed above; Model grows/shrinks by its rows; model/effort clicks keep feed and draft; the footer and Alt-I share one transition", flush=True)


def approval_glyph_domain():
    # APPROVAL-3: the terminal carries locale selection into the Action read.
    with Chrome("rui-chrome-approval-glyph.", []) as chrome:
        session = chrome.session(permission="ask")
        chrome.endpoint.responses.append(fixture.sse_tool_calls("glyph", [
            ("bash", "glyph-call", json.dumps({
                "cmd": "printf done", "description": "Review approval glyph", "timeout_ms": None}))]))
        request = admit(chrome.home, "session", "send", "--session", session, input="Review this")["request"]
        fixture.wait_for(lambda: fixture.observe(chrome.store, request)["state"] == "waiting_for_permission", "pending request")
        for locale, glyph in (("C", "?"), ("C.UTF-8", "●")):
            for width, height in ((140, 40), (46, 30)):
                master, slave = open_pty(width, height)
                chrome.descriptors += [master, slave]
                caller = spawn([str(fixture.RUI), "session", "resume", "--", session],
                    env={**os.environ, "HOME": str(chrome.home), "LC_ALL": locale}, cwd=str(chrome.workspace),
                    stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                chrome.callers.append(caller)
                title = f"{glyph} Review approval glyph"
                shown = chrome.frame(master, b"", lambda screen: title in screen and "Allow once" in screen)
                assert title in shown and ("●" if glyph == "?" else "?") + " Review approval glyph" not in shown, shown
                chrome.detach(master, caller)
    print("session chrome: approval headings match the terminal locale at both widths", flush=True)


def opening_case():
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
            admit(chrome.home, "session", "send", "--session", session, input="HOLD-QUESTION")
            fixture.wait_for(lambda: len(chrome.endpoint.requests) >= 2, "held request", timeout=20)
            for index in range(2):
                admit(chrome.home, "session", "send", "--session", session, input=f"WAITING-{index}")
            release.set()
            master, caller, opened = chrome.open(session, lambda screen: "◌ 2 · WAITING-1" in screen and "◝ Held call · " in screen)
            tail = tail_rows(opened)
            assert tail[-2].startswith("◝ Held call · ") and tail[-1] == "◌ 2 · WAITING-1", opened
            assert footer(opened).endswith("ctrl+x stop"), opened
            (chrome.workspace / "release").write_text("")
            chrome.frame(master, b"", lambda screen: latest(screen, "HELD-DONE") and "◌" not in screen, timeout=30)
            chrome.leave(master, caller)
            master, caller, reopened = chrome.open(session, lambda screen: "HELD-DONE" in screen)
            assert "    done" not in reopened, reopened
            folded = chrome.frame(master, b"\x1b[5~\x1b[5~", lambda screen: "┄ 38 more lines" in screen)
            tool = chrome.frame(master, b"\x0f", lambda screen: "    done" in screen)
            assert "Message · 40 lines" not in tool, tool
            chrome.frame(master, b"\x0f", lambda screen: "    done" not in screen)
            chrome.leave(master, caller)
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



def private_chrome_command(chrome, *arguments, input=None):
    assert "--store" in arguments, ("private Store must be explicit", arguments)
    environment = {key: value for key, value in os.environ.items()
                   if key not in ("RUI_STORE", "RUI_ADDRESS", "RUI_SENDER_HANDLE")}
    environment["HOME"] = str(chrome.home)
    result = subprocess.run([str(fixture.RUI), *map(str, arguments)], env=environment,
                            cwd=chrome.workspace, capture_output=True, text=True, input=input, timeout=20)
    assert result.returncode == 0, (arguments, result.stdout, result.stderr)
    return result.stdout


def verify_private_chrome(chrome):
    expected_endpoint = f"providers.codex.endpoint=http://127.0.0.1:{chrome.endpoint.server_port}/responses"
    assert chrome.host.poll() is None and expected_endpoint in chrome.host.args, chrome.host.args
    assert "providers.codex.unauthenticated=true" in chrome.host.args, chrome.host.args
    status = json.loads(private_chrome_command(chrome, "host", "status", "--store", chrome.store))
    assert status["store"] == str(chrome.store), status
    assert len(chrome.endpoint.requests) == 0


def configure_refresh_case():
    # SUI-136: a delayed Current never leaves stale settings on an actionable footer.
    for field in ("effort", "model"):
        release = threading.Event()
        captured = threading.Event()
        statuses = []
        with Chrome("rui-chrome-configure-refresh.", [fixture.sse_answer("r", "q", "m", "DONE")[0]]) as chrome:
            verify_private_chrome(chrome)
            session = chrome.session(model="gpt-6.1-terra")
            master, caller, opened = chrome.open(session, lambda frame: "gpt-6.1-terra" in frame,
                                                 columns=120, height=36)
            marker = "high" if field == "effort" else "gpt-6.1-terra"
            chrome.frame(master, footer_click(opened, marker=marker),
                         lambda frame: "✓" in frame)
            def hold_current(response):
                statuses.append(json.loads(response.split(b"\r\n\r\n", 1)[1]))
                captured.set()
                assert release.wait(15), "Current gate not released"
                return response
            proxy = canonical_fixture.ReplyProxy(chrome.host, "/v1/inspect-session", hold_current)
            try:
                os.write(master, b"\x1b[A\r" if field == "effort" else b"gpt-5.5\r")
                assert captured.wait(10), "accepted Current was not requested"
                expected_model = "gpt-6.1-terra" if field == "effort" else "gpt-5.5"
                expected_effort = "medium" if field == "effort" else "high"
                assert statuses[0]["session"]["model"] == expected_model, statuses
                assert statuses[0]["session"]["reasoning_effort"] == expected_effort, statuses
                shown = chrome.frame(master, b"config probe\r", lambda frame:
                                     "config probe" in frame and "Updating" in frame)
                assert "gpt-6.1-terra · high" not in footer(shown), shown
                fixture.wait_for(lambda: len(chrome.endpoint.requests) == 1, "configured provider request")
                request = json.loads(chrome.endpoint.requests[0])
                assert request["model"] == expected_model and request["reasoning"]["effort"] == expected_effort, request
            finally:
                release.set()
                proxy.close()
            chrome.frame(master, b"", lambda frame: f"{expected_model} · {expected_effort}" in frame)
            chrome.leave(master, caller)
    print("session chrome: a pending Current refresh does not display stale settings for a send", flush=True)


def configure_receipt_case():
    # SUI-135/136/137: A may be admitted only after later B and a chat switch.
    for b_unknown in (False, True):
        with Chrome("rui-chrome-configure-receipt.", []) as chrome:
            verify_private_chrome(chrome)
            original = chrome.session(model="gpt-6.1-terra")
            other = chrome.session(model="gpt-6.1-terra")
            private_chrome_command(chrome, "session", "configure", "--store", chrome.store, "--session", original, "--label", "original-config")
            private_chrome_command(chrome, "session", "configure", "--store", chrome.store, "--session", other, "--label", "other-config")
            master, caller, opened = chrome.open(original, lambda frame:
                "original-config" in frame and "other-config" in frame and "gpt-6.1-terra" in frame,
                columns=120, height=36)
            draft = chrome.frame(master, b"next draft", lambda frame: composing(frame, "next draft"))
            chrome.frame(master, footer_click(draft, marker="high"), lambda frame: "Effort" in frame and "✓" in frame)
            attempts = []
            def forward(record):
                attempts.append(record)
                return len(attempts) > 1 and not (b_unknown and len(attempts) == 2)
            proxy = canonical_fixture.ReplyProxy(chrome.host, "/v1/configure", lambda response: response,
                                                 before_forward=forward)
            try:
                failed = chrome.frame(master, b"\x1b[A\r", lambda frame: "not confirmed" in frame.lower(), timeout=20)
                fixture.wait_for(lambda: len(attempts) == 1, "first original Configure")
                a = json.loads(attempts[0])["key"]
                assert composing(failed, "next draft"), failed
                settled = chrome.frame(master, b"", lambda frame: "gpt-6.1-terra · high" in frame and "not confirmed" in frame.lower())
                closed = chrome.frame(master, b"\x1b", lambda frame: "Effort" not in conversation_text(frame))
                chrome.frame(master, footer_click(closed, marker="gpt-6.1-terra"), lambda frame: "✓" in frame)
                second = chrome.frame(master, b"gpt-5.5\r", lambda frame:
                    ("not confirmed" in frame.lower() if b_unknown else "gpt-5.5 · high" in frame), timeout=20)
                fixture.wait_for(lambda: len(attempts) == 2, "second independent Configure")
                b = json.loads(attempts[1])["key"]
                assert a != b and composing(second, "next draft"), (a, b, second)
                if b_unknown:
                    second = chrome.frame(master, b"\x1b", lambda frame: "not confirmed" not in conversation_text(frame).lower())
            finally:
                proxy.close()

            def sidebar_click(frame, label):
                for row, line in enumerate(frame.splitlines(), 1):
                    left = line.split("┆", 1)[0]
                    if label in left:
                        col = left.index(label) + 1
                        return f"\x1b[<0;{col};{row}M\x1b[<0;{col};{row}m".encode()
                raise AssertionError((label, frame))

            switched = chrome.frame(master, sidebar_click(second, "other-config"),
                                    lambda frame: composing(frame, "") and "other-config" in frame)
            recovered = json.loads(private_chrome_command(chrome, "request", "recover", "--store", chrome.store, "--kind", "configure", "--record", chrome.home / ".config/rui/requests" / (a + ".json")))
            assert recovered["context"]["key"] == a and recovered["answer"]["status"] == "accepted", recovered
            assert recovered["answer"]["replayed"] is False, recovered
            host_after_a = json.loads(private_chrome_command(chrome, "session", "inspect", "--store", chrome.store, "--session", original))["session"]
            assert host_after_a["reasoning_effort"] == "medium", host_after_a
            assert host_after_a["model"] == ("gpt-6.1-terra" if b_unknown else "gpt-5.5"), host_after_a
            reopened = chrome.frame(master, sidebar_click(switched, "original-config"),
                                    lambda frame: composing(frame, "next draft"))
            assert composing(reopened, "next draft"), reopened
            requests = chrome.frame(master, b"\x7f" * len("next draft") + b"/requests\r", lambda frame:
                                    "Local recovery handles" in frame and a in frame and b in frame, timeout=20)
            if b_unknown:
                assert b in requests, requests
            current = chrome.frame(master, b"\x1b", lambda frame: " · medium" in footer(frame), timeout=20)
            assert "gpt-6.1-terra" in footer(current) if b_unknown else "gpt-5.5" in footer(current), current
            os.write(master, b"\x03")
            _, errors = terminal_exit(caller, master)
            assert caller.returncode == 0, errors
            assert a.encode() not in errors, errors
            if b_unknown:
                assert b.encode() in errors and b"model: gpt-5.5" in errors, errors
                reply = json.loads(private_chrome_command(chrome, "request", "recover", "--store", chrome.store, "--kind", "configure", "--record", chrome.home / ".config/rui/requests" / (b + ".json")))
                assert reply["context"]["key"] == b and reply["answer"]["status"] == "accepted", reply
                assert reply["answer"]["replayed"] is False, reply
            else:
                assert b.encode() not in errors, errors
    print("session chrome: distinct Configure keys survive a later edit, chat switch and original recovery", flush=True)

def main():
    configure_refresh_case()
    configure_receipt_case()
    send_recovery_case()
    activity_case()
    thinking_queue_case()
    pages_case()
    info_natural_height_case()
    approval_glyph_domain()
    opening_case()
