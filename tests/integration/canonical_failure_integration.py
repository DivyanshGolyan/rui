#!/usr/bin/env python3
"""Canonical invocation failure at real producers and current caller boundaries."""
import json
import fcntl
import os
import pathlib
import pty
import re
import select
import shutil
import struct
import socket
import socketserver
import sqlite3
import subprocess
import sys
import tempfile
import termios
import threading
import time

import dispatch_integration as fixture
from host_process import canonical_fixture_root, assert_persistent_terminal_restored

ERROR = {"version": "1", "type": "invocation_error", "code": "canonical_store_failure"}
ERROR_BYTES = json.dumps(ERROR, separators=(",", ":")).encode()


def invoke(home, *args):
    return subprocess.run([str(fixture.RUI), *map(str, args)],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=20)


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
    observed = json.loads(result.stdout.splitlines()[-1])
    if "event" in observed:
        assert observed["event"] == "invocation_error" and observed["request"] == saved["key"], observed
        observed = observed["error"]
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
        "configure": ["configure", "--workspace", state, "--provider", "codex", "--model", "model-a"],
        "message": ["message", "--text", text],
        "permission-decision": ["allow-action", "--action", "7"],
        "permission-denial": ["deny-action", "--action", "7"],
        "session-stop": ["stop-session"],
        "model-interruption": ["interrupt-model", "--turn", "3", "--operation", "5"],
    }
    for name, command in commands.items():
        kind = "permission-decision" if name == "permission-denial" else name
        modes = ("raw", "human", "json") if kind in ("configure", "message", "permission-decision") else ("raw",)
        for mode in modes:
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
                elif mode == "json":
                    args += ["--json"]
                result = invoke(home, *args)
                expect_fatal(result)
                if mode == "json":
                    captured, failed = map(json.loads, result.stdout.splitlines())
                    key = captured["request"]
                    assert captured == {"event": "captured", "request": key}, captured
                elif mode == "human":
                    key = result.stdout.splitlines()[0].removeprefix("request: ")
                if mode != "raw":
                    record = home / ".config/rui/requests" / f"{key}.json"
                original = record.read_bytes()
                assert json.loads(original)["key"] == key, original
                expect_mutation_error(result, json.loads(original), human=mode == "human")
                # The production fault must fence/shut down, not just return a
                # fixture-owned fatal reply while the Host keeps admitting.
                assert host.wait(timeout=10) != 0, "Store fault did not fence the Host"
            finally:
                fixture.stop_host(host)
            if mode != "raw":
                for recovery_mode in ([], ["--json"]):
                    host = fixture.start_host(store, None, "--fault", "before-commit")
                    try:
                        recovered = invoke(home, "recover", key, *recovery_mode)
                        expect_fatal(recovered)
                        expect_mutation_error(recovered, json.loads(original), human=not recovery_mode)
                        assert record.read_bytes() == original, recovered
                    finally:
                        fixture.stop_host(host)
            host = fixture.start_host(store, None, "--fault", "before-commit")
            try:
                retried = invoke(home, "retry", "--store", store, "--record", record, "--kind", kind)
                expect_fatal(retried)
                expect_mutation_error(retried, json.loads(original))
                assert record.read_bytes() == original, retried
            finally:
                fixture.stop_host(host)
    print("canonical producers: all five fenced HTTP mutation owners; typed explicit/human/JSON diagnostics and five retry kinds passed", flush=True)


