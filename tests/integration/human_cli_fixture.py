from terminal_screen import RULE_GLYPHS, VERTICAL_DIVIDER, split_pane_row
import errno
import fcntl
import json
import os
import re
import select
import struct
import subprocess
import termios
import threading
import time

import terminal_process as terminal_process_module
from terminal_process import answers_to


def _fixture():
    import model_fixture
    return model_fixture


CHOICE = "Allow once    Deny"


ALLOW = b"\r"


CHOICE_ROW = re.compile(r"^(?: [›>])? Allow", re.M)


def highlighted(capture):
    rows = capture.completed.split("\n")
    for index, row in enumerate(rows):
        if CHOICE_ROW.match(row):
            cells = capture.completed_cells[index]
            marked = [label for label in ("Allow once", "Deny")
                      if label in row and cells[row.index(label)].reverse]
            assert len(marked) <= 1, (row, marked)
            return marked[0] if marked else None
    return None


def pick_deny(master):
    capture = terminal_capture(master)
    return keyed_frame(master, b"\x1b[C", lambda screen, x, y: highlighted(capture) == "Deny")


def run(home, *args, success=True, environment=None, input=None):
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(_fixture().RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20, input=input)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (args, result.stdout, result.stderr)
    return result.stdout


CAPTURE_NOTICE = re.compile(r"request: (\S+) \(wait: rui request wait \1; if unconfirmed: rui request recover \1\)\n")


def admit(home, *args, expect=0, environment=None, input=None, cwd=None):
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(_fixture().RUI), *map(str, args)], env=env, capture_output=True,
        text=True, timeout=20, input=input, cwd=cwd)
    assert result.returncode == expect, (args, result.stdout, result.stderr)
    notice = CAPTURE_NOTICE.match(result.stderr)
    assert notice, (args, result.stderr)
    admission = json.loads(result.stdout)
    assert admission["context"]["key"] == notice.group(1), (admission, result.stderr)
    return {"request": notice.group(1), "admission": admission, "stderr": result.stderr}


_captures = terminal_process_module.CAPTURES


def terminal_capture(master, *, fresh=False, silent=False):
    from terminal_screen import ScreenCapture
    try:
        rows, columns = struct.unpack("HHHH", fcntl.ioctl(master, termios.TIOCGWINSZ, b"\0" * 8))[:2]
    except OSError:
        rows, columns = 24, 80
    rows, columns = rows or 24, columns or 80
    capture = None if fresh else _captures.get(master)
    if capture is None:
        capture = ScreenCapture(columns, rows, reply=None if silent else answers_to(master))
        terminal_process_module.register_capture(master, capture)
    elif (capture.screen.columns, capture.screen.lines) != (columns, rows):
        capture.resize(columns, rows)
    return capture


def draining(master, observe, feed=None):
    feed = feed or terminal_capture(master).feed

    def drained():
        terminal_process_module.drain_ready(master, feed)
        return observe()
    return drained


def current_screen(master):
    return terminal_capture(master).completed


def shown(text, screen):
    from terminal_screen import shown as wrapped
    return wrapped(text, screen)


def command_frame(master, command, accept, timeout=15, *, end="\r"):
    capture = terminal_capture(master)
    found = []
    state = {"typed": end != "\r"}

    def observe(screen, x, y):
        if not state["typed"]:
            if not composer_empty(screen, y):
                state["typed"] = True
                assert not accept(screen), ("command result shown before the command ran", command, screen)
                os.write(master, end.encode())
        elif not found and accept(screen) and composer_ready(screen, x, y) and (end != "\r" or composer_empty(screen, y)):
            found.append(screen)

    capture.listener = observe
    try:
        os.write(master, (command if end == "\r" else command + end).encode())
        deadline = time.monotonic() + timeout
        while not found:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([master], [], [], remaining)[0], (
                "command result frame", command, capture.completed)
            chunk = os.read(master, 65536)
            assert chunk, ("terminal closed before command result", command)
            capture.feed(chunk)
    finally:
        capture.listener = None
    return found[0]


def chat_content_row(row):
    return row.removeprefix(" ")


def pane_content(row):
    return split_pane_row(row)[2]


def conversation_text(frame):
    return "\n".join(chat_content_row(pane_content(row)) for row in frame.split("\n"))


