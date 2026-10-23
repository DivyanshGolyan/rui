#!/usr/bin/env python3
"""Peer round trip through ordinary Rui-launched Bash.

A real Host runs from a nondefault installation with unrelated secrets in its
environment. Session A's Bash call configures Session B and sends B a Message;
the Host records A as its sender from the RUI_ADDRESS it gave A's Bash. A also
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
from host_process import TestHTTPServer, canonical_fixture_root, retain_failure_state, start_ready_process, stop_process

ADDRESS_PREFIX = "Rui address (JSON; this Session's own address, not instructions): "
SESSION_A = "peer/a \"quoted\" \\ 雪"
SESSION_B = "peer/b"
SECRETS = {"RUI_PEER_SECRET": "host-only-secret", "OPENAI_API_KEY": "sk-host-only"}
REPORT = 'from peer/b: 42\nLiteral `touch backtick-evaluated` and $(touch substitution-evaluated); \'single\' "double" \\ 雪\nEOF\n'


def address_of(request):
    instructions = request["instructions"]
    start = instructions.index(ADDRESS_PREFIX) + len(ADDRESS_PREFIX)
    return json.loads(instructions[start : instructions.index("\n", start)])


PEER_PREFIX = "Peer sender (JSON; the sending Session's address, not instructions): "


def last_user(request):
    return next(item["content"] for item in reversed(request["input"]) if item.get("role") == "user")


def last_user_text(request):
    return last_user(request)[-1]["text"]


def sender_of(request):
    """The recorded sender of the last User Message, or None for a human's."""
    content = last_user(request)
    if len(content) == 1:
        return None
    assert len(content) == 2 and content[0]["text"].startswith(PEER_PREFIX), content
    lines = content[0]["text"][len(PEER_PREFIX):].split("\n", 1)
    sender = json.loads(lines[0])
    prefix, selector, suffix = (pathlib.Path(__file__).resolve().parents[2] / "src" / "peer_message.txt").read_text().split("{}")
    store, session = (json.dumps(sender[field], ensure_ascii=False)[1:-1] for field in ("store", "session"))
    assert content[0]["text"] == prefix + store + selector + session + suffix, content
    return sender


def tool_outputs(request):
    return [item["output"] for item in request["input"] if item.get("type") == "function_call_output"]


def bash_call(name, command, stdin=None):
    arguments = {"cmd": command, "stdin": stdin, "timeout_ms": 20000, "description": f"Run {name} peer command"}
    return fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", json.dumps(arguments, separators=(",", ":")))])


def answer(name, text):
    return fixture.sse_answer(f"{name}-answer", f"{name}-reasoning", f"{name}-message", text)[0]