class ReplyProxy(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """Forward the real request, drain its reply, replace only the selected route."""
    def __init__(self, host, route, rewrite=None):
        self.path = pathlib.Path(host.rui_ready_fields["socket"])
        self.backend = self.path.with_suffix(".canonical-backend")
        self.path.rename(self.backend)
        self.route = route
        self.rewrite = rewrite
        self.exchanges = []
        self.host_exchanges = []
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
        route = head.split(b" ")[1].decode()
        self.server.host_exchanges.append((route, body, response))
        if route == self.server.route:
            self.server.exchanges.append((body, response))
            if self.server.rewrite is not None:
                response = self.server.rewrite(response)
            else:
                response = (b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n"
                    b"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
                    + str(len(ERROR_BYTES)).encode() + b"\r\n\r\n" + ERROR_BYTES)
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


def presentation_cases(state):
    home = state / "presentation"
    home.mkdir(mode=0o700)
    store = home / "store"
    host = fixture.start_host(store, None)
    try:
        for fatal in (False, True):
            def rewrite(response):
                value = json.loads(response.split(b"\r\n\r\n", 1)[1])
                if fatal:
                    value = {"version": "1", "type": "busy", "code": "ordinary_capacity_exhausted"}
                value["wire_only"] = "must-not-be-presented"
                encoded = json.dumps(value, indent=2, ensure_ascii=True).encode()
                return ((b"HTTP/1.1 503 Unavailable" if fatal else b"HTTP/1.1 200 OK")
                    + b"\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
                    + str(len(encoded)).encode() + b"\r\n\r\n" + encoded)
            for mode in ("explicit", "human", "json"):
                record = home / f"{fatal}-{mode}.json"
                args = ["configure", "--store", store, "--session", 'original/µ"',
                    "--workspace", state, "--provider", "codex", "--model", "model-a"]
                args += ["--record", record, "--key", 'explicit/µ"'] if mode == "explicit" else (["--json"] if mode == "json" else [])
                proxy = ReplyProxy(host, "/v1/configure", rewrite)
                try:
                    result = invoke(home, *args)
                finally:
                    proxy.close()
                saved = json.loads(proxy.exchanges[0][0])
                assert "must-not-be-presented" not in result.stdout and '"version"' not in result.stdout, result
                if fatal:
                    assert result.returncode != 0 and "HostInvocationFailed" in result.stderr, result
                    expect_mutation_error(result, saved, human=mode == "human", status=503,
                        reason="HostInvocationFailed", diagnostic={"type": "busy", "code": "ordinary_capacity_exhausted"})
                else:
                    assert result.returncode == 0, result
                    if mode == "human":
                        assert "admitted: accepted" in result.stdout and "revision:" in result.stdout, result
                    else:
                        rendered = json.loads(result.stdout.splitlines()[-1])
                        if mode == "json":
                            rendered = rendered["admission"]
                        assert rendered["answer"] == json.loads(proxy.exchanges[0][1].split(b"\r\n\r\n", 1)[1])["answer"], rendered
                        assert rendered["context"]["key"] == saved["key"] and rendered["context"]["session"] == saved["session"], rendered
    finally:
        fixture.stop_host(host)
    print("mutation presentation: typed explicit/human/JSON facts and noncanonical diagnostics, original escaped identity; no Host wire passthrough", flush=True)


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
        ("configure", "/v1/configure", ["configure", "--workspace", state, "--provider", "codex", "--model", "model-a"]),
        ("message", "/v1/message", ["message", "--text", text]),
        ("session-stop", "/v1/control/session-stop", ["stop-session"]),
        ("model-interruption", "/v1/control/model-interruption", ["interrupt-model", "--turn", "3", "--operation", "11"]),
        ("permission-decision", "/v1/control/permission-decision", ["deny-action", "--action", "7"]),
        ("permission-allow", "/v1/control/permission-decision", ["allow-action", "--action", "7"]),
    )
    try:
        for name, route, command in commands:
            kind = "permission-decision" if name == "permission-allow" else name
            for mode in (("raw", "human", "json") if kind in ("configure", "message", "permission-decision") else ("raw",)):
                record = home / f"{name}-{mode}.json"
                args = [*command, "--store", store, "--session", "original/session"]
                args += ["--record", record, "--key", f"{name}-{mode}"] if mode == "raw" else (["--json"] if mode == "json" else [])
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
                    record = home / ".config/rui/requests" / f"{key}.json"
                assert record.read_bytes() == request
                expect_mutation_error(result, saved, human=mode == "human", status=200,
                    reason=reason, diagnostic=None)
                for recovery in (["retry", "--store", store, "--record", record, "--kind", kind],
                        *([["recover", key, "--json"]] if mode != "raw" else [])):
                    proxy = ReplyProxy(host, route, rewrite)
                    try:
                        failed = invoke(home, *recovery)
                        assert failed.returncode != 0 and reason in failed.stderr, failed
                    finally:
                        proxy.close()
                    expect_mutation_error(failed, saved, status=200, reason=reason, diagnostic=None)
                    assert record.read_bytes() == request
                recovered = invoke(home, "retry", "--store", store, "--record", record, "--kind", kind)
                assert recovered.returncode == 0 and json.loads(recovered.stdout)["answer"]["replayed"] is True, recovered
                if mode != "raw":
                    recovered = invoke(home, "recover", key, "--json")
                    assert recovered.returncode == 0 and json.loads(recovered.stdout)["answer"]["replayed"] is True, recovered
                assert record.read_bytes() == request
    finally:
        fixture.stop_host(host)
    print(f"mutation {'nulls' if null_code else 'bindings'}: five typed explicit/human/JSON/retry/recover callers reject {'present null code' if null_code else 'wrong Session, digest, target or decision'}; original-key replay preserved", flush=True)