def composer_line(screen, y):
    lines = screen.split("\n")
    return pane_content(lines[y]) if y < len(lines) else ""


def composer_bounds(screen):
    rules = [index for index in range(len(screen.split("\n")))
             if len(set(composer_line(screen, index))) == 1
             and composer_line(screen, index)[0] in RULE_GLYPHS]
    return tuple(rules[-2:]) if len(rules) >= 2 else None


def chat_footer_row(screen):
    bounds = composer_bounds(screen)
    assert bounds is not None, ("composer rules", screen)
    return bounds[1] + 1


def composer_empty(screen, y):
    return composer_line(screen, y) in (" ›", " >", " › What shall we work on?", " > What shall we work on?")


def composer_ready(screen, x, y):
    if "Opening…" in screen:
        return False
    line = composer_line(screen, y)
    return x >= 3 and any(line == " " + mark or line.startswith(" " + mark + " ") for mark in ("›", ">"))


def keyed_frame(master, keys, accept, timeout=15):
    capture = terminal_capture(master)
    found = []

    def observe(screen, x, y):
        if not found and accept(screen, x, y):
            found.append(screen)

    capture.listener = observe
    try:
        if keys:
            os.write(master, keys)
        elif accept(capture.completed, capture.screen.cursor.x, capture.screen.cursor.y):
            return capture.completed
        deadline = time.monotonic() + timeout
        while not found:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([master], [], [], remaining)[0], (
                "keyed frame", keys, capture.completed)
            chunk = os.read(master, 65536)
            assert chunk, ("terminal closed before keyed frame", keys)
            capture.feed(chunk)
    finally:
        capture.listener = None
    return found[0]


def overview_title(frame):
    return "   + New chat" in frame and "     Settings" in frame and "What shall we work on?" not in frame


def overview_frame(master, accept, keys=b"", timeout=15, *, ready=True):
    return keyed_frame(master, keys, lambda screen, x, y: accept(screen) and overview_title(screen)
                       and not any(re.match(r"\s*[›>](?: |$)", pane_content(row))
                                   for row in screen.split("\n")), timeout)


def open_new_chat(master, timeout=15):
    return keyed_frame(master, b"\x1b[H\r", lambda screen, x, y: "What shall we work on?" in screen
                       and composer_ready(screen, x, y), timeout)



def panel_frame(master, accept, keys=b"", timeout=15):
    return keyed_frame(master, keys, lambda screen, x, y: accept(screen), timeout)


def assert_chat_info_layout(screen, *, context=None):
    rows = screen.split("\n")
    contents = [pane_content(row) for row in rows]
    footers = [index for index, row in enumerate(contents) if row.endswith("esc")]
    assert footers == [chat_footer_row(screen)], ("one plain panel footer after the input", screen)
    assert " · info" not in screen and "esc close" not in screen, screen
    assert "alt+i info" not in screen, ("live chat footer must be substituted", screen)
    bounds = composer_bounds(screen)
    assert bounds is not None, ("composer rules", screen)
    prompts = [index for index in range(bounds[0] + 1, bounds[1])
               if contents[index].strip() in ("›", ">") or contents[index].lstrip().startswith(("› ", "> "))]
    assert prompts and max(prompts) < footers[0], ("info footer follows input", screen)
    effort = next(index for index in range(bounds[0] + 1, bounds[1]) if contents[index].startswith("   Effort"))
    assert bounds[0] < effort < min(prompts), ("panel inside input rules", screen)
    assert not any(any(char in row for char in ("┌┐└┘" + VERTICAL_DIVIDER)) for row in contents[bounds[0] + 1:bounds[1]]), screen
    actions = next(index for index in range(bounds[0] + 1, bounds[1]) if "Rename" in contents[index])
    assert not contents[actions - 1].strip(), ("blank row before chat actions", screen)
    assert not any(row.strip().startswith("Context") and "unknown" in row for row in contents), screen
    if context is not None:
        assert any(row.strip().startswith("Context") for row in contents) == context, screen



