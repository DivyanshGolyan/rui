#!/usr/bin/env python3

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

import bash_fixture as bash
import model_fixture as fixture
from product_defaults import DEFAULTS, compaction_trigger, start_effort
import host_process
import os_semantics
from host_process import HostDiagnostics, PauseGate, READY_TRANSPORT, retain_failure_state, start_ready_process
from control_fixture import raw_request
from codex_fixture import ACCESS, ACCOUNT, OPENAI_KEY, credentials, expected_user_agent


class ManagedHandler(fixture.SuccessHandler):
    def do_POST(self):
        with self.server.lock:
            self.server.header_observations.append(
                (self.path, self.headers.get("Authorization"), self.headers.get("ChatGPT-Account-ID"),
                 self.headers.get("session-id"), self.headers.get("originator"))
            )
            self.server.user_agents.append(self.headers.get("User-Agent"))
            if hasattr(self.server, "turn_states"):
                self.server.turn_states.append(self.headers.get_all("x-codex-turn-state") or [])
        super().do_POST()


def credential_facts(path):
    facts = dict(line.split("=", 1) for line in path.read_text().splitlines())
    return facts["generation"], facts["state"]


def lock_available(lock):
    if not os_semantics.try_lock(lock):
        return False
    os_semantics.release_lock(lock)
    return True


def proposal_with_private_reasoning(command):
    reasoning = {"type": "reasoning", "id": "managed-reasoning", "summary": [],
                 "encrypted_content": "synthetic-private-reasoning"}
    call = {"type": "function_call", "id": "managed-call-item", "status": "completed",
            "name": "bash", "call_id": "managed-call",
            "arguments": json.dumps({"cmd": command, "timeout_ms": None, "description": "Run managed provider command"}, separators=(",", ":"))}
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


def start(store, endpoint, *extra, pause=None):
    host, _ = start_ready_process(
        [fixture.RUI, "host", "serve", "--store", store, "--set", 'execution.activeCapacity=2',
         "--set", f"providers.codex.endpoint={endpoint}", *extra],
        required_fields=READY_TRANSPORT,
        observations="managed" if "--test-phase-trace" in extra else None,
        pause=pause,
    )
    return host


