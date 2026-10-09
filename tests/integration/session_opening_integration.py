#!/usr/bin/env python3
"""Focused real-CLI opening witnesses; run with the assembled rui executable.

No metadata-only server substitutes for Host authority. These cases intentionally
fail on the old session/readLine CLI. They are not native display qualification.
"""
import errno
import fcntl
import json
import os
import pathlib
import pty
import re
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import threading
import time
import uuid

import dispatch_integration as host
from canonical_failure_integration import ReplyProxy
from conversation_page_integration import request as public_read
from control_integration import raw_request
from host_process import canonical_fixture_root
from human_cli_integration import action_ready, admit, run


class Terminal:
    """One reader, one absolute case budget, bounded transcript through reap."""
    def __init__(self, home, store, session, seconds=20):
        self.deadline = time.monotonic() + seconds
        self.transcript = bytearray()
        self.master, self.slave = pty.openpty()
        # Establish geometry before exec; a new PTY otherwise has zero rows
        # and columns and cannot discriminate ordinary bounded rendering.
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", 24, 100, 0, 0))
        self.original = termios.tcgetattr(self.slave)
        self.ready, writer = os.pipe()
        try:
            self.process = subprocess.Popen(
                [str(host.RUI), "--store", str(store), "--resume", session],
                env={**os.environ, "HOME": str(home),
                     "RUI_TEST_ACTION_READY_FD": str(writer)},
                pass_fds=(writer,), stdin=self.slave, stdout=self.slave,
                stderr=self.slave)
        except BaseException:
            os.close(self.ready)
            os.close(self.master)
            os.close(self.slave)
            raise
        finally:
            os.close(writer)

    def remaining(self):
        value = self.deadline - time.monotonic()
        assert value > 0, self.transcript.decode(errors="replace")
        return value

    def read(self):
        assert select.select([self.master], [], [], self.remaining())[0], self.transcript
        try:
            data = os.read(self.master, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b""
        self.transcript.extend(data)
        assert len(self.transcript) <= 1024 * 1024, "unbounded CLI transcript"
        return data

    def until(self, marker, start=None):
        start = len(self.transcript) if start is None else start
        needle = marker.encode()
        while needle not in self.transcript[start:]:
            assert self.read(), (marker, self.transcript)
        return bytes(self.transcript[start:]).decode(errors="replace")

    def send(self, value):
        os.write(self.master, value.encode())

    def command(self, value, marker="rui> \r\x1b[5C"):
        start = len(self.transcript)
        self.send(value + "\n")
        if marker != "rui> \r\x1b[5C":
            return self.until(marker, start)
        # Require this case's semantic reply, then a settled empty footer.
        # Commands accepted during a stream need not have been visually echoed.
        semantic = {
            "/setup": b"Host: ", "/status": b"Session: ",
            "/requests": b"Local recovery handles", "/configure": b"Rui: Configured.",
            "/recover": b"Original request accepted", "/wait": b"Permission attention",
            "/history": b"No older Conversation rows", "/resume": b"old Session and draft retained",
        }[value.split()[0]]
        while True:
            data = bytes(self.transcript[start:])
            replied = data.find(semantic)
            if replied >= 0:
                for frame in re.finditer(rb"\r(Rui:[^\r\n]*)\r\r\nrui> \r\x1b\[5C", data[replied:]):
                    if not frame[1].startswith(b"Rui: command running"):
                        return data.decode(errors="replace")
            assert self.read(), (value, self.transcript)

    def finish(self, nonzero=False):
        # Retaining the slave permits exact restoration inspection; close it
        # after the child exits so the master can deliver genuine EOF/EIO.
        while self.process.poll() is None:
            readable = select.select([self.master], [], [], min(.05, self.remaining()))[0]
            if readable:
                self.read()
        assert termios.tcgetattr(self.slave) == self.original, "terminal not restored"
        os.close(self.slave)
        self.slave = None
        while self.read():
            pass
        code = self.process.wait(timeout=self.remaining())
        assert (code != 0) == nonzero, (code, self.transcript)

    def close(self):
        try:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=5)
        finally:
            if self.slave is not None:
                os.close(self.slave)
            os.close(self.master)
            os.close(self.ready)


def key():
    return str(uuid.uuid4())


def configure(home, store, workspace, session):
    result = admit(home, "configure", "--store", store, "--session", session,
                   "--workspace", workspace, "--provider", "codex", "--model",
                   "model-a", "--tools", "bash", "--permission-mode", "ask")
    assert result["admission"]["answer"]["status"] == "accepted", result
    return result


def completed(store, request):
    host.wait_for(lambda: host.completed_observation(store, request),
                  "original saved result")