def chat_info_geometry(screen):
    content = [pane_content(row) for row in screen.split("\n")]
    bounds = composer_bounds(screen)
    assert bounds is not None, ("composer rules", screen)
    panel_rows = range(bounds[0] + 1, bounds[1])
    effort = next(index for index in panel_rows if content[index].startswith("   Effort"))
    composer = next(index for index in panel_rows if content[index].rstrip() in (" ›", " >") or content[index].startswith((" › ", " > ")))
    actions = [index for index in panel_rows
               if content[index].strip().startswith(("Rename", "Archive", "Copy last answer"))]
    assert actions and bounds[0] < effort <= actions[-1] < composer < bounds[1], screen
    return {"top": bounds[0], "input": composer, "footer": chat_footer_row(screen),
            "feed": content[:bounds[0]], "rows": content}



def footer_click(screen, *, column=None, marker=None):
    content = screen.split("\n")
    row = chat_footer_row(screen)
    line = content[row]
    if marker is not None:
        column = line.index(marker)
    assert column is not None and 0 <= column < len(content[row - 1]), (column, line)
    return f"\x1b[<0;{column + 1};{row + 1}M\x1b[<0;{column + 1};{row + 1}m".encode()


def chat_info_open(master, timeout=15):
    screen = panel_frame(master, lambda screen: "unavailable" not in screen and all(word in screen for word in
                         ("Effort", "Permissions", "Allowed tools", "Folder", "Model", "Rename", "Archive", "Copy last answer")),
                         b"\x1bi", timeout)
    assert_chat_info_layout(screen)
    return screen


def chat_info_frame(master, timeout=15):
    screen = chat_info_open(master, timeout)
    panel_frame(master, lambda frame: "Copy last answer" not in frame, b"\x1b", timeout)
    return screen


def app_settings_open(master):
    overview_frame(master, lambda screen: "Settings" in screen, b"\x1b[F")
    return panel_frame(master, lambda screen: composer_line(screen, len(screen.split("\n")) - 1).split() == ["Settings", "esc"], b"\r")



def model_choice_details(screen):
    rows = [pane_content(row) for row in screen.split("\n")]
    field = next((index for index, row in enumerate(rows) if row.startswith("   Model")), None)
    matches = []
    more = None
    if field is not None:
        for index, row in enumerate(rows[field + 1:], field + 1):
            hit = re.match(r"^   [✓+ ] ([A-Za-z0-9][^ ]*)", row)
            remaining = re.fullmatch(r"   [↓v] ([1-9][0-9]*) more", row)
            if hit:
                matches.append((index, hit[1], row))
            elif remaining:
                more = int(remaining[1])
                break
            else:
                break
    value = rows[field][19:].strip() if field is not None else None
    return {"rows": rows, "field": field, "value": value, "matches": matches, "more": more}


def model_choice_shown(screen, query=None):
    choice = model_choice_details(screen)
    return bool(choice["matches"]) and (query is None or choice["value"] == query)


def assert_model_choice(screen, *, query=None, more=None):
    choice = model_choice_details(screen)
    assert "Filter:" not in screen, screen
    assert not any(re.match(r"^   ↑(?: |$)", row) for row in choice["rows"]), screen
    assert model_choice_shown(screen, query), screen
    hits = choice["matches"]
    assert hits[0][0] == choice["field"] + 1, ("matches immediately follow inline input", screen)
    assert [hit[0] for hit in hits] == list(range(hits[0][0], hits[0][0] + len(hits))), screen
    assert len(hits) <= 8, ("bounded Model match list", screen)
    if more is not None:
        assert (choice["more"] is not None) == more, screen
    if choice["more"] is not None:
        assert len(hits) < 8, ("overflow count has its own bounded row", screen)
    return choice


def model_choice_frame(master, keys=b"", *, query=None, more=None):
    shown = panel_frame(master, lambda screen: model_choice_shown(screen, query), keys)
    assert_model_choice(shown, query=query, more=more)
    return shown


class AppModelCatalog:

    def __init__(self, host):
        from canonical_fixture import ReplyProxy
        self.entered = threading.Event()
        self.release = threading.Event()
        self.proxy = ReplyProxy(host, "/v1/model-list", lambda response: response,
                                before_forward=self.hold)

    def hold(self, _):
        self.entered.set()
        _fixture().wait_for(self.release.is_set, "initial Model catalog release", timeout=20)
        return True

    def close(self):
        self.release.set()
        if self.proxy is not None:
            proxy, self.proxy = self.proxy, None
            proxy.close()


