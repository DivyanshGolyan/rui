#!/usr/bin/env python3
"""Public-caller managed-route journey with only fixed, synthetic credentials."""

import json
import fcntl
import os
import pathlib
import shlex
import shutil
import sys
import tempfile
import threading
import time

import bash_integration as bash
import dispatch_integration as fixture
from host_process import HostDiagnostics, start_ready_process


ACCESS = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln"
ID = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJydWktdGVzdC1hY2NvdW50In0.c2ln"
FEDRAMP_ID = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoicnVpLXRlc3QtYWNjb3VudCIsImNoYXRncHRfYWNjb3VudF9pc19mZWRyYW1wIjp0cnVlfX0.c2ln"
ACCOUNT = "rui-test-account"


class ManagedHandler(fixture.SuccessHandler):
    def do_POST(self):
        with self.server.lock:
            self.server.header_observations.append(
                (self.path, self.headers.get("Authorization"), self.headers.get("ChatGPT-Account-ID"))
            )
        super().do_POST()


def credentials(path, *, state="ready", access=ACCESS, fedramp=False):
    path.write_text(
        "version=3\ngeneration=1\naccount_id=" + ACCOUNT +
        "\nfedramp=" + str(int(fedramp)) + "\nid_token=" + (FEDRAMP_ID if fedramp else ID) +
        "\naccess_token=" + access + "\nrefresh_token=synthetic-not-real\n"
        "expires_at=4102444800\nrefreshed_at=1750000000\nstate=" + state + "\n"
    )
    path.chmod(0o600)


def proposal_with_private_reasoning(command):
    reasoning = {"type": "reasoning", "id": "managed-reasoning", "summary": [],
                 "encrypted_content": "synthetic-private-reasoning"}
    call = {"type": "function_call", "id": "managed-call-item", "status": "completed",
            "name": "bash", "call_id": "managed-call",
            "arguments": json.dumps({"cmd": command, "timeout_ms": None}, separators=(",", ":"))}
    return fixture.encode_sse([
        {"type": "response.output_item.added", "output_index": 0,
         "item": {"type": "reasoning", "id": reasoning["id"]}},
        {"type": "response.output_item.done", "output_index": 0, "item": reasoning},
        {"type": "response.output_item.added", "output_index": 1,
         "item": {"type": "function_call", "id": call["id"]}},
        {"type": "response.output_item.done", "output_index": 1, "item": call},
        {"type": "response.completed", "response": {"id": "managed-calls", "status": "completed",
                                                  "output": [reasoning, call]}},
    ])


def start(store, endpoint, *extra):
    host, _ = start_ready_process(
        [fixture.RUI, "serve", "--store", store, "--active-capacity", "2",
         "--test-codex-fixture-endpoint", endpoint, *extra],
        required_fields={"execution": "enabled", "curl": "8.22.0"},
    )
    return host


