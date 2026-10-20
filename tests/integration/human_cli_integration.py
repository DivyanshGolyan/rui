#!/usr/bin/env python3
"""Public one-shot caller recovery and exact Bash authorization."""
import errno
import json
import fcntl
import os
import pathlib
import pty
import re
import select
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

from host_process import canonical_fixture_root, dispose_all, preserve_failure_metadata, stop_process


# From 60 columns a user Message's first row ends with its admission time.
TIMED_ROW = re.compile(r"^(.*?) +(\d\d:\d\d)$")


def untimed(row):
    match = TIMED_ROW.match(row)
    return match.group(1) if match else row
from terminal_process import open_pty, terminal_process
import terminal_process as terminal_process_module
import model_fixture as fixture
import codex_integration as codex_fixture


def run(home, *args, success=True, environment=None):
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (args, result.stdout, result.stderr)
    return result.stdout


def terminal_safe_json(text):
    """Metadata JSON reaches terminals as printable ASCII and still decodes exactly."""
    unsafe = [character for character in text if not (" " <= character <= "~" or character == "\n")]
    assert not unsafe, ("raw terminal-unsafe characters in metadata JSON", unsafe, text)
    return json.loads(text)


def json_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from json_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from json_strings(item)


# The bypass default is explained only where /status reports it.
BYPASS_STATUS = "Permission: bypass (Bash runs without asking)"


def permission_row(frame, mode):
    """The exact /status row, unwrapped from a narrow page."""
    value = BYPASS_STATUS if mode == "bypass" else f"Permission: {mode}"
    return f"{value} Automatic compaction:" in " ".join(frame.split())


CAPTURE_NOTICE = re.compile(r"request: (\S+) \(inspect: rui request inspect \1; if unconfirmed: rui request recover \1\)\n")


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
    return {"request": notice.group(1), "admission": admission}


def invoke(home, *args, expect=0, environment=None):
    """Both streams of one call: metadata on stdout, notices on stderr."""
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20)
    assert result.returncode == expect, (args, result.stdout, result.stderr)
    return result


def defaults(home, *args, success=True, environment=None):
    """One defaults JSON value; failures leave stdout empty."""
    output = run(home, "defaults", "configure" if args else "inspect", *args,
        success=success, environment=environment)
    if not success:
        assert output == "", output
        return None
    value = json.loads(output)
    assert value["version"] == "1" and value["type"] == "defaults", value
    assert value["changed"] is bool(args), value
    return value


def help_case():
    with tempfile.TemporaryDirectory(prefix="rui-help.") as directory:
        home = pathlib.Path(directory)
        for flag in ("--help", "-h"):
            result = subprocess.run(
                [str(fixture.RUI), flag], env={**os.environ, "HOME": str(home)},
                capture_output=True, text=True, timeout=10,
            )
            assert result.returncode == 0, (flag, result.stdout, result.stderr)
            assert "rui [PROMPT]" in result.stdout, result.stdout
            assert not result.stderr, result.stderr
            assert list(home.iterdir()) == [], "help created runtime state"
        for command in ("session configure", "session inspect"):
            for flag in ("--help", "-h"):
                output = run(home, *command.split(), flag)
                assert output.startswith(f"rui {command} ["), output
                if command == "session configure":
                    for phrase in ("Omission preserves", "default resets", "Unknown models",
                                   "rui session inspect", "extra compaction headroom",
                                   "Changes apply to new model requests.",
                                   "Requests already accepted keep their original settings, even when retried."):
                        assert phrase in output, output
                assert list(home.iterdir()) == [], "scoped help created runtime state"
        for flag in ("--compaction-trigger", "--output-reservation"):
            for args in ((flag, "10", flag, "20"), ("--model", "--help"),
                         ("--session", "-h")):
                output = run(home, "session", "configure", *args, success=False)
                assert "rui session configure [" not in output, output
                assert list(home.iterdir()) == [], "invalid configuration captured a request"
        result = subprocess.run(
            [str(fixture.RUI), "--not-an-option"], env={**os.environ, "HOME": str(home)},
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode != 0 and "InvalidArguments" in result.stderr, result
        assert list(home.iterdir()) == [], "invalid arguments created runtime state"
        send_help = run(home, "session", "send", "--help")
        assert "\nRequires: --session REF or --session-hex HEX; --text FILE|- or TEXT|-.\n" in send_help, send_help
        assert "\nRequires: PROVIDER.\n" in run(home, "auth", "login", "--help")
        # Each syntactically valid call lacks one declared requirement and
        # fails before capture with scoped help, never the root usage.
        record = home / "explicit.json"
        for args, missing in (
                (("session", "send", "hi"), "missing --session REF or --session-hex HEX"),
                (("session", "send", "--session", "help/half", "--key", "half-key", "hi"), "missing --record FILE"),
                (("session", "send", "--session", "help/half", "--record", record, "hi"), "missing --key KEY or --key-hex HEX"),
                (("request", "recover", "--record", record, "--kind", "message"), "missing --store PATH or --store-hex HEX"),
                (("auth", "login"), "missing PROVIDER")):
            result = subprocess.run([str(fixture.RUI), *map(str, args)], env={**os.environ, "HOME": str(home)},
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            operation = " ".join(args[:2])
            assert result.returncode == 1 and result.stdout == "", (args, result)
            assert (f"rui: {operation}: {missing}. Nothing was captured or sent. "
                f"Usage: rui {operation} --help\n") in result.stderr, (args, result.stderr)
            assert "usage:" not in result.stderr and "rui [PROMPT]" not in result.stderr, (args, result.stderr)
            assert "request:" not in result.stderr, ("missing requirement printed a capture notice", result.stderr)
            assert list(home.iterdir()) == [], ("missing requirement created capture or record state", args)
        # Retired names are refused before any entry path, even with a
        # terminal that could otherwise reach the provider chooser.
        master, slave = pty.openpty()
        try:
            caller = subprocess.Popen([str(fixture.RUI), "setup"],
                env={**os.environ, "HOME": str(home), "TERM": "xterm-256color"},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            output, errors = terminal_exit(caller, master)
        finally:
            dispose_all(lambda: os.close(master), lambda: os.close(slave))
        assert caller.returncode == 1, (output, errors)
        assert ("rui: `setup` is now `rui defaults inspect|configure`; see rui defaults --help. "
            "Nothing was captured or sent. To start a conversation with this text, put -- before it: rui -- TEXT.\n").encode() in errors, errors
        assert b"Provider:" not in output + errors and b"Codex login" not in output + errors, (output, errors)
        assert b"usage:" not in errors and b"rui [PROMPT]" not in errors, errors
        assert list(home.iterdir()) == [], "retired name created runtime state"
        # After --, the same word is a prompt: it reaches bare entry, which
        # refuses here only because no terminal is attached.
        literal = subprocess.run([str(fixture.RUI), "--", "setup"], env={**os.environ, "HOME": str(home)},
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        assert literal.returncode == 1 and "InteractiveTerminalRequired" in literal.stderr, literal
        assert "is now" not in literal.stderr, literal.stderr
        assert list(home.iterdir()) == [], "literal prompt without a terminal created runtime state"


def compaction_settings_case(home, store, workspace):
    # Pages word-wrap; phrases are checked across their soft breaks.
    flat = lambda text: " ".join(text.split())
    session = "human/compaction-settings"
    run(home, "session", "configure", "--store", store, "--session", session,
        "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-luna")
    with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
        "--", session], env={**os.environ, "HOME": str(home)}) as (entered, master):
        read_terminal(master, "› ")
        status = flat(status_frame(master, session))
        assert "244800 tokens (model default)" in status, status
        assert "Extra compaction headroom: 0 tokens (model default); not a guaranteed output budget" in status, status
        usage = flat(terminal_step(master, "/configure --bogus", "Omission preserves", composer=True))
        assert "Unknown models have no automatic threshold" in usage, usage
        assert "Changes apply to new model requests." in usage, usage
        assert "Requests already accepted keep their original settings, even when retried." in usage, usage
        for flags, trigger, headroom in (
            ("--compaction-trigger 12345 --output-reservation 234", "12345 tokens (Session override)", "234 tokens (Session override)"),
            ("--permission-mode ask", "12345 tokens (Session override)", "234 tokens (Session override)"),
            ("--compaction-trigger default --output-reservation default", "244800 tokens (model default)", "0 tokens (model default)"),
        ):
            configured = configured_frame(master, "/configure " + flags)
            assert "revision:" not in configured and "request:" not in configured, configured
            status = flat(status_frame(master, session))
            assert trigger in status and "Extra compaction headroom: " + headroom in status, status
            assert "Output reservation:" not in status and "source unknown" not in status, status
            assert "not a guaranteed output budget" in status, status
        terminal_step(master, "/exit", "Detached.")
        assert entered.wait(timeout=5) == 0
    records = set((home / ".config/rui/requests").glob("*.json"))
    for flag in ("--compaction-trigger", "--output-reservation"):
        run(home, "session", "configure", "--store", store, "--session", session,
            flag, "10", flag, "20", success=False)
        assert set((home / ".config/rui/requests").glob("*.json")) == records
    report = json.loads(run(home, "session", "inspect", "--store", store, "--session", session))
    assert report["session"]["model"] == "gpt-6-luna", report
    unknown = "human/compaction-unknown-model"
    run(home, "session", "configure", "--store", store, "--session", unknown,
        "--workspace", workspace, "--provider", "codex", "--model", "unknown-model")
    with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
        "--", unknown], env={**os.environ, "HOME": str(home)}) as (entered, master):
        read_terminal(master, "› ")
        status = flat(terminal_step(master, "/status", "Work: ", composer=True))
        assert "no automatic threshold (model default)" in status, status
        assert "Use /configure --compaction-trigger TOKENS to enable a threshold." in status, status
        assert "Provider context-overflow recovery still applies." in status, status
        terminal_step(master, "/exit", "Detached.")
        assert entered.wait(timeout=5) == 0


def preference_edits(home, store):
    """Exact saved intent, independent of prospective recommendation output."""
    defaults(home, "--store", store, "--provider", "codex", "--model", "gpt-6-luna")
    saved = home / ".config/rui/preferences"
    pinned = f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
    cleared = f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=\n"
    assert saved.read_text() == pinned
    defaults(home, "--store", store)
    assert saved.read_text() == pinned, "omitted model lost its selection"
    assert defaults(home, "--clear-model")["model"] is None
    assert saved.read_text() == cleared, "clear persisted a recommendation or retained the model"
    defaults(home)
    assert saved.read_text() == cleared, "inspection persisted a recommendation"
    for flags in (("--clear-model", "--model", "gpt-6-luna"),
                  ("--model", "gpt-6-luna", "--clear-model"), ("--model", "")):
        defaults(home, *flags, success=False)
        assert saved.read_text() == cleared, "rejected edit changed preferences"
    saved.write_text(pinned.replace("provider=codex", "provider=retired").replace("gpt-6-luna", "old-model"))
    defaults(home, "--clear-model")
    assert saved.read_text() == cleared.replace("provider=codex", "provider=retired")
    assert defaults(home)["next_session"] == {"status": "unsupported_provider"}
    defaults(home, "--provider", "codex", "--clear-model")
    assert saved.read_text() == cleared
    defaults(home, "--model", "gpt-6-luna")
    assert saved.read_text() == pinned


def read_pipe_output(stream, *, count=None, timeout=10):
    """Read one complete line or an exact prefix without consuming later output.

    Use raw descriptor reads consistently: a buffered readline after select can
    still block, and read-ahead would invalidate the large-result backpressure case.
    """
    limit = 16 * 1024
    assert count is None or 0 < count <= limit, count
    output = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([stream], [], [], remaining)[0], (
            "pipe output deadline exceeded", count, bytes(output))
        chunk = os.read(stream.fileno(), 1 if count is None else count - len(output))
        assert chunk, ("pipe closed before complete output", count, bytes(output))
        output.extend(chunk)
        if (count is None and output.endswith(b"\n")) or len(output) == count:
            return bytes(output)
        assert len(output) < limit, ("pipe record exceeds 16 KiB", bytes(output))


_captures = terminal_process_module.CAPTURES


def terminal_capture(master, *, fresh=False):
    """The committed-screen observer for one PTY master, at its current size."""
    from terminal_screen import ScreenCapture
    try:
        rows, columns = struct.unpack("HHHH", fcntl.ioctl(master, termios.TIOCGWINSZ, b"\0" * 8))[:2]
    except OSError:
        rows, columns = 24, 80  # Self-test pipes and sockets have no geometry.
    rows, columns = rows or 24, columns or 80
    capture = None if fresh else _captures.get(master)
    if capture is None:
        capture = _captures[master] = ScreenCapture(columns, rows)
    elif (capture.screen.columns, capture.screen.lines) != (columns, rows):
        capture.resize(columns, rows)
    return capture


def forget_terminal(master):
    _captures.pop(master, None)


def current_screen(master):
    """The latest committed frame: what the user sees now."""
    return terminal_capture(master).completed


def shown(text, screen):
    from terminal_screen import shown as wrapped
    return wrapped(text, screen)


def command_frame(master, command, accept, timeout=15):
    """Send `command`; return the first committed frame after it that
    `accept`s with the composer ready in that same frame. Page identity,
    readiness and any absence check then describe one shown frame."""
    capture = terminal_capture(master)
    found = []

    def observe(screen, x, y):
        if not found and accept(screen) and composer_ready(screen, x, y):
            found.append(screen)

    capture.listener = observe
    try:
        os.write(master, (command + "\n").encode())
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


def status_frame(master, session, command="/status", timeout=15):
    """The /status page for exactly `session` (escaped as /status shows it)."""
    escaped = session.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    line = "\nSession: " + escaped + "\n"
    return command_frame(master, command, lambda frame: frame.startswith("Browsing · Esc returns\n")
        and line in frame and "\nWork: " in frame, timeout)


def configured_frame(master, command):
    """The live frame whose status row reports this Configure's success."""
    return command_frame(master, command, lambda frame: "Configured." in frame.split("\n")
        and not frame.startswith("Browsing"))


def composer_ready(screen, x, y):
    """Input is accepted at the composer: the cursor sits on its prompt row."""
    if "Opening…" in screen:
        return False
    line = screen.split("\n")[y] if y < len(screen.split("\n")) else ""
    return x >= 2 and (line == "›" or line.startswith("› ") or line == ">" or line.startswith("> "))


def read_terminal(master, marker, timeout=15, preserve_colour=False, *, composer=False, redraw=False, initial=b""):
    """Wait until a committed frame shows `marker`; return the frames shown.

    The renderer replaces whole frames, so each committed frame is checked as
    it arrives, not only the last. `composer` also requires a later (or the
    same) frame whose cursor is at the composer: the reply has been drawn and
    input is accepted again. The "› " marker alone waits for that composer.
    The result joins distinct frames seen during this wait, oldest first,
    bounded to the newest MiB; use current_screen for what is shown now.
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


def permanent_tool_count(screen, heading):
    """Count a call heading's rows in one frame (not repeated frames)."""
    return len(re.findall(r"(?m)^" + re.escape(heading) + r"$", screen))


def pipe_wait_oracles():
    reader, writer = os.pipe()
    with os.fdopen(reader, "rb", buffering=0) as stream:
        try:
            os.write(writer, "first café\nsecond\ntail".encode())
            assert read_pipe_output(stream) == "first café\n".encode()
            assert read_pipe_output(stream) == b"second\n"
            assert read_pipe_output(stream, count=2) == b"ta"
            assert os.read(reader, 2) == b"il", "prefix reader consumed unread output"
            for prefix in (b"", b"unfinished"):
                if prefix:
                    os.write(writer, prefix)
                try:
                    read_pipe_output(stream, timeout=0.5)
                except AssertionError as error:
                    assert error.args[0] == ("pipe output deadline exceeded", None, prefix), error
                else:
                    raise AssertionError("unterminated record accepted")
            os.write(writer, b"short")
        finally:
            os.close(writer)
        try:
            read_pipe_output(stream, count=6)
        except AssertionError as error:
            assert error.args[0] == ("pipe closed before complete output", 6, b"short"), error
        else:
            raise AssertionError("pipe EOF accepted as a complete prefix")
    with tempfile.TemporaryFile() as stream:
        stream.write(b"x" * (16 * 1024))
        stream.seek(0)
        try:
            read_pipe_output(stream)
        except AssertionError as error:
            assert error.args[0] == ("pipe record exceeds 16 KiB", b"x" * (16 * 1024)), error
        else:
            raise AssertionError("unbounded pipe record accepted")
    print("pipe wait oracles passed: exact records/prefix, unread suffix, EOF, partial deadline and byte bound", flush=True)


def terminal_frame(lines, cursor=None):
    """One synchronized full-screen frame as the renderer commits it."""
    row, column = cursor if cursor is not None else (len(lines), len(lines[-1]) + 1 if lines else 1)
    body = "\r\n".join(lines)
    return f"\x1b[?2026h\x1b[H\x1b[2J{body}\x1b[{row};{column}H\x1b[?2026l".encode()


def terminal_wait_oracles():
    """Committed frames are evidence; partial frames and diagnostics are not."""
    def collect(frames, marker, *, composer=False, error=None, close_output=False, initial=b""):
        reader, writer = os.pipe()
        forget_terminal(reader)
        stopped = threading.Event()

        def produce():
            try:
                for frame in frames:
                    while frame:
                        frame = frame[os.write(writer, frame):]
                if not close_output:
                    stopped.wait()
            except BrokenPipeError:
                pass  # The expected collector refusal closes its reader.
            finally:
                dispose_all(lambda: os.close(writer))

        thread = threading.Thread(target=produce)
        thread.start()
        try:
            try:
                options = {"timeout": 0.5} if error == "deadline" else {}
                output = read_terminal(reader, marker, composer=composer, initial=initial, **options)
            except AssertionError as failure:
                assert error is not None, failure
                if error == "deadline":
                    assert isinstance(failure.args[0], tuple) and failure.args[0][0] == marker, failure
                    assert failure.terminal_metadata["received_bytes"] == sum(map(len, frames)), failure.terminal_metadata
                elif error == "closed":
                    assert failure.args[0][:2] == ("terminal closed before marker", marker), failure
                    assert failure.terminal_metadata["received_bytes"] == sum(map(len, frames)), failure.terminal_metadata
                else:
                    assert str(failure) == error, failure
            else:
                assert error is None, ("incomplete terminal boundary was accepted", output)
                return output
        finally:
            def join_producer():
                thread.join(timeout=2)
                assert not thread.is_alive(), "terminal oracle producer did not retire"

            dispose_all(lambda: os.close(reader), lambda: forget_terminal(reader), stopped.set, join_producer)

    ready = terminal_frame(["answer shown", "", "›"], (3, 3))
    # A marker drawn in a frame that the same write replaces is still seen.
    replaced = terminal_frame(["transient café"], (1, 1)) + terminal_frame(["later"], (1, 1))
    assert "transient café" in collect([replaced], "transient café")
    # In the full screen, bytes outside a committed frame, or an unfinished
    # frame, are not shown.
    collect([b"\x1b[?1049htransient"], "transient", error="deadline")
    collect([b"\x1b[?1049h" + terminal_frame(["shown"])[:-8]], "shown", error="deadline")
    # The main screen is a stream: text before entry or after restoration.
    restored = b"\x1b[?1049h" + terminal_frame(["inside"]) + b"\x1b[?2026l\x1b[0m\x1b[?2004l\x1b[?25h\x1b[?1049l\r\nResume: rui session resume x\r\n"
    assert "Resume: rui session resume x\n" in collect([restored], "Resume: ")
    collect([b"\x1b[?1049h" + terminal_frame(["Resume: inside"])], "Resume: ")
    # Split writes still commit the whole frame, including split UTF-8.
    frame = terminal_frame(["split café 中"])
    assert "split café 中" in collect([frame[n:n + 5] for n in range(0, len(frame), 5)], "split café 中")
    # Composer readiness needs the cursor on the prompt after the marker.
    diagnostic = "RequestBindingMismatch"
    collect([terminal_frame([diagnostic], (1, 1))], diagnostic, composer=True, error="deadline")
    collect([terminal_frame([diagnostic, "›"], (1, 1))], diagnostic, composer=True, error="deadline")
    output = collect([terminal_frame([diagnostic], (1, 1)), terminal_frame([diagnostic, "›"], (2, 3))], diagnostic, composer=True)
    assert diagnostic in output
    # Opening is not input readiness, even with the cursor at the prompt.
    collect([terminal_frame(["Opening…", "›"], (2, 3))], "› ", error="deadline")
    assert "answer shown" in collect([ready], "› ")
    # A retained draft row counts as the composer; its text is the draft.
    edited = "› fresh café"
    assert edited in collect([terminal_frame([edited], (1, 13))], edited, composer=True)
    # Frames committed before this wait are not evidence for it.
    reader, peer = socket.socketpair()
    with reader, peer:
        forget_terminal(reader.fileno())
        peer.sendall(terminal_frame(["old reply", "›"], (2, 3)))
        assert "old reply" in read_terminal(reader.fileno(), "old reply", composer=True)
        try:
            read_terminal(reader.fileno(), "old reply", timeout=0.3)
        except AssertionError:
            pass
        else:
            raise AssertionError("an earlier frame satisfied a later wait")
        forget_terminal(reader.fileno())
    # The command writer: a queued composer cannot acknowledge a command.
    for command, marker in (("/configure --model model-a", "Configured."), ("/status", "Session: example")):
        stale = terminal_frame(["› /con"], (1, 7))
        for suffix in (b"", terminal_frame([marker], (1, 1)), terminal_frame([marker, "›"], (2, 3))):
            reader, peer = socket.socketpair()
            with reader, peer:
                forget_terminal(reader.fileno())
                peer.settimeout(1)
                peer.sendall(stale + suffix)
                peer.shutdown(socket.SHUT_WR)
                try:
                    output = terminal_step(reader.fileno(), command, marker, composer=True)
                except AssertionError as failure:
                    assert suffix != terminal_frame([marker, "›"], (2, 3)), failure
                    assert failure.args[0] == ("terminal closed before command result", command), failure
                else:
                    assert suffix == terminal_frame([marker, "›"], (2, 3)), (command, output)
                assert peer.recv(4096) == (command + "\n").encode()
                forget_terminal(reader.fileno())
    # Command results: identity, readiness and absence describe one fresh
    # committed frame, not readiness or a Session borrowed from earlier ones.
    session = 's/é"\n'
    page = ["Browsing · Esc returns", 'Session: s/é\\"\\n', "Permission: bypass (Bash runs without asking)", "Work: completed", "", "›"]
    def frame_after(command, chunks, read):
        reader, peer = socket.socketpair()
        with reader, peer:
            forget_terminal(reader.fileno())
            peer.settimeout(1)
            peer.sendall(b"".join(chunks))
            peer.shutdown(socket.SHUT_WR)
            try:
                return read(reader.fileno())
            except AssertionError as failure:
                assert failure.args[0][0] == "terminal closed before command result", failure
                return None
            finally:
                assert peer.recv(4096) == (command + "\n").encode()
                forget_terminal(reader.fileno())
    status = lambda fd: status_frame(fd, session)
    configured = lambda fd: configured_frame(fd, "/configure --model m")
    unavailable = terminal_frame(["Browsing · Esc returns", "rui: status: StatusUnavailable", "", "›"], (4, 3))
    assert frame_after("/status", [terminal_frame(page[:2], (2, 1)), unavailable], status) is None
    assert frame_after("/status", [terminal_frame([page[0], "Session: other"] + page[2:], (6, 3))], status) is None
    assert frame_after("/status", [terminal_frame(page, (1, 1))], status) is None  # Not at the composer.
    shown = frame_after("/status", [terminal_frame(["✓ Inspect café", "", "›"], (3, 3)), terminal_frame(page, (6, 3))], status)
    assert shown is not None and "Inspect café" not in shown, shown  # A transient live outcome is legitimate.
    live = ["answer", "Configured.", "›"]
    assert frame_after("/configure --model m", [terminal_frame(live, (2, 1))], configured) is None
    assert frame_after("/configure --model m", [terminal_frame(["Browsing · Esc returns"] + live, (4, 3))], configured) is None
    assert frame_after("/configure --model m", [terminal_frame(live, (3, 3))], configured) is not None
    # Every command step with a composer check binds marker and readiness to
    # one frame: a marker frame that is not ready, then a ready frame without
    # the marker, is no result.
    step = lambda fd: terminal_step(fd, "/requests", "Recovery handles", composer=True)
    marked = terminal_frame(["Browsing · Esc returns", "Recovery handles", "", "›"], (1, 1))
    assert frame_after("/requests", [marked, terminal_frame(["answer", "›"], (2, 3))], step) is None
    assert "Recovery handles" in frame_after("/requests", [marked, terminal_frame(
        ["Browsing · Esc returns", "Recovery handles", "", "›"], (4, 3))], step)
    reader, peer = socket.socketpair()
    with reader, peer:  # A page committed before the command is not its result.
        forget_terminal(reader.fileno())
        peer.sendall(terminal_frame(page, (6, 3)))
        read_terminal(reader.fileno(), "Work: ", composer=True)
        try:
            status_frame(reader.fileno(), session, "/status", timeout=0.3)
        except AssertionError:
            pass
        else:
            raise AssertionError("an earlier page satisfied a later command")
        forget_terminal(reader.fileno())
    # Many large frames keep the newest MiB and still find the marker.
    large = [terminal_frame([f"frame {n} " + "x" * 70] * 49) for n in range(400)] + [terminal_frame(["final marker", "›"], (2, 3))]
    output = collect(large, "final marker", composer=True)
    assert "final marker" in output and len(output.encode()) < 1024 * 1024, len(output)
    collect([terminal_frame(["distinctive prefix"])], "required cursor", close_output=True, error="closed")
    # Linux PTY closure reports EIO; Darwin reports an empty read. Neither is
    # input readiness or a deadline failure, and both retain the same context.
    master, slave = open_pty()
    os.close(slave)
    try:
        try:
            read_terminal(master, "required cursor", timeout=0.5)
        except AssertionError as failure:
            assert failure.args[0][:2] == ("terminal closed before marker", "required cursor"), failure
            assert failure.terminal_metadata["received_bytes"] == 0, failure.terminal_metadata
        else:
            raise AssertionError("closed PTY became a ready terminal")
    finally:
        os.close(master)
        forget_terminal(master)
    print("terminal wait oracles passed: committed frames only, replaced frames seen, composer cursor, bounded frames and closure", flush=True)


def assert_permission_workspace(output, workspace, columns=80):
    """Join only hanging-indent layout breaks; retain every exact path byte.

    A path that fits a continuation row but not the label's row starts on
    the next row, leaving the label at the end of its own.
    """
    fields = output.split("\n  Workspace:", 1)
    assert len(fields) == 2 and "\n  Time limit:" in fields[1], ("Action fields missing", output)
    shown = fields[1].split("\n  Time limit:", 1)[0]
    assert re.sub(r"^ |\n {2,}", "", shown) == str(workspace), output
    assert all(len(line) <= columns for line in ("  Workspace:" + shown).splitlines()), output


def shown_bash_command(master):
    """The current Action's "$ " command, rejoined across wrapped rows.

    Continuations are indented four columns. As in raw_export, a row filled
    to the edge broke inside a word; any other soft break consumed a space.
    """
    capture = terminal_capture(master)
    width = capture.screen.columns
    rows = [line.rstrip() for line in capture.screen.display]
    start = next(index for index, line in enumerate(rows) if line.startswith("  $ "))
    command = rows[start][4:]
    previous = rows[start]
    for line in rows[start + 1:]:
        if not line.startswith("    "):
            break
        command += ("" if len(previous) >= width else " ") + line[4:]
        previous = line
    return command


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
                chunk = os.read(fd, 65536)
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
                data = os.read(fd, 65536)
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


# Palette index 12 as pyte reports SGR 94 or 38;5;12.
USER_COLOUR = {"brightblue", "5c5cff"}
# Palette index 3 (attention) as SGR 33 or 38;5;3.
ATTENTION_COLOUR = {"brown", "cdcd00"}


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


def scroll_until(master, key, marker, *, presses=40):
    """Press `key` until the committed screen shows `marker`; return frames.

    A press that moves nothing at an edge draws nothing, and a page load can
    draw several frames, so each press drains frames until output is quiet.
    """
    seen = []
    for _ in range(presses):
        if marker in current_screen(master):
            return "\n".join(seen)
        os.write(master, key)
        while (frame := next_frame(master, 1)) is not None:
            seen.append(frame)
    assert marker in current_screen(master), ("scroll did not reach marker", key, marker, current_screen(master))
    return "\n".join(seen)


def await_screen(master, marker, *, composer=False, timeout=15):
    """The current frame if it already shows `marker` (at the composer when
    asked), else the frames until one does. A frame already shown is not
    redrawn, so a wait must not depend on seeing it again."""
    capture = terminal_capture(master)
    shown = capture.completed
    if marker in shown and (not composer or composer_ready(shown, capture.screen.cursor.x, capture.screen.cursor.y)):
        return shown
    return read_terminal(master, marker, timeout, composer=composer)


def return_to_live(master, key=b"\x1b", timeout=15, *, input_fd=None):
    """Leave browsing or an inspection; wait until live output is drawn.

    A lone Esc completes only after the decoder's deadline, so the next
    bytes must wait for this frame or they would join it as Alt-<key>.
    """
    capture = terminal_capture(master)
    shown = capture.completed
    if not shown.startswith("Browsing") and composer_ready(shown, capture.screen.cursor.x, capture.screen.cursor.y):
        return shown  # Already live: Esc would draw nothing to wait for.
    os.write(master if input_fd is None else input_fd, key)
    deadline = time.monotonic() + timeout
    while True:
        shown = capture.completed
        if (not shown.startswith("Browsing")
                and composer_ready(shown, capture.screen.cursor.x, capture.screen.cursor.y)):
            return shown
        remaining = deadline - time.monotonic()
        assert remaining > 0 and next_frame(master, remaining) is not None, ("did not return to live", shown)


def settle_screen(master, quiet=1.0, timeout=15):
    """Drain frames until none arrives for `quiet` seconds; return the screen."""
    deadline = time.monotonic() + timeout
    while next_frame(master, quiet) is not None:
        assert time.monotonic() < deadline, ("screen never settled", current_screen(master))
    return current_screen(master)


def raw_export(master, screen):
    """The printed raw export command, rejoined across word-wrapped rows.

    Word wrap consumes the space at a soft break; a row filled to the edge
    broke inside a word instead (a long hex identity), so it joins directly.
    """
    columns = terminal_capture(master).screen.columns
    lines = screen.split("\n")
    start = next(index for index, line in enumerate(lines) if line.startswith("Raw export: "))
    command = lines[start].removeprefix("Raw export: ")
    previous = lines[start]
    for line in lines[start + 1:]:
        if re.search(r"--ordinal [0-9]+$", command):
            break
        command += ("" if len(previous) == columns else " ") + line
        previous = line
    assert re.search(r"--ordinal [0-9]+$", command), screen
    return command


def drawn_style(master, text, offset=0):
    """Cell style where the latest committed frame draws `text`."""
    return terminal_capture(master).style(text, offset)


def terminal_step(master, command, marker, *, composer=False):
    """Send one command and wait for its response boundary.

    Callers choose the response marker. `composer` returns the one fresh
    committed frame that shows the marker with input accepted again, so every
    check on the result describes that shown frame.
    """
    if composer:
        return command_frame(master, command, lambda frame: marker in frame)
    os.write(master, (command + "\n").encode())
    return read_terminal(master, marker)


