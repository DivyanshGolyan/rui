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


def completed(store, request):
    host.wait_for(lambda: host.completed_observation(store, request),
                  "original saved result")


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
        for session in ("idle", "equal", "approval", "local", "wait"):
            configure(home, store, workspace, "opening/" + session)
        fatal_stderr(home, store)
        local_commands(home, store, workspace, endpoint)
        idle_catchup(state, home, store, endpoint)
        with endpoint.lock:
            endpoint.responses.extend([answer("EQUAL-ANSWER-A"), answer("EQUAL-ANSWER-B"),
                                       answer("OLD-SELECTION-ANSWER")])
        equal_admissions(state, home, store, endpoint)
        with endpoint.lock:
            endpoint.responses.extend([
                host.sse_tool_calls("opening-proposal", [("bash", "opening-call", arguments)]),
                answer("APPROVAL-ANSWER"), answer("PRESERVED-ANSWER")])
        approval(state, home, store, workspace, endpoint)
        wait_attention(state, home, store, workspace, endpoint)
        print("session opening: 6 focused real Host/provider/PTY cases passed")
    finally:
        if owner is not None:
            host.stop_host(owner)
        endpoint.shutdown()
        endpoint.server_close()
        worker.join(timeout=5)
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
