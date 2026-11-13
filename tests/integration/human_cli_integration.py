#!/usr/bin/env python3
"""Public one-shot caller recovery and exact Bash authorization."""
import base64
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
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty
import unicodedata

import host_process
from host_process import assert_caller_error, canonical_fixture_root, dispose_all, preserve_failure_metadata, retain_failure_state, screen_fixture_root, stop_process
from product_defaults import CATALOG, DEFAULTS, compaction_trigger, start_effort


# From 60 columns a user Message's first row ends with its admission time.
TIMED_ROW = re.compile(r"^(.*?) +(\d\d:\d\d)$")


def untimed(row):
    match = TIMED_ROW.match(row)
    return match.group(1) if match else row


# What work under way says: the running call's row, "⠹ Run tests · 42s", or
# the conversation's last line, "⠹ Thinking · 12s",
# "⠹ Rate limited · retry 2 in 18s", "Stopping…".
LIVE_LINE = re.compile(r"^(?:[⠹◌?] .+ · (?:\d|retry )|Stopping…)", re.M)
# What the line under a draft beside an Action says once Enter there denies
# the Action and sends the draft as the reason.
REASON = "enter denies the call and sends this"
# The refusal of an Enter there before such a frame was offered.
REASON_NOT_READY = "! Not ready; nothing denied · " + REASON


def reason_shown(shown):
    return REASON in shown


def send_reason(master, ready, description):
    """Once a frame saying Enter denies is offered, press Enter in the draft
    beside the Action; return the frames up to the Action's denial."""
    shown = action_ready(ready, master, shows=reason_shown)
    os.write(master, b"\r")
    return shown + read_terminal(master, f"■ {description} · denied")


def time_limit(milliseconds):
    """A custom time limit as an Action's request block shows it."""
    for unit, size in (("min", 60000), ("s", 1000)):
        if milliseconds % size == 0:
            return f"{milliseconds // size} {unit}"
    return f"{milliseconds} ms"


from terminal_process import close_pty, answers_to, open_pty, spawn, terminal_process
import model_fixture as fixture
from session_list_fixture import session_values
import codex_fixture
import os_semantics
from human_cli_fixture import chat_info_geometry, model_choice_frame, model_choice_shown, chat_info_frame, chat_info_open, panel_frame, ALLOW, CAPTURE_NOTICE, CHOICE, highlighted, _captures, action_ready, admit, await_screen, chat_content_row, command_frame, composer_ready, chat_footer_row, conversation_text, current_screen, draining, drop_spent_readiness, keyed_frame, next_frame, overview_frame, overview_title, pick_deny, read_terminal, return_to_live, run, settle_screen, shown, terminal_capture, terminal_exit, terminal_gate, terminal_step


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


def permission_row(frame, mode):
    """The chat info Permissions field, unwrapped from a narrow panel."""
    value = "run without asking" if mode == "bypass" else "ask first"
    return f"Permissions {value} Tools" in " ".join(frame.split())


def home_path(home, path):
    """`path` as chat info shows it: from `~` under HOME."""
    text, home = str(path), str(home)
    if len(home) > 1 and (text == home or text.startswith(home + "/")):
        text = "~" + text[len(home):]
    return text


def folder_row(home, path):
    """An unclipped, home-relative Folder row for short visible paths."""
    return "Folder          " + home_path(home, path)


def status_row(page, label, following):
    """A chat info row's value and note, words single-spaced: the text from
    `label`'s row up to the next row, `following`."""
    flat = " ".join(page.split())
    return flat.split(f" {label} ", 1)[1].split(f" {following} ", 1)[0]


def invoke(home, *args, expect=0, environment=None, input=None):
    """Both streams of one call: metadata on stdout, notices on stderr."""
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20, input=input)
    assert result.returncode == expect, (args, result.stdout, result.stderr)
    return result


def create_session(home, *args):
    """Capture the allocated identity; callers carry it unchanged thereafter."""
    reply = terminal_safe_json(run(home, "session", "configure", *args))
    session = reply["answer"]["session"]
    assert re.fullmatch(r"[0123456789abcdefghjkmnpqrstvwxyz]{6}", session), reply
    assert reply["answer"]["status"] == "accepted" and reply["answer"]["created"] is True, reply
    assert reply["context"]["session"] == session, reply
    return session


def shell_word(text):
    """Rui's Bash ANSI-C quoting of one argv value."""
    escaped = "".join("\\'" if byte == 0x27 else "\\\\" if byte == 0x5c else
        chr(byte) if 32 <= byte <= 126 else f"\\{byte:03o}" for byte in text.encode())
    return f"$'{escaped}'"


