#!/usr/bin/env python3
"""Canonical invocation failure at real producers and current caller boundaries."""
import json
import os
import pathlib
import pty
import re
import select
import shutil
import socket
import socketserver
import sqlite3
import subprocess
import sys
import tempfile
import termios
import threading
import time

import model_fixture as fixture
from host_process import canonical_fixture_root, preserve_failure_metadata

ERROR = {"version": "1", "type": "invocation_error", "code": "canonical_store_failure"}
ERROR_BYTES = json.dumps(ERROR, separators=(",", ":")).encode()


def invoke(home, *args):
    return subprocess.run([str(fixture.RUI), *map(str, args)],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=20)


def announced(result):
    """Generated capture identity: the first stderr line, before transmission."""
    first = result.stderr.splitlines()[0] if result.stderr else ""
    match = re.fullmatch(r"request: (\S+) \(inspect: rui request inspect \1; if unconfirmed: rui request recover \1\)", first)
    assert match, result
    assert result.stderr.count("request: ") == 1, result
    return match[1]


def expect_fatal(result):
    assert result.returncode != 0 and "CanonicalStoreFailure" in result.stderr, result
    assert "admitted:" not in result.stdout and "replayed:" not in result.stdout, result
    assert "no work was admitted" not in result.stdout, result


def expect_mutation_error(result, saved, *, human=False, status=500,
        reason="CanonicalStoreFailure", diagnostic=ERROR):
    """Original request context, never the substituted reply's claimed target."""
    context = {field: saved[field] for field in ("store", "key", "kind")}
    context["session"] = saved["target"]["session"] if "target" in saved else saved["session"]
    if human:
        for label, field in (("Store", "store"), ("Session", "session"), ("key", "key")):
            escaped = json.dumps(context[field], ensure_ascii=False)[1:-1]
            assert f"{label}: {escaped}\n" in result.stdout, result
        assert f"invocation: {reason} (HTTP {status}); outcome unconfirmed\n" in result.stdout, result
        if diagnostic:
            assert f"type: {diagnostic['type']}\ncode: {diagnostic['code']}\n" in result.stdout, result
        assert '"version"' not in result.stdout and '"answer"' not in result.stdout, result
        return
    # Metadata is exactly one JSON value on stdout.
    observed = json.loads(result.stdout)
    expected = {"context": context, "error": {
        "status": str(status), "reason": reason, "certainty": "unconfirmed",
        "type": diagnostic["type"] if diagnostic else None,
        "code": diagnostic["code"] if diagnostic else None,
    }}
    if "target" in saved:
        expected["request_target"] = {field: saved["target"][field] for field in ("turn", "operation")}
    elif saved["kind"] == "permission_decision":
        expected["request_target"] = {field: saved[field] for field in ("action", "decision")}
    assert observed == expected, observed


def producer_cases(state):
    text = state / "input"
    text.write_text("original mutation bytes")
    commands = {
        "configure": ["session", "configure", "--workspace", state, "--provider", "codex", "--model", "model-a"],
        "message": ["session", "send", "--text", text],
        "permission-decision": ["action", "allow", "--action", "7"],
        "permission-denial": ["action", "deny", "--action", "7"],
        "session-stop": ["session", "stop"],
        "model-interruption": ["session", "interrupt-model", "--turn", "3", "--operation", "5"],
    }
    for name, command in commands.items():
        kind = "permission-decision" if name == "permission-denial" else name
        # Every mutation kind supports explicit and generated captures.
        for mode in ("raw", "generated"):
            home = state / f"{name}-{mode}"
            home.mkdir(mode=0o700)
            store = home / "store"
            record = home / "record.json"
            key = f"{kind}-{mode}"
            host = fixture.start_host(store, None, "--fault", "before-commit")
            try:
                args = [*command, "--store", store, "--session", "original/session"]
                if mode == "raw":
                    args += ["--record", record, "--key", key]
                result = invoke(home, *args)
                expect_fatal(result)
                if mode != "raw":
                    key = announced(result)
                    record = home / ".config/rui/requests" / f"{key}.json"
                original = record.read_bytes()
                assert json.loads(original)["key"] == key, original
                expect_mutation_error(result, json.loads(original))
                # The production fault must fence/shut down, not just return a
                # fixture-owned fatal reply while the Host keeps admitting.
                assert host.wait(timeout=10) != 0, "Store fault did not fence the Host"
            finally:
                fixture.stop_host(host)
            if mode != "raw":
                host = fixture.start_host(store, None, "--fault", "before-commit")
                try:
                    recovered = invoke(home, "request", "recover", key)
                    expect_fatal(recovered)
                    expect_mutation_error(recovered, json.loads(original))
                    assert record.read_bytes() == original, recovered
                finally:
                    fixture.stop_host(host)
            host = fixture.start_host(store, None, "--fault", "before-commit")
            try:
                retried = invoke(home, "request", "recover", "--store", store, "--record", record, "--kind", kind)
                expect_fatal(retried)
                expect_mutation_error(retried, json.loads(original))
                assert record.read_bytes() == original, retried
            finally:
                fixture.stop_host(host)
    print("canonical producers: all five fenced HTTP mutation owners; typed explicit/generated JSON diagnostics and five retry kinds passed", flush=True)