def run():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-codex."))
    credential_dir = state / "private"
    credential_dir.mkdir(mode=0o700)
    credential_file = credential_dir / "codex.json"
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential_file)
    proof = state / "proof"
    command = f"printf 'once\\n' >> {shlex.quote(str(proof))}; printf tool-witness"
    responses = [proposal_with_private_reasoning(command),
                 fixture.sse_answer("managed-answer", "reasoning", "message", "managed answer")[0]]
    responses.append(fixture.sse_answer("after-restart", "reasoning", "answer", "later answer")[0])
    endpoint = fixture.SuccessEndpoint(responses)
    endpoint.RequestHandlerClass = ManagedHandler
    endpoint.header_observations = []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    store = state / "store"
    host = None
    diagnostics = None
    complete = False
    try:
        # Missing and uncertain credentials must never reach model transport.
        credentials(credential_file, state="refresh_pending")
        host = start(store, url)
        instruction_file = state / "instructions.txt"
        instruction_file.write_text("Use the approved tool result.")
        configured = fixture.command(
            "configure", "--store", store, "--record", state / "configure.json",
            "--key", "configure", "--session", "managed/session", "--workspace", fixture.ROOT,
            "--provider", "codex", "--model", "model-a", "--tools", "bash",
            "--permission-mode", "ask", "--instructions", instruction_file,
        )
        assert configured["answer"]["status"] == "accepted"
        fixture.message(state, store, "pending-message", "managed/session", "run the proof")
        fixture.wait_for(lambda: fixture.observe(store, "pending-message").get("result"), "authentication failure")
        assert not endpoint.requests, "pending refresh reached transport"
        fixture.stop_host(host)
        host = None

        credentials(credential_file, access="e30.eyJleHAiOjQxMDI0NDQ4MDB9.b3RoZXI")
        host = start(store, url)
        fixture.message(state, store, "other-credential", "managed/session", "reject another credential")
        fixture.wait_for(lambda: fixture.observe(store, "other-credential").get("result"), "synthetic-only fixture rejection")
        assert not endpoint.requests, "a non-canary credential reached the test endpoint"
        fixture.stop_host(host)
        host = None

        credentials(credential_file)
        host = start(store, url)
        fixture.message(state, store, "message", "managed/session", "run the proof")
        action = fixture.wait_for(lambda: bash.action_for(store, "managed/session"), "managed Bash proposal")
        assert fixture.read_action(store, "managed/session", action["action"], "call-id") == b"managed-call"
        assert json.loads(fixture.read_action(store, "managed/session", action["action"], "arguments"))["cmd"] == command
        bash.allow(state, store, "allow", "managed/session", action["action"])
        fixture.wait_for(lambda: fixture.completed_observation(store, "message"), "managed answer")
        # The 12-byte tool stdout is optionally retained; custody, not the
        # retained full output, must be released before the crash cut.
        fixture.wait_for(lambda: bash.execution_custody_idle(store, "managed/session"), "owned cleanup")
        assert fixture.read_result(store, "message") == b"managed answer"
        assert proof.read_text() == "once\n"
        public_report = json.dumps(fixture.command(
            "inspect-session", "--store", store, "--session", "managed/session", "--profile", "full",
        ))
        assert "synthetic-private-reasoning" not in public_report
        assert ACCESS not in public_report
        assert bash.rows(store, "SELECT private FROM content WHERE instr(payload, ?) > 0", (b"synthetic-private-reasoning",)) == [(1,)]
        assert not bash.rows(store, "SELECT private FROM content WHERE instr(payload, ?) > 0", (ACCESS.encode(),))
        assert len(endpoint.requests) == 2
        continuation = json.loads(endpoint.requests[1])
        assert any(item.get("type") == "function_call_output" and item["call_id"] == "managed-call" and "tool-witness" in item["output"] for item in continuation["input"])
        assert any(item.get("type") == "reasoning" and item.get("encrypted_content") for item in continuation["input"])
        assert all(item.get("role") != "system" for item in continuation["input"])
        assert continuation["instructions"] == "Use the approved tool result."

        fixture.stop_host(host)
        host = start(store, url)
        assert fixture.retry_message(state, store, "message")["answer"]["replayed"] is True
        assert fixture.read_result(store, "message") == b"managed answer"
        assert len(endpoint.requests) == 2 and proof.read_text() == "once\n"
        fixture.message(state, store, "later", "managed/session", "new message")
        fixture.wait_for(lambda: fixture.completed_observation(store, "later"), "post-restart answer")
        assert fixture.read_result(store, "later") == b"later answer"
        assert len(endpoint.requests) == 3 and proof.read_text() == "once\n"
        later = json.loads(endpoint.requests[2])
        assert any(item.get("type") == "function_call_output" and item["call_id"] == "managed-call" for item in later["input"])
        with endpoint.lock:
            endpoint.responses.append(fixture.ResponseSpec(b"authentication rejected", {}, 401))
        fixture.message(state, store, "rejected", "managed/session", "no hidden resend")
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "rejected")).get("result", {}).get("code") and value,
            "managed authentication rejection",
        )
        assert failure["result"]["code"] == "provider_http_401", failure
        time.sleep(0.4)
        assert len(endpoint.requests) == 4, "managed authentication rejection resent a model request"
        assert all(path == "/responses" and bearer == "Bearer " + ACCESS and account == ACCOUNT for path, bearer, account in endpoint.header_observations)
        fixture.stop_host(host)
        host = None

        # Block the worker on the same stable file lock used by login while
        # a public stop is accepted. Releasing it must not revive dispatch.
        stop_store = state / "stop-store"
        host = start(stop_store, url, "--test-phase-trace")
        diagnostics = HostDiagnostics(host)
        configured = fixture.command(
            "configure", "--store", stop_store, "--record", state / "stop-config.json",
            "--key", "stop-config", "--session", "managed/stop", "--workspace", fixture.ROOT,
            "--provider", "codex", "--model", "model-a", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted"
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            fixture.message(state, stop_store, "stop-message", "managed/stop", "do not launch")
            diagnostics.wait("preparation_completed", timeout=10)
            stopped = fixture.command(
                "stop-session", "--store", stop_store, "--record", state / "stop.json",
                "--key", "stop", "--session", "managed/stop",
            )
            assert stopped["answer"]["status"] == "accepted"
            assert len(endpoint.requests) == 4
        fixture.wait_for(lambda: bash.execution_custody_idle(stop_store, "managed/stop"),
                         "cancelled authentication custody", timeout=10)
        assert len(endpoint.requests) == 4, "stopped authentication launched a model request"
        schema = state / "unsupported-schema.json"
        schema.write_text('{"type":"object"}')
        for feature, tools, extra in (("edit", "edit", []),
                                      ("schema", "none", ["--output-schema", schema])):
            session = f"managed/{feature}"
            configured = fixture.command(
                "configure", "--store", stop_store,
                "--record", state / f"{feature}-config.json", "--key", f"{feature}-config",
                "--session", session, "--workspace", fixture.ROOT, "--provider", "codex",
                "--model", "model-a", "--tools", tools, *extra,
            )
            assert configured["answer"]["status"] == "accepted"
            fixture.message(state, stop_store, feature, session, "unsupported managed request")
            rejected = fixture.wait_for(
                lambda feature=feature: (value := fixture.observe(stop_store, feature)).get("result", {}).get("code") and value,
                f"{feature} rejected before managed dispatch",
            )
            assert rejected["result"]["code"] == "unsupported_codex_configuration", rejected
            assert len(endpoint.requests) == 4
        print("codex synthetic managed journey passed: approved effect once, private continuation, fresh Host, post-restart dispatch, no authentication resend, stopped authentication and unsupported settings never launch")
        complete = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        if diagnostics is not None:
            diagnostics.close()
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if complete:
            shutil.rmtree(state)
        else:
            print(f"retained Codex fixture failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    run()