def app_model_open(master, query=b"", *, catalog=None):
    app_settings_open(master)
    shown = model_choice_frame(master, b"\r", query="")
    if catalog is not None:
        _fixture().wait_for(catalog.entered.is_set, "initial Model catalog requested")
        catalog.release.set()
        panel_frame(master, lambda screen: not model_choice_shown(screen))
        catalog.close()
        shown = model_choice_frame(master, b"\r", query="")
    if query:
        shown = model_choice_frame(master, query, query=query.decode())
    return shown


def read_terminal(master, marker, timeout=15, preserve_colour=False, *, composer=False, redraw=False, initial=b"", fresh=False):
    del preserve_colour, redraw
    capture = terminal_capture(master)
    limit = 1024 * 1024
    assert len(marker.encode()) < limit, "terminal marker exceeds retained output bound"
    frames = []
    state = {"marker": marker == "› ", "ready": False, "retained": 0}
    received = 0
    raw = bytearray()

    def observe(screen, x, y):
        if not frames or frames[-1] != screen:
            frames.append(screen)
            state["retained"] += len(screen.encode()) + 1
            while state["retained"] >= limit and len(frames) > 1:
                state["retained"] -= len(frames.pop(0).encode()) + 1
        if not state["marker"] and marker in conversation_text(screen):
            state["marker"] = True
        if state["marker"] and composer_ready(screen, x, y):
            state["ready"] = True

    def reached():
        return state["marker"] and (state["ready"] or (not composer and marker != "› "))

    capture.listener = observe
    plain_start = capture.plain_total

    def plain():
        return capture.plain_since(plain_start)

    def reached_plain():
        if marker != "› " and not composer and marker in plain():
            state["marker"] = True
        return reached()

    try:
        if not fresh:
            observe(capture.completed, capture.screen.cursor.x, capture.screen.cursor.y)
        if initial:
            capture.feed(initial)
        deadline = time.monotonic() + timeout
        while not reached_plain():
            remaining = deadline - time.monotonic()
            assert remaining > 0, (marker, capture.completed, plain())
            assert select.select([master], [], [], remaining)[0], (marker, capture.completed, plain())
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            assert chunk, ("terminal closed before marker", marker, capture.completed, plain())
            received += len(chunk)
            raw.extend(chunk[-limit:])
            del raw[:-limit]
            before = time.monotonic()
            capture.feed(chunk)
            deadline += time.monotonic() - before
    except AssertionError as error:
        error.terminal_metadata = {"received_bytes": received, "frames": len(frames),
            "marker_bytes": len(marker.encode()), "composer": composer, "tail": bytes(raw[-4096:])}
        raise
    finally:
        capture.listener = None
    return "\n".join(frames + ([plain()] if plain() else []))


def terminal_exit(caller, master, timeout=5):
    errors_fd = caller.stderr.fileno()
    streams = {master: bytearray(), errors_fd: bytearray()}
    pending = set(streams)
    deadline = time.monotonic() + timeout
    while True:
        exited = caller.poll() is not None
        remaining = deadline - time.monotonic()
        assert remaining > 0, ("terminal exit timeout", bytes(streams[master]), bytes(streams[errors_fd]))
        ready = select.select(list(pending), [], [], 0 if exited else min(remaining, 0.1))[0]
        if exited and not ready:
            caller.stderr.close()
            return bytes(streams[master]), bytes(streams[errors_fd])
        for fd in ready:
            try:
                chunk = os.read(fd, 65536) if fd == master else os.read(fd, 65536)
            except OSError as error:
                if fd != master or error.errno != errno.EIO:
                    raise
                chunk = b""
            if chunk:
                streams[fd].extend(chunk)
                assert sum(map(len, streams.values())) < 1024 * 1024, "unexpected unbounded terminal output"
            else:
                pending.remove(fd)