def run():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-codex.")).resolve()
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
    endpoint.user_agents = []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    store = state / "store"
    host = None
    diagnostics = None
    handoff = None
    complete = False
    try:
        credentials(credential_file, state="refresh_pending")
        host = start(store, url)
        head, listed_body = raw_request(host.rui_ready_fields["socket"], "/v1/model-list", json.dumps({
            "version": host_process.WIRE_VERSION, "kind": "model_list", "store": str(store),
        }).encode())
        listed = json.loads(listed_body)["connections"]
        assert b" 200 " in head and len(listed) == 1, (head, listed)
        assert listed[0]["connection"] == "codex" and listed[0]["source"] == "catalog", listed
        assert listed[0]["models"] and all(model["known"] for model in listed[0]["models"]), listed
        configured = fixture.command(
            "session", "configure", "--store", store, "--record", state / "configure.json",
            "--key", "configure", "--workspace", fixture.ROOT,
            "--connection", "codex", "--model", "gpt-6-sol", "--tools", "bash",
            "--permission-mode", "ask", "--instructions", "-",
            input="Use the approved tool result.",
        )
        assert configured["answer"]["status"] == "accepted"
        session = configured["answer"]["session"]
        fixture.message(state, store, "pending-message", session, "run the proof")
        pending = fixture.wait_for(lambda: fixture.observe(store, "pending-message").get("result"), "authentication failure")
        assert pending["code"] == "provider_sign_in_required", pending
        assert not endpoint.requests, "pending refresh reached transport"
        fixture.stop_host(host)
        host = None

        credentials(credential_file, access="e30.eyJleHAiOjQxMDI0NDQ4MDB9.b3RoZXI")
        host = start(store, url)
        fixture.message(state, store, "other-credential", session, "reject another credential")
        fixture.wait_for(lambda: fixture.observe(store, "other-credential").get("result"), "synthetic-only fixture rejection")
        assert not endpoint.requests, "a non-canary credential reached the test endpoint"
        fixture.stop_host(host)
        host = None

        credentials(credential_file)
        host = start(store, url)
        diagnostics = HostDiagnostics(host)
        fixture.message(state, store, "message", session, "run the proof")
        action = fixture.wait_for(lambda: bash.action_for(store, session), "managed Bash proposal")
        assert fixture.read_action(store, session, action["action"], "call-id") == b"managed-call"
        assert json.loads(fixture.read_action(store, session, action["action"], "arguments"))["cmd"] == command
        assert json.loads(endpoint.requests[0])["reasoning"] == {"effort": start_effort("gpt-6-sol")}
        configured = fixture.command(
            "session", "configure", "--store", store, "--session", session,
            "--record", state / "effort-high.json", "--key", "effort-high",
            "--reasoning-effort", "high",
        )
        assert configured["answer"]["status"] == "accepted", configured
        bash.allow(state, store, "allow", session, action["action"])
        fixture.wait_for(lambda: fixture.completed_observation(store, "message"), "managed answer")
        fixture.wait_for(lambda: bash.execution_custody_idle(store, session), "owned cleanup")
        assert fixture.read_result(store, "message") == b"managed answer"
        assert proof.read_text() == "once\n"
        public_report = json.dumps(fixture.command(
            "session", "inspect", "--store", store, "--session", session, "--profile", "full",
        ))
        assert "synthetic-private-reasoning" not in public_report
        assert ACCESS not in public_report
        assert len(endpoint.requests) == 2
        continuation = json.loads(endpoint.requests[1])
        assert continuation["reasoning"] == {"effort": start_effort("gpt-6-sol")}, continuation
        assert [item for item in continuation["input"] if item.get("type") == "configuration_update"] == [
            {"type": "configuration_update", "reasoning": {"effort": "high"}}
        ], continuation["input"]
        assert any(item.get("type") == "function_call_output" and item["call_id"] == "managed-call" and "tool-witness" in item["output"] for item in continuation["input"])
        assert any(item.get("type") == "reasoning" and item.get("encrypted_content") for item in continuation["input"])
        assert all(item.get("role") != "system" for item in continuation["input"])
        assert fixture.request_system_prompt(continuation) == fixture.model_instructions(fixture.ROOT, "Use the approved tool result.", store=store, session=session, model="gpt-6-sol")

        fixture.stop_host(host)
        assert bash.rows(store, "SELECT private FROM content WHERE instr(payload, ?) > 0", (b"synthetic-private-reasoning",)) == [(1,)]
        assert not bash.rows(store, "SELECT private FROM content WHERE instr(payload, ?) > 0", (ACCESS.encode(),))
        host = start(store, url)
        assert fixture.retry_message(state, store, "message")["answer"]["replayed"] is True
        assert fixture.read_result(store, "message") == b"managed answer"
        assert len(endpoint.requests) == 2 and proof.read_text() == "once\n"
        settings = fixture.command("session", "inspect", "--store", store, "--session", session)["session"]
        assert settings["reasoning_effort"] == settings["reasoning_effort_override"] == "high", settings
        guard = fixture.command(
            "session", "configure", "--store", store, "--record", state / "effort-guard.json",
            "--key", "effort-guard", "--workspace", fixture.ROOT,
            "--connection", "codex", "--model", "gpt-6.1-sol", "--tools", "bash",
            "--reasoning-effort", "high", "--permission-mode", "ask",
        )
        assert guard["answer"]["status"] == "accepted", guard
        guard_session = guard["answer"]["session"]
        guard_settings = fixture.command("session", "inspect", "--store", store, "--session", guard_session)["session"]
        for effort in ("none",):
            rejected = fixture.command(
                "session", "configure", "--store", store, "--session", guard_session,
                "--record", state / f"effort-refused-{effort}.json", "--key", f"effort-refused-{effort}",
                "--reasoning-effort", effort, "--permission-mode", "bypass", expect=3,
            )
            assert rejected["answer"]["status"] == "rejected", rejected
            assert rejected["answer"]["code"] == "unsupported_reasoning_effort", rejected
            unchanged = fixture.command("session", "inspect", "--store", store, "--session", guard_session)["session"]
            assert unchanged == guard_settings and len(endpoint.requests) == 2, unchanged
        configured = fixture.command(
            "session", "configure", "--store", store, "--session", session,
            "--record", state / "effort-none.json", "--key", "effort-none",
            "--reasoning-effort", "none",
        )
        assert configured["answer"]["status"] == "accepted", configured
        selected = fixture.command("session", "inspect", "--store", store, "--session", session)["session"]
        assert selected["reasoning_effort"] == selected["reasoning_effort_override"] == "none", selected
        invalid_effort = subprocess.run([str(fixture.RUI), "session", "configure", "--store", str(store),
            "--session", session, "--reasoning-effort", "ultra"], capture_output=True, text=True, timeout=10)
        assert invalid_effort.returncode == 2 and not invalid_effort.stdout, invalid_effort
        assert "[choice_unsupported]" in invalid_effort.stderr, invalid_effort
        configured = fixture.command(
            "session", "configure", "--store", store, "--session", session,
            "--record", state / "effort-default.json", "--key", "effort-default",
            "--reasoning-effort", "default",
        )
        assert configured["answer"]["status"] == "accepted", configured
        fixture.message(state, store, "later", session, "new message")
        fixture.wait_for(lambda: fixture.completed_observation(store, "later"), "post-restart answer")
        assert fixture.read_result(store, "later") == b"later answer"
        assert len(endpoint.requests) == 3 and proof.read_text() == "once\n"
        later = json.loads(endpoint.requests[2])
        assert later["reasoning"] == {"effort": start_effort("gpt-6-sol")}, later
        assert any(item.get("type") == "function_call_output" and item["call_id"] == "managed-call" for item in later["input"])
        rejected_release = threading.Event()
        with endpoint.lock:
            endpoint.responses.append((fixture.ResponseSpec(b"authentication rejected", {"X-Request-Id": "newer-ready"}, 401), rejected_release))
        fixture.message(state, store, "rejected", session, "no hidden resend")
        fixture.wait_for(lambda: len(endpoint.requests) == 4, "rejected managed request")
        credentials(credential_file, generation=2)
        rejected_release.set()
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "rejected")).get("result", {}).get("code") and value,
            "managed authentication rejection",
        )
        assert failure["result"]["code"] == "provider_http_401", failure
        operation = fixture.command("session", "inspect", "--store", store, "--session", session,
                                    "--profile", "full")["full"]["model_operations"][-1]
        assert operation["request_id"] == "newer-ready", operation
        time.sleep(0.4)
        assert len(endpoint.requests) == 4, "managed authentication rejection resent a model request"
        assert credential_facts(credential_file) == ("2", "ready"), "an advanced generation was refreshed again"
        assert len(endpoint.header_observations) == 4
        session_ids = {row[3] for row in endpoint.header_observations}
        assert len(session_ids) == 1 and re.fullmatch(r"[0-9a-f]{32}", next(iter(session_ids)))
        assert all(path == "/responses" and bearer == "Bearer " + ACCESS and account == ACCOUNT and originator == "rui"
                   for path, bearer, account, _, originator in endpoint.header_observations)
        fixture.stop_host(host)
        host = None
        assert b"rui: codex transfer" not in diagnostics.tail()
        assert not any(row["rui_test_phase"] == "codex_transfer" for row in diagnostics.records), "ordinary Host emitted test-only transfer observations"
        diagnostics = None

        stop_store = state / "stop-store"
        host = start(stop_store, url, "--test-phase-trace")
        diagnostics = HostDiagnostics(host)
        configured = fixture.command(
            "session", "configure", "--store", stop_store, "--record", state / "stop-config.json",
            "--key", "stop-config", "--workspace", fixture.ROOT,
            "--connection", "codex", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted"
        stopped_session = configured["answer"]["session"]
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            os_semantics.take_lock(lock)
            fixture.message(state, stop_store, "stop-message", stopped_session, "do not launch")
            diagnostics.wait("preparation_completed", timeout=10)
            stopped = fixture.command(
                "session", "stop", "--store", stop_store, "--record", state / "stop.json",
                "--key", "stop", "--session", stopped_session,
            )
            assert stopped["answer"]["status"] == "accepted"
            assert len(endpoint.requests) == 4
        fixture.wait_for(lambda: bash.execution_custody_idle(stop_store, stopped_session),
                         "cancelled authentication custody", timeout=10)
        assert len(endpoint.requests) == 4, "stopped authentication launched a model request"
        fixture.stop_host(host)
        host = None

        # EXR-61
        handoff = PauseGate("model.before_handoff")
        host = start(stop_store, url, "--test-phase-trace", pause=handoff)
        diagnostics = HostDiagnostics(host)
        configured = fixture.command(
            "session", "configure", "--store", stop_store, "--record", state / "handoff-config.json",
            "--key", "handoff-config", "--workspace", fixture.ROOT,
            "--connection", "codex", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted"
        handoff_session = configured["answer"]["session"]
        fixture.message(state, stop_store, "handoff-message", handoff_session, "do not launch")
        handoff.wait()
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            assert not lock_available(lock), "authenticated handoff released its credential lease early"
        stopped = fixture.command(
            "session", "stop", "--store", stop_store, "--record", state / "handoff-stop.json",
            "--key", "handoff-stop", "--session", handoff_session,
        )
        assert stopped["answer"]["status"] == "accepted"
        handoff.release()
        fixture.wait_for(lambda: bash.execution_custody_idle(stop_store, handoff_session),
                         "stopped authenticated handoff custody", timeout=10)
        assert len(endpoint.requests) == 4, "stopped authenticated handoff launched a model request"
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            fixture.wait_for(lambda: lock_available(lock), "credential lease release after stopped handoff")

        schema = state / "unsupported-schema.json"
        schema.write_text('{"type":"object"}')
        configured = fixture.command(
            "session", "configure", "--store", stop_store,
            "--record", state / "schema-config.json", "--key", "schema-config",
            "--workspace", fixture.ROOT, "--connection", "codex",
            "--model", "gpt-6-sol", "--tools", "none", "--output-schema", schema,
        )
        assert configured["answer"]["status"] == "accepted"
        schema_session = configured["answer"]["session"]
        fixture.message(state, stop_store, "schema", schema_session, "unsupported managed request")
        rejected = fixture.wait_for(
            lambda: (value := fixture.observe(stop_store, "schema")).get("result", {}).get("code") and value,
            "schema rejected before managed dispatch",
        )
        assert rejected["result"]["code"] == "unsupported_output_schema_route", rejected
        assert len(endpoint.requests) == 4
        fixture.stop_host(host)
        handoff.close()
        host = start(stop_store, url)
        diagnostics = None
        expected_agent = expected_user_agent()
        mismatches = []
        for index, model in enumerate(("gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-astra",
                                       "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5")):
            effort, trigger = start_effort(model), str(compaction_trigger("codex", model))
            key = f"envelope-{index}"
            with endpoint.lock:
                endpoint.responses.append(fixture.sse_answer(key, key + "-r", key + "-m", key)[0])
            configured = fixture.command(
                "session", "configure", "--store", stop_store, "--record", state / f"{key}-config.json",
                "--key", key + "-config", "--workspace", fixture.ROOT,
                "--connection", "codex", "--model", model, "--tools", "bash" if index % 2 else "none",
            )
            assert configured["answer"]["status"] == "accepted", configured
            selected = configured["answer"]["session"]
            settings = fixture.command("session", "inspect", "--store", stop_store, "--session", selected)["session"]
            if model == "gpt-5.5":
                rejected = fixture.command(
                    "session", "configure", "--store", stop_store, "--session", selected,
                    "--record", state / "effort-unsupported-max.json", "--key", "effort-unsupported-max",
                    "--reasoning-effort", "max", expect=3,
                )
                assert rejected["answer"]["status"] == "rejected", rejected
                assert fixture.command("session", "inspect", "--store", stop_store, "--session", selected)["session"] == settings
            fixture.message(state, stop_store, key, selected, key)
            observation, answer, _ = fixture.wait_for_result_release(stop_store, key, selected, time.monotonic() + 20)
            assert observation["result"]["status"] == "completed" and answer == key.encode(), observation
            request = json.loads(endpoint.requests[4 + index])
            assert request["model"] == model, request
            if settings["compaction_trigger"] != trigger or settings["output_reservation"] != str(DEFAULTS.output_reservation):
                mismatches.append((model, "compaction defaults", settings["compaction_trigger"], settings["output_reservation"]))
            if settings["reasoning_effort"] != effort or settings["reasoning_effort_override"] != effort:
                mismatches.append((model, "effort settings", settings["reasoning_effort"], settings["reasoning_effort_override"]))
            if request.get("reasoning") != {"effort": effort}:
                mismatches.append((model, "reasoning", request.get("reasoning")))
            if request.get("text") != {"verbosity": "low"}:
                mismatches.append((model, "text", request.get("text")))
            if request.get("parallel_tool_calls") is not True:
                mismatches.append((model, "parallel_tool_calls", request.get("parallel_tool_calls")))
            if endpoint.user_agents[4 + index] != expected_agent:
                mismatches.append((model, "User-Agent", endpoint.user_agents[4 + index], expected_agent))
        assert len(endpoint.requests) == 13, endpoint.requests
        assert not mismatches, mismatches
        for index, effort in enumerate(("none", "low", "medium", "high", "xhigh", "max")):
            key = f"unlisted-effort-{effort}"
            response = (fixture.ResponseSpec(b'{"error":{"message":"unsupported effort"}}', {}, 400)
                        if effort == "max" else fixture.sse_answer(key, key + "-r", key + "-m", key)[0])
            with endpoint.lock:
                endpoint.responses.append(response)
            configured = fixture.command(
                "session", "configure", "--store", stop_store, "--record", state / f"{key}-config.json",
                "--key", key + "-config", "--workspace", fixture.ROOT, "--connection", "codex",
                "--model", "unlisted-effort-model", "--tools", "none", "--reasoning-effort", effort,
            )
            assert configured["answer"]["status"] == "accepted", configured
            selected = configured["answer"]["session"]
            settings = fixture.command("session", "inspect", "--store", stop_store, "--session", selected)["session"]
            assert settings["reasoning_effort"] == settings["reasoning_effort_override"] == effort, settings
            fixture.message(state, stop_store, key, selected, key)
            observed = fixture.wait_for(
                lambda: (value if (value := fixture.observe(stop_store, key)).get("result") else None), key)
            if effort == "max":
                assert observed["result"]["code"] == "provider_http_400", observed
            else:
                assert observed["result"]["status"] == "completed", observed
                assert fixture.read_result(stop_store, key) == key.encode()
            assert len(endpoint.requests) == 14 + index, endpoint.requests
            request = json.loads(endpoint.requests[-1])
            assert request["model"] == "unlisted-effort-model" and request["reasoning"] == {"effort": effort}, request
        print("unlisted effort passed: all grammar values forwarded, provider refusal preserved without fallback or resend")
        print(f"codex request envelopes passed: nine exact model IDs, client default effort, ChatGPT compaction/reservation defaults, low verbosity, explicit parallel calls, User-Agent={expected_agent}")
        print("codex synthetic managed journey passed: approved effect once, private continuation, fresh Host, post-restart dispatch, no authentication resend, stopped authentication/handoff and unsupported settings never launch")
        complete = True
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for dispose in (lambda: fixture.stop_host(host) if host is not None else None,
                        lambda: handoff.close() if handoff is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        if thread.is_alive():
            errors.append(AssertionError("Codex endpoint thread did not retire"))
        if complete and incoming_error is None and not errors:
            shutil.rmtree(state)
        else:
            retain_failure_state("Codex fixture failure state", state)
        if errors:
            if incoming_error is None:
                raise errors[0]
            incoming_error.add_note("Codex cleanup failed: " + ", ".join(type(error).__name__ for error in errors))


def turn_state_proposal(command, state):
    reasoning = {"type": "reasoning", "id": "turn-reasoning", "summary": [{"type": "summary_text", "text": "visible"}],
                 "content": [{"type": "reasoning_text", "text": "private-reasoning-text"}],
                 "encrypted_content": "turn-private-continuation"}
    call = {"type": "function_call", "id": "turn-call-item", "status": "completed", "name": "bash", "call_id": "turn-call",
            "arguments": json.dumps({"cmd": command, "timeout_ms": None, "description": "Run turn-state command"}, separators=(",", ":"))}
    body = fixture.encode_sse([
        {"type": "response.output_item.added", "output_index": 0, "item": {"type": "reasoning", "id": reasoning["id"]}},
        {"type": "response.output_item.done", "output_index": 0, "item": reasoning},
        {"type": "response.output_item.added", "output_index": 1, "item": {"type": "function_call", "id": call["id"]}},
        {"type": "response.output_item.done", "output_index": 1, "item": call},
        {"type": "response.completed", "response": {"id": "turn-calls", "status": "completed", "output": [reasoning, call]}},
    ])
    return fixture.ResponseSpec(body, {"x-codex-turn-state": state})


def turn_state_answer(key, state):
    headers = {} if state is None else {"x-codex-turn-state": state}
    return fixture.ResponseSpec(fixture.sse_answer(key, key + "-r", key + "-m", key)[0], headers)


def turn_state_journey():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-codex-turn.")).resolve()
    credential_dir = state / "private"
    credential_dir.mkdir(mode=0o700)
    credential_file = credential_dir / "codex.json"
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential_file)
    credentials(credential_file)
    endpoint = fixture.SuccessEndpoint([
        fixture.ResponseSpec(b"temporary", {"x-codex-turn-state": "error-state"}, 503),
        turn_state_proposal("printf a-witness", "sticky-a"),
        fixture.ResponseSpec(b"temporary", {"x-codex-turn-state": "error-later"}, 503),
        turn_state_answer("turn-a-answer", "sticky-a-replaced"),
        turn_state_answer("turn-b-answer", "sticky-b"),
        turn_state_proposal("printf c-witness", "sticky-c"),
        turn_state_answer("turn-c-answer", None),
    ])
    endpoint.RequestHandlerClass = ManagedHandler
    endpoint.header_observations = []
    endpoint.user_agents = []
    endpoint.turn_states = []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    store = state / "store"
    host = None
    complete = False
    try:
        host = start(store, url, "--test-retry-waits-ms", "1,1,1")
        sessions = []
        for key in ("turn-config", "turn-c-config"):
            configured = fixture.command(
                "session", "configure", "--store", store, "--record", state / f"{key}.json",
                "--key", key, "--workspace", fixture.ROOT,
                "--connection", "codex", "--model", "gpt-6-sol", "--tools", "bash", "--permission-mode", "ask",
            )
            assert configured["answer"]["status"] == "accepted", configured
            sessions.append(configured["answer"]["session"])
        session, other = sessions
        fixture.message(state, store, "turn-a", session, "turn a")
        action = fixture.wait_for(lambda: bash.action_for(store, session), "turn A proposal")
        bash.allow(state, store, "turn-a-allow", session, action["action"])
        fixture.wait_for(lambda: fixture.completed_observation(store, "turn-a"), "turn A answer")
        assert fixture.read_result(store, "turn-a") == b"turn-a-answer"
        fixture.message(state, store, "turn-b", session, "turn b")
        fixture.wait_for(lambda: fixture.completed_observation(store, "turn-b"), "turn B answer")
        assert endpoint.turn_states == [[], [], ["sticky-a"], ["sticky-a"], []], endpoint.turn_states
        continuation = json.loads(endpoint.requests[3])
        assert continuation == json.loads(endpoint.requests[2]), "retry changed the continuation request"
        reasoning = [item for item in continuation["input"] if item.get("type") == "reasoning"]
        assert reasoning == [{"type": "reasoning", "id": "turn-reasoning", "summary": [{"type": "summary_text", "text": "visible"}],
                              "encrypted_content": "turn-private-continuation"}], reasoning
        assert b"private-reasoning-text" not in b"".join(endpoint.requests)

        fixture.message(state, store, "turn-c", other, "turn c")
        action = fixture.wait_for(lambda: bash.action_for(store, other), "turn C proposal")
        fixture.stop_host(host)
        host = None
        assert not bash.rows(store, "SELECT 1 FROM content WHERE instr(payload, ?) > 0", (b"sticky-",))
        assert bash.rows(store, "SELECT private FROM content WHERE instr(payload, ?) > 0", (b"private-reasoning-text",)), "saved reasoning text evidence lost"
        host = start(store, url, "--test-retry-waits-ms", "1,1,1")
        bash.allow(state, store, "turn-c-allow", other, action["action"])
        fixture.wait_for(lambda: fixture.completed_observation(store, "turn-c"), "turn C answer")
        assert endpoint.turn_states[5:] == [[], []], endpoint.turn_states
        assert len(endpoint.requests) == 7
        print("codex turn state passed: first successful value per Turn, replayed on retry and continuation, absent across Turns and Hosts; reasoning text never replayed")
        complete = True
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for dispose in (lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        if complete and incoming_error is None and not errors:
            shutil.rmtree(state)
        else:
            retain_failure_state("Codex turn-state failure state", state)
        if errors and incoming_error is None:
            raise errors[0]


def forced_refresh_journey():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-codex-refresh.")).resolve()
    credential_dir = state / "private"
    credential_dir.mkdir(mode=0o700)
    credential_file = credential_dir / "codex.json"
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential_file)
    credentials(credential_file)
    endpoint = fixture.SuccessEndpoint([
        fixture.ResponseSpec(b"stale token", {"X-Request-Id": "stale-1"}, 401),
        fixture.sse_answer("refreshed", "refreshed-r", "refreshed-m", "refreshed answer")[0],
        fixture.ResponseSpec(b"stale token", {"X-Request-Id": "stale-2"}, 401),
        fixture.ResponseSpec(b"still rejected", {"X-Request-Id": "stale-3"}, 401),
    ])
    endpoint.RequestHandlerClass = ManagedHandler
    endpoint.header_observations = []
    endpoint.user_agents = []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    store = state / "store"
    host = None
    complete = False
    try:
        host = start(store, url)
        configured = fixture.command(
            "session", "configure", "--store", store, "--record", state / "configure.json",
            "--key", "configure", "--workspace", fixture.ROOT,
            "--connection", "codex", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]

        fixture.message(state, store, "stale", session, "refresh a stale token")
        answered = fixture.wait_for(lambda: fixture.completed_observation(store, "stale"), "answer after forced refresh")
        assert answered["binding"]["attempt"] == "2", answered
        assert fixture.read_result(store, "stale") == b"refreshed answer"
        assert len(endpoint.requests) == 2
        assert endpoint.requests[0] == endpoint.requests[1], "replacement changed the model request"
        assert credential_facts(credential_file) == ("2", "ready")

        fixture.message(state, store, "rejected-twice", session, "reject twice")
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "rejected-twice")).get("result", {}).get("code") and value,
            "second rejection after forced refresh",
        )
        assert failure["result"]["code"] == "provider_http_401", failure
        time.sleep(0.4)
        assert len(endpoint.requests) == 4, "a second 401 refreshed or resent again"
        assert credential_facts(credential_file) == ("3", "ready"), "one Operation refreshed more than once"

        pending_release = threading.Event()
        with endpoint.lock:
            endpoint.responses.append((fixture.ResponseSpec(b"stale token", {}, 401), pending_release))
        fixture.message(state, store, "login-required", session, "login required")
        fixture.wait_for(lambda: len(endpoint.requests) == 5, "request before pending refresh")
        credentials(credential_file, state="refresh_pending", generation=3)
        pending_release.set()
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "login-required")).get("result", {}).get("code") and value,
            "authentication failure after pending refresh",
        )
        assert failure["result"]["code"] == "provider_sign_in_required", failure
        time.sleep(0.4)
        assert len(endpoint.requests) == 5, "a login-required refresh resent a model request"
        assert credential_facts(credential_file) == ("3", "refresh_pending")

        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            os_semantics.take_lock(lock)
            credentials(credential_file, generation=4)
        newer_release = threading.Event()
        with endpoint.lock:
            endpoint.responses.append((fixture.ResponseSpec(b"stale token", {"X-Request-Id": "newer-pending"}, 401), newer_release))
        fixture.message(state, store, "newer-pending", session, "another owner claimed refresh")
        fixture.wait_for(lambda: len(endpoint.requests) == 6, "request before newer pending generation")
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            os_semantics.take_lock(lock)
            credentials(credential_file, state="refresh_pending", generation=5)
            newer_record = credential_file.read_bytes()
        newer_release.set()
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "newer-pending")).get("result", {}).get("code") and value,
            "answered rejection with newer pending generation",
        )
        assert failure["result"]["code"] == "provider_http_401", failure
        operation = fixture.command("session", "inspect", "--store", store, "--session", session,
                                    "--profile", "full")["full"]["model_operations"][-1]
        assert operation["request_id"] == "newer-pending", operation
        time.sleep(0.4)
        assert len(endpoint.requests) == 6, "a newer pending generation resent a model request"
        assert credential_file.read_bytes() == newer_record, "a stale claimant changed the newer credentials"
        assert all(bearer == "Bearer " + ACCESS and account == ACCOUNT
                   for _, bearer, account, _, _ in endpoint.header_observations)
        print("codex forced refresh passed: one refresh and replacement, second 401 and login-required refresh fail without resend; newer pending generation preserves answered 401/correlation and credentials")
        complete = True
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for dispose in (lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        if complete and incoming_error is None and not errors:
            shutil.rmtree(state)
        else:
            retain_failure_state("Codex forced refresh failure state", state)
        if errors and incoming_error is None:
            raise errors[0]


def openai_journey():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-openai.")).resolve()
    private = state / "private"
    private.mkdir(mode=0o700)
    credential_file = private / "codex.json"
    key_file = private / "openai.key"
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential_file)
    os.environ["RUI_OPENAI_KEY_FILE"] = str(key_file)
    credentials(credential_file)
    answer = fixture.sse_answer("same", "same-r", "same-m", "same answer")[0]
    endpoint = fixture.SuccessEndpoint([], {
        "same turn": answer,
        "rejected": fixture.ResponseSpec(b"invalid api key", {"X-Request-Id": "key-rejected"}, 401),
    })
    endpoint.RequestHandlerClass = ManagedHandler
    endpoint.header_observations = []
    endpoint.user_agents = []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    store = state / "store"
    host = None
    complete = False
    try:
        for serve in (["--set", f"providers.openai.endpoint={url}"], ["--set", 'providers={"openai":{}}']):
            refused = subprocess.run([fixture.RUI, "host", "serve", "--store", store, *serve],
                                     capture_output=True, text=True, timeout=15)
            assert refused.returncode != 0 and "no OpenAI API key" in refused.stderr, refused
            assert not refused.stdout.startswith("ready "), refused.stdout
        key_file.write_text(OPENAI_KEY + "\n")
        key_file.chmod(0o644)
        refused = subprocess.run([fixture.RUI, "host", "serve", "--store", store, "--set", f"providers.openai.endpoint={url}"],
                                 capture_output=True, text=True, timeout=15)
        assert refused.returncode != 0, refused
        key_file.chmod(0o600)

        host = start(store, url, "--set", f"providers.openai.endpoint={url}")
        status = fixture.command("host", "status", "--store", store)
        assert host_process.capability_routes(status["capabilities"]) == {"codex": "chatgpt_device", "openai": "key_file", "chatgpt": "unserved"}, status
        sessions = {}
        for provider in ("codex", "openai"):
            configured = fixture.command(
                "session", "configure", "--store", store, "--record", state / f"configure-{provider}.json",
                "--key", f"configure-{provider}", "--workspace", fixture.ROOT,
                "--connection", provider, "--model", "gpt-6.1-sol", "--tools", "none",
            )
            assert configured["answer"]["status"] == "accepted", configured
            sessions[provider] = configured["answer"]["session"]
            settings = fixture.command("session", "inspect", "--store", store, "--session", sessions[provider])["session"]
            expected_trigger = str(compaction_trigger(provider, "gpt-6.1-sol"))
            assert settings["compaction_trigger"] == settings["compaction_trigger_override"] == expected_trigger, settings
            assert settings["reasoning_effort"] == settings["reasoning_effort_override"] == start_effort("gpt-6.1-sol"), settings
            fixture.message(state, store, f"same-{provider}", sessions[provider], "same turn")
            fixture.wait_for(lambda: fixture.completed_observation(store, f"same-{provider}"), f"{provider} answer")
            assert fixture.read_result(store, f"same-{provider}") == b"same answer"
        assert len(endpoint.requests) == 2
        codex_body, openai_body = (json.loads(body) for body in endpoint.requests)
        codex_instructions = fixture.request_system_prompt(codex_body).replace(sessions["codex"], "SESSION")
        assert codex_instructions == fixture.request_system_prompt(openai_body).replace(sessions["openai"], "SESSION")
        for body in (codex_body, openai_body):
            if "instructions" in body:
                del body["instructions"]
            else:
                body["input"] = body["input"][1:]
        assert codex_body == openai_body, (codex_body, openai_body)
        (codex_path, codex_bearer, codex_account, codex_affinity, _), (path, bearer, account, affinity, originator) = endpoint.header_observations
        assert codex_bearer == "Bearer " + ACCESS and codex_account == ACCOUNT
        assert path == "/responses" and bearer == "Bearer " + OPENAI_KEY and account is None and originator == "rui"
        assert re.fullmatch(r"[0-9a-f]{32}", affinity) and affinity != codex_affinity
        assert endpoint.user_agents[1] == expected_user_agent()

        fixture.message(state, store, "rejected", sessions["openai"], "rejected")
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "rejected")).get("result", {}).get("code") and value,
            "API key rejection",
        )
        assert failure["result"]["code"] == "provider_api_key_rejected", failure
        assert len(endpoint.requests) == 3, "a rejected API key was resent"
        assert key_file.read_text() == OPENAI_KEY + "\n"
        fixture.stop_host(host)
        host = None
        assert not bash.rows(store, "SELECT 1 FROM content WHERE instr(payload, ?) > 0", (OPENAI_KEY.encode(),))
        print("openai provider passed: Codex and OpenAI on one Host, bearer key with no account, same body, 401 final, no start without a key")
        complete = True
    finally:
        incoming_error = sys.exc_info()[1]
        errors = []
        for dispose in (lambda: fixture.stop_host(host) if host is not None else None,
                        endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5)):
            try:
                dispose()
            except BaseException as error:
                errors.append(error)
        del os.environ["RUI_OPENAI_KEY_FILE"]
        if complete and incoming_error is None and not errors:
            shutil.rmtree(state)
        else:
            retain_failure_state("OpenAI provider failure state", state)
        if errors and incoming_error is None:
            raise errors[0]


if __name__ == "__main__":
    host_process.enter()
    run()
    turn_state_journey()
    forced_refresh_journey()
    openai_journey()
