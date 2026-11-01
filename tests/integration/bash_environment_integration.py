#!/usr/bin/env python3
"""Bash runs in the environment of the terminal that sent the work.

A real Host starts with a secret in its own environment. Each person's
Message carries the sending terminal's environment, and the Session's next
Bash call sees it: the first Bash of the Turn, a later terminal's value, a
peer Message that leaves a person's value in place, a peer that fills a
Session no person has sent to, a refused oversized environment and the
recovery of that same saved request from another terminal. The Host's
secret never reaches Bash, and no environment value reaches a saved request.
The Host refuses a Message without a valid environment before admission.

The scripted model answers each request from its context: a request with no
tool output runs the command its user text names, and a continuation
answers. So every Message consumes its own exchange in any order.
"""
import http.server
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

import model_fixture as fixture
import host_process
from host_process import TestHTTPServer, canonical_fixture_root, dispose_all, retain_failure_state, start_ready_process, stop_process, wait_for

HOST_SECRET = "host-only-secret-5c1e"
CLIENT_PATH = "/client/bin:/usr/bin:/bin"
SHOW = ('printf "ENV[%s|%s|%s|%s]" "${CLIENT_MARK-unset}" "${HOST_SECRET-unset}" '
        '"${RUI_FAKE-unset}" "$PATH"')
RESULT = re.compile(r"ENV\[([^|\]]*)\|([^|\]]*)\|([^|\]]*)\|([^\]]*)\]")


def session_of(request):
    return fixture.instructions_session(request["instructions"])


def last_user_text(request):
    return next(item["content"] for item in reversed(request["input"]) if item.get("role") == "user")[-1]["text"]


def tool_outputs(request):
    """The outputs since the last User Message: this Turn's continuation."""
    items = request["input"]
    last_user = max(index for index, item in enumerate(items) if item.get("role") == "user")
    return [item["output"] for item in items[last_user:] if item.get("type") == "function_call_output"]