def assistant_rendering(state, home, store, endpoint):
    """Opening, staged history and keyed answers render only assistant markup."""
    raw = "# RENDER-HEADING\n**RENDER-STRONG** é\n\x1b[31mRAW-CONTROL"
    user = "# USER-MARKUP **USER-STRONG**"
    # More than one opening page leaves real older Conversation rows for
    # /history; otherwise a renderer test merely exercises an empty notice.
    for index in range(9):
        with endpoint.lock:
            endpoint.responses.append(host.sse_answer("render-response-" + str(index),
                "render-private-" + str(index), "render-item-" + str(index), raw)[0])
        request = key()
        host.message(state, store, request, "opening/render", user + str(index))
        completed(store, request)
    terminal = Terminal(home, store, "opening/render")
    try:
        terminal.until("rui> ", 0)
        opening = bytes(terminal.transcript)
        assert b"\x1b[1mRENDER-HEADING" in opening, opening
        start = len(terminal.transcript)
        terminal.send("/history\n")
        terminal.until("RENDER-STRONG", start)
        terminal.command("/status")
        history = bytes(terminal.transcript[start:])
        start = len(terminal.transcript)
        terminal.send("/result " + request + "\n")
        terminal.until("RENDER-STRONG", start)
        terminal.command("/status")
        answer = bytes(terminal.transcript[start:])
        for rendered in (opening, history, answer):
            assert b"\x1b[1mRENDER-HEADING" in rendered, rendered
            assert b"\x1b[1mRENDER-STRONG" in rendered, rendered
            assert b"# RENDER-HEADING" not in rendered, rendered
            assert b"**RENDER-STRONG**" not in rendered, rendered
            assert b"\\x1b[31mRAW-CONTROL" in rendered, rendered
            assert b"\x1b[31mRAW-CONTROL" not in rendered, rendered
        assert user.encode() in opening and user.encode() in history
        assert host.read_result(store, request) == raw.encode(), "presentation rewrote raw result"
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        terminal.close()


def historical_export(state, home, store, workspace, endpoint, owner):
    """Large live values stay complete; both historical paths give usable exports."""
    session = "opening/omission' $(touch injected) é\\A\n\x1bF"
    configuration = configure(home, store, workspace, session)
    user = "OMIT-USER-BEGIN" + "u" * (8193 - 15)
    answer = "OMIT-ANSWER-BEGIN" + "a" * (8229 - 33) + "OMIT-ANSWER-END!"
    assert len(user.encode()) == 8193 and len(answer.encode()) == 8229
    terminal = Terminal(home, store, session)
    try:
        terminal.until("rui> ", 0)
        with endpoint.lock:
            endpoint.responses.append(host.sse_answer("omission-response", "omission-private",
                                                     "omission-item", answer)[0])
        request = key()
        original_message = request
        start = len(terminal.transcript)
        host.message(state, store, request, session, user)
        completed(store, request)
        terminal.until("OMIT-ANSWER-END!", start)
        terminal.command("/status")
        live = bytes(terminal.transcript[start:])
        assert user.encode() in live and answer.encode() in live, "live content was omitted/shortened"
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        terminal.close()

    def exports(rendered):
        commands = [line for line in rendered.decode().splitlines()
                    if line.startswith("rui export-conversation ")]
        assert len(commands) == 2, rendered
        assert b"omitted: 8193 raw bytes" in rendered and b"omitted: 8229 raw bytes" in rendered
        assert b"OMIT-USER-BEGIN" not in rendered and b"OMIT-ANSWER-BEGIN" not in rendered
        actual = []
        for index, command in enumerate(commands):
            assert command.endswith(" > NEW_FILE"), command
            destination = state / ("export-" + str(index))
            invocation = command[:-len("NEW_FILE")] + str(destination)
            result = subprocess.run(["bash", "-c", invocation], cwd=workspace,
                env={**os.environ, "HOME": str(home),
                     "PATH": str(host.RUI.parent) + os.pathsep + os.environ["PATH"]},
                capture_output=True, timeout=15)
            assert result.returncode == 0 and result.stdout == b"", result.stderr
            actual.append(destination.read_bytes())
            if index == 0:
                for failure in ("framing", "truncated", "tail"):
                    def rewrite(response):
                        head, body = response.split(b"\r\n\r\n", 1)
                        if failure == "framing":
                            head = head.replace(b"X-Rui-Content-Bytes: " + str(len(body)).encode(),
                                                b"X-Rui-Content-Bytes: " + str(len(body) + 1).encode())
                        elif failure == "truncated":
                            body = body[:-1]
                        else:
                            body += b"!"
                        return head + b"\r\n\r\n" + body
                    proxy = ReplyProxy(owner, "/v1/conversation-content", rewrite)
                    try:
                        failed = subprocess.run(["bash", "-c", command[:-len(" > NEW_FILE")]],
                            env={**os.environ, "HOME": str(home),
                                 "PATH": str(host.RUI.parent) + os.pathsep + os.environ["PATH"]},
                            capture_output=True, timeout=15)
                        assert failed.returncode != 0, (failure, failed)
                        assert failed.stdout == (b"" if failure == "framing" else actual[-1][:8192])
                        expected = b"TruncatedResponse" if failure == "truncated" else b"InvalidResponse"
                        assert expected in failed.stderr, (failure, failed.stderr)
                    finally:
                        proxy.close()
        assert sorted(actual) == sorted([user.encode(), answer.encode()]), "export identity/bytes changed"
        assert not (workspace / "injected").exists(), "export quoting executed another command"

    terminal = Terminal(home, store, session)
    try:
        terminal.until("rui> ", 0)
        opening = bytes(terminal.transcript)
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        terminal.close()
    # ReplyProxy replaces the listener. Run its standalone export faults only
    # after the interactive poller has exited and restored its terminal.
    exports(opening)
    # Push the large pair out of opening so /history owns their omission.
    for index in range(9):
        with endpoint.lock:
            endpoint.responses.append(host.sse_answer("small-response-" + str(index),
                "small-private-" + str(index), "small-item-" + str(index), "SMALL-ANSWER")[0])
        request = key()
        host.message(state, store, request, session, "SMALL-USER")
        completed(store, request)
    terminal = Terminal(home, store, session)
    try:
        terminal.until("rui> ", 0)
        start = len(terminal.transcript)
        terminal.send("/history\n")
        terminal.until("NEW_FILE", start)
        terminal.command("/status")
        history = bytes(terminal.transcript[start:])
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        terminal.close()
    exports(history)
    # NUL is admitted by the real protocol but cannot travel through argv.
    # Copy captured request values, never alter the original recovery records.
    nul_session = "opening/nul\x00exact"
    configured = json.loads((home / ".config/rui/requests" / (configuration["request"] + ".json")).read_bytes())
    configured.update(key=key(), session=nul_session)
    socket_path = owner.rui_ready_fields["socket"]
    head, body = raw_request(socket_path, "/v1/configure", json.dumps(configured, separators=(",", ":")).encode())
    assert head.startswith(b"HTTP/1.1 200 ") and json.loads(body)["answer"]["status"] == "accepted", body
    saved = json.loads((state / (original_message + ".json")).read_bytes())
    saved.update(key=key(), session=nul_session)
    with endpoint.lock:
        endpoint.responses.append(host.sse_answer("nul-response", "nul-private", "nul-item", "NUL-ANSWER")[0])
    head, body = raw_request(socket_path, "/v1/message", json.dumps(saved, separators=(",", ":")).encode())
    assert head.startswith(b"HTTP/1.1 200 ") and json.loads(body)["answer"]["status"] == "accepted", body
    completed(store, saved["key"])
    head, body = public_read(socket_path, store, "/v1/conversation-page", "conversation_page", nul_session,
                            end="0", before_position="0", before_ordinal="0")
    assert head.startswith(b"HTTP/1.1 200 "), body
    item = next(item for item in json.loads(body)["items"] if item["kind"] == "user")
    exported = subprocess.run([str(host.RUI), "export-conversation", "--store", str(store),
        "--session-hex", nul_session.encode().hex(), "--position", item["position"], "--ordinal", item["ordinal"]],
        env={**os.environ, "HOME": str(home)}, capture_output=True, timeout=15)
    assert exported.returncode == 0 and exported.stdout == user.encode(), exported.stderr