def command_entry_cases():
    """Familiar entry routes use the same captured intent and conversation."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-command-entry."))
    home = state / "home"
    (home / ".config/rui").mkdir(parents=True, mode=0o700)
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    codex_fixture.credentials(home / ".config/rui/codex.json")
    prompt = "/status\nkeep //literal café"
    held_release = threading.Event()
    permission_release = threading.Event()
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("entry-answer", "entry-reason", "entry-message", "Initial prompt answered.")[0],
        fixture.sse_answer("older-answer", "older-reason", "older-message", "Older Session active.")[0],
        (fixture.sse_answer("exec-answer", "exec-reason", "exec-message", "# Literal **answer** café\n\x1b[31mnot a control")[0], held_release),
        fixture.sse_answer("stdin-answer", "stdin-reason", "stdin-message", "Stdin answered.")[0],
        fixture.ResponseSpec(b'{"error":"denied"}', {}, 401),
        fixture.sse_answer("lost-answer", "lost-reason", "lost-message", "Lost reply recovered.")[0],
        (fixture.sse_tool_calls("exec-tools", [("bash", "exec-call", json.dumps({"cmd": "touch must-not-run", "description": "Create forbidden marker", "timeout_ms": None}))]), permission_release),
        fixture.sse_answer("dash-answer", "dash-reason", "dash-message", "Literal dash answered.")[0],
        fixture.sse_answer("option-answer", "option-reason", "option-message", "Literal option answered.")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = lookalike_host = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        defaults(home, "--store", store, "--provider", "codex", "--model", "gpt-6-luna")
        master, slave = open_pty()
        original = termios.tcgetattr(slave)
        caller = subprocess.Popen([str(fixture.RUI), prompt], cwd=workspace,
            env={**os.environ, "HOME": str(home), "TERM": "xterm-256color", "NO_COLOR": ""},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        output = read_terminal(master, "Initial prompt answered.", composer=True)
        prompt_cell = drawn_style(master, "› ")
        assert prompt_cell is not None and prompt_cell.fg in USER_COLOUR, (prompt_cell, output)
        assert "Provider:" not in output and "Assistant:" not in output, output
        assert len(endpoint.requests) == 1
        request = json.loads(endpoint.requests[0])
        user = [item for item in request["input"] if item.get("role") == "user"]
        assert user[-1]["content"][0]["text"] == prompt, user
        terminal_step(master, "/exit", "Resume: ")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0 and not errors, errors
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original
        initial_session = json.loads(run(home, "session", "list", "--all"))["sessions"][0]["reference"]
        # More than one eight-row page here; a newer foreign Workspace must not
        # win --last. Exact resume is independent of that cwd filtering.
        other = state / "other"
        other.mkdir()
        for index in range(9):
            run(home, "session", "configure", "--session", f"last/{index}", "--workspace", workspace,
                "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
        run(home, "session", "configure", "--session", "foreign/newer", "--workspace", other,
            "--provider", "codex", "--model", "model-b", "--permission-mode", "ask")
        older = admit(home, "session", "send", "--session", "last/0", "older activity")
        fixture.wait_for(lambda: fixture.completed_observation(store, older["request"]), "older Session activity")
        alias = state / "workspace-alias"
        alias.symlink_to(workspace, target_is_directory=True)
        for flags, expected in ((("--last",), "last/8"), ((initial_session,), initial_session)):
            for terminal, no_colour in (("xterm-256color", ""), ("xterm-256color", "1"), ("dumb", "")):
                caller = subprocess.Popen([str(fixture.RUI), "session", "resume", *flags], cwd=alias,
                    env={**os.environ, "HOME": str(home), "TERM": terminal, "NO_COLOR": no_colour},
                    stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                if terminal == "dumb":
                    # Without cursor addressing Rui refuses before any Host or
                    # terminal change, naming the recovery.
                    _, errors = caller.communicate(timeout=10)
                    assert caller.returncode == 1, (caller.returncode, errors)
                    assert b"TERM=dumb does not" in errors and b"No Host or Session changed." in errors, errors
                    assert not select.select([master], [], [], 0.2)[0], "dumb terminal was drawn"
                    assert termios.tcgetattr(slave) == original or sys.platform == "darwin"
                    continue
                opening = read_terminal(master, "› ")
                prompt_cell = drawn_style(master, "› ")
                coloured = prompt_cell is not None and prompt_cell.fg in USER_COLOUR
                assert prompt_cell is not None and coloured == (no_colour == ""), (prompt_cell, opening)
                status = terminal_step(master, "/status", "Session: ", composer=True)
                assert f"Session: {expected}\n" in status, status
                terminal_step(master, "/exit", "Resume: ")
                _, errors = terminal_exit(caller, master)
                assert caller.returncode == 0 and not errors, errors
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                assert actual == original
        assert len(endpoint.requests) == 2, "resume submitted or restarted work"
        env = {**os.environ, "HOME": str(home)}
        # Fresh Configure without a selector creates rui/<key> with concrete
        # cwd and saved-default settings. Send returns at admission while the
        # provider answer is still held; the saved answer is exact bytes.
        fresh = admit(home, "session", "configure", cwd=workspace)
        created = fresh["admission"]["answer"]
        assert created["status"] == "accepted" and created["created"] is True, created
        selected = created["session"]
        assert selected == "rui/" + fresh["request"], created
        settings = fixture.command("session", "inspect", "--store", store, "--session", selected)["session"]
        assert (settings["workspace"], settings["provider"], settings["model"], settings["tools"],
            settings["permission_mode"]) == (str(workspace), "codex", "gpt-6-luna", ["bash"], "bypass"), settings
        held = admit(home, "session", "send", "--session", selected, "held prompt", cwd=workspace)
        assert held["admission"]["answer"]["status"] == "accepted", held
        fixture.wait_for(lambda: len(endpoint.requests) == 3, "held provider request")
        assert "result" not in fixture.observe(store, held["request"]), "send waited for or invented an answer"
        held_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, held["request"]), "held answer")
        assert fixture.read_result(store, held["request"]) == "# Literal **answer** café\n\x1b[31mnot a control".encode()
        piped = admit(home, "session", "send", "--session", selected, "-", input="/literal\nstdin café\n", cwd=workspace)
        fixture.wait_for(lambda: fixture.completed_observation(store, piped["request"]), "stdin answer")
        assert fixture.read_result(store, piped["request"]) == b"Stdin answered."
        stdin_user = [item for item in json.loads(endpoint.requests[3])["input"] if item.get("role") == "user"]
        assert stdin_user[-1]["content"][0]["text"] == "/literal\nstdin café\n", stdin_user
        failed = admit(home, "session", "send", "--session", selected, "failure", cwd=workspace)
        observation = fixture.wait_for(lambda: (value if (value := fixture.observe(store, failed["request"])).get("result") else None),
            "failed provider result")
        assert observation["result"] == {"status": "failed", "code": "provider_http_401"}, observation
        unavailable = subprocess.run([str(fixture.RUI), "request", "read-result", failed["request"]], env=env,
            capture_output=True, timeout=10)
        # Content stays content-only: the typed diagnostic goes to stderr.
        assert unavailable.returncode == 1 and unavailable.stdout == b"", unavailable
        assert json.loads(unavailable.stderr.splitlines()[0])["error"]["code"] == "result_failed", unavailable
        proxy = canonical.ReplyProxy(host, "/v1/message", lambda _: b"")
        lost = subprocess.run([str(fixture.RUI), "session", "send", "--session", selected, "lost original"], cwd=workspace,
            env=env, capture_output=True, text=True, timeout=10)
        assert lost.returncode != 0 and lost.stdout == "", lost
        receipt = CAPTURE_NOTICE.match(lost.stderr)
        assert receipt, lost.stderr
        handle = receipt.group(1)
        record = home / ".config/rui/requests" / (handle + ".json")
        original_record = record.read_bytes()
        proxy.close()
        proxy = None
        fixture.wait_for(lambda: fixture.completed_observation(store, handle), "lost send original answer")
        assert json.loads(run(home, "request", "recover", handle))["answer"]["replayed"] is True
        assert record.read_bytes() == original_record and len(endpoint.requests) == 6, "recovery replaced uncertain input"
        blocked = admit(home, "session", "send", "--session", selected, "needs approval", cwd=workspace)
        fixture.wait_for(lambda: len(endpoint.requests) == 7, "held tool request")
        # Permission mode is selected at proposal admission, not dispatch.
        admit(home, "session", "configure", "--session", selected, "--permission-mode", "ask")
        permission_release.set()
        current = fixture.wait_for(lambda: (value if (value := fixture.command("session", "inspect", "--store", store,
            "--session", selected))["actionable_permissions"] else None), "blocked Action proposal")
        assert not (workspace / "must-not-run").exists(), current
        assert "result" not in fixture.observe(store, blocked["request"]), "blocked send completed"
        assert len(endpoint.requests) == 7, "blocked send authorized or continued work"
        # Accepted configuration survives failure before conversation entry.
        records = home / ".config/rui/requests"
        before_entry = set(records.glob("*.json"))
        caller = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**env, "TMPDIR": "not-absolute"}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        output, errors = terminal_exit(caller, master)
        assert caller.returncode != 0 and b"InvalidTemporaryDirectory" in errors, (output, errors)
        caller.stderr.close()
        added = set(records.glob("*.json")) - before_entry
        assert len(added) == 1, added
        saved = json.loads(next(iter(added)).read_bytes())
        assert "configuration" in saved, saved
        assert json.loads(run(home, "request", "recover", saved["key"]))["answer"]["replayed"] is True
        assert f"Configuration request: {saved['key']}".encode() in errors, errors
        assert b"Fix or unset TMPDIR before resuming." in errors, errors
        resume = errors.decode().split("Resume: ", 1)[1].splitlines()[0]
        assert "rui session resume --store " in resume, resume
        public_bin = state / "bin"
        public_bin.mkdir()
        (public_bin / "rui").symlink_to(fixture.RUI)
        caller = subprocess.Popen(["bash", "-c", resume], cwd=workspace,
            env={**env, "PATH": str(public_bin) + os.pathsep + os.environ["PATH"]},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        read_terminal(master, "› ")
        status = terminal_step(master, "/status", "Session: ", composer=True)
        assert f"Session: {saved['session']}\n" in status, status
        terminal_step(master, "/exit", "Resume: ")
        _, resumed_errors = terminal_exit(caller, master)
        assert caller.returncode == 0 and not resumed_errors, resumed_errors
        caller.stderr.close()
        assert set(records.glob("*.json")) == before_entry | added, "resume created a replacement Session"
        assert len(endpoint.requests) == 7, "entry recovery submitted provider work"
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            actual[3] &= ~mask
        assert actual == original
        literal = admit(home, "session", "configure", cwd=workspace)["admission"]["answer"]["session"]
        for index, (prompt, answer) in enumerate((("-", b"Literal dash answered."),
                ("--model", b"Literal option answered.")), start=7):
            input_read, input_write = os.pipe()
            try:
                # Keep unrelated stdin open: literal operands after -- must
                # neither consume its bytes nor wait for EOF before admission.
                unrelated = b"unrelated held stdin\n"
                os.write(input_write, unrelated)
                sent = subprocess.run([str(fixture.RUI), "session", "send", "--session", literal, "--", prompt],
                    cwd=workspace, env=env, stdin=input_read, capture_output=True, timeout=5)
                assert sent.returncode == 0, sent
                key = json.loads(sent.stdout)["context"]["key"]
                fixture.wait_for(lambda: fixture.completed_observation(store, key), "literal operand answer")
                assert fixture.read_result(store, key) == answer
                user = [item for item in json.loads(endpoint.requests[index])["input"]
                    if item.get("role") == "user"]
                assert user[-1]["content"][0]["text"] == prompt, user
                assert select.select([input_read], [], [], 0)[0], "literal consumed stdin"
                assert os.read(input_read, len(unrelated)) == unrelated
            finally:
                dispose_all(lambda: os.close(input_read), lambda: os.close(input_write))
        lookalike_store = state / "lookalike-store"
        lookalike_host = fixture.start_host(lookalike_store, None)
        pages = [json.loads(line) for line in run(home, "session", "list", "--all").splitlines()]
        newest = [row["reference"] for page in pages for row in page["sessions"]
            if row["workspace"] == str(workspace)][-1]
        for index, (entry, chosen) in enumerate((("last", newest),
                ("exact", "last/8"))):
            defaults(home, "--store", store)
            before_failure = set(records.glob("*.json"))
            proxy = canonical.ReplyProxy(host, "/v1/inspect-session")
            arguments = ["session", "resume", "--last"] if entry == "last" else ["session", "resume", "--", chosen]
            caller = subprocess.Popen([str(fixture.RUI), *arguments], cwd=workspace,
                env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            output, errors = terminal_exit(caller, master)
            assert caller.returncode == 1 and b"CanonicalStoreFailure" in errors, (output, errors)
            assert b"Resume: rui session resume --store " in errors, errors
            exact_resume = errors.decode().split("Resume: ", 1)[1].splitlines()[0]
            assert set(records.glob("*.json")) == before_failure and not proxy.mutations
            proxy.close()
            proxy = None
            caller.stderr.close()
            # Both selectors now have a plausible different destination.
            run(home, "session", "configure", "--store", store, "--session", f"newer/{index}",
                "--workspace", workspace, "--provider", "codex", "--model", "model-a")
            run(home, "session", "configure", "--store", lookalike_store, "--session", chosen,
                "--workspace", other, "--provider", "codex", "--model", "lookalike-model")
            defaults(home, "--store", lookalike_store)
            before_resume = set(records.glob("*.json"))
            caller = subprocess.Popen(["bash", "-c", exact_resume], cwd=workspace,
                env={**env, "PATH": str(public_bin) + os.pathsep + os.environ["PATH"]},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            read_terminal(master, "› ")
            status = terminal_step(master, "/status", "Session: ", composer=True)
            assert f"Session: {chosen}\n" in status and shown(f"Store: {store}\n", status), status
            assert "lookalike-model" not in status, status
            terminal_step(master, "/exit", "Resume: ")
            _, errors = terminal_exit(caller, master)
            assert caller.returncode == 0 and not errors, errors
            caller.stderr.close()
            assert set(records.glob("*.json")) == before_resume
            assert len(endpoint.requests) == 9, "entry recovery submitted provider work"
        defaults(home, "--store", store)
        before_failure = set(records.glob("*.json"))
        page_count = 0
        def fail_later_page(response):
            nonlocal page_count
            page_count += 1
            if page_count == 1:
                return response
            return (b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n"
                b"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
                + str(len(canonical.ERROR_BYTES)).encode() + b"\r\n\r\n" + canonical.ERROR_BYTES)
        proxy = canonical.ReplyProxy(host, "/v1/list-sessions", fail_later_page)
        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--last"], cwd=workspace,
            env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        output, errors = terminal_exit(caller, master)
        assert caller.returncode == 1 and page_count == 2, (output, errors, page_count)
        assert b"Resume:" not in errors, "partial last selection escaped as final identity"
        assert set(records.glob("*.json")) == before_failure and not proxy.mutations
        caller.stderr.close()
        proxy.close()
        proxy = None
        completed = True
        print("CLI entry/resume/send: literal prompt, canonical scoped paginated last vs older activity, exact resume, colour/NO_COLOR, fresh default Configure, admission-only held send with exact saved answer, stdin, literal dash/option with untouched held stdin, failure, exact lost-reply recovery, permission block and accepted-entry recovery controls passed", flush=True)
    finally:
        dispose_all(
            held_release.set, permission_release.set,
            lambda: proxy.close() if proxy is not None else None,
            lambda: stop_process(caller, timeout=5) if caller is not None else None,
            *(lambda fd=fd: os.close(fd) for fd in (master, slave) if fd is not None),
            lambda: fixture.stop_host(lookalike_host) if lookalike_host is not None else None,
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained command-entry failure state: {state}", file=sys.stderr)


def scroll_return_case():
    """Rows scrolled up and the same rows back down return to live output.

    Short screens reach the opened transcript's top, where older pages load
    above it; the return must still count from the latest row. Scrolling
    never edits or sends the draft.
    """
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-scroll-return."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store"
    endpoint = fixture.SuccessEndpoint([
        *[fixture.sse_answer(f"scroll-{i}", f"scroll-r-{i}", f"scroll-m-{i}",
            f"scroll answer {i:02d}\n\nsecond row {i:02d}\n\nthird row {i:02d}")[0] for i in range(24)],
        fixture.sse_answer("brief", "brief-r", "brief-m", "brief answer")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = None
    master = slave = None
    completed = False
    records = home / ".config/rui/requests"
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        for session, count in (("scroll/long", 24), ("scroll/brief", 1)):
            run(home, "session", "configure", "--store", store, "--session", session,
                "--workspace", state, "--provider", "codex", "--model", "model-a")
            for i in range(count):
                message = admit(home, "session", "send", "--store", store, "--session", session, f"scroll input {i:02d}")
                fixture.wait_for(lambda: fixture.completed_observation(store, message["request"]), "saved scroll answer")

        def enter(session, rows, latest):
            nonlocal caller, master, slave
            master, slave = open_pty(80, rows)
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "--", session],
                env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            read_terminal(master, latest, composer=True)
            os.write(master, b"keep")
            await_screen(master, "› keep", composer=True)
            return {path: path.read_bytes() for path in records.glob("*.json")}, len(endpoint.requests)

        def live(latest, context):
            shown = settle_screen(master, quiet=0.5)
            capture = terminal_capture(master)
            assert not shown.startswith("Browsing"), (context, "still browsing", shown)
            assert composer_ready(shown, capture.screen.cursor.x, capture.screen.cursor.y), (context, shown)
            # The status row (a notice, if any) may sit between them.
            rows = shown.rstrip("\n").split("\n")
            assert rows[-1] == "› keep" and latest in rows[-4:-1], (context, "latest row not last", shown)

        def leave(saved):
            records_before, requests = saved
            assert {path: path.read_bytes() for path in records.glob("*.json")} == records_before, "scrolling captured input"
            assert len(endpoint.requests) == requests, "scrolling sent input"
            os.write(master, b"\x15/exit\n")
            _, errors = terminal_exit(caller, master)
            assert caller.returncode == 0, errors
            for fd in (master, slave):
                os.close(fd)

        latest = "third row 23"
        for rows in (30, 16):
            saved = enter("scroll/long", rows, latest.strip())
            for count in (1, 8, 40):
                context = (rows, count)
                os.write(master, b"\x1b[A" * count)
                shown = settle_screen(master, quiet=0.5)
                assert shown.startswith("Browsing · Esc returns"), (context, shown)
                os.write(master, b"\x1b[B" * count)
                live(latest, context)
            leave(saved)
            master = slave = caller = None
        # At the history boundary extra rows up move nothing, so the same
        # count down still reaches live output; every return key works.
        latest = "brief answer"
        for rows in (30, 16):
            saved = enter("scroll/brief", rows, latest.strip())
            for up, back in ((b"\x1b[A", b"\x1b[B" * 40), (b"\x1bOA", b"\x1b"),
                    (b"\x1b[5;2~", b"\x1b[1;5F"), (b"\x1b[5~", b"\x1b[6~" * 40)):
                context = (rows, up, back[:8])
                os.write(master, up * 40)
                shown = settle_screen(master, quiet=0.5)
                assert shown.startswith("Browsing · Esc returns") and "Start of conversation" in shown, (context, shown)
                if back == b"\x1b":
                    return_to_live(master)
                else:
                    os.write(master, back)
                live(latest, context)
            leave(saved)
            master = slave = caller = None
        completed = True
        print("scroll return: N rows up then N down (1, 8, 40 at 30 and 16 rows) and history-boundary returns reach live output; draft kept, nothing sent")
    finally:
        dispose_all(
            lambda: stop_process(caller, timeout=5) if caller is not None else None,
            *(lambda fd=fd: os.close(fd) for fd in (master, slave) if fd is not None),
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)


def persistent_opening_case():
    """Frozen replay uses real content once and assistant-only formatting."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-opening."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store'$(false)"
    large_answer = "# Saved heading\n**saved bold** é\n# " + "x" * 8192 + "\nOPENING-COMPLETE"
    history_release = threading.Event()
    opening_release = threading.Event()
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_answer("opening-a", "opening-ar", "opening-am", large_answer)[0],
        *[fixture.sse_answer(f"older-{i}", f"older-r-{i}", f"older-m-{i}", f"saved answer {i:02d}")[0] for i in range(1, 10)],
        fixture.sse_answer("late", "late-r", "late-m", "late beyond captured end")[0],
        fixture.sse_answer("independent", "independent-r", "independent-m", "independent history admission")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        run(home, "session", "configure", "--store", store, "--session", "persistent/opening",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        message = admit(home, "session", "send", "--store", store, "--session", "persistent/opening", "literal **user** é")
        fixture.wait_for(lambda: fixture.completed_observation(store, message["request"]), "opening saved answer")
        assert run(home, "request", "read-result", "--store", store, "--key", message["request"]) == large_answer
        assert run(home, "request", "read-result", message["request"]) == large_answer
        master, slave = open_pty()
        # Tall enough that the whole wrapped opening is one committed frame.
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 120, 100, 0, 0))
        original = termios.tcgetattr(slave)
        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", "persistent/opening"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        read_terminal(master, "› ", composer=True)
        output = current_screen(master)
        assert output.count("literal **user** é") == 1, ("opening lost or duplicated User", output)
        assert "\n› literal **user** é" in output, output
        assert "\nSaved heading\n" in output and "# Saved heading" not in output, output
        assert all(noise not in output for noise in ("You:", "Assistant:", "Rui:", "item_id:", "call_id:", "Capturing original", "Original reserved request")), output
        assert output.count("Saved heading") == 1, ("opening bypassed assistant renderer", output)
        assert output.count("saved bold é") == 1 and "**saved" not in output, output
        heading, emphasis, plain_suffix = (drawn_style(master, "Saved heading"),
            drawn_style(master, "saved bold é"), drawn_style(master, "saved bold é", 11))
        assert heading.bold and emphasis.bold and not plain_suffix.bold, (heading, emphasis, plain_suffix)
        assert not drawn_style(master, "literal **user** é").bold, "User text was rendered as Markdown"
        assert "Provider:" not in output and "Workspace (Bash cwd):" not in output, ("opening is not compact", output)
        assert "OPENING-COMPLETE" in output, "opening applied the historical omission limit"
        assert len(endpoint.requests) == 1, "opening restarted saved work"
        os.write(master, b"\x03")
        read_terminal(master, "Detached.")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, "opening terminal configuration was not restored"
        os.close(master)
        os.close(slave)
        master = slave = None

        # A late opening read error is fatal after a visible prefix, not a
        # recoverable page preparation error or a reason to replay provider work.
        proxy = canonical.ReplyProxy(host, "/v1/activity-content",
            lambda response: response[:-1] if b"OPENING-COMPLETE" in response else response)
        master, slave = open_pty()
        original = termios.tcgetattr(slave)
        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", "persistent/opening"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        # Opening content is verified before the screen draws it: a truncated
        # read fails without drawing any prefix, naming the exact resume.
        drawn, errors = terminal_exit(caller, master)
        assert caller.returncode != 0 and b"TruncatedResponse" in errors, errors
        assert b"Resume: rui session resume --store " in errors, errors
        # No prefix at all: not the heading, not the answer's verified-so-far
        # windows, not even the User row of the same opening.
        for unverified in (b"Saved heading", b"x" * 80, b"OPENING-COMPLETE", b"literal"):
            assert unverified not in drawn, ("truncated opening exposed unverified content", unverified, drawn)
        assert not drawn.count(b"\x1b[?1049h") or drawn.endswith(b"\x1b[?1049l") or b"\x1b[?1049l" in drawn, drawn
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, "late opening error left terminal configuration changed"
        assert len(endpoint.requests) == 1 and len(proxy.exchanges) == 2, "opening error retried or caused work"
        proxy.close()
        proxy = None
        os.close(master)
        os.close(slave)
        master = slave = None
        for buffered_reset in (False, True):
            def truncate_result(response):
                if not buffered_reset:
                    return response[:-1]
                # The renderer has returned to normal style, but its reset and
                # incomplete span remain buffered after a visible bold prefix.
                body = b"# " + b"x" * 5000 + b"\n*UNVERIFIED"
                return (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n"
                    b"X-Rui-Wire-Version: 1\r\nContent-Length: " + str(len(body) + 1).encode()
                    + b"\r\nConnection: close\r\n\r\n" + body)

            proxy = canonical.ReplyProxy(host, "/v1/read-result", truncate_result)
            # Content reads stream earlier windows, so a truncated reply may
            # leave a prefix, but it fails typed and never appears complete or
            # retried. The final window is released only after its advertised
            # length is bound, so neither tail marker can reach stdout.
            failed_result = subprocess.run([str(fixture.RUI), "request", "read-result", message["request"]],
                env={**os.environ, "HOME": str(home)}, capture_output=True, timeout=5)
            assert failed_result.returncode == 1 and b"TruncatedResponse" in failed_result.stderr, failed_result
            served = (b"# " + b"x" * 5000 + b"\n*UNVERIFIED") if buffered_reset else large_answer.encode()[:-1]
            final_window = len(served) // 4096 * 4096
            assert served.startswith(failed_result.stdout) and len(failed_result.stdout) <= final_window, (
                "truncated result released its final window", len(failed_result.stdout), failed_result.stdout[-64:])
            assert b"OPENING-COMPLET" not in failed_result.stdout and b"UNVERIFIED" not in failed_result.stdout, (
                "truncated result flushed its unverified tail", failed_result.stdout[-64:])
            assert len(endpoint.requests) == 1 and len(proxy.exchanges) == 1, "failed keyed result restarted work"
            proxy.close()
            proxy = None
        for i in range(1, 10):
            message = admit(home, "session", "send", "--store", store, "--session", "persistent/opening", f"saved user {i:02d}")
            fixture.wait_for(lambda: fixture.completed_observation(store, message["request"]), "history saved answer")
        # A queued local traversal is not eligible until opening establishes its
        # cursor. Both command and inspection cancellation must retain it.
        for handoff in (b"/requests\n", b"/inspect-action\n"):
            opening_release.clear()
            opening_held = threading.Event()

            def hold_first_opening(response):
                if len(proxy.exchanges) == 1:
                    opening_held.set()
                    assert opening_release.wait(15), "cancelled opening gate was not released"
                return response

            proxy = canonical.ReplyProxy(host, "/v1/activity-page", hold_first_opening)
            master, slave = open_pty()
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", "persistent/opening"], env={**os.environ, "HOME": str(home)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            startup = terminal_gate(caller, master, opening_held, ("queued opening", handoff, proxy.exchanges))
            os.write(master, b"/history\n" + handoff)
            # /history scrolls to the start once opening establishes it.
            output = read_terminal(master, "Start of conversation")
            shown = current_screen(master)
            assert "Start of conversation" in shown, ("queued history lost its scroll", handoff, shown)
            assert shown.index("Start of conversation") < shown.index("literal **user** é") < shown.index("saved user 01"), \
                ("queued history consumed an unestablished opening cursor", handoff, shown)
            assert len(endpoint.requests) == 10, "opening/history handoff restarted work"
            opening_release.set()
            os.write(master, b"\x03")
            _, errors = terminal_exit(caller, master)
            assert caller.returncode == 0, errors
            proxy.close()
            proxy = None
            os.close(master)
            os.close(slave)
            master = slave = None
        master, slave = open_pty()
        # Short enough that opening shows only the latest rows; wide enough
        # that the raw export command is one row.
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 512, 0, 0))
        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", "persistent/opening"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        output = read_terminal(master, "› ")
        assert "saved user 09" in output and "literal **user** é" not in output, output
        assert output.index("saved user 08") < output.index("saved answer 08") < output.index("saved user 09"), output
        message = admit(home, "session", "send", "--store", store, "--session", "persistent/opening", "late input")
        fixture.wait_for(lambda: fixture.completed_observation(store, message["request"]), "late saved answer")
        read_terminal(master, "late beyond captured end")
        # Explicit latest details cannot move the frozen older-history cursor.
        os.write(master, b"/details\n")
        details = read_terminal(master, "Recent conversation — tool details")
        assert "Recent conversation — tool details" in current_screen(master), details
        while "late beyond captured end" not in current_screen(master):
            assert current_screen(master).startswith("Browsing · Esc returns"), ("details paging left browsing", details)
            os.write(master, b"\x1b[6~")
            details += read_terminal(master, "Browsing · Esc returns")
        assert "literal **user** é" not in details, details
        return_to_live(master)

        history_held = threading.Event()

        def truncate_second(response):
            if len(proxy.exchanges) == 2:
                history_held.set()
                assert history_release.wait(15), "history preparation gate was not released"
                return response[:-1]
            return response

        proxy = canonical.ReplyProxy(host, "/v1/conversation-content", truncate_second)
        os.write(master, b"/history\n")
        assert history_held.wait(10), "history did not reach its held content read"
        records = home / ".config/rui/requests"
        before = set(records.glob("*.json"))
        os.write(master, "during history é\nnext café!\x1b[D\x1b[DX".encode())
        fixture.wait_for(lambda: len(set(records.glob("*.json")) - before) == 1, "independent history Admission capture")
        record = (set(records.glob("*.json")) - before).pop()
        fixture.wait_for(lambda: fixture.completed_observation(store, record.stem), "Admission while history preparation is held")
        assert json.loads(record.read_text())["text"]["value"] == "during history é"
        # Rows the held page would add must not appear before it is verified.
        staged = ("literal **user**", "Historical item omitted", "saved user 01", "saved user 02")
        composing = read_terminal(master, "› next cafXé!", timeout=5)
        assert not history_release.is_set() and not any(row in composing for row in staged), composing
        history_release.set()
        failed = read_terminal(master, "! Earlier messages unavailable; scroll up to retry. Draft retained.")
        assert not any(row in failed for row in staged), "failed history exposed a staged prefix"
        if "› next cafXé!" not in current_screen(master):
            read_terminal(master, "› next cafXé!")
        os.write(master, b"\x1b[CZ")
        read_terminal(master, "› next cafXéZ!")
        # The failure names its recovery: a new scroll retries the whole page.
        # (/history alone does not retry after a failure; reported, not pinned.)
        os.write(master, b"\x05\x15")
        read_terminal(master, "› ", composer=True)
        scroll_until(master, b"\x1b[5~", "Start of conversation")
        recovered = current_screen(master)
        assert recovered.count("literal **user** é") == 1 and "Historical item omitted" in recovered, recovered
        assert "Saved heading" not in recovered and "OPENING-COMPLETE" not in recovered, "oversized historical content leaked"
        assert recovered.index("Start of conversation") < recovered.index("literal **user** é") < recovered.index("Historical item omitted") < recovered.index("saved user 01"), recovered
        export = raw_export(master, recovered)
        command = shlex.split(export)
        assert command[0:4] == ["rui", "session", "read-conversation", "--store-hex"] and bytes.fromhex(command[4]) == str(store).encode(), export
        assert all(32 <= ord(char) < 127 for char in export), "raw export printed terminal controls"
        executables = state / "bin"
        executables.mkdir()
        (executables / "rui").symlink_to(fixture.RUI.resolve())
        exported = subprocess.run(export, shell=True, env={**os.environ, "HOME": str(home),
            "PATH": str(executables) + os.pathsep + os.environ["PATH"]}, capture_output=True, timeout=10)
        assert exported.returncode == 0 and exported.stdout == large_answer.encode(), (export, exported.stderr, exported.stdout)
        # Unavailable content leaves stdout empty; its typed diagnostic is on stderr.
        absent = list(command)
        absent[0] = str(fixture.RUI)
        absent[absent.index("--position") + 1] = "999999999"
        missing = subprocess.run(absent, env={**os.environ, "HOME": str(home)}, capture_output=True, timeout=10)
        assert missing.returncode == 1 and missing.stdout == b"", missing
        assert "error" in json.loads(missing.stderr.splitlines()[0]), missing
        for flags in (("--session-hex", "0"), ("--session-hex", "zz"),
                ("--session-hex", "61" * 129), ("--session", "persistent/opening", "--store-hex", "61" * 493),
                ("--session", "persistent/opening", "--session-hex", "61"),
                ("--store", store, "--store-hex", "61")):
            rejected = subprocess.run([str(fixture.RUI), "session", "read-conversation", *map(str, flags),
                "--position", "1", "--ordinal", "0"], capture_output=True, timeout=10)
            assert rejected.returncode == 1 and not rejected.stdout, (flags, rejected)
            assert any(code in rejected.stderr for code in (b"InvalidHexIdentity", b"DuplicateArgument", b"ConflictingArguments")), rejected.stderr
        assert "late beyond captured end" not in recovered and "saved user 09" not in recovered, "history recaptured or replayed opening"
        assert proxy.exchanges[0][0] == proxy.exchanges[2][0], "history failure advanced its actual cursor"
        # At the start there is nothing older: /history reads nothing more.
        reads = len(proxy.exchanges)
        os.write(master, b"/history")
        read_terminal(master, "› /history")
        os.write(master, b"\n")
        read_terminal(master, "› ", composer=True)
        time.sleep(0.5)
        assert "Start of conversation" in current_screen(master), current_screen(master)
        assert len(proxy.exchanges) == reads, "history read past the start"
        assert len(endpoint.requests) == 12, "history caused provider work"
        os.write(master, b"\x03")
        read_terminal(master, "Detached.")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        completed = True
        print("persistent opening/history: exact chronological frozen replay, assistant-only Markdown, whole-page failure/retry, no cursor loss/late append/repeated work passed", flush=True)
    finally:
        dispose_all(
            history_release.set, opening_release.set,
            lambda: stop_process(caller, timeout=5) if caller is not None else None,
            *(lambda fd=fd: os.close(fd) for fd in (master, slave) if fd is not None),
            lambda: proxy.close() if proxy is not None else None,
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained persistent opening failure state: {state}", file=sys.stderr)


def persistent_pending_case():
    """Opening counts the frozen queue beyond its newest Activity page."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-pending."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store"
    release, captured, opening_release = threading.Event(), threading.Event(), threading.Event()
    endpoint = fixture.SuccessEndpoint([(fixture.sse_answer("pending-a", "pending-r", "pending-m", "held answer")[0], release)])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        run(home, "session", "configure", "--store", store, "--session", "persistent/pending", "--workspace", state,
            "--provider", "codex", "--model", "model-a")
        admit(home, "session", "send", "--store", store, "--session", "persistent/pending", "active original")
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "held first provider request")
        for i in range(1, 25):
            admit(home, "session", "send", "--store", store, "--session", "persistent/pending", f"queued-{i:02d} é")

        def hold_opening(response):
            if len(proxy.exchanges) == 1:
                captured.set()
                assert opening_release.wait(15), "opening metadata gate was not released"
            return response

        proxy = canonical.ReplyProxy(host, "/v1/activity-page", hold_opening)
        # Tall enough that the queue summary and every row are one frame.
        master, slave = open_pty(rows=160)
        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", "persistent/pending"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        startup = terminal_gate(caller, master, captured, ("pending opening", proxy.exchanges, endpoint.requests))
        admit(home, "session", "send", "--store", store, "--session", "persistent/pending", "late queued beyond snapshot")
        opening_release.set()
        read_terminal(master, "› ")
        output = current_screen(master)
        assert "24 queued messages" in output, ("opening counted only its newest page or fresh Current", output)
        # The newest page shows its queued Messages whole and labelled; older
        # ones are listed where a transcript reaches them, never previewed.
        assert "Queued: " not in output and output.count("! Queued") == 16, output
        assert all(f"queued-{i:02d} é" in output for i in range(9, 25)) and not any(f"queued-{i:02d} é" in output for i in range(1, 9)), output
        assert len(endpoint.requests) == 1, "opening dispatched queued work"
        os.write(master, b"\x03")
        read_terminal(master, "Detached.")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        completed = True
        print("persistent pending: exact frozen 24 beyond newest 16, newest page labelled, late admission excluded passed", flush=True)
    finally:
        dispose_all(
            opening_release.set,
            lambda: stop_process(caller, timeout=5) if caller is not None else None,
            *(lambda fd=fd: os.close(fd) for fd in (master, slave) if fd is not None),
            lambda: proxy.close() if proxy is not None else None,
            lambda: fixture.stop_host(host) if host is not None else None,
            release.set, endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained persistent pending failure state: {state}", file=sys.stderr)


def persistent_input_cases():
    """Real captured Admission, a next draft, original replay and input recovery."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-input."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store"
    first_release = threading.Event()
    next_received, next_admission_release = threading.Event(), threading.Event()
    endpoint = fixture.SuccessEndpoint([
        (fixture.sse_answer("persistent-a", "persistent-ar", "persistent-am", "first exact answer")[0], first_release),
        fixture.sse_answer("persistent-b", "persistent-br", "persistent-bm", "second exact answer")[0],
        fixture.sse_answer("persistent-c", "persistent-cr", "persistent-cm", "valid after malformed")[0],
        fixture.sse_answer("persistent-d", "persistent-dr", "persistent-dm", "capture retry answer")[0],
        fixture.sse_answer("persistent-e", "persistent-er", "persistent-em", "next after capture retry")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        run(home, "session", "configure", "--store", store, "--session", "persistent/input",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        master, slave = open_pty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        original = termios.tcgetattr(slave)
        received, admission_release = threading.Event(), threading.Event()

        def lost_once(response):
            received.set()
            assert admission_release.wait(15), "Admission gate was not released"
            if len(proxy.exchanges) == 3:
                next_received.set()
                assert next_admission_release.wait(15), "next Admission gate was not released"
            return b"" if len(proxy.exchanges) in (1, 4) else response

        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", "persistent/input"], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        read_terminal(master, "› ")
        proxy = canonical.ReplyProxy(host, "/v1/message", lost_once)
        # An idle recovery key cannot authorize retry of a future submission.
        os.write(master, "\x12original éZ\n".encode())
        assert received.wait(10), "original Message did not reach Host"
        os.write(master, "next café!\x1b[D\x1b[DX".encode())
        composed = read_terminal(master, "› next cafXé!")
        assert "Sending" in composed and "Original reserved request" not in composed, composed
        records = home / ".config/rui/requests"
        before = set(records.glob("*.json"))
        os.write(master, b"\n")
        assert "Input still pending" in read_terminal(master, "Input still pending")
        assert set(records.glob("*.json")) == before, "busy Enter created replacement intent"
        admission_release.set()
        uncertain = read_terminal(master, "Not confirmed")
        assert "! Not confirmed" in uncertain and "Rui:" not in uncertain, uncertain
        assert "Original reserved request" not in uncertain, ("normal recovery exposed a UUID", uncertain)
        assert len(proxy.exchanges) == 1
        saved = proxy.exchanges[0][0]
        assert json.loads(saved)["text"]["value"] == "original éZ"
        # Cosmetic spacing must yield before actionable recovery guidance.
        # Fresh edits identify each resized frame, not an earlier status line.
        # (Below the status plus draft, Rui refuses the terminal instead.)
        for rows, columns, edit in ((3, 80, "Z"), (6, 20, "Q")):
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
            os.write(master, edit.encode())
            marker = f"› next cafX{edit}é!"
            read_terminal(master, marker, composer=True)
            narrow = current_screen(master)
            shown = " ".join(re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", narrow).split())
            assert "! Not confirmed · Ctrl-R retries original" in shown, (
                "optional spacer hid actionable recovery", rows, columns, narrow)
            assert len(proxy.exchanges) == 1 and set(records.glob("*.json")) == before
            os.write(master, b"\x7f")
            read_terminal(master, "› next cafXé!", composer=True)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        read_terminal(master, "› next cafXé!", composer=True)
        first_release.set()
        read_terminal(master, "first exact answer")
        assert len(proxy.exchanges) == 1, "idle Ctrl-R retried unrelated uncertain intent"
        os.write(master, b"\x12")
        read_terminal(master, "Original confirmed")
        assert len(proxy.exchanges) == 2 and proxy.exchanges[1][0] == saved, "Ctrl-R changed original capture"
        assert len(endpoint.requests) == 1, "recovery repeated provider work"
        # Cursor still sits before é; insert at that exact logical position.
        os.write(master, b"Y\n")
        assert next_received.wait(10), "next Message did not reach Host"
        # A retry requested during this Admission belongs only to its ticket.
        os.write(master, b"\x12pending scope")
        read_terminal(master, "› pending scope")
        next_admission_release.set()
        read_terminal(master, "second exact answer")
        assert json.loads(proxy.exchanges[-1][0])["text"]["value"] == "next cafXYé!"
        assert len(endpoint.requests) == 2
        os.write(master, b"\x15bad\xc3(\n")
        rejected = read_terminal(master, "Input rejected; nothing sent.")
        assert "InvalidTerminalInput" not in rejected, ("internal error name leaked", rejected)
        os.write(master, b"valid after rejection\n")
        uncertain = read_terminal(master, "Not confirmed")
        if "valid after malformed" not in uncertain:
            read_terminal(master, "valid after malformed")
        assert json.loads(proxy.exchanges[-1][0])["text"]["value"] == "valid after rejection"
        assert len(proxy.exchanges) == 4, "accepted ticket's Ctrl-R retried a later submission"
        os.write(master, b"\x12")
        read_terminal(master, "Original confirmed")
        assert len(proxy.exchanges) == 5 and proxy.exchanges[4][0] == proxy.exchanges[3][0], "fresh Ctrl-R did not recover the current original"
        # Actual prepublication access failure, followed by repair. Recovery
        # must capture the original under its reserved key, not wedge forever.
        before_failure = set(records.glob("*.json"))
        records.chmod(0o500)
        os.write(master, b"original before capture failure\n")
        failed = read_terminal(master, "Not confirmed")
        assert "Original reserved request" not in failed, failed
        # Diagnostics run with canonical input restored. Their final line is
        # not readiness: the next raw-entry flush follows it. Await the resumed
        # composer under the same response budget before typing the next draft.
        diagnostic_deadline = time.monotonic() + 15
        os.write(master, b"/status\n")
        diagnostic = read_terminal(master, "Ctrl-R retries this exact original.",
            timeout=diagnostic_deadline - time.monotonic(), composer=True)
        reserved = diagnostic.split("Original reserved request: ", 1)[1].splitlines()[0]
        os.write(master, "next café!\x1b[D\x1b[DX".encode())
        failed += read_terminal(master, "› next cafXé!")
        assert set(records.glob("*.json")) == before_failure
        assert len(proxy.exchanges) == 5, "capture failure transmitted input"
        records.chmod(0o700)
        os.write(master, b"\x12")
        read_terminal(master, "Original confirmed.")
        # The /status page stays until the user returns to live output.
        if "capture retry answer" not in return_to_live(master):
            read_terminal(master, "capture retry answer")
        recovered = json.loads(proxy.exchanges[-1][0])
        assert recovered["key"] == reserved and recovered["text"]["value"] == "original before capture failure", recovered
        assert len(set(records.glob("*.json")) - before_failure) == 1
        os.write(master, b"Y\n")
        # Visible answer bytes are not joined-reader readiness for a command.
        read_terminal(master, "next after capture retry", composer=True)
        assert json.loads(proxy.exchanges[-1][0])["text"]["value"] == "next cafXYé!"
        assert len(endpoint.requests) == 5 and len(proxy.exchanges) == 7
        # A pending command owns the next Enter: queued text stays a draft.
        before_command = set(records.glob("*.json"))
        os.write(master, b"/configure --permission-mode ask\nUNREAD suffix\n")
        read_terminal(master, "Configured.", composer=True)
        await_screen(master, "› UNREAD suffix", composer=True)
        added = [json.loads(path.read_text()) for path in set(records.glob("*.json")) - before_command]
        assert len(added) == 1 and "configuration" in added[0], ("command suffix became captured Message intent", added, current_screen(master))
        assert fixture.command("session", "inspect", "--store", store,
            "--session", "persistent/input")["session"]["permission_mode"] == "ask"
        assert len(endpoint.requests) == 5 and len(proxy.exchanges) == 7, "command suffix reached Host"
        os.write(master, b"\x03")
        read_terminal(master, "Detached.")
        _, errors = caller.communicate(timeout=5)
        assert caller.returncode == 0, errors
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            # NOW restores user configuration, not kernel-owned history flags.
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, "persistent terminal configuration was not restored"
        completed = True
        print("persistent public Session: exact original replay, joined acceptance, next Unicode cursor, malformed→valid, prepublication repair, restoration passed", flush=True)
    finally:
        records = home / ".config/rui/requests"

        def report_caller():
            if not completed and caller is not None and caller.poll() is not None:
                print(f"persistent caller exited {caller.returncode}: {caller.stderr.read().decode(errors='replace')}", file=sys.stderr)

        dispose_all(
            first_release.set, next_admission_release.set,
            lambda: records.chmod(0o700) if records.exists() else None,
            report_caller,
            lambda: stop_process(caller, timeout=5) if caller is not None else None,
            lambda: proxy.close() if proxy is not None else None,
            *(lambda fd=fd: os.close(fd) for fd in (master, slave) if fd is not None),
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained persistent input failure state: {state}", file=sys.stderr)


def persistent_permission_case(decision="deny-action", exit_code=0, signal_failure=False,
                               lost_reply=False, fragmented_paste=False, stale_target=False, timed_out=False):
    """Fresh inline choices retain draft custody and exact canonical targets."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-persistent-permission."))
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store'$(false)"
    reference = "persistent/permission'$(false) é\n"
    answer = "after explicit denial" if decision == "deny-action" else "after explicit approval"
    description = "Inspect café output"
    retirement = ("Process retirement confirmed: the child was reaped and the original process group was observed absent. "
                  "macOS group signaling returned EPERM, which can mean no live targets or permission denial.")
    command = f"printf inspection-only-output; printf unsafe >> effect-count; exit {exit_code}"
    if exit_code:
        command = f"printf '%9000s' inspection-only-output; printf unsafe >> effect-count; exit {exit_code}"
    if timed_out:
        command = "printf inspection-only-output; printf unsafe >> effect-count; sleep 1"
    timeout_ms = 100 if timed_out else 30000
    arguments = json.dumps({"cmd": command, "description": description, "timeout_ms": timeout_ms})
    calls = [("bash", "persistent-call-id", arguments)]
    second_command = "printf distinct >> second-effect"
    if stale_target:
        calls.append(("bash", "persistent-second-id", json.dumps({"cmd": second_command, "description": "Write sibling effect", "timeout_ms": None})))
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("persistent-call", calls),
        fixture.sse_answer("persistent-answer", "persistent-reason", "persistent-message", answer)[0],
        fixture.sse_answer("retained-answer", "retained-reason", "retained-message", "retained draft complete")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = caller = proxy = None
    master = slave = None
    arguments_release = threading.Event()
    arguments_held = threading.Event()
    ready_read, ready_write = os.pipe()
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
            *(("--fault", "bash-signal") if signal_failure else ()), active_capacity=4)
        run(home, "session", "configure", "--store", store, "--session", reference,
            "--workspace", state, "--provider", "codex", "--model", "model-a", "--permission-mode", "ask")
        master, slave = open_pty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
        original = termios.tcgetattr(slave)
        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", reference], env={**os.environ, "HOME": str(home),
                "TERM": "xterm-256color", "NO_COLOR": "",
                "RUI_TEST_ACTION_READY_FD": str(ready_write)}, pass_fds=(ready_write,),
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        opening = read_terminal(master, "› ")
        assert all(noise not in opening for noise in ("model-a", "Workspace:", "Session:", "Store:", "/help commands")), opening
        def hold_arguments(response):
            if not arguments_held.is_set():
                arguments_held.set()
                assert arguments_release.wait(15), "Action arguments gate was not released"
            return response

        proxy = canonical.ReplyProxy(host, "/v1/read-action-arguments", hold_arguments)
        os.write(master, b"requires permission\n")
        terminal_gate(caller, master, arguments_held, "automatic Action arguments")
        os.write(master, "next café!\x1b[D\x1b[DX".encode())
        read_terminal(master, "› next cafXé!")
        records = home / ".config/rui/requests"
        before_choice = set(records.glob("*.json"))
        os.write(master, b"a\n\x1b[200~" if fragmented_paste else b"a\n")
        arguments_release.set()
        if fragmented_paste:
            # The decoder keeps an unfinished paste; no frame or consent
            # scope may start from it.
            assert not select.select([ready_read], [], [], 1)[0], "unfinished chat paste opened consent scope"
            os.write(master, b"\x1b[201~\n")
        transcript = read_terminal(master, json.loads(arguments)["cmd"])
        header = drawn_style(master, f"? Run Bash · {description}")
        assert header is not None and header.fg in ATTENTION_COLOUR, (header, current_screen(master))
        transcript += action_ready(ready_read, master)
        transcript += await_screen(master, "Type a + Enter to allow once · d + Enter to deny")
        assert "Capturing original" not in transcript and "Original reserved request" not in transcript, transcript
        assert "item_id:" not in transcript and "call_id:" not in transcript and "arguments:" not in transcript, transcript
        # One committed frame shows the whole Action once, as the user reads it.
        shown = current_screen(master)
        assert shown.count("Workspace:") == 1 and shown.count("? Run Bash") == 1, shown
        assert f"\n? Run Bash · {description}\n" in "\n" + shown, ("Action heading lost its description", shown)
        assert f"\n  $ {json.loads(arguments)['cmd']}\n" in shown, shown
        assert_permission_workspace(shown, state, 100)
        assert shown.count(f"Time limit: {timeout_ms} ms") == 1, shown
        assert shown.count(json.loads(arguments)["cmd"]) == 1, shown
        assert all(noise not in transcript for noise in ("You:", "Assistant:", "Rui:", "persistent-call-id")), transcript
        assert set(records.glob("*.json")) == before_choice, "queued chat created a record"
        assert not (state / "effect-count").exists(), "queued chat authorized an effect"
        if decision == "allow-action" and not any((exit_code, signal_failure, lost_reply, fragmented_paste, stale_target)):
            for rows, columns in ((3, 80), (4, 20), (8, 8)):
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
                os.write(master, b"\x01")  # Service input at the new size without granting authority.
                assert next_frame(master, 5) is not None, ("resize did not redraw", rows, columns)
                while next_frame(master, 0.5) is not None:
                    pass
                narrow = current_screen(master)
                shown = " ".join(narrow.split())  # Word wrap consumes the breaking space.
                assert len(narrow.split("\n")) == rows and narrow.split("\n")[-1].startswith(">"), narrow
                # A clipped Action never offers the choice: it says to read on.
                choice = any(text in shown for text in ("Type a + Enter to allow once · d + Enter to deny", "a Allow / d Deny Enter"))
                assert choice or "PgDn reads the rest · then a/d + Enter" in shown, narrow
                if choice:
                    assert f"$ {json.loads(arguments)['cmd']}" in shown, ("choice offered for an unread Action", narrow)
                assert caller.poll() is None and not (state / "effect-count").exists(), narrow
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
            os.write(master, b"\x01")
            read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
            action_ready(ready_read, master)
        for invalid in (b"Y\n", b"\x1b[200~a\x1b[201~\n"):
            os.write(master, invalid)
            rejected = read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
            rejected += action_ready(ready_read, master)
            assert current_screen(master).count("? Run Bash") == 1, ("invalid choice repeated command", current_screen(master))
            assert set(records.glob("*.json")) == before_choice, "invalid choice captured authority"
            assert not (state / "effect-count").exists()
        for command, notice in (("/wait", "Work continues while you compose."),
                                ("/login", "Login uses rui auth login codex in your shell.")):
            os.write(master, (command + "\n").encode())
            restricted = read_terminal(master, notice)
            restricted += action_ready(ready_read, master)
            assert current_screen(master).count("? Run Bash") == 1, ("notice repeated command", current_screen(master))
            assert set(records.glob("*.json")) == before_choice, "nested prompt created intent"
        current = fixture.command("session", "inspect", "--store", store, "--session", reference)
        action = current["actionable_permissions"][0]["action"]
        proxy.exchanges.clear()
        proxy.route = "/v1/control/permission-decision"
        proxy.rewrite = lambda response: b"" if lost_reply and len(proxy.exchanges) == 1 else response
        if stale_target:
            run(home, "action", "deny", "--store", store, "--session", reference, "--action", action)
            proxy.exchanges.clear()
        os.write(master, b"d\n" if decision == "deny-action" and not stale_target else b"a\n")
        settled = ""
        if lost_reply:
            settled = read_terminal(master, "Decision not confirmed")
            assert "! Decision not confirmed" in settled and "Rui:" not in settled, settled
            os.write(master, b"\x12")
            settled += read_terminal(master, "Decision confirmed.")
        if stale_target:
            read_terminal(master, "action_not_pending", composer=True)
            assert len(proxy.exchanges) == 1
            assert json.loads(proxy.exchanges[0][0])["action"] == action
            assert not (state / "effect-count").exists() and not (state / "second-effect").exists()
            assert len(endpoint.requests) == 1
            before_rejected = {path: path.read_bytes() for path in records.glob("*.json")}
            busy = terminal_step(master, "", "Keep editing;", composer=True)
            assert "/discard" in busy and "Ctrl-R" not in busy, busy
            assert "› next cafXaé!" in busy, busy
            os.write(master, b"\x12Y")
            retained = read_terminal(master, "› next cafXaYé!")
            assert "› next cafXaYé!" in retained, retained
            assert len(proxy.exchanges) == 1, "Ctrl-R retried a rejected decision"
            assert {path: path.read_bytes() for path in records.glob("*.json")} == before_rejected
            os.write(master, b"\x01\x0b/discard\n")
            shown = read_terminal(master, second_command)
            shown += action_ready(ready_read, master)
            assert {path: path.read_bytes() for path in records.glob("*.json")} == before_rejected
            if "Type a + Enter to allow once · d + Enter to deny" not in shown:
                shown += read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
            shown = current_screen(master)
            assert f"\n  $ {second_command}\n" in shown, shown
            assert "? Run Bash · Write sibling effect" in shown, ("sibling identity reused the first label", shown)
            os.write(master, b"/details\n")
            read_terminal(master, "Recent conversation — tool details")
            details = current_screen(master)
            assert "\n› requires permission" in details, details
            details += action_ready(ready_read, master)
            assert fixture.command("session", "inspect", "--store", store, "--session", reference)["actionable_permissions"][0]["action"] == current["actionable_permissions"][1]["action"]
            os.write(master, b"/exit\n")
            assert caller.wait(timeout=5) == 0, caller.stderr.read()
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original
            assert len(endpoint.requests) == 1
            assert not (state / "effect-count").exists() and not (state / "second-effect").exists()
            completed = True
            return
        settled += await_screen(master, answer, composer=True)
        assert len(proxy.exchanges) == (2 if lost_reply else 1), proxy.exchanges
        if lost_reply:
            assert proxy.exchanges[0][0] == proxy.exchanges[1][0], "decision retry changed intent"
        submitted = json.loads(proxy.exchanges[0][0])
        assert submitted["action"] == action and submitted["session"] == reference
        assert submitted["decision"] == ("deny" if decision == "deny-action" else "allow_once")
        for _, response in proxy.exchanges:
            assert json.loads(response.split(b"\r\n\r\n", 1)[1])["answer"]["status"] == "accepted"
        saved = [json.loads(path.read_text()) for path in records.glob("*.json")]
        assert sum(row["kind"] == "permission_decision" for row in saved) == 1, saved
        assert len(endpoint.requests) == 2
        outputs = [item["output"] for item in json.loads(endpoint.requests[1])["input"]
                   if item.get("type") == "function_call_output"]
        assert len(outputs) == 1, outputs
        saved_result = outputs[0]
        if sys.platform == "darwin" and decision == "allow-action" and not (timed_out or signal_failure):
            assert retirement in saved_result, ("native retirement evidence missing from saved result", saved_result)
        assert "Process retirement confirmed" not in settled and "macOS group signaling returned EPERM" not in settled, (
            "routine retirement diagnostics leaked into conversation", settled)
        if timed_out:
            assert f"! {description} — Timed out" in settled, settled
            # The notice wraps with the text beside the timestamp margin.
            assert "[summary shortened; /details]" in " ".join(settled.split()), settled
        elif exit_code:
            assert f"! {description} — Failed (exit {exit_code})" in settled, ("quiet view hid tool failure", settled)
            assert "Exit code:" not in settled, ("exit status repeated below its heading", settled)
            assert "Bash failed." not in settled, ("failure status repeated below its heading", settled)
            assert "/details for full output." in settled, settled
        elif decision == "allow-action":
            assert f"✓ {description}" in settled, ("quiet view hid tool outcome", settled)
            assert "Exit code: 0." not in settled, ("routine zero exit code leaked", settled)
        else:
            assert f"• {description} — Denied" in settled, ("intentional denial was not a settled outcome", settled)
            assert f"! {description}" not in settled and "/details for full output." not in settled, settled
        assert "Bash succeeded." not in settled and "Tool result:" not in settled, settled
        if signal_failure:
            assert "Process-group signaling reported a failure." in settled, ("quiet view hid cleanup warning", settled)
            if timed_out:
                # The warning starts its own line after the wrapped notice.
                assert re.search(r"\[summary\s+shortened;\s+/details\]\n  Process-group signaling reported a failure\.\n", settled), settled
        assert f"\n{answer}" in settled, settled
        assert all(noise not in settled for noise in ("You:", "Assistant:", "Rui:", "item_id:", "call_id:", "Capturing original", "Original reserved request")), settled
        if not timed_out:
            # Only a failure keeps its last output lines in view; this one
            # is a single shortened 9000-column line.
            assert "inspection-only-output" not in settled, ("routine tool output leaked", settled)
        effect = state / "effect-count"
        assert effect.read_text() == "unsafe" if decision == "allow-action" else not effect.exists()
        if "› next cafXaé!" not in settled:
            read_terminal(master, "› next cafXaé!")
        proxy.route = "/v1/message"
        proxy.exchanges.clear()
        proxy.rewrite = lambda response: response
        os.write(master, b"Y\n")
        # An answer prefix is not the joined reader boundary. Wait for its
        # final composer before a command handoff may cancel that borrower.
        submitted_draft = read_terminal(master, "retained draft complete", composer=True)
        assert "\n› next cafXaYé!" in submitted_draft, submitted_draft
        fixture.wait_for(lambda: proxy.exchanges, "retained draft queued Message")
        assert json.loads(proxy.exchanges[0][0])["text"]["value"] == "next cafXaYé!"
        # The page itself, not live frames drawn while it loaded: the
        # transcript rightly keeps the outcome above the composer. No outcome
        # form (success, denial, failure, timeout) repeats on the page.
        quiet_status = status_frame(master, reference)
        assert description not in quiet_status and "Bash succeeded." not in quiet_status, (
            "already presented outcome repeated on refresh", quiet_status)
        if exit_code:
            # Wide enough that the raw export command is one row.
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 512, 0, 0))
        os.write(master, b"/details\n")
        read_terminal(master, "Recent conversation — tool details", composer=True)
        details = current_screen(master)
        assert "Recent conversation — tool details" in details and description in details, details
        assert "\n› requires permission" in details and f"\n{answer}" in details, details
        assert all(noise not in details for noise in ("You:", "Assistant:", "Tool Result:")), details
        if exit_code:
            # The omitted saved result carries the exit status; export reads it.
            assert f"! {description} — Failed\nRui: Historical item omitted:" in details, details
            assert "inspection-only-output" not in details and "Exit code:" not in details, details
            export = raw_export(master, details)
            exported = run(home, *shlex.split(export)[1:])
            assert len(exported.encode()) > 8192 and exported.startswith(f"Bash failed. Exit code: {exit_code}.\n"), exported[:200]
            assert "inspection-only-output" in exported
            assert exported == saved_result, "raw export changed the canonical Tool Result"
        else:
            assert "Rui:" not in details, details
            if decision == "allow-action":
                assert "inspection-only-output" in details, ("saved tool output unavailable on inspection", details)
                assert f"Exit code: {exit_code}." in details, ("exact exit code unavailable on inspection", details)
                if retirement in saved_result:
                    # Hanging indentation can wrap inside a word. Compare
                    # visible content here; raw export above checks exact bytes.
                    assert "".join(retirement.split()) in "".join(details.split()), ("details hid retirement evidence", details)
        return_to_live(master)
        if exit_code:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
        if decision == "allow-action" and not any((exit_code, signal_failure, lost_reply, timed_out)):
            # Four real held effects exceed the display bound. Repeated labels
            # must not merge identities. A later, long-labelled failure must
            # stay truthful while an earlier sibling remains unresolved.
            bypass_description = "Wait for bypass café"
            long_description = "Inspect application settings and report configuration errors before applying changes to local assets"
            assert len(long_description.encode()) == 100
            bypass_descriptions = [bypass_description, long_description, bypass_description, "Check final sibling"]
            bypass_releases = [state / f"bypass-release-{index}" for index in range(4)]
            endpoint.responses.extend([
                fixture.sse_tool_calls("bypass-call", [("bash", f"bypass-distinct-id-{index}", json.dumps({
                    "cmd": f"touch bypass-started-{index}; while [ ! -e bypass-release-{index} ]; do sleep 0.05; done; printf bypass-output-{index}; exit {7 if index == 1 else 0}",
                    "description": label, "timeout_ms": 30000}))
                    for index, label in enumerate(bypass_descriptions)]),
                fixture.sse_answer("bypass-answer", "bypass-reason", "bypass-message", "bypass complete")[0],
            ])
            run(home, "session", "configure", "--store", store, "--session", reference,
                "--workspace", state, "--provider", "codex", "--model", "model-a", "--permission-mode", "bypass")
            try:
                os.write(master, b"run without approval\n")
                live = read_terminal(master, "+1 more calls · /status", composer=True)
                fixture.wait_for(lambda: all((state / f"bypass-started-{index}").exists() for index in range(4)), "held bypass effects")
                assert live.index(f"• {bypass_description}") < live.index("• Inspect application settings"), live
                assert "Check final sibling" not in live, live
                assert "? Run Bash" not in live and "allow once" not in live, live
                os.write(master, "live café!\x1b[D\x1b[DX".encode())
                live += read_terminal(master, "› live cafXé!")
                assert f"• {bypass_description}" in live and f"✓ {bypass_description}" not in live, live
                bypass_releases[1].touch()
                reverse = read_terminal(master, "— Failed", composer=True)
                assert "! Inspect application settings" in reverse and f"• {bypass_description}" in reverse, reverse
                assert "+1 more calls · /status" in reverse and len(endpoint.requests) == 4, reverse
                bypass_releases[0].touch()
                partial = read_terminal(master, f"✓ {bypass_description}", composer=True)
                assert f"• {bypass_description}" in partial and "+1 more calls · /status" in partial, partial
                assert len(endpoint.requests) == 4, "a partial tool group continued model work"
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 6, 32, 0, 0))
                short = read_terminal(master, "+3 more calls · /status", composer=True)
                assert "› live cafXé!" in short, short
                assert "Inspect application" not in short, ("a clipped call hid its failure", short)
                # Sizes below the required status and draft refuse the
                # terminal instead (TerminalTooSmall); these must still fit.
                for index, (rows, columns) in enumerate(((4, 80), (6, 20), (10, 8))):
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
                    edit = chr(ord("A") + index)
                    os.write(master, b"\x01" + edit.encode())
                    marker = f"› {edit}live"
                    read_terminal(master, marker, composer=True)
                    narrow = current_screen(master)
                    shown = " ".join(narrow.split())  # Word wrap consumes the breaking space.
                    # Every one of the four calls is either shown or counted.
                    label = re.search(r"\+(\d+)(?: more calls)? · /status", shown)
                    calls = sum(row.lstrip().startswith(("✓ ", "• ", "! ")) for row in narrow.splitlines())
                    assert label and int(label[1]) + calls == 4, narrow
                    if (rows, columns) == (6, 20):
                        assert "Working…" in shown, ("optional spacing or wording hid status", narrow)
                    assert caller.poll() is None, ("wrapped overflow displaced the composer", narrow)
                    os.write(master, b"\x7f")
                    read_terminal(master, "› live", composer=True)
                os.write(master, b"\x05\x1b[D\x1b[D")
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 12, 32, 0, 0))
                wrapped = read_terminal(master, "— Failed", composer=True)
                assert "! Inspect application settings" in wrapped and "+1 more calls · /status" in wrapped, wrapped
                assert "› live cafXé!" in wrapped, wrapped
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
                read_terminal(master, "+1 more calls · /status", composer=True)
                terminal_step(master, "\x01\x0b/exit", "Detached.")
                assert caller.wait(timeout=5) == 0, caller.stderr.read()
                caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                    "--", reference], env={**os.environ, "HOME": str(home), "TERM": "xterm-256color", "NO_COLOR": ""},
                    stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                reopened = read_terminal(master, "+1 more calls · /status", composer=True)
                assert f"✓ {bypass_description}" in reopened and f"• {bypass_description}" in reopened, reopened
                assert "bypass complete" not in reopened and len(endpoint.requests) == 4, reopened
                os.write(master, "live café!\x1b[D\x1b[DX".encode())
                read_terminal(master, "› live cafXé!")
                for release in bypass_releases:
                    release.touch()
                read_terminal(master, "bypass complete", composer=True)
                outcome = settle_screen(master)
                assert permanent_tool_count(outcome, f"✓ {bypass_description}") == 2, outcome
                assert "! Inspect application settings" in outcome and "— Failed (exit 7)" in outcome and "Exit code:" not in outcome, outcome
                assert "✓ Check final sibling" in outcome, outcome
                assert f"✓ {bypass_description}\n✓ Check final sibling\n" in outcome, ("adjacent successful calls kept a blank line", outcome)
                assert "Bash succeeded." not in outcome and "Tool result:" not in outcome, outcome
                assert "Process retirement confirmed" not in outcome, ("sibling retirement diagnostics leaked", outcome)
                assert "› live cafXé!" in outcome, outcome
                page = status_frame(master, reference, "\x01\x0b/status")
                assert bypass_description not in page, ("status page repeated a presented result", page)
                return_to_live(master)
                refreshed = settle_screen(master)
                assert permanent_tool_count(refreshed, f"✓ {bypass_description}") == 2, ("presented bypass result repeated", refreshed)
                assert len(endpoint.requests) == 5, "bypass refresh repeated provider work"
                # Eighteen results cross the 16-item Activity page. A second
                # group is held until the first is permanently presented,
                # exercising compaction across polling reads as well.
                compact_labels = [f"Compact item {index}" for index in range(18)]
                compact_release = state / "compact-release"
                notice_release = state / "notice-release"
                notice_held = threading.Event()
                notice_reply_release = threading.Event()
                endpoint.responses.extend([
                    fixture.sse_tool_calls("compact-call", [("bash", f"compact-id-{index}", json.dumps({
                        "cmd": "exit 0", "description": label, "timeout_ms": 30000}))
                        for index, label in enumerate(compact_labels)]),
                    fixture.sse_tool_calls("compact-tail", [("bash", "compact-tail-id", json.dumps({
                        "cmd": "while [ ! -e compact-release ]; do sleep 0.05; done",
                        "description": "Wait for compact tail", "timeout_ms": 30000}))]),
                    fixture.sse_tool_calls("notice-call", [("bash", "notice-call-id", json.dumps({
                        "cmd": "while [ ! -e notice-release ]; do sleep 0.05; done",
                        "description": "Check after notice", "timeout_ms": 30000}))]),
                    fixture.sse_answer("compact-answer", "compact-reason", "compact-message", "compact complete")[0],
                ])
                # Tall enough that every group row stays in one frame.
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 160, 100, 0, 0))
                try:
                    compact_deadline = time.monotonic() + 15
                    os.write(master, b"\x01\x0brun compact group\n")
                    read_terminal(master, "• Wait for compact tail", composer=True)
                    compact_release.touch()
                    read_terminal(master, "• Check after notice", composer=True)
                    while "✓ Wait for compact tail\n" not in (compact := current_screen(master)):
                        remaining = compact_deadline - time.monotonic()
                        assert remaining > 0, ("compact tail never permanently presented", compact)
                        next_frame(master, remaining)
                    headings = list(re.finditer(r"✓ (Compact item [0-9]+|Wait for compact tail)\n", compact))
                    assert [match[1] for match in headings] == compact_labels + ["Wait for compact tail"], compact
                    for match in headings[1:]:
                        assert compact[match.start() - 2:match.start()] not in ("\n\n", "\r\n"), (
                            "successful group gained a separator across reads", compact)
                    def hold_notice_result(response):
                        page = json.loads(response.split(b"\r\n\r\n", 1)[1])
                        if any("tool_result" in item["value"] for item in page["items"]):
                            notice_held.set()
                            assert notice_reply_release.wait(15), "notice result gate was not released"
                        return response
                    proxy.rewrite = hold_notice_result
                    proxy.route = "/v1/activity-page"
                    notice_release.touch()
                    fixture.wait_for(notice_held.is_set, "silent Activity result before notice")
                    os.write(master, b"\x00\n")
                    read_terminal(master, "! Input rejected; nothing sent.", composer=True)
                    notice_reply_release.set()
                    read_terminal(master, "compact complete", composer=True)
                    after_notice = settle_screen(master)
                    # A notice is status, not conversation: it neither enters
                    # nor splits the success group around it.
                    assert "✓ Wait for compact tail\n✓ Check after notice\n" in after_notice, after_notice
                    assert after_notice.index("compact complete") < after_notice.index("! Input rejected; nothing sent."), after_notice
                    proxy.route = "/v1/message"
                    proxy.rewrite = lambda response: response
                finally:
                    compact_release.touch()
                    notice_release.touch()
                    notice_reply_release.set()
                # A permission reader may refresh a stale Action that another
                # client has already allowed. It must not invent an approval
                # block or end the preceding success group merely by starting.
                for with_notice in (False, True):
                    index = int(with_notice)
                    prior_label = f"Prepare external approval {index}"
                    label = f"External approval {index}"
                    prior_release = state / f"external-release-{index}"
                    pending_held, pending_release = threading.Event(), threading.Event()
                    refreshed_held, refreshed_release = threading.Event(), threading.Event()
                    answer_release = threading.Event()
                    selected = []
                    answer = f"external approval complete {index}"
                    endpoint.responses.extend([
                        fixture.sse_tool_calls(f"external-prior-{index}", [("bash", f"external-prior-id-{index}", json.dumps({
                            "cmd": f"while [ ! -e external-release-{index} ]; do sleep 0.05; done",
                            "description": prior_label, "timeout_ms": 30000}))]),
                        fixture.sse_tool_calls(f"external-call-{index}", [("bash", f"external-id-{index}", json.dumps({
                            "cmd": "exit 0", "description": label, "timeout_ms": 30000}))]),
                        (fixture.sse_answer(f"external-answer-{index}", f"external-reason-{index}",
                            f"external-message-{index}", answer)[0], answer_release),
                    ])
                    def hold_pending_page(response):
                        pending_held.set()
                        assert pending_release.wait(15), "stale Action page was not released"
                        return response
                    def observe_action(response):
                        report = json.loads(response.split(b"\r\n\r\n", 1)[1])
                        if report["actionable_permissions"]:
                            selected.append(report["actionable_permissions"][0]["action"])
                            proxy.route = "/v1/activity-page"
                            proxy.rewrite = hold_pending_page
                        return response
                    def hold_refreshed_current(response):
                        report = json.loads(response.split(b"\r\n\r\n", 1)[1])
                        assert not report["actionable_permissions"], report
                        refreshed_held.set()
                        assert refreshed_release.wait(15), "permission refresh was not released"
                        return response
                    try:
                        run(home, "session", "configure", "--store", store, "--session", reference, "--permission-mode", "bypass")
                        proxy.rewrite = observe_action
                        proxy.route = "/v1/inspect-session"
                        os.write(master, f"external approval race {index}\n".encode())
                        read_terminal(master, f"• {prior_label}", composer=True)
                        run(home, "session", "configure", "--store", store, "--session", reference, "--permission-mode", "ask")
                        prior_release.touch()
                        prefix = terminal_gate(caller, master, pending_held, "stale actionable Current and pending page")
                        assert len(selected) == 1, selected
                        # A scan settled after the prior call and before the
                        # Action rightly shows that success; only the held
                        # stale page must change nothing.
                        held = settle_screen(master, quiet=0.5)
                        assert "? Run Bash" not in held, held
                        requests_before = len(endpoint.requests)
                        run(home, "action", "allow", "--store", store, "--session", reference, "--action", selected[0])
                        fixture.wait_for(lambda: len(endpoint.requests) == requests_before + 1, "successful external approval continuation")
                        proxy.rewrite = hold_refreshed_current
                        proxy.route = "/v1/inspect-session"
                        pending_release.set()
                        prefix += terminal_gate(caller, master, refreshed_held, "permission refresh without an Action")
                        if with_notice:
                            os.write(master, b"\x00\n")
                            read_terminal(master, "! Input rejected; nothing sent.", composer=True)
                            before_notice = current_screen(master)
                            # A page read under the stale Current shows only with a
                            # settled one: neither its success nor an approval yet.
                            assert (f"✓ {prior_label}\n" in before_notice) == (f"✓ {prior_label}\n" in held), (held, before_notice)
                            assert "? Run Bash" not in before_notice, before_notice
                            prefix = b""
                        refreshed_release.set()
                        await_screen(master, f"✓ {label}", composer=True)
                        shown = settle_screen(master)
                        start = shown.index(f"✓ {label}\n")
                        # A notice is status only; neither it nor the stale
                        # permission scan separates the two successes.
                        assert f"✓ {prior_label}\n✓ {label}\n" in shown, ("stale permission scan separated successes", with_notice, shown)
                        assert "? Run Bash" not in shown, ("stale scan invented an approval block", shown)
                        answer_release.set()
                        read_terminal(master, answer, composer=True)
                    finally:
                        prior_release.touch()
                        pending_release.set()
                        refreshed_release.set()
                        answer_release.set()
                    proxy.route = "/v1/message"
                    proxy.rewrite = lambda response: response
            finally:
                for release in bypass_releases:
                    release.touch()
        # A resize must retain the exact non-tail Unicode cursor without prose.
        os.write(master, "next café!\x1b[D\x1b[DX".encode())
        read_terminal(master, "› next cafXé!")
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 32, 0, 0))
        resized = read_terminal(master, "› next cafXé!")
        assert "terminal resized" not in resized, resized
        os.write(master, b"Y")
        read_terminal(master, "› next cafXYé!")
        caller.send_signal(signal.SIGTERM)
        assert caller.wait(timeout=5) == 0, caller.stderr.read()
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
            original[3] &= ~mask
        assert actual == original, "signal after inspection handoff did not restore terminal"
        # Opening uses certified labels, not undisplayed exact proposal fields.
        # Explicit inspection and permission above still read the exact command.
        hidden_reads = []
        proxy.route = "/v1/proposal-field"
        def observe_hidden_read(response):
            hidden_reads.append(len(response))
            return response
        proxy.rewrite = observe_hidden_read
        # Tall enough that the whole reopened conversation is one frame.
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 160, 100, 0, 0))
        caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", reference], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        reopened = read_terminal(master, "› ", composer=True)
        reopened += "\n" + settle_screen(master)
        assert "Process retirement confirmed" not in reopened and "macOS group signaling returned EPERM" not in reopened, (
            "routine retirement diagnostics leaked on reopening", reopened)
        if decision == "allow-action" and not any((exit_code, signal_failure, lost_reply, timed_out)):
            assert "✓ Prepare external approval 1\n✓ External approval 1\n" in reopened, ("reopening lost compact successes", reopened)
        if signal_failure:
            assert "Process-group signaling reported a failure." in reopened, ("reopening hid cleanup warning", reopened)
        assert not hidden_reads, ("label-only opening read undisplayed proposal bytes", hidden_reads)
        os.write(master, b"/exit\n")
        _, errors = terminal_exit(caller, master)
        assert caller.returncode == 0, errors
        actual = termios.tcgetattr(slave)
        if sys.platform == "darwin":
            mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
            actual[3] &= ~mask
        assert actual == original, "label-only opening left terminal configuration changed"
        if exit_code:
            # Age the same saved result out of opening, then reconstruct it
            # through /history. Neither navigation nor export may rerun Bash.
            proxy.close()
            proxy = None
            for index in range(9):
                endpoint.responses.append(fixture.sse_answer(f"aging-{index}", f"aging-r-{index}",
                    f"aging-m-{index}", f"later answer {index}")[0])
                key = f"aging-{index}"
                fixture.message(state, store, key, reference, f"later input {index}")
                fixture.wait_for(lambda: fixture.completed_observation(store, key), "age saved Tool Result")
            calls_before_history = len(endpoint.requests)
            # Wide enough that the raw export command is one row.
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 512, 0, 0))
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", reference], env={**os.environ, "HOME": str(home)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            read_terminal(master, "› ")
            os.write(master, b"/history\n")
            read_terminal(master, "Browsing · Esc returns")
            scroll_until(master, b"\x1b[5~", "Start of conversation")
            history = current_screen(master)
            assert f"! {description} — Failed\nRui: Historical item omitted:" in history, history
            assert "inspection-only-output" not in history
            history_export = raw_export(master, history)
            assert history_export == export and run(home, *shlex.split(history_export)[1:]) == exported
            assert len(endpoint.requests) == calls_before_history and effect.read_text() == "unsafe"
            os.write(master, b"/exit\n")
            _, errors = terminal_exit(caller, master)
            assert caller.returncode == 0, errors
        completed = True
        print(f"persistent permission: inline {decision}, lost={lost_reply}, fragmented={fragmented_paste}, quiet outcome, retained cursor, label-only opening and TERM cleanup passed", flush=True)
    finally:
        if sys.exc_info()[0] is not None:
            preserve_failure_metadata(state / "pty-failure.json", lambda: {
                "case": "persistent_permission", "decision": decision,
                "lost_reply": lost_reply, "fragmented_paste": fragmented_paste,
                "error": sys.exc_info()[0].__name__,
                "caller_returncode": caller.poll() if caller is not None else None,
                "ready_pending": bool(select.select([ready_read], [], [], 0)[0]),
                "terminal_pending": bool(select.select([master], [], [], 0)[0]) if master is not None else None,
            })
        dispose_all(
            arguments_release.set,
            lambda: stop_process(caller, timeout=5) if caller is not None else None,
            lambda: proxy.close() if proxy is not None else None,
            *(lambda fd=fd: os.close(fd) for fd in (master, slave, ready_read, ready_write) if fd is not None),
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained persistent permission failure state: {state}", file=sys.stderr)


def store_selection_cases(state, workspace, valid_store):
    for case in ("saved-initial", "saved-after", "explicit-override", "explicit-create", "home-create"):
        home = state / case
        home.mkdir(mode=0o700)
        destination = home / ".local/share/rui/store" if case == "home-create" else home / "store"
        saved = case.startswith("saved") or case == "explicit-override"
        if saved:
            destination.mkdir(mode=0o700)
            defaults(home, "--store", destination, "--provider", "codex", "--model", "gpt-6-luna")
            if case != "saved-after":
                destination.rmdir()
                assert run(home, "host", "status", success=False) == ""
        if not case.startswith("saved"):
            (home / ".config/rui").mkdir(mode=0o700, parents=True, exist_ok=True)
            codex_fixture.credentials(home / ".config/rui/codex.json")
        explicit = valid_store if case == "explicit-override" else destination
        if case == "explicit-override":
            assert json.loads(run(home, "host", "status", "--store", explicit))["status"] == "ready"
        args = ["--store", str(explicit)] if case.startswith("explicit") else []
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        caller = subprocess.Popen([str(fixture.RUI), *args], cwd=workspace,
            env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(ready_write)},
            pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        os.close(ready_write)
        try:
            settlement_timeout = 5
            if case == "saved-after":
                assert "No locally ready provider" in provider_prompt(master, ready_read)
                destination.rmdir()
                assert run(home, "host", "status", success=False) == ""
                response_deadline = time.monotonic() + settlement_timeout
                os.write(master, b"d\n")
                # Darwin prompt cleanup can wait for this PTY consumer. Drain
                # the actual deferral response within the original exit budget.
                read_terminal(master, "Rui: Login deferred.", timeout=response_deadline - time.monotonic())
                settlement_timeout = response_deadline - time.monotonic()
                assert settlement_timeout > 0, "saved-Store deferral did not settle within 5 seconds"
            if not case.startswith("saved"):
                greeting = read_terminal(master, "› ")
                assert "Session:" not in greeting and "request:" not in greeting, greeting
                terminal_step(master, "/exit", "Detached.")
            _, errors = caller.communicate(timeout=settlement_timeout)
            if case.startswith("saved"):
                assert caller.returncode != 0 and b"FileNotFound" in errors, (case, errors)
                assert not destination.exists() and not (home / ".config/rui/requests").exists()
            else:
                assert caller.returncode == 0, (case, errors)
                record, = (home / ".config/rui/requests").glob("*.json")
                binding = json.loads(record.read_bytes())
                assert binding["store"] == str(explicit.resolve()) and binding["require_model"] is True
            print("Store provenance:", case, "passed", flush=True)
        finally:
            def stop_created_host():
                if case in ("explicit-create", "home-create") and destination.exists():
                    run(home, "host", "stop", "--store", destination)
                    fixture.wait_for(lambda: json.loads(run(home, "host", "status", "--store", destination))["status"] == "unavailable", "created Host stopped")

            dispose_all(lambda: stop_process(caller, timeout=5),
                        lambda: os.close(ready_read), lambda: os.close(master),
                        lambda: os.close(slave), stop_created_host)


def action_ready(descriptor, master, timeout=15, *, return_to_action=True):
    """Supply normal terminal credit until the actual fresh-input boundary.

    Read exactly one notification, never a future choice's byte. Return the
    distinct committed frames shown meanwhile. A selected inspection keeps
    the Action behind it; like a user, return to it once with Ctrl-G unless
    the caller is checking that paused state itself. Deliberately
    withheld-credit controls must select the pipe directly.
    """
    capture = terminal_capture(master)
    deadline = time.monotonic() + timeout
    frames = []
    returned = [not return_to_action]

    def observe(screen, x, y):
        if not frames or frames[-1] != screen:
            frames.append(screen)
            while sum(len(frame) for frame in frames) >= 1024 * 1024 and len(frames) > 1:
                frames.pop(0)

    capture.listener = observe
    try:
        while True:
            if not returned[0] and "Approval paused · Esc returns to Action" in capture.completed:
                returned[0] = True
                os.write(master, b"\x07")
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
                # A notification from before a later invalidation (another
                # page selected, or approval readiness redrawn) is stale:
                # readiness is the visible Action with its choice prompt.
                shown = capture.completed
                choice = " ".join(shown.split())
                if ("Approval paused" not in shown
                        and capture.screen.display[capture.screen.cursor.y].startswith(">")
                        and ("Type a + Enter to allow once · d + Enter to deny" in choice or "a Allow / d Deny Enter" in choice)):
                    return "\n".join(frames)
    finally:
        capture.listener = None


def provider_prompt(master, ready, command=None):
    # Initial prompts use a fresh pipe. Later prompts must not consume an
    # unread notification from an earlier choice as readiness for this one.
    if command is not None:
        assert not select.select([ready], [], [], 0)[0], "stale provider readiness"
        os.write(master, (command + "\n").encode())
    deadline = time.monotonic() + 15
    output = read_terminal(master, "Provider: [c]", timeout=deadline - time.monotonic())
    # The provider prompt is a main-screen line before any Session frame:
    # its readiness is the notification itself, after the prompt's bytes.
    capture = terminal_capture(master)
    total = capture.plain_total
    while True:
        remaining = deadline - time.monotonic()
        assert remaining > 0, ("provider prompt readiness did not arrive", capture.plain)
        selected = select.select([ready, master], [], [], remaining)[0]
        if master in selected:
            capture.feed(os.read(master, 65536))
        if ready in selected:
            assert os.read(ready, 1) == b"x", "prompt caller exited before readiness"
            while select.select([master], [], [], 0)[0]:
                chunk = os.read(master, 65536)
                assert chunk, "prompt terminal closed at readiness"
                capture.feed(chunk)
            break
    output += capture.plain_since(total)
    assert not select.select([ready], [], [], 0)[0], "extra provider readiness"
    return output


def terminal_bulk(master, command, marker="› ", *, submit=True, draft=None, caret=None):
    """Write a large input in chunks while the screen is read.

    With `draft`, wait instead until the composer shows exactly that draft
    with its caret at display column `caret`. Returns the frames seen; the
    terminal's output volume meanwhile is in `terminal_bulk.received`.
    """
    fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
        "noncanonical terminal input")
    def send():
        payload = (command + ("\n" if submit else "")).encode()
        for offset in range(0, len(payload), 1024):
            os.write(master, payload[offset:offset + 1024])

    capture = terminal_capture(master)
    received = capture.received_bytes
    writer = threading.Thread(target=send, daemon=True)
    writer.start()
    if draft is None:
        output = read_terminal(master, marker)
    else:
        deadline = time.monotonic() + 15
        frames = []
        while not capture.draft(draft, caret):
            remaining = deadline - time.monotonic()
            frame = next_frame(master, max(0, remaining))
            assert frame is not None, ("draft not drawn", draft[:80], caret, capture.completed, capture.screen.cursor.x)
            frames.append(frame)
        output = "\n".join(frames)
    writer.join(timeout=5)
    assert not writer.is_alive(), "bulk terminal writer stalled"
    terminal_bulk.received = capture.received_bytes - received
    return output


def saved_capture_cases(state, store, workspace):
    home = state / "capture-home"
    home.mkdir()
    records = home / ".config/rui/requests"
    args = ["session", "configure", "--store", store, "--session", "capture/original",
        "--workspace", workspace, "--provider", "codex", "--model", "model-a"]
    gate = state / "capture-original-reader"
    caller = subprocess.Popen([str(fixture.RUI), *map(str, args)],
        env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    original = None
    record = None
    try:
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "capture reader publication")
        handles = json.loads(run(home, "request", "list"))
        assert len(handles) == 1, handles
        handle = handles[0]
        record = records / f"{handle}.json"
        original = record.read_bytes()
        assert fixture.command("request", "inspect", "--store", store,
            "--key", handle)["observation"]["status"] == "absent"
        # A pathname replacement after publication must not swap the bytes
        # selected by the captured owner before its announcement.
        replaced = json.loads(original)
        replaced["session"] = "capture/replacement"
        replacement = records / "replacement"
        replacement.write_text(json.dumps(replaced, separators=(",", ":")))
        replacement.replace(record)
        pathlib.Path(f"{gate}.release").touch()
        output, errors = caller.communicate(timeout=20)
        assert caller.returncode == 0, (output, errors)
        captured = CAPTURE_NOTICE.match(errors)
        admission = json.loads(output)
        assert captured and captured.group(1) == handle and admission["answer"]["status"] == "accepted", (output, errors)
        observed = fixture.command("request", "inspect", "--store", store, "--key", handle)["observation"]
        assert observed["target"] == "capture/original", ("captured owner transmitted a replaced pathname", observed)
    finally:
        dispose_all(lambda: stop_process(caller, timeout=5),
                    lambda: record.write_bytes(original) if original is not None else None)

    # Recovery must ignore a newly selected, nonexistent preference Store.
    defaults(home, "--store", store)
    preferences = home / ".config/rui/preferences"
    preferences.write_text(f"version=1\nstore={state / 'missing-capture-store'}\n")
    assert json.loads(run(home, "request", "recover", handle))["answer"]["replayed"] is True

    # Failure to announce happens after publication but before any send.
    before = set(json.loads(run(home, "request", "list")))
    output = run(home, *args, success=False,
        environment={"RUI_TEST_CAPTURE_GATE": str(state / "missing-parent/gate")})
    assert output == "", output
    failed_notice, = set(json.loads(run(home, "request", "list"))) - before
    assert fixture.command("request", "inspect", "--store", store,
        "--key", failed_notice)["observation"]["status"] == "absent"
    assert json.loads(run(home, "request", "recover", failed_notice))["answer"]["replayed"] is False

    # Linux libc fault injection reaches the actual post-rename directory sync,
    # not a fixture-only success path. No automatic send may follow uncertainty.
    if sys.platform == "linux":
        source, library = state / "capture-sync.c", state / "capture-sync.so"
        source.write_text(r"""
#include <dlfcn.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
int fsync(int fd) {
    struct stat value;
    if (!fstat(fd, &value) && S_ISDIR(value.st_mode)) { errno = EIO; return -1; }
    int (*real_sync)(int) = dlsym(RTLD_NEXT, "fsync");
    return real_sync(fd);
}
""")
        subprocess.run(["cc", "-shared", "-fPIC", str(source), "-ldl", "-o", str(library)], check=True)
        before = set(json.loads(run(home, "request", "list")))
        failed = subprocess.run([str(fixture.RUI), *map(str, args)],
            env={**os.environ, "HOME": str(home), "LD_PRELOAD": str(library)},
            capture_output=True, text=True, timeout=20)
        assert failed.returncode != 0 and "RecordDirectorySyncFailed" in failed.stderr, failed
        assert failed.stdout == "", failed.stdout
        uncertain, = set(json.loads(run(home, "request", "list"))) - before
        assert fixture.command("request", "inspect", "--store", store,
            "--key", uncertain)["observation"]["status"] == "absent"
        assert json.loads(run(home, "request", "recover", uncertain))["answer"]["replayed"] is False
    else:
        print("capture directory-sync injection: unavailable outside Linux", flush=True)

    invalid = "01234567-89ab-4cde-8012-3456789abcde"
    stopped = "01234567-89ab-4cde-8012-3456789abcdf"
    (records / f"{invalid}.json").write_text("not a readable record")
    # Every mutation kind, including Session stop, is a recoverable capture.
    stop = {"version": "1", "kind": "session_stop", "store": str(store.resolve()),
        "key": stopped, "session": "capture/original"}
    (records / f"{stopped}.json").write_text(json.dumps(stop, separators=(",", ":")))
    (records / "not-a-handle.json").write_text("not a record")
    listed = json.loads(run(home, "request", "list"))
    assert invalid in listed and stopped in listed and "not-a-handle" not in listed, listed
    assert run(home, "request", "recover", invalid, success=False) == ""
    recovered_stop = json.loads(run(home, "request", "recover", stopped))
    assert recovered_stop["context"] == {"store": str(store.resolve()), "session": "capture/original",
        "key": stopped, "kind": "session_stop"}, recovered_stop
    assert recovered_stop["answer"]["status"] == "accepted", recovered_stop
    with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
        "--", "capture/original"], env={**os.environ, "HOME": str(home)},
    ) as (entered, master):
        read_terminal(master, "› ")
        listing = terminal_step(master, "/requests", "Local recovery handles", composer=True)
        assert handle in listing and failed_notice in listing and f"{stopped} (session_stop)" in listing, listing
        assert invalid not in listing, listing
        terminal_step(master, "/exit", "Detached.")
        assert entered.wait(timeout=5) == 0
    print("saved capture owner: pinned original bytes, preference-independent recovery, failed announcement, "
        "sync uncertainty, listing asymmetry", flush=True)


def silent_read_edit_cases():
    """Silent observation must not hide accepted draft edits with ECHO off."""
    import canonical_failure_integration as canonical
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-silent-edit."))
    home, store = state / "home", state / "store"
    home.mkdir(mode=0o700)
    host = caller = proxy = None
    completed = False
    try:
        host = fixture.start_host(store, None)
        for index, route in enumerate(("/v1/inspect-session", "/v1/activity-page")):
            reference = f"silent/{index}"
            run(home, "session", "configure", "--store", store, "--session", reference,
                "--workspace", state, "--provider", "codex", "--model", "model-a")
            master, slave = open_pty()
            original = termios.tcgetattr(slave)
            held, release = threading.Event(), threading.Event()
            try:
                caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), reference],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                read_terminal(master, "› ")
                def hold(response):
                    held.set()
                    assert release.wait(15), "silent read was not released"
                    return response
                proxy = canonical.ReplyProxy(host, route, hold)
                terminal_gate(caller, master, held, ("silent observation", route))
                os.write(master, "visible café!\x1b[D\x1b[DX".encode())
                output = read_terminal(master, "› visible cafXé!", timeout=5)
                assert not release.is_set() and "Run Bash:" not in output
                release.set()
                before = set((home / ".config/rui/requests").glob("*.json"))
                os.write(master, b"\n")
                fixture.wait_for(lambda: len(set((home / ".config/rui/requests").glob("*.json")) - before) == 1,
                    "visible draft capture")
                record, = set((home / ".config/rui/requests").glob("*.json")) - before
                assert json.loads(record.read_bytes())["text"]["value"] == "visible cafXé!"
                os.write(master, b"\x03")
                _, errors = terminal_exit(caller, master)
                assert caller.returncode == 0, errors
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original
                print(f"silent observation: {route} visible Unicode edit and exact capture passed", flush=True)
            finally:
                dispose_all(release.set,
                            lambda: stop_process(caller, timeout=5) if caller is not None else None,
                            lambda: proxy.close() if proxy is not None else None,
                            lambda: os.close(master), lambda: os.close(slave))
                proxy = None
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained silent-edit failure state: {state}", file=sys.stderr)


def opaque_session_commands_case():
    """Execute generated commands without losing opaque Session bytes in argv."""
    from control_integration import raw_request
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-opaque-session."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    reference = "human/nul\x00' é\n--last"
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("opaque-actions", [("bash", "opaque-deny", json.dumps({"cmd": "touch must-not-run", "description": "Create forbidden marker", "timeout_ms": None})),
                                                   ("bash", "opaque-allow", json.dumps({"cmd": "touch allowed-once", "description": "Create approved marker", "timeout_ms": None}))]),
        fixture.sse_answer("opaque-answer", "opaque-r", "opaque-m", "Opaque decisions complete.")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    ready_read, ready_write = os.pipe()
    host = entered = None
    master = slave = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        for key, session in (("prefix", "human/nul"), ("opaque", reference)):
            body = {"version": "1", "kind": "configure", "store": str(store), "key": key,
                    "session": session, "configuration": {
                        **{name: {"state": "value", "value": value} for name, value in
                           (("workspace", str(state)), ("provider", "codex"), ("model", "model-a"))},
                        **{name: {"state": "omitted"} for name in
                           ("instructions", "tools", "permission_mode", "output_schema")}}}
            body["configuration"]["permission_mode"] = {"state": "value", "value": "ask"}
            head, answer = raw_request(host.rui_ready_fields["socket"], "/v1/configure", json.dumps(body).encode())
            assert b" 200 " in head and json.loads(answer)["answer"]["status"] == "accepted", (head, answer)
        # Wide enough that each printed recovery command is one inspection row.
        master, slave = open_pty(columns=256)
        entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "--last"],
            cwd=state, env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=slave)
        read_terminal(master, "› ")
        assert "Session: human/nul\\x00" in terminal_step(master, "/status", "Session: ", composer=True)
        farewell = terminal_step(master, "/exit", "Resume: ")
        assert entered.wait(timeout=5) == 0
        command = farewell.split("Resume: ", 1)[1].split("\n", 1)[0]
        bin_dir = state / "bin"
        bin_dir.mkdir()
        (bin_dir / "rui").symlink_to(fixture.RUI)
        entered = subprocess.Popen(["bash", "-c", "exec " + command], cwd=state,
            env={**os.environ, "HOME": str(home), "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                 "RUI_TEST_ACTION_READY_FD": str(ready_write)}, pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        read_terminal(master, "› ")
        actual = terminal_step(master, "/status", "Session: ", composer=True)
        assert "Session: human/nul\\x00" in actual, (command, actual)
        os.write(master, b"propose two distinct Actions\n")
        proposal = action_ready(ready_read, master)
        for label, decision in (("Deny: ", "deny"), ("Allow once: ", "allow_once")):
            terminal_step(master, "/inspect-action", label)
            inspection = current_screen(master)
            action_ready(ready_read, master)
            printed = inspection.split(label, 1)[1].split("\n", 1)[0]
            reply = subprocess.run(["bash", "-c", "exec " + printed], cwd=state,
                env={**os.environ, "HOME": str(home), "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]},
                capture_output=True, text=True, timeout=10)
            assert reply.returncode == 0, (printed, reply.stdout, reply.stderr)
            captured = CAPTURE_NOTICE.match(reply.stderr)
            assert captured, reply.stderr
            admission = json.loads(reply.stdout)
            saved = json.loads((home / ".config/rui/requests" / (captured.group(1) + ".json")).read_bytes())
            assert admission["answer"]["status"] == "accepted", admission
            assert saved["session"] == reference and saved["decision"] == decision
            assert saved["action"] == printed.rsplit(" --action ", 1)[1], (saved, printed)
            print(json.dumps({"printed": printed, "decision": decision, "exact_session": True}), flush=True)
        fixture.wait_for(lambda: (state / "allowed-once").exists(), "printed Allow executed its exact Action")
        assert (state / "allowed-once").exists() and not (state / "must-not-run").exists()
        # Type only once the decided choice has left the screen; a line begun
        # at a choice withdrawn meanwhile is the separate defect #540.
        capture = terminal_capture(master)
        deadline = time.monotonic() + 15
        while "Opaque decisions complete." not in capture.completed or "Type a + Enter" in capture.completed:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([master], [], [], remaining)[0], capture.completed
            chunk = os.read(master, 65536)
            assert chunk, capture.completed
            capture.feed(chunk)
        terminal_step(master, "/exit", "Resume: ")
        assert entered.wait(timeout=5) == 0
        before = {path: path.read_bytes() for path in (home / ".config/rui/requests").glob("*.json")}
        invalid_hex = ("", "0", "zz", "ff", "61" * 129)
        for route in (("session", "resume"), ("action", "allow"), ("action", "deny")):
            extra = [] if route[1] == "resume" else ["--action", "1"]
            negatives = [["--session-hex", value] for value in invalid_hex]
            negatives += [["--session-hex", "61", "--session-hex", "62"]]
            negatives += ([["--last", "--session-hex", "61"], ["--session-hex", "61", "other"],
                           ["other", "--session-hex", "61"]] if route[1] == "resume" else
                          [["--session", "plain", "--session-hex", "61"],
                           ["--session-hex", "61", "--session", "plain"],
                           ["--session", "plain", "--session", "other"],
                           ["--session-hex", reference.encode().hex(), "--action", "1"],
                           ["--session-hex", reference.encode().hex(), "--action", "2"]])
            for flags in negatives:
                rejected = subprocess.run([str(fixture.RUI), *route, "--store", str(store), *flags, *extra],
                    env={**os.environ, "HOME": str(home)}, capture_output=True, timeout=10)
                assert rejected.returncode != 0 and b"InteractiveTerminalRequired" not in rejected.stderr, (route, flags, rejected)
        assert {path: path.read_bytes() for path in before} == before
        assert set((home / ".config/rui/requests").glob("*.json")) == set(before)
        completed = True
        print("opaque Session: actual printed resume preserves NUL and rejects a configured prefix lookalike", flush=True)
    finally:
        if sys.exc_info()[0] is not None:
            preserve_failure_metadata(state / "pty-failure.json", lambda: {
                "case": "opaque_session_commands", "error": sys.exc_info()[0].__name__,
                "caller_returncode": entered.poll() if entered is not None else None,
                "ready_pending": bool(select.select([ready_read], [], [], 0)[0]) if ready_read is not None else None,
                "terminal_pending": bool(select.select([master], [], [], 0)[0]) if master is not None else None,
            })
        dispose_all(
            lambda: stop_process(entered, timeout=5) if entered is not None else None,
            *(lambda fd=fd: os.close(fd) for fd in (master, slave, ready_read, ready_write) if fd is not None),
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained opaque-Session failure state: {state}", file=sys.stderr)


def long_input_case(home, store, workspace, endpoint, host):
    import canonical_failure_integration as canonical
    endpoint.responses.append(fixture.sse_answer("long-answer", "long-reason", "long-message", "long input intact")[0])
    long_session = "human/long-input"
    run(home, "session", "configure", "--store", store, "--session", long_session,
        "--workspace", workspace, "--provider", "codex", "--model", "model-a")
    proxy = canonical.ReplyProxy(host, "/v1/message", lambda response: response)
    master = slave = entered = None
    try:
        master, slave = open_pty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 40, 0, 0))
        entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", long_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        greeting = read_terminal(master, "› ")
        assert "Permission:" not in greeting, greeting
        assert "Bash runs without" not in greeting, ("bypass is quiet", greeting)
        assert "Bash commands can run without asking you" not in greeting, greeting
        binding = terminal_step(master, "/status", "Session: ", composer=True)
        assert permission_row(binding, "bypass") and "Provider: codex" in binding and "Model: model-a" in binding, binding
        return_to_live(master)
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 2048, 0, 0))
        before = len(endpoint.requests)
        long_text = "X" * 5000
        answer = terminal_bulk(master, long_text, "long input intact")
        assert "long input intact" in answer, answer
        assert len(endpoint.requests) == before + 1
        body = json.loads(endpoint.requests[-1])
        assert next(item["content"][0]["text"] for item in reversed(body["input"])
            if item.get("role") == "user") == long_text
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        long_cluster = "a" + "\u0301" * 2048
        for index, draft in enumerate((long_cluster, ("e" + "\u0301" * 1024) * 3,
                                       "ab" + "\u0301" * 32767)):
            marker = f"encoded row accepted {index}"
            endpoint.responses.append(fixture.sse_answer(f"encoded-answer-{index}",
                f"encoded-reason-{index}", f"encoded-message-{index}", marker)[0])
            before_draft = len(endpoint.requests)
            before_messages = len(proxy.mutations)
            before_records = set((home / ".config/rui/requests").glob("*.json"))
            # Do not race Enter against redraw: the complete unsent draft
            # must remain renderable before any capture/transmission.
            caret = (3, 5, 4)[index]  # Independent display-cell expectations.
            terminal_bulk(master, "\x1b[200~" + draft + "\x1b[201~", submit=False, draft=draft, caret=caret)
            assert entered.poll() is None and len(endpoint.requests) == before_draft
            assert len(proxy.mutations) == before_messages, "unsent draft transmitted a Message"
            assert set((home / ".config/rui/requests").glob("*.json")) == before_records, "unsent draft published a capture"
            terminal_step(master, "", marker, composer=True)
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == draft
        # A draft tab is drawn as one space; the submitted bytes keep it.
        for index, (columns, draft, drawn) in enumerate((
                (80, "A中e\u0301\tB", ("A中é B", 8)),
                (8, "abc\tQ", ("abc Q", 7)))):
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))
            marker = f"tab row accepted {index}"
            endpoint.responses.append(fixture.sse_answer(f"tab-answer-{index}",
                f"tab-reason-{index}", f"tab-message-{index}", marker)[0])
            before_draft = len(endpoint.requests)
            before_messages = len(proxy.mutations)
            before_records = set((home / ".config/rui/requests").glob("*.json"))
            terminal_bulk(master, "\x1b[200~" + draft + "\x1b[201~", submit=False, draft=drawn[0], caret=drawn[1])
            assert entered.poll() is None and len(endpoint.requests) == before_draft
            assert len(proxy.mutations) == before_messages, "unsent draft transmitted a Message"
            assert set((home / ".config/rui/requests").glob("*.json")) == before_records, "unsent draft published a capture"
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            terminal_step(master, "", marker, composer=True)
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == draft
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        endpoint.responses.append(fixture.sse_answer("encoded-delete-answer", "encoded-delete-reason",
            "encoded-delete-message", "encoded deletion intact")[0])
        terminal_bulk(master, "\x1b[200~" + long_cluster + "\x1b[201~", submit=False, draft=long_cluster, caret=3)
        terminal_step(master, "\x7fZ", "encoded deletion intact", composer=True)
        body = json.loads(endpoint.requests[-1])
        assert next(item["content"][0]["text"] for item in reversed(body["input"])
            if item.get("role") == "user") == "Z", body
        accepted_count = len(endpoint.requests)
        rejected = terminal_bulk(master, "Y" * (64 * 1024 + 1) + "\x7f", "input too long")
        assert "input too long" in rejected and "nothing sent" in rejected, rejected[-1000:]
        assert "Draft cleared. Enter a shorter message." in rejected, rejected[-1000:]
        if not terminal_capture(master).draft("", 2):
            rejected += read_terminal(master, "› ", composer=True)
        assert terminal_capture(master).draft("", 2), ("oversized draft was not cleared", current_screen(master))
        assert len(endpoint.requests) == accepted_count, "oversized input reached Host"
        endpoint.responses.append(fixture.sse_answer("shorter-answer", "shorter-reason",
            "shorter-message", "shorter replacement intact")[0])
        terminal_step(master, "shorter replacement", "shorter replacement intact", composer=True)
        assert len(endpoint.requests) == accepted_count + 1
        body = json.loads(endpoint.requests[-1])
        assert next(item["content"][0]["text"] for item in reversed(body["input"])
            if item.get("role") == "user") == "shorter replacement", body
        accepted_count += 1
        rejected = terminal_step(master, "invalid\x00x", "Input rejected; nothing sent.")
        assert "Input rejected; nothing sent." in rejected and "--text FILE" not in rejected, rejected
        assert len(endpoint.requests) == accepted_count, "unsupported control reached Host"
        assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
        assert entered.wait(timeout=5) == 0
        assert termios.tcgetattr(master)[3] & termios.ICANON
    finally:
        incoming = sys.exc_info()[1]
        if incoming is not None:
            preserve_failure_metadata(home.parent / "pty-failure.json", lambda: {
                "case": "long_input", "error": type(incoming).__name__,
                "terminal": getattr(incoming, "terminal_metadata", None),
                "caller_returncode": entered.poll() if entered is not None else None,
                "message_transmissions": len(proxy.mutations),
                "provider_requests": len(endpoint.requests),
                "request_records": len(list((home / ".config/rui/requests").glob("*.json"))),
            })
        disposals = ([lambda: stop_process(entered, timeout=5)] if entered is not None else [])
        disposals += [lambda fd=fd: os.close(fd) for fd in (master, slave) if fd is not None]
        disposals.append(proxy.close)
        dispose_all(*disposals)


def incomplete_input_case(home, store, session, endpoint, host):
    """Retain terminal custody through delayed collection and restoration."""
    import canonical_failure_integration as canonical
    callers = []
    before = len(endpoint.requests)
    records = home / ".config/rui/requests"
    before_records = {path: path.read_bytes() for path in records.glob("*.json")}
    proxy = canonical.ReplyProxy(host, None)
    try:
        for incomplete in (b"\xc3", b"\x1b[200~unfinished", b"\x1b[", b"\x1bO"):
            master, slave = open_pty()
            try:
                original = termios.tcgetattr(slave)
                entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                    "--", session], env={**os.environ, "HOME": str(home)},
                    stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            except BaseException:
                dispose_all(lambda: os.close(master), lambda: os.close(slave))
                raise
            deadline = time.monotonic() + 7
            callers.append((master, slave, entered, original, deadline))
            read_terminal(master, "› ", timeout=deadline - time.monotonic())
            os.write(master, incomplete)
            # Shared-Host polling is not decoder load coverage. Reap each
            # caller before collection while retaining its parent slave.
            assert entered.wait(timeout=deadline - time.monotonic()) != 0
            output, errors = terminal_exit(entered, master, timeout=deadline - time.monotonic())
            assert b"IncompleteTerminalInput" in errors, (output, errors)
            assert b"\x1b[0m\x1b[?2004l" in output, "delayed collector lost terminal cleanup"
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original, (actual, original)
    finally:
        disposals = []
        for master, slave, entered, _, _ in callers:
            disposals.extend((lambda process=entered: stop_process(process, timeout=5),
                              lambda fd=master: os.close(fd), lambda fd=slave: os.close(fd)))
        dispose_all(*disposals, proxy.close)
    assert not proxy.mutations, "incomplete terminal input transmitted a Message or Decision"
    assert {path: path.read_bytes() for path in records.glob("*.json")} == before_records, "incomplete input published a capture"
    assert len(endpoint.requests) == before, "incomplete terminal input reached provider"
    print("incomplete input: all four native deadlines, delayed output, exact restoration and no dispatch passed", flush=True)


def renderer_cases():
    """Full-screen geometry, input, consent and restoration through screen cells."""
    from contextlib import contextmanager
    from terminal_screen import ScreenCapture
    import canonical_failure_integration as canonical
    import resource

    # Every-frame oracles see each synchronized commit, not just the newest one after a read.
    control, seen = ScreenCapture(), []
    control.listener = lambda screen, x, y: seen.append(screen)
    control.feed(b"\x1b[?2026h\x1b[HBROKEN INTERMEDIATE\x1b[?2026l"
                 b"\x1b[?2026h\x1b[H\x1b[2JCORRECT FINAL\x1b[?2026l")
    assert len(seen) == 2 and "BROKEN INTERMEDIATE" in seen[0], seen
    assert "BROKEN" not in control.completed and "CORRECT FINAL" in control.completed, control.completed

    original_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(256, original_limit[0]), original_limit[1]))

    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-renderer."))
    # Always wrap the Workspace, including on short Linux temporary roots.
    home, store, workspace = state / "home", state / "store", state / ("workspace-" + "w" * 80)
    home.mkdir(mode=0o700)
    workspace.mkdir()
    endpoint = fixture.SuccessEndpoint([])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = proxy = None
    completed = False

    class Terminal:
        def __init__(self, master, slave, caller):
            self.master, self.slave, self.caller = master, slave, caller
            self.capture = ScreenCapture()

        def resize(self, columns, rows=24):
            self.capture.resize(columns, rows)
            fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

        def feed(self, data):
            self.capture.feed(data)

        def wait(self, marker=None, *, predicate=None, after=None, timeout=15):
            deadline = time.monotonic() + timeout
            while not ((after is None or self.capture.generation > after) and
                       (predicate() if predicate is not None else self.capture.reached(marker))):
                remaining = deadline - time.monotonic()
                assert remaining > 0 and select.select([self.master], [], [], remaining)[0], (
                    "renderer screen deadline", marker, self.capture.completed,
                    self.caller.poll(), self.capture.screen.cursor)
                chunk = os.read(self.master, 65536)
                assert chunk, ("renderer terminal closed", marker)
                # Collection budget excludes observer work on long combining
                # cells; this is not a native wall-response performance claim.
                before = time.monotonic()
                self.feed(chunk)
                deadline += time.monotonic() - before
            return self.capture.completed

        def every_frame(self):
            """Every committed frame from now on. One read can commit several
            frames; the newest after a read hides the ones before it."""
            frames = []
            self.capture.listener = lambda screen, x, y: frames.append(screen)
            return frames

        def send(self, text, marker=None, *, predicate=None):
            generation = self.capture.generation
            payload = text.encode()
            failure = []
            def write():
                try:
                    for offset in range(0, len(payload), 1024):
                        remaining = memoryview(payload)[offset:offset + 1024]
                        while remaining:
                            remaining = remaining[os.write(self.master, remaining):]
                except BaseException as error:
                    failure.append(error)
            writer = threading.Thread(target=write, daemon=True)
            writer.start()
            result = self.wait(marker, predicate=predicate, after=generation)
            writer.join(timeout=5)
            assert not writer.is_alive(), "renderer input writer stalled"
            if failure:
                raise failure[0]
            return result

        def ready(self, descriptor):
            deadline = time.monotonic() + 15
            while True:
                remaining = deadline - time.monotonic()
                assert remaining > 0, "renderer Action readiness deadline"
                ready = select.select([descriptor, self.master], [], [], remaining)[0]
                assert ready, "renderer Action readiness missing"
                if self.master in ready:
                    self.feed(os.read(self.master, 65536))
                if descriptor in ready:
                    assert os.read(descriptor, 1) == b"x"
                    while select.select([self.master], [], [], 0)[0]:
                        assert time.monotonic() < deadline
                        self.feed(os.read(self.master, 65536))
                    return

        def finish(self, expected=0):
            # Own BOTH streams through actual exit, rather than communicate
            # while an undrained PTY can still hold the final renderer writes.
            deadline = time.monotonic() + 10
            pending = {self.master, self.caller.stderr.fileno()}
            output, errors = bytearray(), bytearray()
            while True:
                exited = self.caller.poll() is not None
                remaining = deadline - time.monotonic()
                assert remaining > 0, ("renderer exit deadline", bytes(errors))
                ready = select.select(list(pending), [], [], 0 if exited else min(remaining, 0.1))[0]
                if exited and not ready:
                    break
                for fd in ready:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError as error:
                        if fd != self.master or error.errno != errno.EIO:
                            raise
                        chunk = b""
                    if not chunk:
                        pending.remove(fd)
                    elif fd == self.master:
                        output.extend(chunk)
                        self.feed(chunk)
                    else:
                        errors.extend(chunk)
                    assert len(output) + len(errors) < 1024 * 1024
            assert self.caller.wait(timeout=1) == expected, bytes(errors)
            # These are protocol cleanup checks, not displayed-content claims.
            assert b"\x1b[?1049l" in output and b"\x1b[?2004l" in output, output
            assert b"\x1b[?25h" in output, output
            return bytes(output), bytes(errors)

    @contextmanager
    def terminal(session, ready_write=None, *, columns=80, rows=24, opening=True, initial_text=None, tmux=False):
        master, slave = open_pty()
        original = termios.tcgetattr(slave)
        original_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        # Asymmetric user state catches restoration to generic sane defaults.
        original[6][termios.VERASE] = b"\x08"
        termios.tcsetattr(slave, termios.TCSANOW, original)
        caller = None
        terminal = None
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
            env = {**os.environ, "HOME": str(home), "TERM": "xterm-256color"}
            env.pop("TMUX", None)
            if tmux:
                env["TMUX"] = "/tmp/tmux-renderer/default,1,0"
            if ready_write is not None:
                env["RUI_TEST_ACTION_READY_FD"] = str(ready_write)
            arguments = (["session", "resume", "--store", str(store), "--", session] if initial_text is None else
                ["--store", str(store), "--provider", "codex", "--model", "model-a", "--", initial_text])
            caller = subprocess.Popen([str(fixture.RUI), *arguments],
                cwd=workspace, env=env, pass_fds=(() if ready_write is None else (ready_write,)),
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            terminal = Terminal(master, slave, caller)
            if opening:
                terminal.wait(predicate=lambda: terminal.capture.draft("", 2))
            yield terminal
            assert caller.poll() is not None, "case did not retire its renderer"
            actual, expected = termios.tcgetattr(slave), list(original)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                expected[3] &= ~mask
            assert actual == expected, ("renderer termios restoration", expected, actual)
            from terminal_restoration_integration import assert_file_flags
            assert_file_flags(fcntl.fcntl(slave, fcntl.F_GETFL), original_flags)
        finally:
            if sys.exception() is not None:
                preserve_failure_metadata(state / "screen-failure.json", lambda: {
                    "session": session, "screen": terminal.capture.completed if terminal else None,
                    "cursor": repr(terminal.capture.screen.cursor) if terminal else None,
                    "returncode": caller.poll() if caller else None,
                    "stderr": caller.stderr.read().decode(errors="replace") if caller and caller.poll() is not None else None})
            dispose_all(
                lambda: stop_process(caller, timeout=5) if caller is not None else None,
                lambda: termios.tcflush(slave, termios.TCIFLUSH),
                lambda: termios.tcsetattr(slave, termios.TCSANOW, original),
                lambda: os.close(master), lambda: os.close(slave))

    def configure(session, permission="bypass"):
        run(home, "session", "configure", "--store", store, "--session", session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a", "--permission-mode", permission)

    def answer(index):
        marker = f"renderer answer {index}"
        endpoint.responses.append(fixture.sse_answer(f"renderer-{index}", f"reason-{index}", f"message-{index}", marker)[0])
        return marker

    def submitted(text):
        body = json.loads(endpoint.requests[-1])
        actual = next(item["content"][0]["text"] for item in reversed(body["input"]) if item.get("role") == "user")
        assert actual.encode() == text.encode(), ("renderer changed submitted bytes", actual, text)

    def joined(tty):
        # A final answer frame is not proof that its reader has joined.
        tty.send("/status\n", "Session: ")
        tty.send("\x07", predicate=lambda: tty.capture.draft("", 2))

    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        configure("renderer/geometry")
        codex_fixture.credentials(home / ".config/rui/codex.json")
        initial = "\u0301literal initial prompt\u200d"
        marker = answer("initial")
        with terminal("initial prompt", initial_text=initial, opening=False) as tty:
            tty.wait(marker)
            submitted(initial)
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: initial zero-width prompt bypasses composer and reaches provider unchanged", flush=True)
        with terminal("renderer/geometry") as tty:
            tty.send("kept\x01", predicate=lambda: tty.capture.draft("kept", 2))
            tty.send("\x1b[200~\u0301discarded\x1b[201~", "! Input rejected")
            assert tty.capture.draft("kept", 2), tty.capture.completed
            # An identical frame writes nothing: clear the notice with an
            # edit and its undo before the next rejection.
            tty.send("x", predicate=lambda: tty.capture.draft("xkept", 3))
            tty.send("\x7f", predicate=lambda: tty.capture.draft("kept", 2) and "! Input rejected" not in tty.capture.completed)
            tty.send("\x1b[200~prefix\n\u0301discarded\x1b[201~", "! Input rejected")
            assert tty.capture.draft("kept", 2), tty.capture.completed
            # Rejection leaves a usable editor, not a latent fatal redraw.
            tty.send("é", predicate=lambda: tty.capture.draft("ékept", 3))
            assert os.write(tty.master, b"\x15\x0b/exit\n") == 8
            tty.finish()
        env = {**os.environ, "HOME": str(home)}
        rejected = subprocess.run([str(fixture.RUI), "session", "resume", "--store", str(store), "renderer/geometry"],
            env=env, input=b"", capture_output=True, timeout=5)
        assert rejected.returncode != 0 and b"InteractiveTerminalRequired" in rejected.stderr, rejected
        assert b"\x1b" not in rejected.stdout + rejected.stderr, rejected
        pipe_text = "/literal\nstdin café\n"
        pipe_answer = answer("pipe")
        piped = subprocess.run([str(fixture.RUI), "session", "send", "--store", str(store), "--session", "renderer/geometry", "-"],
            cwd=workspace, env=env, input=pipe_text.encode(), capture_output=True, timeout=10)
        assert piped.returncode == 0 and json.loads(piped.stdout)["answer"]["status"] == "accepted", piped
        assert b"\x1b" not in piped.stdout + piped.stderr, piped
        piped_key = json.loads(piped.stdout)["context"]["key"]
        fixture.wait_for(lambda: fixture.completed_observation(store, piped_key), "piped renderer answer")
        assert fixture.read_result(store, piped_key) == pipe_answer.encode()
        submitted(pipe_text)
        print("renderer: non-TTY rejection and literal multiline pipe output retain their existing contracts", flush=True)
        with terminal("renderer/geometry") as tty:
            # Keep the historical native Mac OOM sequence exactly: wide5000X
            # at 24x2048, shrink to 24x80, then a + 2048 combining acutes.
            tty.resize(2048)
            marker = answer("wide")
            tty.send("X" * 5000 + "\n", marker)
            submitted("X" * 5000)
            joined(tty)
            tty.resize(80)
            for index, (draft, caret) in enumerate((("a" + "\u0301" * 2048, 3),
                    ("A中e\u0301\tB", 8), ("e" + "\u0301" * 1024, 3))):
                before = len(endpoint.requests)
                records = set((home / ".config/rui/requests").glob("*.json"))
                # A draft tab shows as one cell; the submitted bytes keep it.
                drawn = "A中é B" if index == 1 else draft
                tty.send("\x1b[200~" + draft + "\x1b[201~", predicate=lambda: tty.capture.draft(drawn, caret))
                assert len(endpoint.requests) == before and set((home / ".config/rui/requests").glob("*.json")) == records
                marker = answer(index)
                tty.send("\n", marker)
                submitted(draft)
                joined(tty)
            multiline = "first café\nsecond 中"
            before = len(endpoint.requests)
            # Continuation rows align under the draft without a second glyph.
            tty.send("\x1b[200~" + multiline + "\x1b[201~", "  second 中")
            screen = tty.capture.screen
            assert screen.display[screen.cursor.y - 1].rstrip() == "› first café"
            assert screen.display[screen.cursor.y].rstrip() == "  second 中" and screen.cursor.x == 11
            assert len(endpoint.requests) == before
            tty.send("\n", answer("multiline"))
            submitted(multiline)
            joined(tty)
            os.write(tty.master, b"/exit\n")
            tty.finish()
        print("renderer: wide5000X resize, long combining cells, tabs, multiline paste and exact submitted bytes passed", flush=True)

        records = set((home / ".config/rui/requests").glob("*.json"))
        for initial in (True, False):
            with terminal("renderer/geometry", columns=480 if initial else 80,
                    rows=135 if initial else 24, opening=not initial) as tty:
                if not initial:
                    tty.resize(480, 135)
                _, errors = tty.finish(expected=1)
                for marker in (b"49,152", b"Shrink the terminal"):
                    assert marker in errors, errors
                assert b"OutOfMemory" not in errors, errors
                assert set((home / ".config/rui/requests").glob("*.json")) == records
        print("renderer: initial oversize and excessive resize give typed actionable guidance and restore exactly", flush=True)

        # Ctrl-R recovers in each encoding a terminal sends it: raw, Kitty and
        # xterm modifyOtherKeys.
        for name, recover in (("raw", "\x12"), ("kitty", "\x1b[114;5u"), ("xterm", "\x1b[27;5;114~")):
            session = f"renderer/recovery-{name}"
            configure(session)
            marker = answer(f"recovery {name}")
            proxy = canonical.ReplyProxy(host, "/v1/message", lambda response: b"" if len(proxy.exchanges) == 1 else response)
            with terminal(session) as tty:
                before = len(endpoint.requests)
                tty.send("original é\n", "Not confirmed")
                saved = proxy.exchanges[0][0]
                # A pasted Ctrl-R byte is rejected text, never recovery.
                tty.send("\x1b[200~\x12\x1b[201~\r", "Input rejected; nothing sent")
                assert len(proxy.exchanges) == 1 and tty.capture.draft("", 2), tty.capture.completed
                tty.send("next café!\x1b[D\x1b[DX", predicate=lambda: tty.capture.draft("next cafXé!", 11))
                generation = tty.capture.generation
                tty.resize(40, 12)
                tty.wait(predicate=lambda: tty.capture.draft("next cafXé!", 11), after=generation)
                tty.send(recover, "Original confirmed")
                assert len(proxy.exchanges) == 2 and proxy.exchanges[1][0] == saved
                assert json.loads(saved)["text"]["value"] == "original é"
                fixture.wait_for(lambda: len(endpoint.requests) == before + 1, "original renderer request")
                submitted("original é")
                assert tty.capture.draft("next cafXé!", 11), tty.capture.completed
                marker = answer(f"retained {name}")
                tty.send("Y\n", marker)
                submitted("next cafXYé!")
                tty.resize(80)
                joined(tty)
                tty.caller.send_signal(signal.SIGTERM)
                tty.finish()
            proxy.close()
            proxy = None
        print("renderer: lost admission exact replay on raw, Kitty and modifyOtherKeys Ctrl-R, retained draft/caret and SIGTERM restoration passed", flush=True)

        configure("renderer/invisible")
        invisible = "\u00ad\u200b\u2060\ufeff\n\u200b\u0301\njoined e\u0301"
        arguments = json.dumps({"cmd": "printf '\\302\\255\\342\\200\\213\\342\\201\\240\\357\\273\\277\\n\\342\\200\\213\\314\\201\\njoined e\\314\\201'", "description": "Invisible output", "timeout_ms": None})
        endpoint.responses.append(fixture.sse_tool_calls("renderer-invisible", [("bash", "renderer-invisible-call", arguments)]))
        endpoint.responses.append(fixture.sse_answer("invisible-answer", "invisible-reason", "invisible-message", invisible + "\noutput survived")[0])
        escaped = ("\\u{ad}", "\\u{200b}", "\\u{2060}", "\\u{feff}", "\\u{301}")
        with terminal("renderer/invisible") as tty:
            shown = tty.send("show invisible output\n", "output survived")
            assert all(value in shown for value in escaped), shown
            joined(tty)
            shown = tty.send("/details\n", "joined é")
            # Both the saved Tool Result and answer use the same display sink.
            assert all(value in shown for value in escaped), shown
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        with terminal("renderer/invisible") as tty:
            shown = tty.wait("output survived")
            assert all(value in shown for value in escaped), shown
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: invisible answer and tool output escaped; saved conversation reopens", flush=True)

        configure("renderer/consent", "ask")
        proxy = canonical.ReplyProxy(host, "/v1/control/permission-decision", lambda response: response)
        command = "\n".join(f"# exact command line {index}" for index in range(100)) + "\nprintf approved > renderer-effect"
        arguments = json.dumps({"cmd": command, "description": "Renderer consent", "timeout_ms": None})
        release = threading.Event()
        endpoint.responses.append((fixture.sse_tool_calls("renderer-call", [("bash", "renderer-action", arguments)]), release))
        marker = answer("consent")
        ready_read, ready_write = os.pipe()
        try:
            with terminal("renderer/consent", ready_write) as tty:
                tty.send("propose renderer action\n\x1b[200~a\x1b[201~", predicate=lambda: tty.capture.draft("a", 3))
                release.set()
                opened = shown = tty.wait("Action continues · PgDn")
                assert "printf approved > renderer-effect" not in shown, shown
                records = set((home / ".config/rui/requests").glob("*.json"))
                # An unread Action takes choice text but never opens a fresh
                # choice: readiness waits for its last row.
                tty.send("/help\n", "Enter sends")
                assert "Enter sends" in tty.capture.completed, tty.capture.completed
                tty.send("\x07", "Action continues · PgDn")
                tty.send("a\n", "Read the whole Action first")
                assert not (workspace / "renderer-effect").exists(), "unseen Action tail was approved"
                tty.send("a", predicate=lambda: tty.capture.draft("a", 3, prompt="> "))
                for _ in range(8):
                    tty.send("\x1b[6~" * 6, predicate=lambda: "Action read" in tty.capture.completed or "Action continues" in tty.capture.completed)
                    if "Action read" in tty.capture.completed:
                        break
                else:
                    raise AssertionError("complete Action never became ready after paging")
                tty.ready(ready_read)
                shown = tty.wait("Type a + Enter to allow once · d + Enter to deny")
                assert tty.capture.draft("", 2, prompt="> "), "unread choice text survived readiness"
                tty.send("\n", "Type a + Enter to allow once · d + Enter to deny")
                # The empty Enter rejects the choice, which becomes fresh again.
                tty.ready(ready_read)
                assert "printf approved > renderer-effect" in shown, shown
                # Paging hid the Action's heading, so the choice keeps where it
                # runs beside it; the opening frame showed that heading instead.
                assert "? Run Bash" not in shown and "Run Bash · Renderer consent\nWorkspace:" in shown, shown
                kept = shown.split("Run Bash · Renderer consent\nWorkspace:", 1)[1].split("Type a + Enter", 1)[0]
                assert "".join(kept.split()) == str(workspace) + "·Timelimit:Hostdefault", shown
                assert "\nRun Bash · Renderer consent\nWorkspace:" not in opened, opened
                # The header leads the Action: where and how long, then the command.
                assert "? Run Bash · Renderer consent" in opened, opened
                shown_workspace = opened.split("\n  Workspace:", 1)[1].split("\n  Time limit:", 1)[0]
                assert "\n" in shown_workspace, "Workspace wrap witness did not wrap"
                assert shown_workspace.replace("\n", "").replace(" ", "") == str(workspace), opened
                assert "\n  Time limit: Host default\n  $ # exact command line 0\n    # exact command line 1\n" in opened, opened
                assert set((home / ".config/rui/requests").glob("*.json")) == records, "early a survived until approval readiness"
                current = fixture.command("session", "inspect", "--store", store, "--session", "renderer/consent")
                action = current["actionable_permissions"][0]["action"]
                exact = json.loads(run(home, "action", "inspect", "--store", store, "--session", "renderer/consent", "--action", action))
                assert exact["arguments"] == arguments
                assert not (workspace / "renderer-effect").exists()
                tty.send("\x1b[200~a\x1b[201~\n", "Type a + Enter to allow once · d + Enter to deny")
                tty.ready(ready_read)
                assert set((home / ".config/rui/requests").glob("*.json")) == records
                assert not (workspace / "renderer-effect").exists(), "pasted consent authorized an Action"
                # Beside a ready Action, Ctrl-R in any encoding is choice
                # input: it rejects the choice, recovering and deciding nothing.
                for recover in ("\x12", "\x1b[114;5u", "\x1b[27;5;114~"):
                    tty.send("a", predicate=lambda: tty.capture.draft("a", 3, prompt="> "))
                    tty.send(recover + "\n", "Decision input rejected")
                    tty.ready(ready_read)
                    assert set((home / ".config/rui/requests").glob("*.json")) == records and not proxy.exchanges
                    assert not (workspace / "renderer-effect").exists(), "Ctrl-R at the choice authorized an Action"
                # A complete non-pasted line, not its first byte, authorizes.
                tty.send("a", "Type a + Enter to allow once · d + Enter to deny")
                assert not (workspace / "renderer-effect").exists()
                tty.send("\n", marker)
                assert (workspace / "renderer-effect").read_bytes() == b"approved"
                decisions = [json.loads(path.read_text()) for path in set((home / ".config/rui/requests").glob("*.json")) - records]
                assert len(decisions) == 1 and decisions[0]["action"] == action and decisions[0]["decision"] == "allow_once", decisions
                assert len(proxy.exchanges) == 1, "consent transmitted more than one decision"
                body, response = proxy.exchanges[0]
                assert json.loads(body)["action"] == action and json.loads(body)["decision"] == "allow_once"
                assert json.loads(response.split(b"\r\n\r\n", 1)[1])["answer"]["status"] == "accepted"
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            dispose_all(release.set, lambda: os.close(ready_read), lambda: os.close(ready_write))
        print("renderer: fresh complete non-pasted exact Action consent and SIGINT restoration passed", flush=True)

        proxy.close()
        proxy = None
        configure("renderer/oversized", "ask")
        command = "#" + "x" * (256 * 1024) + "\nprintf forbidden > renderer-oversized-effect"
        arguments = json.dumps({"cmd": command, "description": "Oversized proposal", "timeout_ms": None})
        endpoint.responses.append(fixture.sse_tool_calls("renderer-oversized", [("bash", "renderer-oversized-call", arguments)]))
        with terminal("renderer/oversized") as tty:
            tty.send("propose oversized action\n", "Approval disabled")
            current = fixture.command("session", "inspect", "--store", store, "--session", "renderer/oversized")
            action = current["actionable_permissions"][0]["action"]
            records = set((home / ".config/rui/requests").glob("*.json"))
            # A typed decision stays a draft, and the notice names the only way to decide.
            tty.send("a\n", predicate=lambda: "! Approval disabled · /help for exact shell commands. Draft retained." in tty.capture.completed and tty.capture.draft("a", 3))
            tty.caller.send_signal(signal.SIGINT)
            detached = tty.finish()[0].decode()
            for name in ("inspect", "allow", "deny"):
                assert f"rui action {name} --store $'{store}' --session $'renderer/oversized' --action {action}" in detached, detached
            assert set((home / ".config/rui/requests").glob("*.json")) == records
            assert not (workspace / "renderer-oversized-effect").exists()
        print("renderer: oversized Action cannot approve; exact shell commands survive alternate-screen exit", flush=True)

        # Another client decides: the choice must leave on its own, with the
        # outcome and answer shown, never an Action that still looks pending.
        for decision in ("allow", "deny"):
            session = f"renderer/elsewhere-{decision}"
            configure(session, "ask")
            effect = workspace / f"renderer-elsewhere-{decision}"
            arguments = json.dumps({"cmd": f"printf decided > {effect.name}", "description": "Decided elsewhere", "timeout_ms": None})
            endpoint.responses.append(fixture.sse_tool_calls(f"renderer-elsewhere-{decision}", [("bash", f"elsewhere-{decision}-call", arguments)]))
            marker = answer(f"elsewhere {decision}")
            with terminal(session) as tty:
                tty.send("propose an Action decided elsewhere\n", "Type a + Enter to allow once · d + Enter to deny")
                action = fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"][0]["action"]
                # A line begun at the choice ends there (#540): `/` typed
                # before the decision and `status` + Enter after it open
                # /status, and never send `status` as a Message.
                tty.send("/", predicate=lambda: tty.capture.draft("/", 3, prompt="> "))
                generation = tty.capture.generation
                run(home, "action", decision, "--store", store, "--session", session, "--action", action)
                shown = tty.wait(marker, after=generation)
                for pending in ("Type a + Enter", "PgDn reads", "? Run Bash"):
                    assert pending not in shown, (decision, shown)
                assert effect.exists() == (decision == "allow"), decision
                requests = len(endpoint.requests)
                shown = tty.send("status\r", predicate=lambda: "Session: " in tty.capture.completed or "› status" in tty.capture.completed)
                assert "Session: " in shown and "› status" not in shown, (decision, shown)
                assert len(endpoint.requests) == requests, endpoint.requests
                tty.send("\x07", predicate=lambda: tty.capture.draft("", 2))
                # Paging and a /status round trip cannot bring the choice back.
                tty.send("\x1b[6~/status\n", "Session: ")
                tty.send("\x07", predicate=lambda: tty.capture.draft("", 2))
                assert "Type a + Enter" not in tty.capture.completed and "Approval" not in tty.capture.completed, tty.capture.completed
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        print("renderer: an Action decided by another client leaves the choice and shows its outcome without a key; a line begun there stays there", flush=True)

        # A line begun at one choice never decides the next (#540): `/` at the
        # first of two Actions, decided elsewhere, then `a` + Enter is the
        # command `/a`. The second Action waits for that Enter and is decided
        # only by its own fresh line.
        session = "renderer/elsewhere-successor"
        configure(session, "ask")
        endpoint.responses.append(fixture.sse_tool_calls("renderer-successor", [
            ("bash", f"successor-{index}", json.dumps({"cmd": f"printf decided > renderer-successor-{index}", "description": f"Successor {index}", "timeout_ms": None}))
            for index in (1, 2)]))
        marker = answer("successor")
        ready_read, ready_write = os.pipe()
        try:
            with terminal(session, ready_write) as tty:
                tty.send("propose two Actions\n", "Type a + Enter to allow once · d + Enter to deny")
                tty.ready(ready_read)
                first, second = [item["action"] for item in fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"]]
                tty.send("/", predicate=lambda: tty.capture.draft("/", 3, prompt="> "))
                generation = tty.capture.generation
                run(home, "action", "deny", "--store", store, "--session", session, "--action", first)
                tty.wait("Successor 1 — Denied", after=generation)
                # The other client saved its own record in this HOME.
                records = set((home / ".config/rui/requests").glob("*.json"))
                # Give the second Action the time it would take to be shown
                # and ready; it must wait for the open line instead.
                select.select([ready_read], [], [], 2)
                tty.send("a\r", "! Unknown command /a · /help")
                tty.ready(ready_read)
                assert [item["action"] for item in fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"]] == [second]
                assert set((home / ".config/rui/requests").glob("*.json")) == records
                tty.send("d\r", marker)
                decisions = [json.loads(path.read_text()) for path in set((home / ".config/rui/requests").glob("*.json")) - records]
                assert [(item["action"], item["decision"]) for item in decisions] == [(second, "deny")], decisions
                assert not any((workspace / f"renderer-successor-{index}").exists() for index in (1, 2))
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            dispose_all(lambda: os.close(ready_read), lambda: os.close(ready_write))
        print("renderer: a line begun at one choice never decides the next Action", flush=True)

        # A sequence the choice is decoding finishes there (#540): a /status
        # page whose read joins between the two bytes of é waits for the
        # second, so é stays the choice's line and is never sent.
        session = "renderer/elsewhere-fragment"
        configure(session, "ask")
        endpoint.responses.append(fixture.sse_tool_calls("renderer-fragment", [
            ("bash", "fragment-call", json.dumps({"cmd": "printf never > renderer-fragment-effect", "description": "Fragment action", "timeout_ms": None}))]))
        marker = answer("fragment")
        held, released, reads = (threading.Event(), threading.Event()), (threading.Event(), threading.Event()), []
        def hold_two_reads(_):
            if len(reads) < 2:
                reads.append(len(reads))
                held[len(reads) - 1].set()
                assert released[len(reads) - 1].wait(10)
            return True
        ready_read, ready_write = os.pipe()
        try:
            with terminal(session, ready_write) as tty:
                tty.send("propose a fragment Action\n", "Type a + Enter to allow once · d + Enter to deny")
                tty.ready(ready_read)
                action = fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"][0]["action"]
                proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_two_reads)
                assert held[0].wait(5), "first held Activity page"
                # The held read predates /status, so the next one opens it.
                os.write(tty.master, b"/status\r")
                time.sleep(0.1)
                released[0].set()
                assert held[1].wait(5), "/status Activity page"
                os.write(tty.master, b"\xc3")
                time.sleep(0.1)
                released[1].set()
                # Long enough for the /status read to join; the page waits.
                time.sleep(0.5)
                os.write(tty.master, b"\xa9")
                tty.wait("Session: ")
                generation = tty.capture.generation
                run(home, "action", "deny", "--store", store, "--session", session, "--action", action)
                tty.wait(predicate=lambda: "Work: completed" in tty.capture.completed, after=generation, timeout=20)
                requests = len(endpoint.requests)
                tty.send("\x07", marker)
                assert tty.capture.draft("", 2, prompt="> "), tty.capture.completed
                tty.send("\r", predicate=lambda: tty.capture.draft("", 2))
                assert len(endpoint.requests) == requests, endpoint.requests
                assert "› é" not in tty.capture.completed, tty.capture.completed
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            dispose_all(*(event.set for event in released), lambda: os.close(ready_read), lambda: os.close(ready_write))
        proxy.close()
        proxy = None
        print("renderer: a page opening mid-sequence at the choice keeps that sequence there", flush=True)

        # Reading a tall Action to its end clears earlier choice text, but a
        # slash command begun while reading stays a command (#540): `/`, the
        # final page, then `a` + Enter runs `/a` and authorizes nothing.
        session = "renderer/reading-command"
        configure(session, "ask")
        command = "\n".join(f"# reading line {index}" for index in range(100)) + "\nprintf allowed > renderer-reading-effect"
        endpoint.responses.append(fixture.sse_tool_calls("renderer-reading", [
            ("bash", "reading-call", json.dumps({"cmd": command, "description": "Reading command", "timeout_ms": None}))]))
        marker = answer("reading")
        ready_read, ready_write = os.pipe()
        try:
            with terminal(session, ready_write) as tty:
                # An unread Action draws no decision prompt, so no readiness.
                tty.send("propose a tall Action\n", "Action continues · PgDn")
                tty.send("/", predicate=lambda: tty.capture.draft("/", 3, prompt="> "))
                for _ in range(8):
                    tty.send("\x1b[6~" * 6, predicate=lambda: "Action read" in tty.capture.completed or "Action continues" in tty.capture.completed)
                    if "Action read" in tty.capture.completed:
                        break
                else:
                    raise AssertionError("tall Action never became ready after paging")
                tty.ready(ready_read)
                tty.wait("Type a + Enter to allow once · d + Enter to deny")
                assert tty.capture.draft("/", 3, prompt="> "), tty.capture.completed
                records = set((home / ".config/rui/requests").glob("*.json"))
                tty.send("a\r", "! Unknown command /a · /help")
                tty.ready(ready_read)
                assert set((home / ".config/rui/requests").glob("*.json")) == records
                tty.send("d\r", marker)
                assert not (workspace / "renderer-reading-effect").exists()
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            dispose_all(lambda: os.close(ready_read), lambda: os.close(ready_write))
        print("renderer: a slash command begun while reading a tall Action stays a command", flush=True)

        # Delivered history and the live footer describe one capture: no
        # committed frame shows a call twice, or both pending and finished.
        session = "renderer/one-capture"
        configure(session)
        labels = ("List project files", "Fail with exit 127", "Fail with an excerpt")
        commands = ("sleep 0.2; ls", "sleep 0.2; exit 127", "sleep 0.2; echo excerpt >&2; exit 1")
        endpoint.responses.append(fixture.sse_tool_calls("renderer-one-capture", [
            ("bash", f"one-capture-{index}", json.dumps({"cmd": command, "description": label, "timeout_ms": None}))
            for index, (command, label) in enumerate(zip(commands, labels))]))
        marker = answer("one capture")
        with terminal(session) as tty:
            frames = tty.every_frame()
            tty.send("run the tool demonstration\n", marker)
            assert any("Working" in frame for frame in frames), frames
            for frame in frames:
                for label in labels:
                    assert frame.count(label) <= 1, (label, frame)
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: delivered history and the live footer never show one call twice", flush=True)

        # An open /status page follows Current: once the work ends, the page
        # says so without another /status.
        session = "renderer/status-follows"
        configure(session)
        endpoint.responses.append(fixture.sse_tool_calls("renderer-status-follows", [
            ("bash", "status-follows-call", json.dumps({"cmd": "sleep 1.5", "description": "Wait briefly", "timeout_ms": None}))]))
        marker = answer("status follows")
        with terminal(session) as tty:
            tty.send("wait briefly\n", "• Wait briefly")
            shown = tty.send("/status\n", "Session: ")
            assert "Work: in_flight" in shown or "Work: runnable" in shown, shown
            shown = tty.wait(predicate=lambda: "Work: completed" in tty.capture.completed, timeout=20)
            assert "Session: " in shown and "Permission: bypass" in shown, shown
            tty.send("\x07", marker)
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: an open /status page follows the work it describes", flush=True)

        # From Enter on, every frame shows the Message: sending, or submitted
        # in full. A cleared composer alone or a bare submitted marker is not
        # feedback.
        session = "renderer/submitted-feedback"
        configure(session)
        marker = answer("submitted feedback")
        with terminal(session) as tty:
            tty.send("x", predicate=lambda: tty.capture.draft("x", 3))
            frames = tty.every_frame()
            sent = time.time()
            tty.send("\n", marker)
            # The time is the Host's admission second, in this local zone.
            times = {time.strftime("%H:%M", time.localtime(second)) for second in range(int(sent), int(time.time()) + 1)}
            for frame in frames:
                rows = frame.rstrip("\n").split("\n")
                composer = max(index for index, row in enumerate(rows) if row.startswith("›"))
                history = rows[:composer]
                assert "›" not in [row.strip() for row in history], frame
                for row in history:
                    if untimed(row) == "› x":
                        assert len(row) == 80 and row[-5:] in times, (row, times)
                if rows[composer].strip() == "›":
                    assert "› x" in map(untimed, history) or {"Sending…", "Sent"} & set(history), frame
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: a submitted Message shows as sending or in full from Enter on", flush=True)

        def feedback(frames, text):
            for frame in frames:
                rows = frame.rstrip("\n").split("\n")
                composer = max(index for index, row in enumerate(rows) if row.startswith("›"))
                history = rows[:composer]
                if rows[composer].strip() == "›":
                    assert f"› {text}" in map(untimed, history) or {"Sending…", "Sent"} & set(history), (text, frame)

        def held_pages():
            """Once holding is set, Activity page requests reach the Host only
            after release, so the page then read holds everything until then."""
            holding, release = threading.Event(), threading.Event()
            def hold(_):
                if holding.is_set():
                    release.wait(10)
                return True
            return holding, release, hold

        # Sent belongs to the accepted Message, not to whichever read joins
        # next: a read that predates a second Message cannot clear it.
        session = "renderer/sent-identity"
        configure(session)
        markers = (answer("sent first"), answer("sent second"))
        gates = {text: threading.Event() for text in (b"AAA", b"BBB")}
        holding = {text: threading.Event() for text in gates}
        def hold_content(response):
            for text, gate in gates.items():
                if text in response and not holding[text].is_set():
                    holding[text].set()
                    gate.wait(10)
            return response
        proxy = canonical.ReplyProxy(host, "/v1/activity-content", hold_content)
        with terminal(session) as tty:
            os.write(tty.master, b"AAA\n")
            assert holding[b"AAA"].wait(10), tty.capture.completed
            frames = tty.every_frame()
            sent = len(proxy.mutations)
            def accepted():
                rows = tty.capture.completed.rstrip("\n").split("\n")
                return len(proxy.mutations) > sent and rows[-1].strip() == "›" and "Sending…" not in rows
            tty.send("BBB\n", predicate=accepted)
            gates[b"AAA"].set()
            tty.wait(predicate=lambda: holding[b"BBB"].is_set() and "› AAA" in tty.capture.completed)
            gates[b"BBB"].set()
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "both Messages answered", timeout=20)
            # BBB may join the first Turn; then its own answer is never asked for.
            unused = [response for response in endpoint.responses if markers[1].encode() in response]
            for response in unused:
                endpoint.responses.remove(response)
            tty.wait(markers[0] if unused else markers[1])
            feedback(frames, "BBB")
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: Sent stays with each accepted Message until a delivered page holds it", flush=True)

        # A catch-up page that ends before the accepted Message is not its
        # delivery: Sent stays through every page until one holds it.
        session = "renderer/sent-catch-up"
        configure(session)
        holding, release, hold_page = held_pages()
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_page)
        with terminal(session) as tty:
            holding.set()
            for index in range(10):
                answer(f"backlog {index}")
                key = admit(home, "session", "send", "--store", store, "--session", session, f"backlog {index}")["request"]
                fixture.wait_for(lambda: fixture.completed_observation(store, key), "backlog answer", timeout=20)
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "backlog settled", timeout=20)
            marker = answer("caught up")
            frames = tty.every_frame()
            tty.send("CCC\n", predicate=lambda: "Sent" in tty.capture.completed)
            release.set()
            tty.wait(marker, timeout=20)
            feedback(frames, "CCC")
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: Sent stays through catch-up pages that end before the Message", flush=True)

        # An open /status page reloads when anything it reports changes, not
        # only the first Action: deciding a later one elsewhere updates it.
        session = "renderer/status-attention"
        configure(session, "ask")
        endpoint.responses.append(fixture.sse_tool_calls("renderer-status-attention", [
            ("bash", f"status-attention-{index}", json.dumps({"cmd": f"printf {index}", "description": f"Attention {index}", "timeout_ms": None}))
            for index in range(3)]))
        with terminal(session) as tty:
            tty.send("propose three Actions\n", "Type a + Enter to allow once · d + Enter to deny")
            actions = [row["action"] for row in fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"]]
            assert len(actions) == 3, actions
            shown = tty.send("/status\n", "Session: ")
            for action in actions:
                assert f"Action requiring attention: {action}" in shown, shown
            # The update replaces the page in place: what the user scrolled
            # to and was told stays, and nothing returns to the top.
            tty.resize(80, 12)
            tty.wait(predicate=lambda: f"Action requiring attention: {actions[0]}" not in tty.capture.completed or "Session: " not in tty.capture.completed)
            # Line by line, so the last Action lands on the bottom row however
            # many rows the Store path wraps to.
            for _ in range(40):
                if f"Action requiring attention: {actions[2]}" in tty.capture.completed:
                    break
                tty.send("\x1b[1;2B", predicate=lambda: True)
            scrolled = tty.capture.completed
            assert "Session: " not in scrolled and f"Action requiring attention: {actions[0]}" in scrolled, scrolled
            tty.send("/foo\n", "! Unknown command /foo · /help")
            frames = tty.every_frame()
            run(home, "action", "deny", "--store", store, "--session", session, "--action", actions[1])
            def updated():
                screen = tty.capture.completed
                return (f"Action requiring attention: {actions[1]}" not in screen and
                        f"Action requiring attention: {actions[0]}" in screen and f"Action requiring attention: {actions[2]}" in screen)
            tty.wait(predicate=updated, timeout=10)
            for frame in frames:
                assert "Session: " not in frame and "! Unknown command /foo · /help" in frame, frame
            # A command typed at the choice while another runs waits for it,
            # rather than queueing behind it or replacing its page.
            reading, release_read = threading.Event(), threading.Event()
            missing = b"00000000-0000-4000-8000-000000000000"
            def hold_read(body):
                if missing not in body:
                    return True
                reading.set()
                return release_read.wait(10)
            proxy = canonical.ReplyProxy(host, "/v1/observe-command", lambda response: response, before_forward=hold_read)
            # Nothing redraws while the command is held: wait for the hold.
            os.write(tty.master, b"/result " + missing + b"\n")
            assert reading.wait(10), tty.capture.completed
            tty.send("/requests\n", "! Command still running. Try again when it finishes.")
            release_read.set()
            tty.wait(predicate=lambda: "Command still running" not in tty.capture.completed, timeout=10)
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: an open /status page updates in place and a choice command waits for a running one", flush=True)

        # A page that spans several output windows still commits as one
        # capture: a running call never vanishes between footer and history.
        session = "renderer/whole-page"
        configure(session)
        label = "Wait one second"
        endpoint.responses.append(fixture.sse_tool_calls("renderer-whole-page", [
            ("bash", "whole-page-call", json.dumps({"cmd": "sleep 1", "description": label, "timeout_ms": None}))]))
        after_call = answer("whole page call")
        queued = answer("whole page queued")
        holding, release, hold_page = held_pages()
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_page)
        with terminal(session) as tty:
            tty.send("wait one second\n", f"• {label}")
            requests = len(endpoint.requests)
            holding.set()
            long_message = "\n".join(f"queued line {index:03} " + "m" * 80 for index in range(70))
            admit(home, "session", "send", "--store", store, "--session", session, long_message)
            fixture.wait_for(lambda: len(endpoint.requests) > requests, "call finished", timeout=20)
            frames = tty.every_frame()
            release.set()
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "queued Message answered", timeout=20)
            # The queued Message may join the call's Turn; then one answer covers both.
            unused = [response for response in endpoint.responses if queued.encode() in response]
            for response in unused:
                endpoint.responses.remove(response)
            final = after_call if unused else queued
            tty.wait(final, timeout=20)
            for frame in frames:
                if final in frame:
                    break
                assert label in frame, frame
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: a page spanning several windows commits with its footer as one capture", flush=True)

        # The composer status comes from the capture its history does: an
        # ended Turn's answer never sits beside Working….
        session = "renderer/status-capture"
        configure(session)
        endpoint.responses.append(fixture.sse_tool_calls("renderer-status-capture", [
            ("bash", "status-capture-call", json.dumps({"cmd": "sleep 1", "description": "Wait for the capture", "timeout_ms": None}))]))
        marker = answer("status capture")
        holding, release, hold_page = held_pages()
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_page)
        with terminal(session) as tty:
            tty.send("wait for the capture\n", "• Wait for the capture")
            frames = tty.every_frame()
            holding.set()
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "turn ended", timeout=20)
            release.set()
            tty.wait(marker, timeout=20)
            tty.wait(predicate=lambda: "Working…" not in tty.capture.completed, timeout=5)
            for frame in frames:
                assert not (marker in frame and "Working…" in frame), frame
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: the composer status and history come from one capture", flush=True)

        # /status opens from the capture the composer status shows: a Turn
        # that ended unseen never reads completed beside Working….
        session = "renderer/status-open"
        configure(session)
        endpoint.responses.append(fixture.sse_tool_calls("renderer-status-open", [
            ("bash", "status-open-call", json.dumps({"cmd": "sleep 1", "description": "Wait to open status", "timeout_ms": None}))]))
        marker = answer("status open")
        holding, release, hold_page = held_pages()
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_page)
        with terminal(session) as tty:
            tty.send("wait to open status\n", "• Wait to open status")
            holding.set()
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "turn ended", timeout=20)
            frames = tty.every_frame()
            os.write(tty.master, b"/status\n")
            time.sleep(1)
            release.set()
            tty.wait(predicate=lambda: "Work: completed" in tty.capture.completed, timeout=20)
            for frame in frames:
                assert not ("Session: " in frame and "Working…" in frame), frame
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: /status opens from the capture the composer status shows", flush=True)

        # A /status not yet shown yields to a later page request: the page
        # asked for last is the one that stays on screen, even when the read
        # that would show /status is already in flight.
        session = "renderer/status-yields"
        configure(session)
        marker = answer("status yields")
        holding = threading.Event()
        held = [threading.Event(), threading.Event()]
        released = [threading.Event(), threading.Event()]
        reads = []
        def hold_two(_):
            if holding.is_set() and len(reads) < 2:
                index = len(reads)
                reads.append(index)
                held[index].set()
                released[index].wait(10)
            return True
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_two)
        with terminal(session) as tty:
            tty.send("status yields\n", marker)
            frames = tty.every_frame()
            holding.set()
            assert held[0].wait(10)
            os.write(tty.master, b"/status\n")
            time.sleep(0.3)
            released[0].set()
            # The next read carries the /status request.
            assert held[1].wait(10)
            os.write(tty.master, b"/details\n")
            time.sleep(0.3)
            released[1].set()
            tty.wait("Recent conversation — tool details", timeout=20)
            time.sleep(1.5)
            assert "Recent conversation — tool details" in tty.capture.completed, tty.capture.completed
            for frame in frames:
                assert "Session: " not in frame, frame
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: a later /details replaces a /status not yet shown", flush=True)

        # A fresh Session's live page begins with an Admission row, which is
        # no conversation cursor: its start is the start of the conversation.
        session = "renderer/fresh-start"
        configure(session)
        marker = answer("fresh start")
        with terminal(session) as tty:
            tty.send("fresh start\n", marker)
            frames = tty.every_frame()
            tty.send("/history\n", "Start of conversation")
            for _ in range(3):
                os.write(tty.master, b"\x1b[5~")
                time.sleep(0.3)
            time.sleep(1)
            shown = tty.capture.completed
            assert shown.index("Start of conversation") < shown.index("› fresh start") < shown.index(marker), shown
            for frame in frames:
                assert "Earlier messages unavailable" not in frame, frame
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: a fresh Session scrolls to its start", flush=True)

        # While approval is paused the composer is the draft: what is typed
        # stays there, cannot decide, and returns after the decision.
        session = "renderer/paused-draft"
        configure(session, "ask")
        endpoint.responses.append(fixture.sse_tool_calls("renderer-paused", [
            ("bash", "paused-call", json.dumps({"cmd": "printf paused", "description": "Paused draft", "timeout_ms": None}))]))
        marker = answer("paused done")
        with terminal(session) as tty:
            tty.send("propose paused\n", "Type a + Enter to allow once · d + Enter to deny")
            tty.send("/details\n", "Approval paused · Esc returns to Action")
            tty.send("next draft", predicate=lambda: tty.capture.draft("next draft", 12))
            tty.send("\r", "! Action needs a decision; Esc returns to it. Draft retained.")
            assert tty.capture.draft("next draft", 12), tty.capture.completed
            assert fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"]
            # Ctrl-R in any encoding waits for the Action: the draft stays
            # whole, unrejected, and nothing is recovered or decided.
            records = set((home / ".config/rui/requests").glob("*.json"))
            draft = "next draft"
            for recover in ("\x12", "\x1b[114;5u", "\x1b[27;5;114~"):
                draft += "!"
                tty.send("!", predicate=lambda: tty.capture.draft(draft, len(draft) + 2))
                tty.send(recover, "! Action needs a decision; Esc returns to it. Draft retained.")
                assert tty.capture.draft(draft, len(draft) + 2), tty.capture.completed
            tty.send("?", predicate=lambda: tty.capture.draft(draft + "?", len(draft) + 3))
            tty.send("\r", "! Action needs a decision; Esc returns to it. Draft retained.")
            assert tty.capture.draft(draft + "?", len(draft) + 3), tty.capture.completed
            assert set((home / ".config/rui/requests").glob("*.json")) == records
            assert fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"]
            tty.send("\x1b", "Type a + Enter to allow once · d + Enter to deny")
            # Shift-Enter as Ghostty sends it (ESC CR) adds a line to the
            # choice, so a, then it, then Enter decides nothing.
            tty.send("a\x1b\r\r", "! Choose a or d. Nothing authorized.")
            assert fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"]
            tty.send("a\r", marker)
            tty.wait(predicate=lambda: tty.capture.draft(draft + "?", len(draft) + 3), timeout=10)
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: a draft typed while approval is paused stays and cannot decide", flush=True)

        # A Message accepted after its page and many later ones were shown is
        # already delivered: Sent never outlives it.
        session = "renderer/sent-late"
        configure(session)
        held, release_reply = threading.Event(), threading.Event()
        def hold_first(response):
            if not held.is_set():
                held.set()
                release_reply.wait(12)
            return response
        proxy = canonical.ReplyProxy(host, "/v1/message", hold_first)
        with terminal(session) as tty:
            answer("sent late")
            tty.send("DDD\n", predicate=lambda: held.is_set() and "Sending…" in tty.capture.completed)
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "held Message answered", timeout=20)
            for index in range(9):
                answer(f"later {index}")
                key = admit(home, "session", "send", "--store", store, "--session", session, f"later {index}")["request"]
                fixture.wait_for(lambda: fixture.completed_observation(store, key), "later answer", timeout=20)
            unused = [response for response in endpoint.responses if b"later " in response]
            for response in unused:
                endpoint.responses.remove(response)
            tty.wait("› later 8", timeout=20)
            release_reply.set()
            tty.wait(predicate=lambda: "Sending…" not in tty.capture.completed, timeout=10)
            time.sleep(1)
            tty.wait(predicate=lambda: "Sent" not in tty.capture.completed.rstrip("\n").split("\n")[-3:], timeout=5)
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: Sent never outlives a Message delivered before its acceptance joined", flush=True)

        # An unbound Alt chord, as Option-as-Meta or tmux sends it (ESC then
        # the key), never types its bare key, and the draft around it stays.
        session = "renderer/alt-chord"
        configure(session)
        with terminal(session) as tty:
            requests = len(endpoint.requests)
            tty.send("o\x1b.\x1b ", predicate=lambda: "! Key combination not recognized; ignored. Draft unchanged." in tty.capture.completed and tty.capture.draft("o", 3))
            tty.send("k", predicate=lambda: "! Key combination not recognized" not in tty.capture.completed and tty.capture.draft("ok", 4))
            # Shift-Enter as Ghostty sends it (ESC CR), and ESC LF, add a line.
            tty.send("\x1b\r", predicate=lambda: "! Key combination not recognized" not in tty.capture.completed and tty.capture.draft("", 2, prompt="  "))
            tty.send("\x1b\n2", predicate=lambda: tty.capture.draft("2", 3, prompt="  "))
            # A hand-typed Esc expires before Enter, which then sends.
            marker = answer("esc then enter")
            os.write(tty.master, b"\x1b")
            time.sleep(0.3)
            assert len(endpoint.requests) == requests, endpoint.requests
            tty.send("\r", marker)
            submitted("ok\n\n2")
            tty.send("ok", predicate=lambda: tty.capture.draft("ok", 4))
            marker = answer("alt chord")
            # Sent while browsing, the Message returns to the live view.
            tty.send("\x1b[A", "Browsing · Esc returns")
            tty.send("\r", marker)
            assert "Browsing · Esc returns" not in tty.capture.completed, tty.capture.completed
            assert "In tmux" not in tty.capture.completed, tty.capture.completed
            submitted("ok")
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: an unbound Alt chord is dropped as it arrives and the draft stays", flush=True)

        # With nothing said yet, scrolling up reaches the start, not a gap.
        # In tmux, Shift-Enter arrives as Enter: composing says how to add a line.
        session = "renderer/empty-tmux"
        configure(session)
        hint = "In tmux, Shift-Enter sends · Alt-J adds a line"
        with terminal(session, tmux=True) as tty:
            tty.send("\x1b[A", "Start of conversation")
            assert "Earlier rows left this view." not in tty.capture.completed, tty.capture.completed
            tty.send("x", predicate=lambda: hint in tty.capture.completed and tty.capture.draft("x", 3))
            tty.send("\x7f", predicate=lambda: hint not in tty.capture.completed and tty.capture.draft("", 2))
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: an empty Session scrolls to its start, and tmux composing names Alt-J", flush=True)

        # A page asked for just before a Message never opens over it: queued
        # behind a held scan, or (/details) already reading when it is sent.
        session = "renderer/stale-pages"
        configure(session)
        holding, release, held = threading.Event(), threading.Event(), threading.Event()
        def hold_page(_):
            if holding.is_set():
                held.set()
                release.wait(10)
            return True
        with terminal(session) as tty:
            tty.send("before pages\n", answer("stale before"))
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        # The first three queue behind a held scan; the last /details is
        # itself held reading the Conversation.
        for command, route in (("/status", "/v1/activity-page"), ("/details", "/v1/activity-page"),
                               ("/history", "/v1/activity-page"), ("/details", "/v1/conversation-page")):
            holding.clear()
            release.clear()
            held.clear()
            proxy = canonical.ReplyProxy(host, route, lambda response: response, before_forward=hold_page)
            with terminal(session) as tty:
                holding.set()
                if route == "/v1/activity-page":
                    assert held.wait(5), "no scan reached the held page"
                tty.send(command, predicate=lambda: tty.capture.draft(command, 2 + len(command)))
                tty.send("\r", predicate=lambda: tty.capture.draft("", 2))
                assert held.wait(5), (command, route, "the page was not held")
                marker = answer(f"stale {command} {route}")
                tty.send("after page\n", predicate=lambda: "Sending…" in tty.capture.completed or "Sent" in tty.capture.completed)
                release.set()
                tty.wait(marker, timeout=20)
                shown = tty.capture.completed
                assert marker in shown and "Browsing · Esc returns" not in shown and "Session: " not in shown, (command, route, shown)
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
            proxy.close()
            proxy = None
        print("renderer: a page asked for before a Message never opens over it", flush=True)

        # A Message's conversation row shows nothing live (its Admission did),
        # so a later read cannot begin a transcript before it. Once eviction
        # cuts the Admission, older pages still hold the Message, whether its
        # row arrives alone (held reply) or with the reply.
        # A long Message shows collapsed live, so the reply alone outgrows
        # the live view. Older pages show the Message by its size alone.
        reply = "\n".join(f"REPLY-{index:05d} " + "y" * 50 for index in range(4400))
        omitted = "› ┄ 59 KB"

        def after_message(shown, reply="REPLY-00000"):
            # What follows the Message: its reply live, the long reply's own
            # omission on an older page, or the seam where live rows left.
            markers = (reply, "Earlier rows left this view.") + (("Historical item omitted: position",) if reply == "REPLY-00000" else ())
            found = [shown.index(marker) for marker in markers if marker in shown]
            assert found, shown
            return min(found)

        for variant in ("alone", "with-reply"):
            session = f"renderer/evicted-message-{variant}"
            configure(session)
            provider_release = threading.Event()
            response = fixture.sse_answer(f"evicted-{variant}", "reason", "message", reply)[0]
            endpoint.responses.append((response, provider_release) if variant == "alone" else response)
            holding, release, held = threading.Event(), threading.Event(), threading.Event()
            proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_page)
            with terminal(session) as tty:
                requests = len(endpoint.requests)
                tty.send("\x1b[200~" + "m" * 59199 + "\x1b[201~\r", predicate=lambda: tty.capture.draft("", 2) and "m" * 40 in tty.capture.completed)
                if variant == "alone":
                    fixture.wait_for(lambda: len(endpoint.requests) > requests, "model request", timeout=20)
                    time.sleep(1)  # Scans see the conversation row before the reply.
                    provider_release.set()
                else:
                    holding.set()
                    fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "evicted Message answered", timeout=20)
                    release.set()
                tty.wait("REPLY-04399", timeout=30)
                tty.send("\x1b[A", "Browsing · Esc returns")
                # Each /history jumps to the transcript's top, where the
                # preceding page then loads.
                for _ in range(10):
                    tty.send("/history\n", predicate=lambda: "Loading earlier messages…" not in tty.capture.completed)
                    if "Start of conversation" in tty.capture.completed:
                        break
                shown = tty.capture.completed
                assert "Start of conversation" in shown, shown
                assert omitted in shown, (variant, shown)
                assert shown.index(omitted) < after_message(shown), (variant, shown)
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
            proxy.close()
            proxy = None
        print("renderer: an evicted Message stays in the transcript, alone or with its reply", flush=True)

        # Ctrl-O opens the lowest collapsed Message in view, live or in the
        # transcript, with every line; Esc, Ctrl-G or Ctrl-O returns to the
        # same rows.
        session = "renderer/expand-message"
        configure(session)
        pasted = "".join(f"PASTE-{index:04d} " + "p" * 40 + "\n" for index in range(300)) + "PASTE-END"
        # 15,609 bytes in 301 lines: two preview lines show, 299 are hidden.
        assert len(pasted.encode()) == 15609
        heading = "Message · 301 lines · 16 KB"
        endpoint.responses.append(fixture.sse_answer("expand-answer", "reason", "message", "EXPAND-ANSWER")[0])
        with terminal(session, rows=40) as tty:
            tty.capture.resize(80, 40)
            tty.send("\x1b[200~" + pasted + "\x1b[201~\r", "EXPAND-ANSWER")
            shown = tty.capture.completed
            assert "PASTE-0001" in shown and "PASTE-0002" not in shown and "┄ 299 more lines · 16 KB" in shown, shown
            for return_key in ("\x1b", "\x07", "\x0f"):
                before = tty.capture.completed
                tty.send("\x0f", heading)
                page = tty.capture.completed
                assert "PASTE-0000" in page and "PASTE-END" not in page, page
                end = tty.send("\x1b[6~" * 20, "PASTE-END")
                assert "PASTE-END" in end and "PASTE-0299" in end, end
                tty.send(return_key, predicate=lambda: "Message ·" not in tty.capture.completed)
                assert tty.capture.completed == before, (return_key, before, tty.capture.completed)
            # In the transcript the same block opens and returns to its rows.
            tty.send("\x1b[A", "Browsing · Esc returns")
            browsing = tty.capture.completed
            tty.send("\x0f", heading)
            tty.send("\x1b", predicate=lambda: "Message ·" not in tty.capture.completed)
            assert tty.capture.completed == browsing, (browsing, tty.capture.completed)
            tty.send("\x1b", predicate=lambda: "Browsing" not in tty.capture.completed)
            # With no collapsed block in view, Ctrl-O says so and opens nothing.
            endpoint.responses.append(fixture.sse_answer("expand-filler", "reason", "message", "\n".join(f"FILLER-{index:02d}" for index in range(60)))[0])
            tty.send("SHORT\r", "FILLER-59")
            tty.send("\x0f", "No collapsed message in view")
            assert "Message ·" not in tty.capture.completed
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: Ctrl-O shows a collapsed Message whole and returns to the same rows", flush=True)

        def traverse(tty, steps=10):
            tty.send("\x1b[A", "Browsing · Esc returns")
            # Each step loads one older page or one listed Message.
            for _ in range(steps):
                tty.send("/history\n", predicate=lambda: "Loading earlier messages…" not in tty.capture.completed)
                if "Start of conversation" in tty.capture.completed:
                    break
            return tty.capture.completed

        def reachable(shown, before, reply="REPLY-00000"):
            # Older pages reach the Message exactly once, after what preceded
            # it and before its reply, or before the rows that left the view.
            assert "Start of conversation" in shown, shown
            assert shown.count(omitted) == 1, shown
            assert shown.index(before) < shown.index(omitted) < after_message(shown, reply), shown

        # A Message sent while a tool runs shows as its Admission at once but
        # gains its conversation row only after the tool's result shows. No
        # transcript may start between them, and after eviction older pages
        # still reach the Message.
        session = "renderer/evicted-steer"
        configure(session)
        gate = workspace / "steer-gate"
        endpoint.responses.append(fixture.sse_tool_calls("evicted-steer", [
            ("bash", "steer-call", json.dumps({"cmd": f"while [ ! -e {shlex.quote(str(gate))} ]; do sleep 0.05; done",
                                               "description": "Wait for steer", "timeout_ms": None}))]))
        endpoint.responses.append(fixture.sse_answer("evicted-steer", "reason", "message", reply)[0])
        with terminal(session) as tty:
            tty.send("start steering\n", "Wait for steer")
            tty.send("\x1b[200~" + "m" * 59199 + "\x1b[201~\r", predicate=lambda: tty.capture.draft("", 2) and "m" * 40 in tty.capture.completed)
            assert not gate.exists()
            gate.touch()
            tty.wait("REPLY-04399", timeout=30)
            shown = traverse(tty)
            reachable(shown, "Wait for steer")
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: a Message steered into a running tool stays in the transcript after eviction", flush=True)

        # A Message queued behind a running answer shows as its Admission
        # before that answer, but its conversation row follows it.
        session = "renderer/evicted-queued"
        configure(session)
        first_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("evicted-first", "reason", "message", "FIRST-ANSWER-DONE")[0], first_release))
        endpoint.responses.append(fixture.sse_answer("evicted-second", "reason", "message", reply)[0])
        with terminal(session) as tty:
            requests = len(endpoint.requests)
            tty.send("FIRST-SMALL-QUESTION\n", predicate=lambda: "› FIRST-SMALL-QUESTION" in tty.capture.completed)
            fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
            tty.send("\x1b[200~" + "q" * 59199 + "\x1b[201~\r", predicate=lambda: tty.capture.draft("", 2) and "q" * 40 in tty.capture.completed)
            first_release.set()
            tty.wait("REPLY-04399", timeout=30)
            shown = traverse(tty)
            reachable(shown, "FIRST-ANSWER-DONE")
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: a Message queued behind an answer stays in the transcript after eviction", flush=True)

        # One page holds a long answer, the conversation row of the Message
        # queued behind it and that Message's reply. The page cannot begin a
        # transcript at the answer, which the Message's Admission preceded,
        # but can at the reply; older pages from there reach the Message.
        session = "renderer/evicted-batched"
        configure(session)
        first_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("batched-first", "reason", "message", reply)[0], first_release))
        endpoint.responses.append(fixture.sse_answer("batched-second", "reason", "message", "SECOND-REPLY-DONE")[0])
        holding, release, held = threading.Event(), threading.Event(), threading.Event()
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_page)
        with terminal(session) as tty:
            requests = len(endpoint.requests)
            tty.send("DRIVER-QUESTION\n", predicate=lambda: "› DRIVER-QUESTION" in tty.capture.completed)
            fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
            tty.send("\x1b[200~" + "m" * 59199 + "\x1b[201~\r", predicate=lambda: tty.capture.draft("", 2) and "m" * 40 in tty.capture.completed)
            holding.set()
            assert held.wait(5), "no scan reached the held page"
            first_release.set()
            fixture.wait_for(lambda: len(endpoint.requests) > requests + 1 and fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "both answers", timeout=8)
            holding.clear()
            release.set()
            tty.wait("SECOND-REPLY-DONE", timeout=30)
            shown = traverse(tty)
            reachable(shown, "DRIVER-QUESTION", "SECOND-REPLY-DONE")
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: a Message whose row and reply share a page with a long answer stays reachable after eviction", flush=True)

        # The same page shape with an answer that live output shortens: its
        # styling is not kept and its oversized cluster is escaped. Eviction
        # cuts the opening, so the transcript must join at the reply's own
        # boundary, which must name where the reply's text begins live. The
        # reply fits the live view, and with the ~7 KB before it does not.
        session = "renderer/styled-batched"
        configure(session)
        first_release = threading.Event()
        filler = "\n".join(f"FILLER-{index:03d} " + "f" * 50 for index in range(100))
        styled = " ".join(f"**bold{index}**" for index in range(12)) + "\n" + filler + "\ne" + "\u0301" * 200 + " STYLED-END"
        fitting = "\n".join(f"REPLY-{index:05d} " + "y" * 50 for index in range(4100))
        endpoint.responses.append((fixture.sse_answer("styled-first", "reason", "message", styled)[0], first_release))
        endpoint.responses.append(fixture.sse_answer("styled-second", "reason", "message", fitting)[0])
        holding, release, held = threading.Event(), threading.Event(), threading.Event()
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_page)
        with terminal(session, rows=160) as tty:
            tty.capture.resize(80, 160)
            requests = len(endpoint.requests)
            tty.send("DRIVER-QUESTION\n", predicate=lambda: "› DRIVER-QUESTION" in tty.capture.completed)
            fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
            tty.send("\x1b[200~" + "m" * 59199 + "\x1b[201~\r", predicate=lambda: tty.capture.draft("", 2) and "m" * 40 in tty.capture.completed)
            holding.set()
            assert held.wait(5), "no scan reached the held page"
            first_release.set()
            fixture.wait_for(lambda: len(endpoint.requests) > requests + 1 and fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "both answers", timeout=8)
            holding.clear()
            release.set()
            tty.wait("REPLY-04099", timeout=30)
            shown = traverse(tty)
            assert "Earlier rows left this view." not in shown, shown
            reachable(shown, "STYLED-END")
            # The reply starts whole, once, where older pages end.
            assert shown.count("REPLY-00000") == 1 and "\nREPLY-00000 " in shown, shown
            assert shown.count("STYLED-END") == 1 and shown.count("bold11") == 1, shown
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: a boundary after text that live output shortens starts where its item's text does", flush=True)

        # Escaping shortens live output by more than a short reply and the
        # next read add: a later boundary must still follow the reply's.
        session = "renderer/styled-short"
        configure(session)
        first_release = threading.Event()
        styled = "e" + "\u0301" * 2000 + " SHORT-STYLED-END"
        endpoint.responses.append((fixture.sse_answer("short-first", "reason", "message", styled)[0], first_release))
        endpoint.responses.append(fixture.sse_answer("short-second", "reason", "message", "OK-REPLY")[0])
        holding, release, held = threading.Event(), threading.Event(), threading.Event()
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_page)
        with terminal(session) as tty:
            requests = len(endpoint.requests)
            tty.send("DRIVER-QUESTION\n", predicate=lambda: "› DRIVER-QUESTION" in tty.capture.completed)
            fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
            tty.send("QUEUED-M\n", predicate=lambda: "› QUEUED-M" in tty.capture.completed)
            holding.set()
            assert held.wait(5), "no scan reached the held page"
            first_release.set()
            fixture.wait_for(lambda: len(endpoint.requests) > requests + 1 and fixture.command("session", "inspect", "--store", store, "--session", session)["work"]["status"] == "completed", "both answers", timeout=8)
            holding.clear()
            release.set()
            tty.wait("OK-REPLY", timeout=30)
            tty.send("THIRD-QUESTION\n", answer("styled third"))
            tty.send("\x1b[A", "Start of conversation")
            shown = tty.capture.completed
            assert "Browsing · Esc returns" in shown and "Earlier rows left this view." not in shown, shown
            for text in ("› DRIVER-QUESTION", "SHORT-STYLED-END", "› QUEUED-M", "OK-REPLY", "› THIRD-QUESTION", "renderer answer styled third"):
                assert shown.count(text) == 1, (text, shown)
            assert shown.index("SHORT-STYLED-END") < shown.index("OK-REPLY") < shown.index("› THIRD-QUESTION"), shown
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: a boundary after text escaping shortens by more than later output stays ordered", flush=True)

        # A Message queued behind a long answer gains its conversation row
        # once that answer ends, but its own answer is still held: the read
        # that holds its row shows nothing. After eviction cuts its preview,
        # older pages must still reach it.
        session = "renderer/evicted-rowed-silent"
        configure(session)
        first_release, second_release = threading.Event(), threading.Event()
        endpoint.responses.append((fixture.sse_answer("silent-first", "reason", "message", reply)[0], first_release))
        endpoint.responses.append((fixture.sse_answer("silent-second", "reason", "message", "SILENT-SECOND-DONE")[0], second_release))
        try:
            with terminal(session) as tty:
                requests = len(endpoint.requests)
                tty.send("DRIVER-QUESTION\n", predicate=lambda: "› DRIVER-QUESTION" in tty.capture.completed)
                fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
                tty.send("\x1b[200~" + "m" * 59199 + "\x1b[201~\r", predicate=lambda: tty.capture.draft("", 2) and "m" * 40 in tty.capture.completed)
                first_release.set()
                tty.wait("REPLY-04399", timeout=30)
                # The queued Message is now applied, and its own answer held.
                fixture.wait_for(lambda: len(endpoint.requests) > requests + 1, "second model request", timeout=20)
                time.sleep(1)  # Scans read its row; nothing more shows.
                assert "SILENT-SECOND-DONE" not in tty.capture.completed
                shown = traverse(tty)
                assert "Start of conversation" in shown and "Earlier rows left this view." not in shown, shown
                assert shown.count(omitted) == 1, shown
                # Its row, after the omitted reply's row, not the live preview before it.
                assert shown.index("DRIVER-QUESTION") < shown.index("raw bytes") < shown.index(omitted), shown
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            second_release.set()
        print("renderer: a Message whose row a silent read holds stays reachable after eviction", flush=True)

        # The same, with the Message's own turn waiting on an Action: a call
        # is outstanding while reads hold the row, and once decided its
        # result takes a later position and shows once.
        session = "renderer/evicted-rowed-asked"
        configure(session, "ask")
        first_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("asked-first", "reason", "message", reply)[0], first_release))
        endpoint.responses.append(fixture.sse_tool_calls("asked-call", [("bash", "asked-action", json.dumps({"cmd": "printf CALL-RESULT-DONE", "description": "Rowed call", "timeout_ms": None}))]))
        endpoint.responses.append(fixture.sse_answer("asked-final", "reason", "message", "ASKED-DONE")[0])
        ready_read, ready_write = os.pipe()
        try:
            with terminal(session, ready_write) as tty:
                requests = len(endpoint.requests)
                tty.send("DRIVER-QUESTION\n", predicate=lambda: "› DRIVER-QUESTION" in tty.capture.completed)
                fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
                tty.send("\x1b[200~" + "m" * 59199 + "\x1b[201~\r", predicate=lambda: tty.capture.draft("", 2) and "m" * 40 in tty.capture.completed)
                first_release.set()
                tty.wait("Type a + Enter to allow once · d + Enter to deny", timeout=30)
                # A pending Action holds the screen until decided (/history waits).
                tty.ready(ready_read)
                tty.send("a", predicate=lambda: tty.capture.draft("a", 3, prompt="> "))
                tty.send("\n", "ASKED-DONE")
                shown = traverse(tty)
                assert "Start of conversation" in shown and "Earlier rows left this view." not in shown, shown
                assert shown.count(omitted) == 1 and shown.index("DRIVER-QUESTION") < shown.index("raw bytes") < shown.index(omitted), shown
                assert shown.count("✓ Rowed call") == 1 and shown.index(omitted) < shown.index("✓ Rowed call") < shown.index("ASKED-DONE"), shown
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            first_release.set()
            os.close(ready_read)
            os.close(ready_write)
        print("renderer: a Message whose turn waits on an Action stays reachable, and its result shows once", flush=True)

        # Messages queued behind an answer that evicts their echoes, and
        # still queued while its call runs: the gap lists each once, two with
        # equal content included, labelled as queued; once they run, each is
        # its row, never also listed.
        def text_and_call(response_id, text, call_id, arguments):
            message = {"type": "message", "id": f"{response_id}-message", "status": "completed", "role": "assistant", "phase": "commentary",
                "content": [{"type": "output_text", "text": text, "annotations": []}]}
            call = {"type": "function_call", "id": f"{response_id}-call", "status": "completed", "name": "bash", "call_id": call_id, "arguments": arguments}
            payloads = []
            for index, item in enumerate((message, call)):
                payloads.append({"type": "response.output_item.added", "output_index": index, "item": {"type": item["type"], "id": item["id"]}})
                if item is call:
                    payloads += [{"type": "response.function_call_arguments.delta", "output_index": index, "item_id": item["id"], "delta": "non-authoritative"},
                        {"type": "response.function_call_arguments.done", "output_index": index, "item_id": item["id"], "arguments": "non-authoritative"}]
                payloads.append({"type": "response.output_item.done", "output_index": index, "item": item})
            payloads.append({"type": "response.completed", "response": {"id": response_id, "status": "completed", "model": "model-a-served", "output": [message, call]}})
            return fixture.encode_sse(payloads)

        def queue_three(tty):
            # Each admission shows before the next is sent.
            for text, marker, count in (("EQUAL-CONTENT", "› EQUAL-CONTENT", 1), ("EQUAL-CONTENT", "› EQUAL-CONTENT", 2), (big, big_size, 1)):
                tty.send("\x1b[200~" + text + "\x1b[201~\r", predicate=lambda: tty.capture.completed.count(marker) == count and tty.capture.draft("", 2))

        long_reply = "\n".join(f"LONG-{index:05d} " + "y" * 50 for index in range(4400))
        big = "BIG-START " + "é ñ ü " * 300 + "BIG-END"
        # 2,717 bytes: collapsed to its first 200 bytes, cut before a split é.
        big_size = "┄ 2.7 KB"

        def big_whole(shown):
            # Its preview once, whatever wrapping, indentation and its time
            # add, then its size and nothing more of it.
            start = shown.index("BIG-START") + len("BIG-START")
            cut = shown.index("…", start)
            body = "\n".join(untimed(row) for row in shown[start:cut].split("\n"))
            return "".join(body.split()) == "éñü" * 21 and shown.index(big_size, cut) - cut < 8 and "BIG-END" not in shown
        session = "renderer/listed-queued"
        configure(session)
        first_release = threading.Event()
        held = {"X-Request-Id": "listed-held", "OpenAI-Model": "model-a-served"}
        endpoint.responses.append((fixture.ResponseSpec(text_and_call("listed-first", long_reply, "listed-call", json.dumps({
            "cmd": "while [ ! -e listed-release ]; do sleep 0.05; done; printf CALL-DONE", "description": "Held call", "timeout_ms": None})), held, gate_timeout=60), first_release))
        endpoint.responses.append(fixture.sse_answer("listed-final", "reason", "message", "LISTED-DONE")[0])
        try:
            with terminal(session, rows=200) as tty:
                tty.capture.resize(80, 200)
                requests = len(endpoint.requests)
                tty.send("DRIVER-QUESTION\n", predicate=lambda: "› DRIVER-QUESTION" in tty.capture.completed)
                fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
                queue_three(tty)
                first_release.set()
                tty.wait("LONG-04399", timeout=60)
                tty.wait("Held call", timeout=30)
                shown = traverse(tty)
                assert "Start of conversation" in shown and "Earlier rows left this view." in shown, shown
                listed = shown.split("Earlier rows left this view.", 1)[1]
                assert shown.index("DRIVER-QUESTION") < shown.index("Earlier rows left this view."), shown
                assert listed.count("! Queued") == 3 and listed.count("EQUAL-CONTENT") == 2, shown
                assert shown.count("EQUAL-CONTENT") == 2 and shown.count("BIG-START") == 1 and shown.count(big_size) == 1, shown
                assert big_whole(shown), shown
                assert "LONG-00000" not in shown, "the copy started before the front"
                tty.send("\x1b", predicate=lambda: "Browsing" not in tty.capture.completed)
                (workspace / "listed-release").write_text("")
                tty.wait("LISTED-DONE", timeout=30)
                shown = traverse(tty)
                # Now rows: each once, never also listed as queued.
                assert "! Queued" not in shown and shown.count("EQUAL-CONTENT") == 2 and shown.count(big_size) == 1, shown
                assert shown.count("BIG-START") == 1 and big_whole(shown), shown
                assert shown.index("DRIVER-QUESTION") < shown.index("EQUAL-CONTENT") < shown.index("BIG-START"), shown
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            first_release.set()
            (workspace / "listed-release").write_text("")
        print("renderer: queued Messages whose echoes left the view are listed once, then are their rows", flush=True)

        # More queued echoes than the record keeps, wrapped twice, with no
        # boundary between them: the dropped span is listed through Activity
        # pages, the kept echoes from the record, each once.
        session = "renderer/listed-dropped"
        configure(session)
        first_release = threading.Event()
        endpoint.responses.append((fixture.ResponseSpec(text_and_call("dropped-first", long_reply, "dropped-call", json.dumps({
            "cmd": "while [ ! -e dropped-release ]; do sleep 0.05; done; printf CALL-DONE", "description": "Held call", "timeout_ms": None})), held, gate_timeout=60), first_release))
        endpoint.responses.append(fixture.sse_answer("dropped-final", "reason", "message", "DROPPED-DONE")[0])
        try:
            # Tall enough to show every listed Message at once.
            with terminal(session, rows=500) as tty:
                tty.capture.resize(80, 500)
                requests = len(endpoint.requests)
                tty.send("DRIVER-QUESTION\n", predicate=lambda: "› DRIVER-QUESTION" in tty.capture.completed)
                fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
                for index in range(66):
                    tty.send(f"DROPPED-QUEUED-{index:02d}\n", predicate=lambda index=index: f"› DROPPED-QUEUED-{index:02d}" in tty.capture.completed and tty.capture.draft("", 2))
                first_release.set()
                tty.wait("LONG-04399", timeout=60)
                tty.wait("Held call", timeout=30)
                shown = traverse(tty, 80)
                assert all(shown.count(f"DROPPED-QUEUED-{index:02d}") == 1 for index in range(66)), shown
                assert "Start of conversation" in shown and shown.count("! Queued") == 66, shown
                order = [shown.index(f"DROPPED-QUEUED-{index:02d}") for index in range(66)]
                assert order == sorted(order) and shown.index("DRIVER-QUESTION") < order[0], shown
                tty.send("\x1b", predicate=lambda: "Browsing" not in tty.capture.completed)
                (workspace / "dropped-release").write_text("")
                tty.wait("DROPPED-DONE", timeout=30)
                shown = traverse(tty)
                assert "! Queued" not in shown and all(shown.count(f"DROPPED-QUEUED-{index:02d}") == 1 for index in range(66)), shown
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            first_release.set()
            (workspace / "dropped-release").write_text("")
        print("renderer: queued echoes beyond the record's capacity are listed once, in order", flush=True)

        # Messages a Stop excludes never gain rows: after later output evicts
        # them, a transcript lists each once, labelled, at its seam.
        session = "renderer/listed-stopped"
        configure(session)
        first_release = threading.Event()
        endpoint.responses.append((fixture.ResponseSpec(fixture.sse_answer("stopped-first", "reason", "message", "NEVER-SHOWN")[0], held, gate_timeout=60), first_release))
        endpoint.responses.append(fixture.sse_answer("stopped-after", "reason", "message", long_reply)[0])
        try:
            with terminal(session, rows=200) as tty:
                tty.capture.resize(80, 200)
                requests = len(endpoint.requests)
                tty.send("DRIVER-QUESTION\n", predicate=lambda: "› DRIVER-QUESTION" in tty.capture.completed)
                fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
                queue_three(tty)
                run(home, "session", "stop", "--store", store, "--session", session, "--record", state / "listed-stop.json", "--key", "listed-stop")
                tty.wait("Session stopped", timeout=30)
                first_release.set()
                tty.send("AFTER-STOP\n", predicate=lambda: "LONG-04399" in tty.capture.completed)
                shown = traverse(tty)
                assert "Start of conversation" in shown and "Earlier rows left this view." not in shown, shown
                stopped = "! Stopped before it ran · send it again to run it"
                assert shown.count(stopped) == 3 and shown.count("EQUAL-CONTENT") == 2, shown
                assert shown.count("BIG-START") == 1 and shown.count(big_size) == 1 and shown.count("AFTER-STOP") == 1, shown
                assert big_whole(shown), shown
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            first_release.set()
        print("renderer: Messages a Stop excluded are listed once, labelled, after later output evicts them", flush=True)

        # A queued Message older than the opening's page, which holds only
        # its turn's commentary and held calls, is applied in the same read
        # as their results. Its row shows nothing live, and the opening's
        # mark left the view, so older pages must reach it.
        session = "renderer/opening-applied"
        configure(session)
        first_release, page_release, page_held = threading.Event(), threading.Event(), threading.Event()
        commentary = {"type": "message", "id": "opening-applied-message", "status": "completed", "role": "assistant", "phase": "commentary",
            "content": [{"type": "output_text", "text": "\n".join(f"OPENING-LONG-{index:05d} " + "x" * 50 for index in range(4500)), "annotations": []}]}
        calls = [{"type": "function_call", "id": f"opening-applied-tool-{index}", "status": "completed", "name": "bash", "call_id": f"opening-applied-call-{index}",
            "arguments": json.dumps({"cmd": "touch opening-started; while [ ! -e opening-release ]; do sleep 0.05; done; printf done", "description": f"Opening call {index:02d}", "timeout_ms": None})}
            for index in range(15)]
        payloads = []
        for index, item in enumerate([commentary, *calls]):
            payloads += [{"type": "response.output_item.added", "output_index": index, "item": {"type": item["type"], "id": item["id"]}},
                {"type": "response.output_item.done", "output_index": index, "item": item}]
        payloads.append({"type": "response.completed", "response": {"id": "opening-applied-first", "status": "completed", "model": "model-a-served", "output": [commentary, *calls]}})
        endpoint.responses.append((fixture.ResponseSpec(fixture.encode_sse(payloads), held, gate_timeout=60), first_release))
        endpoint.responses.append(fixture.sse_answer("opening-applied-final", "reason", "message", "OPENING-APPLIED-DONE")[0])

        def hold_once(_):
            if not page_held.is_set():
                page_held.set()
                assert page_release.wait(20), "the held page was never released"
            return True
        try:
            requests = len(endpoint.requests)
            run(home, "session", "send", "--store", store, "--session", session, "DRIVER-QUESTION")
            fixture.wait_for(lambda: len(endpoint.requests) > requests, "first model request", timeout=20)
            run(home, "session", "send", "--store", store, "--session", session, "HIDDEN-QUEUED-UNIQUE")
            first_release.set()
            fixture.wait_for(lambda: (workspace / "opening-started").exists(), "held calls", timeout=20)
            with terminal(session, rows=200, opening=False) as tty:
                tty.capture.resize(80, 200)
                opened = tty.wait(predicate=lambda: tty.capture.draft("", 2), timeout=30)
                assert "HIDDEN-QUEUED-UNIQUE" not in opened and "OPENING-LONG-04499" in opened, opened
                # One read returns the calls' results and the Message's row.
                proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_once)
                assert page_held.wait(5), "no scan reached the held page"
                (workspace / "opening-release").touch()
                fixture.wait_for(lambda: len(endpoint.requests) > requests + 1, "continuation", timeout=20)
                assert any(item.get("role") == "user" and item["content"][0]["text"] == "HIDDEN-QUEUED-UNIQUE" for item in json.loads(endpoint.requests[-1])["input"])
                page_release.set()
                tty.wait("✓ Opening call 14", timeout=30)
                shown = traverse(tty)
                assert "Start of conversation" in shown and shown.count("HIDDEN-QUEUED-UNIQUE") == 1, shown
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
            proxy.close()
            proxy = None
        finally:
            page_release.set()
            first_release.set()
            (workspace / "opening-release").touch()
        print("renderer: a queued Message the opening left out stays reachable once applied unseen", flush=True)

        # An opening whose newest page holds only some queued Messages: the
        # page shows those, and its seam lists the eight older ones, each
        # once (more than any fixed preview count).
        session = "renderer/listed-opening"
        configure(session)
        first_release = threading.Event()
        endpoint.responses.append((fixture.ResponseSpec(fixture.sse_answer("opening-first", "reason", "message", "OPENING-DONE")[0], held, gate_timeout=60), first_release))
        try:
            requests = len(endpoint.requests)
            run(home, "session", "send", "--store", store, "--session", session, "ACTIVE-ORIGINAL")
            fixture.wait_for(lambda: len(endpoint.requests) > requests, "held first model request", timeout=20)
            for index in range(24):
                run(home, "session", "send", "--store", store, "--session", session, f"OPENING-QUEUED-{index:02d}")
            with terminal(session, rows=200, opening=False) as tty:
                tty.capture.resize(80, 200)
                opened = tty.wait(predicate=lambda: tty.capture.draft("", 2))
                shown = traverse(tty)
                assert all(shown.count(f"OPENING-QUEUED-{index:02d}") == 1 for index in range(24)), shown
                assert "Start of conversation" in shown and "Earlier rows left this view." not in shown, shown
                assert shown.count("! Queued") == 24 and shown.count("ACTIVE-ORIGINAL") == 1, shown
                assert "Rui: 24 queued messages." in opened and "Queued: " not in opened, opened
                assert opened.count("! Queued") == 16 and "OPENING-QUEUED-07" not in opened and "OPENING-QUEUED-08" in opened, opened
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            first_release.set()
        print("renderer: an opening lists the queued Messages its page left out once, at its seam", flush=True)
        completed = True
    finally:
        dispose_all(lambda: proxy.close() if proxy is not None else None,
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5))
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained renderer failure state: {state}", file=sys.stderr)
        resource.setrlimit(resource.RLIMIT_NOFILE, original_limit)


def main(selected="all"):
    import canonical_failure_integration
    import terminal_restoration_integration
    from terminal_process_test import prove_terminal_process
    assert selected in ("all", "renderer", "compaction-settings", "long-input", "terminal-waits", "persistent-permission", "incomplete-input"), selected
    if selected == "renderer":
        renderer_cases()
        return
    if selected == "all":
        renderer_cases()
    if selected in ("all", "compaction-settings"):
        help_case()
    if selected in ("all", "terminal-waits"):
        prove_terminal_process()
        pipe_wait_oracles()
        terminal_wait_oracles()
    if selected == "terminal-waits":
        return
    if selected == "all":
        opaque_session_commands_case()
        silent_read_edit_cases()
        command_entry_cases()
        persistent_opening_case()
        scroll_return_case()
        persistent_pending_case()
        persistent_input_cases()
    if selected in ("all", "persistent-permission"):
        persistent_permission_case()
        persistent_permission_case("allow-action")
        persistent_permission_case("allow-action", exit_code=7)
        persistent_permission_case("allow-action", signal_failure=True)
        persistent_permission_case("allow-action", signal_failure=True, timed_out=True)
        persistent_permission_case("allow-action", lost_reply=True)
        persistent_permission_case("deny-action", lost_reply=True)
        persistent_permission_case(fragmented_paste=True)
        persistent_permission_case(stale_target=True)
    if selected == "persistent-permission":
        return
    if selected == "all":
        terminal_restoration_integration.main()
        canonical_failure_integration.main()
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-human-cli."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    session = "human/bash"
    counter = workspace / "effect-count"
    arguments = json.dumps({"cmd": "printf x >> effect-count", "description": "Write first effect", "timeout_ms": None}, separators=(",", ":"))
    # RLO, C1 CSI and DEL as well as ESC: each can disguise terminal output.
    control_call = "human-call\x1b[1Ghidden\u202e\u009b\x7f"
    control_arguments = arguments + "\r  "
    sibling_started = state / "sibling-started"
    sibling_release = state / "sibling-release"
    sibling_effect = workspace / "sibling-effect"
    sibling_arguments = json.dumps({"cmd": f"touch {shlex.quote(str(sibling_started))}; "
        f"while [ ! -e {shlex.quote(str(sibling_release))} ]; do sleep 0.05; done; "
        "printf y >> sibling-effect", "description": "Write delayed sibling effect", "timeout_ms": None}, separators=(",", ":"))
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("human-calls", [("bash", control_call, control_arguments)]),
        fixture.sse_answer("human-answer", "human-reason", "human-message", "first answer")[0],
        fixture.sse_answer("second-answer", "second-reason", "second-message", "second answer")[0],
        fixture.sse_tool_calls("sibling-calls", [("bash", "pending-call", arguments),
            ("bash", "running-call", sibling_arguments)]),
        fixture.sse_answer("sibling-answer", "sibling-reason", "sibling-message", "siblings done")[0],
    ] if selected == "all" else [])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    host = None
    failure_release = None
    stop_release = None
    observation_release = None
    race_predecessor_release = threading.Event()
    race_message_release = threading.Event()
    completed = False
    try:
        host = fixture.start_host(store, url)
        if selected in ("all", "compaction-settings"):
            compaction_settings_case(home, store, workspace)
        if selected == "compaction-settings":
            completed = True
            print("compaction settings and scoped help passed (partial human CLI suite)")
            return
        if selected == "incomplete-input":
            run(home, "session", "configure", "--store", store, "--session", "incomplete/input",
                "--workspace", workspace, "--provider", "codex", "--model", "model-a")
            incomplete_input_case(home, store, "incomplete/input", endpoint, host)
            completed = True
            return
        if selected == "long-input":
            long_input_case(home, store, workspace, endpoint, host)
            completed = True
            print("long-input selected case passed (partial human CLI suite)", flush=True)
            return
        store_selection_cases(state, workspace, store)
        saved_capture_cases(state, store, workspace)
        preferences_home = state / "preferences-home"
        preferences_home.mkdir()
        fallback = preferences_home / ".local/share/rui/store"
        fresh_setup = defaults(preferences_home)
        assert (fresh_setup["store"], fresh_setup["store_source"], fresh_setup["store_available"]) == (str(fallback), "home", False), fresh_setup
        assert fresh_setup["next_session"] == {"status": "choose_provider"} and fresh_setup["host"] == {"status": "store_unavailable"}, fresh_setup
        assert not (preferences_home / ".config").exists(), "inspection created private state"
        # The shorter preferences path fits while the unsaved Store fallback
        # does not. Independent provider publication still succeeds.
        max_path = os.pathconf(preferences_home, "PC_PATH_MAX")
        long_home = str(preferences_home) + "/." * ((max_path - 16 - len(str(preferences_home))) // 2)
        oversized_setup = defaults(long_home, "--provider", "codex")
        assert oversized_setup["store_available"] is False and oversized_setup["provider"] == "codex", oversized_setup
        assert oversized_setup["host"] == {"status": "store_unavailable"}, oversized_setup
        assert (preferences_home / ".config/rui/preferences").read_text().endswith("provider=codex\nmodel=\n")
        invalid_home = os.fsencode(state) + b"/home-\xff"
        try:
            os.mkdir(invalid_home, mode=0o700)
        except OSError as err:
            if err.errno != errno.EILSEQ:
                raise
            # macOS filesystems may reject this name before Rui sees HOME.
        invalid = subprocess.run([os.fsencode(fixture.RUI), b"defaults", b"configure", b"--provider", b"codex"],
            env={**os.environb, b"HOME": invalid_home}, capture_output=True, timeout=20)
        assert invalid.returncode != 0 and b"InvalidHome" in invalid.stderr, invalid
        assert not os.path.exists(invalid_home + b"/.config"), invalid
        bidi_store = state / "store-\u202ehidden"
        bidi_store.mkdir(mode=0o700)
        bidi_home = state / "bidi-home"
        bidi_home.mkdir()
        canonical_bidi_store = bidi_store.resolve()
        bidi_setup = defaults(bidi_home, "--store", bidi_store)
        assert (bidi_setup["store"], bidi_setup["store_source"]) == (str(canonical_bidi_store), "saved"), bidi_setup
        assert f"store={canonical_bidi_store}\n" in (bidi_home / ".config/rui/preferences").read_text()
        assert "HomeUnavailable" in subprocess.run([str(fixture.RUI), "defaults", "inspect"],
            env={key: value for key, value in os.environ.items() if key != "HOME"},
            capture_output=True, text=True).stderr
        alias = state / "store-alias"
        alias.symlink_to(store, target_is_directory=True)
        defaults(preferences_home, "--store", alias,
            "--provider", "codex", "--model", "gpt-6-luna")
        saved = preferences_home / ".config/rui/preferences"
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        preference_edits(preferences_home, store)
        original_preferences = saved.read_text()
        saved.write_text(original_preferences.replace("model=gpt-6-luna", "model=family=variant"))
        assert saved.read_text().endswith("provider=codex\nmodel=family=variant\n")
        assert defaults(preferences_home)["model"] == "family=variant"
        saved.write_text(original_preferences)
        assert saved.stat().st_mode & 0o777 == 0o600
        assert saved.parent.stat().st_mode & 0o777 == 0o700
        missing_setup = defaults(preferences_home)
        assert (missing_setup["store"], missing_setup["store_source"]) == (str(store.resolve()), "saved"), missing_setup
        assert missing_setup["local_credential"] == "missing" and missing_setup["next_session"] == {
            "status": "selected", "provider": "codex", "model": "gpt-6-luna", "local_credential": "missing"}, missing_setup
        assert missing_setup["host"]["status"] == "ready", missing_setup
        assert missing_setup["host"]["capabilities"]["managed_authentication"] is False, missing_setup
        linked_home = state / "linked-home"
        (linked_home / ".config").mkdir(parents=True)
        (linked_home / ".config/rui").symlink_to(saved.parent, target_is_directory=True)
        defaults(linked_home, "--store", store,
            "--provider", "codex", "--model", "gpt-6-luna", success=False)
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        backup = saved.parent / "saved-preferences"
        saved.rename(backup)
        os.mkfifo(saved, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "defaults", "inspect"],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode != 0, blocked
        finally:
            dispose_all(saved.unlink, lambda: backup.rename(saved))
        retired_store = state / "retired-store"
        retired_store.mkdir(mode=0o700)
        defaults(preferences_home, "--store", retired_store)
        retired_store.rmdir()
        unavailable_setup = defaults(preferences_home)
        assert (unavailable_setup["store"], unavailable_setup["store_available"]) == (str(retired_store), False), unavailable_setup
        assert unavailable_setup["host"] == {"status": "store_unavailable"}, unavailable_setup
        defaults(preferences_home, "--clear-model")
        assert saved.read_text().endswith("provider=codex\nmodel=\n")
        assert f"store={retired_store}\n" in saved.read_text()
        defaults(preferences_home, "--model", "gpt-6-luna")
        defaults(preferences_home, "--store", store)
        assert f"store={store.resolve()}\n" in saved.read_text()
        credential = saved.parent / "codex.json"
        lock = saved.parent / ".codex.json.lock"
        assert not credential.exists() and not lock.exists()
        codex_fixture.credentials(credential)
        configured_setup = defaults(preferences_home)
        assert configured_setup["local_credential"] == "configured", configured_setup
        assert configured_setup["next_session"]["local_credential"] == "configured", configured_setup
        assert not lock.exists(), "status must not create a credential lock"
        fresh_provider_home = state / "fresh-provider-home"
        (fresh_provider_home / ".config/rui").mkdir(parents=True, mode=0o700)
        codex_fixture.credentials(fresh_provider_home / ".config/rui/codex.json")
        defaults(fresh_provider_home, "--model", "gpt-6-luna")
        assert (fresh_provider_home / ".config/rui/preferences").read_text().endswith(
            "store=\nprovider=codex\nmodel=gpt-6-luna\n")
        credential.unlink()
        os.mkfifo(credential, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "defaults", "inspect"],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode == 0 and json.loads(blocked.stdout)["local_credential"] == "credential_error", blocked
        finally:
            dispose_all(credential.unlink)
        codex_fixture.credentials(credential, state="refresh_pending")
        assert defaults(preferences_home)["local_credential"] == "refresh_required"
        assert "state=refresh_pending" in credential.read_text(), "status must not refresh"
        credential.chmod(0o644)
        assert defaults(preferences_home)["local_credential"] == "credential_error"
        credential.unlink()
        defaults(preferences_home, "--provider", "other", success=False)
        defaults(preferences_home, "--model", "other-model")
        assert saved.read_text().endswith("model=other-model\n")
        defaults(preferences_home, "--model", "gpt-6-luna")
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        defaults(preferences_home, "--store", state / "missing", success=False)
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        # A directory in the temporary-file slot is an honest save failure;
        # no partial replacement may appear as a saved preference.
        temp = saved.parent / "preferences.tmp"
        temp.mkdir()
        blocked = subprocess.run([str(fixture.RUI), "defaults", "configure", "--store", str(store)],
            env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=2)
        assert blocked.returncode != 0 and "save failed: InsecurePreferenceFile" in blocked.stderr, blocked
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        temp.rmdir()
        os.mkfifo(temp, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "defaults", "configure", "--store", str(store)],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode != 0, blocked
            assert saved.read_text().endswith("model=gpt-6-luna\n")
        finally:
            dispose_all(temp.unlink)
        codex_fixture.credentials(credential)
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        stale = defaults(preferences_home)
        assert stale["local_credential"] == "configured" and stale["next_session"] == {"status": "unsupported_provider"}, stale
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        defaults(preferences_home, "--store", store)
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        defaults(preferences_home, "--provider", "codex")
        assert saved.read_text().endswith("provider=codex\nmodel=\n")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        defaults(preferences_home, "--provider", "codex", "--model", "gpt-6-luna")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=old-model\n")
        prospective = defaults(preferences_home)["next_session"]
        assert (prospective["status"], prospective["provider"], prospective["model"]) == ("selected", "codex", "old-model"), prospective
        defaults(preferences_home, "--model", "gpt-6-luna")
        saved.rename(saved.parent / "preferences.backup")
        sole = defaults(preferences_home)
        assert sole["provider"] is None and sole["next_session"] == {
            "status": "selected", "provider": "codex", "model": "gpt-6-luna", "local_credential": "configured"}, sole
        (saved.parent / "preferences.backup").rename(saved)
        credential.unlink()
        saved.write_text("version=9\n")
        defaults(preferences_home, success=False)
        defaults(preferences_home, "--model", "another-model", success=False)
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        saved.chmod(0o644)
        defaults(preferences_home, success=False)
        saved.chmod(0o600)
        saved.rename(saved.parent / "real-preferences")
        saved.symlink_to("real-preferences")
        defaults(preferences_home, success=False)
        saved.unlink()
        (saved.parent / "real-preferences").rename(saved)
        defaults(preferences_home, "--model", "bad\nmodel", success=False)
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        config = admit(home, "session", "configure", "--store", store, "--session", session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert config["admission"]["answer"]["status"] == "accepted", config
        # A one-shot read selects the saved Store; explicit targeting bypasses
        # even corrupt preferences, and an invalid saved destination never falls back.
        assert json.loads(run(preferences_home, "session", "inspect", "--session", session))["work"]["status"] == "idle"
        saved.write_text("version=9\n")
        assert run(preferences_home, "session", "inspect", "--session", session, success=False) == ""
        assert json.loads(run(preferences_home, "session", "inspect", "--store", store,
            "--session", session))["work"]["status"] == "idle"
        with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", session], env={**os.environ, "HOME": str(preferences_home)},
        ) as (entered, master):
            assert "Session:" not in read_terminal(master, "› ")
            assert f"Session: {session}" in terminal_step(master, "/status", "Session: ", composer=True)
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        saved.unlink()
        fallback.parent.mkdir(parents=True)
        fallback.symlink_to(store, target_is_directory=True)
        with terminal_process([str(fixture.RUI), "session", "resume", "--", session],
            env={**os.environ, "HOME": str(preferences_home)},
        ) as (entered, master):
            assert "Session:" not in read_terminal(master, "› ")
            assert f"Session: {session}" in terminal_step(master, "/status", "Session: ", composer=True)
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        fallback.unlink()
        saved.write_text(f"version=1\nstore={state / 'missing'}\nprovider=codex\nmodel=gpt-6-luna\n")
        saved.chmod(0o600)
        assert run(preferences_home, "session", "inspect", "--session", session, success=False) == ""
        before_missing = run(preferences_home, "request", "list")
        assert not (state / "missing").exists()
        master, slave = open_pty()
        try:
            entered = subprocess.run([str(fixture.RUI), "session", "resume", "--", session],
                env={**os.environ, "HOME": str(preferences_home)}, stdin=slave,
                stdout=slave, stderr=subprocess.PIPE, timeout=5)
        finally:
            dispose_all(lambda: os.close(slave), lambda: os.close(master))
        assert entered.returncode != 0 and b"FileNotFound" in entered.stderr, entered.stderr
        assert not (state / "missing").exists() and not fallback.exists()
        assert run(preferences_home, "request", "list") == before_missing
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        assert json.loads(run(home, "session", "inspect", "--store", store, "--session", session))["work"]["status"] == "idle"
        before = run(preferences_home, "request", "list")
        invalid_store = subprocess.run([str(fixture.RUI), "session", "send", "--store", "",
            "--session", session, "not sent"], env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=5)
        assert invalid_store.returncode != 0 and "InvalidStore" in invalid_store.stderr, invalid_store
        assert invalid_store.stdout == "" and run(preferences_home, "request", "list") == before
        no_tty_home = state / "no-tty-home"
        no_tty_home.mkdir()
        no_terminal = subprocess.run([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(no_tty_home)}, capture_output=True, text=True, timeout=5)
        assert no_terminal.returncode != 0 and "InteractiveTerminalRequired" in no_terminal.stderr
        assert not (no_tty_home / ".config").exists(), "non-TTY invocation created preferences or a request"
        assert not (no_tty_home / ".local/share/rui/store").exists(), "non-TTY invocation changed the Store"
        before_missing = set(json.loads(run(preferences_home, "request", "list")))
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        try:
            deferred = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(preferences_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            dispose_all(lambda: os.close(master), lambda: os.close(slave), lambda: os.close(ready_read))
            raise
        finally:
            dispose_all(lambda: os.close(ready_write))
        try:
            offered = provider_prompt(master, ready_read)
            assert "No locally ready provider" in offered and "Codex login" in offered, offered
            assert "No new Session created" in terminal_step(master, "d", "No new Session created")
            assert deferred.wait(timeout=5) == 0
            assert set(json.loads(run(preferences_home, "request", "list"))) == before_missing
        finally:
            dispose_all(lambda: stop_process(deferred, timeout=5),
                        lambda: os.close(ready_read), lambda: os.close(master), lambda: os.close(slave))
        explicit_home = state / "explicit-home"
        explicit_config = explicit_home / ".config/rui"
        explicit_config.mkdir(parents=True, mode=0o700)
        malformed = explicit_config / "preferences"
        malformed.write_text("version=9\n")
        malformed.chmod(0o600)
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        try:
            explicit = subprocess.Popen([str(fixture.RUI), "--store", str(store),
                "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
                env={**os.environ, "HOME": str(explicit_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            dispose_all(lambda: os.close(master), lambda: os.close(slave), lambda: os.close(ready_read))
            raise
        finally:
            dispose_all(lambda: os.close(ready_write))
        try:
            assert "No locally ready provider" in provider_prompt(master, ready_read)
            # Another client installs a fixture credential while this caller
            # waits for a choice. Its explicit selectors must still bypass the
            # malformed prospective defaults when it rechecks readiness.
            codex_fixture.credentials(explicit_config / "codex.json")
            os.write(master, b"d\n")
            welcome = read_terminal(master, "› ", timeout=10)
            assert all(noise not in welcome for noise in ("Session:", "Provider:", "Model:", "request:")), welcome
            record, = (explicit_config / "requests").glob("*.json")
            saved = json.loads(record.read_bytes())
            assert saved["session"] == f"rui/{record.stem}" and saved["configuration"]["model"] == {"state": "value", "value": "gpt-6-luna"}, saved
            binding = terminal_step(master, "/status", "Session: ", composer=True)
            assert f"Session: {saved['session']}" in binding and "Provider: codex" in binding and "Model: gpt-6-luna" in binding and permission_row(binding, "bypass"), binding
            assert malformed.read_text() == "version=9\n"
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert explicit.wait(timeout=5) == 0
        finally:
            dispose_all(lambda: stop_process(explicit, timeout=5),
                        lambda: os.close(ready_read), lambda: os.close(master), lambda: os.close(slave))
        # A renewal-due opaque credential arrives while the prompt is open. It
        # remains usable for creation.
        (explicit_config / "codex.json").unlink()
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        try:
            expiring = subprocess.Popen([str(fixture.RUI), "--store", str(store),
                "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
                env={**os.environ, "HOME": str(explicit_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            dispose_all(lambda: os.close(master), lambda: os.close(slave), lambda: os.close(ready_read))
            raise
        finally:
            dispose_all(lambda: os.close(ready_write))
        try:
            assert "No locally ready provider" in provider_prompt(master, ready_read)
            credential_file = explicit_config / "codex.json"
            codex_fixture.credentials(credential_file, access="synthetic-opaque-access")
            renewed_at = int(time.time()) - 8 * 24 * 60 * 60 - 1
            credential_file.write_text(credential_file.read_text().replace("expires_at=4102444800", "expires_at=0").replace("refreshed_at=1750000000", f"refreshed_at={renewed_at}"))
            assert defaults(preferences_home, environment={"RUI_CODEX_CREDENTIAL_FILE": str(credential_file)})["local_credential"] == "renewal_due"
            welcome = terminal_step(master, "d", "› ")
            assert "Session:" not in welcome and "Permission:" not in welcome, welcome
            binding = terminal_step(master, "/status", "Session: ", composer=True)
            assert "Session: rui/" in binding and permission_row(binding, "bypass"), binding
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert expiring.wait(timeout=5) == 0
            assert malformed.read_text() == "version=9\n"
        finally:
            dispose_all(lambda: stop_process(expiring, timeout=5),
                        lambda: os.close(ready_read), lambda: os.close(master), lambda: os.close(slave))
        longer_store = state / "another-longer-store-selector"
        other_host = fixture.start_host(longer_store, url)
        try:
            for index, (before, after) in enumerate(((store, longer_store), (longer_store, store))):
                changing_home = state / f"changing-home-{index}"
                changing_home.mkdir()
                defaults(changing_home, "--store", before,
                    "--provider", "codex", "--model", "gpt-6-luna")
                master, slave = open_pty()
                ready_read, ready_write = os.pipe()
                try:
                    changing = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                        env={**os.environ, "HOME": str(changing_home),
                            "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                        pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
                except BaseException:
                    dispose_all(lambda: os.close(master), lambda: os.close(slave), lambda: os.close(ready_read))
                    raise
                finally:
                    dispose_all(lambda: os.close(ready_write))
                try:
                    assert "No locally ready provider" in provider_prompt(master, ready_read)
                    defaults(changing_home, "--store", after)
                    codex_fixture.credentials(changing_home / ".config/rui/codex.json")
                    welcome = terminal_step(master, "d", "› ")
                    assert all(noise not in welcome for noise in ("Diagnostics:", "request:", "Session:")), welcome
                    record, = (changing_home / ".config/rui/requests").glob("*.json")
                    handle = record.stem
                    selected = json.loads(record.read_bytes())
                    assert selected["store"] == str(after.resolve()), selected
                    current = fixture.command("session", "inspect", "--store", after,
                        "--session", f"rui/{handle}")
                    assert current["session"]["model"] == "gpt-6-luna", current
                    assert "Detached." in terminal_step(master, "/exit", "Detached.")
                    assert changing.wait(timeout=5) == 0
                finally:
                    dispose_all(lambda: stop_process(changing, timeout=5),
                                lambda: os.close(ready_read), lambda: os.close(master), lambda: os.close(slave))
        finally:
            fixture.stop_host(other_host)
        codex_fixture.credentials(credential)
        for tools, mode, warning in (("none", "bypass", False), ("edit", "bypass", False),
                                     ("bash,edit", "bypass", True), ("bash", "ask", False)):
            warning_ref = f"warnings/{tools}/{mode}"
            admit(preferences_home, "session", "configure", "--store", store, "--session", warning_ref,
                  "--workspace", workspace, "--provider", "codex", "--model", "model-a",
                  "--tools", tools, "--permission-mode", mode)
            listing = json.loads(run(preferences_home, "session", "list", "--store", store, "--all"))
            selected, = [row for row in listing["sessions"] if row["reference"] == warning_ref]
            assert selected["permission_mode"] == mode and selected["tools"] == ([] if tools == "none" else tools.split(",")), selected
            with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store), "--", warning_ref],
                env={**os.environ, "HOME": str(preferences_home)},
            ) as (caller, master):
                welcome = read_terminal(master, "› ")
                assert "Permission:" not in welcome, welcome
                assert "Bash runs without" not in welcome, ("bypass is quiet", welcome)
                assert "Bash commands can run without asking you" not in welcome, welcome
                status = status_frame(master, warning_ref)
                assert permission_row(status, mode), status
                assert fixture.command("session", "inspect", "--store", store, "--session", warning_ref)["session"]["permission_mode"] == mode
                assert mode == "bypass" or "without asking" not in status, status
                terminal_step(master, "/exit", "Detached.")
                assert caller.wait(timeout=5) == 0
        created = []
        records = preferences_home / ".config/rui/requests"
        for fresh in range(2):
            before_records = set(records.glob("*.json"))
            master, slave = open_pty()
            caller = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(preferences_home)},
                stdin=slave, stdout=slave, stderr=slave)
            try:
                welcome = read_terminal(master, "› ")
                assert "Attached to the ready Host" not in welcome and "Diagnostics:" not in welcome, welcome
                new_records = set(records.glob("*.json")) - before_records
                assert len(new_records) == 1, new_records
                handle = new_records.pop().stem
                reference = f"rui/{handle}"
                saved = json.loads((records / f"{handle}.json").read_bytes())
                assert saved["require_model"] is True and saved["store"] == str(store.resolve())
                assert saved["session"] == reference and saved["configuration"]["workspace"] == {"state": "value", "value": str(workspace.resolve())}
                mode = "bypass"
                assert saved["configuration"]["tools"] == {"state": "value", "value": ["bash"]} and saved["configuration"]["permission_mode"] == {"state": "value", "value": mode}
                assert all(noise not in welcome for noise in ("request:", "New Session intent:", reference, "Workspace:", "Provider:", "Permission:")), welcome
                status = terminal_step(master, "/status", "Session: ", composer=True)
                assert f"Session: {reference}" in status and permission_row(status, "bypass"), status
                assert "Bash runs without" not in welcome, ("bypass is quiet", welcome)
                assert "Bash commands can run without asking you" not in welcome, welcome
                current = fixture.command("session", "inspect", "--store", store, "--session", reference)
                assert current["session"]["permission_mode"] == mode, current
                assert current["session"]["workspace"] == str(workspace.resolve()), current
                assert current["session"]["provider"] == "codex" and current["session"]["model"] == "gpt-6-luna", current
                assert json.loads(run(preferences_home, "request", "recover", handle))["answer"]["replayed"] is True
                created.append(reference)
                assert "Detached." in terminal_step(master, "/exit", "Detached.")
                assert caller.wait(timeout=5) == 0
            finally:
                dispose_all(lambda: stop_process(caller, timeout=5),
                            lambda: os.close(master), lambda: os.close(slave))
        assert len(set(created)) == 2, "independent new intent reused a reference"
        blocked_home = state / "blocked-capture-home"
        blocked_config = blocked_home / ".config/rui"
        blocked_config.mkdir(parents=True, mode=0o700)
        (blocked_config / "preferences").write_text(
            f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        (blocked_config / "preferences").chmod(0o600)
        (blocked_config / "requests").write_text("not a directory")
        codex_fixture.credentials(blocked_config / "codex.json")
        sessions_before = run(preferences_home, "session", "list", "--store", store, "--all")
        master, slave = open_pty()
        original_mode = termios.tcgetattr(slave)
        blocked = None
        try:
            blocked = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(blocked_home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            # Capture fails before the send/uncertain-admission diagnostic.
            # Keep the slave alive until all output is collected: Darwin can
            # discard unread PTY bytes when the last slave closes.
            output, errors = terminal_exit(blocked, master, timeout=20)
            assert blocked.returncode == 1 and b"error: NotDir" in errors, (output, errors)
            combined = output + errors
            assert all(text not in combined for text in (b"New Session intent", b"request: ", "› ".encode())), combined
            assert termios.tcgetattr(slave) == original_mode
            assert (blocked_config / "requests").read_text() == "not a directory"
            assert run(preferences_home, "session", "list", "--store", store, "--all") == sessions_before
        finally:
            dispose_all(lambda: stop_process(blocked, timeout=5) if blocked is not None else None,
                        lambda: os.close(master), lambda: os.close(slave))
        before = set(json.loads(run(preferences_home, "request", "list")))
        gate = state / "new-session-capture"
        master, slave = open_pty()
        interrupted = subprocess.Popen([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(preferences_home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdin=slave, stdout=slave, stderr=slave)
        try:
            fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "fresh configuration captured")
            early = os.read(master, 65536) if select.select([master], [], [], 0)[0] else b""
            assert b"New Session intent" not in early, "announced before the capture callback"
            after = set(json.loads(run(preferences_home, "request", "list")))
            assert len(after - before) == 1, (before, after)
            handle = (after - before).pop()
            captured = json.loads((preferences_home / ".config/rui/requests" / f"{handle}.json").read_text())
            assert captured["require_model"] is True, captured
            interrupted.kill()
            interrupted.wait(timeout=5)
            recovered = json.loads(run(preferences_home, "request", "recover", handle))
            assert recovered["answer"]["status"] == "accepted" and not recovered["answer"]["replayed"], recovered
            recovered_again = json.loads(run(preferences_home, "request", "recover", handle))
            assert recovered_again["answer"]["replayed"], recovered_again
            assert fixture.command("session", "inspect", "--store", store,
                "--session", f"rui/{handle}")["session"]["permission_mode"] == "bypass"
        finally:
            dispose_all(lambda: stop_process(interrupted, timeout=5),
                        lambda: os.close(master), lambda: os.close(slave))
        credential.unlink()
        initial = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert initial["selected_message"] is None and initial["recent_messages"] == [], initial
        assert "InteractiveTerminalRequired" in subprocess.run(
            [str(fixture.RUI), "session", "resume", "--store", str(store), "--", session],
            env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=5).stderr
        assert config["request"] in json.loads(run(home, "request", "list"))
        assert json.loads(run(home, "request", "recover", config["request"]))["answer"]["replayed"] is True
        assert json.loads(run(home, "request", "recover", config["request"])) == {
            "context": {"store": str(store), "session": session, "key": config["request"], "kind": "configure"},
            "answer": {"status": "accepted", "replayed": True, "session": session, "revision": "1", "created": True}}

        text = state / "input"
        text.write_text("first input")
        dropped = invoke(home, "session", "send", "--store", store, "--session", session,
            "--text", text, "--test-drop-reply", "after-commit", expect=1)
        assert dropped.stdout == "", dropped
        first = CAPTURE_NOTICE.match(dropped.stderr).group(1)
        record = home / ".config/rui/requests" / f"{first}.json"
        captured = record.read_bytes()
        assert json.loads(captured)["text"]["value"] == "first input"
        text.write_text("changed after capture")
        assert first in json.loads(run(home, "request", "list"))
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "first provider request")
        recovered = json.loads(run(home, "request", "recover", first))
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True
        assert record.read_bytes() == captured
        assert len(endpoint.requests) == 1, endpoint.requests

        # One-shot observations replace the removed waits: the original request
        # and its Session both report the same pending Action.
        progress = fixture.wait_for(lambda: (value if (value := fixture.observe(store, first).get("progress", {})).get("status")
            == "waiting_for_permission" else None), "first request attention")
        action = progress["action"]
        blocked = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert blocked["selected_message"] == first and blocked["work"]["status"] == "waiting_for_permission", blocked
        assert [entry["action"] for entry in blocked["actionable_permissions"]] == [action], blocked
        queued = admit(home, "session", "send", "--store", store, "--session", session,
            "queued behind permission")["request"]
        queued_fact = fixture.command("request", "inspect", "--store", store, "--key", queued)["observation"]
        assert queued_fact["status"] == "accepted" and "result" not in queued_fact, queued_fact
        assert queued_fact["queue"]["status"] == "queued" and queued_fact["progress"] == {
            "status": "waiting_for_permission", "action": action}, queued_fact
        scratch = state / "render-scratch"
        scratch.mkdir()
        render_environment = {"TMPDIR": str(scratch)}
        presentation = run(home, "action", "inspect", "--store", store, "--session", session, "--action", action)
        assert json.loads(presentation) == {"action": action, "call_id": control_call, "arguments": control_arguments}, presentation
        assert "\\u001b" in presentation and "\\u202e" in presentation and "\\r  " in presentation, presentation
        assert "\x1b" not in presentation and "\u202e" not in presentation and "\r" not in presentation, presentation
        terminal_safe_json(presentation)
        # Full inspection exposes the same Action identities and proposal.
        full = terminal_safe_json(run(home, "session", "inspect", "--store", store, "--session", session, "--profile", "full"))
        assert control_call in json_strings(full) and control_arguments in json_strings(full), full
        fresh_home = state / "fresh-home"
        fresh_home.mkdir()
        assert not (fresh_home / ".config").exists()
        assert json.loads(run(fresh_home, "action", "inspect", "--store", store, "--session", session,
            "--action", action, environment=render_environment)) == {"action": action, "call_id": control_call, "arguments": control_arguments}
        assert not (fresh_home / ".config").exists()
        assert list(scratch.iterdir()) == []
        unavailable = subprocess.run([str(fixture.RUI), "action", "inspect", "--store", str(store),
            "--session", session, "--action", action],
            env={**os.environ, "HOME": str(fresh_home), "TMPDIR": str(state / "missing-scratch")},
            capture_output=True, text=True, timeout=20)
        assert unavailable.returncode != 0 and unavailable.stdout == "", unavailable
        # Explicit content readers keep stdout byte-exact: a missing Action
        # reports its Host diagnostic on stderr only.
        for field in ("call-id", "arguments"):
            absent = subprocess.run([str(fixture.RUI), "action", f"read-{field}", "--store", str(store),
                "--session", session, "--action", "999999"], env={**os.environ, "HOME": str(home)},
                capture_output=True, text=True, timeout=20)
            assert absent.returncode == 1 and absent.stdout == "", (field, absent)
            terminal_safe_json(absent.stderr.splitlines()[0])
        processing = fixture.observe(store, first)
        assert processing["status"] == "accepted" and "result" not in processing, processing
        assert not counter.exists()

        lost_decision = invoke(home, "action", "allow", "--store", store, "--session", session,
            "--action", action, "--test-drop-reply", "after-commit", expect=1)
        assert lost_decision.stdout == "", lost_decision
        decision_key = CAPTURE_NOTICE.match(lost_decision.stderr).group(1)
        assert decision_key in json.loads(run(home, "request", "list"))
        recovered_decision = json.loads(run(home, "request", "recover", decision_key))["answer"]
        assert recovered_decision["status"] == "accepted" and recovered_decision["replayed"] is True
        fixture.wait_for(lambda: fixture.completed_observation(store, first), "first saved answer")
        fixture.wait_for(lambda: fixture.completed_observation(store, queued), "queued answer after permission")
        stale = admit(home, "action", "deny", "--store", store, "--session", session,
            "--action", action, expect=1)
        assert stale["admission"]["answer"]["status"] == "rejected", stale
        assert fixture.read_result(store, queued) == b"first answer"
        current = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert current["selected_message"] is None and [r["message"] for r in current["recent_messages"]] == [queued, first], current
        assert [r["outcome"] for r in current["recent_messages"]] == ["completed", "completed"], current
        settled = json.loads(run(home, "session", "inspect", "--store", store, "--session", session))
        assert settled["work"]["status"] == "completed" and settled["pending_messages"] == "0", settled
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        try:
            entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--", session],
                env={**os.environ, "HOME": str(preferences_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            dispose_all(lambda: os.close(master), lambda: os.close(slave), lambda: os.close(ready_read))
            raise
        finally:
            dispose_all(lambda: os.close(ready_write))
        try:
            greeting = read_terminal(master, "› ")
            assert all(noise not in greeting for noise in ("Session:", "Workspace:", "Provider:", "Model:", "Permission:", "Store:", queued)), greeting
            assert "\n› first input" in greeting and "\nfirst answer" in greeting, greeting
            binding = terminal_step(master, "/status", "Session: ", composer=True)
            assert f"Session: {session}" in binding and shown(f"Workspace (Bash cwd): {workspace.resolve()}", binding), binding
            assert "Provider: codex" in binding and "Model: model-a" in binding and "Permission: ask" in binding, binding
            help_text = terminal_step(master, "/help", "/result KEY", composer=True)
            for command in ("/status", "/inspect-action", "/details", "/history", "/requests", "/result KEY", "/setup", "/configure", "/exit", "Ctrl-R"):
                assert command in help_text, help_text
            assert "/wait" not in help_text and "/login" not in help_text and "rui auth login codex" in help_text, help_text
            # This Session asks: help must not describe the bypass default as its mode.
            assert "without approval" not in help_text and "/status shows whether Bash asks first" in help_text, help_text
            result = terminal_step(master, f"/result {queued}", "result: completed", composer=True)
            assert "result: completed\nfirst answer" in result, result
            terminal_step(master, "/requests", "Local recovery handles", composer=True)
            assert not (fresh_home / ".config/rui/requests").exists(), "re-entry should not require saved records"
            before_unsupported = set(json.loads(run(preferences_home, "request", "list")))
            for command, notice in (("/wait", "Work continues while you compose."),
                                    ("/login", "Login uses rui auth login codex in your shell.")):
                terminal_step(master, command, notice, composer=True)
                assert set(json.loads(run(preferences_home, "request", "list"))) == before_unsupported
            terminal_step(master, "/setup", "gpt-6-luna", composer=True)
            terminal_step(master, "/status", "Permission: ask", composer=True)
            assert not credential.exists(), "unsupported in-session login created credentials"
            terminal_step(master, "/setup --model gpt-6-luna", "Saved defaults for future Sessions", composer=True)
            terminal_step(master, "/setup --model other-model", "Saved defaults for future Sessions", composer=True)
            interactive_saved = preferences_home / ".config/rui/preferences"
            terminal_step(master, "/setup --clear-model", "Saved defaults for future Sessions", composer=True)
            assert interactive_saved.read_text().endswith("provider=codex\nmodel=\n")
            cleared_preferences = interactive_saved.read_bytes()
            for command, error in (("/setup --clear-model --model gpt-6-luna", "ConflictingPreferenceModelEdit"),
                                   ("/setup --model gpt-6-luna --clear-model", "ConflictingPreferenceModelEdit"),
                                   ('/setup --model ""', "InvalidPreferenceModel")):
                terminal_step(master, command, error, composer=True)
                assert interactive_saved.read_bytes() == cleared_preferences
            terminal_step(master, "/status", "Permission: ask", composer=True)
            active = fixture.command("session", "inspect", "--store", store, "--session", session)["session"]
            assert active["model"] == "model-a" and active["permission_mode"] == "ask", active
            terminal_step(master, "/setup --model gpt-6-luna", "Saved defaults for future Sessions", composer=True)
            spaced_store = state / "spaced store"
            spaced_store.mkdir(mode=0o700)
            terminal_step(master, f'/setup --store "{spaced_store}"', "Saved defaults for future Sessions", composer=True)
            assert defaults(preferences_home)["store"] == str(spaced_store.resolve())
            quoted_store = state / 'quoted "store"'
            quoted_store.mkdir(mode=0o700)
            escaped_store = str(quoted_store).replace('"', r'\"')
            terminal_step(master, f'/setup --store "{escaped_store}"', "Saved defaults for future Sessions", composer=True)
            assert defaults(preferences_home)["store"] == str(quoted_store.resolve())
            terminal_step(master, '/setup --store "unfinished', "Usage: /setup", composer=True)
            assert defaults(preferences_home)["store"] == str(quoted_store.resolve())
            terminal_step(master, f'/setup --store "{store}"', "Saved defaults for future Sessions", composer=True)
            terminal_step(master, "/status", "Permission: ask", composer=True)
            assert fixture.command("session", "inspect", "--store", store,
                "--session", session)["session"]["model"] == "model-a"
            terminal_step(master, "/configure --session human/other", "Usage: /configure", composer=True)
            terminal_step(master, "/configure --instructions -", "Use a file for", composer=True)
            terminal_step(master, "/configure --output-schema -", "Use a file for", composer=True)
            terminal_step(master, "/status", f"Session: {session}", composer=True)
            configured = configured_frame(master, '/configure --model "model-a"')
            assert "Configured." in configured and "request:" not in configured, configured
            for receipt in ("Store:", "Session:", "key:", "admitted:", "replayed:"):
                assert receipt not in configured, configured
            terminal_step(master, "/status", f"Session: {session}", composer=True)
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            dispose_all(lambda: stop_process(entered, timeout=5),
                        lambda: os.close(ready_read), lambda: os.close(master), lambda: os.close(slave))
        assert fixture.observe(store, queued)["result"]["status"] == "completed"
        def rejected_decision(key, replayed):
            return {"context": {"store": str(store), "session": session, "key": key, "kind": "permission_decision"},
                "request_target": {"action": action, "decision": "deny"},
                "answer": {"status": "rejected", "replayed": replayed, "session": session, "action": action,
                    "decision": "deny", "code": "action_not_pending"}}
        recovered_stale = json.loads(invoke(home, "request", "recover", stale["request"], expect=1).stdout)
        assert recovered_stale == rejected_decision(stale["request"], True), recovered_stale
        stale_default = admit(home, "action", "deny", "--store", store, "--session", session,
            "--action", action, expect=1)
        assert stale_default["admission"] == rejected_decision(stale_default["request"], False), stale_default
        assert run(home, "request", "read-result", first, environment=render_environment) == "first answer"
        assert fixture.observe(store, first)["result"]["status"] == "completed"
        assert list(scratch.iterdir()) == []
        assert counter.read_text() == "x"

        before = set(json.loads(run(home, "request", "list")))
        gate = state / "captured-before-handle"
        caller = subprocess.Popen(
            [str(fixture.RUI), "session", "send", "--store", str(store), "--session", session,
             "--text", str(text)],
            env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "durable capture before handle output")
        after = set(json.loads(run(home, "request", "list")))
        assert len(after - before) == 1, (before, after)
        second = (after - before).pop()
        assert caller.poll() is None
        assert fixture.command("request", "inspect", "--store", store,
            "--key", second)["observation"]["status"] == "absent"
        caller.kill()
        output, _ = caller.communicate(timeout=5)
        assert caller.returncode == -signal.SIGKILL and output == b"", output
        assert second != first
        text.unlink()
        initial_recovery = json.loads(run(home, "request", "recover", second))["answer"]
        assert initial_recovery["status"] == "accepted" and initial_recovery["replayed"] is False
        fixture.wait_for(lambda: fixture.completed_observation(store, second), "second saved answer")
        assert fixture.read_result(store, first) == b"first answer"
        assert fixture.read_result(store, second) == b"second answer"
        assert counter.read_text() == "x" and len(endpoint.requests) == 3

        fixture.stop_host(host)
        host = fixture.start_host(store, url, active_capacity=2)
        sibling_session = "human/siblings"
        sibling_config = admit(home, "session", "configure", "--store", store, "--session", sibling_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")["admission"]
        assert sibling_config["context"] == {"store": str(store), "session": sibling_session,
            "key": sibling_config["context"]["key"], "kind": "configure"}, sibling_config
        assert sibling_config["answer"]["status"] == "accepted" and sibling_config["answer"]["created"] is True, sibling_config
        sibling_key = admit(home, "session", "send", "--store", store, "--session", sibling_session,
            "two independent Actions")["request"]
        def two_actions():
            candidate = fixture.command("session", "inspect", "--store", store, "--session", sibling_session)
            return candidate if len(candidate["actionable_permissions"]) == 2 else None

        report = fixture.wait_for(two_actions, "two actionable siblings")
        pending, running = [row["action"] for row in report["actionable_permissions"]]
        assert report["selected_message"] == sibling_key, report
        attention = fixture.observe(store, sibling_key)["progress"]
        assert attention == {"status": "waiting_for_permission", "action": pending}, attention
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", sibling_session], env={**os.environ, "HOME": str(fresh_home),
                "RUI_TEST_ACTION_READY_FD": str(ready_write)}, pass_fds=(ready_write,),
            stdin=slave, stdout=slave, stderr=slave)
        try:
            deadline = time.monotonic() + 15
            opening = read_terminal(master, "Type a + Enter to allow once · d + Enter to deny", timeout=deadline - time.monotonic())
            opening += action_ready(ready_read, master, timeout=deadline - time.monotonic())
            deadline = time.monotonic() + 15
            os.write(master, b"/status\n")
            # The page pauses approval; a user returns to the Action after it.
            status = read_terminal(master, "Approval paused · Esc returns to Action", timeout=deadline - time.monotonic())
            status = current_screen(master)
            action_ready(ready_read, master, timeout=deadline - time.monotonic())
            assert status.count("Action requiring attention: ") == 2, status
            assert f"Action requiring attention: {pending}" in status and f"Action requiring attention: {running}" in status, status
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            dispose_all(lambda: stop_process(entered, timeout=5),
                        *(lambda fd=fd: os.close(fd) for fd in (master, ready_read, ready_write, slave)))
        run(home, "action", "allow", "--store", store, "--session", sibling_session,
            "--action", running)
        fixture.wait_for(lambda: sibling_started.exists(), "approved sibling in flight")
        attention = fixture.wait_for(lambda: (value if (value := fixture.observe(store, sibling_key)).get("progress", {}).get("action")
            == pending else None), "sibling attention while another Action runs")
        assert attention["progress"] == {"status": "in_flight", "action": pending}, attention
        assert attention["status"] == "accepted" and "result" not in attention, attention
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", sibling_session], env={**os.environ, "HOME": str(home),
                "RUI_TEST_ACTION_READY_FD": str(ready_write)}, pass_fds=(ready_write,),
            stdin=slave, stdout=slave, stderr=slave)
        try:
            waiting = read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
            waiting += action_ready(ready_read, master)
            assert "\n? Run Bash · Write first effect\n" in waiting and "\n  $ printf x >> effect-count\n" in waiting, waiting
            assert counter.read_text() == "x" and not sibling_effect.exists(), "opening authorized pending sibling"
            run(home, "action", "deny", "--store", store, "--session", sibling_session,
                "--action", pending)
            sibling_release.touch()
            rejected = terminal_step(master, "a", "action_not_pending")
            assert "Decision rejected" in rejected and counter.read_text() == "x", rejected
            if "› " not in rejected.split("action_not_pending", 1)[1]:
                rejected += read_terminal(master, "› ")
            records = home / ".config/rui/requests"
            sealed = {path: path.read_bytes() for path in records.glob("*.json")}
            oversized = terminal_bulk(master, "Y" * (64 * 1024 + 1), "input too long")
            assert "Draft cleared. Enter a shorter message." in oversized, oversized[-1000:]
            os.write(master, "next café!\x1b[D\x1b[DX".encode())
            rejected += oversized + read_terminal(master, "› next cafXé!")
            busy = terminal_step(master, "", "Keep editing;", composer=True)
            assert "/discard" in busy and "Ctrl-R" not in busy, busy
            os.write(master, b"\x12Y")
            rejected += busy + read_terminal(master, "› next cafXYé!")
            assert {path: path.read_bytes() for path in records.glob("*.json")} == sealed
            # Slash commands are composition: replacing this draft is an
            # explicit caller edit, not discard consuming a separate draft.
            caught_up = rejected + terminal_step(master, "\x01\x0b/discard",
                "› " if "siblings done" in rejected else "siblings done", composer=True)
            assert "siblings done" in caught_up and counter.read_text() == "x", caught_up
            assert {path: path.read_bytes() for path in records.glob("*.json")} == sealed
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            dispose_all(sibling_release.touch, lambda: stop_process(entered, timeout=5),
                        *(lambda fd=fd: os.close(fd) for fd in (master, ready_read, ready_write, slave)))
        fixture.wait_for(lambda: fixture.completed_observation(store, sibling_key), "sibling outcome")
        assert fixture.read_result(store, sibling_key) == b"siblings done"
        assert sibling_effect.read_text() == "y" and counter.read_text() == "x"

        failure_release = threading.Event()
        endpoint.responses.extend([
            (fixture.ResponseSpec(b"permanent failure", {}, 422), failure_release),
            fixture.sse_answer("successor-answer", "successor-reason", "successor-message", "successor done")[0],
        ])
        failure_session = "human/failure"
        run(home, "session", "configure", "--store", store, "--session", failure_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        failed_key = admit(home, "session", "send", "--store", store, "--session", failure_session,
            "first failing Turn")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 6, "held first failed Turn")
        queued_key = admit(home, "session", "send", "--store", store, "--session", failure_session,
            "queued successor")["request"]
        waiting = fixture.observe(store, queued_key)
        assert waiting["status"] == "accepted" and waiting["queue"]["status"] == "queued" and "result" not in waiting, waiting
        failure_release.set()
        failed_result = fixture.wait_for(lambda: fixture.command("request", "inspect", "--store", store,
            "--key", failed_key)["observation"].get("result"), "failed first Turn")
        assert failed_result == {"status": "failed", "code": "provider_http_422"}, failed_result
        fixture.wait_for(lambda: fixture.completed_observation(store, queued_key), "queued successor")
        assert fixture.read_result(store, queued_key) == b"successor done"
        with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", failure_session], env={**os.environ, "HOME": str(home)},
        ) as (entered, master):
            read_terminal(master, "› ")
            failed = terminal_step(master, f"/result {failed_key}", "result: failed", composer=True)
            assert "result: failed" in failed, failed
            assert "code: provider_http_422" in failed and "successor done" not in failed, failed
            result = terminal_step(master, f"/result {queued_key}", "result: completed", composer=True)
            assert "result: completed\nsuccessor done" in result, result
            terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0

        stop_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("stopped-answer", "stopped-reason",
            "stopped-message", "must not appear")[0], stop_release))
        stop_session = "human/stopped"
        run(home, "session", "configure", "--store", store, "--session", stop_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        stopped_key = admit(home, "session", "send", "--store", store, "--session", stop_session,
            "running when stopped")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 8, "held stopped Turn")
        excluded_key = admit(home, "session", "send", "--store", store, "--session", stop_session,
            "queued when stopped")["request"]
        excluded = fixture.observe(store, excluded_key)
        assert excluded["status"] == "accepted" and excluded["queue"]["status"] == "queued" and "result" not in excluded, excluded
        stopped = fixture.command("session", "stop", "--store", store, "--session", stop_session,
            "--record", state / "stop.json", "--key", "human-stop")
        assert stopped["answer"]["status"] == "accepted", stopped
        stop_release.set()
        cancelled = fixture.wait_for(lambda: fixture.command("request", "inspect", "--store", store,
            "--key", stopped_key)["observation"].get("result"), "stopped Turn")
        assert cancelled["status"] == "cancelled", cancelled
        assert fixture.observe(store, excluded_key)["result"] == {"status": "cancelled", "code": "session_stopped"}

        rejected = admit(home, "session", "send", "--store", store, "--session", "human/absent",
            "unknown session", expect=1)
        assert rejected["admission"]["answer"] == {"status": "rejected", "replayed": False,
            "session": "human/absent", "code": "unknown_session"}, rejected
        refused = fixture.observe(store, rejected["request"])
        assert refused["status"] == "rejected" and refused["code"] == "unknown_session", refused
        replayed_rejection = json.loads(invoke(home, "request", "recover", rejected["request"], expect=1).stdout)
        assert replayed_rejection == {"context": {"store": str(store), "session": "human/absent",
            "key": rejected["request"], "kind": "message"}, "answer": {"status": "rejected", "replayed": True,
            "session": "human/absent", "code": "unknown_session"}, "input": rejected["admission"]["input"]}, replayed_rejection
        assert rejected["admission"]["input"]["bytes"] == str(len(b"unknown session")), rejected

        large_answer = "x" * 4095 + "🍰" + "y" * (128 * 1024)
        endpoint.responses.append(fixture.sse_answer("large-answer", "large-reason",
            "large-message", large_answer)[0])
        large_session = "human/large"
        run(home, "session", "configure", "--store", store, "--session", large_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        large_key = admit(home, "session", "send", "--store", store, "--session", large_session,
            "large output")["request"]
        fixture.wait_for(lambda: fixture.completed_observation(store, large_key), "large saved answer")
        reader = subprocess.Popen([str(fixture.RUI), "request", "read-result", large_key],
            env={**os.environ, "HOME": str(home), **render_environment},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert read_pipe_output(reader.stdout, count=256) == large_answer.encode()[:256]
            assert reader.poll() is None, "large result should block on unread stdout"
            assert list(scratch.iterdir()) == [], "streaming must not leave a named payload"
        finally:
            stop_process(reader, timeout=5)
        assert reader.returncode == -signal.SIGKILL and list(scratch.iterdir()) == []
        assert run(home, "request", "read-result", large_key, environment=render_environment) == large_answer

        fixture.crash_host(host, state, "human-cli-crash")
        failed_observation = run(home, "request", "inspect", first, success=False)
        assert failed_observation == "", failed_observation
        host = fixture.start_host(store, url)
        assert json.loads(run(home, "request", "recover", first))["answer"]["replayed"] is True
        assert fixture.read_result(store, first) == b"first answer"
        recovered_session = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert recovered_session["selected_message"] is None
        assert [row["message"] for row in recovered_session["recent_messages"]] == [second, queued, first]
        assert counter.read_text() == "x" and sibling_effect.read_text() == "y" and len(endpoint.requests) == 9

        endpoint.responses.extend([
            (fixture.sse_answer("race-prior", "race-prior-reason", "race-prior-message", "prior done")[0], race_predecessor_release),
            (fixture.sse_answer("race-a", "race-a-reason", "race-a-message", "A done")[0], race_message_release),
            fixture.sse_tool_calls("race-b", [("bash", "race-b-call", arguments)]),
            fixture.sse_answer("race-b-done", "race-b-done-reason", "race-b-done-message", "B done")[0],
        ])
        race_session = "human/follow-race"
        run(home, "session", "configure", "--store", store, "--session", race_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        prior_receipt = invoke(home, "session", "send", "--store", store, "--session", race_session, "prior")
        prior = CAPTURE_NOTICE.match(prior_receipt.stderr).group(1)
        prior_answer = json.loads(prior_receipt.stdout)
        assert prior_answer["context"] == {"store": str(store), "session": race_session, "key": prior, "kind": "message"}, prior_answer
        assert prior_receipt.stderr == CAPTURE_NOTICE.match(prior_receipt.stderr).group(0), prior_receipt.stderr
        fixture.wait_for(lambda: len(endpoint.requests) == 10, "held predecessor request")
        message_a = admit(home, "session", "send", "--store", store, "--session", race_session, "A")["request"]
        queued_a = fixture.observe(store, message_a)
        assert queued_a["queue"]["status"] == "queued" and "result" not in queued_a, queued_a
        race_predecessor_release.set()
        fixture.wait_for(lambda: len(endpoint.requests) == 11, "A processing request")
        race_message_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, message_a), "A outcome before Current")
        fixture.wait_for(lambda: fixture.completed_observation(store, prior), "predecessor completion")
        message_b = admit(home, "session", "send", "--store", store, "--session", race_session, "B")["request"]
        def b_action():
            report = fixture.command("session", "inspect", "--store", store, "--session", race_session)
            return report["actionable_permissions"][0]["action"] if report["actionable_permissions"] else None

        action_b = fixture.wait_for(b_action, "B permission before Current")
        assert fixture.command("request", "inspect", "--store", store, "--key", message_a)["observation"]["result"]["status"] == "completed"
        assert fixture.observe(store, message_a)["target"] == race_session
        assert fixture.read_result(store, message_a) == b"A done"
        assert b_action() == action_b
        assert json.loads(run(home, "action", "inspect", "--store", store, "--session", race_session,
            "--action", action_b))["call_id"] == "race-b-call"
        denied = admit(home, "action", "deny", "--store", store, "--session", race_session,
            "--action", action_b)
        assert denied["admission"]["answer"]["status"] == "accepted", denied
        fixture.wait_for(lambda: fixture.completed_observation(store, message_b), "B outcome after decision")
        control_call = "interactive-bash\x1b[1Ghidden\u202e"
        argument_prefix = '{"cmd":"printf x >> effect-count # '
        padded_arguments = json.dumps({"cmd": "printf x >> effect-count # " +
            "A" * (4095 - len(argument_prefix)) + "é", "description": "Write interactive effect", "timeout_ms": None},
            ensure_ascii=False, separators=(",", ":")) + "\r  "
        assert padded_arguments.encode()[4095:4097] == "é".encode()
        endpoint.responses.extend([
            fixture.sse_tool_calls("interactive-call", [("bash", control_call, padded_arguments)]),
            fixture.sse_answer("interactive-answer", "interactive-reason", "interactive-message",
                "interactive complete")[0],
        ])
        interactive = "human/interactive"
        run(home, "session", "configure", "--store", store, "--session", interactive,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        # Tall enough that the whole 4 KiB command is one committed frame.
        master, slave = open_pty(80, 100)
        ready_read, ready_write = os.pipe()
        try:
            entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", interactive], env={**os.environ, "HOME": str(home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            dispose_all(lambda: os.close(master), lambda: os.close(slave), lambda: os.close(ready_read))
            raise
        finally:
            dispose_all(lambda: os.close(ready_write))
        try:
            assert "Permission:" not in read_terminal(master, "› ")
            os.write(master, b"interactive request\na\n")
            proposal = read_terminal(master, "Type a + Enter to allow once · d + Enter to deny")
            proposal += action_ready(ready_read, master)
            assert counter.read_text() == "x", "pasted typeahead approved an unseen Action"
            assert "\n› interactive request" in proposal, proposal
            assert "\n? Run Bash · Write interactive effect\n" in proposal, proposal
            assert shown_bash_command(master) == json.loads(padded_arguments)["cmd"], proposal
            assert_permission_workspace(proposal, workspace.resolve())
            assert "call ID:" not in proposal and "request:" not in proposal and "return:" not in proposal, proposal
            assert "é" in proposal and "\u202e" not in proposal and "hidden" not in proposal, proposal
            interactive_key = fixture.command("session", "inspect", "--store", store, "--session", interactive)["selected_message"]
            assert interactive_key is not None, proposal
            assert interactive_key in json.loads(run(home, "request", "list")), "hidden receipt must remain recoverable"
            current_action = fixture.command("session", "inspect", "--store", store, "--session", interactive)
            action_id = current_action["actionable_permissions"][0]["action"]
            assert [item["action"] for item in current_action["actionable_permissions"]] == [action_id], current_action
            terminal_step(master, "/inspect-action", "Approval paused · Esc returns to Action")
            inspection = settle_screen(master, quiet=0.5)
            # The JSON string wraps across page rows; rejoin as for exports.
            rows = inspection.split("\n")
            start = next(index for index, row in enumerate(rows) if row.startswith("Bash arguments: "))
            shown_arguments = rows[start].removeprefix("Bash arguments: ")
            previous = rows[start]
            for row in rows[start + 1:]:
                if not row or row.startswith("Approval paused"):
                    break
                shown_arguments += ("" if len(previous) >= 80 else " ") + row
                previous = row
            # Later page rows may follow the string without a blank row.
            assert json.JSONDecoder().raw_decode(shown_arguments)[0] == padded_arguments, inspection
            action_ready(ready_read, master)
            assert "\\r  " in inspection and "\u202e" not in inspection, inspection
            exact = json.loads(run(home, "action", "inspect", "--store", store, "--session", interactive,
                "--action", action_id))
            assert exact == {"action": action_id, "call_id": control_call, "arguments": padded_arguments}, exact
            mismatch = admit(home, "action", "allow", "--store", store, "--session", session,
                "--action", action_id, expect=1)
            assert mismatch["admission"]["answer"]["status"] == "rejected", mismatch
            assert mismatch["admission"]["answer"]["code"] == "target_mismatch", mismatch
            records = home / ".config/rui/requests"
            before_choice = set(records.glob("*.json"))
            for invalid in ("l", " a ", "\x1b[200~a\x1b[201~", ""):
                # A repeated rejection redraws nothing; readiness is the boundary.
                os.write(master, (invalid + "\n").encode())
                rejected_choice = action_ready(ready_read, master)
                rejected_choice += "\n" + current_screen(master)
                # The fresh explicit choice is the next action; a no-op need
                # not add another notice to it. Durable effects are the oracle.
                assert "Type a + Enter to allow once · d + Enter to deny" in rejected_choice, (invalid, rejected_choice)
                assert counter.read_text() == "x", "non-exact choice approved an Action"
                assert set(records.glob("*.json")) == before_choice, "no-op choice captured authorization"
                assert current_screen(master).count("? Run Bash") == 1, "no-op repeated the command"
            completed_turn = terminal_step(master, "a", "interactive complete", composer=True)
            assert "\ninteractive complete" in completed_turn and "result:" not in completed_turn and "request:" not in completed_turn, completed_turn
            decision_record, = set(records.glob("*.json")) - before_choice
            saved_decision = json.loads(decision_record.read_bytes())
            assert saved_decision["action"] == action_id and saved_decision["decision"] == "allow_once" and saved_decision["session"] == interactive, saved_decision
            assert json.loads(run(home, "request", "recover", decision_record.stem))["answer"]["replayed"] is True
            # The pasted chat suffix remains a draft, not approval or another
            # submission. Clear only that unsent draft before diagnostics.
            result = terminal_step(master, "\x15/result " + interactive_key, "result: completed", composer=True)
            assert "result: completed\ninteractive complete" in result, result
            terminal_step(master, "/status", "Recent messages", composer=True)
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON, "terminal mode not restored"
            assert counter.read_text() == "xx", counter.read_text()
        finally:
            dispose_all(lambda: stop_process(entered, timeout=5),
                        lambda: os.close(ready_read), lambda: os.close(master), lambda: os.close(slave))
        control_session = "human/name\n\x1b[2J\u202e"
        terminal_safe_json(run(home, "session", "configure", "--store", store, "--session", control_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a"))
        # Current inspection and listing carry the Session's own name.
        current = terminal_safe_json(run(home, "session", "inspect", "--store", store, "--session", control_session))
        assert control_session in json_strings(current), current
        listed = terminal_safe_json(run(home, "session", "list", "--store", store, "--all"))
        assert control_session in [entry["reference"] for entry in listed["sessions"]], listed
        with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", control_session], env={**os.environ, "HOME": str(home)},
        ) as (entered, master):
            greeting = read_terminal(master, "› ")
            assert "Session:" not in greeting, greeting
            assert "\x1b[2J" not in greeting and "\u202e" not in greeting, greeting
            status = terminal_step(master, "/status", "Session: ", composer=True)
            assert "Session: human/name\\n\\x1b[2J\\u202e" in status, status
            assert "\x1b[2J" not in status and "\u202e" not in status, status
            farewell = terminal_step(master, "/exit", "Resume: ")
            assert entered.wait(timeout=5) == 0
            resume = farewell.split("Resume: ", 1)[1].split("\n", 1)[0]
            assert "\x1b" not in resume and "\u202e" not in resume, resume
        # Execute the printed command, not a reconstructed equivalent. Both
        # exact selectors must survive shell quoting and changed defaults.
        other_store = workspace / "unused-store"
        other_store.mkdir(mode=0o700)
        defaults(home, "--store", other_store)
        resume_bin = state / "resume-bin"
        resume_bin.mkdir()
        (resume_bin / "rui").symlink_to(fixture.RUI)
        with terminal_process(["bash", "-c", "exec " + resume],
            env={**os.environ, "HOME": str(home),
                 "PATH": str(resume_bin) + os.pathsep + os.environ["PATH"]},
        ) as (entered, master):
            read_terminal(master, "› ")
            resumed = terminal_step(master, "/status", "Session: ", composer=True)
            assert "Session: human/name\\n\\x1b[2J\\u202e" in resumed, resumed
            assert shown(f"Store: {store}\n", resumed), resumed
            terminal_step(master, "/exit", "Resume: ")
            assert entered.wait(timeout=5) == 0
            defaults(home, "--store", store)
        unsafe_session = "human/unsafe-key"
        unsafe_key = "message\n\x1b[2J\u202e"
        unsafe_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("unsafe-answer", "unsafe-reason",
            "unsafe-message", "safe result")[0], unsafe_release))
        run(home, "session", "configure", "--store", store, "--session", unsafe_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        unsafe_text = state / "unsafe-input"
        unsafe_text.write_text("report status")
        run(home, "session", "send", "--store", store, "--session", unsafe_session,
            "--record", state / "unsafe-record.json", "--key", unsafe_key, "--text", unsafe_text)
        fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store,
            "--session", unsafe_session)["selected_message"] == unsafe_key, "unsafe key selected")
        try:
            selected_report = run(home, "session", "inspect", "--store", store, "--session", unsafe_session)
            assert json.loads(selected_report)["selected_message"] == unsafe_key, selected_report
            assert "\x1b" not in selected_report and "\n" not in selected_report.rstrip("\n"), selected_report
            with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", unsafe_session], env={**os.environ, "HOME": str(home)},
            ) as (entered, master):
                read_terminal(master, "› ")
                status = terminal_step(master, "/status", "Session: ", composer=True)
                assert "Current message: message\\n\\x1b[2J\\u202e" in status, status
                assert "\x1b[2J" not in status and "\u202e" not in status, status
                assert "Detached." in terminal_step(master, "/exit", "Detached.")
                assert entered.wait(timeout=5) == 0
        finally:
            unsafe_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, unsafe_key), "unsafe key result")
        assert fixture.command("session", "inspect", "--store", store,
            "--session", unsafe_session)["recent_messages"][0]["message"] == unsafe_key
        with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", unsafe_session], env={**os.environ, "HOME": str(home)},
        ) as (entered, master):
            greeting = read_terminal(master, "› ")
            assert "Session:" not in greeting and "\nsafe result" in greeting, greeting
            status = terminal_step(master, "/status", "Session: ", composer=True)
            assert "Session: human/unsafe-key" in status, status
            assert "message\\n\\x1b[2J\\u202e: completed" in status, status
            assert "\x1b[2J" not in status and "\u202e" not in status, status
            assert "Detached." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        empty_session = "human/empty-key"
        run(home, "session", "configure", "--store", store, "--session", empty_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        empty_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("empty-answer", "empty-reason", "empty-message",
            "empty key answer")[0], empty_release))
        empty_input = state / "empty-input"
        empty_input.write_text("empty key input")
        admission = json.loads(run(home, "session", "send", "--store", store, "--session", empty_session,
            "--record", state / "empty-record.json", "--key", "", "--text", empty_input))
        assert admission["answer"]["status"] == "accepted", admission
        fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store,
            "--session", empty_session)["work"]["status"] == "in_flight", "empty key active")
        current = fixture.command("session", "inspect", "--store", store, "--session", empty_session)
        assert current["selected_message"] == "", current
        try:
            assert "result" not in fixture.observe(store, ""), "empty key completed before release"
            empty_release.set()
            fixture.wait_for(lambda: fixture.completed_observation(store, ""), "empty key result")
            assert fixture.read_result(store, "") == b"empty key answer"
        finally:
            empty_release.set()
        current = fixture.command("session", "inspect", "--store", store, "--session", empty_session)
        assert current["selected_message"] is None and current["recent_messages"][0]["message"] == "", current
        long_input_case(home, store, workspace, endpoint, host)
        editor_session = "human/editor"
        run(home, "session", "configure", "--store", store, "--session", editor_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        cases = [
            ("first second\x1b\x7fZ", "first Z"),
            ("A中e\u0301🧑‍🌾\x7f", "A中e\u0301"),
            ("\x1b[200~line1\nline2\x1b[201~", "line1\nline2"),
            ("\x1b[200~a\n\u0301\x1b[201~\x01\x7f\x7fZ", "Z"),
            ("ab\x01\x04\x05\x04", "b"),
            ("ask src/foo-bar\x17", "ask "),
            ("\x1b[123;4~Z", "Z"),
            ("ok\x1bZ", "ok"),
            ("abc\x1b[D\x1b[DZ", "aZbc"),
            ("\x1b[200~line1\nline2\x1b[201~\x1b[A\x01X", "Xline1\nline2"),
        ]
        endpoint.responses.extend(fixture.sse_answer(f"editor-answer-{i}", f"editor-reason-{i}",
            f"editor-message-{i}", f"edited {i}")[0] for i in range(len(cases)))
        master, slave = open_pty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 2048, 0, 0))
        entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", editor_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        try:
            read_terminal(master, "› ")
            for index, (typed, expected) in enumerate(cases):
                if index == 0:
                    os.write(master, b"first second\x1b\x7f")
                    read_terminal(master, "› first", composer=True)
                    observed = terminal_step(master, "Z", f"edited {index}")
                elif index == 1:
                    os.write(master, typed.encode())
                    read_terminal(master, "› A中\u00e9")  # Cells hold the NFC cluster.
                    observed = terminal_step(master, "", f"edited {index}")
                elif typed == "abc\x1b[D\x1b[DZ":
                    os.write(master, b"abc\x1b[")
                    time.sleep(0.2)  # A recognized CSI must outlive the bare-ESC ambiguity timeout.
                    observed = terminal_step(master, "D\x1b[DZ", f"edited {index}")
                else:
                    observed = terminal_step(master, typed, f"edited {index}")
                assert f"edited {index}" in observed, observed
                if index == 2:
                    assert "\n› line1\n  line2" in "\n".join(map(untimed, observed.split("\n"))), observed
                    assert "\nedited 2" in observed, observed
                if "› " not in observed.split(f"edited {index}", 1)[1]:
                    await_screen(master, "", composer=True)
                body = json.loads(endpoint.requests[-1])
                actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user")
                assert actual == expected, (typed, expected, actual)
            for index, (cluster, count) in enumerate((("a", 1000), ("e\u0301", 500))):
                marker = f"burst edited {index}"
                endpoint.responses.append(fixture.sse_answer(f"burst-answer-{index}",
                    f"burst-reason-{index}", f"burst-message-{index}", marker)[0])
                observed = terminal_bulk(master, cluster * count + "\x7f" * count + "Z", marker)
                assert terminal_bulk.received < 100_000, ("tail deletion repainted the whole draft per key", terminal_bulk.received)
                body = json.loads(endpoint.requests[-1])
                actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                    if item.get("role") == "user")
                assert actual == "Z", actual
                if "› " not in observed.split(marker, 1)[1]:
                    await_screen(master, "", composer=True)
            endpoint.responses.append(fixture.sse_answer("paced-answer", "paced-reason",
                "paced-message", "paced edited")[0])
            os.write(master, b"a" * 100)
            read_terminal(master, "a" * 100)
            for _ in range(100):
                os.write(master, b"\x7f")
                time.sleep(0.025)  # Longer than the editor's repaint window.
            observed = terminal_step(master, "Z", "paced edited")
            assert "\n› Z" in observed, observed
            body = json.loads(endpoint.requests[-1])
            actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user")
            assert actual == "Z", actual
            if "› " not in observed.split("paced edited", 1)[1]:
                await_screen(master, "", composer=True)
            endpoint.responses.append(fixture.sse_answer("wrapped-answer", "wrapped-reason",
                "wrapped-message", "wrapped edit intact")[0])
            accepted = terminal_bulk(master, "a" * 2050 + "\x7f" * 2048, "wrapped edit intact")
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == "aa", body
            before = len(endpoint.requests)
            for invalid in (b"\xc3(\n", b"\xc3\n"):
                os.write(master, invalid)
                # A repeated identical notice redraws nothing.
                rejected = await_screen(master, "Input rejected; nothing sent.")
                assert "Input rejected; nothing sent." in rejected, rejected
            settle_screen(master, quiet=0.5)
            assert len(endpoint.requests) == before, "malformed UTF-8 reached Host"
            endpoint.responses.append(fixture.sse_answer("editor-limit-answer", "editor-limit-reason",
                "editor-limit-message", "limit accepted")[0])
            at_limit = "a" * (64 * 1024 - 2) + "é"
            accepted = terminal_bulk(master, at_limit, "limit accepted")
            assert "limit accepted" in accepted, accepted[-1000:]
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == at_limit
            if "› " not in accepted.split("limit accepted", 1)[1]:
                await_screen(master, "", composer=True)
            before = len(endpoint.requests)
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 12, 0, 0))
            endpoint.responses.append(fixture.sse_answer("narrow-answer", "narrow-reason",
                "narrow-message", "intact")[0])
            terminal_step(master, "A中e\u0301\x1b[DX", "intact")
            assert len(endpoint.requests) == before + 1
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == "A中Xe\u0301", body
            os.write(master, b"\x04")
            assert "Detached. Host work continues." in read_terminal(master, "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            dispose_all(lambda: stop_process(entered, timeout=5),
                        lambda: os.close(master), lambda: os.close(slave))
        master, slave = open_pty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", empty_session], env={**os.environ, "HOME": str(fresh_home)},
            stdin=slave, stdout=slave, stderr=slave)
        try:
            assert "Recent messages" not in read_terminal(master, "› ")
            fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
                "terminal ready for Ctrl+C")
            os.write(master, b"\x03")
            assert "Detached. Host work continues." in read_terminal(master, "Detached.")
            assert entered.wait(timeout=5) == 0
            assert termios.tcgetattr(master)[3] & termios.ICANON
        finally:
            dispose_all(lambda: stop_process(entered, timeout=5),
                        lambda: os.close(master), lambda: os.close(slave))
        for columns in (7, 8):
            master, slave = open_pty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))
            original_terminal = termios.tcgetattr(slave)
            before = set((fresh_home / ".config/rui/requests").glob("*.json"))
            entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", empty_session], env={**os.environ, "HOME": str(fresh_home)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            try:
                if columns == 8:
                    read_terminal(master, "› ")
                    os.write(master, b"\x03")
                output, errors = terminal_exit(entered, master)
                assert entered.returncode == (1 if columns == 7 else 0), errors
                # Below eight columns the Session refuses to draw, with resume guidance.
                assert (b"error: TerminalTooSmall" in errors and b"Resume: rui session resume --store " in errors) == (columns == 7), errors
                assert (b"Detached." in output) == (columns == 8), output
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original_terminal[3] &= ~mask
                assert actual == original_terminal
                assert set((fresh_home / ".config/rui/requests").glob("*.json")) == before
            finally:
                dispose_all(lambda: stop_process(entered, timeout=5),
                            entered.stderr.close,
                            lambda: os.close(master), lambda: os.close(slave))
        incomplete_input_case(fresh_home, store, empty_session, endpoint, host)
        observation_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("observed-later", "observed-later-reason",
            "observed-later-message", "observed later")[0], observation_release))
        observation_held, observation_continue = threading.Event(), threading.Event()
        master, slave = open_pty()
        original_terminal = termios.tcgetattr(slave)
        entered = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", empty_session], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        proxy = None
        try:
            read_terminal(master, "› ")
            before = set(json.loads(run(home, "request", "list")))
            def hold_observation(response):
                observation_held.set()
                assert observation_continue.wait(15), "accepted observation gate was not released"
                return b""  # Lost read framing must be fatal, not partial success.

            def after_admission(response):
                assert json.loads(response.split(b"\r\n\r\n", 1)[1])["answer"]["status"] == "accepted"
                proxy.route = "/v1/activity-page"
                proxy.rewrite = hold_observation
                return response

            proxy = canonical_failure_integration.ReplyProxy(host, "/v1/message", after_admission)
            os.write(master, b"observe after Host loss\n")
            terminal_gate(entered, master, observation_held, "accepted Message before activity loss", timeout=8)
            after = set(json.loads(run(home, "request", "list")))
            assert len(after - before) == 1, (before, after)
            saved_key = (after - before).pop()
            record = home / ".config/rui/requests" / f"{saved_key}.json"
            original = record.read_bytes()
            assert json.loads(original)["text"]["value"] == "observe after Host loss"
            assert fixture.command("request", "inspect", "--store", store,
                "--key", saved_key)["observation"]["status"] == "accepted"
            fixture.crash_host(host, state, "accepted-before-observation-loss")
            observation_continue.set()
            lost, errors = terminal_exit(entered, master)
            assert entered.returncode != 0 and b"TruncatedResponse" in errors, errors
            assert b"Message accepted; do not resubmit it" in errors, errors
            assert f"rui request read-result {saved_key}".encode() in errors, errors
            assert b"Detached." not in lost and b"Not confirmed" not in lost, lost
            assert proxy.mutations == [("/v1/message", original)], "fatal observation retransmitted Message"
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original_terminal[3] &= ~mask
            assert actual == original_terminal
            assert set(json.loads(run(home, "request", "list"))) == after and record.read_bytes() == original
            proxy.close()
            proxy = None
            endpoint.responses.append(fixture.sse_answer("observed-recovery", "observed-recovery-reason",
                "observed-recovery-message", "observed after recovery")[0])
            host = fixture.start_host(store, url)
            assert fixture.command("request", "inspect", "--store", store,
                "--key", saved_key)["observation"]["status"] == "accepted"
            assert json.loads(run(home, "request", "recover", saved_key))["answer"]["replayed"] is True
            assert record.read_bytes() == original, "activity failure replaced accepted original"
        finally:
            dispose_all(observation_continue.set, observation_release.set,
                        lambda: stop_process(entered, timeout=5),
                        lambda: proxy.close() if proxy is not None else None,
                        lambda: os.close(master), lambda: os.close(slave))
        completed = True
        print("human CLI: saved recovery, one-shot observation/re-entry, exact PTY approval, bounded input and Host restart passed")
    finally:
        dispose_all(
            sibling_release.touch,
            lambda: failure_release.set() if failure_release is not None else None,
            lambda: stop_release.set() if stop_release is not None else None,
            lambda: observation_release.set() if observation_release is not None else None,
            race_predecessor_release.set, race_message_release.set,
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained human CLI failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[2] if len(sys.argv) == 3 else "all")