def defaults(home, *args, success=True, environment=None):
    """One defaults JSON value; failures leave stdout empty. Only a saved Store says it became the global default."""
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), "defaults", "configure" if args else "inspect", *map(str, args)],
        env=env, capture_output=True, text=True, timeout=20)
    if not success:
        assert result.returncode != 0 and result.stdout == "", (args, result.stdout, result.stderr)
        assert "global default Store" not in result.stderr, result.stderr
        return None
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    value = json.loads(result.stdout)
    assert value["version"] == host_process.WIRE_VERSION and value["type"] == "defaults", value
    assert value["changed"] is bool(args), value
    if "--store" in args:
        assert result.stderr == (f"\nrui: saved {shell_word(value['store'])} as the global default Store; "
            "commands without --store now use it from any directory, and saved requests keep their recorded Store.\n"), (args, result.stderr)
    else:
        assert "global default Store" not in result.stderr, (args, result.stderr)
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
            assert "rui [--store PATH]" in result.stdout, result.stdout
            assert not result.stderr, result.stderr
            assert list(home.iterdir()) == [], "help created runtime state"
        for command in ("session configure", "session inspect"):
            for flag in ("--help", "-h"):
                output = run(home, *command.split(), flag)
                assert output.startswith(f"rui {command} ["), output
                if command == "session configure":
                    for phrase in ("Omission preserves", "default resets", "A model Rui does not list",
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
        assert result.returncode != 0, result
        assert_caller_error(result.stderr, "rui: --not-an-option: ", "option_unknown")
        assert list(home.iterdir()) == [], "invalid arguments created runtime state"
        send_help = run(home, "session", "send", "--help")
        assert "\nRequires: --to ID.\n" in send_help and "stdin" in send_help, send_help
        assert "\nRequires: PROVIDER.\n" in run(home, "auth", "login", "--help")
        # Each syntactically valid call lacks one declared requirement and
        # fails before capture with scoped help, never the root usage.
        record = home / "explicit.json"
        for args, accepted in (
                (("session", "send"), "--to ID"),
                (("session", "send", "--to", "k7m2qx", "--key", "half-key"), "--record FILE"),
                (("session", "send", "--to", "k7m2qx", "--record", record), "--key KEY or --key-hex HEX"),
                (("request", "recover", "--record", record, "--kind", "message"), "--store PATH or --store-hex HEX"),
                (("auth", "login"), "PROVIDER")):
            result = subprocess.run([str(fixture.RUI), *map(str, args)], env={**os.environ, "HOME": str(home)},
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            operation = " ".join(args[:2])
            assert result.returncode == 2 and result.stdout == "", (args, result)
            assert_caller_error(result.stderr, f"rui {operation}: {accepted}: ", "option_required")
            assert f" Accepted: {accepted}. " in result.stderr, (args, result.stderr)
            assert "usage:" not in result.stderr and "rui [PROMPT]" not in result.stderr, (args, result.stderr)
            assert "request:" not in result.stderr, ("missing requirement printed a capture notice", result.stderr)
            assert list(home.iterdir()) == [], ("missing requirement created capture or record state", args)
        # Rejected input forms must name a usable correction, without reading
        # even available stdin or creating a recovery record.
        for args, (context, code) in (
                (("session", "send", "k7m2qx"),
                 ("k7m2qx", "session_id_needs_to")),
                (("session", "send", "--", "k7m2qx"),
                 ("k7m2qx", "session_id_needs_to")),
                (("session", "configure", "k7m2qx"),
                 ("k7m2qx", "session_id_needs_session")),
                (("session", "inspect", "--", "k7m2qx"),
                 ("k7m2qx", "session_id_needs_session")),
                (("session", "send", "--to", "k7m2qx", "literal"),
                 ("literal", "message_not_stdin")),
                (("session", "send", "--to", "k7m2qx", "--", "literal"),
                 ("literal", "message_not_stdin")),
                (("session", "start", "literal"),
                 ("literal", "message_not_stdin")),
                (("session", "start", "--", "literal"),
                 ("literal", "message_not_stdin")),
                (("session", "configure", "--instructions", "instructions.txt"),
                 ("--instructions instructions.txt", "instructions_source")),
                (("session", "list", "literal"),
                 ("literal", "positional_unexpected"))):
            input_read, input_write = os.pipe()
            try:
                untouched = b"held stdin must not be consumed\n"
                os.write(input_write, untouched)
                result = subprocess.run([str(fixture.RUI), *args], env={**os.environ, "HOME": str(home)},
                    stdin=input_read, capture_output=True, text=True, timeout=5)
                assert result.returncode == 2 and result.stdout == "", (args, result)
                assert_caller_error(result.stderr, f"rui {args[0]} {args[1]}: {context}: ", code)
                assert select.select([input_read], [], [], 0)[0] and os.read(input_read, len(untouched)) == untouched
                assert list(home.iterdir()) == [], ("invalid input created runtime state", args)
            finally:
                dispose_all(lambda: os.close(input_read), lambda: os.close(input_write))
        # Fresh typed choices, saved-HANDLE conflicts and malformed IDs must
        # refuse before reading stdin or publishing a capture.
        # The permission mode's choices come from the option, not the catalog.
        for args, context, code, accepted in (
                (("session", "start", "--permission-mode", "auto"),
                 "rui session start: --permission-mode auto: ", "choice_unsupported", " Accepted: ask, bypass. "),
                (("request", "inspect", "HANDLE", "--store", "P"),
                 "rui request inspect: --store with HANDLE: ", "handle_names_store_and_key", ""),
                (("session", "interrupt-model", "--session", "k7m2qx", "--turn", "12x", "--operation", "3"),
                 "rui session interrupt-model: --turn 12x: ", "id_malformed", "")):
            input_read, input_write = os.pipe()
            try:
                untouched = b"unread grammar input\n"
                os.write(input_write, untouched)
                result = subprocess.run([str(fixture.RUI), *args], env={**os.environ, "HOME": str(home)},
                    stdin=input_read, capture_output=True, text=True, timeout=5)
                assert result.returncode == 2 and result.stdout == "", (args, result)
                assert_caller_error(result.stderr, context, code)
                assert accepted in result.stderr, (args, result.stderr)
                assert select.select([input_read], [], [], 0)[0] and os.read(input_read, len(untouched)) == untouched
                assert list(home.iterdir()) == [], (args, "rejected invocation created runtime state")
            finally:
                dispose_all(lambda: os.close(input_read), lambda: os.close(input_write))
        # Retired names are refused before any entry path, even with a
        # terminal that could otherwise reach the provider chooser.
        master, slave = pty.openpty()
        try:
            caller = spawn([str(fixture.RUI), "setup"],
                env={**os.environ, "HOME": str(home), "TERM": "xterm-256color"},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            output, errors = terminal_exit(caller, master)
        finally:
            dispose_all(lambda: close_pty(master), lambda: close_pty(slave))
        assert caller.returncode == 2, (output, errors)
        assert ("rui: `setup` is now `rui defaults inspect|configure`; see rui defaults --help. "
            "Nothing was captured or sent. To start a Session, use rui session start with Message text on stdin.\n").encode() in errors, errors
        assert b"Provider:" not in output + errors and b"Codex login" not in output + errors, (output, errors)
        assert b"usage:" not in errors and b"rui [PROMPT]" not in errors, errors
        assert list(home.iterdir()) == [], "retired name created runtime state"
        # Bare entry has no inline Message operand, even after --.
        literal = subprocess.run([str(fixture.RUI), "--", "setup"], env={**os.environ, "HOME": str(home)},
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
        assert literal.returncode == 2 and '[positional_unexpected]' in literal.stderr, literal
        assert "is now" not in literal.stderr, literal.stderr
        assert list(home.iterdir()) == [], "literal prompt without a terminal created runtime state"


def compiled_model_cases():
    """One release list owns help; any ID with valid syntax is admitted, an unlisted one with default limits."""
    import host_launch_fixture as launch
    # The generated shipped snapshot is the source, not a second hand list.
    models = tuple(model for model, row in CATALOG.items() if row.openai_listed)
    windows = {model: CATALOG[model].context_window for model in models}
    assert DEFAULTS.recommended_model in models
    listing = "Supported model IDs: " + ", ".join(models) + "\n"
    unlisted_note = "client defaults use estimated limits"
    root = canonical_fixture_root(pathlib.Path(tempfile.mkdtemp(prefix="rui-compiled-models.")))
    home, store = root / "home", root / "host-store"
    home.mkdir(mode=0o700)
    env = {**os.environ, "HOME": str(home), "RUI_CODEX_CREDENTIAL_FILE": str(root / "missing-credential")}
    completed = False
    try:
        output = run(home, "session", "configure", "--help")
        assert listing in output and output.count("Supported model IDs:") == 1, output
        assert list(home.iterdir()) == [], "model help created state"
        no_home = {key: value for key, value in env.items() if key != "HOME"}
        help_without_home = subprocess.run([str(fixture.RUI), "session", "configure", "--help"],
            env=no_home, capture_output=True, text=True, timeout=10)
        assert help_without_home.returncode == 0 and listing in help_without_home.stdout and not help_without_home.stderr
        # An ID without valid syntax is refused before capture.
        for named in ((), ("--session", "k7m2qx")):
            for model in ("bad\x1b[31m", "two words", "x" * 257):
                record = root / "must-not-exist.json"
                result = subprocess.run([str(fixture.RUI), "session", "configure",
                    "--store", str(root / "absent-store"), *named, "--provider", "codex", "--model", model,
                    "--record", str(record), "--key", "invalid-model", "--instructions", "-"],
                    env=env, capture_output=True, text=True, timeout=10)
                assert result.returncode == 2 and not result.stdout, result
                assert "[model_id_malformed]" in result.stderr, result.stderr
                assert listing in result.stderr and "invalid model" in result.stderr, result.stderr
                assert "syntax and recovery:" not in result.stderr, result.stderr
                assert "error: InvalidModel" not in result.stderr, result.stderr
                assert "\x1b" not in result.stderr, result.stderr
                assert not record.exists() and not (root / "absent-store").exists()
                assert list(home.iterdir()) == [], "invalid model created capture or preference state"
        # Malformed Store paths and closed parser choices exit 2.
        for arguments, code in ((("session", "list", "--store", ""), "store_path_malformed"),
                (("session", "inspect", "--store", str(root / "absent-store"), "--session", "k7m2qx", "--profile", "invalid"), "choice_unsupported")):
            result = subprocess.run([str(fixture.RUI), *arguments], env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == 2 and not result.stdout, result
            assert f"[{code}]" in result.stderr, result.stderr
        rejected_default = subprocess.run([str(fixture.RUI), "defaults", "configure", "--provider", "codex", "--model", "two words"],
            env=env, capture_output=True, text=True, timeout=10)
        assert rejected_default.returncode == 2 and "[preference_model_invalid]" in rejected_default.stderr, rejected_default
        assert "Accepted: a supported model ID of 1-256 printable non-space ASCII bytes." in rejected_default.stderr, rejected_default.stderr
        assert not list(home.iterdir()), "refused default model created preferences"
        assert "error: InvalidModel" not in rejected_default.stderr, rejected_default.stderr
        # An unlisted ID with valid syntax is saved, with one line on its limits.
        for model in ("retired-model", "GPT-6-SOL"):
            accepted = subprocess.run([str(fixture.RUI), "defaults", "configure", "--provider", "codex", "--model", model],
                env=env, capture_output=True, text=True, timeout=10)
            assert accepted.returncode == 0, accepted
            assert accepted.stderr.count(unlisted_note) == 1 and model in accepted.stderr, accepted.stderr
            assert json.loads(accepted.stdout)["next_session"]["model"] == model, accepted.stdout
        saved = home / ".config/rui/preferences"
        assert saved.read_text().endswith("model=GPT-6-SOL\n")
        saved.write_bytes(saved.read_bytes().replace(b"model=GPT-6-SOL", b"model=retired-model"))
        original = saved.read_bytes()
        # Bare rui with the saved unlisted pin goes on to sign-in, not a refusal.
        with terminal_process([str(fixture.RUI), "--store", str(root / "absent-store")], env=env) as (entered, master):
            shown = provider_prompt(master)
            assert "invalid model" not in shown and listing.strip() not in shown, shown
        assert saved.read_bytes() == original
        # The Host starts quietly with an unlisted pin, and leaves it as it is.
        started = launch.run_start(store, env)
        assert started.returncode == 0, started.stderr
        assert "retired-model" not in started.stderr, started.stderr
        assert saved.read_bytes() == original, "startup substituted or rewrote the pin"
        attached = launch.run_start(store, env)
        assert attached.returncode == 0 and not attached.stderr, attached
        sessions = []
        for index, model in enumerate(models + ("retired-model",)):
            admitted = subprocess.run([str(fixture.RUI), "session", "configure", "--store", str(store),
                "--workspace", str(root), "--provider", "codex", "--model", model,
                "--compaction-trigger", "1"], env=env, capture_output=True, text=True, timeout=10)
            if windows.get(model) == 0:
                assert admitted.returncode == 3, admitted
                assert json.loads(admitted.stdout)["answer"]["code"] == "compact_at_too_large", admitted
                continue
            assert admitted.returncode == 0, admitted
            assert (unlisted_note in admitted.stderr) == (model not in models), admitted.stderr
            answer = json.loads(admitted.stdout)["answer"]
            assert answer["status"] == "accepted", admitted.stdout
            sessions.append(answer["session"])
            current = fixture.command("session", "inspect", "--store", store, "--session", answer["session"])
            assert current["session"]["model"] == model, current
        captures = home / ".config/rui/requests"
        before = {path.name: path.read_bytes() for path in captures.glob("*.json")}
        original_session = fixture.command("session", "inspect", "--store", store, "--session", sessions[0])["session"]
        rejected = subprocess.run([str(fixture.RUI), "session", "configure", "--store", str(store),
            "--session", sessions[0], "--model", "gpt 6"], env=env, capture_output=True, text=True, timeout=10)
        assert rejected.returncode != 0 and listing in rejected.stderr, rejected
        assert {path.name: path.read_bytes() for path in captures.glob("*.json")} == before
        assert fixture.command("session", "inspect", "--store", store, "--session", sessions[0])["session"] == original_session
        assert saved.read_bytes() == original
        launch.forced_crash_cleanup(store)
        for flags in (("--model", "gpt-6-sol"), ("--clear-model",)):
            defaults(home, *flags)
            retained = saved.read_bytes()
            started = launch.run_start(store, env)
            assert started.returncode == 0 and not started.stderr, started
            assert saved.read_bytes() == retained
            launch.forced_crash_cleanup(store)
        completed = True
        print("compiled models: shared help, invalid-ID refusal before capture, unlisted IDs admitted with default limits, and retained defaults passed")
    finally:
        dispose_all(lambda: launch.forced_crash_cleanup(store),
            lambda: shutil.rmtree(root) if completed else retain_failure_state("compiled model CLI failure state", root))


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
    # Notifications are on by default; off keeps every other choice and is
    # the only choice an older Rui cannot read.
    assert defaults(home)["notifications"] is True
    assert defaults(home, "--notifications", "off")["notifications"] is False
    assert saved.read_text() == pinned.replace("version=1", "version=2") + "notifications=off\n"
    defaults(home, "--notifications", "maybe", success=False)
    assert defaults(home, "--notifications", "on")["notifications"] is True
    assert saved.read_text() == pinned

    # Permissions-only edits publish through setup, and inspection reads them.
    original = saved.read_bytes()
    for mode in ("ask", "bypass"):
        changed = defaults(home, "--permission-mode", mode)
        assert changed["changed"] and changed["permission_mode"] == mode, changed
        inspected = defaults(home)
        assert not inspected["changed"] and inspected["permission_mode"] == mode, inspected
        assert saved.read_text().startswith("version=4\n"), saved.read_text()
        assert saved.read_text().endswith(f"reasoning_effort=\npermission_mode={mode}\n"), saved.read_text()
    retained = saved.read_bytes()
    defaults(home, "--permission-mode", "plan", success=False)
    assert saved.read_bytes() == retained, "invalid permission mode changed preferences"
    saved.write_bytes(original)


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


def forget_terminal(master):
    _captures.pop(master, None)


def discard_terminal(master):
    """Drop a reaped writer's queued output and its screen, so the next
    caller's capture starts at that caller's first byte. A writer killed while
    the PTY was full leaves a frame begun and never ended; it is no later
    frame's start."""
    discarded = 0
    while select.select([master], [], [], 0)[0]:
        chunk = os.read(master, 65536)
        if not chunk:
            break
        discarded += len(chunk)
        assert discarded < 1024 * 1024, "unbounded output from a reaped writer"
    forget_terminal(master)


def info_frame(master, session, timeout=15):
    """Read the panel on the already selected chat; keep CLI identity explicit."""
    assert session
    return chat_info_frame(master, timeout)


def saved_default(master, command, line):
    """The /setup reply that shows `line`. Every such reply opens with the
    same words and stays shown until the next, so the line this command
    changed is what tells its reply from the last one."""
    return command_frame(master, command, lambda frame: "Saved defaults for future Sessions" in conversation_text(frame) and shown(line, conversation_text(frame)))



def leave_overview(master, timeout=15):
    """Ctrl-D on an empty composer leaves the overview; returns the text
    printed after it, through the notice's Overview line."""
    capture = terminal_capture(master)
    total = capture.plain_total
    os.write(master, b"\x04")
    deadline = time.monotonic() + timeout
    while True:
        plain = capture.plain_since(total)
        at = plain.find("Overview: rui --store ")
        if at >= 0 and "\n" in plain[at:]:
            return plain
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([master], [], [], remaining)[0], ("overview notice", plain)
        chunk = os.read(master, 65536)
        assert chunk, ("terminal closed before the overview notice", plain)
        capture.feed(chunk)


def overview_store(notice):
    """The Store the overview's notice names, without its shell quoting."""
    line = notice.split("Overview: rui --store ", 1)[1].splitlines()[0]
    assert line.startswith("$'") and line.endswith("'") and "\\" not in line, line
    return line[2:-1]


def permanent_tool_count(screen, heading):
    """Count a call heading's rows in one frame (not repeated frames)."""
    return len(re.findall(r"(?m)^" + re.escape(heading) + r"$", "\n".join(chat_content_row(row) for row in screen.split("\n"))))


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


def command_wait_oracles():
    """command_frame against a scripted terminal that keeps its page shown
    while a command runs, as Rui does. Enter follows the first frame that
    shows typed text, and a wait that frame already satisfies is refused
    before Enter: the page still shown would have passed for the reply. A
    later frame that shows the whole command in the composer is not the
    reply either, though the command's own words satisfy the wait."""
    command = "/setup --model new"

    def frame(page, draft=""):
        composer = " ›" + (" " + draft if draft else "")
        return terminal_frame([*page, composer], (len(page) + 1, len(composer) + 2))

    old, new = ["Saved.", "Model: old"], ["Saved.", "Model: new"]
    for accept, refused in ((lambda shown: "Saved." in shown, True), (lambda shown: "new" in shown, False)):
        master, slave = open_pty()
        stop_read, stop_write = os.pipe()
        events = []

        def typed_input():
            ready = select.select([slave, stop_read], [], [], 10)[0]
            return os.read(slave, 64) if ready == [slave] else b""

        def terminal():
            os.write(slave, frame(old))
            typed = b""
            while command.encode() not in typed:
                part = typed_input()
                if not part:
                    return
                typed += part
            # Recorded before the frame that answers it.
            events.append("command and Enter" if b"\r" in typed else "command")
            os.write(slave, frame(old, command[:6]))
            while b"\r" not in typed:
                part = typed_input()
                if not part:
                    return
                typed += part
            events.append("Enter")
            os.write(slave, frame(old, command) + frame(old) + frame(new))

        peer = threading.Thread(target=terminal)
        try:
            tty.setraw(slave)
            peer.start()
            try:
                reply = command_frame(master, command, accept, timeout=10)
            except AssertionError as error:
                assert refused and error.args[0][:2] == ("command result shown before the command ran", command), error
                assert events == ["command"], events
            else:
                assert not refused, "a wait the shown page satisfies was accepted"
                assert reply.split("\n")[:3] == [*new, " ›"] and events == ["command", "Enter"], (reply, events)
        finally:
            dispose_all(lambda: os.write(stop_write, b"x"), lambda: peer.join(timeout=5) if peer.ident else None,
                        lambda: os.close(stop_read), lambda: os.close(stop_write),
                        lambda: _captures.pop(master, None), lambda: close_pty(master), lambda: close_pty(slave))
            assert not peer.is_alive(), "scripted terminal did not stop"
    print("command wait oracles passed: Enter follows the typed frame; the shown page and the typed command are not the reply", flush=True)


def conversation_wait_oracles():
    """The list's answer arrives first; only the conversation ends a wait.

    Queue committed frames, not byte substrings: the same ordering must hold
    for an already shown frame, a fresh read and a command's ready reply.
    """
    marker = "edited 2"
    for wide in (False, True):
        def rows(answer, draft="", listed=marker):
            chat = ["", answer, "⠹ Waiting" if answer != marker else "", "› " + draft]
            return ([f"{left:20}│ {right}" for left, right in zip(
                ("+ New Session", listed, "", ""), chat)] if wide else [" " + row for row in chat])

        pending, complete = rows("edited 1"), rows(marker)
        for mode in ("shown", "fresh", "await"):
            reader, writer = os.pipe()
            try:
                capture = terminal_capture(reader)
                capture.feed(b"\x1b[?1049h")
                if mode != "fresh":
                    capture.feed(terminal_frame(pending))
                os.write(writer, terminal_frame(complete))
                if mode == "await":
                    observed = await_screen(reader, marker)
                else:
                    observed = read_terminal(reader, marker, fresh=mode == "fresh",
                        initial=terminal_frame(pending) if mode == "fresh" else b"")
                assert "\nedited 2" in conversation_text(observed), (wide, mode, observed)
            finally:
                dispose_all(lambda: _captures.pop(reader, None), lambda: os.close(reader), lambda: os.close(writer))

        reader, writer = socket.socketpair()
        master = reader.fileno()
        try:
            # command_frame sees the draft before Enter, then two ready replies.
            # Its result is the first matching frame, even in one observer read.
            writer.sendall(terminal_frame(rows("edited 1", "send", listed="edited 1"))
                + terminal_frame(pending) + terminal_frame(complete))
            observed = terminal_step(master, "send", marker, composer=True)
            assert "\nedited 2" in conversation_text(observed), (wide, "command", observed)
        finally:
            dispose_all(lambda: _captures.pop(master, None), reader.close, writer.close)
    print("conversation wait oracles passed: list-only answers cannot finish shown, fresh, await or command waits", flush=True)


def terminal_frame(lines, cursor=None):
    """One synchronized full-screen frame as the renderer commits it."""
    row, column = cursor if cursor is not None else (len(lines), len(lines[-1]) + 1 if lines else 1)
    body = "\r\n".join(lines)
    return f"\x1b[?2026h\x1b[H\x1b[2J{body}\x1b[{row};{column}H\x1b[?2026l".encode()


def shown_bash_command(master):
    """The current Action's "$ " command, rejoined across wrapped rows.

    A later line of the command starts with the content mark `│`; a wrapped
    row starts with `┆`. As in raw_export, a row filled to the edge broke
    inside a word; any other soft break consumed a space.
    """
    capture = terminal_capture(master)
    width = capture.screen.columns
    # PermissionCard is an overlay with its own two-column inset, not feed content.
    rows = [line.rstrip() for line in capture.screen.display]
    start = next(index for index, line in enumerate(rows) if line.startswith("  $ "))
    command = rows[start][4:]
    previous = rows[start]
    for line in rows[start + 1:]:
        if line.startswith("  │ "):
            command += "\n" + line[4:]
        elif line.startswith("  ┆ "):
            command += ("" if len(previous) >= width else " ") + line[4:]
        else:
            break
        previous = line
    return command


def drawn_cluster(text):
    """`text` as a terminal draws it: libghostty-vt, like the terminals Rui
    runs in, keeps at most 64 combining marks on one cell. The submitted
    bytes still carry every mark."""
    return re.sub("([\u0300-\u036f]{64})[\u0300-\u036f]+", r"\1", text)


# Palette index 12, which SGR 94 and 38;5;12 both select.
USER_COLOUR = {12}
# Palette index 3 (attention), which SGR 33 and 38;5;3 both select.
ATTENTION_COLOUR = {3}


def scroll_until(master, key, marker, *, presses=40):
    """Press `key` until the committed screen shows `marker`; return frames.

    A press that moves nothing at an edge draws nothing, and a page load can
    draw several frames, so each press drains frames until output is quiet.
    """
    seen = []
    for _ in range(presses):
        if marker in conversation_text(current_screen(master)):
            return "\n".join(seen)
        os.write(master, key)
        while (frame := next_frame(master, 1)) is not None:
            seen.append(frame)
    assert marker in conversation_text(current_screen(master)), ("scroll did not reach marker", key, marker, current_screen(master))
    return "\n".join(seen)


def raw_export(master, screen):
    """The printed raw export command, rejoined across word-wrapped rows.

    Word wrap consumes the space at a soft break; a row filled to the edge
    broke inside a word instead (a long hex identity), so it joins directly.
    """
    columns = terminal_capture(master).screen.columns - 1  # Feed width, without its gutter.
    lines = [chat_content_row(line) for line in screen.split("\n")]
    start = next(index for index, line in enumerate(lines) if line.lstrip(" ").startswith("Raw export: "))
    command = lines[start].lstrip(" ").removeprefix("Raw export: ")
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


def raw_output(master, until, timeout=15):
    """Raw terminal bytes, fed on to the screen capture, until they hold the
    bytes `until` or a committed frame `until` accepts."""
    capture = terminal_capture(master)
    raw = b""
    deadline = time.monotonic() + timeout
    while not (until in raw if isinstance(until, bytes) else until(capture.completed)):
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([master], [], [], remaining)[0], ("terminal output deadline", raw[-512:])
        chunk = os.read(master, 65536)
        assert chunk, ("terminal closed", raw[-512:])
        capture.feed(chunk)
        raw += chunk
    return raw


def quiet_output(master, seconds):
    """Whatever the terminal writes within `seconds`."""
    raw = b""
    deadline = time.monotonic() + seconds
    while (remaining := deadline - time.monotonic()) > 0:
        if not select.select([master], [], [], remaining)[0]:
            break
        chunk = os.read(master, 65536)
        if not chunk:
            break
        raw += chunk
    return raw


def persistent_copy_case():
    """/copy sends the last answer, and /copy code its last code block, to the
    clipboard as one OSC 52 sequence of at most 75,000 bytes; /copy file saves
    the answer where Rui runs, mode 0600 even over an earlier file, and replaces
    a link at its name without following it."""
    state = screen_fixture_root("rui-copy.")
    home = state / "home"
    home.mkdir(mode=0o700)
    store = state / "store"
    here = state / "here"
    here.mkdir()
    answer = "Run:\n```sh\nzig build\n```\nThen:\n```py\nprint('é')\n```\nDone."
    # The code block is the clipboard's limit exactly; the answer is over it.
    limit = 75_000
    block = ("x" * 99 + "\n") * 749 + "x" * 100
    large = "```\n" + block + "\n```\nLarge done."
    endpoint = fixture.SuccessEndpoint([fixture.sse_answer("copy-0", "r-0", "m-0", answer)[0],
                                        fixture.sse_answer("copy-1", "r-1", "m-1", large)[0]])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = None
    completed = False
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        session = create_session(home, "--store", store,
            "--workspace", state, "--provider", "codex", "--model", "gpt-6-sol")
        with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store), session],
                env={**os.environ, "HOME": str(home)}, cwd=here) as (caller, master):
            read_terminal(master, "› ")
            capture = terminal_capture(master)
            terminal_step(master, "/copy", "No answer to copy", composer=True)
            terminal_step(master, "/copy code", "No answer to copy", composer=True)
            assert capture.clipboard == [] and not any(here.iterdir()), capture.clipboard
            terminal_step(master, "Copy request", "Done.", composer=True)
            # A left drag over the answer's last word copies exactly the text
            # it covered, in one OSC 52 sequence, once the button is released.
            lines = current_screen(master).split("\n")
            row = next(index for index, line in enumerate(lines) if line.strip() == "Done.")
            column = lines[row].index("Done.")
            capture.clipboard.clear()
            drag = (f"\x1b[<0;{column + 1};{row + 1}M\x1b[<32;{column + 3};{row + 1}M"
                    f"\x1b[<32;{column + 5};{row + 1}M\x1b[<0;{column + 5};{row + 1}m")
            command_frame(master, drag, lambda frame: "Copied 1 line" in frame, end="")
            assert capture.clipboard == ["\x1b]52;c;" + base64.b64encode(b"Done.").decode() + "\x1b\\"], capture.clipboard

            def sent(command):
                before = len(capture.clipboard)
                frame = terminal_step(master, command, "Sent to clipboard", composer=True)
                assert frame.split("\n")[chat_footer_row(frame)].endswith("Sent to clipboard"), frame
                assert frame.count("Sent to clipboard") == 1, frame
                assert len(capture.clipboard) == before + 1, capture.clipboard
                return capture.clipboard[-1]

            def osc52(text):
                return "\x1b]52;c;" + base64.b64encode(text.encode()).decode() + "\x1b\\"

            assert sent("/copy") == osc52(answer)
            # The chat info action uses the same last-answer clipboard owner.
            copied = len(capture.clipboard)
            chat_info_open(master)
            panel_frame(master, lambda frame: len(capture.clipboard) == copied + 1,
                        b"\x1b[B" * 6 + b"\r")
            assert capture.clipboard[-1] == osc52(answer), capture.clipboard
            panel_frame(master, lambda frame: "Copy last answer" not in frame, b"\x1b")
            assert sent("/copy code") == osc52("print('é')")
            name = f"rui-{session}-answer.md"
            terminal_step(master, "/copy file", f"Saved to ./{name}", composer=True)
            saved = here / name
            assert saved.read_bytes() == answer.encode() and saved.stat().st_mode & 0o777 == 0o600, saved
            terminal_step(master, "Large request", "More — Ctrl-O for whole message", composer=True)
            before = len(capture.clipboard)
            terminal_step(master, "/copy", "Too large for the clipboard · /copy file", composer=True)
            assert len(capture.clipboard) == before, "an answer over the limit is never sent"
            assert len(block) == limit
            started = time.monotonic()
            assert sent("/copy code") == osc52(block)
            print(f"persistent copy: /copy code of {limit} bytes took {time.monotonic() - started:.3f}s to its frame", flush=True)
            saved.chmod(0o644)
            terminal_step(master, "/copy file", f"Saved to ./{name}", composer=True)
            assert saved.read_bytes() == large.encode() and saved.stat().st_mode & 0o777 == 0o600, saved
            # A link at the export name is replaced, never followed.
            sentinel = state / "sentinel"
            sentinel.write_bytes(b"sentinel")
            sentinel.chmod(0o640)
            saved.unlink()
            saved.symlink_to(sentinel)
            terminal_step(master, "/copy file", f"Saved to ./{name}", composer=True)
            assert sentinel.read_bytes() == b"sentinel" and sentinel.stat().st_mode & 0o777 == 0o640, sentinel
            assert not saved.is_symlink() and stat.S_ISREG(saved.lstat().st_mode), saved
            assert saved.read_bytes() == large.encode() and saved.lstat().st_mode & 0o777 == 0o600, saved
            assert list(here.iterdir()) == [saved], list(here.iterdir())
            terminal_step(master, "\x03", "Detached.")
            assert caller.wait(timeout=5) == 0
        completed = True
        print("persistent copy: /copy and /copy code sent exact OSC 52 bytes; /copy file saved the exact answer", flush=True)
    finally:
        dispose_all(lambda: fixture.stop_host(host) if host is not None else None,
                    endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5))
        if completed:
            shutil.rmtree(state)
        else:
            retain_failure_state("copy failure state", state)


def provider_prompt(master):
    # First run is now a committed app frame, not a canonical line prompt.
    return await_screen(master, "› ChatGPT    API key")


def terminal_bulk(master, command, marker="› ", *, submit=True, draft=None, caret=None, timeout=15):
    """Write a large input in chunks while the screen is read.

    With `draft`, wait instead until the composer shows exactly that draft
    with its caret at display column `caret`. Returns the frames seen; the
    terminal's output volume meanwhile is in `terminal_bulk.received`.
    """
    fixture.wait_for(lambda: not termios.tcgetattr(master)[3] & termios.ICANON,
        "noncanonical terminal input")
    def send():
        payload = (command + ("\r" if submit else "")).encode()  # Enter is CR; LF is Ctrl-J.
        for offset in range(0, len(payload), 1024):
            os.write(master, payload[offset:offset + 1024])

    capture = terminal_capture(master)
    received = capture.received_bytes
    writer = threading.Thread(target=send, daemon=True)
    writer.start()
    if draft is None:
        output = read_terminal(master, marker, timeout=timeout)
    else:
        deadline = time.monotonic() + timeout
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
    args = ["session", "configure", "--store", store,
        "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol"]
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
        assert replaced["session"] == "", replaced
        replaced["session"] = "000000"
        replacement = records / "replacement"
        replacement.write_text(json.dumps(replaced, separators=(",", ":")))
        replacement.replace(record)
        pathlib.Path(f"{gate}.release").touch()
        output, errors = caller.communicate(timeout=20)
        assert caller.returncode == 0, (output, errors)
        captured = CAPTURE_NOTICE.match(errors)
        admission = json.loads(output)
        assert captured and captured.group(1) == handle and admission["answer"]["status"] == "accepted", (output, errors)
        session = admission["answer"]["session"]
        assert re.fullmatch(r"[0123456789abcdefghjkmnpqrstvwxyz]{6}", session), admission
        observed = fixture.command("request", "inspect", "--store", store, "--key", handle)["observation"]
        assert observed["target"] == session and admission["answer"]["created"] is True, ("captured owner transmitted a replaced pathname", observed)
    finally:
        dispose_all(lambda: stop_process(caller, timeout=5),
                    lambda: record.write_bytes(original) if original is not None else None)

    # Recovery must ignore a newly selected, nonexistent preference Store.
    defaults(home, "--store", store)
    preferences = home / ".config/rui/preferences"
    saved_preferences = preferences.read_bytes()
    preferences.write_text(f"version=1\nstore={state / 'missing-capture-store'}\n")
    assert json.loads(run(home, "request", "recover", handle))["answer"]["replayed"] is True
    preferences.write_bytes(saved_preferences)

    # Rejected creation has no allocated Session. It remains inspectable and
    # recoverable, without hiding another Session's valid recovery handles.
    sessions_before = run(home, "session", "list", "--store", store, "--all")
    rejected_handles = []
    for operation, kind in (("configure", "configure"), ("start", "message")):
        rejected = admit(home, "session", operation, "--store", store,
            "--workspace", state / "missing-workspace", "--provider", "codex", "--model", "gpt-6-sol",
            input="rejected first Message" if operation == "start" else None, expect=3)
        rejected_handle = rejected["request"]
        rejected_handles.append(rejected_handle)
        rejected_answer = rejected["admission"]["answer"]
        assert rejected_answer == {"status": "rejected", "replayed": False,
            "session": "", "code": "invalid_workspace"}, rejected
        rejected_record = records / f"{rejected_handle}.json"
        rejected_bytes = rejected_record.read_bytes()
        observed = json.loads(run(home, "request", "inspect", rejected_handle))["observation"]
        expected = {"status": "rejected", "kind": kind, "target": "", "code": "invalid_workspace"}
        if kind == "message":
            expected["state"] = "rejected"
        # Rejected observations retain no canonical Message content; its
        # original input remains in the unchanged local capture and receipt.
        assert observed == expected, observed
        recovered = json.loads(run(home, "request", "recover", rejected_handle, success=False))
        assert recovered["answer"] == {**rejected_answer, "replayed": True}, recovered
        assert rejected_record.read_bytes() == rejected_bytes
        # The rejected record advances Store freshness, not Session facts.
        after = json.loads(run(home, "session", "list", "--store", store, "--all"))
        assert session_values(after) == session_values(json.loads(sessions_before))

    # Later capture faults update that same allocated Session, so /requests
    # must retain all of its recoverable configuration handles together.
    args += ["--session", session]
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
    if os_semantics.SYNC_FAULT_PRELOAD:
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
        subprocess.run(os_semantics.shared_library_command(source, library), check=True)
        before = set(json.loads(run(home, "request", "list")))
        failed = subprocess.run([str(fixture.RUI), *map(str, args)],
            env={**os.environ, "HOME": str(home), os_semantics.PRELOAD: str(library)},
            capture_output=True, text=True, timeout=20)
        assert failed.returncode == 1 and "[internal_unexpected]" in failed.stderr, failed
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
    stop = {"version": host_process.WIRE_VERSION, "kind": "session_stop", "store": str(store.resolve()),
        "key": stopped, "session": session}
    (records / f"{stopped}.json").write_text(json.dumps(stop, separators=(",", ":")))
    (records / "not-a-handle.json").write_text("not a record")
    listed = json.loads(run(home, "request", "list"))
    assert invalid in listed and stopped in listed and "not-a-handle" not in listed, listed
    assert run(home, "request", "recover", invalid, success=False) == ""
    recovered_stop = json.loads(run(home, "request", "recover", stopped))
    assert recovered_stop["context"] == {"store": str(store.resolve()), "session": session,
        "key": stopped, "kind": "session_stop"}, recovered_stop
    assert recovered_stop["answer"]["status"] == "accepted", recovered_stop
    with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
        session], env={**os.environ, "HOME": str(home)},
    ) as (entered, master):
        read_terminal(master, "› ")
        listing = terminal_step(master, "/requests", "Local recovery handles", composer=True)
        assert handle in listing and failed_notice in listing and f"{stopped} (session_stop)" in listing, listing
        assert invalid not in listing and all(handle not in listing for handle in rejected_handles), listing
        terminal_step(master, "\x03", "Detached.")
        assert entered.wait(timeout=5) == 0
    print("saved capture owner: pinned original bytes, preference-independent recovery, failed announcement, "
        "sync uncertainty, listing asymmetry", flush=True)