def fatal_stderr(home, store):
    """A restored caller must exit even when its separate stderr TTY is stopped."""
    for stopped in (False, True):
        master, slave = pty.openpty()
        error_master, error_slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
        original = termios.tcgetattr(slave)
        output_flags = fcntl.fcntl(slave, fcntl.F_GETFL)
        error_flags = fcntl.fcntl(error_slave, fcntl.F_GETFL)
        if stopped:
            termios.tcflow(error_slave, termios.TCOOFF)
        process = None
        try:
            process = subprocess.Popen(
                [str(host.RUI), "--store", str(store), "--resume", "missing/fatal-session"],
                env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=error_slave)
            assert process.wait(timeout=5) == 1, "missing Session must return fatal exit, not detach or signal death"
            assert termios.tcgetattr(slave) == original, "fatal caller left raw mode"
            assert fcntl.fcntl(slave, fcntl.F_GETFL) == output_flags, "stdout flags changed"
            assert fcntl.fcntl(error_slave, fcntl.F_GETFL) == error_flags, "stderr flags changed"
            if not stopped:
                assert select.select([error_master], [], [], 1)[0], "missing fatal diagnostic"
                assert b"SessionNotConfigured" in os.read(error_master, 4096)
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if stopped:
                termios.tcflow(error_slave, termios.TCOON)
            for fd in (master, slave, error_master, error_slave):
                os.close(fd)