class Model(TestHTTPServer):
    """Runs `show`, or relays `show` to another Session as a peer."""

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.lock = threading.Lock()
        self.calls = 0
        # Each Session's Bash results, in order.
        self.results = {}

    def respond(self, request):
        session = session_of(request)
        outputs = tool_outputs(request)
        with self.lock:
            self.calls += 1
            name = f"call-{self.calls}"
            if outputs:
                found = RESULT.search(outputs[-1])
                if found:
                    self.results.setdefault(session, []).append(found.groups())
                return fixture.sse_answer(f"{name}-answer", f"{name}-reasoning", f"{name}-message", "done")[0]
        text = last_user_text(request)
        command = SHOW if text == "show" else f"printf show | rui session send --to {text.removeprefix('relay ')}"
        arguments = json.dumps({"cmd": command, "timeout_ms": 20000, "description": "Report the environment"}, separators=(",", ":"))
        return fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", arguments)])


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        payload = self.server.respond(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def terminal(home, **variables):
    """A terminal's environment: no Rui variables of its own unless given."""
    return {"PATH": CLIENT_PATH, "HOME": str(home), "RUI_FAKE": "stripped", **variables}


def run(environment, *args, expect=0, input=None):
    completed = subprocess.run([str(fixture.RUI), *map(str, args)], text=True, capture_output=True,
                            timeout=15, env=environment, input=input)
    assert completed.returncode == expect, (args, completed)
    return completed


def raw_message(socket_path, store, key, session, header, entries):
    body = json.dumps({"version": "3", "kind": "message", "store": str(store), "key": key, "session": session,
                       "sender": None, "sender_handle": None, "text": {"state": "value", "value": "show"}},
                      separators=(",", ":")).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(10)
        connection.connect(socket_path)
        # The refusal comes before the Host reads the request itself, so its
        # bytes stay unsent: unread bytes would reset the connection. The
        # declared length is never reached.
        connection.sendall(b"POST /v1/message HTTP/1.1\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 3\r\n"
                           + header + f"Content-Length: {65537 + len(body)}\r\n\r\n".encode() + entries)
        response = b""
        while part := connection.recv(65536):
            response += part
    head, reply = response.split(b"\r\n\r\n", 1)
    return int(head.split(b" ")[1]), json.loads(reply)


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-bash-environment."))
    host = endpoint = thread = None
    completed = False
    try:
        home = state / "home"
        home.mkdir()
        workspace = state / "workspace"
        workspace.mkdir()
        store = state / "store"
        endpoint = Model()
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        host, fields = start_ready_process(
            fixture.host_arguments(store, f"http://127.0.0.1:{endpoint.server_port}/responses"),
            env={"PATH": os.environ["PATH"], "HOME": str(home), "HOST_SECRET": HOST_SECRET},
            required_fields={"execution": "enabled"})
        rui_dir = str(fixture.RUI.parent)

        def configure(environment):
            reply = json.loads(run(environment, "session", "configure", "--store", store, "--workspace", workspace,
                                   "--provider", "codex", "--model", "gpt-6-sol", "--tools", "bash",
                                   "--permission-mode", "bypass").stdout)
            return reply["context"]["session"]

        def send(environment, session, text, key, expect=0):
            return run(environment, "session", "send", "--store", store, "--to", session,
                       "--record", state / f"{key}.json", "--key", key, input=text, expect=expect)

        def next_result(session, count):
            results = wait_for(lambda: endpoint.results.get(session, [])[count:] or None,
                               f"Bash result {count + 1} of {session}", timeout=20)
            return results[0]

        a = terminal(home, CLIENT_MARK="terminal-a")
        session = configure(a)
        # The Turn's first Bash already sees the sending terminal's environment,
        # led by this rui, without the Host's secret or the terminal's RUI_ names.
        send(a, session, "show", "first")
        assert next_result(session, 0) == ("terminal-a", "unset", "unset", f"{rui_dir}:{CLIENT_PATH}")
        saved = (state / "first.json").read_text()
        assert "terminal-a" not in saved and CLIENT_PATH not in saved, saved

        # A later terminal's Message switches the Session to its environment.
        b = terminal(home, CLIENT_MARK="terminal-b")
        send(b, session, "show", "second")
        assert next_result(session, 1)[0] == "terminal-b"

        # A peer's Message never displaces a person's environment, and fills a
        # Session no person has sent to with the peer's own.
        relay = configure(a)
        send(terminal(home, CLIENT_MARK="terminal-p"), relay, f"relay {session}", "relay-person")
        assert next_result(session, 2)[0] == "terminal-b"
        quiet = configure(a)
        send(terminal(home, CLIENT_MARK="terminal-p"), relay, f"relay {quiet}", "relay-quiet")
        assert next_result(quiet, 0)[0] == "terminal-p"

        # An environment over 64 KiB is refused before anything is sent, naming
        # its largest variable; the saved request recovers from a smaller one.
        large = terminal(home, CLIENT_MARK="terminal-large", LARGE_VARIABLE="x" * (64 * 1024))
        refused = send(large, session, "show", "large", expect=1)
        assert "nothing was sent" in refused.stderr and "LARGE_VARIABLE" in refused.stderr, refused.stderr
        unsent = json.loads(run(b, "request", "inspect", "--store", store, "--key", "large").stdout)
        assert unsent["observation"]["status"] == "absent", unsent
        recovered = json.loads(run(terminal(home, CLIENT_MARK="terminal-c"), "request", "recover", "--store", store,
                                   "--record", state / "large.json", "--kind", "message").stdout)
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is False, recovered
        assert next_result(session, 3)[0] == "terminal-c"
        saved = (state / "large.json").read_text()
        assert "terminal-" not in saved and "xxxxxxxx" not in saved, saved

        # The Host refuses a Message without a valid environment before
        # admission: nothing is saved under its key.
        socket_path = fields["socket"]
        for key, header, entries, status, code in (
            ("raw-missing", b"", b"", 400, "environment_required"),
            # Refused from its header alone, before any entry is read.
            ("raw-large", b"X-Rui-Environment-Bytes: 65537\r\n", b"", 413, "environment_too_large"),
            ("raw-malformed", b"X-Rui-Environment-Bytes: 3\r\n", b"A=1", 400, "invalid_environment"),
            ("raw-repeated", b"X-Rui-Environment-Bytes: 8\r\n", b"A=1\0A=2\0", 400, "invalid_environment"),
        ):
            answered, reply = raw_message(socket_path, fields["store"], key, session, header, entries)
            assert (answered, reply["code"]) == (status, code), (key, answered, reply)
            absent = json.loads(run(b, "request", "inspect", "--store", store, "--key", key).stdout)
            assert absent["observation"]["status"] == "absent", absent
        # Every Bash call ran; no refused Message reached the model.
        assert len(endpoint.results[session]) == 4, endpoint.results
        completed = True
        print("bash environment passed: first Bash, later terminal, peer rank and fill, size refusal and recovery, Host refusals", flush=True)
    finally:
        incoming = sys.exc_info()[1]
        cleanups = []
        if host is not None:
            cleanups.append(lambda: stop_process(host))
        if endpoint is not None:
            cleanups.extend((endpoint.shutdown, endpoint.server_close))
        if thread is not None:
            cleanups.append(lambda: thread.join(timeout=5))
        dispose_all(*cleanups)
        if completed and incoming is None:
            shutil.rmtree(state)
        else:
            retain_failure_state("Bash environment failure state", state)


if __name__ == "__main__":
    host_process.enter()
    main()
