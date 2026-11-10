#!/usr/bin/env python3
"""Fresh-Host Bash recovery cuts prove durable facts never restore a permit."""

import json
import os
import pathlib
import signal
import sys
import tempfile
import threading

import bash_fixture as bash
import model_fixture as fixture
import human_cli_fixture as human
import host_process
from terminal_process import terminal_process
from bash_fixture import finish_case, start_case


RUI = pathlib.Path(sys.argv[1]).resolve()
fixture.RUI = RUI


def assert_continuation(endpoint, name, result, stdin="x"):
    assert len(endpoint.requests) == 2, endpoint.requests
    first, continuation = map(json.loads, endpoint.requests)
    assert [item["content"][0]["text"] for item in first["input"] if item.get("role") == "user"] == ["run"]
    calls = [item for item in continuation["input"] if item.get("type") == "function_call"]
    assert len(calls) == 1 and calls[0]["call_id"] == f"{name}-call", calls
    assert json.loads(calls[0]["arguments"])["stdin"] == stdin, "recovery changed the canonical input"
    outputs = [item for item in continuation["input"] if item.get("type") == "function_call_output"]
    assert outputs == [{"type": "function_call_output", "call_id": f"{name}-call", "output": result}], outputs
    assert [item["content"][0]["text"] for item in continuation["input"] if item.get("role") == "user"] == ["run"]


def prove_lost_bash_permit_becomes_indeterminate(state):
    case = start_case(
        state,
        "attempt-before-launch",
        "action_attempt_admitted",
        lambda marker: f"cat >> {marker}",
    )
    store, marker, endpoint, thread, keeper, original_host, original_diagnostics, session = case
    recovered_host = None
    try:
        original_diagnostics.wait("action_attempt_admitted", action="1")
        crash = fixture.crash_host(original_host, state, "attempt-before-launch-crash", original_diagnostics)
        assert crash["returncode"] == -signal.SIGKILL and not marker.exists(), crash
        recovered_host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        fixture.wait_for(lambda: bash.resolution(store, session) == "indeterminate", "indeterminate Action")
        result = bash.result_text(store, session)
        fixture.wait_for(lambda: fixture.completed_observation(store, "attempt-before-launch-message"), "continuation")
        assert not marker.exists()
        assert_continuation(endpoint, "attempt-before-launch", result)
    finally:
        finish_case(original_host, recovered_host, keeper, endpoint, thread)


def prove_effect_without_result_becomes_indeterminate(state):
    marker = state / "effect-before-result-effect"
    case = start_case(state, "effect-before-result", "action_result_ready", f"cat >> {marker}")
    store, _, endpoint, thread, keeper, original_host, original_diagnostics, session = case
    recovered_host = None
    continuation_release = threading.Event()
    try:
        original_diagnostics.wait("action_result_ready", action="1")
        assert marker.read_text() == "x"
        crash = fixture.crash_host(original_host, state, "effect-before-result-crash", original_diagnostics)
        assert crash["returncode"] == -signal.SIGKILL, crash
        endpoint.responses[0] = (endpoint.responses[0], continuation_release)
        recovered_host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        fixture.wait_for(lambda: bash.resolution(store, session) == "indeterminate", "indeterminate effect")
        result = bash.result_text(store, session)
        home = state / "effect-before-result-home"
        home.mkdir()
        with terminal_process([str(RUI), "session", "resume", "--store", str(store), "--", session],
            env={**os.environ, "HOME": str(home)},
        ) as (entered, master):
            human.read_terminal(master, "› ")
            status = human.terminal_step(master, "/status", " Status · ", composer=True)
            assert "Indeterminate Action: 1" in status, status
            assert "The command may have run; Rui did not replay it." in status, status
            human.terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        continuation_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, "effect-before-result-message"), "continuation")
        assert marker.read_text() == "x"
        assert_continuation(endpoint, "effect-before-result", result)
    finally:
        continuation_release.set()
        finish_case(original_host, recovered_host, keeper, endpoint, thread)


def prove_committed_bash_result_survives_restart(state):
    marker = state / "result-after-commit-effect"
    case = start_case(state, "result-after-commit", "action_result_committed", f"cat >> {marker}")
    store, _, endpoint, thread, keeper, original_host, original_diagnostics, session = case
    recovered_host = None
    try:
        original_diagnostics.wait("action_result_committed", action="1")
        original_result = bash.result_text(store, session)
        assert marker.read_text() == "x" and bash.resolution(store, session) == "succeeded"
        crash = fixture.crash_host(original_host, state, "result-after-commit-crash", original_diagnostics)
        assert crash["returncode"] == -signal.SIGKILL, crash
        recovered_host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        fixture.wait_for(lambda: fixture.completed_observation(store, "result-after-commit-message"), "continuation")
        result = bash.result_text(store, session)
        assert result == original_result
        assert fixture.read_result(store, "result-after-commit-message") == b"result-after-commit completed"
        assert bash.resolution(store, session) == "succeeded" and marker.read_text() == "x"
        assert_continuation(endpoint, "result-after-commit", result)
    finally:
        finish_case(original_host, recovered_host, keeper, endpoint, thread)


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-bash-recovery."))
    prove_lost_bash_permit_becomes_indeterminate(state)
    prove_effect_without_result_becomes_indeterminate(state)
    prove_committed_bash_result_survives_restart(state)
    print(json.dumps({"bash_recovery": "passed"}, sort_keys=True))


if __name__ == "__main__":
    host_process.enter()
    main()
