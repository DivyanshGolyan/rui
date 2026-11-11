"""Terminal screen helpers that PTY fixtures share: read and step a terminal, wait
for screens and frames, and the Overview and consent prompts they match."""
import errno
import fcntl
import json
import os
import re
import select
import struct
import subprocess
import termios
import time

import model_fixture as fixture
import terminal_process as terminal_process_module
from terminal_process import answers_to


# The permission card's choice row: its buttons " Allow once " and " Deny ",
# two cells apart, inside the card's border. The highlighted one is drawn in
# reverse video only (see `highlighted`). Enter answers with the
# highlighted button, Allow once at first.
CHOICE = "Allow once    Deny"


ALLOW = b"\r"


# The choice row at any width; a card too small for its border drops it.
CHOICE_ROW = re.compile(r"^(?:│ )? Allow", re.M)


def highlighted(capture):
    """The button the latest committed frame's choice row draws in reverse
    video, or None when no choice row is shown."""
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
    """Move the card's highlight to Deny; return the first frame that shows
    it. The card answers the request it drew, so no new readiness follows."""
    capture = terminal_capture(master)
    return keyed_frame(master, b"\x1b[C", lambda screen, x, y: highlighted(capture) == "Deny")


def run(home, *args, success=True, environment=None, input=None):
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20, input=input)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (args, result.stdout, result.stderr)
    return result.stdout


CAPTURE_NOTICE = re.compile(r"request: (\S+) \(wait: rui request wait \1; if unconfirmed: rui request recover \1\)\n")


def admit(home, *args, expect=0, environment=None, input=None, cwd=None):
    """Generated capture: stderr names the pre-send handle; stdout is the saved answer."""
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True,
        text=True, timeout=20, input=input, cwd=cwd)
    assert result.returncode == expect, (args, result.stdout, result.stderr)
    notice = CAPTURE_NOTICE.match(result.stderr)
    assert notice, (args, result.stderr)
    admission = json.loads(result.stdout)
    assert admission["context"]["key"] == notice.group(1), (admission, result.stderr)
    return {"request": notice.group(1), "admission": admission, "stderr": result.stderr}


_captures = terminal_process_module.CAPTURES


def terminal_capture(master, *, fresh=False, silent=False):
    """The committed-screen observer for one PTY master, at its current size.
    It answers queries on that master unless `silent`."""
    from terminal_screen import ScreenCapture
    try:
        rows, columns = struct.unpack("HHHH", fcntl.ioctl(master, termios.TIOCGWINSZ, b"\0" * 8))[:2]
    except OSError:
        rows, columns = 24, 80  # Self-test pipes and sockets have no geometry.
    rows, columns = rows or 24, columns or 80
    capture = None if fresh else _captures.get(master)
    if capture is None:
        capture = ScreenCapture(columns, rows, reply=None if silent else answers_to(master))
        terminal_process_module.register_capture(master, capture)
    elif (capture.screen.columns, capture.screen.lines) != (columns, rows):
        capture.resize(columns, rows)
    return capture


def draining(master, observe, feed=None):
    """`observe`, after reading ready terminal output: a fixture waiting on
    the Host still drains the PTY as a terminal does. Darwin's holds 1 KiB, so
    a screen that stopped being read blocks mid-frame and runs no new work.
    `feed` takes the bytes; by default the master's registered capture."""
    feed = feed or terminal_capture(master).feed

    def drained():
        terminal_process_module.drain_ready(master, feed)
        return observe()
    return drained


def current_screen(master):
    """The latest committed frame: what the user sees now."""
    return terminal_capture(master).completed


def shown(text, screen):
    from terminal_screen import shown as wrapped
    return wrapped(text, screen)


def command_frame(master, command, accept, timeout=15, *, end="\r"):
    """Send `command` and `end`; return the first committed frame after it
    that `accept`s with the composer ready in that same frame. Page identity,
    readiness and any absence check then describe one shown frame.

    A command that ends with Enter is typed first, and Enter follows the
    frame that shows it in the composer. The reply is then a frame whose
    composer the command has left. That typed frame must not `accept`: a
    page stays shown while the next command runs, so a wait it already
    satisfies would return before the reply. Such a caller names what the
    reply changes, or leaves the page first."""
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


def conversation_text(frame):
    """Transcript rows alone, without a wide shell's list and divider."""
    return "\n".join(row.partition("│")[2] if "│" in row else row for row in frame.split("\n"))


def composer_line(screen, y):
    """The cursor row inside its pane, excluding a drawn list and divider."""
    lines = screen.split("\n")
    line = lines[y] if y < len(lines) else ""
    if not line.startswith((" ›", " >")) and "│" in line:
        line = line.partition("│")[2]
    return line


def composer_empty(screen, y):
    """The composer holds no draft: the cursor's row is its bare mark."""
    return composer_line(screen, y) in (" ›", " >")


def composer_ready(screen, x, y):
    """Input is accepted at the composer: the cursor sits on its prompt row."""
    if "Opening…" in screen:
        return False
    line = composer_line(screen, y)
    # The composer's mark follows the screen's one-column margin.
    return x >= 3 and any(line == " " + mark or line.startswith(" " + mark + " ") for mark in ("›", ">"))


def overview_composer(screen, x, y):
    """Input is accepted at the overview's composer: the cursor is on its row."""
    line = composer_line(screen, y)
    return x >= 3 and any(line == " " + mark or line.startswith(" " + mark + " ") for mark in ("›", ">"))