def idle_catchup(state, home, store, endpoint):
    """Idle opening must keep following another caller, not select idle once."""
    release = threading.Event()
    response = host.sse_answer("idle-response", "idle-private", "idle-message",
                               "IDLE-CATCHUP-ANSWER")[0]
    with endpoint.lock:
        endpoint.responses.append((host.ResponseSpec(response, {}, gate_timeout=20), release))
        endpoint.responses.append(host.sse_answer("draft-response", "draft-private",
                                                 "draft-item", "DRAFT-ANSWER")[0])
        before = len(endpoint.requests)
    terminal = Terminal(home, store, "opening/idle")
    try:
        terminal.until("rui> ", 0)
        terminal.send("é中🙂")
        terminal.send("\x1b[D")
        request = key()
        host.message(state, store, request, "opening/idle", "OTHER-CALLER-INPUT")
        host.wait_for(lambda: len(endpoint.requests) == before + 1, "provider held read")
        # Provider has the actual request and withholds the answer. A rendered
        # edit before release proves editing does not await content completion.
        start = len(terminal.transcript)
        terminal.send("EDIT")
        terminal.until("EDIT", start)
        release.set()
        terminal.until("IDLE-CATCHUP-ANSWER", start)
        terminal.send("\n")
        # The exact sent bytes, not visual cursor coordinates, are the oracle.
        host.wait_for(lambda: len(endpoint.requests) == before + 2, "draft admission")
        sent = json.loads(endpoint.requests[-1])
        user = next(row for row in reversed(sent["input"]) if row.get("role") == "user")
        assert user["content"][0]["text"] == "é中EDIT🙂", user
        terminal.until("DRAFT-ANSWER", start)
        completed(store, request)
        assert b"IDLE-CATCHUP-ANSWER" in host.read_result(store, request)
        terminal.command("/history")
        terminal.command("/status")
        assert len(endpoint.requests) == before + 2, "catch-up observation resubmitted work"
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        release.set()
        terminal.close()


def equal_admissions(state, home, store, endpoint):
    """Replay must not deduplicate equal text or resubmit saved admissions."""
    requests = [key(), key()]
    for request in requests:
        host.message(state, store, request, "opening/equal", "EQUAL-INPUT")
        completed(store, request)
    before = len(endpoint.requests)
    terminal = Terminal(home, store, "opening/equal")
    try:
        terminal.until("rui> ", 0)
        replay = bytes(terminal.transcript).decode(errors="replace")
        assert replay.count("EQUAL-INPUT") == 2, replay
        assert replay.count("EQUAL-ANSWER-A") == 1, replay
        assert replay.count("EQUAL-ANSWER-B") == 1, replay
        history = terminal.command("/history")
        assert "Unknown" not in history, history
        assert len(endpoint.requests) == before, "observation resubmitted work"
        status = terminal.command("/status")
        assert all(request in status for request in requests), "status omitted recent original keys"
        terminal.command("/resume missing/session")
        status = terminal.command("/status")
        assert "opening/equal" in status, "failed pre-switch lookup lost old Session"
        # After the failed lookup, exercise the selected Session and Unicode
        # cursor, not just its printed name. Expected bytes are independent of
        # the renderer and of the input owner's private bank representation.
        start = len(terminal.transcript)
        terminal.send("é中🙂\x1b[DRETAINED\n")
        host.wait_for(lambda: len(endpoint.requests) == before + 1,
                      "old selection retained admission")
        sent = json.loads(endpoint.requests[-1])
        user = next(row for row in reversed(sent["input"]) if row.get("role") == "user")
        assert user["content"][0]["text"].encode() == "é中RETAINED🙂".encode(), user
        terminal.until("OLD-SELECTION-ANSWER", start)
        terminal.command("/history")
        assert len(endpoint.requests) == before + 1, "retained submission admitted twice"
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        terminal.close()
    for request in requests:
        assert b"EQUAL-ANSWER" in host.read_result(store, request)


