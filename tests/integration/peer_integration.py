#!/usr/bin/env python3
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
from session_list_fixture import session_values
import host_process
from product_defaults import DEFAULTS, compaction_trigger, start_effort
from host_process import TestHTTPServer, assert_caller_error, canonical_fixture_root, dispose_all, retain_failure_state, start_ready_process, stop_process, wait_for
import os_semantics

SESSION_ID = re.compile("[0123456789abcdefghjkmnpqrstvwxyz]{6}")
SECRETS = {"RUI_PEER_SECRET": "host-only-secret", "OPENAI_API_KEY": "sk-host-only"}
REPORT = 'from peer/b: 42\nLiteral `touch backtick-evaluated` and $(touch substitution-evaluated); \'single\' "double" \\ 雪\nEOF\n'


def address_of(request):
    session = fixture.instructions_session(fixture.request_system_prompt(request))
    assert SESSION_ID.fullmatch(session), session
    return session


PEER_PARTS = (pathlib.Path(__file__).resolve().parents[2] / "src" / "peer_message.txt").read_text().split("{}")
A_LABEL = "Lead: arithmetic check"
B_LABEL = "Worker: multiply"
EMPTY_LABEL = "Empty target"
ARCHIVED_LABEL = "Archived target"
STOPPED_LABEL = "Stopped target"


def model_instructions(workspace, session):
    return fixture.model_instructions(workspace, store=None, session=session, model="gpt-6-sol")


def last_user(request):
    return next(item["content"] for item in reversed(request["input"]) if item.get("role") == "user")


def last_user_text(request):
    return last_user(request)[-1]["text"]


def sender_of(request):
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


def call_output(request, call_id):
    return any(item.get("type") == "function_call_output" and item.get("call_id") == call_id for item in request["input"])


def bash_call(name, command, stdin=None):
    arguments = {"cmd": command, "stdin": stdin, "timeout_ms": 20000, "description": f"Run {name} peer command"}
    return fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", json.dumps(arguments, separators=(",", ":")))])


def answer(name, text):
    return fixture.sse_answer(f"{name}-answer", f"{name}-reasoning", f"{name}-message", text)[0]


