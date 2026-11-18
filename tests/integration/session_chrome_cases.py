from terminal_screen import VERTICAL_DIVIDER
import json
import os
import pathlib
import re
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

    def session(self, permission="bypass"):
        reply = json.loads(run(self.home, "session", "configure", "--workspace", self.workspace,
            "--provider", "codex", "--model", "gpt-6-sol", "--permission-mode", permission))
        return reply["answer"]["session"]

    def answered(self, session, *inputs):
        for text in inputs:
            message = admit(self.home, "session", "send", "--to", session, input=text)
            fixture.wait_for(lambda key=message["request"]: fixture.completed_observation(self.store, key), "saved answer")

    def open(self, session, ready, *, columns=80, height=ROWS):
        master, slave = open_pty(columns, height)
        self.descriptors += [master, slave]
        caller = spawn([str(fixture.RUI), "session", "resume", "--", session],
            env={**os.environ, "HOME": str(self.home)}, cwd=str(self.workspace),
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
                    and all(screen.count(f"› WAITING-{i}") == 1
                        and screen.count(f"second line {i}") == 1 for i in range(index + 1)))
                assert "Sending" not in waiting, waiting
            bottom = feed_bottom(waiting)
            tail = transcript_rows(waiting)[bottom - 2:bottom]
            assert [line for line in transcript_rows(waiting)[:bottom] if line.startswith(("◝", "◌"))] == tail, waiting
            assert tail[-2].startswith("◝ Held call · ") and tail[-1] == "◌ 3 · WAITING-2", waiting
            assert transcript_rows(waiting)[bottom - 1] == "◌ 3 · WAITING-2" and not rows(waiting)[bottom].strip(), waiting
            assert "queued" not in waiting.lower(), waiting
            for index in range(3):
                assert waiting.count(f"› WAITING-{index}") == 1, waiting
                assert waiting.count(f"second line {index}") == 1, waiting
            assert waiting.index("› WAITING-0") < waiting.index("› WAITING-1") < waiting.index("› WAITING-2"), waiting
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
    print("session chrome: the running call and its clock, ◌ 3 · the newest waiting Message, ctrl+x stop; full waiting Messages stay visible once before and after completion", flush=True)


def send_state_case():
    with Chrome("rui-chrome-send.", [fixture.sse_answer("sent", "r", "m", "SENT-ANSWER")[0]]) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        held, release = threading.Event(), threading.Event()

        def hold_admission(record):
            held.set()
            assert release.wait(15), "Message admission gate was not released"
            return True

        proxy = canonical_fixture.ReplyProxy(chrome.host, "/v1/message", lambda response: response,
            before_forward=hold_admission)
        try:
            os.write(master, b"SEND-ME")
            chrome.frame(master, b"", lambda screen: composing(screen, "SEND-ME"))
            frames = frames_until(master, b"\r", lambda screen:
                composing(screen, "") and "› SEND-ME" in "\n".join(transcript_rows(screen)))
            fixture.wait_for(held.is_set, "Message held before Host admission")
            cleared = [frame for frame in frames if composing(frame, "")]
            assert cleared, frames
            for frame in cleared:
                assert "Sending" not in frame, frame
                assert "\n".join(transcript_rows(frame)).count("› SEND-ME") == 1, frame
                assert "SENT-ANSWER" not in frame, frame
            release.set()
            frames += frames_until(master, b"", lambda screen: "SENT-ANSWER" in screen)
            for frame in frames:
                assert "Sending" not in frame, frame
                assert "\n".join(transcript_rows(frame)).count("› SEND-ME") <= 1, frame
            assert "\n".join(transcript_rows(frames[-1])).count("› SEND-ME") == 1, frames[-1]
            assert len(proxy.mutations) == 1, proxy.mutations
            chrome.leave(master, caller)
        finally:
            release.set()
            proxy.close()
    print("session chrome: Enter immediately shows one sent Message before admission; no Sending state or admission duplicate", flush=True)


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