def late_switch_failure(state, home, store, endpoint, owner):
    """A committed switch cannot roll back or prompt after incomplete content."""
    # A historical value below the omission limit still spans two windows.
    payload = "SWITCH-CONTENT-BEGIN-" + "x" * 6144 + "-SWITCH-CONTENT-END"
    with endpoint.lock:
        endpoint.responses.append(host.sse_answer("switch-answer", "switch-private",
                                                  "switch-item", "SWITCH-ANSWER")[0])
    request = key()
    host.message(state, store, request, "opening/switch-target", payload)
    completed(store, request)
    before = len(endpoint.requests)
    # Both cases use real metadata and real content. Only the failing case
    # drops a late suffix; all framing/binding headers remain byte-identical.
    for truncate in (False, True):
        cut = []
        def rewrite(response):
            head, body = response.split(b"\r\n\r\n", 1)
            if body.startswith(b"SWITCH-CONTENT-BEGIN-"):
                assert head.startswith(b"HTTP/1.1 200 "), head
                fields = dict(line.split(b": ", 1) for line in head.split(b"\r\n")[1:])
                assert int(fields[b"Content-Length"]) == len(payload.encode()) == len(body)
                if truncate:
                    cut.append(body[:4096])
                    return head + b"\r\n\r\n" + cut[-1]
            return response
        proxy = ReplyProxy(owner, "/v1/activity-content", rewrite)
        terminal = None
        try:
            terminal = Terminal(home, store, "opening/switch-source")
            terminal.until("rui> ", 0)
            start = len(terminal.transcript)
            terminal.send("/resume opening/switch-target\n")
            terminal.until("Session: opening/switch-target", start)
            terminal.until("SWITCH-CONTENT-BEGIN-", start)
            if truncate:
                terminal.finish(nonzero=True)
                output = bytes(terminal.transcript[start:])
                assert cut == [payload.encode()[:4096]], "failed stream was retried/prepassed"
                assert cut[0] in output, "failure occurred before the streamed prefix was presented"
                assert b"TruncatedResponse" in output, output
                assert b"SWITCH-CONTENT-END" not in output, "missing suffix was fabricated"
                assert b"old Session and draft retained" not in output, "committed switch rolled back"
                assert b"Session: opening/switch-source" not in output, "old selection was reentered"
                prefix_end = output.index(cut[0]) + len(cut[0])
                assert b"rui> " not in output[prefix_end:], "incomplete replay resumed prompting"
                assert b"Detached." not in output, "fatal replay was reported as normal detach"
            else:
                terminal.until("SWITCH-CONTENT-END", start)
                terminal.until("rui> \r\x1b[5C", start)
                assert not cut
                status = terminal.command("/status")
                assert "Session: opening/switch-target" in status, status
                terminal.command("/exit", "Detached.")
                terminal.finish()
            assert len(endpoint.requests) == before, "replay resubmitted saved work"
        finally:
            if terminal is not None:
                terminal.close()
            proxy.close()  # Join all borrowers before returning the real socket.


def rejected_input(home, store, endpoint, owner):
    """Completed malformed attempts cannot poison editing or a sealed Message."""
    held, release = threading.Event(), threading.Event()
    def hold_reply(response):
        held.set()
        assert release.wait(15), "original admission reply was never released"
        return response
    terminal = Terminal(home, store, "opening/rejection")
    proxy = None
    try:
        terminal.until("rui> ", 0)
        before = len(endpoint.requests)
        os.write(terminal.master, b"DISCARD\xffsuffix\n")
        terminal.until("Whole input rejected; nothing sent.", 0)
        terminal.command("/status")
        assert len(endpoint.requests) == before, "malformed attempt submitted work"
        with endpoint.lock:
            for label in ("RECOVERED-ANSWER", "SEALED-ANSWER", "NEXT-ANSWER"):
                endpoint.responses.append(host.sse_answer(label, label + "-private",
                                                          label + "-item", label)[0])
        start = len(terminal.transcript)
        terminal.send("é中🙂\x1b[DRECOVERED\n")
        terminal.until("RECOVERED-ANSWER", start)
        terminal.command("/status")
        first = json.loads(endpoint.requests[before])
        assert first["input"][-1]["content"][0]["text"] == "é中RECOVERED🙂", first
        # The Host accepted the original, but Input still owns its sealed bank
        # until this real admission response returns. This is not a capture-
        # loan hold or a synthetic Host rejection.
        proxy = ReplyProxy(owner, "/v1/message", hold_reply)
        terminal.send("ORIGINAL-SEALED-é🙂\n")
        host.wait_for(held.is_set, "real original admission response held")
        start = len(terminal.transcript)
        os.write(terminal.master, b"REJECT-NEXT\xfftail\n")
        terminal.until("Whole input rejected; nothing sent.", start)
        terminal.send("NEXT-é🙂\x1b[DKEPT")
        terminal.until("NEXT-éKEPT🙂", start)
        assert len(proxy.exchanges) == 1, "malformed next composition sent another request"
        settled = len(terminal.transcript)
        release.set()
        # A footer without the submitting label establishes caller settlement,
        # not merely Host completion, without replacing the composing draft.
        terminal.until("\rRui: completed", settled)
        terminal.until("SEALED-ANSWER", start)
        second = json.loads(endpoint.requests[before + 1])
        assert second["input"][-1]["content"][0]["text"] == "ORIGINAL-SEALED-é🙂", second
        terminal.send("\n")
        terminal.until("NEXT-ANSWER", start)
        third = json.loads(endpoint.requests[before + 2])
        assert third["input"][-1]["content"][0]["text"] == "NEXT-éKEPT🙂", third
        assert len(endpoint.requests) == before + 3, "rejected attempt leaked or duplicated work"
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        release.set()
        terminal.close()
        if proxy is not None:
            proxy.close()


