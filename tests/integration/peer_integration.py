#!/usr/bin/env python3
"""Peer round trip through ordinary Rui-launched Bash.

A real Host runs from a nondefault installation with unrelated secrets in its
environment. Session A's Bash call configures Session B and sends B a Message;
the Host resolves A as its sender from the Action handle it gave A's Bash. A also
includes its own address and explicit report-back instructions in B's task. B
checks that parent address against the Message's recorded sender. A's
send returns after admission and A finishes its Turn while B's own Bash call
is held. B's Bash then replies to the recorded sender, which A receives as a
peer Message from B. The generated capture recovers the original send with
its saved sender, outside any Bash, with no login or idle peer process. A
receives the saved incoming report without polling requests, reading results
or reading B's Conversation. The fixture observer takes one diagnostic request
snapshot while B is deliberately silent; it never drives A's normal flow.
This scripted provider proves workflow and wording, not future model compliance.
"""
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time

import model_fixture as fixture
import host_process
from host_process import TestHTTPServer, canonical_fixture_root, dispose_all, retain_failure_state, start_ready_process, stop_process, wait_for
import os_semantics

SESSION_ID = re.compile("[0123456789abcdefghjkmnpqrstvwxyz]{6}")
SECRETS = {"RUI_PEER_SECRET": "host-only-secret", "OPENAI_API_KEY": "sk-host-only"}
REPORT = 'from peer/b: 42\nLiteral `touch backtick-evaluated` and $(touch substitution-evaluated); \'single\' "double" \\ 雪\nEOF\n'


def address_of(request):
    session = fixture.instructions_session(request["instructions"])
    assert SESSION_ID.fullmatch(session), session
    return session


PEER_PARTS = (pathlib.Path(__file__).resolve().parents[2] / "src" / "peer_message.txt").read_text().split("{}")
# Labels A gives itself and the B it starts, from its own Bash.
A_LABEL = "Lead: arithmetic check"
B_LABEL = "Worker: multiply"


def model_instructions(workspace, session):
    prefix, address, suffix = (pathlib.Path(__file__).resolve().parents[2] / "src" / "model_instructions.txt").read_text().split("{}")
    return prefix + json.dumps(str(workspace), ensure_ascii=False)[1:-1] + address + session + suffix


def last_user(request):
    return next(item["content"] for item in reversed(request["input"]) if item.get("role") == "user")


def last_user_text(request):
    return last_user(request)[-1]["text"]


def sender_of(request):
    """The recorded sender of the last User Message, or None for a human's."""
    content = last_user(request)
    if len(content) == 1:
        return None
    prefix, suffix = PEER_PARTS
    assert len(content) == 2 and content[0]["text"].startswith(prefix), content
    sender = content[0]["text"][len(prefix):len(prefix) + 6]
    assert SESSION_ID.fullmatch(sender), sender
    assert content[0]["text"] == prefix + sender + suffix, content
    return sender


def tool_outputs(request):
    return [item["output"] for item in request["input"] if item.get("type") == "function_call_output"]


def bash_call(name, command, stdin=None):
    arguments = {"cmd": command, "stdin": stdin, "timeout_ms": 20000, "description": f"Run {name} peer command"}
    return fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", json.dumps(arguments, separators=(",", ":")))])


def answer(name, text):
    return fixture.sse_answer(f"{name}-answer", f"{name}-reasoning", f"{name}-message", text)[0]


class PeerModel(TestHTTPServer):
    """Plays both models from request context. The foreign destination is an
    explicit negative control, not a supported peer route."""

    def __init__(self, workspace, report_source, foreign_store, foreign_session):
        super().__init__(("127.0.0.1", 0), PeerHandler)
        self.workspace = workspace
        self.report_source = report_source
        self.foreign_store = foreign_store
        self.foreign_session = foreign_session
        self.a = self.b = None
        self.requests = []
        self.lock = threading.Lock()
        self.defaults_restored = threading.Event()
        self.b_received = threading.Event()
        self.a_continued = threading.Event()
        self.a_reply_received = threading.Event()

    def respond(self, request):
        address = address_of(request)
        outputs = tool_outputs(request)
        text = last_user_text(request)
        if address != self.a:
            self.b = address
            if text.startswith("self report"):
                assert sender_of(request) == address, request
                return answer("b-self", "plain reply stays local")
            if outputs:
                return answer("b-done", "plain reply stays local")
            self.b_received.set()
            reply_to = text.splitlines()[1].removeprefix("Parent ID: ")
            assert reply_to == sender_of(request), request
            # Self-send is legitimate for explicit and generated captures,
            # using only the allocated ID. Neither probe consumes the literal
            # report on this Bash call's stdin.
            send = f"rui session send --to {reply_to} "
            report = (send + "> b-reply.json 2> b-reply.err"
                      if self.report_source == "stdin" else
                      "cat > b-report.txt; " +
                      send + "< b-report.txt > b-reply.json 2> b-reply.err")
            return bash_call("b-reply", (
                'printf "%s\\n" "$HOME"/.config/rui/requests/* > b-captures-before; '
                f'printf %s "self report explicit" | rui session send --store "$RUI_STORE/." --to {address} '
                f"--record {shlex.quote(str(self.workspace.parent / 'b-self.json'))} --key self-send > b-self.out 2> b-self.err; "
                "echo $? > b-self.status; "
                f"printf %s 'self report generated' | rui session send --to {address} "
                "> b-self-generated.out 2> b-self-generated.err; "
                "echo $? > b-self-generated.status; "
                'printf "%s\\n" "$HOME"/.config/rui/requests/* > b-captures-after; '
                "i=0; while [ ! -e b-release ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done; [ -e b-release ] || exit 124; "
                + report
            ), stdin=REPORT)
        if text.startswith("from peer/b: "):
            self.a_reply_received.set()
            return answer("a-final", "peer said 42")
        if outputs:
            self.a_continued.set()
            return answer("a-wait", "waiting for peer/b")
        assert self.defaults_restored.wait(20), "conflicting HOME preference was not restored"
        message = ("Please compute 6*7.\n"
                   f"Parent ID: {address}\n"
                   "When done, send findings back to this parent with rui session send.")
        return bash_call("a-ask", (
            "env | sed '/^RUI_SENDER_HANDLE=/d' > a-env.txt; command -v rui > a-which.txt; "
            f"rui session send --store {shlex.quote(str(self.foreign_store))} --to {self.foreign_session} "
            f"--record {shlex.quote(str(self.workspace.parent / 'conflicting-store.json'))} --key conflicting-store "
            "> conflicting-store.out 2> conflicting-store.err; "
            "[ $? -eq 1 ] || exit 91; "
            f"printf %s 'must not arrive' | RUI_STORE={shlex.quote(str(self.foreign_store))} rui session send --to {self.foreign_session} "
            f"--record {shlex.quote(str(self.workspace.parent / 'foreign-send.json'))} --key foreign-send > foreign-send.out 2> foreign-send.err; "
            "[ $? -eq 1 ] || exit 90; "
            f'rui session configure --store "$RUI_STORE" --session "$RUI_ADDRESS" --label {shlex.quote(A_LABEL)} '
            "> a-label.out 2> a-label.err || exit 89; "
            f"rui session start --workspace {shlex.quote(str(self.workspace))} --label {shlex.quote(B_LABEL)} "
            "--provider codex --model gpt-6-sol --tools bash --permission-mode bypass > b-start.id 2> b-send.err; "
            "status=$?; cat b-start.id; exit $status"
        ), stdin=message)


