#!/usr/bin/env python3
"""Canonical invocation failure at real producers and current caller boundaries."""
import json
import os
import pathlib
import pty
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

import dispatch_integration as fixture

ERROR = {"version": "1", "type": "invocation_error", "code": "canonical_store_failure"}
ERROR_BYTES = json.dumps(ERROR, separators=(",", ":")).encode()


def invoke(home, *args):
    return subprocess.run([str(fixture.RUI), *map(str, args)],
        env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=20)


def expect_fatal(result):
    assert result.returncode != 0 and "CanonicalStoreFailure" in result.stderr, result
    assert "admitted:" not in result.stdout and "replayed:" not in result.stdout, result
    assert "no work was admitted" not in result.stdout, result


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
                if mode == "raw":
                    assert json.loads(result.stdout) == ERROR, result
                elif mode == "json":
                    captured, failed = map(json.loads, result.stdout.splitlines())
                    key = captured["request"]
                    assert captured == {"event": "captured", "request": key}, captured
                    assert failed == {"event": "invocation_error", "request": key, "error": ERROR}, failed
                else:
                    assert result.stdout.splitlines()[-1] == ERROR_BYTES.decode(), result
                    key = result.stdout.splitlines()[0].removeprefix("request: ")
                if mode != "raw":
                    record = home / ".config/rui/requests" / f"{key}.json"
                original = record.read_bytes()
                assert json.loads(original)["key"] == key, original
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
                        assert json.loads(recovered.stdout) == ERROR and record.read_bytes() == original, recovered
                    finally:
                        fixture.stop_host(host)
            host = fixture.start_host(store, None, "--fault", "before-commit")
            try:
                retried = invoke(home, "retry", "--store", store, "--record", record, "--kind", kind)
                expect_fatal(retried)
                assert json.loads(retried.stdout) == ERROR and record.read_bytes() == original, retried
            finally:
                fixture.stop_host(host)
    print("canonical producers: all five fenced HTTP mutation owners; raw/human/JSON and five retry kinds passed", flush=True)


class ReplyProxy(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    """Forward the real request, drain its reply, replace only the selected route."""
    def __init__(self, host, route):
        self.path = pathlib.Path(host.rui_ready_fields["socket"])
        self.backend = self.path.with_suffix(".canonical-backend")
        self.path.rename(self.backend)
        self.route = route
        self.exchanges = []
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
        if route == self.server.route:
            self.server.exchanges.append((body, response))
            response = (b"HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\n"
                b"X-Rui-Wire-Version: 1\r\nConnection: close\r\nContent-Length: "
                + str(len(ERROR_BYTES)).encode() + b"\r\n\r\n" + ERROR_BYTES)
        self.request.sendall(response)


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
                assert failed == {"event": "invocation_error", "request": key, "error": ERROR}, failed
                assert captured == {"event": "captured", "request": key}, captured
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
        # Reads/observations have no operation answer either; raw routes retain
        # the full envelope, while typed follow fails instead of fabricating work.
        for route, args in (
            ("/v1/observe-command", ["observe-command", "--key", key]),
            ("/v1/read-result", ["read-result", "--key", key]),
            ("/v1/inspect-session", ["inspect-session", "--session", "original/session"]),
        ):
            proxy = ReplyProxy(host, route)
            try:
                result = invoke(home, *args, "--store", store)
                expect_fatal(result)
                assert json.loads(result.stdout) == ERROR, result
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


def interactive_cases(state):
    import human_cli_integration as human
    import codex_integration as codex
    home = state / "interactive"
    home.mkdir()
    store = home / "store"
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
                ("/v1/configure", None), ("/v1/observe-command", "confirmed terminal bytes")):
            master, slave = pty.openpty()
            original_terminal = termios.tcgetattr(slave)
            ready_read, ready_write = os.pipe()
            args = (["session", "--store", str(store), "--session", "original/session"] if line is not None
                else ["--store", str(store), "--provider", "codex", "--model", "gpt-6-luna"])
            proxy = None
            caller = None
            try:
                if line is None:
                    proxy = ReplyProxy(host, route)
                caller = subprocess.Popen([str(fixture.RUI), *args],
                    env={**os.environ, "HOME": str(home), "RUI_TEST_ACTION_READY_FD": str(ready_write)},
                    pass_fds=(ready_write,), stdin=slave, stdout=slave, stderr=subprocess.PIPE)
                if line is not None:
                    human.read_terminal(master, "rui> ")
                    proxy = ReplyProxy(host, route)
                    os.write(master, (line + "\n").encode())
                    if route == "/v1/control/permission-decision":
                        human.read_terminal(master, "Allow once, deny, or later?")
                        human.action_ready(ready_read)
                        os.write(master, b"d\n")
                output = "" if route == "/v1/observe-command" else human.read_terminal(master, "canonical_store_failure")
                assert caller.wait(timeout=10) != 0, "fatal mutation resumed the Session prompt"
                errors = caller.stderr.read().decode()
                assert "CanonicalStoreFailure" in errors, errors
                if route == "/v1/observe-command":
                    assert "Message accepted" in errors and "do not resubmit it" in errors and "admission may be uncertain" not in errors, errors
                # Drain before checking that there is no later prompt/success.
                while select.select([master], [], [], 0.05)[0]:
                    output += os.read(master, 65536).decode(errors="replace")
                assert "rui> " not in output and "Detached." not in output and "admitted:" not in output, output
                assert termios.tcgetattr(slave) == original_terminal, "fatal invocation did not restore the terminal"
                request, reply = proxy.exchanges[0]
                decoded = json.loads(reply.split(b"\r\n\r\n", 1)[1])
                assert decoded["observation" if route == "/v1/observe-command" else "answer"]["status"] == "accepted"
                key = json.loads(request)["key"]
                record = home / ".config/rui/requests" / f"{key}.json"
                assert json.loads(record.read_bytes())["key"] == key
            finally:
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
    print("canonical PTY: Configure/Message/Permission/bare creation fail before outcome interpretation, restore terminal and retain original capture", flush=True)


def main(selected="all"):
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-canonical-failure."))
    completed = False
    try:
        assert selected in ("all", "producers", "committed", "interactive"), selected
        for name, case in (("producers", producer_cases), ("committed", committed_cases), ("interactive", interactive_cases)):
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
