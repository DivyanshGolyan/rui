"""Injected PTY bytes through the native terminal owner, decoder and editor.

No Host, Store, terminal emulator or physical keyboard is involved. Each step
writes one complete chord; the production terminal reader consumes single bytes.
"""

import fcntl
import hashlib
import os
import platform
import resource
import select
import subprocess
import termios
import time

from host_process import dispose_all, stop_process
from terminal_process import open_pty
import os_semantics


def event(kind, point=0, mods=0, pasted=False, outcome="none", text="headTAIL", cursor=4):
    return (f"event {kind} {point} {mods} {str(pasted).lower()} "
            f"{outcome} {text.encode().hex()} {cursor}")


def replay(actor, name, steps, *, error=None):
    master, slave = open_pty()
    process = None
    original = None
    try:
        original = termios.tcgetattr(slave)
        # Nondefault user configuration catches restoration to generic sane.
        original[6][termios.VERASE] = b"\x08"
        original[0] |= termios.ICRNL
        termios.tcsetattr(slave, termios.TCSANOW, original)
        flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        process = subprocess.Popen([actor, "input-replay"], stdin=slave, stdout=slave,
                                   stderr=subprocess.PIPE, env=os.environ)
        output, records = bytearray(), bytearray()
        deadline = time.monotonic() + 8

        def drain_until(predicate):
            while not predicate():
                remaining = deadline - time.monotonic()
                assert remaining > 0, (name, "replay deadline", bytes(records), bytes(output))
                ready = select.select([master, process.stderr], [], [], min(remaining, 0.1))[0]
                for fd in ready:
                    data = os.read(fd if isinstance(fd, int) else fd.fileno(), 4096)
                    assert data, (name, "unexpected EOF", bytes(records), process.poll())
                    (output if fd == master else records).extend(data)
                assert len(output) + len(records) < 65536, (name, "transcript overflow")

        drain_until(lambda: records == b"ready\n")
        expected = ["ready"]
        for data, lines in steps:
            # Keep a chord together across scheduler pauses. Fragmentation at
            # every byte boundary belongs to the canonical TD2 unit corpus.
            assert os.write(master, data) == len(data)
            expected.extend(lines)
            wanted = ("\n".join(expected) + "\n").encode()
            drain_until(lambda: records.count(b"\n") >= len(expected))
            assert bytes(records) == wanted, (name, "decoded events", wanted, bytes(records))

        # Keep the slave until exit and drain both channels through reap. A
        # final decoded event is not evidence that restoration has completed.
        while process.poll() is None:
            remaining = deadline - time.monotonic()
            assert remaining > 0, (name, "exit deadline", bytes(records))
            for fd in select.select([master, process.stderr], [], [], min(remaining, 0.1))[0]:
                data = os.read(fd if isinstance(fd, int) else fd.fileno(), 4096)
                (output if fd == master else records).extend(data)
        process.wait(timeout=max(0.001, deadline - time.monotonic()))
        for fd, destination in ((master, output), (process.stderr.fileno(), records)):
            while select.select([fd], [], [], 0)[0]:
                data = os.read(fd, 4096)
                if not data:
                    break
                destination.extend(data)
        assert len(output) + len(records) < 65536, (name, "transcript overflow")
        wanted = ("\n".join(expected) + "\n").encode()
        if error is None:
            assert process.returncode == 0 and bytes(records) == wanted, (name, process.returncode, bytes(records))
        else:
            assert process.returncode == 1 and bytes(records) == wanted + f"error: {error}\n".encode(), (
                name, process.returncode, bytes(records))
        for control in (b"\x1b[?1049h", b"\x1b[?2004h", b"\x1b[?2004l", b"\x1b[?25h", b"\x1b[?1049l"):
            assert output.count(control) == 1, (name, "terminal mode lifecycle", control, bytes(output))
        actual, expected_attributes = termios.tcgetattr(slave), list(original)
        assert os_semantics.user_termios(actual) == os_semantics.user_termios(expected_attributes), (name, "termios restoration", expected_attributes, actual)
        from terminal_restoration_integration import assert_file_flags
        assert_file_flags(fcntl.fcntl(slave, fcntl.F_GETFL), flags)
        print(bytes(records).decode(), end="")
        print(f"input replay: {name}: decoded events, exact draft/caret and restoration passed", flush=True)
    finally:
        # Stop/reap before fixture restoration or closure, even on assertion.
        dispose_all(lambda: stop_process(process, timeout=5) if process is not None else None,
                    lambda: process.stderr.close() if process is not None else None,
                    lambda: termios.tcsetattr(slave, termios.TCSANOW, original) if original is not None else None,
                    lambda: os.close(master), lambda: os.close(slave))