def silent_read_edit_cases():
    """Silent observation must not hide accepted draft edits with ECHO off."""
    import canonical_fixture as canonical
    state = screen_fixture_root("rui-silent-edit.")
    home, store = state / "home", state / "store"
    home.mkdir(mode=0o700)
    host = caller = proxy = None
    completed = False
    try:
        host = fixture.start_host(store, None)
        # A live scan reads only its activity page.
        for index, route in enumerate(("/v1/activity-page",)):
            reference = create_session(home, "--store", store,
                "--workspace", state, "--provider", "codex", "--model", "gpt-6-sol")
            master, slave = open_pty()
            original = termios.tcgetattr(slave)
            held, release = threading.Event(), threading.Event()
            try:
                caller = spawn([str(fixture.RUI), "session", "resume", "--store", str(store), reference],
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
                os.write(master, b"\r")
                fixture.wait_for(lambda: len(set((home / ".config/rui/requests").glob("*.json")) - before) == 1,
                    "visible draft capture")
                record, = set((home / ".config/rui/requests").glob("*.json")) - before
                assert json.loads(record.read_bytes())["text"]["value"] == "visible cafXé!"
                os.write(master, b"\x03")
                _, errors = terminal_exit(caller, master)
                assert caller.returncode == 0, errors
                actual = termios.tcgetattr(slave)
                assert os_semantics.user_termios(actual) == os_semantics.user_termios(original)
                print(f"silent observation: {route} visible Unicode edit and exact capture passed", flush=True)
            finally:
                dispose_all(release.set,
                            lambda: stop_process(caller, timeout=5) if caller is not None else None,
                            lambda: proxy.close() if proxy is not None else None,
                            lambda: close_pty(master), lambda: close_pty(slave))
                proxy = None
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if completed:
            shutil.rmtree(state)
        else:
            retain_failure_state("silent-edit failure state", state)


def wait_for_listed_call(tty):
    # A matching Bash projection supplies the unresolved row's clock. The
    # command stays held until after traversal; a bare heading can precede claim.
    running = re.compile(r"⠹ Held call · (?:[0-9]+s|[0-9]+m [0-9]+s|[0-9]+h [0-9]+m)")
    tty.wait(predicate=lambda: any(running.fullmatch(row) for row in conversation_text(tty.capture.completed).splitlines()), timeout=30)


def listed_call_readiness_cases():
    """A heading may precede claim; only the current running row is a barrier."""
    from terminal_screen import ScreenCapture

    class OfferedFrames:
        def __init__(self, elapsed):
            self.capture = ScreenCapture(80, 24)
            self.frames = (
                "⠹ Held call\n◌ Queued · 0s",
                "✓ Held call · 42s",
                "⠹ Other call · 42s",
                "prefix ⠹ Held call · 42s",
                "⠹ Held call · 42s extra",
                "⠹ Held call · " + elapsed,
            )
            self.offered = None
            # Accumulated output already contains a timed row: it is not current.
            self.frame("⠹ Held call · 99s")
            self.frame(self.frames[0])

        def frame(self, text):
            self.capture.feed(("\x1b[?2026h\x1b[H\x1b[2J" + text.replace("\n", "\r\n") + "\x1b[?2026l").encode())

        def wait(self, marker=None, *, predicate=None, timeout=15):
            assert timeout == 30, timeout
            for self.offered, frame in enumerate(self.frames):
                self.frame(frame)
                if (predicate() if predicate is not None else self.capture.reached(marker)):
                    return self.capture.completed
            raise AssertionError(("running listed call was not accepted", self.capture.completed))

    for elapsed in ("0s", "2m 3s", "1h 2m"):
        tty = OfferedFrames(elapsed)
        wait_for_listed_call(tty)
        assert tty.offered == len(tty.frames) - 1, ("listed call accepted before current running row", tty.capture.completed)


def renderer_cases():
    """Full-screen geometry, input, consent and restoration through screen cells."""
    from contextlib import contextmanager, ExitStack
    from terminal_screen import ScreenCapture
    import canonical_fixture as canonical
    import resource

    listed_call_readiness_cases()

    # Every-frame oracles see each synchronized commit, not just the newest one after a read.
    control, seen = ScreenCapture(), []
    control.listener = lambda screen, x, y: seen.append(screen)
    control.feed(b"\x1b[?2026h\x1b[HBROKEN INTERMEDIATE\x1b[?2026l"
                 b"\x1b[?2026h\x1b[H\x1b[2JCORRECT FINAL\x1b[?2026l")
    assert len(seen) == 2 and "BROKEN INTERMEDIATE" in seen[0], seen
    assert "BROKEN" not in control.completed and "CORRECT FINAL" in control.completed, control.completed

    original_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(256, original_limit[0]), original_limit[1]))

    state = screen_fixture_root("rui-renderer.")
    # Always wrap the Workspace, whatever the temporary root.
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
            self.capture = ScreenCapture(reply=answers_to(master))

        def resize(self, columns, rows=24):
            self.capture.resize(columns, rows)
            fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

        def feed(self, data):
            self.capture.feed(data)

        def draining(self, observe):
            """`observe` after reading this screen, as `draining` does."""
            return draining(self.master, observe, self.feed)

        def wait(self, marker=None, *, predicate=None, after=None, timeout=15):
            deadline = time.monotonic() + timeout
            matched = None
            previous = self.capture.listener
            def reached():
                return ((after is None or self.capture.generation > after) and
                        (predicate() if predicate is not None else
                         self.capture.reached(marker) and unicodedata.normalize("NFC", marker) in conversation_text(self.capture.completed)))
            def observe(screen, x, y):
                nonlocal matched
                if previous is not None:
                    previous(screen, x, y)
                if matched is None and reached():
                    matched = screen
            self.capture.listener = observe
            try:
                while matched is None and not reached():
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
                return matched if matched is not None else self.capture.completed
            finally:
                self.capture.listener = previous

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

        def ready(self, descriptor, until=lambda: True):
            """Return once an offered frame shows what `until` accepts. Rui
            writes a token after each offered frame, so a token can belong
            to a frame drawn before the one a case waits for: keys that
            draw a frame of their own before the last one (Ctrl-R before
            Enter) offer that frame too."""
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
                    if until():
                        # Spend the tokens of later offers too, with their
                        # frames (each token follows its frame), so the next
                        # ready() waits for an offer made after this one.
                        while select.select([descriptor], [], [], 0)[0]:
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
                        chunk = os.read(fd, 65536) if fd == self.master else os.read(fd, 65536)
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
            if initial_text is not None:
                session = json.loads(run(home, "session", "start", "--store", store, "--workspace", workspace,
                    "--provider", "codex", "--model", "gpt-6-sol", input=initial_text))["context"]["session"]
                assert re.fullmatch(r"[0123456789abcdefghjkmnpqrstvwxyz]{6}", session), session
            arguments = ["session", "resume", "--store", str(store), "--", session]
            caller = spawn([str(fixture.RUI), *arguments],
                cwd=workspace, env=env, pass_fds=(() if ready_write is None else (ready_write,)),
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            terminal = Terminal(master, slave, caller)
            # The capture matches the pty before the first frame: the input
            # draws on the bottom row, past a default-sized capture's last.
            terminal.capture.resize(columns, rows)
            if opening:
                terminal.wait(predicate=lambda: terminal.capture.draft("", 2))
            yield terminal
            assert caller.poll() is not None, "case did not retire its renderer"
            actual, expected = termios.tcgetattr(slave), list(original)
            assert os_semantics.user_termios(actual) == os_semantics.user_termios(expected), ("renderer termios restoration", expected, actual)
            from terminal_restoration_fixture import assert_file_flags
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
                lambda: close_pty(master), lambda: close_pty(slave))

    def configure(permission="bypass"):
        return create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol", "--permission-mode", permission)

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
        tty.send("\x1bi", "Copy last answer")
        tty.send("\x1b", predicate=lambda: tty.capture.draft("", 2))

    try:
        # One read can replace a valid Message frame with the final reply.
        # The wait and existing every-frame oracle must both see that frame.
        master, writer = os.pipe()
        try:
            tty = Terminal(master, None, None)
            frames = tty.every_frame()
            listener = tty.capture.listener
            os.write(writer, ("\x1b[?1049h\x1b[?2026h\x1b[2J\x1b[H" + "m" * 40 +
                "\r\n› \x1b[?2026l\x1b[?2026h\x1b[2J\x1b[HREPLY-04399\r\n› \x1b[?2026l").encode())
            os.close(writer)
            writer = None
            observed = tty.wait(predicate=lambda: tty.capture.draft("", 2) and "m" * 40 in tty.capture.completed,
                after=0)
            assert "m" * 40 in observed and "REPLY-04399" not in observed, observed
            assert len(frames) == 2 and "m" * 40 in frames[0] and "REPLY-04399" in frames[1], frames
            assert "REPLY-04399" in tty.capture.completed and tty.capture.listener is listener
        finally:
            dispose_all(lambda: close_pty(master), lambda: os.close(writer) if writer is not None else None)
        master, writer = os.pipe()
        try:
            tty = Terminal(master, None, None)
            os.write(writer, terminal_frame(["  + New Session │", "  edited 2      │ edited 1", "                │ ⠹ Waiting"])
                + terminal_frame(["  + New Session │", "  edited 2      │ edited 2", "                │ ›"]))
            observed = tty.wait("edited 2", after=0)
            assert "\nedited 2" in conversation_text(observed), observed
        finally:
            dispose_all(lambda: close_pty(master), lambda: os.close(writer))
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        defaults(home, "--store", store)
        geometry = configure()
        codex_fixture.credentials(home / ".config/rui/codex.json")
        initial = "\u0301literal initial prompt\u200d"
        marker = answer("initial")
        with terminal("initial prompt", initial_text=initial, opening=False) as tty:
            tty.wait(marker)
            submitted(initial)
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: initial zero-width prompt bypasses composer and reaches provider unchanged", flush=True)
        with terminal(geometry) as tty:
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
            assert os.write(tty.master, b"\x03") == 1
            tty.finish()
        env = {**os.environ, "HOME": str(home)}
        rejected = subprocess.run([str(fixture.RUI), "session", "resume", "--store", str(store), geometry],
            env=env, input=b"", capture_output=True, timeout=5)
        assert rejected.returncode != 0 and b"rui needs terminal input and output" in rejected.stderr, rejected
        assert b"\x1b" not in rejected.stdout + rejected.stderr, rejected
        pipe_text = "/literal\nstdin café\n"
        pipe_answer = answer("pipe")
        piped = subprocess.run([str(fixture.RUI), "session", "send", "--store", str(store), "--to", geometry],
            cwd=workspace, env=env, input=pipe_text.encode(), capture_output=True, timeout=10)
        assert piped.returncode == 0 and json.loads(piped.stdout)["answer"]["status"] == "accepted", piped
        assert b"\x1b" not in piped.stdout + piped.stderr, piped
        piped_key = json.loads(piped.stdout)["context"]["key"]
        fixture.wait_for(lambda: fixture.completed_observation(store, piped_key), "piped renderer answer")
        assert fixture.read_result(store, piped_key) == pipe_answer.encode()
        submitted(pipe_text)
        print("renderer: non-TTY rejection and literal multiline pipe output retain their existing contracts", flush=True)
        with terminal(geometry) as tty:
            # Keep the historical native Mac OOM sequence exactly: wide5000X
            # at 24x2048, shrink to 24x80, then a + 2048 combining acutes.
            tty.resize(2048)
            marker = answer("wide")
            tty.send("X" * 5000 + "\r", marker)
            submitted("X" * 5000)
            joined(tty)
            tty.resize(80)
            for index, (draft, caret) in enumerate((("a" + "\u0301" * 2048, 3),
                    ("A中e\u0301\tB", 8), ("e" + "\u0301" * 1024, 3))):
                before = len(endpoint.requests)
                records = set((home / ".config/rui/requests").glob("*.json"))
                # A draft tab shows as one cell; the submitted bytes keep it.
                drawn = "A中é B" if index == 1 else drawn_cluster(draft)
                tty.send("\x1b[200~" + draft + "\x1b[201~", predicate=lambda: tty.capture.draft(drawn, caret))
                assert len(endpoint.requests) == before and set((home / ".config/rui/requests").glob("*.json")) == records
                marker = answer(index)
                tty.send("\r", marker)
                submitted(draft)
                joined(tty)
            multiline = "first café\nsecond 中"
            before = len(endpoint.requests)
            # Continuation rows align under the draft, inside the composer margin,
            # without a second glyph.
            tty.send("\x1b[200~" + multiline + "\x1b[201~",
                predicate=lambda: "   second 中" in tty.capture.completed)
            screen = tty.capture.screen
            assert screen.display[screen.cursor.y - 1].rstrip() == " › first café"
            assert screen.display[screen.cursor.y].rstrip() == "   second 中" and screen.cursor.x == 12
            assert len(endpoint.requests) == before
            tty.send("\r", answer("multiline"))
            submitted(multiline)
            joined(tty)
            os.write(tty.master, b"\x03")
            tty.finish()
        print("renderer: wide5000X resize, long combining cells, tabs, multiline paste and exact submitted bytes passed", flush=True)

        invisible_session = configure()
        invisible = "\u00ad\u200b\u2060\ufeff\n\u200b\u0301\njoined e\u0301"
        arguments = json.dumps({"cmd": "printf '\\302\\255\\342\\200\\213\\342\\201\\240\\357\\273\\277\\n\\342\\200\\213\\314\\201\\njoined e\\314\\201'", "description": "Invisible output", "timeout_ms": None})
        endpoint.responses.append(fixture.sse_tool_calls("renderer-invisible", [("bash", "renderer-invisible-call", arguments)]))
        endpoint.responses.append(fixture.sse_answer("invisible-answer", "invisible-reason", "invisible-message", invisible + "\noutput survived")[0])
        escaped = ("\\u{ad}", "\\u{200b}", "\\u{2060}", "\\u{feff}", "\\u{301}")
        with terminal(invisible_session) as tty:
            shown = tty.send("show invisible output\r", "output survived")
            assert all(value in shown for value in escaped), shown
            joined(tty)
            shown = tty.send("\x0f", chat_content_row("    Bash "))
            # Both the saved Tool Result and answer use the same display sink.
            assert all(value in shown for value in escaped), shown
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        with terminal(invisible_session) as tty:
            shown = tty.wait("output survived")
            assert all(value in shown for value in escaped), shown
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: invisible answer and tool output escaped; saved conversation reopens", flush=True)

        # The request stays above the input row. Its choice initially hides
        # the kept draft, highlights Allow once and accepts Enter even before
        # a long command's end is shown. Typing or paste reveals and edits the
        # draft without deciding; Esc returns to the choice.
        consent_session = configure("ask")
        proxy = canonical.ReplyProxy(host, "/v1/control/permission-decision", lambda response: response)
        command = "\n".join(f"# exact command line {index}" for index in range(100)) + "\nprintf approved > renderer-effect"
        arguments = json.dumps({"cmd": command, "description": "Renderer consent", "timeout_ms": None})
        release = threading.Event()
        endpoint.responses.append((fixture.sse_tool_calls("renderer-call", [("bash", "renderer-action", arguments)]), release))
        marker = answer("consent")
        ready_read, ready_write = os.pipe()
        try:
            with terminal(consent_session, ready_write) as tty:
                tty.send("propose renderer action\r\x1b[200~a\x1b[201~", predicate=lambda: tty.capture.draft("a", 3))
                release.set()
                opened = tty.wait(CHOICE)
                tty.ready(ready_read)
                assert highlighted(tty.capture) == "Allow once", opened
                # One title, then the exact command cut to what fits. Only
                # the choice is on the input row; the kept draft is hidden.
                assert opened.count("? Renderer consent") == 1 and "$ # exact command line 0" in opened, opened
                assert "printf approved > renderer-effect" not in opened and "› a" not in opened, opened
                assert "Workspace" not in opened and "Time limit" not in opened and "Run Bash" not in opened, opened
                records = set((home / ".config/rui/requests").glob("*.json"))
                current = fixture.command("session", "inspect", "--store", store, "--session", consent_session)
                action = current["actionable_permissions"][0]["action"]
                exact = json.loads(run(home, "action", "inspect", "--store", store, "--session", consent_session, "--action", action))
                assert exact["arguments"] == arguments
                # Ctrl-R and Shift-Enter as Ghostty sends it (ESC CR) do
                # not decide at the choice. A printable key then reveals
                # the kept draft and is inserted at its caret.
                drafting = tty.send("\x12\x1b\ry", predicate=lambda: tty.capture.draft("ay", 4))
                assert "? Renderer consent" in drafting and highlighted(tty.capture) is None, drafting
                tty.send("\r", "Not sent: this Action needs a decision")
                tty.send("\x1b", predicate=lambda: highlighted(tty.capture) == "Allow once")

                def pasted_draft():
                    screen = tty.capture.screen
                    return (not tty.capture.synchronized and screen.cursor.y > 0
                            and screen.display[screen.cursor.y - 1].rstrip() == " › aypasted"
                            and screen.display[screen.cursor.y].rstrip() == "   text"
                            and screen.cursor.x == 7)

                # A paste switches back to the draft too. Its embedded
                # Enter is text, never a decision, and the request stays up.
                drafting = tty.send("\x1b[200~pasted\r\ntext\x1b[201~", predicate=pasted_draft)
                assert "? Renderer consent" in drafting and highlighted(tty.capture) is None, drafting
                tty.send("\x1b", predicate=lambda: highlighted(tty.capture) == "Allow once")
                tty.send("\x1b[C", predicate=lambda: highlighted(tty.capture) == "Deny")
                tty.send("\x1b[D", predicate=lambda: highlighted(tty.capture) == "Allow once")
                assert set((home / ".config/rui/requests").glob("*.json")) == records and not proxy.exchanges
                assert not (workspace / "renderer-effect").exists(), "editing the draft authorized an Action"
                # Enter allows at once, though the command's end is not shown.
                tty.send("\r", marker)
                assert (workspace / "renderer-effect").read_bytes() == b"approved"
                decisions = [json.loads(path.read_text()) for path in set((home / ".config/rui/requests").glob("*.json")) - records]
                assert len(decisions) == 1 and decisions[0]["action"] == action and decisions[0]["decision"] == "allow_once", decisions
                assert len(proxy.exchanges) == 1, "consent transmitted more than one decision"
                body, response = proxy.exchanges[0]
                assert json.loads(body)["action"] == action and json.loads(body)["decision"] == "allow_once"
                assert json.loads(response.split(b"\r\n\r\n", 1)[1])["answer"]["status"] == "accepted"
                # The edited draft returns unchanged, including its caret.
                tty.wait(predicate=pasted_draft)
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            dispose_all(release.set, lambda: os.close(ready_read), lambda: os.close(ready_write))
        print("renderer: the choice hides the draft; typing and paste edit it without deciding; Esc returns the choice and Allow restores the draft", flush=True)

        proxy.close()
        proxy = None
        # A preview past the old 256 KiB veto can still be approved, at once
        # (audit item 8, 2026-11-09). Left waiting, its detach notice names
        # the exact shell commands.
        oversized_session = configure("ask")
        command = "#" + "x" * (256 * 1024) + "\nprintf oversized > renderer-oversized-effect"
        arguments = json.dumps({"cmd": command, "description": "Oversized proposal", "timeout_ms": None})
        endpoint.responses.append(fixture.sse_tool_calls("renderer-oversized", [("bash", "renderer-oversized-call", arguments)]))
        with terminal(oversized_session) as tty:
            tty.send("propose oversized action\r", CHOICE)
            current = fixture.command("session", "inspect", "--store", store, "--session", oversized_session)
            action = current["actionable_permissions"][0]["action"]
            tty.caller.send_signal(signal.SIGINT)
            detached = tty.finish()[1].decode()
            for name in ("inspect", "allow", "deny"):
                assert f"rui action {name} --store $'{store}' --session {oversized_session} --action {action}" in detached, detached
            assert not (workspace / "renderer-oversized-effect").exists()
        marker = answer("oversized")
        with terminal(oversized_session) as tty:
            tty.wait(CHOICE)
            assert "printf oversized" not in tty.capture.completed, tty.capture.completed
            records = set((home / ".config/rui/requests").glob("*.json"))
            tty.send("\r", marker)
            # The decision is the oracle: Linux refuses a 256 KiB argument,
            # so whether Bash then ran depends on the platform.
            decisions = [json.loads(path.read_text()) for path in set((home / ".config/rui/requests").glob("*.json")) - records]
            assert [(item["action"], item["decision"]) for item in decisions] == [(action, "allow_once")], decisions
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: an oversized Action can be approved; left waiting, its exact shell commands survive exit", flush=True)

        # Another client decides: the card leaves on its own, with the
        # outcome and answer shown, never an Action that still looks pending.
        # A key typed at the choice remains in the draft after that decision.
        for decision in ("allow", "deny"):
            session = configure("ask")
            effect = workspace / f"renderer-elsewhere-{decision}"
            arguments = json.dumps({"cmd": f"printf decided > {effect.name}", "description": "Decided elsewhere", "timeout_ms": None})
            endpoint.responses.append(fixture.sse_tool_calls(f"renderer-elsewhere-{decision}", [("bash", f"elsewhere-{decision}-call", arguments)]))
            marker = answer(f"elsewhere {decision}")
            with terminal(session) as tty:
                tty.send("propose an Action decided elsewhere\r", CHOICE)
                action = fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"][0]["action"]
                tty.send("x", predicate=lambda: tty.capture.draft("x", 3))
                generation = tty.capture.generation
                run(home, "action", decision, "--store", store, "--session", session, "--action", action)
                shown = tty.wait(predicate=lambda: marker in conversation_text(tty.capture.completed) and tty.capture.draft("x", 3), after=generation)
                for pending in ("Allow once", "? Decided elsewhere"):
                    assert pending not in shown, (decision, shown)
                assert effect.exists() == (decision == "allow"), decision
                requests = len(endpoint.requests)
                tty.send("\x7f", predicate=lambda: tty.capture.draft("", 2))
                tty.send("\x1bi", "Copy last answer")
                assert len(endpoint.requests) == requests, endpoint.requests
                tty.send("\x1b", predicate=lambda: tty.capture.draft("", 2))
                assert CHOICE not in tty.capture.completed, tty.capture.completed
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        print("renderer: an Action decided by another client leaves the card and shows its outcome; a key typed at the choice stays in the draft", flush=True)

        # The card decides only the request it drew: when the first of two is
        # decided elsewhere, the second gets its own card and readiness.
        session = configure("ask")
        endpoint.responses.append(fixture.sse_tool_calls("renderer-successor", [
            ("bash", f"successor-{index}", json.dumps({"cmd": f"printf decided > renderer-successor-{index}", "description": f"Successor {index}", "timeout_ms": None}))
            for index in (1, 2)]))
        marker = answer("successor")
        ready_read, ready_write = os.pipe()
        try:
            with terminal(session, ready_write) as tty:
                tty.send("propose two Actions\r", "? Successor 1")
                tty.ready(ready_read)
                first, second = [item["action"] for item in fixture.command("session", "inspect", "--store", store, "--session", session)["actionable_permissions"]]
                generation = tty.capture.generation
                run(home, "action", "deny", "--store", store, "--session", session, "--action", first)
                tty.wait(predicate=lambda: "? Successor 2" in conversation_text(tty.capture.completed) and CHOICE in conversation_text(tty.capture.completed), after=generation)
                tty.ready(ready_read)
                assert highlighted(tty.capture) == "Allow once", tty.capture.completed
                # The other client saved its own record in this HOME.
                records = set((home / ".config/rui/requests").glob("*.json"))
                tty.send("\x1b[C", predicate=lambda: highlighted(tty.capture) == "Deny")
                tty.send("\r", marker)
                decisions = [json.loads(path.read_text()) for path in set((home / ".config/rui/requests").glob("*.json")) - records]
                assert [(item["action"], item["decision"]) for item in decisions] == [(second, "deny")], decisions
                assert not any((workspace / f"renderer-successor-{index}").exists() for index in (1, 2))
                tty.caller.send_signal(signal.SIGINT)
                tty.finish()
        finally:
            dispose_all(lambda: os.close(ready_read), lambda: os.close(ready_write))
        print("renderer: a card decides only the request it drew", flush=True)

        # Chat info is its own Layer, independent of an Activity read in flight.
        # Closing it and opening Settings > Keys must not let a delayed read reopen it.
        session = configure()
        marker = answer("info yields")
        holding = threading.Event()
        held = [threading.Event(), threading.Event()]
        released = [threading.Event(), threading.Event()]
        def hold_info_read(_):
            if holding.is_set():
                for ready, resume in zip(held, released):
                    if not ready.is_set():
                        ready.set()
                        resume.wait(10)
                        break
            return True
        proxy = canonical.ReplyProxy(host, "/v1/activity-page", lambda response: response, before_forward=hold_info_read)
        with terminal(session, columns=140) as tty:
            tty.send("info yields\r", marker)
            holding.set()
            fixture.wait_for(tty.draining(held[0].is_set), "first held Activity page", timeout=10)
            tty.send("\x1bi", "Copy last answer")
            released[0].set()
            # The next Activity read carries the info inspection request.
            fixture.wait_for(tty.draining(held[1].is_set), "info Activity page", timeout=10)
            tty.send("\x1b", predicate=lambda: "Copy last answer" not in tty.capture.completed)
            row, line = next((index, line) for index, line in enumerate(tty.capture.completed.split("\n")) if "Settings" in line)
            col = line.index("Settings") + 1
            tty.send(f"\x1b[<0;{col};{row + 1}M\x1b[<0;{col};{row + 1}m", "Notifications")
            keys = tty.send("\x1b[B" * 6 + "\r", "earlier message")
            assert all(stale not in keys for stale in ("/help", "Commands", "Marks", "Esc returns", "Ctrl-X twice", 'ctrl+g', 'ctrl+d', 'ctrl+n', 'ctrl+end', 'ctrl+c/d', 'pgup/pgdn', 'first session', 'latest / last', 'scroll / select')), keys
            frames = tty.every_frame()
            released[1].set()
            time.sleep(1.5)
            assert "earlier message" in tty.capture.completed, tty.capture.completed
            for frame in frames:
                assert " · info" not in frame and "Copy last answer" not in frame, frame
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        proxy.close()
        proxy = None
        print("renderer: delayed info inspection cannot cover Settings > Keys after the panel closes", flush=True)

        # A short fresh feed clamps at its first saved row; scrolling does
        # not add a start label or duplicate the admitted Message and reply.
        session = configure()
        marker = answer("fresh start")
        with terminal(session) as tty:
            tty.send("fresh start\r", marker)
            frames = tty.every_frame()
            # Only the first PgUp moves a feed this short; the rest draw nothing.
            shown = tty.send("\x1b[5~" * 3, predicate=lambda: "› fresh start" in conversation_text(tty.capture.completed)
                and marker in conversation_text(tty.capture.completed) and "↓" in tty.capture.completed)
            assert shown.count("› fresh start") == 1 and shown.count(marker) == 1, shown
            assert shown.index("› fresh start") < shown.index(marker), shown
            assert "Start of conversation" not in shown, shown
            for frame in frames:
                assert "Earlier messages unavailable" not in frame and "Start of conversation" not in frame, frame
            tty.caller.send_signal(signal.SIGINT)
            tty.finish()
        print("renderer: a fresh Session scrolls to its first row without labels or duplicate Messages", flush=True)

        completed = True
    finally:
        dispose_all(lambda: proxy.close() if proxy is not None else None,
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5))
        if completed:
            shutil.rmtree(state)
        else:
            retain_failure_state("renderer failure state", state)
        resource.setrlimit(resource.RLIMIT_NOFILE, original_limit)


