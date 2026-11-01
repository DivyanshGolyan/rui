#!/usr/bin/env python3
"""Public-caller managed-route journey with only fixed, synthetic credentials."""

import json
import fcntl
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

import bash_integration as bash
import model_fixture as fixture
import host_process
from host_process import HostDiagnostics, retain_failure_state, start_ready_process


ACCESS = "e30.eyJleHAiOjQxMDI0NDQ4MDB9.c2ln"
ID = "e30.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJydWktdGVzdC1hY2NvdW50In0.c2ln"
FEDRAMP_ID = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoicnVpLXRlc3QtYWNjb3VudCIsImNoYXRncHRfYWNjb3VudF9pc19mZWRyYW1wIjp0cnVlfX0.c2ln"
ACCOUNT = "rui-test-account"


def expected_user_agent():
    if not (fixture.ROOT / ".git").exists() or shutil.which("git") is None:
        return "rui/unknown"
    identity = subprocess.run(
        ["git", "rev-parse", "--show-toplevel", "HEAD"], cwd=fixture.ROOT,
        capture_output=True, text=True,
    )
    lines = identity.stdout.splitlines()
    revision = lines[1] if (identity.returncode == 0 and len(lines) == 2
                           and pathlib.Path(lines[0]).resolve() == fixture.ROOT
                           and re.fullmatch(r"[0-9a-f]{40}", lines[1])) else "unknown"
    return "rui/" + revision


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


def credentials(path, *, state="ready", access=ACCESS, fedramp=False, generation=1):
    path.write_text(
        "version=3\ngeneration=" + str(generation) + "\naccount_id=" + ACCOUNT +
        "\nfedramp=" + str(int(fedramp)) + "\nid_token=" + (FEDRAMP_ID if fedramp else ID) +
        "\naccess_token=" + access + "\nrefresh_token=synthetic-not-real\n"
        "expires_at=4102444800\nrefreshed_at=1750000000\nstate=" + state + "\n"
    )
    path.chmod(0o600)


def credential_facts(path):
    facts = dict(line.split("=", 1) for line in path.read_text().splitlines())
    return facts["generation"], facts["state"]


def lock_available(lock):
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return False
    fcntl.flock(lock, fcntl.LOCK_UN)
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