def input_replay_cases():
    actor = os.environ["RUI_TEST_TERMINAL_NOTICE"]
    with open(actor, "rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    print(f"input replay: {os_semantics.DESCRIPTION} "
          f"Python {platform.python_version()} RLIMIT_NOFILE={resource.getrlimit(resource.RLIMIT_NOFILE)} "
          f"actor_sha256={digest}", flush=True)
    submit = event("key_press", 106, 4, outcome="submit")  # CR -> LF under ICRNL.
    interrupt = event("key_press", 99, 4, outcome="ctrl_c")
    # Protocol vectors and goldens match canonical TD2 owner regressions.
    # ESC CR is the historical Shift+Enter capture, decoded as Alt-Enter;
    # nothing here claims to press Shift or Option on physical Mac hardware.
    for name, data, mods in (
        ("historical Shift+Enter ESC CR", b"\x1b\r", 2),
        ("Opt+Enter ESC LF", b"\x1b\n", 2),
        ("Kitty Shift+Enter", b"\x1b[13;2u", 1),
        ("Kitty Opt+Enter", b"\x1b[13;3u", 2),
        ("modifyOtherKeys Shift+Enter", b"\x1b[27;2;13~", 1),
        ("modifyOtherKeys Opt+Enter", b"\x1b[27;3;13~", 2),
    ):
        text = "head\nTAIL"
        replay(actor, name, [(data, [event("key_press", 13, mods, outcome="redraw", text=text, cursor=5)]),
                             (b"Z\r", [event("key_press", 90, outcome="redraw", text="head\nZTAIL", cursor=6),
                                       event("key_press", 106, 4, outcome="submit", text="head\nZTAIL", cursor=6)])])
    replay(actor, "ordinary Enter submits", [(b"\r", [submit])])
    replay(actor, "expired ESC then Enter submits", [(b"\x1b", ["expired escape"]), (b"\r", [submit])])
    replay(actor, "Kitty release does not insert or submit", [
        (b"\x1b[13;2:3u", [event("key_release", 13, 1)]), (b"\r", [submit])])
    for name, data in (("raw Ctrl-C", b"\x03"), ("Kitty Ctrl-C", b"\x1b[99;5u"),
                       ("modifyOtherKeys Ctrl-C", b"\x1b[27;5;99~"),
                       ("Ctrl-C interrupts incomplete CSI", b"\x1b[\x03")):
        replay(actor, name, [(data, [interrupt])])

    start, end = event("paste_start"), event("paste_end", pasted=True, text="headé\nZTAIL", cursor=8)
    pasted = [event("key_press", 233, pasted=True, outcome="redraw", text="headéTAIL", cursor=6),
              event("key_press", 106, 4, True, "redraw", "headé\nTAIL", 7),
              event("key_press", 90, pasted=True, outcome="redraw", text="headé\nZTAIL", cursor=8)]
    replay(actor, "marked multiline paste", [(b"\x1b[200~", [start]),
        ("é\nZ".encode(), pasted), (b"\x1b[201~", [end]),
        (b"\r", [event("key_press", 106, 4, outcome="submit", text="headé\nZTAIL", cursor=8)])])
    replay(actor, "pasted Ctrl-C is not an interrupt", [(b"\x1b[200~", [start]),
        (b"\x03", [event("key_press", 99, 4, True)]),
        (b"\x1b[201~", [event("paste_end", pasted=True)]),
        (b"\r", [event("key_press", 106, 4, outcome="invalid")])])
    replay(actor, "Esc before paste preserves framing", [(b"\x1b\x1b[200~", [
        event("key_press", 27, outcome="escape"), start]),
        (b"\x1b[201~\r", [event("paste_end", pasted=True), submit])])
    replay(actor, "unmatched paste end rejects submission", [(b"\x1b[201~", [event("paste_end")]),
        (b"\r", [event("key_press", 106, 4, outcome="invalid")])])
    # Doubling ESC is not a quoting mechanism inside paste. The stray ESC
    # alone rejects the draft; the exact end delimiter after it still ends
    # the paste, so the next keystroke is the user's and Enter sends nothing.
    replay(actor, "stray ESC before a paste end rejects the paste and still ends it", [(b"\x1b[200~", [start]),
        (b"\x1b\x1b[201~", [event("invalid", pasted=True), event("paste_end", pasted=True)]),
        (b"\r", [event("key_press", 106, 4, outcome="invalid")])])
    # A backslash-spelled delimiter is literal text, never a paste end.
    literal = b"\\x1b[201~"
    lines = [event("key_press", point, pasted=True, outcome="redraw",
                   text="head" + literal[:index + 1].decode() + "TAIL", cursor=5 + index)
             for index, point in enumerate(literal)]
    replay(actor, "escaped end-marker text retains paste custody", [(b"\x1b[200~", [start]),
        (literal, lines)], error="IncompleteTerminalInput")
    for name, prefix in (("incomplete CSI", b"\x1b["), ("incomplete UTF-8", b"\xc3"),
                         ("unterminated paste", b"\x1b[200~")):
        replay(actor, name, [(prefix, [start] if name == "unterminated paste" else [])],
               error="IncompleteTerminalInput")
    print("input replay: injected PTY evidence only; no physical keyboard/display qualification", flush=True)