def provider_line_cases():
    """First-run screen: choices, device cancellation, masked keys and no TTY."""
    state = screen_fixture_root("rui-provider-screen.")
    store = state / "store"
    endpoint = fixture.SuccessEndpoint([])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = None
    completed = False
    try:
        host_key = state / "host-openai.key"
        host_key.write_text("fixture-provider-choice-key\n")
        host_key.chmod(0o600)
        host_codex = state / "host-codex.json"
        codex_fixture.credentials(host_codex)
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        host, _ = host_process.start_ready_process(
            [fixture.RUI, "host", "serve", "--store", store,
             "--test-codex-fixture-endpoint", url, "--test-openai-fixture-endpoint", url],
            env={**os.environ, "RUI_OPENAI_KEY_FILE": str(host_key), "RUI_CODEX_CREDENTIAL_FILE": str(host_codex)},
            required_fields={"execution": "enabled", "nghttp2": "1.70.0"})
        no_tty = state / "no-tty"
        no_tty.mkdir()
        refused = subprocess.run([str(fixture.RUI)], cwd=state,
            env={**os.environ, "HOME": str(no_tty)}, capture_output=True, text=True, timeout=5)
        assert refused.returncode == 2 and "[terminal_required]" in refused.stderr, refused
        assert "rui needs terminal input and output" in refused.stderr, refused.stderr
        assert not (no_tty / ".config").exists() and not (no_tty / ".local").exists()
        scripted = subprocess.run([str(fixture.RUI), "session", "start", "--store", str(no_tty / "store")],
            cwd=state, env={**os.environ, "HOME": str(no_tty)}, input="script task",
            capture_output=True, text=True, timeout=5)
        assert scripted.returncode == 6 and "[store_unavailable]" in scripted.stderr, scripted
        assert "› ChatGPT    API key" not in scripted.stdout and "Provider: [c]" not in scripted.stdout
        assert not (no_tty / ".config").exists() and not (no_tty / "store").exists()
        for choice in ("codex", "ready-key", "key", "device", "escape"):
            home = state / choice
            config = home / ".config/rui"
            config.mkdir(parents=True, mode=0o700)
            if choice in ("codex", "ready-key"):
                codex_fixture.credentials(config / "codex.json")
                (config / "openai.key").write_text("fixture-provider-choice-key\n")
                (config / "openai.key").chmod(0o600)
            selected_store = home / "store" if choice == "key" else store
            master, slave = open_pty()
            original = termios.tcgetattr(slave)
            caller = None
            try:
                env = {**os.environ, "HOME": str(home), "TERM": "xterm-256color", "RUI_TEST_LOGIN": "waiting"}
                env.pop("RUI_CODEX_CREDENTIAL_FILE", None)
                env.pop("RUI_OPENAI_KEY_FILE", None)
                caller = spawn([str(fixture.RUI), "--store", str(selected_store)], cwd=state,
                    env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                    default_signals=(signal.SIGINT,))
                if choice in ("codex", "ready-key"):
                    provider_prompt(master)
                    key_file = config / "openai.key"
                    key_before = key_file.read_bytes(), key_file.stat().st_mtime_ns
                    os.write(master, b"\x1b[C\r" if choice == "ready-key" else b"\r")
                    overview_frame(master, overview_title)
                    provider = "openai" if choice == "ready-key" else "codex"
                    assert f"provider={provider}\n" in (config / "preferences").read_text()
                    assert (key_file.read_bytes(), key_file.stat().st_mtime_ns) == key_before
                else:
                    offered = provider_prompt(master)
                    assert "API key" in offered and "Provider: [c]" not in offered, offered
                    if choice == "key":
                        os.write(master, b"\x1b[C\r")
                        await_screen(master, "API key")
                        os.write(master, b"\r")
                        read_terminal(master, "Invalid API key")
                        os.write(master, b"sk-screen-secret")
                        masked = read_terminal(master, "••••••••••••••••")
                        assert "sk-screen-secret" not in masked, masked
                        os.write(master, b"\r")
                        overview_frame(master, overview_title)
                        assert (config / "openai.key").read_text() == "sk-screen-secret\n"
                        assert "provider=openai\n" in (config / "preferences").read_text()
                        assert stat.S_IMODE((config / "openai.key").stat().st_mode) == 0o600
                    elif choice == "device":
                        os.write(master, b"\r")
                        waiting = read_terminal(master, "BDL9-KI88H")
                        assert "auth.openai.com/codex/device · BDL9-KI88H" in waiting, waiting
                        assert "Waiting for ChatGPT" in waiting, waiting
                        os.write(master, b"\x1b")
                        read_terminal(master, "› ChatGPT    API key", fresh=True)
                    else:
                        # Choice typing does nothing. Escape from key entry
                        # returns to a visibly different choice frame before
                        # Ctrl-C, so it cannot become an Alt+Ctrl-C sequence.
                        os.write(master, b"hello\x1b[C\r")
                        read_terminal(master, "esc back")
                        os.write(master, b"\x1b")
                        read_terminal(master, "←→ choose · enter", fresh=True)
                os.write(master, b"\x03")
                output, errors = terminal_exit(caller, master)
                assert caller.returncode == 0, (choice, caller.returncode, errors)
                assert "sk-screen-secret".encode() not in output + errors
                assert os_semantics.user_termios(termios.tcgetattr(slave)) == os_semantics.user_termios(original)
                if choice in ("device", "escape"):
                    assert not (config / "preferences").exists()
                    assert not (config / "codex.json").exists()
                assert not (config / "requests").exists(), "sign-in captured a Message"
            finally:
                dispose_all(lambda: stop_process(caller, timeout=5) if caller is not None else None,
                            lambda: run(home, "host", "pause", "--store", selected_store)
                            if choice == "key" and selected_store.exists() else None,
                            lambda: close_pty(master), lambda: close_pty(slave))
        assert endpoint.requests == [], endpoint.requests
        completed = True
        print("provider screen: no-TTY, choices, device back, invalid/masked key and restored terminal passed", flush=True)
    finally:
        dispose_all(lambda: fixture.stop_host(host) if host is not None else None,
                    endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5))
        if completed:
            shutil.rmtree(state)
        else:
            retain_failure_state("provider screen failure state", state)