def keyed_frame(master, keys, accept, timeout=15):
    """Write `keys`; return the first committed frame after them that
    `accept`s, given the frame and its cursor. With no keys, the frame shown
    now counts."""
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
    """The overview's title row: रुई rui, or rui alone without Unicode."""
    return "rui" in frame.split("\n", 1)[0].split()[:2]


def overview_frame(master, accept, keys=b"", timeout=15):
    """The first overview frame after `keys` that `accept`s, with its
    composer taking input."""
    return keyed_frame(master, keys, lambda screen, x, y: accept(screen) and overview_composer(screen, x, y), timeout)


def read_terminal(master, marker, timeout=15, preserve_colour=False, *, composer=False, redraw=False, initial=b"", fresh=False):
    """Wait until a committed frame shows `marker`; return the frames shown.

    The renderer replaces whole frames, so each committed frame is checked as
    it arrives, not only the last. `composer` also requires a later (or the
    same) frame whose cursor is at the composer: the reply has been drawn and
    input is accepted again. The "› " marker alone waits for that composer.
    The result joins distinct frames seen during this wait, oldest first,
    bounded to the newest MiB; use current_screen for what is shown now.
    `fresh` requires a frame observed after this call, for repeated commands.
    """
    del preserve_colour, redraw  # Frames are cells, not a byte transcript.
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
        if not state["marker"] and marker in screen:
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
            # The response budget excludes observer work on long combining
            # cells; this is not a native wall-response performance claim.
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
    """Own both output streams until exit, including a late rendering prefix."""
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
    """Own startup output until the public metadata gate, not a silent wait."""
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
                    capture.feed(data)  # Later screen oracles continue from here.
                assert sum(map(len, streams.values())) < 1024 * 1024, "unexpected unbounded startup output"
            else:
                pending.remove(fd)
        assert reached.is_set() or (caller.poll() is None and time.monotonic() < deadline), (
            "terminal metadata gate not reached", context, caller.poll(),
            bytes(streams[master]), bytes(streams[errors_fd]))
    assert not streams[errors_fd], (context, bytes(streams[errors_fd]))
    return bytes(streams[master])


def next_frame(master, timeout=3):
    """Wait for the next committed frame; return it, or None if none came.

    An unchanged frame writes nothing, so a quiet wait is an answer here.
    """
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
    """The current frame if it already shows `marker` (at the composer when
    asked), else the frames until one does. A frame already shown is not
    redrawn, so a wait must not depend on seeing it again."""
    capture = terminal_capture(master)
    shown = capture.completed
    if marker in shown and (not composer or composer_ready(shown, capture.screen.cursor.x, capture.screen.cursor.y)):
        return shown
    return read_terminal(master, marker, timeout, composer=composer)


def return_to_live(master, live, key=b"\x1b", timeout=15):
    """Leave a page with `key`; return the first frame after it that shows
    the composer ready and that `live(screen)` accepts.

    App draws no page heading, so the key is always sent; the caller names
    what the live view shows. Esc at the live view would leave the Session.
    """
    return keyed_frame(master, key,
        lambda screen, x, y: composer_ready(screen, x, y) and live(screen), timeout)


# The clock that ends a live line ("⠹ Waiting · 12s") redraws every second
# while work runs; it is not a change of what the screen says.
LIVE_CLOCK = re.compile(r"^([⠹◌?] .+ · )(?:retry \d+ in )?\d+[hms](?: \d+[ms])?$", re.M)


def settle_screen(master, quiet=1.0, timeout=15):
    """Drain frames until none but a live clock's tick arrives for `quiet`
    seconds; return the screen. A ticking clock never goes quiet for a full
    second, so ticks alone must not keep the screen unsettled."""
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
    """Send one command and wait for its response boundary.

    Callers choose the response marker. `composer` returns the one fresh
    committed frame that shows the marker with input accepted again, so every
    check on the result describes that shown frame.
    """
    if composer:
        return command_frame(master, command, lambda frame: marker in frame)
    os.write(master, (command + "\r").encode())
    return read_terminal(master, marker, fresh=True)


def drop_spent_readiness(descriptor):
    """Discard notifications already queued, so the next wait reads one made
    after the input sent next: the card notifies once per request it draws,
    and a byte left from an earlier request would pass for this one."""
    while select.select([descriptor], [], [], 0)[0]:
        assert os.read(descriptor, 1) == b"x", "Action caller exited before readiness"


def action_ready(descriptor, master, timeout=15, *, shows=None, send=None):
    """Supply normal terminal credit until the card has drawn its request.

    Read exactly one notification, never a future request's byte. Return the
    distinct committed frames shown meanwhile. Deliberately withheld-credit
    controls must select the pipe directly. `shows` names the frame awaited
    when it is not the choice. `send` is input written first, after dropping
    notifications already queued, so the one read follows that input.
    """
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
                # The notification follows the final write/flush. Collect its
                # remaining queued bytes too, without waiting for another prompt.
                while select.select([master], [], [], 0)[0]:
                    assert time.monotonic() < deadline, "Action transcript exceeded readiness deadline"
                    chunk = os.read(master, 65536)
                    assert chunk, "Action terminal closed at readiness"
                    capture.feed(chunk)
                # Readiness is the drawn card with its choice.
                shown = capture.completed
                if shows(shown) if shows else CHOICE_ROW.search(shown):
                    return "\n".join(frames)
    finally:
        capture.listener = None