class ReplyProxy(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """Forward the real request, drain its reply, replace only the selected route."""
    def __init__(self, host, route, rewrite=None, *, before_forward=None):
        self.path = pathlib.Path(host.rui_ready_fields["socket"])
        self.backend = self.path.with_suffix(".canonical-backend")
        self.path.rename(self.backend)
        self.route = route
        self.rewrite = rewrite
        self.before_forward = before_forward
        self.exchanges = []
        self.mutations = []
        super().__init__(str(self.path), Exchange)
        os.chmod(self.path, 0o600)
        self.thread = threading.Thread(target=self.serve_forever)
        self.thread.start()

    def close(self):
        self.shutdown()
        self.server_close()  # Joins the bounded handlers before restoring the socket.
        self.thread.join(timeout=5)
        assert not self.thread.is_alive(), "reply proxy did not join"
        self.path.unlink()
        self.backend.rename(self.path)


class Exchange(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        data = b""
        while b"\r\n\r\n" not in data:
            part = self.request.recv(4096)
            assert part, "truncated request head"
            data += part
        head, body = data.split(b"\r\n\r\n", 1)
        fields = dict(line.split(b": ", 1) for line in head.split(b"\r\n")[1:])
        length = int(fields[b"Content-Length"])
        while len(body) < length:
            part = self.request.recv(length - len(body))
            assert part, "truncated request body"
            body += part
        route = head.split(b" ")[1].decode()
        if route in ("/v1/message", "/v1/control/permission-decision"):
            self.server.mutations.append((route, body))
        if route == self.server.route and self.server.before_forward is not None:
            if not self.server.before_forward(body):
                return  # Held full request was cancelled before Host admission.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as backend:
            backend.settimeout(15)
            backend.connect(str(self.server.backend))
            backend.sendall(head + b"\r\n\r\n" + body)
            response = b""
            while True:
                part = backend.recv(65536)
                if not part:
                    break
                response += part
        if route == self.server.route:
            self.server.exchanges.append((body, response))
            if self.server.rewrite is not None:
                response = self.server.rewrite(response)
            else:
                response = (b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n"
                    b"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
                    + str(len(ERROR_BYTES)).encode() + b"\r\n\r\n" + ERROR_BYTES)
        if response is not None:  # An explicitly held cancellation peer sends nothing.
            self.request.sendall(response)


def wrong_target(response, null_code=False):
    head, body = response.split(b"\r\n\r\n", 1)
    value = json.loads(body)
    answer = value["answer"]
    if null_code:
        value["code"] = None
    elif "target" in answer:
        answer["target"]["operation"] = str(int(answer["target"]["operation"]) + 1)
    elif "action" in answer:
        answer["decision"] = "allow_once" if answer["decision"] == "deny" else "deny"
    elif "input" in value:
        value["input"]["sha256"] = "00" * 32
    else:
        answer["session"] = "other/session"
    encoded = json.dumps(value, separators=(",", ":")).encode()
    return (head.split(b"\r\n", 1)[0] + b"\r\nContent-Type: application/json\r\n"
        b"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
        + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)


def binding_cases(state, null_code=False):
    home = state / ("nulls" if null_code else "binding")
    reason = "InvalidResponse" if null_code else "RequestBindingMismatch"
    rewrite = lambda response: wrong_target(response, null_code=null_code)
    home.mkdir(mode=0o700)
    store = home / "store"
    host = fixture.start_host(store, None)
    text = home / "input"
    text.write_text("a\nµ")
    commands = (
        ("configure", "/v1/configure", ["session", "configure", "--workspace", state, "--provider", "codex", "--model", "model-a"]),
        ("message", "/v1/message", ["session", "send", "--text", text]),
        ("session-stop", "/v1/control/session-stop", ["session", "stop"]),
        ("model-interruption", "/v1/control/model-interruption", ["session", "interrupt-model", "--turn", "3", "--operation", "11"]),
        ("permission-decision", "/v1/control/permission-decision", ["action", "deny", "--action", "7"]),
        ("permission-allow", "/v1/control/permission-decision", ["action", "allow", "--action", "7"]),
    )
    try:
        for name, route, command in commands:
            kind = "permission-decision" if name == "permission-allow" else name
            for mode in ("raw", "generated"):
                record = home / f"{name}-{mode}.json"
                args = [*command, "--store", store, "--session", "original/session"]
                args += ["--record", record, "--key", f"{name}-{mode}"] if mode == "raw" else []
                proxy = ReplyProxy(host, route, rewrite)
                try:
                    result = invoke(home, *args)
                    assert result.returncode != 0 and reason in result.stderr, result
                    assert "admitted:" not in result.stdout and "replayed:" not in result.stdout, result
                finally:
                    proxy.close()
                request, original_reply = proxy.exchanges[0]
                saved = json.loads(request)
                key = saved["key"]
                if mode != "raw":
                    assert announced(result) == key, result
                    record = home / ".config/rui/requests" / f"{key}.json"
                assert record.read_bytes() == request
                expect_mutation_error(result, saved, status=200, reason=reason, diagnostic=None)
                for recovery in (["request", "recover", "--store", store, "--record", record, "--kind", kind],
                        *([["request", "recover", key]] if mode != "raw" else [])):
                    proxy = ReplyProxy(host, route, rewrite)
                    try:
                        failed = invoke(home, *recovery)
                        assert failed.returncode != 0 and reason in failed.stderr, failed
                    finally:
                        proxy.close()
                    expect_mutation_error(failed, saved, status=200, reason=reason, diagnostic=None)
                    assert record.read_bytes() == request
                # Replay returns the original saved answer; a saved rejection
                # still arrives on stdout and exits 1.
                original_answer = json.loads(original_reply.split(b"\r\n\r\n", 1)[1])["answer"]
                for recovery in (["request", "recover", "--store", store, "--record", record, "--kind", kind],
                        *([["request", "recover", key]] if mode != "raw" else [])):
                    recovered = invoke(home, *recovery)
                    replayed = json.loads(recovered.stdout)["answer"]
                    assert recovered.returncode == (0 if original_answer["status"] == "accepted" else 1), recovered
                    assert replayed["replayed"] is True and replayed["status"] == original_answer["status"], recovered
                assert record.read_bytes() == request
    finally:
        fixture.stop_host(host)
    print(f"mutation {'nulls' if null_code else 'bindings'}: five typed explicit/generated/retry/recover callers reject {'present null code' if null_code else 'wrong Session, digest, target or decision'}; original-key replay preserved", flush=True)


def committed_cases(state):
    home = state / "committed"
    home.mkdir()
    store = home / "store"
    host = fixture.start_host(store, None)
    try:
        configured = invoke(home, "session", "configure", "--store", store, "--session", "original/session",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        assert configured.returncode == 0, configured
        proxy = ReplyProxy(host, "/v1/message")
        try:
            result = invoke(home, "session", "send", "--store", store, "--session", "original/session",
                "original committed bytes")
            expect_fatal(result)
        finally:
            proxy.close()
        request, reply = proxy.exchanges[0]
        assert reply.startswith(b"HTTP/1.1 200"), reply
        answer = json.loads(reply.split(b"\r\n\r\n", 1)[1])["answer"]
        assert answer["status"] == "accepted" and answer["replayed"] is False, answer
        key = json.loads(request)["key"]
        assert announced(result) == key, result
        record = home / ".config/rui/requests" / f"{key}.json"
        original = record.read_bytes()
        assert request == original, "transmission changed the captured inputs"
        saved = json.loads(original)
        assert saved["key"] == key and saved["store"] == str(store.resolve()) and saved["session"] == "original/session", saved
        expect_mutation_error(result, saved)
        for _ in range(2):
            recovered = invoke(home, "request", "recover", key)
            assert recovered.returncode == 0, recovered
            assert json.loads(recovered.stdout)["answer"] == {**answer, "replayed": True}, recovered
            assert record.read_bytes() == original, "fatal diagnosis replaced original recovery inputs"
        database = sqlite3.connect(store / "rui.sqlite3")
        try:
            assert database.execute("SELECT count(*) FROM core_command WHERE command_key=?", (key,)).fetchone() == (1,)
        finally:
            database.close()
        # Keyed reads retain typed diagnostics and the queried key; the distinct
        # inspection/report route remains outside this owner correction.
        for route, args in (
            ("/v1/observe-command", ["request", "inspect", "--key", key]),
            ("/v1/read-result", ["request", "read-result", "--key", key]),
            ("/v1/inspect-session", ["session", "inspect", "--session", "original/session"]),
        ):
            proxy = ReplyProxy(host, route)
            try:
                result = invoke(home, *args, "--store", store)
                expect_fatal(result)
                expected = ERROR if route == "/v1/inspect-session" else {
                    "key": key, "error": {"status": 500, "type": ERROR["type"], "code": ERROR["code"]}}
                assert json.loads(result.stdout) == expected, result
                assert len(proxy.exchanges) == 1, (route, proxy.exchanges)
            finally:
                proxy.close()
        # The saved-handle observation keeps the same typed diagnostic.
        proxy = ReplyProxy(host, "/v1/observe-command")
        try:
            result = invoke(home, "request", "inspect", key)
            expect_fatal(result)
            assert json.loads(result.stdout) == {
                "key": key, "error": {"status": 500, "type": ERROR["type"], "code": ERROR["code"]}}, result
            assert len(proxy.exchanges) == 1, proxy.exchanges
        finally:
            proxy.close()
    finally:
        fixture.stop_host(host)
    print("canonical callers: committed-then-fatal retains original key/bytes, replay not resubmit; observation/read errors passed", flush=True)


def interactive_cases(state, binding=False, null_code=False):
    import human_cli_integration as human
    import codex_integration as codex
    binding = binding or null_code  # Both are recoverable unconfirmed replies.
    reason = "InvalidResponse" if null_code else "RequestBindingMismatch"
    rewrite = (lambda response: wrong_target(response, null_code=null_code)) if binding else None
    home = state / ("null-interactive" if null_code else "binding-interactive" if binding else "interactive")
    home.mkdir()
    store = home / "store"
    endpoint = fixture.SuccessEndpoint([fixture.sse_tool_calls("canonical-tool", [("bash", "canonical-call",
        '{"cmd":"true","timeout_ms":null,"description":"Check successful shell exit"}')]),
        fixture.sse_answer("canonical-answer", "canonical-reason", "canonical-message", "denied tool saved")[0],
        fixture.sse_answer("confirmed-answer", "confirmed-reason", "confirmed-message", "accepted work remains accepted")[0]])
    endpoint_thread = threading.Thread(target=endpoint.serve_forever)
    endpoint_thread.start()
    host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
    try:
        configured = invoke(home, "session", "configure", "--store", store, "--session", "original/session",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        assert configured.returncode == 0, configured
        codex.credentials(home / ".config/rui/codex.json")
        for route, line in (("/v1/configure", "/configure --permission-mode ask"),
                ("/v1/message", "original terminal bytes"), ("/v1/control/permission-decision", "d"),
                ("/v1/configure", None), ("/v1/activity-page", "confirmed terminal bytes")):
            if binding and route == "/v1/activity-page":
                continue  # Activity framing/binding is covered by opening cases.
            master, slave = pty.openpty()
            original_terminal = termios.tcgetattr(slave)
            ready_read, ready_write = os.pipe()
            args = (["session", "resume", "--store", str(store), "--", "original/session"] if line is not None
                else ["--store", str(store), "--provider", "codex", "--model", "gpt-6-luna"])
            proxy = None
            caller = None
            before_messages = {
                path.name: path.read_bytes()
                for path in (home / ".config/rui/requests").glob("*.json")
                if json.loads(path.read_bytes())["kind"] == "message"
            }
            try:
                if line is None or route == "/v1/control/permission-decision":
                    proxy = ReplyProxy(host, route, rewrite)
                caller = subprocess.Popen([str(fixture.RUI), *args],
                    env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                    pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                if line is not None:
                    if route == "/v1/control/permission-decision":
                        proposal = human.read_terminal(master, "a: Allow once / d: Deny (Enter)")
                        assert "Run Bash:\n  true" in proposal, proposal
                        human.assert_permission_workspace(proposal, state)
                        proposal += human.action_ready(ready_read, master)
                    else:
                        human.read_terminal(master, "› ")
                        if route == "/v1/activity-page":
                            # Keep opening and pre-Message Activity polls healthy.
                            # Backend delivery is not frontend Admission settlement.
                            proxy = ReplyProxy(host, "/v1/message", lambda response: response)
                        else:
                            proxy = ReplyProxy(host, route, rewrite)
                    os.write(master, (line + "\n").encode())
                output = ""
                if route == "/v1/activity-page":
                    fixture.wait_for(lambda: proxy.exchanges, "healthy Message reply")
                    accepted_request = proxy.exchanges[0][0]
                    accepted_key = json.loads(accepted_request)["key"]
                    deadline = time.monotonic() + 10
                    # A backend reply does not join the visible transcript.
                    # Finish this answer before a diagnostic command can cancel it.
                    human.read_terminal(master, "accepted work remains accepted",
                        timeout=deadline - time.monotonic(), composer=True)
                    while True:
                        os.write(master, b"/status\n")
                        status = human.read_terminal(master, "Session: original/session",
                            timeout=deadline - time.monotonic(), composer=True)
                        # /status exposes unresolved frontend custody, independently
                        # of the accepted backend reply and canonical database.
                        if "Original reserved request:" not in status:
                            assert "Publication/admission may be incomplete" not in status, status
                            break
                        assert accepted_key in status, status
                        assert time.monotonic() < deadline, ("frontend did not settle Admission", status)
                    message_records = {
                        path.name: path.read_bytes()
                        for path in (home / ".config/rui/requests").glob("*.json")
                        if json.loads(path.read_bytes())["kind"] == "message"
                    }
                    assert message_records == {**before_messages, f"{accepted_key}.json": accepted_request}
                    assert set(message_records) - set(before_messages) == {f"{accepted_key}.json"}
                    assert message_records[f"{accepted_key}.json"] == accepted_request
                    assert len(proxy.exchanges) == 1 and proxy.mutations == [("/v1/message", accepted_request)]
                    proxy.rewrite = None
                    proxy.route = route
                if binding and line is not None:
                    marker = reason if route == "/v1/configure" else "Decision not confirmed" if route == "/v1/control/permission-decision" else "Not confirmed"
                    deadline = time.monotonic() + 15
                    output = human.read_terminal(master, marker, timeout=deadline - time.monotonic(),
                        composer=True)
                    assert "other/session" not in output and '"answer"' not in output, output
                    original = proxy.exchanges[0][0]
                    key = json.loads(original)["key"]
                    record = home / ".config/rui/requests" / f"{key}.json"
                    assert record.read_bytes() == original, "unconfirmed reply replaced captured authority"
                    if route == "/v1/configure":
                        expect_mutation_error(subprocess.CompletedProcess(caller.args, None,
                            stdout=output.replace("\r\n", "\n")), json.loads(original),
                            human=True, status=200, reason=reason, diagnostic=None)
                        assert len(proxy.exchanges) == 1, "unconfirmed Configure automatically retried"
                    else:
                        # An unresolved Message intentionally suppresses consent
                        # until exact recovery. Its composer, not Action readiness,
                        # owns this diagnostic handoff.
                        if route == "/v1/control/permission-decision":
                            if "denied tool saved" not in output:
                                output += human.read_terminal(master, "denied tool saved",
                                    timeout=deadline - time.monotonic(), composer=True)
                            elif "› " not in output.split("denied tool saved", 1)[1]:
                                output += human.read_terminal(master, "› ", timeout=deadline - time.monotonic())
                        os.write(master, b"/status\n")
                        diagnostic = human.read_terminal(master, f"Last submission error: {reason}", composer=True)
                        assert key in diagnostic and "Ctrl-R retries this exact original" in diagnostic, diagnostic
                        # No ordinary no-op may retry an unresolved submission.
                        os.write(master, b"\n")
                        human.read_terminal(master, "› ")
                        assert len(proxy.exchanges) == 1, "empty input retried unconfirmed intent"
                        proxy.rewrite = lambda response: response
                        os.write(master, b"\x12")
                        output += human.read_terminal(master, "Decision confirmed." if route == "/v1/control/permission-decision" else "Original confirmed.")
                        assert len(proxy.exchanges) == 2 and proxy.exchanges[1][0] == original
                        recovered = json.loads(proxy.exchanges[1][1].split(b"\r\n\r\n", 1)[1])["answer"]
                        assert recovered["status"] == "accepted" and recovered["replayed"] is True, recovered
                        assert record.read_bytes() == original
                        if route == "/v1/message":
                            if "a: Allow once / d: Deny (Enter)" not in output:
                                output += human.read_terminal(master, "a: Allow once / d: Deny (Enter)")
                            output += human.action_ready(ready_read, master)
                    os.write(master, b"/exit\n")
                # Supply output credit during the original exit budget for
                # fatal cleanup and recoverable explicit detachment alike.
                try:
                    transcript, errors = human.terminal_exit(caller, master, timeout=10)
                except AssertionError as error:
                    if isinstance(error.args[0], tuple) and error.args[0][0] == "terminal exit timeout":
                        raise subprocess.TimeoutExpired(caller.args, 10,
                            output=error.args[0][1], stderr=error.args[0][2]) from error
                    raise
                output += transcript.decode(errors="replace")
                if binding and line is not None:
                    assert caller.returncode == 0, "explicit detachment failed"
                else:
                    assert caller.returncode != 0, "fatal mutation resumed the Session prompt"
                errors = errors.decode()
                if not binding or line is None or route == "/v1/configure":
                    assert (reason if binding else "CanonicalStoreFailure") in errors, errors
                else:
                    assert "CanonicalStoreFailure" not in errors, errors
                if route == "/v1/activity-page":
                    assert f"Message accepted; do not resubmit it. Use rui request read-result {accepted_key} for the same Message's answer." in errors, errors
                    assert "outcome unconfirmed" not in errors and "Ctrl-R" not in errors, errors
                    assert "Original reserved request:" not in output and "Not confirmed" not in output, output
                    assert "› " not in output, "fatal Activity read resumed the composer"
                    assert proxy.mutations == [("/v1/message", accepted_request)], "fatal read retransmitted Message"
                    assert {
                        path.name: path.read_bytes()
                        for path in (home / ".config/rui/requests").glob("*.json")
                        if json.loads(path.read_bytes())["kind"] == "message"
                    } == message_records, "fatal observation captured replacement intent"
                    assert proxy.exchanges[0][0] == accepted_request
                assert "admitted:" not in output and "Configured." not in output, output
                assert "You: " not in output, output
                if not binding or line is None:
                    assert "Detached." not in output, output
                    if line is None:
                        assert "› " not in output, "unaccepted fresh configuration entered the frontend"
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original_terminal[3] &= ~mask
                assert actual == original_terminal, "fatal invocation did not restore the terminal"
                request, reply = proxy.exchanges[0]
                decoded = json.loads(reply.split(b"\r\n\r\n", 1)[1])
                assert decoded["answer"]["status"] == "accepted"
                key = json.loads(request)["key"]
                record = home / ".config/rui/requests" / f"{key}.json"
                assert json.loads(record.read_bytes())["key"] == key
            finally:
                if sys.exc_info()[0] is not None:
                    preserve_failure_metadata(state / "pty-failure.json", lambda: {
                        "route": route, "bare_entry": line is None,
                        "error": sys.exc_info()[0].__name__,
                        "terminal": getattr(sys.exc_info()[1], "terminal_metadata", None),
                        "terminal_canonical": bool(termios.tcgetattr(slave)[3] & termios.ICANON),
                        "caller_returncode": caller.poll() if caller is not None else None,
                        "ready_pending": bool(select.select([ready_read], [], [], 0)[0]),
                        "terminal_pending": bool(select.select([master], [], [], 0)[0]),
                        "exchanges": len(proxy.exchanges) if proxy is not None else 0,
                        "mutation_routes": [route for route, _ in proxy.mutations] if proxy is not None else [],
                    })
                if proxy is not None:
                    proxy.close()
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                if caller is not None:
                    caller.stderr.close()
                os.close(master)
                os.close(slave)
                os.close(ready_read)
                os.close(ready_write)
    finally:
        fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        assert not endpoint_thread.is_alive(), "provider fixture did not join"
    print(f"{'null' if null_code else 'binding' if binding else 'canonical'} PTY: Configure/Message/Permission/bare creation fail before outcome interpretation, restore terminal and retain original capture", flush=True)


def permission_read_cases(state):
    import human_cli_integration as human
    home = state / "permission-read"
    home.mkdir()
    store = home / "store"
    endpoint = fixture.SuccessEndpoint([fixture.sse_tool_calls("permission-read", [("bash", "permission-call",
        '{"cmd":"true","timeout_ms":null,"description":"Check successful shell exit"}')])])
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = None
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        assert invoke(home, "session", "configure", "--store", store, "--session", "permission/read",
            "--workspace", state, "--provider", "codex", "--model", "model-a",
            "--permission-mode", "ask").returncode == 0
        assert invoke(home, "session", "send", "--store", store, "--session", "permission/read",
            "inspect exact permission").returncode == 0
        records = home / ".config/rui/requests"
        before = {path.name: path.read_bytes() for path in records.glob("*.json")}
        for status, body, expected in (
                (500, ERROR_BYTES, "CanonicalStoreFailure"),
                (503, b'{"version":"1","type":"busy","code":"host_busy"}', "ActionReadFailed"),
                (500, ERROR_BYTES[:-1], "InvalidResponse"),
                (409, ERROR_BYTES, "InvalidResponse")):
            response = (f"HTTP/1.1 {status} Rejected\r\nContent-Type: application/json\r\n"
                f"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body
            proxy = ReplyProxy(host, "/v1/read-action-arguments", lambda reply: response)
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            caller = None
            try:
                caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "permission/read"],
                    env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                try:
                    output, errors = human.terminal_exit(caller, master, timeout=10)
                except AssertionError as error:
                    if isinstance(error.args[0], tuple) and error.args[0][0] == "terminal exit timeout":
                        raise AssertionError("failed permission read did not exit") from error
                    raise
                errors = errors.decode()
                assert caller.returncode != 0 and expected in errors, (expected, errors)
                if expected == "CanonicalStoreFailure":
                    assert "rui: Read failed: HTTP 500; type: invocation_error; code: canonical_store_failure\n" in errors, errors
                elif expected == "ActionReadFailed":
                    assert "rui: Read failed: HTTP 503; type: busy; code: host_busy\n" in errors, errors
                else:
                    assert "rui: Read failed:" not in errors and "type:" not in errors and "code:" not in errors, errors
                assert b"a: Allow once" not in output and b"Run Bash:" not in output, output
                assert len(proxy.exchanges) == 1 and proxy.mutations == [], proxy.mutations
                assert {path.name: path.read_bytes() for path in records.glob("*.json")} == before
                actual = termios.tcgetattr(slave)
                if sys.platform == "darwin":
                    mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                    actual[3] &= ~mask
                    original[3] &= ~mask
                assert actual == original, "failed permission read did not restore terminal"
            finally:
                if sys.exc_info()[0] is not None:
                    preserve_failure_metadata(state / "pty-failure.json", lambda: {
                        "case": "permission_read", "response_status": status,
                        "error": sys.exc_info()[0].__name__,
                        "caller_returncode": caller.poll() if caller is not None else None,
                        "terminal_pending": bool(select.select([master], [], [], 0)[0]),
                        "exchanges": len(proxy.exchanges), "mutations": len(proxy.mutations),
                    })
                proxy.close()
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                if caller is not None:
                    caller.stderr.close()
                os.close(master)
                os.close(slave)
        # An ordinary details preparation failure stays live and is delivered
        # before the next Activity borrower can reset its diagnostic storage.
        assert invoke(home, "session", "configure", "--store", store, "--session", "details/read",
            "--workspace", state, "--provider", "codex", "--model", "model-a").returncode == 0
        before = {path.name: path.read_bytes() for path in records.glob("*.json")}
        body = b'{"version":"1","type":"busy","code":"host_busy"}'
        response = (b"HTTP/1.1 503 Rejected\r\nContent-Type: application/json\r\n"
            b"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
            + str(len(body)).encode() + b"\r\n\r\n" + body)
        proxy = ReplyProxy(host, "/v1/conversation-page", lambda reply: response)
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        caller = None
        try:
            caller = subprocess.Popen([str(fixture.RUI), "session", "resume", "--store", str(store), "details/read"],
                env={**os.environ, "HOME": str(home)}, stdin=slave, stdout=slave, stderr=subprocess.PIPE)
            human.read_terminal(master, "› ")
            os.write(master, b"/details\n")
            output = human.read_terminal(master,
                "! Details unavailable; draft retained. HTTP 503; type: busy; code: host_busy", timeout=10)
            assert caller.poll() is None, output
            os.write(master, b"\x03")
            _, errors = human.terminal_exit(caller, master, timeout=10)
            assert caller.returncode == 0 and b"rui: Read failed:" not in errors, errors
            assert len(proxy.exchanges) == 1 and proxy.mutations == [], proxy.mutations
            assert {path.name: path.read_bytes() for path in records.glob("*.json")} == before
            actual = termios.tcgetattr(slave)
            if sys.platform == "darwin":
                mask = getattr(termios, "PENDIN", 0) | getattr(termios, "FLUSHO", 0)
                actual[3] &= ~mask
                original[3] &= ~mask
            assert actual == original, "recoverable details failure did not restore terminal"
        finally:
            proxy.close()
            if caller is not None and caller.poll() is None:
                caller.kill()
                caller.wait(timeout=5)
            if caller is not None:
                caller.stderr.close()
            os.close(master)
            os.close(slave)
    finally:
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        assert not thread.is_alive(), "permission provider fixture did not join"
    print("automatic permission read: canonical/ordinary/invalid failures retain classification, restore terminal and never consent or mutate", flush=True)


def store_read_cases(state):
    """A canonical read fault in the Host fences it; it is never an ordinary miss."""
    home = state / "store-read"
    home.mkdir(mode=0o700)
    store = home / "store"
    host = fixture.start_host(store, None)
    try:
        fixture.configure(home, store, "store-read-configure", "s", "model-a")
        fixture.message(home, store, "store-read-message", "s", "queued work")
        before = invoke(home, "request", "read-result", "--store", store, "--key", "store-read-message")
        assert json.loads(before.stdout)["error"]["code"] == "result_not_ready", before
        # The statement still compiles; SQLite fails it at the first step,
        # as for an I/O or corruption fault after preparation.
        database = sqlite3.connect(store / "rui.sqlite3")
        try:
            with database:
                database.execute("ALTER TABLE core_command RENAME TO core_command_unreadable")
                database.execute("CREATE VIEW core_command AS SELECT * FROM core_command_unreadable "
                    "WHERE abs(-9223372036854775808) IS NOT NULL")
        finally:
            database.close()
        result = invoke(home, "request", "read-result", "--store", store, "--key", "store-read-message")
        expect_fatal(result)
        assert json.loads(result.stdout) == {"key": "store-read-message",
            "error": {"status": 500, "type": ERROR["type"], "code": ERROR["code"]}}, result
        fixture.wait_for(lambda: host.poll() is not None, "canonical read fault fences the Host")
        assert host.returncode == 1, host.returncode
        failure = host.stderr.read()
        assert b"dispatch fenced after result observation failure: ResultReadFailed" in failure, failure
    finally:
        fixture.stop_host(host)
    print("canonical Store read: step fault fences the Host instead of reporting result_not_found", flush=True)


def keyed_observation_cases(state, only="keyed"):
    home = state / only
    home.mkdir(mode=0o700)
    store = home / "store"
    endpoint = fixture.SuccessEndpoint([fixture.ResponseSpec(b"permanent failure", {}, 422)])
    endpoint_thread = threading.Thread(target=endpoint.serve_forever)
    endpoint_thread.start()
    host = None
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        kinds = ("configure", "message", "session_stop", "model_interruption", "permission_decision")
        commands = (["session", "configure", "--workspace", state, "--provider", "codex", "--model", "model-a"],
            ["session", "send", "submitted bytes"], ["session", "stop"],
            ["session", "interrupt-model", "--turn", "733", "--operation", "911"], ["action", "allow", "--action", "721"])
        keys = {}
        for kind, command in zip(kinds, commands):
            args = [*command, "--store", store, "--session", "s"]
            args += [] if kind == "message" else ["--record", home / f"{kind}.json", "--key", kind]
            submitted = invoke(home, *args)
            # A saved rejection is delivered on stdout with exit 1.
            rejected = kind in ("model_interruption", "permission_decision")
            assert submitted.returncode == (1 if rejected else 0), submitted
            key = announced(submitted) if kind == "message" else kind
            assert json.loads(submitted.stdout)["context"]["key"] == key, submitted
            keys[kind] = key
            observed = json.loads(invoke(home, "request", "inspect", "--store", store, "--key", key).stdout)["observation"]
            assert observed["kind"] == kind and observed["target"] == "s", observed
            assert observed["status"] == ("rejected" if kind in ("model_interruption", "permission_decision") else "accepted"), observed
            if kind == "message":
                fixture.wait_for(lambda: fixture.observe(store, key).get("result"), "accepted Message's terminal outcome")
        key = keys["message"]
        def rewrite(response, omitted=False):
            head, body = response.split(b"\r\n\r\n", 1)
            value = json.loads(body)
            observation = value["observation"]
            if omitted:
                assert observation["status"] == "accepted" and "processing" in observation and "result" in observation, observation
                del observation["processing"]
            else:
                observation["wire_only"] = "must-not-be-presented"
            encoded = json.dumps(value, indent=2, ensure_ascii=True).encode()
            return (head.split(b"\r\n", 1)[0] + b"\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nContent-Length: "
                + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
        for omitted in (False, True):
            if only == "keyed-bindings" and not omitted or only == "keyed-output" and omitted:
                continue
            proxy = ReplyProxy(host, "/v1/observe-command", lambda response: rewrite(response, omitted))
            try:
                for args in (["request", "inspect", "--store", store, "--key", key], ["request", "inspect", key]):
                    result = invoke(home, *args)
                    if omitted:
                        assert result.returncode != 0 and "InvalidObservation" in result.stderr, ("omitted processing binding was confirmed", result)
                        assert not result.stdout, result
                    else:
                        assert result.returncode == 0 and "must-not-be-presented" not in result.stdout, ("unknown DOM leaked", result)
                        rendered = json.loads(result.stdout)["observation"]
                        assert rendered["status"] == "accepted" and rendered["result"]["status"] == "failed", ("accepted request confused with failed work", rendered)
                        assert all(field in rendered for field in ("input", "queue", "processing")), rendered
            finally:
                proxy.close()
        # The saved handle reads only the original answer: failed work, not a substitute.
        failed = invoke(home, "request", "read-result", key)
        assert failed.returncode != 0 and json.loads(failed.stdout) == {
            "key": key, "error": {"status": 409, "type": "result_unavailable", "code": "result_failed"}}, failed
        unavailable = invoke(home, "request", "read-result", "--store", store, "--key", "never-submitted")
        assert unavailable.returncode != 0 and json.loads(unavailable.stdout) == {
            "key": "never-submitted", "error": {"status": 409, "type": "result_unavailable", "code": "result_not_found"}}, unavailable
    finally:
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        assert not endpoint_thread.is_alive(), "keyed provider fixture did not join"
    print(f"{only}: five actual operation observations, accepted request vs failed work; typed keyed/handle inspection, handle read-result and diagnostics passed", flush=True)


def main(selected="all"):
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-canonical-failure."))
    completed = False
    try:
        assert selected in ("all", "producers", "committed", "interactive", "permission-read", "bindings", "nulls", "binding-interactive", "null-interactive", "keyed", "keyed-bindings", "keyed-output", "store-read"), selected
        if selected in ("keyed-bindings", "keyed-output"):
            keyed_observation_cases(state, selected)
        for name, case in (("producers", producer_cases), ("committed", committed_cases), ("store-read", store_read_cases), ("interactive", interactive_cases), ("permission-read", permission_read_cases), ("bindings", binding_cases), ("nulls", lambda path: binding_cases(path, null_code=True)), ("binding-interactive", lambda path: interactive_cases(path, binding=True)), ("null-interactive", lambda path: interactive_cases(path, null_code=True)), ("keyed", keyed_observation_cases)):
            if selected in ("all", name):
                case(state)
        completed = True
    finally:
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained canonical failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[2] if len(sys.argv) == 3 else "all")