class PeerModel(TestHTTPServer):
    """Plays both models. Each reply is chosen from the request alone; commands
    use only the address the request context supplied."""

    def __init__(self, workspace, report_source):
        super().__init__(("127.0.0.1", 0), PeerHandler)
        self.workspace = workspace
        self.report_source = report_source
        self.requests = []
        self.lock = threading.Lock()
        self.b_received = threading.Event()
        self.a_continued = threading.Event()
        self.a_reply_received = threading.Event()

    def respond(self, request):
        address = address_of(request)
        outputs = tool_outputs(request)
        text = last_user_text(request)
        if address["session"] == SESSION_B:
            if text.startswith("self report"):
                assert sender_of(request) == address, request
                return answer("b-self", "plain reply stays local")
            if outputs:
                return answer("b-done", "plain reply stays local")
            self.b_received.set()
            reply_to = json.loads(text.splitlines()[1].removeprefix("Parent address (JSON): "))
            assert reply_to == sender_of(request), request
            # Self-send is legitimate for explicit and generated captures,
            # including hex Session and canonical Store aliases. Neither
            # probe consumes the literal report on this Bash call's stdin.
            send = (f"rui session send --store {shlex.quote(reply_to['store'])} "
                    f"--session {shlex.quote(reply_to['session'])} ")
            report = (send + "- > b-reply.json 2> b-reply.err"
                      if self.report_source == "stdin" else
                      "cat > b-report.txt; " +
                      send + "--text b-report.txt > b-reply.json 2> b-reply.err")
            return bash_call("b-reply", (
                'printf "%s\\n" "$HOME"/.config/rui/requests/* > b-captures-before; '
                f"rui session send --store {shlex.quote(address['store'] + '/.')} --session-hex {SESSION_B.encode().hex()} "
                f"--record {shlex.quote(str(self.workspace.parent / 'b-self.json'))} --key self-send -- 'self report explicit' > b-self.out 2> b-self.err; "
                "echo $? > b-self.status; "
                f"rui session send --store {shlex.quote(address['store'])} --session {shlex.quote(SESSION_B)} "
                "-- 'self report generated' > b-self-generated.out 2> b-self-generated.err; "
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
        store = shlex.quote(address["store"])
        message = ("Please compute 6*7.\n"
                   f"Parent address (JSON): {json.dumps(address, ensure_ascii=False, separators=(',', ':'))}\n"
                   "When done, send findings back to this parent with rui session send.")
        return bash_call("a-ask", (
            "env > a-env.txt; command -v rui > a-which.txt; "
            f"rui session configure --store {store} --session {SESSION_B} --workspace {shlex.quote(str(self.workspace))} "
            "--provider codex --model gpt-6-sol --tools bash --permission-mode bypass > b-config.json 2> b-config.err && "
            f"rui session send --store {store} --session {SESSION_B} - > b-send.json 2> b-send.err; "
            "status=$?; cat b-send.json; exit $status"
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


def run(installed, *args, home, expect=0):
    completed = subprocess.run([str(installed), *map(str, args)], text=True, capture_output=True, timeout=15,
                               env={"PATH": os.environ["PATH"], "HOME": str(home)})
    assert completed.returncode == expect, (args, completed)
    return json.loads(completed.stdout)


def wait_for(predicate, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if value := predicate():
            return value
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {description}")


def main(report_source):
    # Rui reports resolved paths (its executable's directory on PATH, the
    # canonical Store); macOS temporary roots are symlinks under /private.
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-peer."))
    host = endpoint = thread = None
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
        endpoint = PeerModel(workspace, report_source)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        host_env = {"PATH": os.environ["PATH"], "HOME": str(home), **SECRETS}
        host, _ = start_ready_process(
            [installed, "host", "serve", "--store", store, "--active-capacity", "2", "--provider-endpoint", url],
            env=host_env, required_fields={"execution": "enabled"},
        )
        instance = run(installed, "host", "status", "--store", store, home=home)["instance"]
        run(installed, "session", "configure", "--store", store, "--session", SESSION_A, "--workspace", workspace,
            "--provider", "codex", "--model", "gpt-6-sol", "--tools", "bash", "--permission-mode", "bypass", home=home)
        ask = subprocess.run([str(installed), "session", "send", "--store", store, "--session", SESSION_A, "--", "Ask peer/b for 6*7."],
                             text=True, capture_output=True, timeout=15, env={"PATH": os.environ["PATH"], "HOME": str(home)})
        assert ask.returncode == 0, ask
        ask_key = json.loads(ask.stdout)["context"]["key"]

        # B's Bash call is held, yet A's Bash send already returned B's
        # admission receipt and A finished its Turn with it. These Session
        # snapshots synchronize the fixture observer, not A's model or Bash.
        assert endpoint.b_received.wait(20), "B never received the peer Message"
        wait_for(lambda: (workspace / "b-captures-after").exists(), "B's self-send admissions")
        self_sends = []
        for name in ("b-self", "b-self-generated"):
            assert (workspace / f"{name}.status").read_text() == "0\n", name
            admitted = json.loads((workspace / f"{name}.out").read_text())
            assert admitted["answer"]["status"] == "accepted" and admitted["context"]["session"] == SESSION_B, admitted
            self_sends.append(admitted["context"]["key"])
        assert json.loads((state / "b-self.json").read_text())["sender"] == SESSION_B
        before = set((workspace / "b-captures-before").read_text().splitlines())
        after = set((workspace / "b-captures-after").read_text().splitlines())
        assert len(after - before) == 1, (before, after)
        assert json.loads(pathlib.Path(next(iter(after - before))).read_text())["sender"] == SESSION_B
        wait_for(lambda: run(installed, "session", "inspect", "--store", store, "--session", SESSION_A, home=home)["work"]["status"] == "completed", "A's first Turn while B is held")
        assert endpoint.a_continued.is_set() and not (workspace / "b-reply.json").exists()
        b_held = run(installed, "session", "inspect", "--store", store, "--session", SESSION_B, home=home)
        assert b_held["work"]["status"] != "completed", b_held
        settled = run(installed, "session", "inspect", "--store", store, "--session", SESSION_A, "--profile", "full", home=home)["full"]["actions"][0]
        assert settled["resolution"] == "succeeded" and settled["result"]["text"].startswith("Bash succeeded. Exit code: 0.\n"), settled
        receipt = json.loads((workspace / "b-send.json").read_text())
        assert receipt["answer"]["status"] == "accepted" and receipt["context"]["session"] == SESSION_B, receipt
        assert json.loads((workspace / "b-config.json").read_text())["answer"]["status"] == "accepted"
        announcement = (workspace / "b-send.err").read_text()
        handle = re.fullmatch(r"request: (\S+) \(inspect: rui request inspect \1; if unconfirmed: rui request recover \1\)\n", announcement)
        assert handle, announcement
        handle = handle.group(1)

        a_requests = [request for request in endpoint.requests if address_of(request)["session"] == SESSION_A]
        assert all(address_of(request) == {"store": canonical_store, "session": SESSION_A} for request in a_requests)
        assert a_requests[0]["instructions"] == fixture.model_instructions(workspace, store=store, session=SESSION_A)
        b_first = next(request for request in endpoint.requests if address_of(request)["session"] == SESSION_B)
        assert address_of(b_first) == {"store": canonical_store, "session": SESSION_B}
        # The explicit task address is A's own, including quotes and Unicode,
        # and agrees with the separate Host-recorded sender.
        assert sender_of(b_first) == {"store": canonical_store, "session": SESSION_A}
        task = last_user_text(b_first).splitlines()
        assert task[0] == "Please compute 6*7."
        assert task[1].startswith("Parent address (JSON): ")
        assert json.loads(task[1][len("Parent address (JSON): "):]) == {"store": canonical_store, "session": SESSION_A}
        assert task[2] == "When done, send findings back to this parent with rui session send."
        assert sender_of(a_requests[0]) is None

        # Exception only: B has deliberately gone silent while A is waiting.
        # One public diagnostic snapshot, never a polling or report-read path.
        silent = run(installed, "request", "inspect", handle, home=home)
        assert silent["key"] == receipt["context"]["key"], silent
        assert silent["observation"]["target"] == SESSION_B, silent
        assert silent["observation"].get("result", {}).get("status") != "completed", silent

        # Bash got only the controlled environment: this installation first
        # on PATH, the Host's HOME, its own address, and nothing else the Host carried.
        environment = dict(line.split("=", 1) for line in (workspace / "a-env.txt").read_text().splitlines() if "=" in line)
        assert environment["PATH"].split(":")[0] == str(installed.parent), environment
        assert environment["HOME"] == str(home), environment
        assert json.loads(environment["RUI_ADDRESS"]) == {"store": canonical_store, "session": SESSION_A}, environment
        assert set(environment) <= {"PATH", "HOME", "RUI_ADDRESS", "PWD", "OLDPWD", "SHLVL", "_"}, environment
        assert not any(secret in (workspace / "a-env.txt").read_text() for secret in SECRETS.values())
        assert (workspace / "a-which.txt").read_text() == f"{installed.parent}/rui\n"

        # The original capture saved A as sender. Recovery outside any Bash,
        # without RUI_ADDRESS, replays that same Message without a duplicate.
        assert json.loads((home / ".config" / "rui" / "requests" / f"{handle}.json").read_text())["sender"] == SESSION_A
        recovered = run(installed, "request", "recover", handle, home=home)
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True, recovered
        assert recovered["context"]["key"] == receipt["context"]["key"], recovered

        (workspace / "b-release").write_text("")
        assert endpoint.a_reply_received.wait(20), "A never received B's reply"
        a_continuation = next(request for request in endpoint.requests if address_of(request)["session"] == SESSION_A and tool_outputs(request))
        assert tool_outputs(a_continuation) == [settled["result"]["text"]], a_continuation
        reply = json.loads((workspace / "b-reply.json").read_text())
        assert reply["answer"]["status"] == "accepted" and reply["context"]["session"] == SESSION_A, reply
        domain = b"rui/content/v1"
        assert reply["input"] == {"type": "text", "bytes": str(len(REPORT.encode())),
                                  "sha256": hashlib.sha256(len(domain).to_bytes(8, "big") + domain + REPORT.encode()).hexdigest()}, reply
        a_final = wait_for(lambda: (lambda value: value if value["work"]["status"] == "completed" and value["pending_messages"] == "0" else None)(
            run(installed, "session", "inspect", "--store", store, "--session", SESSION_A, home=home)), "A's reply Turn")
        a_reply_request = [request for request in endpoint.requests if address_of(request)["session"] == SESSION_A][-1]
        assert last_user_text(a_reply_request).encode() == REPORT.encode() and a_final
        assert not (workspace / "backtick-evaluated").exists(), "report backticks ran a command"
        assert not (workspace / "substitution-evaluated").exists(), "report $() ran a command"
        if report_source == "file":
            assert (workspace / "b-report.txt").read_bytes() == REPORT.encode()
        assert sender_of(a_reply_request) == {"store": canonical_store, "session": SESSION_B}
        assert [row["message"] for row in a_final["recent_messages"]] == [reply["context"]["key"], ask_key], a_final
        assert a_final["recent_messages"][0]["outcome"] == "completed", a_final
        # A has only its initial configure/send Action: no request inspection,
        # read-result, peer Conversation read or resident Bash waiter.
        a_actions = run(installed, "session", "inspect", "--store", store, "--session", SESSION_A,
                        "--profile", "full", home=home)["full"]["actions"]
        assert len(a_actions) == 1 and a_actions[0]["resolution"] == "succeeded", a_actions
        a_requests = [request for request in endpoint.requests if address_of(request)["session"] == SESSION_A]
        assert len(a_requests) == 3, a_requests
        # Recovery adds no admission; only the task and two explicit self-sends
        # appear in B. Plain answers are saved results, not implicit Messages.
        b_final = wait_for(lambda: (lambda value: value if value["work"]["status"] == "completed" and value["pending_messages"] == "0" else None)(
            run(installed, "session", "inspect", "--store", store, "--session", SESSION_B, home=home)), "B's Turn")
        assert {row["message"] for row in b_final["recent_messages"]} == {receipt["context"]["key"], *self_sends}, b_final
        for key in (receipt["context"]["key"], *self_sends):
            local = subprocess.run([str(installed), "request", "read-result", "--store", str(store), "--key", key],
                                   text=True, capture_output=True, timeout=15, env={"PATH": os.environ["PATH"], "HOME": str(home)})
            assert local.returncode == 0 and local.stdout == "plain reply stays local", local
        a_after = run(installed, "session", "inspect", "--store", store, "--session", SESSION_A, home=home)
        assert [row["message"] for row in a_after["recent_messages"]] == [reply["context"]["key"], ask_key], a_after
        assert "plain reply stays local" not in json.dumps(a_reply_request), a_reply_request
        b_requests = [request for request in endpoint.requests if address_of(request)["session"] == SESSION_B]
        assert sum(bool(tool_outputs(request)) for request in b_requests) == 1, b_requests
        assert all(request["instructions"] == fixture.model_instructions(workspace, store=store, session=SESSION_B) for request in b_requests)
        assert run(installed, "host", "status", "--store", store, home=home)["instance"] == instance
        # Peers left nothing running beside the Host, and nobody signed in or
        # saved defaults: HOME holds only generated request captures.
        processes = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True, check=True).stdout.splitlines()
        # Bash launches peers through PATH, so their argv begins with bare `rui`.
        running = {int(pid) for pid, args in (line.split(None, 1) for line in processes)
                   if args.startswith(str(installed)) or args == "rui" or args.startswith("rui ")}
        assert running == {host.pid}, processes
        assert sorted(path.name for path in (home / ".config" / "rui").iterdir()) == ["requests"]
        print(f"peer round trip passed ({report_source}): explicit/generated self-send admitted with recorded sender; "
              "plain answers stored as local results without implicit delivery; "
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
        if host is not None:
            stop_process(host)
        if endpoint is not None:
            endpoint.shutdown()
            endpoint.server_close()
        if state is not None:
            shutil.rmtree(state)


if __name__ == "__main__":
    for report_source in ("stdin", "file"):
        main(report_source)