def terminal_gate(caller, master, reached, context, timeout=10):
    capture = terminal_capture(master)
    errors_fd = caller.stderr.fileno()
    streams = {master: bytearray(), errors_fd: bytearray()}
    pending = set(streams)
    deadline = time.monotonic() + timeout
    while not reached.is_set():
        remaining = max(0, deadline - time.monotonic())
        for fd in select.select(list(pending), [], [], min(0.1, remaining))[0]:
            try:
                data = os.read(fd, 65536) if fd == master else os.read(fd, 65536)
            except OSError as error:
                if fd != master or error.errno != errno.EIO:
                    raise
                data = b""
            if data:
                streams[fd].extend(data)
                if fd == master:
                    capture.feed(data)
                assert sum(map(len, streams.values())) < 1024 * 1024, "unexpected unbounded startup output"
            else:
                pending.remove(fd)
        assert reached.is_set() or (caller.poll() is None and time.monotonic() < deadline), (
            "terminal metadata gate not reached", context, caller.poll(),
            bytes(streams[master]), bytes(streams[errors_fd]))
    assert not streams[errors_fd], (context, bytes(streams[errors_fd]))
    return bytes(streams[master])


def next_frame(master, timeout=3):
    capture = terminal_capture(master)
    generation = capture.generation
    deadline = time.monotonic() + timeout
    while capture.generation == generation or capture.synchronized:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
            return None
        try:
            chunk = os.read(master, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            chunk = b""
        assert chunk, ("terminal closed before frame", capture.completed)
        capture.feed(chunk)
    return capture.completed


def await_screen(master, marker, *, composer=False, timeout=15):
    capture = terminal_capture(master)
    shown = capture.completed
    if marker in conversation_text(shown) and (not composer or composer_ready(shown, capture.screen.cursor.x, capture.screen.cursor.y)):
        return shown
    return read_terminal(master, marker, timeout, composer=composer)


def return_to_live(master, live, key=b"\x1b", timeout=15):
    return keyed_frame(master, key,
        lambda screen, x, y: composer_ready(screen, x, y) and live(screen), timeout)


LIVE_CLOCK = re.compile(r"^([⠹◌?] .+ · )(?:retry \d+ in )?\d+[hms](?: \d+[ms])?$", re.M)


def settle_screen(master, quiet=1.0, timeout=15):
    deadline = time.monotonic() + timeout
    still = LIVE_CLOCK.sub(r"\1", current_screen(master))
    quiet_until = time.monotonic() + quiet
    while (frame := next_frame(master, max(0, quiet_until - time.monotonic()))) is not None:
        if LIVE_CLOCK.sub(r"\1", frame) != still:
            still = LIVE_CLOCK.sub(r"\1", frame)
            quiet_until = time.monotonic() + quiet
        assert time.monotonic() < deadline, ("screen never settled", current_screen(master))
    return current_screen(master)


def terminal_step(master, command, marker, *, composer=False):
    if composer:
        return command_frame(master, command, lambda frame: marker in conversation_text(frame))
    os.write(master, (command + "\r").encode())
    return read_terminal(master, marker, fresh=True)


def drop_spent_readiness(descriptor):
    while select.select([descriptor], [], [], 0)[0]:
        assert os.read(descriptor, 1) == b"x", "Action caller exited before readiness"


def action_ready(descriptor, master, timeout=15, *, shows=None, send=None):
    if send is not None:
        drop_spent_readiness(descriptor)
        os.write(master, send)
    capture = terminal_capture(master)
    deadline = time.monotonic() + timeout
    frames = []

    def observe(screen, x, y):
        if not frames or frames[-1] != screen:
            frames.append(screen)
            while sum(len(frame) for frame in frames) >= 1024 * 1024 and len(frames) > 1:
                frames.pop(0)

    capture.listener = observe
    try:
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, ("Action input flush did not finish", capture.completed)
            ready = select.select([descriptor, master], [], [], remaining)[0]
            assert ready, ("Action input flush did not finish", capture.completed)
            if master in ready:
                capture.feed(os.read(master, 65536))
            if descriptor in ready:
                assert os.read(descriptor, 1) == b"x", "Action caller exited before readiness"
                while select.select([master], [], [], 0)[0]:
                    assert time.monotonic() < deadline, "Action transcript exceeded readiness deadline"
                    chunk = os.read(master, 65536)
                    assert chunk, "Action terminal closed at readiness"
                    capture.feed(chunk)
                shown = capture.completed
                if shows(shown) if shows else CHOICE_ROW.search(shown):
                    return "\n".join(frames)
    finally:
        capture.listener = None