def current_recovery_diagnostic(home, store, endpoint, owner):
    """A newer uncertain Message, not a stale acceptance, owns fatal guidance."""
    with endpoint.lock:
        for label in ("ACCEPTED-A", "UNCERTAIN-B"):
            endpoint.responses.append(host.sse_answer(label, label + "-private",
                                                      label + "-item", label)[0])
    def lose_second_reply(response):
        if len(proxy.exchanges) == 2:
            # The real Host already committed B. Preserve its framing but lose
            # the body, so the caller cannot know that admission outcome.
            head, _ = response.split(b"\r\n\r\n", 1)
            return head + b"\r\n\r\n"
        return response
    proxy = ReplyProxy(owner, "/v1/message", lose_second_reply)
    terminal = None
    try:
        terminal = Terminal(home, store, "opening/fatal-original")
        terminal.until("rui> ", 0)
        start = len(terminal.transcript)
        terminal.send("ACCEPTED-ORIGINAL-A\n")
        terminal.until("ACCEPTED-A", start)
        terminal.command("/status")
        start = len(terminal.transcript)
        terminal.send("UNCERTAIN-ORIGINAL-B\n")
        terminal.until("Admission unconfirmed.", start)
        assert len(proxy.exchanges) == 2, "uncertain original was retried"
        first, second = [json.loads(body) for body, _ in proxy.exchanges]
        assert first["text"] == {"state": "value", "value": "ACCEPTED-ORIGINAL-A"}, first
        assert second["text"] == {"state": "value", "value": "UNCERTAIN-ORIGINAL-B"}, second
        saved = host.command("observe-command", "--store", store, "--key", second["key"])
        assert saved["key"] == second["key"] and saved["observation"]["status"] == "accepted", saved
        assert saved["observation"]["kind"] == "message", saved
        assert saved["observation"]["target"] == "opening/fatal-original", saved
        start = len(terminal.transcript)
        terminal.send("\x1b[")
        terminal.finish(nonzero=True)
        output = bytes(terminal.transcript[start:]).decode(errors="replace")
        assert "IncompleteTerminalInput" in output, output
        assert "Original Admission unconfirmed" in output, "fatal guidance overstated admission certainty"
        for label, value in (("Store", str(store)), ("Session", "opening/fatal-original"),
                             ("Key", second["key"])):
            assert f"{label}: {value}" in output, (label, output)
        assert first["key"] not in output, "fatal guidance used a stale accepted identity"
        assert "Original Admission accepted" not in output, output
        assert len(proxy.exchanges) == 2, "fatal cleanup resent work"
    finally:
        if terminal is not None:
            terminal.close()
        proxy.close()


def matching_recovery(home, store, endpoint, owner):
    """Only recovery of the matching original may release its input bank."""
    unrelated = admit(home, "configure", "--store", store,
                      "--session", "opening/recover", "--permission-mode", "ask")["request"]
    held, release = threading.Event(), threading.Event()
    with endpoint.lock:
        for label in ("RECOVERY-ORIGINAL-ANSWER", "RECOVERY-NEXT-ANSWER"):
            endpoint.responses.append(host.sse_answer(label, label + "-private",
                                                      label + "-item", label)[0])
        before = len(endpoint.requests)
    def lose_first_reply(response):
        if len(proxy.exchanges) == 1:
            head, _ = response.split(b"\r\n\r\n", 1)
            return head + b"\r\n\r\n"
        if len(proxy.exchanges) == 2:
            held.set()
            assert release.wait(15), "matching recovery reply was never released"
        return response
    proxy = ReplyProxy(owner, "/v1/message", lose_first_reply)
    terminal = None
    try:
        terminal = Terminal(home, store, "opening/recover")
        terminal.until("rui> ", 0)
        start = len(terminal.transcript)
        terminal.send("RECOVER-EXACT-ORIGINAL-é🙂\n")
        terminal.until("Admission unconfirmed.", start)
        original = json.loads(proxy.exchanges[0][0])
        saved = host.command("observe-command", "--store", store, "--key", original["key"])
        assert saved["observation"]["status"] == "accepted", saved
        terminal.command("/recover " + unrelated)
        start = len(terminal.transcript)
        terminal.send("MUST-REMAIN-BUSY\n")
        terminal.until("Submission busy; draft retained.", start)
        assert len(proxy.exchanges) == 1, "unrelated recovery released the original bank"
        terminal.send("\x15")  # Explicitly discard this blocked test composition.
        terminal.send("/recover " + original["key"] + "\n")
        host.wait_for(held.is_set, "matching original recovery response held")
        start = len(terminal.transcript)
        terminal.send("NEXT-é🙂\x1b[D")
        terminal.until("NEXT-é🙂", start)
        assert proxy.exchanges[1][0] == proxy.exchanges[0][0], "recovery replaced original intent"
        start = len(terminal.transcript)
        release.set()
        terminal.until("Original request accepted.", start)
        while not re.search(rb"\rRui: (?:idle|completed|in_flight)\r\r\nrui> NEXT-", terminal.transcript[start:]):
            assert terminal.read(), "matching recovery never settled the caller"
        terminal.send("RECOVERED\n")
        terminal.until("RECOVERY-NEXT-ANSWER", start)
        assert len(proxy.exchanges) == 3, "recovered original was sent again or next input remained busy"
        next_request = json.loads(proxy.exchanges[2][0])
        assert next_request["key"] != original["key"], "next Message reused the original identity"
        assert next_request["text"] == {"state": "value", "value": "NEXT-éRECOVERED🙂"}, next_request
        socket = owner.rui_ready_fields["socket"]
        head, body = public_read(socket, store, "/v1/conversation-page", "conversation_page",
                                 "opening/recover", end="0", before_position="0", before_ordinal="0")
        assert head.startswith(b"HTTP/1.1 200 "), (head, body)
        page = json.loads(body)
        assert page["direction"] == "newest_first" and not page["more"], page
        newest_user = next(row for row in page["items"] if row["kind"] == "user")
        head, body = public_read(socket, store, "/v1/conversation-content", "conversation_content",
                                 "opening/recover", position=newest_user["position"],
                                 ordinal=newest_user["ordinal"], start="0", stream=True)
        assert head.startswith(b"HTTP/1.1 200 ") and body == "NEXT-éRECOVERED🙂".encode(), (head, body)
        assert len(endpoint.requests) == before + 2, "recovery duplicated provider work"
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        release.set()
        if terminal is not None:
            terminal.close()
        proxy.close()