def committed_cases(state):
    home = state / "committed"
    home.mkdir()
    store = home / "store"
    host = fixture.start_host(store, None)
    try:
        configured = invoke(home, "configure", "--store", store, "--session", "original/session",
            "--workspace", state, "--provider", "codex", "--model", "model-a", "--json")
        assert configured.returncode == 0, configured
        for mode in ("human", "json"):
            proxy = ReplyProxy(host, "/v1/message")
            try:
                result = invoke(home, "message", "--store", store, "--session", "original/session",
                    "original committed bytes", *(["--json"] if mode == "json" else []))
                expect_fatal(result)
            finally:
                proxy.close()
            request, reply = proxy.exchanges[0]
            assert reply.startswith(b"HTTP/1.1 200"), reply
            answer = json.loads(reply.split(b"\r\n\r\n", 1)[1])["answer"]
            assert answer["status"] == "accepted" and answer["replayed"] is False, answer
            key = json.loads(request)["key"]
            record = home / ".config/rui/requests" / f"{key}.json"
            original = record.read_bytes()
            assert request == original, "transmission changed the captured inputs"
            saved = json.loads(original)
            assert saved["key"] == key and saved["store"] == str(store.resolve()) and saved["session"] == "original/session", saved
            if mode == "json":
                captured, failed = map(json.loads, result.stdout.splitlines())
                assert captured == {"event": "captured", "request": key}, captured
            expect_mutation_error(result, saved, human=mode == "human")
            for recovery_mode in ([], ["--json"]):
                recovered = invoke(home, "recover", key, *recovery_mode)
                assert recovered.returncode == 0, recovered
                if recovery_mode:
                    assert json.loads(recovered.stdout)["answer"] == {**answer, "replayed": True}, recovered
                else:
                    assert "admitted: accepted" in recovered.stdout and "replayed: true" in recovered.stdout, recovered
                assert record.read_bytes() == original, "fatal diagnosis replaced original recovery inputs"
            database = sqlite3.connect(store / "rui.sqlite3")
            try:
                assert database.execute("SELECT count(*) FROM core_command WHERE command_key=?", (key,)).fetchone() == (1,)
            finally:
                database.close()
        # Keyed reads retain typed diagnostics and the queried key; the distinct
        # inspection/report route remains outside this owner correction.
        for route, args in (
            ("/v1/observe-command", ["observe-command", "--key", key]),
            ("/v1/read-result", ["read-result", "--key", key]),
            ("/v1/inspect-session", ["inspect-session", "--session", "original/session"]),
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
        proxy = ReplyProxy(host, "/v1/observe-command")
        try:
            result = invoke(home, "follow", key, "--json")
            expect_fatal(result)
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
    home.mkdir(mode=0o700)
    store = home / "store"
    canonical_response = None
    if not binding:
        # Retain a real Host's canonical diagnosis, rather than manufacturing
        # canonical authority in the proxy used at the activity-read seam.
        fault_host = fixture.start_host(home / "fault-store", None, "--fault", "before-commit")
        fault_proxy = ReplyProxy(fault_host, "/v1/configure", lambda response: response)
        try:
            failed = invoke(home, "configure", "--store", home / "fault-store",
                "--session", "fault-source", "--workspace", state,
                "--provider", "codex", "--model", "model-a",
                "--record", home / "fault-source.json", "--key", "fault-source")
            expect_fatal(failed)
            canonical_response = fault_proxy.exchanges[0][1]
            assert canonical_response.startswith(b"HTTP/1.1 500 "), canonical_response
            assert json.loads(canonical_response.split(b"\r\n\r\n", 1)[1]) == ERROR
        finally:
            fault_proxy.close()
            fixture.stop_host(fault_host)
    endpoint = fixture.SuccessEndpoint([fixture.sse_tool_calls("canonical-tool", [("bash", "canonical-call",
        '{"cmd":"true","timeout_ms":null}')]),
        fixture.sse_answer("canonical-answer", "canonical-reason", "canonical-message", "denied tool saved")[0],
        fixture.sse_answer("confirmed-answer", "confirmed-reason", "confirmed-message", "accepted work remains accepted")[0]])
    endpoint_thread = threading.Thread(target=endpoint.serve_forever)
    endpoint_thread.start()
    host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
    try:
        configured = invoke(home, "configure", "--store", store, "--session", "original/session",
            "--workspace", state, "--provider", "codex", "--model", "model-a")
        assert configured.returncode == 0, configured
        codex.credentials(home / ".config/rui/codex.json")
        for route, line in (("/v1/configure", "/configure --permission-mode ask"),
                ("/v1/message", "original terminal bytes"), ("/v1/control/permission-decision", "/wait"),
                ("/v1/configure", None), ("/v1/activity-page", "confirmed terminal bytes")):
            if binding and route == "/v1/activity-page":
                continue  # Streaming observation belongs to the subsequent unit.
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
            original_terminal = termios.tcgetattr(slave)
            ready_read, ready_write = os.pipe()
            args = (["--resume", "--store", str(store), "--", "original/session"] if line is not None
                else ["--store", str(store), "--provider", "codex", "--model", "gpt-6-luna"])
            proxy = None
            caller = None
            try:
                if line is None:
                    proxy = ReplyProxy(host, route, rewrite)
                caller = subprocess.Popen([str(fixture.RUI), *args],
                    env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                    pass_fds=(ready_write,), stdin=slave, stdout=slave,
                    stderr=slave if route == "/v1/activity-page" else subprocess.PIPE)
                if line is not None:
                    human.read_terminal(master, "rui> ")
                    proxy = ReplyProxy(host, route,
                        (lambda response: canonical_response) if route == "/v1/activity-page" else rewrite)
                    os.write(master, (line + "\n").encode())
                    if route == "/v1/control/permission-decision":
                        human.read_terminal(master, "Ctrl-G 1 actionable")
                        os.write(master, b"\x07")
                        human.read_terminal(master, "Allow once, deny, or later?")
                        human.action_ready(ready_read)
                        os.write(master, b"d\n")
                if route == "/v1/activity-page" or (route == "/v1/control/permission-decision" and not binding):
                    output = ""
                elif route == "/v1/message" and not binding:
                    # Message admission is asynchronous; its fatal diagnosis
                    # is on stderr, not the command mutation's stdout notice.
                    output = human.read_terminal(master, "Rui: submitting; draft retained")
                else:
                    output = human.read_terminal(master, reason if binding else "CanonicalStoreFailure")
                if binding:
                    assert "other/session" not in output and '"answer"' not in output, output
                if binding and line is not None:
                    # Keep the existing recoverable invocation-error workflow;
                    # only canonical Store failure requires fatal detachment.
                    # Command-running redraws also contain rui>; they are not
                    # a ready prompt, and submitting /exit there is busy input.
                    ready = re.compile(r"\rRui: (?!command running|opening|submitting)[^\r\n]*\r*\n"
                        r"rui> \r\x1b\[5C")
                    deadline = time.monotonic() + 15
                    while not ready.search(output.split(reason, 1)[1]):
                        remaining = deadline - time.monotonic()
                        assert remaining > 0, ("no recovered ready prompt", output)
                        if select.select([master], [], [], remaining)[0]:
                            output += os.read(master, 65536).decode(errors="replace")
                            assert len(output) < 1024 * 1024, "unbounded prompt output"
                    os.write(master, b"/exit\n")
                # Supply output credit during the original exit budget for
                # fatal cleanup and recoverable explicit detachment alike.
                deadline = time.monotonic() + 10
                transcript = bytearray()
                while caller.poll() is None:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(caller.args, 10)
                    if select.select([master], [], [], min(remaining, 0.05))[0]:
                        transcript.extend(os.read(master, 65536))
                        assert len(transcript) < 1024 * 1024, "unexpected unbounded terminal output"
                output += transcript.decode(errors="replace")
                if binding and line is not None:
                    assert caller.returncode == 0, "explicit detachment failed"
                else:
                    assert caller.returncode != 0, "fatal mutation resumed the Session prompt"
                # Final original-request guidance is intentionally a bounded
                # best-effort TTY write. This case gives it ordinary terminal
                # output credit and captures one stdout/stderr byte order.
                errors = caller.stderr.read().decode() if caller.stderr is not None else ""
                if binding and line is not None:
                    assert reason in output, output  # Recoverable editor notice.
                elif route != "/v1/activity-page":
                    assert (reason if binding else "CanonicalStoreFailure") in errors, errors
                # Drain before checking that there is no later prompt/success.
                while select.select([master], [], [], 0.05)[0]:
                    output += os.read(master, 65536).decode(errors="replace")
                assert "admitted:" not in output and "Configured." not in output, output
                if route != "/v1/activity-page":
                    assert "You: " not in output, output
                if not binding or line is None:
                    # Earlier input echo is not a later prompt. Output also
                    # repaints the empty editor while the command still owns
                    # it; exclude only that explicit command-running frame.
                    if route == "/v1/activity-page":
                        # Acceptance can release composition before a later
                        # read fails. Only the fatal owner's joined diagnosis
                        # forbids another prompt; do not hide earlier frames.
                        guidance = "Rui: Original Admission accepted; do not replace intent."
                        assert guidance in output and "CanonicalStoreFailure" in output, output
                        later = output.split(guidance, 1)[1]
                    elif route == "/v1/message":
                        later = "Rui: submitting; draft retained" + output.split(
                            "Rui: submitting; draft retained", 1)[1]
                        later = re.sub(r"Rui: submitting; draft retained[^\r\n]*\r*\n"
                            r"rui> \r\x1b\[5C", "", later)
                    elif route == "/v1/control/permission-decision":
                        later = "\rRui: command running" + output.split("\rRui: command running", 1)[1]
                    else:
                        later = output.split(reason if binding else "CanonicalStoreFailure", 1)[1]
                    if route != "/v1/activity-page":
                        later = re.sub(r"\rRui: command running[^\r\n]*\r*\n"
                            r"rui> \r\x1b\[5C", "", later)
                assert_persistent_terminal_restored(slave, original_terminal)
                if route == "/v1/activity-page":
                    assert proxy.exchanges, "no activity read reached the owning seam"
                    assert not any(path == "/v1/observe-command" for path, _, _ in proxy.host_exchanges)
                    messages = [(body, reply) for path, body, reply in proxy.host_exchanges if path == "/v1/message"]
                    assert len(messages) == 1, "accepted Message was resubmitted"
                    request, reply = messages[0]
                    assert json.loads(proxy.exchanges[0][0])["kind"] == "activity_page"
                else:
                    request, reply = proxy.exchanges[0]
                decoded = json.loads(reply.split(b"\r\n\r\n", 1)[1])
                assert decoded["answer"]["status"] == "accepted"
                key = json.loads(request)["key"]
                record = home / ".config/rui/requests" / f"{key}.json"
                assert json.loads(record.read_bytes())["key"] == key
                assert record.read_bytes() == request, "transmission changed the captured inputs"
                if not binding or line is None:
                    assert "rui> " not in later and "Detached." not in output, output
                if route == "/v1/activity-page":
                    assert f"Store: {store}" in later and "Session: original/session" in later, later
                    assert f"Key: {key}" in later and "admission may be uncertain" not in later, later
            finally:
                if proxy is not None:
                    proxy.close()
                if caller is not None and caller.poll() is None:
                    caller.kill()
                    caller.wait(timeout=5)
                if caller is not None and caller.stderr is not None:
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
        commands = (["configure", "--workspace", state, "--provider", "codex", "--model", "model-a"],
            ["message", "submitted bytes"], ["stop-session"],
            ["interrupt-model", "--turn", "733", "--operation", "911"], ["allow-action", "--action", "721"])
        keys = {}
        for kind, command in zip(kinds, commands):
            args = [*command, "--store", store, "--session", "s"]
            args += ["--json"] if kind == "message" else ["--record", home / f"{kind}.json", "--key", kind]
            submitted = invoke(home, *args)
            assert submitted.returncode == 0, submitted
            key = json.loads(submitted.stdout.splitlines()[0])["request"] if kind == "message" else kind
            keys[kind] = key
            observed = json.loads(invoke(home, "observe-command", "--store", store, "--key", key).stdout)["observation"]
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
                for args in (["observe-command", "--store", store, "--key", key], ["result", key, "--json"], ["follow", key, "--json"]):
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
        human = invoke(home, "result", key)
        assert human.returncode == 0 and "admitted: accepted\nresult: failed\n" in human.stdout, human
        unavailable = invoke(home, "read-result", "--store", store, "--key", "never-submitted")
        assert unavailable.returncode != 0 and json.loads(unavailable.stdout) == {
            "key": "never-submitted", "error": {"status": 409, "type": "result_unavailable", "code": "result_not_found"}}, unavailable
    finally:
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        assert not endpoint_thread.is_alive(), "keyed provider fixture did not join"
    print(f"{only}: five actual operation observations, accepted request vs failed work; typed result/follow and diagnostics passed", flush=True)


def main(selected="all"):
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-canonical-failure."))
    completed = False
    try:
        assert selected in ("all", "producers", "committed", "interactive", "bindings", "nulls", "binding-interactive", "null-interactive", "presentation", "keyed", "keyed-bindings", "keyed-output"), selected
        if selected in ("keyed-bindings", "keyed-output"):
            keyed_observation_cases(state, selected)
        for name, case in (("producers", producer_cases), ("committed", committed_cases), ("interactive", interactive_cases), ("bindings", binding_cases), ("nulls", lambda path: binding_cases(path, null_code=True)), ("binding-interactive", lambda path: interactive_cases(path, binding=True)), ("null-interactive", lambda path: interactive_cases(path, null_code=True)), ("presentation", presentation_cases), ("keyed", keyed_observation_cases)):
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