class PeerHandler(fixture.http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(body)
        with self.server.lock:
            self.server.requests.append(request)
        payload = self.server.respond(request)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Request-Id", f"peer-{len(self.server.requests)}")
        self.send_header("OpenAI-Model", "model-a-served")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def run(installed, *args, home, expect=0, input=None):
    completed = subprocess.run([str(installed), *map(str, args)], text=True, capture_output=True, timeout=15,
                               env={"PATH": os.environ["PATH"], "HOME": str(home)}, input=input)
    assert completed.returncode == expect, (args, completed)
    return json.loads(completed.stdout)


def allocated(response):
    session = response["context"]["session"]
    assert response["answer"]["status"] == "accepted", response
    assert SESSION_ID.fullmatch(session) and response["answer"]["session"] == session, response
    return session


def main(report_source):
    # Rui reports resolved paths (its executable's directory on PATH, the
    # canonical Store); macOS temporary roots are symlinks under /private.
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-peer."))
    host = foreign_host = endpoint = thread = workspace = None
    try:
        installed = state / "opt rui" / "bin" / "rui"
        installed.parent.mkdir(parents=True)
        shutil.copy2(fixture.RUI, installed)
        home = state / "home"
        home.mkdir()
        workspace = state / "workspace"
        workspace.mkdir()
        store = state / "store-雪"
        canonical_store = os.path.realpath(store)
        # The peer's omitted destination Store must beat unrelated HOME defaults.
        unrelated_store = state / "not-the-sending-store"
        unrelated_store.mkdir(mode=0o700)
        run(installed, "defaults", "configure", "--store", unrelated_store, home=home)
        saved_defaults = (home / ".config" / "rui" / "preferences").read_bytes()
        # Invalid addresses reject before content reads or capture publication.
        refused_record = state / "invalid-address.json"
        for address in ('', 'peer/b', 'rui/k7m2qx', '/store/k7m2qx', 'store:k7m2qx', 'K7M2QX', 'k7m2qi', 'k7m2ql', 'k7m2qo',
                        'k7m2qu', 'k7m2q', 'k7m2qxx', '6b376d327178', ' k7m2qx', 'k7m2qx\n',
                        '{}', '{"session":""}', '{"session":"x","store":null}',
                        '{"session":"x","session":"y"}', '{"session_hex":"78"}',
                        '{"session":"x","store_hex":"2f73746f7265"}',
                        '{"session":"peer/nul\\u0000雪"}',
                        '{"session":"x","store":"/bad\\u0000path"}'):
            refused = subprocess.run([str(installed), "session", "send", "--to", address,
                "--record", str(refused_record), "--key", "invalid"],
                env={"PATH": os.environ["PATH"], "HOME": str(home)}, capture_output=True, timeout=10)
            assert refused.returncode == 1 and b"six lowercase Crockford" in refused.stderr, refused
            assert refused.stdout == b"" and not refused_record.exists(), refused
        for old_flag in ("--session", "--session-hex"):
            refused = subprocess.run([str(installed), "session", "send", "--to", "k7m2qx", old_flag, "obsolete",
                "--record", str(refused_record), "--key", "invalid"],
                env={"PATH": os.environ["PATH"], "HOME": str(home)}, capture_output=True, timeout=10)
            assert refused.returncode == 1 and b"UnknownArgument" in refused.stderr, refused
            assert refused.stdout == b"" and not refused_record.exists(), refused
        foreign_store = state / "foreign-store"
        foreign_host, _ = start_ready_process([installed, "host", "serve", "--store", foreign_store],
            env={"PATH": os.environ["PATH"], "HOME": str(home)}, required_fields={"execution": "unavailable"})
        foreign_session = allocated(run(installed, "session", "configure", "--store", foreign_store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol", home=home))
        external_session = allocated(run(installed, "session", "configure", "--store", foreign_store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol", home=home))
        foreign_listing = run(installed, "session", "list", "--store", foreign_store, "--all", home=home)
        # Old caller names and noncanonical IDs fail at capture. The removed
        # hex flag must not revive NUL-bearing arbitrary references either.
        invalid_selectors = [("--session", value, b"InvalidSession") for value in
                             ('peer/a "quoted" \\ 雪', 'ABC123', 'k7m2qi', 'rui/k7m2qx')]
        invalid_selectors.append(("--session-hex", 'peer/nul\x00雪'.encode().hex(), b"UnknownArgument"))
        for flag, invalid, diagnostic in invalid_selectors:
            rejected = subprocess.run([str(installed), "session", "configure", "--store", str(foreign_store),
                flag, invalid, "--workspace", str(workspace),
                "--provider", "codex", "--model", "gpt-6-sol", "--record", str(refused_record), "--key", "invalid-config"],
                env={"PATH": os.environ["PATH"], "HOME": str(home)}, capture_output=True, timeout=15)
            assert rejected.returncode == 1 and diagnostic in rejected.stderr, rejected
            assert rejected.stdout == b"" and not refused_record.exists(), rejected
            assert run(installed, "session", "list", "--store", foreign_store, "--all", home=home) == foreign_listing
        # An anonymous explicit Store beats conflicting HOME defaults without
        # manufacturing peer identity. Human saved-default sends are exercised
        # separately by A's initial submission below.
        external = run(installed, "session", "send", "--store", foreign_store, "--to", external_session,
            input="genuine external send", home=home)
        assert external["answer"]["status"] == "accepted" and external["context"]["session"] == external_session, external
        assert external["context"]["store"] == str(foreign_store), external
        external_capture = json.loads((home / ".config" / "rui" / "requests" / f'{external["context"]["key"]}.json').read_text())
        assert external_capture["sender"] is None and external_capture["sender_handle"] is None, external_capture
        assert (home / ".config" / "rui" / "preferences").read_bytes() == saved_defaults
        endpoint = PeerModel(workspace, report_source, foreign_store, foreign_session)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        host_env = {"PATH": os.environ["PATH"], "HOME": str(home), **SECRETS}
        host, _ = start_ready_process(
            [installed, "host", "serve", "--store", store, "--active-capacity", "2", "--provider-endpoint", url],
            env=host_env, required_fields={"execution": "enabled"},
        )
        instance = run(installed, "host", "status", "--store", store, home=home)["instance"]
        session_a = allocated(run(installed, "session", "configure", "--store", store, "--workspace", workspace,
            "--provider", "codex", "--model", "gpt-6-sol", "--tools", "bash", "--permission-mode", "bypass", home=home))
        endpoint.a = session_a
        # Human admission uses saved HOME defaults; peers must use their own
        # RUI_STORE once the deliberately conflicting preference is restored.
        run(installed, "defaults", "configure", "--store", store, home=home)
        ask = subprocess.run([str(installed), "session", "send", "--to", session_a], input="Ask peer/b for 6*7.",
                             text=True, capture_output=True, timeout=15, env={"PATH": os.environ["PATH"], "HOME": str(home)})
        assert ask.returncode == 0, ask
        ask_key = json.loads(ask.stdout)["context"]["key"]
        run(installed, "defaults", "configure", "--store", unrelated_store, home=home)
        endpoint.defaults_restored.set()

        # B's Bash call is held, yet A's Bash send already returned B's
        # admission receipt and A finished its Turn with it. These Session
        # snapshots synchronize the fixture observer, not A's model or Bash.
        assert endpoint.b_received.wait(20), "B never received the peer Message"
        session_b = endpoint.b
        assert session_b != session_a and SESSION_ID.fullmatch(session_b), session_b
        wait_for(lambda: (workspace / "b-captures-after").exists(), "B's self-send admissions", timeout=20)
        self_sends = []
        for name in ("b-self", "b-self-generated"):
            assert (workspace / f"{name}.status").read_text() == "0\n", name
            admitted = json.loads((workspace / f"{name}.out").read_text())
            assert admitted["answer"]["status"] == "accepted" and admitted["context"]["session"] == session_b, admitted
            self_sends.append(admitted["context"]["key"])
        own_sender = {"store": canonical_store, "session": session_b}
        assert json.loads((state / "b-self.json").read_text())["sender"] == own_sender
        before = set((workspace / "b-captures-before").read_text().splitlines())
        after = set((workspace / "b-captures-after").read_text().splitlines())
        assert len(after - before) == 1, (before, after)
        generated_self_record = pathlib.Path(next(iter(after - before)))
        assert json.loads(generated_self_record.read_text())["sender"] == own_sender
        wait_for(lambda: run(installed, "session", "inspect", "--store", store, "--session", session_a, home=home)["work"]["state"]["kind"] == "finished", "A's first Turn while B is held", timeout=20)
        assert endpoint.a_continued.is_set() and not (workspace / "b-reply.json").exists()
        b_held = run(installed, "session", "inspect", "--store", store, "--session", session_b, home=home)
        assert b_held["work"]["state"]["kind"] != "finished", b_held
        settled = run(installed, "session", "inspect", "--store", store, "--session", session_a, "--profile", "full", home=home)["full"]["actions"][0]
        assert settled["resolution"] == "succeeded" and settled["result"]["text"].startswith("Bash succeeded. Exit code: 0.\n"), settled
        assert (workspace / "conflicting-store.out").read_bytes() == b""
        conflict_diagnostic = (workspace / "conflicting-store.err").read_text()
        assert "CrossStorePeerSend" in conflict_diagnostic and "nothing was sent" in conflict_diagnostic, conflict_diagnostic
        assert "nonexistent" not in conflict_diagnostic, conflict_diagnostic
        assert not (state / "conflicting-store.json").exists(), "conflicting override published a capture"
        assert not (state / ".conflicting-store.json.capture.lock").exists(), "conflicting override opened a capture"
        foreign = json.loads((workspace / "foreign-send.out").read_text())
        assert foreign["answer"]["status"] == "rejected" and foreign["answer"]["code"] == "invalid_sender_handle", foreign
        replay = run(installed, "request", "recover", "--store", foreign_store, "--record", state / "foreign-send.json", "--kind", "message", home=home, expect=1)
        assert replay["answer"]["code"] == "invalid_sender_handle" and replay["answer"]["replayed"] is True, replay
        undelivered = run(installed, "session", "inspect", "--store", foreign_store, "--session", foreign_session, home=home)
        assert undelivered["pending_messages"] == "0" and undelivered["recent_messages"] == [], undelivered
        assert (workspace / "b-start.id").read_text() == session_b + "\n"
        announcement = (workspace / "b-send.err").read_text()
        handle = re.fullmatch(r"request: (\S+) \(inspect: rui request inspect \1; if unconfirmed: rui request recover \1\)\n", announcement)
        assert handle, announcement
        handle = handle.group(1)
        receipt = run(installed, "request", "recover", handle, home=home)
        assert receipt["answer"]["status"] == "accepted" and receipt["context"]["session"] == session_b, receipt
        assert receipt["answer"]["replayed"] is True, receipt

        a_requests = [request for request in endpoint.requests if address_of(request) == session_a]
        assert all(address_of(request) == session_a for request in a_requests)
        assert a_requests[0]["instructions"] == model_instructions(workspace, session_a)
        b_first = next(request for request in endpoint.requests if address_of(request) == session_b)
        assert address_of(b_first) == session_b
        # The explicit task ID agrees with the separate Host-recorded sender.
        assert sender_of(b_first) == session_a
        task = last_user_text(b_first).splitlines()
        assert task[0] == "Please compute 6*7."
        assert task[1] == f"Parent ID: {session_a}"
        assert task[2] == "When done, send findings back to this parent with rui session send."
        assert sender_of(a_requests[0]) is None

        # Exception only: B has deliberately gone silent while A is waiting.
        # One public diagnostic snapshot, never a polling or report-read path.
        silent = run(installed, "request", "inspect", handle, home=home)
        assert silent["key"] == receipt["context"]["key"], silent
        assert silent["observation"]["target"] == session_b, silent
        assert silent["observation"].get("result", {}).get("status") != "completed", silent

        # Audit the controlled environment without recording the private Action
        # handle: this installation first on PATH, HOME, and the exact address.
        environment = dict(line.split("=", 1) for line in (workspace / "a-env.txt").read_text().splitlines() if "=" in line)
        assert environment["PATH"].split(":")[0] == str(installed.parent), environment
        assert environment["HOME"] == str(home), environment
        assert environment["RUI_ADDRESS"] == session_a and environment["RUI_STORE"] == canonical_store, environment
        assert set(environment) <= {"PATH", "HOME", "RUI_ADDRESS", "RUI_STORE", "PWD", "OLDPWD", "SHLVL", "_"}, environment
        assert not any(secret in (workspace / "a-env.txt").read_text() for secret in SECRETS.values())
        assert (workspace / "a-which.txt").read_text() == f"{installed.parent}/rui\n"

        # The original capture saved A as sender. Recovery outside any Bash,
        # without RUI_ADDRESS, replays that same Message without a duplicate.
        saved_sender = json.loads((home / ".config" / "rui" / "requests" / f"{handle}.json").read_text())["sender"]
        assert saved_sender == {"store": canonical_store, "session": session_a}, saved_sender
        recovered = run(installed, "request", "recover", handle, home=home)
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True, recovered
        assert recovered["context"]["key"] == receipt["context"]["key"], recovered

        (workspace / "b-release").write_text("")
        assert endpoint.a_reply_received.wait(20), "A never received B's reply"
        a_continuation = next(request for request in endpoint.requests if address_of(request) == session_a and tool_outputs(request))
        assert tool_outputs(a_continuation) == [settled["result"]["text"]], a_continuation
        reply = json.loads((workspace / "b-reply.json").read_text())
        assert reply["answer"]["status"] == "accepted" and reply["context"]["session"] == session_a, reply
        domain = b"rui/content/v1"
        assert reply["input"] == {"type": "text", "bytes": str(len(REPORT.encode())),
                                  "sha256": hashlib.sha256(len(domain).to_bytes(8, "big") + domain + REPORT.encode()).hexdigest()}, reply
        a_final = wait_for(lambda: (lambda value: value if value["work"]["state"]["kind"] == "finished" and value["pending_messages"] == "0" else None)(
            run(installed, "session", "inspect", "--store", store, "--session", session_a, home=home)), "A's reply Turn", timeout=20)
        a_reply_request = [request for request in endpoint.requests if address_of(request) == session_a][-1]
        assert last_user_text(a_reply_request).encode() == REPORT.encode() and a_final
        assert not (workspace / "backtick-evaluated").exists(), "report backticks ran a command"
        assert not (workspace / "substitution-evaluated").exists(), "report $() ran a command"
        if report_source == "file":
            assert (workspace / "b-report.txt").read_bytes() == REPORT.encode()
        assert sender_of(a_reply_request) == session_b
        assert [row["message"] for row in a_final["recent_messages"]] == [reply["context"]["key"], ask_key], a_final
        assert a_final["recent_messages"][0]["outcome"] == "completed", a_final
        # A has only its initial configure/send Action: no request inspection,
        # read-result, peer Conversation read or resident Bash waiter.
        a_actions = run(installed, "session", "inspect", "--store", store, "--session", session_a,
                        "--profile", "full", home=home)["full"]["actions"]
        assert len(a_actions) == 1 and a_actions[0]["resolution"] == "succeeded", a_actions
        a_requests = [request for request in endpoint.requests if address_of(request) == session_a]
        assert len(a_requests) == 3, a_requests
        # Recovery adds no admission; only the task and two explicit self-sends
        # appear in B. Plain answers are saved results, not implicit Messages.
        b_final = wait_for(lambda: (lambda value: value if value["work"]["state"]["kind"] == "finished" and value["pending_messages"] == "0" else None)(
            run(installed, "session", "inspect", "--store", store, "--session", session_b, home=home)), "B's Turn", timeout=20)
        assert {row["message"] for row in b_final["recent_messages"]} == {receipt["context"]["key"], *self_sends}, b_final
        for record, key in zip((state / "b-self.json", generated_self_record), self_sends):
            replay = run(installed, "request", "recover", "--store", store, "--record", record, "--kind", "message", home=home)
            assert replay["answer"]["status"] == "accepted" and replay["answer"]["replayed"] is True, replay
            assert replay["context"]["key"] == key and replay["context"]["session"] == session_b, replay
        b_after = run(installed, "session", "inspect", "--store", store, "--session", session_b, home=home)
        assert {row["message"] for row in b_after["recent_messages"]} == {receipt["context"]["key"], *self_sends}, b_after
        for key in (receipt["context"]["key"], *self_sends):
            local = subprocess.run([str(installed), "request", "read-result", "--store", str(store), "--key", key],
                                   text=True, capture_output=True, timeout=15, env={"PATH": os.environ["PATH"], "HOME": str(home)})
            assert local.returncode == 0 and local.stdout == "plain reply stays local", local
        a_after = run(installed, "session", "inspect", "--store", store, "--session", session_a, home=home)
        assert [row["message"] for row in a_after["recent_messages"]] == [reply["context"]["key"], ask_key], a_after
        assert "plain reply stays local" not in json.dumps(a_reply_request), a_reply_request
        b_requests = [request for request in endpoint.requests if address_of(request) == session_b]
        assert sum(bool(tool_outputs(request)) for request in b_requests) == 1, b_requests
        # A labelled itself and the B it started. Listing shows both Labels,
        # names A as B's starter and a person or script as A's; a Label is
        # display text, so it never reaches B's model input.
        rows = {row["reference"]: row for row in run(installed, "session", "list", "--store", store, "--all", home=home)["sessions"]}
        assert (rows[session_a]["label"], rows[session_b]["label"]) == (A_LABEL, B_LABEL), rows
        assert rows[session_b]["first_message"]["sender"] == {"session": session_a}, rows[session_b]
        assert rows[session_a]["first_message"]["sender"] is None, rows[session_a]
        assert rows[session_a]["peers"]["from_person_at"] is not None, rows[session_a]
        assert rows[session_b]["peers"]["from_person_at"] is None, rows[session_b]
        assert B_LABEL not in json.dumps(b_requests), b_requests
        assert all(request["instructions"] == model_instructions(workspace, session_b) for request in b_requests)
        assert run(installed, "host", "status", "--store", store, home=home)["instance"] == instance
        # The census's own controls: a process named rui running another image
        # is not owned, and an extra owned copy is whatever it is called.
        (state / "leak-home").mkdir()
        controls = []
        try:
            controls.append(subprocess.Popen(["rui", "60"], executable="/bin/sleep"))
            controls.append(subprocess.Popen(["renamed-copy", "host", "serve", "--store", str(state / "leak-store")],
                executable=installed, env={"PATH": os.environ["PATH"], "HOME": str(state / "leak-home")},
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            observed = os_semantics.processes_executing(installed)
            assert controls[0].pid not in observed and controls[1].pid in observed, (controls[1].pid, observed)
        finally:
            dispose_all(*(lambda process=process: stop_process(process) for process in controls))
        # Peers left nothing running beside the Host, and nobody signed in or
        # changed the deliberately conflicting saved defaults.
        running = os_semantics.processes_executing(installed)
        assert running == {host.pid, foreign_host.pid}, running
        assert list(unrelated_store.iterdir()) == [], "peer followed HOME preferences instead of its sender Store"
        assert (home / ".config" / "rui" / "preferences").read_bytes() == saved_defaults
        assert sorted(path.name for path in (home / ".config" / "rui").iterdir()) == [".preferences.lock", "preferences", "requests"]
        print(f"peer round trip passed ({report_source}): explicit/generated self-send admitted with recorded sender; "
              "anonymous explicit Store beat conflicting HOME defaults; peer canonical Store alias accepted; "
              "conflicting peer override refused before content/capture without recipient admission; "
              "plain answers stored as local results without implicit delivery; "
              "foreign-Store peer rejected by Host and replayed without delivery; omitted Store beat conflicting HOME defaults; "
              "literal backticks and $() reached the parent byte-exact without shell evaluation; "
              "installed Bash rui configured B and sent with a durable receipt, "
              "A included its own parent address and explicit report-back instructions, "
              "B explicitly sent findings and A received the saved incoming report without request polling, result or peer Conversation reads, "
              "one silent-peer diagnostic inspection, Host-recorded senders both ways, "
              "original capture recovered its saved sender without duplicate, A finished while B was held, "
              "no idle peer or login, controlled PATH/HOME; scripted provider, not a model-compliance guarantee")
    except BaseException:
        retain_failure_state("peer integration failure state", state)
        state = None
        raise
    finally:
        disposals = []
        if workspace is not None and workspace.exists():
            disposals.append(lambda: (workspace / "b-release").touch())
        if host is not None:
            disposals.append(lambda: stop_process(host))
        if foreign_host is not None:
            disposals.append(lambda: stop_process(foreign_host))
        if endpoint is not None:
            disposals.append(endpoint.defaults_restored.set)
            disposals.extend((endpoint.shutdown, endpoint.server_close))
        if state is not None:
            disposals.append(lambda: shutil.rmtree(state))
        dispose_all(*disposals)


class CohortModel(TestHTTPServer):
    """Ten concurrent allocations, each started and reporting through Bash."""

    def __init__(self, workspace):
        super().__init__(("127.0.0.1", 0), PeerHandler)
        self.workspace = workspace
        self.parent = None
        self.requests = []
        self.lock = threading.Lock()
        self.reports = {}

    def respond(self, request):
        session = address_of(request)
        assert request["instructions"] == model_instructions(self.workspace, session), request
        if session != self.parent:
            assert sender_of(request) == self.parent, request
            assert last_user_text(request) == f"Report to parent ID {self.parent}", request
            if tool_outputs(request):
                assert all(output.startswith("Bash succeeded. Exit code: 0.\n") for output in tool_outputs(request)), request
                return answer(session, f"peer original result {session}")
            return bash_call(session, (
                "n=0; while [ ! -e cohort-report-release ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done; "
                "[ -e cohort-report-release ] || exit 124; "
                f"printf %s 'report from {session}' | rui session send --to {self.parent} --record {shlex.quote(str(self.workspace.parent / f'{session}-report.json'))} "
                f"--key report-{session} > {session}-report.out 2> {session}-report.err"
            ))
        for item in request["input"]:
            if item.get("role") == "user" and len(item["content"]) == 2:
                sender = sender_of({"input": [item]})
                text = item["content"][-1]["text"]
                assert text == f"report from {sender}", item
                with self.lock:
                    self.reports[sender] = text
        if last_user_text(request).startswith("report from "):
            return answer("parent-reports", "parent received reports")
        if tool_outputs(request):
            assert all(output.startswith("Bash succeeded. Exit code: 0.\n") for output in tool_outputs(request)), request
            return answer("parent-started", "parent original result")
        assert sender_of(request) is None, request
        # Start all configurators before any allocation is allowed. Each
        # child then uses only its allocated bare ID to start its own peer.
        return bash_call("cohort-start", (
            "pids=''; for i in 0 1 2 3 4 5 6 7 8 9; do ( "
            "n=0; while [ ! -e cohort-create ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done; "
            "[ -e cohort-create ] || exit 124; "
            f"printf %s 'Report to parent ID {self.parent}' | rui session start --workspace {shlex.quote(str(self.workspace))} "
            "--provider codex --model gpt-6-sol --tools bash --permission-mode bypass "
            f'--record {shlex.quote(str(self.workspace.parent))}/cohort-$i.json --key cohort-$i '
            '> "cohort-$i-start.id" 2> "cohort-$i-start.err" '
            ') & pids="$pids $!"; done; touch cohort-create; '
            'status=0; for pid in $pids; do wait "$pid" || status=1; done; exit "$status"'
        ))


def stdin_start_contract():
    """Real CLI capture, concurrent replay and cancellation without a provider."""
    from concurrent.futures import ThreadPoolExecutor
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-stdin-start."))
    host = None
    try:
        home = state / "home"
        home.mkdir()
        store = state / "store"
        environment = {"PATH": os.environ["PATH"], "HOME": str(home)}

        def invoke(*args, input=b"", extra=None, **kwargs):
            return subprocess.run([str(fixture.RUI), *map(str, args)],
                env={**environment, **(extra or {})}, capture_output=True, timeout=15,
                **({"input": input} if "stdin" not in kwargs else {}), **kwargs)

        def failed(result, stage, cause):
            assert result.returncode == 1 and result.stdout == b"", result
            assert f"failure during {stage};".encode() in result.stderr and cause in result.stderr, result
            assert b"no Host serving" not in result.stderr, result

        failed(invoke("session", "start", "--store", state / "absent", input=b"first"), "store", b"FileNotFound")
        host = fixture.start_host(store, None)
        # File-valued and literal forms have no compatibility route.
        for args in (("send", "--to", "k7m2qx", "--text", "input"),
                     ("send", "--to", "k7m2qx", "literal"),
                     ("configure", "--instructions", "input"),
                     ("start", "--instructions", "-")):
            result = invoke("session", *args, "--store", store)
            assert result.returncode == 1 and result.stdout == b"" and b"request:" not in result.stderr, result
        for data, cause in ((b"", b"Nothing was sent"), (b"bad\xff", b"InvalidUtf8")):
            record = state / "invalid.json"
            result = invoke("session", "start", "--store", store, "--record", record, "--key", "invalid", input=data)
            failed(result, "input_parse", cause)
            assert not record.exists(), result
        directory = os.open(state, os.O_RDONLY)
        try:
            failed(invoke("session", "start", "--store", store, stdin=directory), "stdin_read", b"error:")
        finally:
            os.close(directory)
        failed(invoke("session", "configure", "--store", store,
            "--output-schema", state / "missing-schema"), "input_file_read", b"FileNotFound")
        for peer in ({"RUI_ADDRESS": "k7m2qx"}, {"RUI_STORE": str(store)},
                     {"RUI_ADDRESS": "broken", "RUI_STORE": str(store), "RUI_SENDER_HANDLE": "x"}):
            rejected = invoke("session", "start", "--store", store, extra=peer, input=b"must not run")
            assert rejected.returncode == 1 and b"InvalidRuiAddress" in rejected.stderr and b"request:" not in rejected.stderr, rejected
        assert fixture.command("session", "list", "--store", store, "--all")["sessions"] == []

        text = "initial\x00雪\n`literal` $(data)\r\n\n".encode()
        record = state / "start.json"
        lost = invoke("session", "start", "--store", store, "--record", record, "--key", "first",
            "--workspace", state, "--test-drop-reply", "after-commit", input=text)
        failed(lost, "admission_response", b"admission outcome is unconfirmed")
        saved = record.read_bytes()
        capture = json.loads(saved)
        assert capture["session"] == "" and capture["kind"] == "message", capture
        assert capture["text"]["value"].encode() == text and capture["configuration"]["workspace"]["value"] == str(state), capture
        with ThreadPoolExecutor(max_workers=4) as pool:
            replays = list(pool.map(lambda _: fixture.command("request", "recover", "--store", store,
                "--record", record, "--kind", "message"), range(4)))
        assert all(value == replays[0] for value in replays), replays
        receipt = replays[0]
        session = receipt["context"]["session"]
        assert SESSION_ID.fullmatch(session) and receipt["answer"]["replayed"] is True, receipt
        assert receipt["answer"]["admission"] == "1", receipt
        domain = b"rui/content/v1"
        assert receipt["input"] == {"type": "text", "bytes": str(len(text)),
            "sha256": hashlib.sha256(len(domain).to_bytes(8, "big") + domain + text).hexdigest()}, receipt
        observed = fixture.observe(store, "first")
        assert observed["target"] == session and "result" not in observed and observed["queue"]["status"] == "queued", observed
        listing = fixture.command("session", "list", "--store", store, "--all")["sessions"]
        assert [row["reference"] for row in listing] == [session], listing
        snapshot = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert snapshot["pending_messages"] == "1", snapshot
        instructions = "rules\x00é\n\n"
        configured = fixture.command("session", "configure", "--store", store, "--session", session,
            "--record", state / "instructions.json", "--key", "instructions", "--instructions", "-", input=instructions)
        assert configured["answer"]["status"] == "accepted", configured
        assert json.loads((state / "instructions.json").read_bytes())["configuration"]["instructions"]["value"] == instructions
        stopped = fixture.command("session", "stop", "--store", store, "--session", session)
        assert stopped["answer"]["status"] == "accepted", stopped
        assert fixture.observe(store, "first")["result"] == {"status": "cancelled", "code": "session_stopped"}
        socket = pathlib.Path(host.rui_ready_fields["socket"])
        fixture.stop_host(host)
        host = None
        assert socket.is_socket(), socket
        failed(invoke("session", "send", "--store", store, "--to", session, input=b"offline"), "connect", b"ConnectionRefused")
        socket.unlink()
        failed(invoke("session", "send", "--store", store, "--to", session, input=b"offline"), "connect", b"FileNotFound")
        offline_record = state / "offline-start.json"
        failed(invoke("session", "start", "--store", store, "--record", offline_record, "--key", "offline-start",
            input=b"admit once after reconnect"), "connect", b"FileNotFound")
        host = fixture.start_host(store, None)
        assert fixture.command("request", "recover", "--store", store, "--record", record, "--kind", "message") == receipt
        assert record.read_bytes() == saved
        assert fixture.observe(store, "first")["result"]["status"] == "cancelled"
        assert fixture.command("session", "inspect", "--store", store, "--session", session)["pending_messages"] == "0"
        with ThreadPoolExecutor(max_workers=4) as pool:
            first_admissions = list(pool.map(lambda _: fixture.command("request", "recover", "--store", store,
                "--record", offline_record, "--kind", "message"), range(4)))
        assert sum(not value["answer"]["replayed"] for value in first_admissions) == 1, first_admissions
        destinations = {value["context"]["session"] for value in first_admissions}
        assert len(destinations) == 1 and session not in destinations, first_admissions
        second = destinations.pop()
        assert [row["reference"] for row in fixture.command("session", "list", "--store", store, "--all")["sessions"]] == [session, second]
        assert fixture.command("session", "inspect", "--store", store, "--session", second)["pending_messages"] == "1"
        print("stdin/start: exact NUL/UTF-8/newline bytes, lost admission, four concurrent original replays, one allocated Session, "
              "queued-not-completed receipt, cancellation/reopen, stdin-only grammar and precise read/parse/store/connect errors passed")
    except BaseException:
        retain_failure_state("stdin/start failure state", state)
        state = None
        raise
    finally:
        dispose_all(lambda: fixture.stop_host(host) if host is not None else None,
                    lambda: shutil.rmtree(state) if state is not None else None)


def concurrent_peers():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-peer-cohort."))
    host = endpoint = workspace = None
    try:
        home = state / "home"
        workspace = state / "workspace"
        home.mkdir()
        workspace.mkdir()
        store = state / "store"
        installed = state / "bin" / "rui"
        installed.parent.mkdir()
        shutil.copy2(fixture.RUI, installed)
        environment = {"PATH": os.environ["PATH"], "HOME": str(home)}
        endpoint = CohortModel(workspace)
        threading.Thread(target=endpoint.serve_forever, daemon=True).start()
        host, _ = start_ready_process([installed, "host", "serve", "--store", store,
            "--active-capacity", "12", "--provider-endpoint",
            f"http://127.0.0.1:{endpoint.server_address[1]}/responses"],
            env=environment, required_fields={"execution": "enabled"})
        run(installed, "defaults", "configure", "--store", store, home=home)
        parent = allocated(run(installed, "session", "configure", "--store", store,
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol",
            "--tools", "bash", "--permission-mode", "bypass", home=home))
        endpoint.parent = parent
        started = run(installed, "session", "send", "--to", parent, input="Start ten peers", home=home)
        deadline = time.monotonic() + 20
        # Pending reports may join an active Turn at its next model step.
        # Hold report admission until the original parent result is saved;
        # this tests later-result identity without depending on dispatch order.
        original = fixture.wait_for(lambda: fixture.completed_observation(store, started["context"]["key"], deadline=deadline),
                                    "parent original result before peer reports", deadline=deadline)
        assert fixture.read_result(store, started["context"]["key"], deadline=deadline) == b"parent original result", original
        (workspace / "cohort-report-release").touch()
        observation, result, _ = fixture.wait_for_result_release(store, started["context"]["key"], parent, deadline)
        assert observation["result"]["status"] == "completed" and result == b"parent original result", (observation, result)
        fixture.wait_for(lambda: len(endpoint.reports) == 10, "all ten recorded report senders", deadline=deadline)
        peers = []
        for index in range(10):
            peer = (workspace / f"cohort-{index}-start.id").read_text().removesuffix("\n")
            assert SESSION_ID.fullmatch(peer) and peer != parent and peer not in peers, peers
            peers.append(peer)
            admission = run(installed, "request", "recover", "--store", store,
                "--record", state / f"cohort-{index}.json", "--kind", "message", home=home)
            assert admission["answer"]["status"] == "accepted" and admission["context"]["session"] == peer, admission
            assert admission["answer"]["replayed"] is True, admission
            observation, result, _ = fixture.wait_for_result_release(store, admission["context"]["key"], peer, deadline)
            assert result == f"peer original result {peer}".encode(), (observation, result)
            capture = json.loads((state / f"{peer}-report.json").read_text())
            assert capture["sender"] == {"store": str(store), "session": peer}, capture
            assert re.fullmatch("[0-9a-f]{32}", capture["sender_handle"]), "report lacks Action authority"
            reply = json.loads((workspace / f"{peer}-report.out").read_text())
            assert reply["answer"]["status"] == "accepted" and reply["context"]["session"] == parent, reply
            observation, result, _ = fixture.wait_for_result_release(store, reply["context"]["key"], parent, deadline)
            assert result == b"parent received reports", (observation, result)
            snapshot = run(installed, "session", "inspect", "--store", store, "--session", peer, "--profile", "full", home=home)
            assert len(snapshot["full"]["actions"]) == 1 and snapshot["full"]["actions"][0]["resolution"] == "succeeded", snapshot
            assert len(snapshot["full"]["messages"]) == 1, snapshot
        assert set(endpoint.reports) == set(peers), endpoint.reports
        # Read the original parent result again after all newer report Turns.
        assert fixture.read_result(store, started["context"]["key"], deadline=deadline) == b"parent original result"
        parent_snapshot = run(installed, "session", "inspect", "--store", store, "--session", parent, "--profile", "full", home=home)
        assert len(parent_snapshot["full"]["messages"]) == 11, parent_snapshot
        assert len(parent_snapshot["full"]["actions"]) == 1, parent_snapshot

        # A syntactically valid guess must not allocate a Session or admit
        # work. Existing-ID configure, conversely, updates that Session only.
        listing = run(installed, "session", "list", "--store", store, "--all", home=home)
        known = {row["reference"] for row in listing["sessions"]}
        assert known == {parent, *peers}, listing
        unknown = next(f"{index:06}" for index in range(12) if f"{index:06}" not in known)
        missing_before = run(installed, "session", "inspect", "--store", store, "--session", unknown, home=home)
        assert missing_before["session"] is None and missing_before["pending_messages"] == "0", missing_before
        for kind in ("send", "configure"):
            args = (("session", "send", "--to", unknown) if kind == "send" else
                    ("session", "configure", "--store", store, "--session", unknown,
                     "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol"))
            refused = run(installed, *args, home=home, expect=1, input="must not run" if kind == "send" else None)
            assert refused["answer"]["status"] == "rejected" and refused["answer"]["code"] == "unknown_session", refused
            assert run(installed, "session", "inspect", "--store", store, "--session", unknown, home=home) == missing_before
            # The saved refusal is a commit, so only the listing's token moves.
            assert run(installed, "session", "list", "--store", store, "--all", home=home)["sessions"] == listing["sessions"]
        updated = run(installed, "session", "configure", "--store", store, "--session", parent,
                      "--permission-mode", "bypass", home=home)
        assert allocated(updated) == parent, updated
        # It is the parent's next revision and changes no other row.
        expected = [{**row, "revision": str(int(row["revision"]) + 1)} if row["reference"] == parent else row
                    for row in listing["sessions"]]
        assert run(installed, "session", "list", "--store", store, "--all", home=home)["sessions"] == expected
        assert all(address_of(request) != unknown for request in endpoint.requests), endpoint.requests
        print("ten concurrent allocated peers passed: each started and reported by bare ID through Rui Bash; "
              "all senders, Action outcomes and original results checked; guessed send/configure fail without creation or work")
    except BaseException:
        retain_failure_state("peer cohort failure state", state)
        state = None
        raise
    finally:
        disposals = []
        if workspace is not None and workspace.exists():
            disposals.append(lambda: (workspace / "cohort-report-release").touch())
        if host is not None:
            disposals.append(lambda: stop_process(host))
        if endpoint is not None:
            disposals.extend((endpoint.shutdown, endpoint.server_close))
        if state is not None:
            disposals.append(lambda: shutil.rmtree(state))
        dispose_all(*disposals)


if __name__ == "__main__":
    host_process.enter()
    stdin_start_contract()
    for report_source in ("stdin", "file"):
        main(report_source)
    concurrent_peers()