def approval(state, home, store, workspace, endpoint):
    """Attention cannot steal draft focus; only fresh exact Action approves."""
    terminal = Terminal(home, store, "opening/approval")
    effect = workspace / "opening-effect"
    try:
        terminal.until("rui> ", 0)
        terminal.send("kept-é🙂")
        request = key()
        host.message(state, store, request, "opening/approval", "PROPOSE")
        def pending():
            current = host.command("inspect-session", "--store", store,
                                   "--session", "opening/approval")
            return current["actionable_permissions"] or None
        permissions = host.wait_for(pending, "real pending Action")
        action = permissions[0]["action"]
        exact = json.loads(run(home, "inspect-action", "--store", store,
                               "--session", "opening/approval", "--action", action, "--json"))
        arguments = json.dumps({"cmd": "printf x >> opening-effect", "timeout_ms": None})
        assert exact == {"action": action, "call_id": "opening-call",
                         "arguments": arguments}, exact
        start = len(terminal.transcript)
        terminal.send("FOCUS")
        terminal.until("FOCUS", start)
        assert not effect.exists(), "attention consumed composition as permission"
        terminal.send("\x07a\n")  # Typeahead must be flushed at the fresh boundary.
        proposal = terminal.until("Allow once, deny, or later?", start)
        action_ready(terminal.ready)
        assert action in proposal and "Bash arguments:" in proposal, proposal
        displayed = proposal.split("Bash arguments: ", 1)[1].splitlines()[0]
        assert json.loads(displayed) == arguments, "incomplete approval arguments"
        assert not effect.exists(), "typeahead authorized unseen Action"
        terminal.send("a\n")
        terminal.until("APPROVAL-ANSWER", start)
        completed(store, request)
        assert effect.read_text() == "x", "effect absent or duplicated"
        terminal.send("\n")
        terminal.until("PRESERVED-ANSWER", start)
        sent = json.loads(endpoint.requests[-1])
        user = next(row for row in reversed(sent["input"]) if row.get("role") == "user")
        assert user["content"][0]["text"] == "kept-é🙂FOCUS", user
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        terminal.close()


def local_commands(home, store, workspace, endpoint):
    """Nested local commands retain one terminal and require a fresh choice."""
    terminal = Terminal(home, store, "opening/local")
    before = len(endpoint.requests)
    try:
        terminal.until("rui> ", 0)
        setup = terminal.command("/setup --provider codex --model future-model")
        assert "Saved defaults for future Sessions" in setup, setup
        status = terminal.command("/status")
        assert "Model: model-a" in status and "future-model" not in status, status
        handles = terminal.command("/requests")
        assert "Local recovery handles" in handles, handles
        original = re.findall(r"  ([0-9a-f-]{36}) \(configure\)", handles)
        assert len(original) == 1, handles
        start = len(terminal.transcript)
        terminal.send("/login\nd\n")
        terminal.until("Provider: [c] Codex login, [d] defer", start)
        # Output appearance alone is not a fresh-choice boundary. The existing
        # terminal gate is emitted only after real drainage and typeahead flush.
        action_ready(terminal.ready)
        assert b"Login deferred" not in terminal.transcript[start:], "typeahead selected login choice"
        terminal.send("d\n")
        terminal.until("Login deferred", start)
        terminal.until("rui> \r\x1b[5C", start)
        assert not (home / ".config/rui/codex.json").exists(), "defer changed credentials"
        configured = terminal.command("/configure --permission-mode bypass")
        assert "Configured" in configured, configured
        status = terminal.command("/status")
        assert "Permission: bypass" in status and "Model: model-a" in status, status
        recovered = terminal.command("/recover " + original[0])
        assert "Original request accepted" in recovered, recovered
        status = terminal.command("/status")
        assert "Permission: bypass" in status, "recovery reapplied old configuration"
        assert len(endpoint.requests) == before, "local command started model work"
        for tools, mode, warning in (("none", "bypass", False), ("edit", "bypass", False),
                                     ("bash,edit", "bypass", True), ("bash", "ask", False),
                                     ("bash", "bypass", True)):
            terminal.command(f'/configure --tools "{tools}" --permission-mode {mode}')
            status = terminal.command("/status")
            assert ("Bash bypasses approval" in status) == warning, (tools, mode, status)
            listing = run(home, "sessions", "--store", store, "--all")
            selected = listing.split("Session: opening/local\n", 1)[1].split("Session: ", 1)[0]
            assert ("Bash runs without approval" in selected) == warning, (tools, mode, selected)
            entered = Terminal(home, store, "opening/local")
            try:
                opening = entered.until("rui> ", 0)
                assert ("Bash bypasses approval" in opening) == warning, (tools, mode, opening)
                entered.command("/exit", "Detached.")
                entered.finish()
            finally:
                entered.close()
        if os.path.exists("/proc/self/task"):
            with open(home / ".config/rui/.preferences.lock", "rb") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                start = len(terminal.transcript)
                terminal.send("/setup --clear-model\n")
                # Establish real native lock wait before typing. This is Linux
                # development evidence, not a Mac or stopped-drain claim.
                host.wait_for(lambda: any("locks_lock_inode_wait" in p.read_text()
                                          for p in pathlib.Path(f"/proc/{terminal.process.pid}/task").glob("*/wchan")),
                              "setup worker inside native preference lock")
                terminal.send("éZ\x1b[DKEPT")
                terminal.until("éKEPTZ", start)
                fcntl.flock(lock, fcntl.LOCK_UN)
            terminal.until("Model: not selected", start)
            terminal.send("\x1b[F" + "\x7f" * 6)
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        terminal.close()