def start(store, endpoint, *extra):
    host, _ = start_ready_process(
        [fixture.RUI, "host", "serve", "--store", store, "--active-capacity", "2",
         "--test-codex-fixture-endpoint", endpoint, *extra],
        required_fields={"execution": "enabled", "nghttp2": "1.70.0"},
        observations="managed" if "--test-phase-trace" in extra else None,
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
    complete = False
    try:
        # Missing and uncertain credentials must never reach model transport.
        credentials(credential_file, state="refresh_pending")
        host = start(store, url)
        configured = fixture.command(
            "session", "configure", "--store", store, "--record", state / "configure.json",
            "--key", "configure", "--workspace", fixture.ROOT,
            "--provider", "codex", "--model", "gpt-6-sol", "--tools", "bash",
            "--permission-mode", "ask", "--instructions", "-",
            input="Use the approved tool result.",
        )
        assert configured["answer"]["status"] == "accepted"
        session = configured["answer"]["session"]
        fixture.message(state, store, "pending-message", session, "run the proof")
        pending = fixture.wait_for(lambda: fixture.observe(store, "pending-message").get("result"), "authentication failure")
        assert pending["code"] == "provider_authentication_failed", pending
        assert not endpoint.requests, "pending refresh reached transport"
        fixture.stop_host(host)
        host = None

        # The fixture flag must reach credential selection: a real-looking
        # credential is refused before any request to the fixture endpoint.
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
        assert json.loads(endpoint.requests[0])["reasoning"] == {"effort": "medium"}
        configured = fixture.command(
            "session", "configure", "--store", store, "--session", session,
            "--record", state / "effort-high.json", "--key", "effort-high",
            "--reasoning-effort", "high",
        )
        assert configured["answer"]["status"] == "accepted", configured
        bash.allow(state, store, "allow", session, action["action"])
        fixture.wait_for(lambda: fixture.completed_observation(store, "message"), "managed answer")
        # The 12-byte tool stdout is optionally retained; custody, not the
        # retained full output, must be released before the crash cut.
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
        assert continuation["reasoning"] == {"effort": "high"}, continuation
        assert any(item.get("type") == "function_call_output" and item["call_id"] == "managed-call" and "tool-witness" in item["output"] for item in continuation["input"])
        assert any(item.get("type") == "reasoning" and item.get("encrypted_content") for item in continuation["input"])
        assert all(item.get("role") != "system" for item in continuation["input"])
        assert continuation["instructions"] == fixture.model_instructions(fixture.ROOT, "Use the approved tool result.", store=store, session=session)

        fixture.stop_host(host)
        # The Host holds its Store exclusively; inspect private rows between Hosts.
        assert bash.rows(store, "SELECT private FROM content WHERE instr(payload, ?) > 0", (b"synthetic-private-reasoning",)) == [(1,)]
        assert not bash.rows(store, "SELECT private FROM content WHERE instr(payload, ?) > 0", (ACCESS.encode(),))
        host = start(store, url)
        assert fixture.retry_message(state, store, "message")["answer"]["replayed"] is True
        assert fixture.read_result(store, "message") == b"managed answer"
        assert len(endpoint.requests) == 2 and proof.read_text() == "once\n"
        settings = fixture.command("session", "inspect", "--store", store, "--session", session)["session"]
        assert settings["reasoning_effort"] == settings["reasoning_effort_override"] == "high", settings
        for effort in ("none", "ultra"):
            rejected = fixture.command(
                "session", "configure", "--store", store, "--session", session,
                "--record", state / f"effort-{effort}.json", "--key", f"effort-{effort}",
                "--reasoning-effort", effort, "--permission-mode", "bypass", expect=1,
            )
            assert rejected["answer"]["status"] == "rejected", rejected
            unchanged = fixture.command("session", "inspect", "--store", store, "--session", session)["session"]
            assert unchanged == settings and len(endpoint.requests) == 2, unchanged
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
        assert later["reasoning"] == {"effort": "medium"}, later
        assert any(item.get("type") == "function_call_output" and item["call_id"] == "managed-call" for item in later["input"])
        # Another owner commits a newer credential generation while this
        # Attempt is in flight: the rejected lease is not refreshed and the
        # Operation fails as before, with no replacement request.
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

        # Block the worker on the same stable file lock used by login while
        # a public stop is accepted. Releasing it must not revive dispatch.
        stop_store = state / "stop-store"
        host = start(stop_store, url, "--test-phase-trace")
        diagnostics = HostDiagnostics(host)
        configured = fixture.command(
            "session", "configure", "--store", stop_store, "--record", state / "stop-config.json",
            "--key", "stop-config", "--workspace", fixture.ROOT,
            "--provider", "codex", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted"
        stopped_session = configured["answer"]["session"]
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
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

        # The credential is already selected and the transfer prepared. A
        # committed stop before the final handoff must still suppress POST.
        host = start(stop_store, url, "--test-phase-trace", "--test-before-launch-delay-ms", "1500")
        diagnostics = HostDiagnostics(host)
        configured = fixture.command(
            "session", "configure", "--store", stop_store, "--record", state / "handoff-config.json",
            "--key", "handoff-config", "--workspace", fixture.ROOT,
            "--provider", "codex", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted"
        handoff_session = configured["answer"]["session"]
        fixture.message(state, stop_store, "handoff-message", handoff_session, "do not launch")
        diagnostics.wait("prepared_before_handoff", timeout=10)
        # Header construction borrows the worker's lease; its stable lock
        # must remain owned through the final launch decision, even if a stop
        # wins that handoff. A copied/early-released owner would allow this.
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            assert not lock_available(lock), "authenticated handoff released its credential lease early"
        stopped = fixture.command(
            "session", "stop", "--store", stop_store, "--record", state / "handoff-stop.json",
            "--key", "handoff-stop", "--session", handoff_session,
        )
        assert stopped["answer"]["status"] == "accepted"
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
            "--workspace", fixture.ROOT, "--provider", "codex",
            "--model", "gpt-6-sol", "--tools", "none", "--output-schema", schema,
        )
        assert configured["answer"]["status"] == "accepted"
        schema_session = configured["answer"]["session"]
        fixture.message(state, stop_store, "schema", schema_session, "unsupported managed request")
        rejected = fixture.wait_for(
            lambda: (value := fixture.observe(stop_store, "schema")).get("result", {}).get("code") and value,
            "schema rejected before managed dispatch",
        )
        assert rejected["result"]["code"] == "unsupported_codex_configuration", rejected
        assert len(endpoint.requests) == 4
        fixture.stop_host(host)
        host = start(stop_store, url)
        diagnostics = None
        # Independent catalog expectations, exercised through real managed POSTs
        # and public effective settings rather than capability helpers alone.
        expected_agent = expected_user_agent()
        mismatches = []
        for index, (model, effort) in enumerate((
            ("gpt-6-luna", "medium"), ("gpt-6.1-sol", "low"),
            ("gpt-6-sol", "medium"), ("gpt-6-astra", "low"),
            ("gpt-5.6-sol", "low"), ("gpt-5.6-terra", "medium"),
            ("gpt-5.6-luna", "medium"), ("gpt-5.5", "medium"),
        )):
            key = f"envelope-{index}"
            with endpoint.lock:
                endpoint.responses.append(fixture.sse_answer(key, key + "-r", key + "-m", key)[0])
            configured = fixture.command(
                "session", "configure", "--store", stop_store, "--record", state / f"{key}-config.json",
                "--key", key + "-config", "--workspace", fixture.ROOT,
                "--provider", "codex", "--model", model, "--tools", "bash" if index % 2 else "none",
            )
            assert configured["answer"]["status"] == "accepted", configured
            selected = configured["answer"]["session"]
            settings = fixture.command("session", "inspect", "--store", stop_store, "--session", selected)["session"]
            if model == "gpt-5.5":
                rejected = fixture.command(
                    "session", "configure", "--store", stop_store, "--session", selected,
                    "--record", state / "effort-unsupported-max.json", "--key", "effort-unsupported-max",
                    "--reasoning-effort", "max", expect=1,
                )
                assert rejected["answer"]["status"] == "rejected", rejected
                assert fixture.command("session", "inspect", "--store", stop_store, "--session", selected)["session"] == settings
            fixture.message(state, stop_store, key, selected, key)
            observation, answer, _ = fixture.wait_for_result_release(stop_store, key, selected, time.monotonic() + 20)
            assert observation["result"]["status"] == "completed" and answer == key.encode(), observation
            request = json.loads(endpoint.requests[4 + index])
            assert request["model"] == model, request
            if settings["compaction_trigger"] != "244800" or settings["output_reservation"] != "0":
                mismatches.append((model, "compaction defaults", settings["compaction_trigger"], settings["output_reservation"]))
            if settings["reasoning_effort"] != effort or settings["reasoning_effort_override"] is not None:
                mismatches.append((model, "effort settings", settings["reasoning_effort"], settings["reasoning_effort_override"]))
            if request.get("reasoning") != {"effort": effort}:
                mismatches.append((model, "reasoning", request.get("reasoning")))
            if request.get("text") != {"verbosity": "low"}:
                mismatches.append((model, "text", request.get("text")))
            # Codex suppresses parallel calls on Responses-lite bindings even
            # when the catalog advertises supports_parallel_tool_calls=true.
            if request.get("parallel_tool_calls") is not (model == "gpt-5.5"):
                mismatches.append((model, "parallel_tool_calls", request.get("parallel_tool_calls")))
            if endpoint.user_agents[4 + index] != expected_agent:
                mismatches.append((model, "User-Agent", endpoint.user_agents[4 + index], expected_agent))
        assert len(endpoint.requests) == 12, endpoint.requests
        assert not mismatches, mismatches
        print(f"codex request envelopes passed: eight exact model IDs, catalog effort defaults, 244800/0 defaults, low verbosity, explicit parallel calls, User-Agent={expected_agent}")
        print("codex synthetic managed journey passed: approved effect once, private continuation, fresh Host, post-restart dispatch, no authentication resend, stopped authentication/handoff and unsupported settings never launch")
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
    # Private reasoning text is saved evidence; replay must omit it.
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
    """Codex sticky routing: one captured value per Turn, replayed on its
    retries and continuations, never sent to another Turn or a fresh Host."""
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-codex-turn.")).resolve()
    credential_dir = state / "private"
    credential_dir.mkdir(mode=0o700)
    credential_file = credential_dir / "codex.json"
    os.environ["RUI_CODEX_CREDENTIAL_FILE"] = str(credential_file)
    credentials(credential_file)
    endpoint = fixture.SuccessEndpoint([
        # Turn A: an error answer's value is not routing state; the retry
        # starts the Turn and the first successful value is kept.
        fixture.ResponseSpec(b"temporary", {"x-codex-turn-state": "error-state"}, 503),
        turn_state_proposal("printf a-witness", "sticky-a"),
        fixture.ResponseSpec(b"temporary", {"x-codex-turn-state": "error-later"}, 503),
        turn_state_answer("turn-a-answer", "sticky-a-replaced"),
        # Turn B in the same Session starts without Turn A's value.
        turn_state_answer("turn-b-answer", "sticky-b"),
        # Turn C's value dies with its Host; its continuation starts fresh.
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
                "--provider", "codex", "--model", "gpt-6-sol", "--tools", "bash", "--permission-mode", "ask",
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
        # Turn state is process memory: no Store row ever holds it.
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
    """A managed model 401 claims its Operation's one forced refresh at the
    rejected lease's unchanged generation and makes one replacement Attempt.
    A second 401 and a refresh that requires login fail without resend."""
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
            "--provider", "codex", "--model", "gpt-6-sol", "--tools", "none",
        )
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["answer"]["session"]

        # One stale-token 401: one forced refresh, one replacement Attempt.
        fixture.message(state, store, "stale", session, "refresh a stale token")
        answered = fixture.wait_for(lambda: fixture.completed_observation(store, "stale"), "answer after forced refresh")
        assert answered["processing"]["attempt"] == "2", answered
        assert fixture.read_result(store, "stale") == b"refreshed answer"
        assert len(endpoint.requests) == 2
        assert endpoint.requests[0] == endpoint.requests[1], "replacement changed the model request"
        assert credential_facts(credential_file) == ("2", "ready")

        # The refreshed credential is rejected again: the Operation has spent
        # its refresh, so it fails with the provider's answer and no resend.
        fixture.message(state, store, "rejected-twice", session, "reject twice")
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "rejected-twice")).get("result", {}).get("code") and value,
            "second rejection after forced refresh",
        )
        assert failure["result"]["code"] == "provider_http_401", failure
        time.sleep(0.4)
        assert len(endpoint.requests) == 4, "a second 401 refreshed or resent again"
        assert credential_facts(credential_file) == ("3", "ready"), "one Operation refreshed more than once"

        # A refresh that requires login fails as authentication, distinct
        # from the provider's 401, and sends no replacement.
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
        assert failure["result"]["code"] == "provider_authentication_failed", failure
        time.sleep(0.4)
        assert len(endpoint.requests) == 5, "a login-required refresh resent a model request"
        assert credential_facts(credential_file) == ("3", "refresh_pending")

        # A different owner advances the generation and then leaves it
        # pending. Preserve this Attempt's answered 401 and correlation,
        # rather than replacing them with that owner's login failure.
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            credentials(credential_file, generation=4)
        newer_release = threading.Event()
        with endpoint.lock:
            endpoint.responses.append((fixture.ResponseSpec(b"stale token", {"X-Request-Id": "newer-pending"}, 401), newer_release))
        fixture.message(state, store, "newer-pending", session, "another owner claimed refresh")
        fixture.wait_for(lambda: len(endpoint.requests) == 6, "request before newer pending generation")
        with open(credential_dir / ".codex.json.lock", "r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
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


OPENAI_KEY = "sk-synthetic-openai-key"


def openai_journey():
    """One Host serves Codex and an OpenAI API key side by side. The key goes
    out as a bearer with no ChatGPT account, the body matches a Codex
    Session's, a 401 is final, and a Host never starts openai without a key."""
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
        # No key: the Host refuses to start rather than serve openai unready.
        for serve in (["--test-openai-fixture-endpoint", url], ["--provider", "openai"]):
            refused = subprocess.run([fixture.RUI, "host", "serve", "--store", store, *serve],
                                     capture_output=True, text=True, timeout=15)
            assert refused.returncode != 0 and "no OpenAI API key" in refused.stderr, refused
            assert not refused.stdout.startswith("ready "), refused.stdout
        # The real endpoint takes the key only from an owner-only file.
        key_file.write_text(OPENAI_KEY + "\n")
        key_file.chmod(0o644)
        refused = subprocess.run([fixture.RUI, "host", "serve", "--store", store, "--test-openai-fixture-endpoint", url],
                                 capture_output=True, text=True, timeout=15)
        assert refused.returncode != 0, refused
        key_file.chmod(0o600)

        host = start(store, url, "--test-openai-fixture-endpoint", url)
        status = fixture.command("host", "status", "--store", store)
        assert status["capabilities"]["providers"] == {"codex": "chatgpt_device", "openai": "key_file"}, status
        sessions = {}
        for provider in ("codex", "openai"):
            configured = fixture.command(
                "session", "configure", "--store", store, "--record", state / f"configure-{provider}.json",
                "--key", f"configure-{provider}", "--workspace", fixture.ROOT,
                "--provider", provider, "--model", "gpt-6-sol", "--tools", "none",
            )
            assert configured["answer"]["status"] == "accepted", configured
            sessions[provider] = configured["answer"]["session"]
            fixture.message(state, store, f"same-{provider}", sessions[provider], "same turn")
            fixture.wait_for(lambda: fixture.completed_observation(store, f"same-{provider}"), f"{provider} answer")
            assert fixture.read_result(store, f"same-{provider}") == b"same answer"
        assert len(endpoint.requests) == 2
        codex_body, openai_body = (json.loads(body) for body in endpoint.requests)
        # The only difference is each Session's own reference in its context.
        codex_instructions = codex_body.pop("instructions").replace(sessions["codex"], "SESSION")
        assert codex_instructions == openai_body.pop("instructions").replace(sessions["openai"], "SESSION")
        assert codex_body == openai_body, (codex_body, openai_body)
        (codex_path, codex_bearer, codex_account, codex_affinity, _), (path, bearer, account, affinity, originator) = endpoint.header_observations
        assert codex_bearer == "Bearer " + ACCESS and codex_account == ACCOUNT
        assert path == "/responses" and bearer == "Bearer " + OPENAI_KEY and account is None and originator == "rui"
        assert re.fullmatch(r"[0-9a-f]{32}", affinity) and affinity != codex_affinity
        assert endpoint.user_agents[1] == expected_user_agent()

        # A rejected key is final: no refresh, no resend, the key untouched.
        fixture.message(state, store, "rejected", sessions["openai"], "rejected")
        failure = fixture.wait_for(
            lambda: (value := fixture.observe(store, "rejected")).get("result", {}).get("code") and value,
            "API key rejection",
        )
        assert failure["result"]["code"] == "provider_http_401", failure
        # A resend would come before the Operation settles, so none came.
        assert len(endpoint.requests) == 3, "a rejected API key was resent"
        assert key_file.read_text() == OPENAI_KEY + "\n"
        # The Host holds its Store exclusively; inspect rows after it stops.
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