def scroll_marker_case():
    release = threading.Event()
    with Chrome("rui-chrome-scroll.", []) as chrome:
        empty = chrome.session()
        master, caller, opened = chrome.open(empty, lambda screen: True)
        for keys in (b"\x1b[1;2A", b"\x1b[5~"):
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
        end = chrome.frame(master, b"", lambda screen:
                           composing(screen, "keep") and bool(transcript_rows(screen)[0].strip()))
        bottom = feed_bottom(end)
        assert not rows(end)[bottom].strip(), end
        for keys in (b"\x1b[1;2A", b"\x1b[5~"):
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
            scrolled = settle_screen(master, quiet=0.5)
            os.write(master, b"\x1b[F")
            same = settle_screen(master, quiet=0.5)
            assert marker(same) == "↓" and rows(same)[:2] == rows(scrolled)[:2], (keys, same)
            back = b"\x1b[1;5F" if keys == b"\x1b[1;2A" else b"\x1b"
            live = chrome.frame(master, back, lambda screen: latest(screen, "second row 07"))
            assert composing(live, "keep"), live
            assert feed_bottom(live) == bottom, (end, live)
            first_known = next(index for index, row in enumerate(end_rows) if row.strip())
            assert rows(live)[first_known:bottom + 1] == rows(end)[first_known:bottom + 1], (end, live)
        assert len(chrome.endpoint.requests) == requests, "scrolling sent input"
        os.write(master, b"\x15HOLD-QUESTION\r")
        release.set()
        chrome.frame(master, b"", lambda screen: "◝ Held call · " in screen)
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


def command_panel_case():
    with Chrome("rui-chrome-command-panel.", []) as chrome:
        session = chrome.session()
        for width, height in ((140, 40), (46, 30)):
            master, caller, _ = chrome.open(session, lambda screen: True, columns=width, height=height)
            opened = chrome.frame(master, b"/", lambda screen: "/new" in screen and "more" in screen)
            assert_plain_panel(master, opened)
            assert "type to narrow" not in opened, opened
            bounds = composer_bounds(opened)
            panel = [composer_line(opened, index) for index in range(bounds[0] + 1, bounds[1] - 1)]
            assert any(re.fullmatch(r"\s*[1-9][0-9]* more", line) for line in panel), opened
            for command in ("archive", "model", "pin"):
                for line in panel:
                    if re.match(r"\s*/" + command + r"(?:\s|$)", line):
                        assert line.strip() == "/" + command, opened
            closed = chrome.frame(master, b"\x7f", lambda screen: composing(screen, "") and "/new" not in screen)
            assert composer_bounds(closed)[0] > bounds[0], (opened, closed)
            chrome.leave(master, caller)
    print("session chrome: command list lifts the input rule at both frame sizes, stays plain, omits redundant descriptions, and shows only N more", flush=True)


def command_escape_case():
    with Chrome("rui-chrome-command-escape.", []) as chrome:
        session = chrome.session()
        for width, height in ((140, 40), (46, 30)):
            master, caller, _ = chrome.open(session, lambda screen: True, columns=width, height=height)
            opened = chrome.frame(master, b"/ne", lambda screen: "/new" in screen and "› /ne" in screen)
            assert composer_bounds(opened) is not None, opened
            closed = chrome.frame(master, b"\x1b", lambda screen: composing(screen, "") and "/new" not in screen)
            assert composing(closed, ""), closed
            settled = settle_screen(master)
            assert composing(settled, "") and "/new" not in settled, settled
            overview = chrome.frame(master, b"\x1b", lambda screen: composer_bounds(screen) is None and "Settings" in screen)
            assert composer_bounds(overview) is None, overview
            chrome.leave(master, caller)
    print("session chrome: lone Escape closes a drawn command list before leaving chat at both sizes", flush=True)


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
        request = admit(chrome.home, "session", "send", "--to", session, input="Review this")["request"]
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


def approval_overflow_case():
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
            fixture.wait_for(lambda: len(chrome.endpoint.requests) >= 2, "held request", timeout=20)
            for index in range(2):
                admit(chrome.home, "session", "send", "--to", session, input=f"WAITING-{index}")
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