def main(selected="all"):
    import canonical_failure_cases
    import canonical_fixture
    import session_chrome_cases
    import terminal_restoration_cases
    from terminal_process_test import prove_terminal_process
    split_callers = selected == "callers"
    assert selected in ("all", "callers", "caller-core", "renderer", "compiled-models", "terminal-waits", "help", "copy", "provider-lines", "session-chrome"), selected
    if selected in ("all", "renderer", "session-chrome"):
        session_chrome_cases.main()
    if selected == "session-chrome":
        return
    if selected in ("all", "callers", "caller-core", "provider-lines"):
        provider_line_cases()
    if selected == "provider-lines":
        return
    if selected in ("all", "callers", "caller-core", "copy"):
        persistent_copy_case()
    if selected == "copy":
        return
    if selected == "help":
        help_case()
        return
    if selected in ("all", "callers", "compiled-models"):
        compiled_model_cases()
    if selected == "compiled-models":
        return
    if selected == "renderer":
        renderer_cases()
        return
    if selected == "all":
        renderer_cases()
    if split_callers:
        selected = "all"
    if selected == "all":
        help_case()
    if selected in ("all", "terminal-waits"):
        prove_terminal_process()
        pipe_wait_oracles()
        command_wait_oracles()
        conversation_wait_oracles()
    if selected == "terminal-waits":
        return
    if selected == "all":
        silent_read_edit_cases()
    if selected == "all" and not split_callers:
        terminal_restoration_cases.main()
        canonical_failure_cases.main()
    if selected == "caller-core":
        selected = "all"
    state = screen_fixture_root("rui-human-cli.")
    home = state / "home"
    home.mkdir()
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
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
        defaults(home, "--store", store)
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
        assert invalid.returncode == 6 and b"[home_unavailable]" in invalid.stderr, invalid
        assert not os.path.exists(invalid_home + b"/.config"), invalid
        bidi_store = state / "store-\u202ehidden"
        bidi_store.mkdir(mode=0o700)
        bidi_home = state / "bidi-home"
        bidi_home.mkdir()
        canonical_bidi_store = bidi_store.resolve()
        bidi_setup = defaults(bidi_home, "--store", bidi_store)
        assert (bidi_setup["store"], bidi_setup["store_source"]) == (str(canonical_bidi_store), "saved"), bidi_setup
        assert f"store={canonical_bidi_store}\n" in (bidi_home / ".config/rui/preferences").read_text()
        no_home = subprocess.run([str(fixture.RUI), "defaults", "inspect"],
            env={key: value for key, value in os.environ.items() if key != "HOME"},
            capture_output=True, text=True)
        assert no_home.returncode == 6 and "[home_unavailable]" in no_home.stderr, no_home
        alias = state / "store-alias"
        alias.symlink_to(store, target_is_directory=True)
        defaults(preferences_home, "--store", alias,
            "--provider", "codex", "--model", "gpt-6-luna")
        saved = preferences_home / ".config/rui/preferences"
        assert saved.read_text() == f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n"
        preference_edits(preferences_home, store)
        original_preferences = saved.read_text()
        # Malformed saved fields are an environment repair, even when a valid
        # edit reaches the locked snapshot. Refusals never rewrite that file.
        for invalid_saved in (
                original_preferences.replace(f"store={store.resolve()}", "store=relative"),
                original_preferences.replace("model=gpt-6-luna", "model=two words"),
                original_preferences.replace("provider=codex", "provider=bad!provider"),
                original_preferences.replace("provider=codex", "provider=")):
            invalid_bytes = invalid_saved.encode()
            saved.write_bytes(invalid_bytes)
            for defaults_args in (("inspect",), ("configure", "--notifications", "on")):
                refused_saved = invoke(preferences_home, "defaults", *defaults_args, expect=6)
                assert not refused_saved.stdout and "[preferences_invalid]" in refused_saved.stderr, refused_saved
                assert saved.read_bytes() == invalid_bytes, (defaults_args, "malformed saved defaults were rewritten")
        saved.write_text(original_preferences.replace("model=gpt-6-luna", "model=gpt-5.6-sol"))
        assert saved.read_text().endswith("provider=codex\nmodel=gpt-5.6-sol\n")
        assert defaults(preferences_home)["model"] == "gpt-5.6-sol"
        saved.write_text(original_preferences)
        assert saved.stat().st_mode & 0o777 == 0o600
        assert saved.parent.stat().st_mode & 0o777 == 0o700
        missing_setup = defaults(preferences_home)
        assert (missing_setup["store"], missing_setup["store_source"]) == (str(store.resolve()), "saved"), missing_setup
        assert missing_setup["local_credentials"]["codex"] == "missing" and missing_setup["next_session"] == {
            "status": "selected", "provider": "codex", "model": "gpt-6-luna", "local_credential": "missing"}, missing_setup
        assert missing_setup["host"]["status"] == "ready", missing_setup
        assert missing_setup["host"]["capabilities"]["providers"]["codex"] != "chatgpt_device", missing_setup
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
        assert configured_setup["local_credentials"]["codex"] == "configured", configured_setup
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
            assert blocked.returncode == 0 and json.loads(blocked.stdout)["local_credentials"]["codex"] == "credential_error", blocked
        finally:
            dispose_all(credential.unlink)
        codex_fixture.credentials(credential, state="refresh_pending")
        assert defaults(preferences_home)["local_credentials"]["codex"] == "refresh_required"
        assert "state=refresh_pending" in credential.read_text(), "status must not refresh"
        credential.chmod(0o644)
        assert defaults(preferences_home)["local_credentials"]["codex"] == "credential_error"
        credential.unlink()
        defaults(preferences_home, "--provider", "other", success=False)
        defaults(preferences_home, "--model", "gpt-5.5")
        assert saved.read_text().endswith("model=gpt-5.5\n")
        defaults(preferences_home, "--model", "gpt-6-luna")
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        original_defaults = saved.read_bytes()
        for flag, value, code, accepted in (
                ("--model", "two words", "preference_model_invalid",
                 "a supported model ID of 1-256 printable non-space ASCII bytes"),
                ("--store", "relative-store", "preference_store_invalid",
                 "an existing private absolute Store directory"),
                ("--store", str(state / "missing"), "preference_store_invalid",
                 "an existing private absolute Store directory")):
            refused_edit = subprocess.run([str(fixture.RUI), "defaults", "configure", flag, value],
                cwd=state, env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=5)
            assert refused_edit.returncode == 2 and not refused_edit.stdout, refused_edit
            assert f"[{code}]" in refused_edit.stderr and flag in refused_edit.stderr, refused_edit
            assert f"Accepted: {accepted}." in refused_edit.stderr, refused_edit
            assert saved.read_bytes() == original_defaults, (flag, value, "refused edit changed defaults")
        # A directory in the temporary-file slot is an honest save failure;
        # no partial replacement may appear as a saved preference.
        temp = saved.parent / "preferences.tmp"
        temp.mkdir()
        blocked = subprocess.run([str(fixture.RUI), "defaults", "configure", "--store", str(store)],
            env={**os.environ, "HOME": str(preferences_home)},
            capture_output=True, text=True, timeout=2)
        assert blocked.returncode == 6 and "[preferences_unavailable]" in blocked.stderr, blocked
        assert saved.read_text().endswith("model=gpt-6-luna\n")
        temp.rmdir()
        os.mkfifo(temp, mode=0o600)
        try:
            blocked = subprocess.run([str(fixture.RUI), "defaults", "configure", "--store", str(store)],
                env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=2)
            assert blocked.returncode == 6 and "[preferences_unavailable]" in blocked.stderr, blocked
            assert saved.read_text().endswith("model=gpt-6-luna\n")
        finally:
            dispose_all(temp.unlink)
        codex_fixture.credentials(credential)
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        stale = defaults(preferences_home)
        assert stale["local_credentials"]["codex"] == "configured" and stale["next_session"] == {"status": "unsupported_provider"}, stale
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        defaults(preferences_home, "--store", store)
        assert saved.read_text().endswith("provider=retired\nmodel=old-model\n")
        defaults(preferences_home, "--provider", "codex")
        assert saved.read_text().endswith("provider=codex\nmodel=\n")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=retired\nmodel=old-model\n")
        defaults(preferences_home, "--provider", "codex", "--model", "gpt-6-luna")
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=old-model\n")
        prospective = defaults(preferences_home)["next_session"]
        # A model Rui does not list is still the next Session's, with default limits.
        assert prospective["status"] == "selected" and prospective["model"] == "old-model", prospective
        assert defaults(preferences_home)["model"] == "old-model", "inspection rewrote the stale pin"
        defaults(preferences_home, "--model", "gpt-6-luna")
        saved.rename(saved.parent / "preferences.backup")
        sole = defaults(preferences_home)
        assert sole["provider"] is None and sole["next_session"] == {
            "status": "selected", "provider": "codex", "model": "gpt-6.1-sol", "local_credential": "configured"}, sole
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
        config = admit(home, "session", "configure", "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol",
            "--tools", "bash", "--permission-mode", "ask")
        assert config["admission"]["answer"]["status"] == "accepted", config
        session = config["admission"]["answer"]["session"]
        # A one-shot read selects the saved Store; explicit targeting bypasses
        # even corrupt preferences, and an invalid saved destination never falls back.
        assert json.loads(run(preferences_home, "session", "inspect", "--session", session))["work"]["state"]["kind"] == "idle"
        saved.write_text("version=9\n")
        invalid_preferences = invoke(preferences_home, "session", "inspect", "--session", session, expect=6)
        assert not invalid_preferences.stdout and "[preferences_invalid]" in invalid_preferences.stderr, invalid_preferences
        assert json.loads(run(preferences_home, "session", "inspect", "--store", store,
            "--session", session))["work"]["state"]["kind"] == "idle"
        with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", session], env={**os.environ, "HOME": str(preferences_home)},
        ) as (entered, master):
            assert "Session:" not in read_terminal(master, "› ")
            assert "Copy last answer" in chat_info_frame(master)
            terminal_step(master, "\x03", "Detached.")
            assert entered.wait(timeout=5) == 0
        saved.unlink()
        fallback.parent.mkdir(parents=True)
        fallback.symlink_to(store, target_is_directory=True)
        with terminal_process([str(fixture.RUI), "session", "resume", "--", session],
            env={**os.environ, "HOME": str(preferences_home)},
        ) as (entered, master):
            assert "Session:" not in read_terminal(master, "› ")
            assert "Copy last answer" in chat_info_frame(master)
            terminal_step(master, "\x03", "Detached.")
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
            dispose_all(lambda: close_pty(slave), lambda: close_pty(master))
        assert entered.returncode == 6 and b"[store_unavailable]" in entered.stderr, entered.stderr
        assert not (state / "missing").exists() and not fallback.exists()
        assert run(preferences_home, "request", "list") == before_missing
        saved.write_text(f"version=1\nstore={store.resolve()}\nprovider=codex\nmodel=gpt-6-luna\n")
        assert json.loads(run(home, "session", "inspect", "--store", store, "--session", session))["work"]["state"]["kind"] == "idle"
        before = run(preferences_home, "request", "list")
        invalid_store = subprocess.run([str(fixture.RUI), "session", "send", "--store", "", "--to",
            session], env={**os.environ, "HOME": str(preferences_home)},
            input="not sent", capture_output=True, text=True, timeout=5)
        assert invalid_store.returncode == 2 and "[store_path_malformed]" in invalid_store.stderr, invalid_store
        assert invalid_store.stdout == "" and run(preferences_home, "request", "list") == before
        no_tty_home = state / "no-tty-home"
        no_tty_home.mkdir()
        no_terminal = subprocess.run([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(no_tty_home)}, capture_output=True, text=True, timeout=5)
        assert no_terminal.returncode == 2 and "rui needs terminal input and output" in no_terminal.stderr
        assert "[terminal_required]" in no_terminal.stderr, no_terminal.stderr
        assert not (no_tty_home / ".config").exists(), "non-TTY invocation created preferences or a request"
        assert not (no_tty_home / ".local/share/rui/store").exists(), "non-TTY invocation changed the Store"
        before_missing = set(json.loads(run(preferences_home, "request", "list")))
        master, slave = open_pty()
        try:
            deferred = spawn([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(preferences_home)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        except BaseException:
            dispose_all(lambda: close_pty(master), lambda: close_pty(slave))
            raise
        try:
            offered = provider_prompt(master)
            assert "› ChatGPT    API key" in offered and "API key" in offered, offered
            os.write(master, b"\x03")
            terminal_exit(deferred, master)
            assert deferred.wait(timeout=5) == 0
            assert set(json.loads(run(preferences_home, "request", "list"))) == before_missing
        finally:
            dispose_all(lambda: stop_process(deferred, timeout=5),
                        lambda: close_pty(master), lambda: close_pty(slave))
        explicit_home = state / "explicit-home"
        explicit_config = explicit_home / ".config/rui"
        explicit_config.mkdir(parents=True, mode=0o700)
        malformed = explicit_config / "preferences"
        malformed.write_text("version=9\n")
        malformed.chmod(0o600)
        master, slave = open_pty()
        try:
            explicit = spawn([str(fixture.RUI), "--store", str(store),
                "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
                env={**os.environ, "HOME": str(explicit_home)},
                stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            dispose_all(lambda: close_pty(master), lambda: close_pty(slave))
            raise
        try:
            assert "› ChatGPT    API key" in provider_prompt(master)
            # Another client installs a fixture credential while this caller
            # waits for a choice. Its explicit selectors must still bypass the
            # malformed prospective defaults when it rechecks readiness.
            codex_fixture.credentials(explicit_config / "codex.json")
            welcome = overview_frame(master, overview_title, keys=b"\r", timeout=10)
            assert all(noise not in welcome for noise in ("Session:", "Provider:", "Model:", "request:")), welcome
            assert not (explicit_config / "requests").exists(), "the overview captured a request"
            assert malformed.read_text() == "version=9\n"
            assert overview_store(leave_overview(master)) == str(store.resolve())
            assert explicit.wait(timeout=5) == 0
        finally:
            dispose_all(lambda: stop_process(explicit, timeout=5),
                        lambda: close_pty(master), lambda: close_pty(slave))
        # A renewal-due opaque credential arrives while the prompt is open. It
        # remains usable for creation.
        (explicit_config / "codex.json").unlink()
        master, slave = open_pty()
        try:
            expiring = spawn([str(fixture.RUI), "--store", str(store),
                "--provider", "codex", "--model", "gpt-6-luna"], cwd=workspace,
                env={**os.environ, "HOME": str(explicit_home)},
                stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            dispose_all(lambda: close_pty(master), lambda: close_pty(slave))
            raise
        try:
            assert "› ChatGPT    API key" in provider_prompt(master)
            credential_file = explicit_config / "codex.json"
            codex_fixture.credentials(credential_file, access="synthetic-opaque-access")
            renewed_at = int(time.time()) - 8 * 24 * 60 * 60 - 1
            credential_file.write_text(credential_file.read_text().replace("expires_at=4102444800", "expires_at=0").replace("refreshed_at=1750000000", f"refreshed_at={renewed_at}"))
            assert defaults(preferences_home, environment={"RUI_CODEX_CREDENTIAL_FILE": str(credential_file)})["local_credentials"]["codex"] == "renewal_due"
            welcome = overview_frame(master, overview_title, keys=b"\r")
            assert "Session:" not in welcome and "Permission:" not in welcome, welcome
            leave_overview(master)
            assert expiring.wait(timeout=5) == 0
            assert malformed.read_text() == "version=9\n"
        finally:
            dispose_all(lambda: stop_process(expiring, timeout=5),
                        lambda: close_pty(master), lambda: close_pty(slave))
        longer_store = state / "another-longer-store-selector"
        other_host = fixture.start_host(longer_store, url)
        try:
            for index, (before, after) in enumerate(((store, longer_store), (longer_store, store))):
                changing_home = state / f"changing-home-{index}"
                changing_home.mkdir()
                defaults(changing_home, "--store", before,
                    "--provider", "codex", "--model", "gpt-6-luna")
                master, slave = open_pty()
                try:
                    changing = spawn([str(fixture.RUI)], cwd=workspace,
                        env={**os.environ, "HOME": str(changing_home)},
                        stdin=slave, stdout=slave, stderr=slave)
                except BaseException:
                    dispose_all(lambda: close_pty(master), lambda: close_pty(slave))
                    raise
                try:
                    assert "› ChatGPT    API key" in provider_prompt(master)
                    defaults(changing_home, "--store", after)
                    codex_fixture.credentials(changing_home / ".config/rui/codex.json")
                    welcome = overview_frame(master, overview_title, keys=b"\r")
                    assert all(noise not in welcome for noise in ("Diagnostics:", "request:", "Session:")), welcome
                    assert overview_store(leave_overview(master)) == str(after.resolve())
                    assert not (changing_home / ".config/rui/requests").exists(), "the overview captured a request"
                    assert changing.wait(timeout=5) == 0
                finally:
                    dispose_all(lambda: stop_process(changing, timeout=5),
                                lambda: close_pty(master), lambda: close_pty(slave))
        finally:
            fixture.stop_host(other_host)
        codex_fixture.credentials(credential)
        # The CLI checks each name's spelling and repeats and sends nothing
        # when one fails; which names exist is the Host's to say.
        for index, (tools, code) in enumerate((("edit", "unknown_tool"), ("bash,edit", "unknown_tool"),
                                               ("edit,bash", "unknown_tool"), ("bash,bash", "internal_unexpected"),
                                               ("Bash", "unknown_tool"), ("none,bash", "unknown_tool"),
                                               ("bash,", "internal_unexpected"))):
            record = state / f"removed-tools-{index}.json"
            rejected = subprocess.run([str(fixture.RUI), "session", "configure", "--store", str(store),
                "--session", session, "--record", str(record), "--key", f"removed-tools-{index}",
                "--tools", tools], env={**os.environ, "HOME": str(preferences_home)},
                capture_output=True, text=True, timeout=10)
            assert rejected.returncode == (3 if code == "unknown_tool" else 1), (tools, rejected)
            assert (code in rejected.stdout if code == "unknown_tool" else f"[{code}]" in rejected.stderr), (tools, rejected)
            # A request the Host refuses was sent, so its capture stays.
            assert record.exists() == (code == "unknown_tool"), ("tool selection capture", tools)
        for tools, mode in (("none", "bypass"), ("none", "ask"),
                            ("bash", "bypass"), ("bash", "ask"),
                            ("web_search", "ask"), ("bash,web_search", "bypass")):
            warning_ref = create_session(preferences_home, "--store", store,
                  "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol",
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
                status = info_frame(master, warning_ref)
                assert permission_row(status, mode), status
                assert fixture.command("session", "inspect", "--store", store, "--session", warning_ref)["session"]["permission_mode"] == mode
                assert mode == "bypass" or "without asking" not in status, status
                terminal_step(master, "\x03", "Detached.")
                assert caller.wait(timeout=5) == 0
        records = preferences_home / ".config/rui/requests"
        before_records = set(records.glob("*.json"))
        sessions_before = run(preferences_home, "session", "list", "--store", store, "--all")
        master, slave = open_pty()
        caller = spawn([str(fixture.RUI)], cwd=workspace,
            env={**os.environ, "HOME": str(preferences_home)},
            stdin=slave, stdout=slave, stderr=slave)
        try:
            welcome = overview_frame(master, overview_title)
            assert "Attached to the ready Host" not in welcome and "Diagnostics:" not in welcome, welcome
            assert all(noise not in welcome for noise in ("request:", "New Session intent:", "Workspace:", "Provider:", "Permission:")), welcome
            leave_overview(master)
            assert caller.wait(timeout=5) == 0
            assert set(records.glob("*.json")) == before_records, "the overview captured a request"
            assert run(preferences_home, "session", "list", "--store", store, "--all") == sessions_before
        finally:
            dispose_all(lambda: stop_process(caller, timeout=5),
                        lambda: close_pty(master), lambda: close_pty(slave))
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
            blocked = spawn([str(fixture.RUI)], cwd=workspace,
                env={**os.environ, "HOME": str(blocked_home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            # The composer's capture fails before any send: the draft stays.
            overview_frame(master, overview_title)
            refused = overview_frame(master, lambda frame: "Not started: NotDir" in frame, keys=b"never captured\r")
            assert "never captured" in refused, refused
            os.write(master, b"\x03")
            # Keep the slave alive until all output is collected: Darwin can
            # discard unread PTY bytes when the last slave closes.
            output, errors = terminal_exit(blocked, master, timeout=20)
            # App writes the detach notice to stderr once it released the terminal.
            assert blocked.returncode == 0 and errors.startswith(b"\nDetached. Host work continues.\n"), (output, errors)
            assert b"request: " not in output + errors, (output, errors)
            assert os_semantics.user_termios(termios.tcgetattr(slave)) == os_semantics.user_termios(original_mode)
            assert (blocked_config / "requests").read_text() == "not a directory"
            assert run(preferences_home, "session", "list", "--store", store, "--all") == sessions_before
        finally:
            dispose_all(lambda: stop_process(blocked, timeout=5) if blocked is not None else None,
                        lambda: close_pty(master), lambda: close_pty(slave))
        credential.unlink()
        initial = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert initial["selected_message"] is None and initial["recent_messages"] == [], initial
        assert "rui needs terminal input and output" in subprocess.run(
            [str(fixture.RUI), "session", "resume", "--store", str(store), "--", session],
            env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=5).stderr
        assert config["request"] in json.loads(run(home, "request", "list"))
        assert json.loads(run(home, "request", "recover", config["request"]))["answer"]["replayed"] is True
        assert json.loads(run(home, "request", "recover", config["request"])) == {
            "context": {"store": str(store), "session": session, "key": config["request"], "kind": "configure"},
            "answer": {"status": "accepted", "replayed": True, "session": session, "revision": "1", "created": True}}

        text = state / "input"
        text.write_text("first input")
        dropped = invoke(home, "session", "send", "--store", store, "--to", session,
            "--test-drop-reply", "after-commit", input=text.read_text(), expect=4)
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
        attention = fixture.wait_for(lambda: (value if (value := fixture.observe(store, first))["state"]
            == "waiting_for_permission" else None), "first request attention")
        assert attention["work"]["state"]["kind"] == "approval", attention
        action = attention["work"]["first_action"]
        blocked = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert blocked["selected_message"] == first and blocked["work"]["state"]["kind"] == "approval", blocked
        assert [entry["action"] for entry in blocked["actionable_permissions"]] == [action], blocked
        queued = admit(home, "session", "send", "--to", session,
            input="queued behind permission")["request"]
        queued_fact = fixture.command("request", "inspect", "--store", store, "--key", queued)["observation"]
        assert queued_fact["status"] == "accepted" and "result" not in queued_fact, queued_fact
        assert queued_fact["state"] == "waiting_for_permission" and "binding" not in queued_fact, queued_fact
        assert queued_fact["work"]["state"]["kind"] == "approval" and queued_fact["work"]["first_action"] == action, queued_fact
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
            "--action", action, "--test-drop-reply", "after-commit", expect=4)
        assert lost_decision.stdout == "", lost_decision
        decision_key = CAPTURE_NOTICE.match(lost_decision.stderr).group(1)
        assert decision_key in json.loads(run(home, "request", "list"))
        recovered_decision = json.loads(run(home, "request", "recover", decision_key))["answer"]
        assert recovered_decision["status"] == "accepted" and recovered_decision["replayed"] is True
        fixture.wait_for(lambda: fixture.completed_observation(store, first), "first saved answer")
        fixture.wait_for(lambda: fixture.completed_observation(store, queued), "queued answer after permission")
        stale = admit(home, "action", "deny", "--store", store, "--session", session,
            "--action", action, expect=3)
        assert stale["admission"]["answer"]["status"] == "rejected", stale
        assert fixture.read_result(store, queued) == b"first answer"
        current = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert current["selected_message"] is None and [r["message"] for r in current["recent_messages"]] == [queued, first], current
        assert [r["outcome"] for r in current["recent_messages"]] == ["completed", "completed"], current
        settled = json.loads(run(home, "session", "inspect", "--store", store, "--session", session))
        assert settled["work"]["state"]["kind"] == "finished" and settled["pending_messages"] == "0", settled
        master, slave = open_pty()
        ready_read, ready_write = os.pipe()
        try:
            entered = spawn([str(fixture.RUI), "session", "resume", "--", session],
                env={**os.environ, "HOME": str(preferences_home),
                    "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=slave)
        except BaseException:
            dispose_all(lambda: close_pty(master), lambda: close_pty(slave), lambda: os.close(ready_read))
            raise
        finally:
            dispose_all(lambda: os.close(ready_write))
        try:
            greeting = read_terminal(master, "› ")
            assert all(noise not in greeting for noise in ("Session:", "Workspace:", "Provider:", "Model:", "Permission:", "Store:", queued)), greeting
            assert "\n› first input" in conversation_text(greeting) and "\nfirst answer" in conversation_text(greeting), greeting
            binding = chat_info_frame(master)
            bound_session = fixture.command("session", "inspect", "--store", store, "--session", session)["session"]
            assert bound_session["workspace"] == str(workspace.resolve()) and bound_session["provider"] == "codex", bound_session
            # A long read-only Folder keeps its basename rather than clipping
            # the right-hand path suffix; the canonical inspection above is full.
            folder = next(row.split("Folder", 1)[1].strip() for row in binding.split("\n")
                          if row.strip().startswith("Folder"))
            assert folder.endswith(workspace.resolve().name), binding
            assert folder.startswith(("…/", "~/", "/")), binding
            assert "gpt-6-sol" in binding and "asks before Bash/MCP" not in binding and permission_row(binding, "ask"), binding
            # The wide layout exposes the pinned Settings row without
            # leaving this conversation or changing its draft.
            terminal_capture(master).resize(140, 50)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 140, 0, 0))
            wide = keyed_frame(master, b"", lambda screen, x, y: "Settings" in screen and "first answer" in screen)
            row, line = next((index, line) for index, line in enumerate(wide.split("\n")) if "Settings" in line)
            col = line.index("Settings") + 1
            gesture = f"\x1b[<0;{col};{row + 1}M\x1b[<0;{col};{row + 1}m".encode()
            app_settings = keyed_frame(master, gesture, lambda screen, x, y: "Notifications" in screen and "Version" in screen)
            assert any("Sign-in" in row and "Codex" in row for row in app_settings.splitlines()), app_settings
            keys = keyed_frame(master, b"\x1b[B" * 6 + b"\r", lambda screen, x, y: "earlier message" in screen)
            for expected in ('enter    send / open', 'esc      back', '⇧enter   new line', 'ctrl+x   stop', '↑↓       scroll', 'ctrl+o   tool output', 'ctrl+p   earlier message', 'ctrl+r   retry', '/        skills', 'alt+a    archive', 'ctrl+c   leave'):
                assert expected in keys, (expected, keys)
            for key, meaning in (('tab', 'next panel/footer field'), ('⇧tab', 'previous panel/footer field'), ('←→', 'list/chat · info actions')):
                assert any(key in row and meaning in row for row in keys.splitlines()), (key, meaning, keys)
            assert all(stale not in keys for stale in ("/help", "Commands", "Marks", "Esc returns", "Ctrl-X twice", "shift+enter or ctrl+j", "‹ Rui · settings", 'ctrl+g', 'ctrl+d', 'ctrl+n', 'ctrl+end', 'ctrl+c/d', 'pgup/pgdn', 'first session', 'latest / last', 'scroll / select')), keys
            settings = keyed_frame(master, b"\x1b", lambda screen, x, y: "Notifications" in screen and "Version" in screen)
            assert "earlier message" not in settings, settings
            keyed_frame(master, b"\x1b", lambda screen, x, y: "first answer" in screen and "Rui · settings" not in screen)
            terminal_capture(master).resize(80, 50)
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 80, 0, 0))
            result = terminal_step(master, f"/result {queued}", "result: completed", composer=True)
            assert "result: completed\nfirst answer" in conversation_text(result), result
            terminal_step(master, "/requests", "Local recovery handles", composer=True)
            assert not (fresh_home / ".config/rui/requests").exists(), "re-entry should not require saved records"
            before_unsupported = set(json.loads(run(preferences_home, "request", "list")))
            for command in ("/upgrade", "/login", "/wait", "/inspect-action", "/exit", "/help"):
                notice = f"! Unknown command {command}"
                terminal_step(master, command, notice, composer=True)
                assert set(json.loads(run(preferences_home, "request", "list"))) == before_unsupported
            terminal_step(master, "/setup", "gpt-6-luna", composer=True)
            chat_info_frame(master)
            assert not credential.exists(), "unsupported in-session login created credentials"
            terminal_step(master, "/setup --model gpt-6-luna", "Saved defaults for future Sessions", composer=True)
            saved_default(master, "/setup --model gpt-5.5", "Model: gpt-5.5")
            interactive_saved = preferences_home / ".config/rui/preferences"
            saved_default(master, "/setup --clear-model", "Model: not selected")
            assert interactive_saved.read_text().endswith("provider=codex\nmodel=\n")
            cleared_preferences = interactive_saved.read_bytes()
            # Neighbours differ: an identical rejection draws no new frame.
            for command, error in (("/setup --clear-model --model gpt-6-luna", "model_excludes_clear_model"),
                                   ('/setup --model ""', 'preference_model_invalid'),
                                   ("/setup --model gpt-6-luna --clear-model", "model_excludes_clear_model")):
                rejected = terminal_step(master, command, error, composer=True)
                if error == "preference_model_invalid":
                    assert "a model ID is 1–256 printable non-space ASCII bytes" in rejected, rejected
                    assert "active Session unchanged" not in rejected, rejected
                assert interactive_saved.read_bytes() == cleared_preferences
            chat_info_frame(master)
            active = fixture.command("session", "inspect", "--store", store, "--session", session)["session"]
            assert active["model"] == "gpt-6-sol" and active["permission_mode"] == "ask", active
            terminal_step(master, "/setup --model gpt-6-luna", "Saved defaults for future Sessions", composer=True)
            spaced_store = state / "spaced store"
            spaced_store.mkdir(mode=0o700)
            saved_default(master, f'/setup --store "{spaced_store}"', f"Store: {spaced_store.resolve()} (saved)")
            assert defaults(preferences_home)["store"] == str(spaced_store.resolve())
            quoted_store = state / 'quoted "store"'
            quoted_store.mkdir(mode=0o700)
            escaped_store = str(quoted_store).replace('"', r'\"')
            shown_store = str(quoted_store.resolve()).replace('"', r'\"')
            saved_default(master, f'/setup --store "{escaped_store}"', f"Store: {shown_store} (saved)")
            assert defaults(preferences_home)["store"] == str(quoted_store.resolve())
            terminal_step(master, '/setup --store "unfinished', "Usage: /setup", composer=True)
            assert defaults(preferences_home)["store"] == str(quoted_store.resolve())
            terminal_step(master, f'/setup --store "{store}"', "Saved defaults for future Sessions", composer=True)
            chat_info_frame(master)
            assert fixture.command("session", "inspect", "--store", store,
                "--session", session)["session"]["model"] == "gpt-6-sol"
            # Removed commands cannot configure or inspect through a second path.
            before_configure = fixture.command("session", "inspect", "--store", store, "--session", session)["session"]
            for command in ("/status", "/configure --model gpt-5.5", "/model"):
                terminal_step(master, command, "Unknown command", composer=True)
            assert fixture.command("session", "inspect", "--store", store, "--session", session)["session"] == before_configure
            chat_info_open(master)
            model_choice_frame(master, b"\x1b[B\x1b[B\x1b[B\r", query="")
            model_choice_frame(master, b"gpt-6-sol", query="gpt-6-sol", more=False)
            configured = panel_frame(master, lambda frame: not model_choice_shown(frame) and "saving" not in frame, b"\r")
            assert "gpt-6-sol" in configured and "request:" not in configured, configured
            # The natural body leaves the previous /setup result in the feed.
            # A typed Configure adds no CLI receipt to the info body itself.
            geometry = chat_info_geometry(configured)
            configured_body = "\n".join(geometry["rows"][geometry["top"]:geometry["input"] - 1])
            for receipt in ("Store:", "Session:", "key:", "admitted:", "replayed:"):
                assert receipt not in configured_body, configured
            panel_frame(master, lambda frame: "Copy last answer" not in frame, b"\x1b")
            chat_info_frame(master)
            assert "Detached. Host work continues." in terminal_step(master, "\x03", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            dispose_all(lambda: stop_process(entered, timeout=5),
                        lambda: os.close(ready_read), lambda: close_pty(master), lambda: close_pty(slave))
        assert fixture.observe(store, queued)["result"]["status"] == "completed"
        def rejected_decision(key, replayed):
            return {"context": {"store": str(store), "session": session, "key": key, "kind": "permission_decision"},
                "request_target": {"action": action, "decision": "deny"},
                "answer": {"status": "rejected", "replayed": replayed, "session": session, "action": action,
                    "decision": "deny", "code": "action_not_pending"}}
        recovered_stale = json.loads(invoke(home, "request", "recover", stale["request"], expect=3).stdout)
        assert recovered_stale == rejected_decision(stale["request"], True), recovered_stale
        stale_default = admit(home, "action", "deny", "--store", store, "--session", session,
            "--action", action, expect=3)
        assert stale_default["admission"] == rejected_decision(stale_default["request"], False), stale_default
        assert run(home, "request", "read-result", first, environment=render_environment) == "first answer"
        assert fixture.observe(store, first)["result"]["status"] == "completed"
        assert list(scratch.iterdir()) == []
        assert counter.read_text() == "x"

        before = set(json.loads(run(home, "request", "list")))
        gate = state / "captured-before-handle"
        with text.open("rb") as stdin:
            caller = subprocess.Popen(
                [str(fixture.RUI), "session", "send", "--to", session], stdin=stdin,
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
        sibling_config = admit(home, "session", "configure", "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol",
            "--tools", "bash", "--permission-mode", "ask")["admission"]
        sibling_session = sibling_config["answer"]["session"]
        assert sibling_config["context"] == {"store": str(store), "session": sibling_session,
            "key": sibling_config["context"]["key"], "kind": "configure"}, sibling_config
        assert sibling_config["answer"]["status"] == "accepted" and sibling_config["answer"]["created"] is True, sibling_config
        sibling_key = admit(home, "session", "send", "--to", sibling_session,
            input="two independent Actions")["request"]
        def two_actions():
            candidate = fixture.command("session", "inspect", "--store", store, "--session", sibling_session)
            return candidate if len(candidate["actionable_permissions"]) == 2 else None

        report = fixture.wait_for(two_actions, "two actionable siblings")
        pending, running = [row["action"] for row in report["actionable_permissions"]]
        assert report["selected_message"] == sibling_key, report
        attention = fixture.observe(store, sibling_key)
        assert attention["state"] == "waiting_for_permission", attention
        assert attention["work"]["state"]["kind"] == "approval" and attention["work"]["first_action"] == pending, attention
        run(home, "action", "allow", "--store", store, "--session", sibling_session,
            "--action", running)
        fixture.wait_for(lambda: sibling_started.exists(), "approved sibling in flight")
        attention = fixture.wait_for(lambda: (value if (value := fixture.observe(store, sibling_key)).get("work", {}).get("first_action")
            == pending else None), "sibling attention while another Action runs")
        assert attention["state"] == "processing", attention
        assert attention["work"]["state"]["kind"] == "bash" and attention["work"]["first_action"] == pending, attention
        assert attention["status"] == "accepted" and "result" not in attention, attention
        run(home, "action", "deny", "--store", store, "--session", sibling_session,
            "--action", pending)
        sibling_release.touch()
        fixture.wait_for(lambda: fixture.completed_observation(store, sibling_key), "sibling outcome")
        assert fixture.read_result(store, sibling_key) == b"siblings done"
        assert sibling_effect.read_text() == "y" and counter.read_text() == "x"

        failure_release = threading.Event()
        endpoint.responses.extend([
            (fixture.ResponseSpec(b"permanent failure", {}, 422), failure_release),
            fixture.sse_answer("successor-answer", "successor-reason", "successor-message", "successor done")[0],
        ])
        failure_session = create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol")
        failed_key = admit(home, "session", "send", "--to", failure_session,
            input="first failing Turn")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 6, "held first failed Turn")
        queued_key = admit(home, "session", "send", "--to", failure_session,
            input="queued successor")["request"]
        waiting = fixture.observe(store, queued_key)
        assert waiting["status"] == "accepted" and waiting["state"] == "queued" and "result" not in waiting, waiting
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
            assert "result: completed\nsuccessor done" in conversation_text(result), result
            terminal_step(master, "\x03", "Detached.")
            assert entered.wait(timeout=5) == 0

        stop_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("stopped-answer", "stopped-reason",
            "stopped-message", "must not appear")[0], stop_release))
        stop_session = create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol")
        stopped_key = admit(home, "session", "send", "--to", stop_session,
            input="running when stopped")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 8, "held stopped Turn")
        excluded_key = admit(home, "session", "send", "--to", stop_session,
            input="queued when stopped")["request"]
        excluded = fixture.observe(store, excluded_key)
        assert excluded["status"] == "accepted" and excluded["state"] == "queued" and "result" not in excluded, excluded
        stopped = fixture.command("session", "stop", "--store", store, "--session", stop_session,
            "--record", state / "stop.json", "--key", "human-stop")
        assert stopped["answer"]["status"] == "accepted", stopped
        stop_release.set()
        cancelled = fixture.wait_for(lambda: fixture.command("request", "inspect", "--store", store,
            "--key", stopped_key)["observation"].get("result"), "stopped Turn")
        assert cancelled["status"] == "cancelled", cancelled
        assert fixture.observe(store, excluded_key)["result"] == {"status": "cancelled", "code": "session_stopped"}

        known_sessions = {row["reference"] for row in json.loads(run(home, "session", "list", "--store", store, "--all"))["sessions"]}
        absent = next(candidate for candidate in ("000000", "111111", "222222") if candidate not in known_sessions)
        rejected = admit(home, "session", "send", "--to", absent,
            input="unknown session", expect=3)
        assert rejected["admission"]["answer"] == {"status": "rejected", "replayed": False,
            "session": absent, "code": "unknown_session"}, rejected
        refused = fixture.observe(store, rejected["request"])
        assert refused["status"] == "rejected" and refused["code"] == "unknown_session", refused
        assert "[unknown_session]" in rejected["stderr"], rejected["stderr"]
        assert "MutationNotAccepted" not in rejected["stderr"] and "Syntax and recovery" not in rejected["stderr"], rejected["stderr"]
        recovered_rejection = invoke(home, "request", "recover", rejected["request"], expect=3)
        assert "[unknown_session]" in recovered_rejection.stderr, recovered_rejection.stderr
        replayed_rejection = json.loads(recovered_rejection.stdout)
        assert replayed_rejection == {"context": {"store": str(store), "session": absent,
            "key": rejected["request"], "kind": "message"}, "answer": {"status": "rejected", "replayed": True,
            "session": absent, "code": "unknown_session"}, "input": rejected["admission"]["input"]}, replayed_rejection
        stop_record = state / "absent-stop.json"
        refused_stop = invoke(home, "session", "stop", "--store", store, "--session", absent,
            "--record", stop_record, "--key", "absent-stop", expect=3)
        assert json.loads(refused_stop.stdout)["answer"] == {"status": "rejected", "replayed": False,
            "session": absent, "code": "unknown_session"}, refused_stop
        repeated_stop = invoke(home, "session", "stop", "--store", store, "--session", absent,
            "--record", stop_record, "--key", "absent-stop", expect=1)
        assert not repeated_stop.stdout and "[internal_unexpected]" in repeated_stop.stderr, repeated_stop
        explicit_route = f"rui request recover --store $'{store}' --record $'{stop_record}' --kind session-stop"
        assert "[unknown_session]" in refused_stop.stderr, refused_stop.stderr
        replayed_stop = subprocess.run(["bash", "-c", shlex.quote(str(fixture.RUI)) + explicit_route[len("rui"):]],
            env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=20)
        assert replayed_stop.returncode == 3 and replayed_stop.stderr == refused_stop.stderr, replayed_stop
        assert json.loads(replayed_stop.stdout)["answer"] == {"status": "rejected", "replayed": True,
            "session": absent, "code": "unknown_session"}, replayed_stop
        assert rejected["admission"]["input"]["bytes"] == str(len(b"unknown session")), rejected

        large_answer = "x" * 4095 + "🍰" + "y" * (128 * 1024)
        endpoint.responses.append(fixture.sse_answer("large-answer", "large-reason",
            "large-message", large_answer)[0])
        large_session = create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol")
        large_key = admit(home, "session", "send", "--to", large_session,
            input="large output")["request"]
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
        race_session = create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol",
            "--tools", "bash", "--permission-mode", "ask")
        prior_receipt = invoke(home, "session", "send", "--to", race_session, input="prior")
        prior = CAPTURE_NOTICE.match(prior_receipt.stderr).group(1)
        prior_answer = json.loads(prior_receipt.stdout)
        assert prior_answer["context"] == {"store": str(store), "session": race_session, "key": prior, "kind": "message"}, prior_answer
        assert prior_receipt.stderr == CAPTURE_NOTICE.match(prior_receipt.stderr).group(0), prior_receipt.stderr
        fixture.wait_for(lambda: len(endpoint.requests) == 10, "held predecessor request")
        message_a = admit(home, "session", "send", "--to", race_session, input="A")["request"]
        queued_a = fixture.observe(store, message_a)
        assert queued_a["state"] == "queued" and "result" not in queued_a, queued_a
        race_predecessor_release.set()
        fixture.wait_for(lambda: len(endpoint.requests) == 11, "A processing request")
        race_message_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, message_a), "A outcome before Current")
        fixture.wait_for(lambda: fixture.completed_observation(store, prior), "predecessor completion")
        message_b = admit(home, "session", "send", "--to", race_session, input="B")["request"]
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
        interactive = create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol",
            "--tools", "bash", "--permission-mode", "ask")
        # The card's own PTY checks live in renderer_cases; this keeps the
        # exact Action's caller checks with the session flow that follows.
        interactive_key = admit(home, "session", "send", "--to", interactive,
            input="interactive request")["request"]
        current_action = fixture.wait_for(lambda: (value if (value := fixture.command("session", "inspect",
            "--store", store, "--session", interactive))["actionable_permissions"] else None), "interactive Action")
        action_id = current_action["actionable_permissions"][0]["action"]
        assert [item["action"] for item in current_action["actionable_permissions"]] == [action_id], current_action
        assert counter.read_text() == "x", "an unanswered Action ran"
        exact = json.loads(run(home, "action", "inspect", "--store", store, "--session", interactive,
            "--action", action_id))
        assert exact == {"action": action_id, "call_id": control_call, "arguments": padded_arguments}, exact
        mismatch = admit(home, "action", "allow", "--store", store, "--session", session,
            "--action", action_id, expect=3)
        assert mismatch["admission"]["answer"]["status"] == "rejected", mismatch
        assert mismatch["admission"]["answer"]["code"] == "target_mismatch", mismatch
        run(home, "action", "allow", "--store", store, "--session", interactive, "--action", action_id)
        fixture.wait_for(lambda: fixture.completed_observation(store, interactive_key), "interactive outcome")
        assert fixture.read_result(store, interactive_key) == b"interactive complete"
        assert counter.read_text() == "xx", counter.read_text()
        invalid_name = "human/name\n\x1b[2J\u202e"
        rejected_name = invoke(home, "session", "configure", "--store", store, "--session", invalid_name, expect=2)
        assert not rejected_name.stdout and "[invalid_session_reference]" in rejected_name.stderr, rejected_name
        # Keep hostile bytes visible after home shortening; long absolute
        # folders otherwise elide whole leading components.
        control_workspace = home / "name\n\x1b[2J\u202e"
        control_workspace.mkdir()
        escaped_workspace = str(control_workspace).replace("\n", "\\n").replace("\x1b", "\\x1b").replace("\u202e", "\\u202e")
        control_session = create_session(home, "--store", store,
            "--workspace", control_workspace, "--provider", "codex", "--model", "gpt-6-sol")
        # Arbitrary Workspace bytes still escape safely in metadata and pages.
        current = terminal_safe_json(run(home, "session", "inspect", "--store", store, "--session", control_session))
        assert str(control_workspace) in json_strings(current), current
        listed = terminal_safe_json(run(home, "session", "list", "--store", store, "--all"))
        assert control_session in [entry["reference"] for entry in listed["sessions"]], listed
        assert str(control_workspace) in json_strings(listed), listed
        with terminal_process([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", control_session], env={**os.environ, "HOME": str(home)},
        ) as (entered, master):
            greeting = read_terminal(master, "› ")
            assert "Session:" not in greeting, greeting
            assert "\x1b[2J" not in greeting and "\u202e" not in greeting, greeting
            status = chat_info_frame(master)
            assert shown(folder_row(home, escaped_workspace) + "\n", status), status
            assert "\x1b[2J" not in status and "\u202e" not in status, status
            farewell = terminal_step(master, "\x03", "Resume: ")
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
            resumed = chat_info_frame(master)
            assert shown(folder_row(home, escaped_workspace) + "\n", resumed), resumed
            terminal_step(master, "\x03", "Resume: ")
            assert entered.wait(timeout=5) == 0
            defaults(home, "--store", store)
        unsafe_key = "message\n\x1b[2J\u202e"
        unsafe_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("unsafe-answer", "unsafe-reason",
            "unsafe-message", "safe result")[0], unsafe_release))
        unsafe_session = create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol")
        unsafe_text = state / "unsafe-input"
        unsafe_text.write_text("report status")
        run(home, "session", "send", "--to", unsafe_session,
            "--record", state / "unsafe-record.json", "--key", unsafe_key, input=unsafe_text.read_text())
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
                status = chat_info_frame(master)
                assert "\x1b[2J" not in status and "\u202e" not in status, status
                assert "Detached." in terminal_step(master, "\x03", "Detached.")
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
            assert "Session:" not in greeting and "\nsafe result" in conversation_text(greeting), greeting
            status = chat_info_frame(master)
            assert "Copy last answer" in status, status
            assert "\x1b[2J" not in status and "\u202e" not in status, status
            assert "Detached." in terminal_step(master, "\x03", "Detached.")
            assert entered.wait(timeout=5) == 0
        empty_session = create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol")
        empty_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("empty-answer", "empty-reason", "empty-message",
            "empty key answer")[0], empty_release))
        empty_input = state / "empty-input"
        empty_input.write_text("empty key input")
        admission = json.loads(run(home, "session", "send", "--to", empty_session,
            "--record", state / "empty-record.json", "--key", "", input=empty_input.read_text()))
        assert admission["answer"]["status"] == "accepted", admission
        fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store,
            "--session", empty_session)["work"]["state"]["kind"] == "working", "empty key active")
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
        editor_session = create_session(home, "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol")
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
        entered = spawn([str(fixture.RUI), "session", "resume", "--store", str(store),
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
                assert f"edited {index}" in conversation_text(observed), observed
                if index == 2:
                    assert "\n› line1\n  line2" in "\n".join(map(untimed, conversation_text(observed).split("\n"))), observed
                    assert "\nedited 2" in conversation_text(observed), observed
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
                await_screen(master, "", composer=True)
            endpoint.responses.append(fixture.sse_answer("paced-answer", "paced-reason",
                "paced-message", "paced edited")[0])
            os.write(master, b"a" * 100)
            read_terminal(master, "a" * 100)
            for _ in range(100):
                os.write(master, b"\x7f")
                time.sleep(0.025)  # Longer than the editor's repaint window.
            observed = terminal_step(master, "Z", "paced edited")
            assert "\n› Z" in conversation_text(observed), observed
            body = json.loads(endpoint.requests[-1])
            actual = next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user")
            assert actual == "Z", actual
            await_screen(master, "", composer=True)
            endpoint.responses.append(fixture.sse_answer("wrapped-answer", "wrapped-reason",
                "wrapped-message", "wrapped edit intact")[0])
            accepted = terminal_bulk(master, "a" * 2050 + "\x7f" * 2048, "wrapped edit intact")
            body = json.loads(endpoint.requests[-1])
            assert next(item["content"][0]["text"] for item in reversed(body["input"])
                if item.get("role") == "user") == "aa", body
            before = len(endpoint.requests)
            for invalid in (b"\xc3(\r", b"\xc3\r"):
                os.write(master, invalid)
                # A repeated identical notice redraws nothing.
                rejected = await_screen(master, "Input rejected; nothing sent.")
                assert "Input rejected; nothing sent." in rejected, rejected
            settle_screen(master, quiet=0.5)
            assert len(endpoint.requests) == before, "malformed UTF-8 reached Host"
            endpoint.responses.append(fixture.sse_answer("editor-limit-answer", "editor-limit-reason",
                "editor-limit-message", "limit accepted")[0])
            at_limit = "a" * (64 * 1024 - 2) + "é"
            # 64 KiB typed a KiB at a time is a third of the default budget on
            # an idle machine, and has run past it on a loaded runner.
            accepted = terminal_bulk(master, at_limit, "limit accepted", timeout=60)
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
                        lambda: close_pty(master), lambda: close_pty(slave))
        master, slave = open_pty()
        entered = spawn([str(fixture.RUI), "session", "resume", "--store", str(store),
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
                        lambda: close_pty(master), lambda: close_pty(slave))
        for columns in (7, 8):
            master, slave = open_pty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, columns, 0, 0))
            original_terminal = termios.tcgetattr(slave)
            before = set((fresh_home / ".config/rui/requests").glob("*.json"))
            entered = spawn([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", empty_session], env={**os.environ, "HOME": str(fresh_home)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            try:
                # A narrow terminal still draws the Session; it has no minimum size.
                read_terminal(master, "› ")
                os.write(master, b"\x03")
                output, errors = terminal_exit(entered, master)
                assert entered.returncode == 0, errors
                assert b"Detached. Host work continues." in errors, errors
                actual = termios.tcgetattr(slave)
                assert os_semantics.user_termios(actual) == os_semantics.user_termios(original_terminal)
                assert set((fresh_home / ".config/rui/requests").glob("*.json")) == before
            finally:
                dispose_all(lambda: stop_process(entered, timeout=5),
                            entered.stderr.close,
                            lambda: close_pty(master), lambda: close_pty(slave))
        observation_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("observed-later", "observed-later-reason",
            "observed-later-message", "observed later")[0], observation_release))
        observation_held, observation_continue = threading.Event(), threading.Event()
        master, slave = open_pty()
        original_terminal = termios.tcgetattr(slave)
        # The TUI starts a crashed Host once by itself. The Host it starts
        # inherits this https proxy and refuses it at startup, so that start
        # fails without serving the accepted Message, which the fixture Host
        # recovers below.
        entered = spawn([str(fixture.RUI), "session", "resume", "--store", str(store),
            "--", empty_session], env={**os.environ, "HOME": str(home), "HTTPS_PROXY": "https://proxy.invalid"},
            stdin=slave, stdout=slave, stderr=subprocess.PIPE)
        proxy = None
        try:
            read_terminal(master, "› ")
            # Cache actual Session facts before the Host is deliberately lost;
            # the stopped-Host modal probes edit those already-known facts.
            chat_info_frame(master)
            before = set(json.loads(run(home, "request", "list")))
            def hold_observation(response):
                observation_held.set()
                assert observation_continue.wait(15), "accepted observation gate was not released"
                return b""  # Lost read framing is the Host's loss, not partial success.

            def after_admission(response):
                assert json.loads(response.split(b"\r\n\r\n", 1)[1])["answer"]["status"] == "accepted"
                proxy.route = "/v1/activity-page"
                proxy.rewrite = hold_observation
                return response

            proxy = canonical_fixture.ReplyProxy(host, "/v1/message", after_admission)
            os.write(master, b"observe after Host loss\r")
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
            # Nobody asked the Host to stop, so the screen stays up and starts
            # it once by itself; that start fails and leaves the person a
            # retry. Nothing is sent again.
            starting = read_terminal(master, "Host starting")
            assert "Host stopped" not in starting, starting
            stopped = read_terminal(master, " · r retry")
            assert "× Host stopped · " in stopped, stopped
            assert "TruncatedResponse" not in stopped and "Not confirmed" not in stopped and "rui host start" not in stopped, stopped
            assert entered.poll() is None, "the Host's stop ended the TUI"
            # With the chat draft empty, Host recovery's `r` must still defer
            # to the modal editor. No Configure is submitted by these probes.
            chat_info_open(master)
            panel_frame(master, lambda frame: any(row.strip() == "r" for row in frame.split("\n")),
                        b"\x1b[B\x1b[B\x1b[B\x1b[B\r\x01\x0br")
            panel_frame(master, lambda frame: "Copy last answer" in frame
                        and not any(row.strip() == "r" for row in frame.split("\n")), b"\x1b")
            model_choice_frame(master, b"\x1b[A\r", query="")
            model_choice_frame(master, b"r", query="r")
            panel_frame(master, lambda frame: not model_choice_shown(frame) and "Copy last answer" in frame, b"\x1b")
            restored = panel_frame(master, lambda frame: "Copy last answer" not in frame and " · r retry" in frame, b"\x1b")
            assert "Host starting" not in restored, restored
            assert proxy.mutations == [("/v1/message", original)], "a lost observation retransmitted the Message"
            os.write(master, b"\x03")
            lost, errors = terminal_exit(entered, master)
            assert entered.returncode == 0, errors
            assert b"The Host stopped" not in errors and b"TruncatedResponse" not in errors, errors
            actual = termios.tcgetattr(slave)
            assert os_semantics.user_termios(actual) == os_semantics.user_termios(original_terminal)
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
                        lambda: close_pty(master), lambda: close_pty(slave))
        # SIGTERM, SIGINT and SIGHUP to the Host are a stop someone asked for, as
        # host-stop is: the open conversation says so and leaves it to r.
        for stop_signal in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            master, slave = open_pty()
            entered = spawn([str(fixture.RUI), "session", "resume", "--store", str(store),
                "--", empty_session], env={**os.environ, "HOME": str(home)},
                stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            served, host = host, None
            try:
                read_terminal(master, "› ")
                served.send_signal(stop_signal)
                # The Host shuts down itself; the signal does not end it.
                assert served.wait(timeout=10) >= 0, (stop_signal, served.returncode)
                stopped = read_terminal(master, "Host stopped · r start")
                assert "Host starting" not in stopped, stopped
                assert entered.poll() is None, "the Host's stop ended the TUI"
                os.write(master, b"\x03")
                _, errors = terminal_exit(entered, master)
                assert entered.returncode == 0, errors
            finally:
                dispose_all(lambda: stop_process(served),
                            lambda: stop_process(entered, timeout=5),
                            lambda: close_pty(master), lambda: close_pty(slave))
            # The TUI started no Host, so the Store's lease is free again.
            host = fixture.start_host(store, url)
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
            retain_failure_state("human CLI failure state", state)


if __name__ == "__main__":
    host_process.enter()
    main(sys.argv[2] if len(sys.argv) == 3 else "all")