def wait_attention(state, home, store, workspace, endpoint):
    arguments = json.dumps({"cmd": "printf x >> wait-should-not-run", "timeout_ms": None})
    with endpoint.lock:
        endpoint.responses.append(host.sse_tool_calls("wait-proposal", [
            ("bash", "wait-a", arguments), ("bash", "wait-b", arguments)]))
    host.message(state, store, key(), "opening/wait", "WAIT-TWO-ACTIONS")
    def pending():
        permissions = host.command("inspect-session", "--store", store,
                                   "--session", "opening/wait")["actionable_permissions"]
        return permissions if len(permissions) == 2 else None
    permissions = host.wait_for(pending, "two real pending Actions")
    terminal = Terminal(home, store, "opening/wait")
    try:
        terminal.until("rui> ", 0)
        status = terminal.command("/status")
        waited = terminal.command("/wait")
        for item in permissions:
            expected = "Pending Action: " + item["action"]
            assert expected in status and expected in waited, (expected, status, waited)
        assert "Permission attention" in waited, waited
        assert not (workspace / "wait-should-not-run").exists(), "observation authorized an effect"
        assert len(pending()) == 2, "wait changed pending authority"
        terminal.command("/exit", "Detached.")
        terminal.finish()
    finally:
        terminal.close()


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-opening."))
    home, workspace, store = state / "home", state / "workspace", state / "store"
    home.mkdir()
    workspace.mkdir()
    answer = lambda label: host.sse_answer(label, label + "-private", label + "-item", label)[0]
    arguments = json.dumps({"cmd": "printf x >> opening-effect", "timeout_ms": None})
    endpoint = host.SuccessEndpoint([])
    worker = threading.Thread(target=endpoint.serve_forever, daemon=True)
    worker.start()
    owner = None
    try:
        owner = host.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        for session in ("idle", "equal", "approval", "local", "wait", "switch-source", "switch-target", "rejection", "fatal-original", "recover", "render"):
            configure(home, store, workspace, "opening/" + session)
        assistant_rendering(state, home, store, endpoint)
        historical_export(state, home, store, workspace, endpoint, owner)
        fatal_stderr(home, store)
        local_commands(home, store, workspace, endpoint)
        idle_catchup(state, home, store, endpoint)
        with endpoint.lock:
            endpoint.responses.extend([answer("EQUAL-ANSWER-A"), answer("EQUAL-ANSWER-B"),
                                       answer("OLD-SELECTION-ANSWER")])
        equal_admissions(state, home, store, endpoint)
        late_switch_failure(state, home, store, endpoint, owner)
        rejected_input(home, store, endpoint, owner)
        current_recovery_diagnostic(home, store, endpoint, owner)
        matching_recovery(home, store, endpoint, owner)
        with endpoint.lock:
            endpoint.responses.extend([
                host.sse_tool_calls("opening-proposal", [("bash", "opening-call", arguments)]),
                answer("APPROVAL-ANSWER"), answer("PRESERVED-ANSWER")])
        approval(state, home, store, workspace, endpoint)
        wait_attention(state, home, store, workspace, endpoint)
        print("session opening: 12 focused real Host/provider/PTY cases passed")
    finally:
        if owner is not None:
            host.stop_host(owner)
        endpoint.shutdown()
        endpoint.server_close()
        worker.join(timeout=5)
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