def keys_case():
    with Chrome("rui-chrome-keys.", []) as chrome:
        session = chrome.session()
        chrome.endpoint.responses.append(fixture.sse_answer("keys", "r", "m", "KEYS-ANSWER")[0])
        chrome.answered(session, "keys")
        for width in (140, 46):
            master, caller, shown = chrome.open(session, lambda screen: "KEYS-ANSWER" in screen, columns=width)
            if width == 140:
                row, line = next((index, line) for index, line in enumerate(rows(shown)) if "Settings" in line)
                col = line.index("Settings") + 1
                gesture = f"\x1b[<0;{col};{row + 1}M\x1b[<0;{col};{row + 1}m".encode()
            else:
                chrome.frame(master, b"\x1b", lambda screen: "Settings" in screen and not any(line.startswith(" ‹ ") for line in rows(screen)))
                gesture = b"\x1b[F\r"
            settings = chrome.frame(master, gesture, lambda screen: "Notifications" in screen and "Version" in screen)
            assert_plain_panel(master, settings, left="Settings")
            keys = chrome.frame(master, b"\x1b[B" * 6 + b"\r", lambda screen: "earlier message" in screen)
            expected = keys_reference()
            columns = 2 if width == 140 else 1
            key_widths = [max(len(key) for key, _ in expected[column::columns])
                          for column in range(columns)]
            bounds = composer_bounds(keys)
            assert bounds is not None, keys
            prompt = next(index for index in range(bounds[0] + 1, bounds[1])
                          if composer_line(keys, index).startswith((" ›", " >")))
            pane_rows = [chat_content_row(composer_line(keys, index))
                         for index in range(bounds[0] + 1, prompt)]
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
            settings = chrome.frame(master, b"\r\x1b", lambda screen: "Notifications" in screen and "Version" in screen)
            assert "earlier message" not in settings, settings
            if width == 140:
                chrome.frame(master, b"\x1b", lambda screen:
                             latest(screen, "KEYS-ANSWER") and composing(screen, "")
                             and "Rui · settings" not in screen)
                chrome.frame(master, gesture, lambda screen: "Notifications" in screen and "Version" in screen)
                chrome.frame(master, b"x", lambda screen: latest(screen, "KEYS-ANSWER") and composing(screen, "x")
                             and "Notifications" not in screen)
                chrome.frame(master, b"\x7f", lambda screen: composing(screen, ""))
            else:
                chrome.frame(master, b"\x1b", lambda screen: "Settings" in screen and "Rui · settings" not in screen and not any(line.startswith(" ‹ ") for line in rows(screen)))
            chrome.leave(master, caller)
    print("session chrome: Settings > Keys shows src/keymap.zig's reference rows aligned, paired at 140 columns and one column at 46; Enter is inert, Esc returns one layer, and printable input returns to the wide conversation", flush=True)


def keys_reference():
    source = (pathlib.Path(__file__).resolve().parents[2] / "src/keymap.zig").read_text()
    body = source.split("pub const list = [_]Reference{", 1)[1].split("\n};", 1)[0]
    rows = tuple(re.findall(r'^    \.\{ \.key = "([^"\\]*)", \.meaning = "([^"\\]*)"', body, re.MULTILINE))
    assert rows and len(rows) == len(re.findall(r'^    \.\{ \.key = "', body, re.MULTILINE)), "src/keymap.zig: teach keys_reference this list"
    return rows


def notice_case():
    with Chrome("rui-chrome-notice.", []) as chrome:
        session = chrome.session()
        master, caller, _ = chrome.open(session, lambda screen: True)
        misused = chrome.frame(master, b"/new unexpected\r", lambda screen: footer(screen).endswith("! Usage: /new"))
        assert composing(misused, ""), misused
        gone = chrome.frame(master, b"a", lambda screen: composing(screen, "a"))
        assert status(gone) == "" and "Usage:" not in footer(gone) and footer(gone).strip().startswith("‹ "), gone
        os.write(master, b"\x15")
        chrome.frame(master, b"", lambda screen: composing(screen, ""))
        question = chrome.frame(master, b"?", lambda screen: composing(screen, "?"))
        assert "shift+enter or ctrl+j" not in question, question
        questions = chrome.frame(master, b"?", lambda screen: composing(screen, "??"))
        assert "shift+enter or ctrl+j" not in questions, questions
        chrome.leave(master, caller)
    print("session chrome: a notice goes at the next key; ? is ordinary text on empty and nonempty drafts", flush=True)


def main():
    command_panel_case()
    command_escape_case()
    send_state_case()
    send_recovery_case()
    activity_case()
    scroll_marker_case()
    pages_case()
    info_natural_height_case()
    approval_glyph_domain()
    approval_overflow_case()
    opening_case()
    notice_case()
    keys_case()