class PeerModel(TestHTTPServer):

    def __init__(self, workspace, foreign_store, external_session):
        super().__init__(("127.0.0.1", 0), PeerHandler)
        self.workspace = workspace
        self.foreign_store = foreign_store
        self.external_session = external_session
        self.a = self.b = self.empty = self.missing = self.archived = self.stopped = None
        self.requests = []
        self.lock = threading.Lock()
        self.defaults_restored = threading.Event()
        self.b_received = threading.Event()
        self.a_continued = threading.Event()
        self.a_reply_received = threading.Event()
        self.stop_received = threading.Event()
        self.b_release = threading.Event()
        self.stop_release = threading.Event()

    def respond(self, request):
        address = address_of(request)
        outputs = tool_outputs(request)
        text = last_user_text(request)
        if address == self.stopped:
            self.stop_received.set()
            assert self.stop_release.wait(20), "stopped target provider was not released"
            return answer("stopped", "unobserved answer")
        if address != self.a:
            self.b = address
            if call_output(request, "b-reply-call"):
                return answer("b-done", "plain reply stays local")
            reply_to = text.splitlines()[1].removeprefix("Parent ID: ")
            self.b_received.set()
            assert self.b_release.wait(20), "B's provider request was not released"
            return fixture.sse_tool_calls("b-reply-calls", [("message_agent", "b-reply-call",
                json.dumps({"id": reply_to, "text": REPORT}, separators=(",", ":")))])
        if text.startswith("from peer/b: "):
            self.a_reply_received.set()
            return answer("a-final", f"peer said 42. [Open worker](rui-session:{self.b})\n"
                          f"[Open empty](rui-session:{self.empty}) [Open missing](rui-session:{self.missing})\n"
                          f"[Open archived](rui-session:{self.archived}) [Open stopped](rui-session:{self.stopped})")
        if outputs:
            self.a_continued.set()
            return answer("a-wait", "waiting for peer/b")
        assert self.defaults_restored.wait(20), "conflicting HOME preference was not restored"
        message = ("Please compute 6*7.\n"
                   f"Parent ID: {address}\n"
                   "When done, send findings back to this parent with message_agent.")
        return bash_call("a-ask", (
            "env | sed '/^RUI_SENDER_HANDLE=/d' > a-env.txt; command -v rui > a-which.txt; "
            f"printf %s 'plain caller elsewhere' | rui session send --store {shlex.quote(str(self.foreign_store))} --session {self.external_session} "
            f"--record {shlex.quote(str(self.workspace.parent / 'conflicting-store.json'))} --key conflicting-store "
            "> conflicting-store.out 2> conflicting-store.err || exit 91; "
            f'rui session configure --store "$RUI_STORE" --session "$RUI_ADDRESS" --label {shlex.quote(A_LABEL)} '
            "> a-label.out 2> a-label.err || exit 89; "
            f"rui session start --workspace {shlex.quote(str(self.workspace))} --label {shlex.quote(B_LABEL)} "
            "--connection codex --model gpt-6-sol --tools bash,message_agent --permission-mode bypass > b-start.json 2> b-send.err; "
            "status=$?; cat b-start.json; exit $status"
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


def assistant_session_link_journey(installed, store, home, workspace, session_a, session_b, empty, missing, endpoint):
    # SUI-26: the rendered Assistant link carries its exact Session through the feed.
    from human_cli_fixture import keyed_frame, read_terminal, terminal_capture
    from terminal_process import terminal_process
    from terminal_screen import chat_footer_shown
    env = {"PATH": os.environ["PATH"], "HOME": str(home)}

    def showing(frame, x, y):
        return chat_footer_shown(frame)

    def footer_of(frame):
        return next(line.strip() for line in frame.split("\n") if line.startswith(" ‹ "))

    def pointer(frame, label, drag=False):
        rows = frame.split("\n")
        row = next(index for index, line in enumerate(rows) if label in line)
        column = rows[row].index(label) + 1
        end = column + 4 if drag else column
        motion = f"\x1b[<32;{end};{row + 1}M" if drag else ""
        return f"\x1b[<0;{column};{row + 1}M{motion}\x1b[<0;{end};{row + 1}m".encode()

    with terminal_process([str(installed), "session", "resume", "--store", str(store), session_a], env=env) as (_, master):
        read_terminal(master, "✓ Run a-ask peer command")
        endpoint.b_release.set()
        frame = keyed_frame(master, b"", lambda screen, x, y: showing(screen, x, y) and "Open worker" in screen, chat=A_LABEL)
        assert "rui-session:" not in frame and "[Open worker]" not in frame, frame
        for session in (session_a, session_b):
            def settled(session=session):
                report = run(installed, "session", "inspect", "--store", store, "--session", session, home=home)
                return report["work"]["state"]["kind"] == "finished" and report["pending_messages"] == "0"
            wait_for(settled, "Session settled", timeout=20)
        def messages(session):
            return run(installed, "session", "inspect", "--store", store, "--session", session,
                       "--profile", "full", home=home)["full"]["messages"]

        before_messages = {session: messages(session) for session in (session_a, session_b, empty, endpoint.archived, endpoint.stopped)}
        assert before_messages[empty] == [] and before_messages[endpoint.archived] == [], before_messages
        assert len(before_messages[endpoint.stopped]) == 1, before_messages[endpoint.stopped]
        before_requests = len(endpoint.requests)
        frame = keyed_frame(master, b"draft survives", lambda screen, x, y: "draft survives" in screen)
        capture = terminal_capture(master)
        before = len(capture.clipboard)
        frame = keyed_frame(master, pointer(frame, "Open worker", drag=True),
                            lambda screen, x, y: showing(screen, x, y) and "Copied 1 line" in screen, chat=A_LABEL)
        assert len(capture.clipboard) == before + 1, capture.clipboard
        worker = keyed_frame(master, pointer(frame, "Open worker"), showing, chat=B_LABEL)
        assert "draft survives" not in worker, worker
        frame = keyed_frame(master, b"\x1b", lambda screen, x, y: showing(screen, x, y) and "draft survives" in screen, chat=A_LABEL)
        target = keyed_frame(master, pointer(frame, "Open empty"), showing, chat=EMPTY_LABEL)
        assert "draft survives" not in target, target
        frame = keyed_frame(master, b"\x1b", lambda screen, x, y: showing(screen, x, y) and "draft survives" in screen, chat=A_LABEL)
        linked_footers = {}
        for text, label in (("Open archived", ARCHIVED_LABEL), ("Open stopped", STOPPED_LABEL)):
            target = keyed_frame(master, pointer(frame, text), lambda screen, x, y:
                                 showing(screen, x, y) and (label != STOPPED_LABEL or "Work to stop" in screen), chat=label)
            linked_footers[label] = footer_of(target)
            frame = keyed_frame(master, b"\x1b", lambda screen, x, y: showing(screen, x, y) and "draft survives" in screen, chat=A_LABEL)
        assert "Archived" in linked_footers[ARCHIVED_LABEL], linked_footers

    for session, label in ((endpoint.archived, ARCHIVED_LABEL), (endpoint.stopped, STOPPED_LABEL)):
        with terminal_process([str(installed), "session", "resume", "--store", str(store), session], env=env) as (_, master):
            direct = keyed_frame(master, b"", lambda screen, x, y:
                                 showing(screen, x, y) and (label != STOPPED_LABEL or "Work to stop" in screen), chat=label)
            footer = footer_of(direct)
            assert footer == linked_footers[label], (label, footer, linked_footers[label])

    # Reopening reads the saved Assistant answer and still follows its link.
    with terminal_process([str(installed), "session", "resume", "--store", str(store), session_a], env=env) as (caller, master):
        frame = keyed_frame(master, b"", lambda screen, x, y: showing(screen, x, y) and "Open worker" in screen, chat=A_LABEL)
        keyed_frame(master, pointer(frame, "Open worker"), showing, chat=B_LABEL)
        frame = keyed_frame(master, b"\x1b", showing, chat=A_LABEL)
        returned = keyed_frame(master, pointer(frame, "Open missing"), lambda screen, x, y:
                               showing(screen, x, y) and "That Session no longer exists" in screen, chat=A_LABEL)
        assert caller.poll() is None, returned

    with terminal_process([str(installed), "session", "resume", "--store", str(store), missing], env=env) as (caller, master):
        terminal_capture(master)
        wait_for(lambda: caller.poll() is not None, "direct missing Session ends the terminal")
        assert caller.returncode != 0, caller.returncode

    assert {session: messages(session) for session in before_messages} == before_messages
    assert len(endpoint.requests) == before_requests, endpoint.requests
    assert run(installed, "session", "inspect", "--store", store, "--session", missing, home=home)["session"] is None


def session_link_journey(installed, store, home, session_a):
    from human_cli_fixture import current_screen, keyed_frame, overview_title, read_terminal
    from terminal_screen import chat_footer_shown
    from terminal_process import terminal_process
    env = {"PATH": os.environ["PATH"], "HOME": str(home)}

    def showing(frame, x, y):
        return chat_footer_shown(frame)

    with terminal_process([str(installed), "session", "resume", "--store", str(store), session_a], env=env) as (_, master):
        read_terminal(master, f"Received message from {B_LABEL}")
        frame = keyed_frame(master, b"", showing, chat=A_LABEL)
        rows = frame.split("\n")
        row = next(index for index, line in enumerate(rows) if f"Received message from {B_LABEL}" in line)
        column = rows[row].index(B_LABEL) + 2
        click = f"\x1b[<0;{column};{row + 1}M\x1b[<0;{column};{row + 1}m".encode()
        keyed_frame(master, click, showing, chat=B_LABEL)
        keyed_frame(master, b"\x1b", showing, chat=A_LABEL)
        # Ctrl-O follows the last openable item, which is now the Assistant answer's final link.
        keyed_frame(master, b"\x0f", showing, chat=STOPPED_LABEL)
        keyed_frame(master, b"\x1b", showing, chat=A_LABEL)
        keyed_frame(master, b"\x1b", lambda frame, x, y: overview_title(frame))

def main():
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
        unrelated_store = state / "not-the-sending-store"
        unrelated_store.mkdir(mode=0o700)
        run(installed, "defaults", "configure", "--store", unrelated_store, home=home)
        saved_defaults = (home / ".config" / "rui" / "preferences").read_bytes()
        refused_record = state / "invalid-address.json"
        for address in ('', 'peer/b', 'rui/k7m2qx', '/store/k7m2qx', 'store:k7m2qx', 'K7M2QX', 'k7m2qi', 'k7m2ql', 'k7m2qo',
                        'k7m2qu', 'k7m2q', 'k7m2qxx', '6b376d327178', ' k7m2qx', 'k7m2qx\n',
                        '{}', '{"session":""}', '{"session":"x","store":null}',
                        '{"session":"x","session":"y"}', '{"session_hex":"78"}',
                        '{"session":"x","store_hex":"2f73746f7265"}',
                        '{"session":"peer/nul\\u0000雪"}',
                        '{"session":"x","store":"/bad\\u0000path"}'):
            refused = subprocess.run([str(installed), "session", "send", "--session", address,
                "--record", str(refused_record), "--key", "invalid"],
                env={"PATH": os.environ["PATH"], "HOME": str(home)}, capture_output=True, timeout=10)
            assert refused.returncode == 2 and b"six lowercase Crockford" in refused.stderr, refused
            assert refused.stdout == b"" and not refused_record.exists(), refused
        for old_flag in ("--to", "--session-hex"):
            refused = subprocess.run([str(installed), "session", "send", "--session", "k7m2qx", old_flag, "obsolete",
                "--record", str(refused_record), "--key", "invalid"],
                env={"PATH": os.environ["PATH"], "HOME": str(home)}, capture_output=True, timeout=10)
            assert refused.returncode == 2, refused
            assert_caller_error(refused.stderr, f"rui session send: {old_flag}: ", "option_unknown")
            assert refused.stdout == b"" and not refused_record.exists(), refused
        foreign_store = state / "foreign-store"
        foreign_host, _ = start_ready_process([installed, "host", "serve", "--store", foreign_store],
            env={"PATH": os.environ["PATH"], "HOME": str(home)}, required_fields={"execution": "unavailable"})
        external_session = allocated(run(installed, "session", "configure", "--store", foreign_store,
            "--workspace", workspace, "--connection", "codex", "--model", "gpt-6-sol", home=home))
        foreign_listing = run(installed, "session", "list", "--store", foreign_store, "--all", home=home)
        invalid_selectors = [("--session", value, (b"[invalid_session_reference]",)) for value in
                             ('peer/a "quoted" \\ 雪', 'ABC123', 'k7m2qi', 'rui/k7m2qx')]
        invalid_selectors.append(("--session-hex", 'peer/nul\x00雪'.encode().hex(),
                                  (b"rui session configure: --session-hex: ", b" Nothing was captured or sent. [option_unknown]\n")))
        for flag, invalid, diagnostic in invalid_selectors:
            rejected = subprocess.run([str(installed), "session", "configure", "--store", str(foreign_store),
                flag, invalid, "--workspace", str(workspace),
                "--connection", "codex", "--model", "gpt-6-sol", "--record", str(refused_record), "--key", "invalid-config"],
                env={"PATH": os.environ["PATH"], "HOME": str(home)}, capture_output=True, timeout=15)
            assert rejected.returncode == 2 and all(part in rejected.stderr for part in diagnostic), rejected
            assert rejected.stdout == b"" and not refused_record.exists(), rejected
            assert run(installed, "session", "list", "--store", foreign_store, "--all", home=home) == foreign_listing
        external = run(installed, "session", "send", "--store", foreign_store, "--session", external_session,
            input="genuine external send", home=home)
        assert external["answer"]["status"] == "accepted" and external["context"]["session"] == external_session, external
        assert external["context"]["store"] == str(foreign_store), external
        assert (home / ".config" / "rui" / "preferences").read_bytes() == saved_defaults
        endpoint = PeerModel(workspace, foreign_store, external_session)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        host_env = {"PATH": os.environ["PATH"], "HOME": str(home), **SECRETS}
        host, _ = start_ready_process(
            [installed, "host", "serve", "--store", store,
                "--set", 'execution.activeCapacity=2',
                "--set", "providers={}",
                "--set", "providers.codex.endpoint=" + str(url),
                "--set", "providers.codex.unauthenticated=true"],
            env=host_env, required_fields={"execution": "enabled"},
        )
        instance = run(installed, "host", "status", "--store", store, home=home)["instance"]
        session_a = allocated(run(installed, "session", "configure", "--store", store, "--workspace", workspace,
            "--connection", "codex", "--model", "gpt-6-sol", "--tools", "bash", "--permission-mode", "bypass", home=home))
        endpoint.a = session_a
        endpoint.empty = allocated(run(installed, "session", "configure", "--store", store, "--workspace", workspace,
            "--connection", "codex", "--model", "gpt-6-sol", "--label", EMPTY_LABEL, home=home))
        endpoint.archived = allocated(run(installed, "session", "configure", "--store", store, "--workspace", workspace,
            "--connection", "codex", "--model", "gpt-6-sol", "--label", ARCHIVED_LABEL, home=home))
        endpoint.stopped = allocated(run(installed, "session", "configure", "--store", store, "--workspace", workspace,
            "--connection", "codex", "--model", "gpt-6-sol", "--label", STOPPED_LABEL, home=home))
        archived = run(installed, "session", "archive", "--store", store, "--session", endpoint.archived, home=home)
        assert archived["answer"]["status"] == "accepted", archived
        wait_for(lambda: run(installed, "session", "inspect", "--store", store, "--session", endpoint.archived,
                             home=home)["archive_state"] == "archived", "archived target")
        stopped_input = run(installed, "session", "send", "--store", store, "--session", endpoint.stopped,
                            home=home, input="Work to stop")
        assert stopped_input["answer"]["status"] == "accepted", stopped_input
        assert endpoint.stop_received.wait(20), "stopped target did not start its model request"
        stopped = run(installed, "session", "stop", "--store", store, "--session", endpoint.stopped, home=home)
        assert stopped["answer"]["status"] == "accepted", stopped
        def stopped_report():
            report = run(installed, "session", "inspect", "--store", store, "--session", endpoint.stopped, home=home)
            return report if report["recent_messages"] and report["recent_messages"][0]["outcome"] == "cancelled" else None
        wait_for(stopped_report, "stopped target settled", timeout=20)
        endpoint.stop_release.set()
        run(installed, "defaults", "configure", "--store", store, home=home)
        ask = subprocess.run([str(installed), "session", "send", "--store", str(store), "--session", session_a], input="Ask peer/b for 6*7.",
                             text=True, capture_output=True, timeout=15, env={"PATH": os.environ["PATH"], "HOME": str(home)})
        assert ask.returncode == 0, ask
        ask_key = json.loads(ask.stdout)["context"]["key"]
        run(installed, "defaults", "configure", "--store", unrelated_store, home=home)
        endpoint.defaults_restored.set()

        assert endpoint.b_received.wait(20), "B never received the peer Message"
        session_b = endpoint.b
        assert session_b != session_a and SESSION_ID.fullmatch(session_b), session_b
        endpoint.missing = next(candidate for candidate in ("000000", "111111", "222222", "333333", "444444", "555555")
                                if candidate not in (session_a, session_b, endpoint.empty, endpoint.archived, endpoint.stopped))
        missing_report = run(installed, "session", "inspect", "--store", store, "--session", endpoint.missing, home=home)
        assert missing_report["session"] is None and missing_report["execution"]["reason"] == "session_not_found", missing_report
        wait_for(lambda: run(installed, "session", "inspect", "--store", store, "--session", session_a, home=home)["work"]["state"]["kind"] == "finished", "A's first Turn while B is held", timeout=20)
        assert endpoint.a_continued.is_set() and not endpoint.a_reply_received.is_set()
        b_held = run(installed, "session", "inspect", "--store", store, "--session", session_b, home=home)
        assert b_held["work"]["state"]["kind"] != "finished", b_held
        settled = run(installed, "session", "inspect", "--store", store, "--session", session_a, "--profile", "full", home=home)["full"]["actions"][0]
        assert settled["resolution"] == "succeeded" and settled["result"]["text"].startswith("Bash succeeded. Exit code: 0.\n"), settled
        elsewhere = json.loads((workspace / "conflicting-store.out").read_text())
        assert elsewhere["answer"]["status"] == "accepted", elsewhere
        assert elsewhere["context"]["session"] == external_session and elsewhere["context"]["store"] == str(foreign_store), elsewhere
        start_receipt = json.loads((workspace / "b-start.json").read_text())
        assert allocated(start_receipt) == session_b, start_receipt
        assert start_receipt["configuration"] == {"connection": "codex", "model": "gpt-6-sol",
            "reasoning_effort": start_effort("gpt-6-sol"), "effort_source": "model_default"}, start_receipt
        announcement = (workspace / "b-send.err").read_text()
        handle = re.fullmatch(r"request: (\S+) \(wait: rui request wait \1; if unconfirmed: rui request recover \1\)\n", announcement)
        assert handle, announcement
        handle = handle.group(1)
        assert start_receipt["context"]["key"] == handle, start_receipt
        receipt = run(installed, "request", "recover", handle, home=home)
        assert receipt["answer"]["status"] == "accepted" and receipt["context"]["session"] == session_b, receipt
        assert receipt["answer"]["replayed"] is True, receipt

        a_requests = [request for request in endpoint.requests if address_of(request) == session_a]
        assert all(address_of(request) == session_a for request in a_requests)
        assert fixture.request_system_prompt(a_requests[0]) == model_instructions(workspace, session_a)
        b_first = next(request for request in endpoint.requests if address_of(request) == session_b)
        assert address_of(b_first) == session_b
        assert sender_of(b_first) is None
        task = last_user_text(b_first).splitlines()
        assert task[0] == "Please compute 6*7."
        assert task[1] == f"Parent ID: {session_a}"
        assert task[2] == "When done, send findings back to this parent with message_agent."
        assert sender_of(a_requests[0]) is None

        silent = run(installed, "request", "inspect", handle, home=home)
        assert silent["key"] == receipt["context"]["key"], silent
        assert silent["observation"]["target"] == session_b, silent
        assert silent["observation"]["status"] == "accepted", silent

        environment = dict(line.split("=", 1) for line in (workspace / "a-env.txt").read_text().splitlines() if "=" in line)
        assert environment["PATH"] == f"{installed.parent}:{os.environ['PATH']}", environment
        assert environment["HOME"] == str(home), environment
        assert environment["RUI_ADDRESS"] == session_a and environment["RUI_STORE"] == canonical_store, environment
        assert set(environment) <= {"PATH", "HOME", "RUI_ADDRESS", "RUI_STORE", "PWD", "OLDPWD", "SHLVL", "_"}, environment
        assert not any(secret in (workspace / "a-env.txt").read_text() for secret in SECRETS.values())
        assert (workspace / "a-which.txt").read_text() == f"{installed.parent}/rui\n"

        assert "sender" not in json.loads((home / ".config" / "rui" / "requests" / f"{handle}.json").read_text())
        recovered = run(installed, "request", "recover", handle, home=home)
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True, recovered
        assert recovered["context"]["key"] == receipt["context"]["key"], recovered

        assistant_session_link_journey(installed, store, home, workspace, session_a, session_b, endpoint.empty, endpoint.missing, endpoint)
        assert endpoint.a_reply_received.wait(20), "A never received B's reply"
        a_continuation = next(request for request in endpoint.requests if address_of(request) == session_a and tool_outputs(request))
        assert tool_outputs(a_continuation) == [settled["result"]["text"]], a_continuation
        wait_for(lambda: any(address_of(request) == session_b and call_output(request, "b-reply-call") for request in endpoint.requests),
                 "B's message_agent call returned", timeout=20)
        a_final = wait_for(lambda: (lambda value: value if value["work"]["state"]["kind"] == "finished" and value["pending_messages"] == "0" else None)(
            run(installed, "session", "inspect", "--store", store, "--session", session_a, home=home)), "A's reply Turn", timeout=20)
        a_reply_request = [request for request in endpoint.requests if address_of(request) == session_a][-1]
        assert last_user_text(a_reply_request).encode() == REPORT.encode() and a_final
        assert not (workspace / "backtick-evaluated").exists(), "report backticks ran a command"
        assert not (workspace / "substitution-evaluated").exists(), "report $() ran a command"
        assert sender_of(a_reply_request) == session_b
        assert [row["message"] for row in a_final["recent_messages"]][1:] == [ask_key], a_final
        assert a_final["recent_messages"][0]["message"].startswith("rui.core/message_agent/"), a_final
        assert a_final["recent_messages"][0]["outcome"] == "completed", a_final
        a_actions = run(installed, "session", "inspect", "--store", store, "--session", session_a,
                        "--profile", "full", home=home)["full"]["actions"]
        assert len(a_actions) == 1 and a_actions[0]["resolution"] == "succeeded", a_actions
        a_requests = [request for request in endpoint.requests if address_of(request) == session_a]
        assert len(a_requests) == 3, a_requests
        b_final = wait_for(lambda: (lambda value: value if value["work"]["state"]["kind"] == "finished" and value["pending_messages"] == "0" else None)(
            run(installed, "session", "inspect", "--store", store, "--session", session_b, home=home)), "B's Turn", timeout=20)
        assert [row["message"] for row in b_final["recent_messages"]] == [receipt["context"]["key"]], b_final
        local = subprocess.run([str(installed), "request", "read-result", "--store", str(store), "--key", receipt["context"]["key"]],
                               text=True, capture_output=True, timeout=15, env={"PATH": os.environ["PATH"], "HOME": str(home)})
        assert local.returncode == 0 and local.stdout == "plain reply stays local", local
        a_after = run(installed, "session", "inspect", "--store", store, "--session", session_a, home=home)
        assert [row["message"] for row in a_after["recent_messages"]][1:] == [ask_key], a_after
        assert "plain reply stays local" not in json.dumps(a_reply_request), a_reply_request
        b_requests = [request for request in endpoint.requests if address_of(request) == session_b]
        b_receipts = [item for request in b_requests for item in request["input"]
                      if item.get("type") == "function_call_output" and item.get("call_id") == "b-reply-call"]
        assert b_receipts, b_requests
        rows = {row["reference"]: row for row in run(installed, "session", "list", "--store", store, "--all", home=home)["sessions"]}
        assert (rows[session_a]["label"], rows[session_b]["label"]) == (A_LABEL, B_LABEL), rows
        assert rows[session_b]["first_message"]["sender"] is None, rows[session_b]
        assert rows[session_a]["first_message"]["sender"] is None, rows[session_a]
        assert rows[session_a]["peers"]["from_person_at"] is not None, rows[session_a]
        assert rows[session_b]["peers"]["from_person_at"] is not None, rows[session_b]
        assert B_LABEL not in json.dumps(b_requests), b_requests
        session_link_journey(installed, store, home, session_a)
        assert all(fixture.request_system_prompt(request) == model_instructions(workspace, session_b) for request in b_requests)
        assert run(installed, "host", "status", "--store", store, home=home)["instance"] == instance
        (state / "leak-home").mkdir()
        controls = []
        try:
            controls.append(subprocess.Popen(["rui", "60"], executable="/bin/sleep"))
            controls.append(subprocess.Popen(["renamed-copy", "host", "serve", "--store", str(state / "leak-store"), "--set", "providers={}"],
                executable=installed, env={"PATH": os.environ["PATH"], "HOME": str(state / "leak-home")},
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            observed = wait_for(lambda: os_semantics.processes_executing(installed), "the census sees the renamed copy",
                                timeout=10, ready=lambda observed: controls[1].pid in observed)
            assert controls[0].pid not in observed, (controls[0].pid, observed)
        finally:
            dispose_all(*(lambda process=process: stop_process(process) for process in controls))
        running = os_semantics.processes_executing(installed)
        assert running == {host.pid, foreign_host.pid}, running
        assert list(unrelated_store.iterdir()) == [], "peer followed HOME preferences instead of its sender Store"
        assert (home / ".config" / "rui" / "preferences").read_bytes() == saved_defaults
        assert sorted(path.name for path in (home / ".config" / "rui").iterdir()) == [".preferences.lock", "preferences", "requests"]
        print("peer round trip passed: anonymous explicit Store beat conflicting HOME defaults; "
              "peer --store naming another Store sent there as a plain caller; "
              "plain answers stored as local results without implicit delivery; omitted Store beat conflicting HOME defaults; "
              "installed Bash rui configured B with a durable receipt, "
              "A included its own parent address and explicit report-back instructions, "
              "B sent findings through message_agent and A received the saved incoming report without request polling, result or peer Conversation reads, "
              "one silent-peer diagnostic inspection, Host-recorded sender on A's incoming report, "
              "original capture recovered without duplicate, A finished while B was held, "
              "no idle peer or login, controlled PATH/HOME; scripted provider, not a model-compliance guarantee")
    except BaseException:
        retain_failure_state("peer integration failure state", state)
        state = None
        raise
    finally:
        disposals = []
        if workspace is not None and workspace.exists():
            disposals.append(endpoint.b_release.set)
        if host is not None:
            disposals.append(lambda: stop_process(host))
        if foreign_host is not None:
            disposals.append(lambda: stop_process(foreign_host))
        if endpoint is not None:
            disposals.append(endpoint.defaults_restored.set)
            disposals.append(endpoint.stop_release.set)
            disposals.extend((endpoint.shutdown, endpoint.server_close))
        if state is not None:
            disposals.append(lambda: shutil.rmtree(state))
        dispose_all(*disposals)


class CohortModel(TestHTTPServer):

    def __init__(self, workspace):
        super().__init__(("127.0.0.1", 0), PeerHandler)
        self.workspace = workspace
        self.parent = None
        self.requests = []
        self.lock = threading.Lock()
        self.reports = {}
        self.release = threading.Event()

    def respond(self, request):
        session = address_of(request)
        assert fixture.request_system_prompt(request) == model_instructions(self.workspace, session), request
        if session != self.parent:
            assert sender_of(request) is None, request
            assert last_user_text(request) == f"Report to parent ID {self.parent}", request
            call_id = f"report-call-{session}"
            if call_output(request, call_id):
                return answer(session, f"peer original result {session}")
            assert self.release.wait(30), "cohort reports were not released"
            return fixture.sse_tool_calls(f"report-calls-{session}", [("message_agent", call_id,
                json.dumps({"id": self.parent, "text": f"report from {session}"}, separators=(",", ":")))])
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
        return bash_call("cohort-start", (
            "pids=''; for i in 0 1 2 3 4 5 6 7 8 9; do ( "
            "n=0; while [ ! -e cohort-create ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done; "
            "[ -e cohort-create ] || exit 124; "
            f"printf %s 'Report to parent ID {self.parent}' | rui session start --workspace {shlex.quote(str(self.workspace))} "
            "--connection codex --model gpt-6-sol --tools bash,message_agent --permission-mode bypass "
            f'--record {shlex.quote(str(self.workspace.parent))}/cohort-$i.json --key cohort-$i '
            '> "cohort-$i-start.json" 2> "cohort-$i-start.err" '
            ') & pids="$pids $!"; done; touch cohort-create; '
            'status=0; for pid in $pids; do wait "$pid" || status=1; done; exit "$status"'
        ))


def stdin_start_contract():
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

        def failed(result, code, status=1):
            assert result.returncode == status and result.stdout == b"", result
            assert f"[{code}]".encode() in result.stderr, result
            assert b"error:" not in result.stderr, result
            if code == "host_not_serving":
                assert f"rui host start --store $'{store}'.".encode() in result.stderr, result

        failed(invoke("session", "start", "--store", state / "absent", input=b"first"), "store_unavailable", status=6)
        host = fixture.start_host(store, None)
        for args in (("send", "--session", "k7m2qx", "--texts", "input"),
                     ("send", "--session", "k7m2qx", "literal"),
                     ("configure", "--instructions", "input"),
                     ("start", "--instructions", "-")):
            result = invoke("session", *args, "--store", store)
            assert result.returncode == 2 and result.stdout == b"" and b"request:" not in result.stderr, result
        for data, code in ((b"", "message_empty"), (b"bad\xff", "internal_unexpected")):
            record = state / "invalid.json"
            result = invoke("session", "start", "--store", store, "--record", record, "--key", "invalid", input=data)
            failed(result, code, status=2 if not data else 1)
            assert not record.exists(), result
        directory = os.open(state, os.O_RDONLY)
        try:
            failed(invoke("session", "start", "--store", store, stdin=directory), "internal_unexpected")
        finally:
            os.close(directory)
        failed(invoke("session", "configure", "--store", store,
            "--output-schema", state / "missing-schema"), "internal_unexpected")
        assert fixture.command("session", "list", "--store", store, "--all")["sessions"] == []

        text = "initial\x00雪\n`literal` $(data)\r\n\n".encode()
        record = state / "start.json"
        lost = invoke("session", "start", "--store", store, "--record", record, "--key", "first",
            "--workspace", state, "--test-drop-reply", "after-commit", input=text)
        assert lost.returncode == 4 and not lost.stdout and b"[reply_unconfirmed]" in lost.stderr, lost
        saved = record.read_bytes()
        capture = json.loads(saved)
        assert capture["session"] == "" and capture["kind"] == "message", capture
        assert capture["text"]["value"].encode() == text and capture["configuration"]["workspace"] == str(state), capture
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
        assert observed["target"] == session and "result" not in observed and observed["state"] == "queued", observed
        listing = fixture.command("session", "list", "--store", store, "--all")["sessions"]
        assert [row["reference"] for row in listing] == [session], listing
        snapshot = fixture.command("session", "inspect", "--store", store, "--session", session)
        assert snapshot["pending_messages"] == "1", snapshot
        instructions = "rules\x00é\n\n"
        configured = fixture.command("session", "configure", "--store", store, "--session", session,
            "--record", state / "instructions.json", "--key", "instructions", "--instructions", "-", input=instructions)
        assert configured["answer"]["status"] == "accepted", configured
        assert json.loads((state / "instructions.json").read_bytes())["configuration"]["instructions"] == instructions
        stopped = fixture.command("session", "stop", "--store", store, "--session", session)
        assert stopped["answer"]["status"] == "accepted", stopped
        assert fixture.observe(store, "first")["result"] == {"status": "cancelled", "code": "session_stopped"}
        socket = pathlib.Path(host.rui_ready_fields["socket"])
        # A crashed Host leaves its socket behind; the offline cases below need that stale socket,
        # so crash it rather than stop it (a clean stop retires the endpoint).
        fixture.crash_host(host, state, "stdin-start-crash")
        host = None
        assert socket.is_socket(), socket
        for arguments in (
                ("request", "inspect", "--key", "first"),
                ("request", "read-result", "--key", "first"),
                ("session", "list"),
                ("session", "read-content", "--session", session, "--position", "1", "--ordinal", "1"),
                ("action", "inspect", "--session", session, "--action", "1")):
            failed(invoke(*arguments, "--store", store), "host_not_serving", status=6)
        failed(invoke("session", "send", "--store", store, "--session", session, input=b"offline"), "host_not_serving", status=6)
        socket.unlink()
        failed(invoke("session", "send", "--store", store, "--session", session, input=b"offline"), "host_not_serving", status=6)
        offline_record = state / "offline-start.json"
        failed(invoke("session", "start", "--store", store, "--record", offline_record, "--key", "offline-start",
            input=b"admit once after reconnect"), "host_not_serving", status=6)
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
        defaults_reply = invoke("defaults", "configure", "--connection", "codex", "--model", "gpt-6.1-sol",
            "--reasoning-effort", "high")
        assert defaults_reply.returncode == 0, defaults_reply
        for arguments, model, effort, source in (
            (("--connection", "codex", "--model", "gpt-6.1-sol"), "gpt-6.1-sol", "high", "saved"),
            (("--model", "gpt-6.1-sol"), "gpt-6.1-sol", "high", "saved"),
            (("--model", "gpt-6.1-sol", "--reasoning-effort", "xhigh"), "gpt-6.1-sol", "xhigh", "flag"),
            (("--model", "gpt-6.1-sol", "--reasoning-effort", "default"), "gpt-6.1-sol", start_effort("gpt-6.1-sol"), "flag"),
            (("--model", "unlisted-model"), "unlisted-model", "high", "saved"),
        ):
            started = invoke("session", "start", "--store", store, "--workspace", state, *arguments,
                input=b"report configuration")
            assert started.returncode == 0, started
            start_receipt = json.loads(started.stdout)
            new_session = allocated(start_receipt)
            assert list(start_receipt) == ["context", "configuration", "answer", "input", "queue"], start_receipt
            assert start_receipt["configuration"] == {"connection": "codex", "model": model,
                "reasoning_effort": effort, "effort_source": source}, start_receipt
            tools = DEFAULTS.tools.split(",")
            if not (os_semantics.PROC_FS or os_semantics.DARWIN):
                tools.remove("read_image")
            loaded = list(tools)
            creation = {"connection": "codex", "model": model, "reasoning_effort": effort,
                        "workspace": str(state.resolve()), "tools": tools, "loaded_tools": loaded,
                        "permission_mode": DEFAULTS.permission_mode,
                        "compaction_trigger": str(compaction_trigger("codex", model))}
            assert start_receipt["answer"]["configuration"] == creation, start_receipt
            observed = fixture.command("session", "inspect", "--store", store, "--session", new_session)["session"]
            assert observed["model"] == model and observed["reasoning_effort"] == effort, observed
            handle = start_receipt["context"]["key"]
            assert f"request: {handle} (wait: rui request wait {handle}; if unconfirmed: rui request recover {handle})\n".encode() in started.stderr, started
            replay = json.loads(invoke("request", "recover", handle).stdout)
            assert replay["context"] == start_receipt["context"] and "configuration" not in replay, replay
            assert replay["answer"]["replayed"] is True and replay["answer"]["configuration"] == creation, replay
            assert fixture.command("session", "stop", "--store", store, "--session", new_session)["answer"]["status"] == "accepted"
        print("stdin/start: exact NUL/UTF-8/newline bytes, lost admission, four concurrent original replays, one allocated Session, "
              "queued-not-completed receipt, effective configuration and effort sources, cancellation/reopen, stdin-only grammar "
              "and precise read/parse/store/connect errors passed")
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
            "--set", 'execution.activeCapacity=12',
                "--set", "providers={}",
                "--set", "providers.codex.endpoint=" + str(f"http://127.0.0.1:{endpoint.server_address[1]}/responses"),
                "--set", "providers.codex.unauthenticated=true"],
            env=environment, required_fields={"execution": "enabled"})
        run(installed, "defaults", "configure", "--store", store, home=home)
        parent = allocated(run(installed, "session", "configure", "--store", store,
            "--workspace", workspace, "--connection", "codex", "--model", "gpt-6-sol",
            "--tools", "bash", "--permission-mode", "bypass", home=home))
        endpoint.parent = parent
        started = run(installed, "session", "send", "--session", parent, input="Start ten peers", home=home)
        deadline = time.monotonic() + 20
        original = fixture.wait_for(lambda: fixture.completed_observation(store, started["context"]["key"], deadline=deadline),
                                    "parent original result before peer reports", deadline=deadline)
        assert fixture.read_result(store, started["context"]["key"], deadline=deadline) == b"parent original result", original
        endpoint.release.set()
        observation, result, _ = fixture.wait_for_result_release(store, started["context"]["key"], parent, deadline)
        assert observation["result"]["status"] == "completed" and result == b"parent original result", (observation, result)
        fixture.wait_for(lambda: len(endpoint.reports) == 10, "all ten recorded report senders", deadline=deadline)
        peers = []
        for index in range(10):
            start_receipt = json.loads((workspace / f"cohort-{index}-start.json").read_text())
            peer = allocated(start_receipt)
            assert SESSION_ID.fullmatch(peer) and peer != parent and peer not in peers, peers
            peers.append(peer)
            admission = run(installed, "request", "recover", "--store", store,
                "--record", state / f"cohort-{index}.json", "--kind", "message", home=home)
            assert admission["answer"]["status"] == "accepted" and admission["context"]["session"] == peer, admission
            assert admission["answer"]["replayed"] is True, admission
            observation, result, _ = fixture.wait_for_result_release(store, admission["context"]["key"], peer, deadline)
            assert result == f"peer original result {peer}".encode(), (observation, result)
            snapshot = run(installed, "session", "inspect", "--store", store, "--session", peer, "--profile", "full", home=home)
            assert len(snapshot["full"]["actions"]) == 1 and snapshot["full"]["actions"][0]["resolution"] == "succeeded", snapshot
            assert len(snapshot["full"]["messages"]) == 1, snapshot
        assert set(endpoint.reports) == set(peers), endpoint.reports
        wait_for(lambda: (lambda value: value if value["work"]["state"]["kind"] == "finished" and value["pending_messages"] == "0" else None)(
            run(installed, "session", "inspect", "--store", store, "--session", parent, home=home)), "parent handled every report", timeout=30)
        assert fixture.read_result(store, started["context"]["key"], deadline=deadline) == b"parent original result"
        parent_snapshot = run(installed, "session", "inspect", "--store", store, "--session", parent, "--profile", "full", home=home)
        assert len(parent_snapshot["full"]["messages"]) == 11, parent_snapshot
        assert len(parent_snapshot["full"]["actions"]) == 1, parent_snapshot

        listing = run(installed, "session", "list", "--store", store, "--all", home=home)
        known = {row["reference"] for row in listing["sessions"]}
        assert known == {parent, *peers}, listing
        unknown = next(f"{index:06}" for index in range(12) if f"{index:06}" not in known)
        missing_before = run(installed, "session", "inspect", "--store", store, "--session", unknown, home=home)
        assert missing_before["session"] is None and missing_before["pending_messages"] == "0", missing_before
        for kind in ("send", "configure"):
            args = (("session", "send", "--session", unknown) if kind == "send" else
                    ("session", "configure", "--store", store, "--session", unknown,
                     "--workspace", workspace, "--connection", "codex", "--model", "gpt-6-sol"))
            refused = run(installed, *args, home=home, expect=3, input="must not run" if kind == "send" else None)
            assert refused["answer"]["status"] == "rejected" and refused["answer"]["code"] == "unknown_session", refused
            assert run(installed, "session", "inspect", "--store", store, "--session", unknown, home=home) == missing_before
            after = run(installed, "session", "list", "--store", store, "--all", home=home)
            assert session_values(after) == session_values(listing)
        updated = run(installed, "session", "configure", "--store", store, "--session", parent,
                      "--permission-mode", "bypass", home=home)
        assert allocated(updated) == parent, updated
        expected = [{**row, "revision": str(int(row["revision"]) + 1)} if row["reference"] == parent else row
                    for row in session_values(listing)]
        assert session_values(run(installed, "session", "list", "--store", store, "--all", home=home)) == expected
        assert all(address_of(request) != unknown for request in endpoint.requests), endpoint.requests
        print("ten concurrent allocated peers passed: each started through Rui Bash and reported through message_agent; "
              "all senders, Action outcomes and original results checked; guessed send/configure fail without creation or work")
    except BaseException:
        retain_failure_state("peer cohort failure state", state)
        state = None
        raise
    finally:
        disposals = []
        if workspace is not None and workspace.exists():
            disposals.append(endpoint.release.set)
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
    main()
    concurrent_peers()
