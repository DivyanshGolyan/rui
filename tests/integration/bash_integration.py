#!/usr/bin/env python3
import base64
import json
import os
import pathlib
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

import dispatch_integration as fixture
from host_process import HostDiagnostics


def detached_shell(command):
    encoded = base64.b64encode(command.encode()).decode()
    program = (
        "import base64,os,sys;"
        "os.setsid();"
        "os.execl('/bin/sh','sh','-c',base64.b64decode(sys.argv[1]).decode())"
    )
    return " ".join(
        (shlex.quote(sys.executable), "-c", shlex.quote(program), shlex.quote(encoded))
    )


def start_detached_shell(command, ready_path):
    ready = shlex.quote(str(ready_path))
    return f"{detached_shell(command)} & while [ ! -s {ready} ]; do :; done"


def configure(state, store, key, session, permission="ask"):
    result = fixture.command(
        "configure",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
        "--workspace",
        fixture.ROOT,
        "--model",
        "model-a",
        "--tools",
        "bash",
        "--permission-mode",
        permission,
    )
    assert result["answer"]["status"] == "accepted", result


def actions_for(store, session, count):
    report = fixture.command("inspect-session", "--store", store, "--session", session)
    unresolved = report["actions"]["unresolved"]
    return unresolved if len(unresolved) == count else None


def action_for(store, session):
    actions = actions_for(store, session, 1)
    return actions[0] if actions is not None else None


def action_rows_by_id(store, session):
    return {
        action["action"]: action
        for action in fixture.command(
            "inspect-session",
            "--store",
            store,
            "--session",
            session,
            "--profile",
            "full",
        )["full"]["actions"]
    }


def allow(state, store, key, session, action):
    result = fixture.command(
        "allow-action",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
        "--action",
        action,
    )
    assert result["answer"]["status"] == "accepted", result
    return result


def rows(store, sql, parameters=()):
    database = sqlite3.connect(store / "rui.sqlite3")
    try:
        return database.execute(sql, parameters).fetchall()
    finally:
        database.close()


def process_resources(process):
    process_root = pathlib.Path(f"/proc/{process.pid}")
    if not process_root.exists():
        return {"process_resources": "unavailable"}
    status = {}
    for line in (process_root / "status").read_text().splitlines():
        if line.startswith(("VmRSS:", "VmHWM:")):
            name, value, unit = line.split()
            assert unit == "kB", line
            status[name[:-1]] = int(value) * 1024
    status["descriptors"] = len(os.listdir(process_root / "fd"))
    return status


def scratch_resources(store):
    files = list((store / "scratch").iterdir())
    return {
        "files": len(files),
        "logical_bytes": sum(path.stat().st_size for path in files),
    }


def execution_idle(store, session):
    report = fixture.command("inspect-session", "--store", store, "--session", session)
    execution = report["execution"]
    return report if execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0" else None


def execution_custody_idle(store, session):
    report = fixture.command("inspect-session", "--store", store, "--session", session)
    return report if report["execution"]["custody_occupied"] == "0" else None


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def stop_traced_host(host, diagnostics):
    if host is not None:
        fixture.stop_host(host)
    if diagnostics is not None:
        diagnostics.close()
    return None, None


def resolution(store, session):
    report = fixture.command(
        "inspect-session", "--store", store, "--session", session, "--profile", "full"
    )
    actions = report["full"]["actions"]
    return actions[0]["resolution"] if len(actions) == 1 else None


def result_text(store, session):
    report = fixture.command(
        "inspect-session", "--store", store, "--session", session, "--profile", "full"
    )
    actions = report["full"]["actions"]
    assert len(actions) == 1 and actions[0]["resolution"] is not None, report
    return actions[0]["result"]["text"]


def add_exchange(responses, name, command, answer="continued", timeout_ms=None):
    arguments = {"cmd": command, "timeout_ms": timeout_ms}
    responses.append(
        fixture.sse_tool_calls(
            f"{name}-calls",
            [("bash", f"{name}-call", json.dumps(arguments, separators=(",", ":")))],
        )
    )
    responses.append(fixture.sse_answer(f"{name}-answer", f"{name}-reasoning", f"{name}-message", answer)[0])


def prove_reused_session(state):
    store = state / "reused-session-store"
    workspace = state / "reused-session-workspace"
    workspace.mkdir()
    cleanup_gate = workspace / "cleanup-gate"
    cleanup_gate.write_text("blocked")
    model_cleanup_gate = workspace / "model-cleanup-gate"
    retry_wait_ms = 500
    slow_release = workspace / "slow-release"
    settlement_order = workspace / "settlement-order"
    slow_command = (
        f"i=0; while [ ! -e {shlex.quote(str(slow_release))} ] && [ \"$i\" -lt 3000 ]; "
        f"do sleep 0.01; i=$((i+1)); done; [ -e {shlex.quote(str(slow_release))} ] || exit 124; "
        f"printf slow >> {shlex.quote(str(settlement_order))}; exit 7"
    )
    fast_command = f"printf fast >> {shlex.quote(str(settlement_order))}"
    retry_failure_release = threading.Event()
    responses = [
        fixture.sse_tool_calls(
            "reuse-calls",
            [
                (
                    "bash",
                    "reuse-slow-call",
                    json.dumps({"cmd": slow_command, "timeout_ms": None}, separators=(",", ":")),
                ),
                ("missing-tool", "reuse-unknown-call", "{}"),
                (
                    "bash",
                    "reuse-fast-call",
                    json.dumps({"cmd": fast_command, "timeout_ms": None}, separators=(",", ":")),
                ),
                ("bash", "reuse-invalid-call", '{"cmd":7}'),
            ],
        ),
        fixture.sse_answer(
            "reuse-first-answer",
            "reuse-first-reasoning",
            "reuse-first-message",
            "first-turn-answer",
        )[0],
        (
            fixture.ResponseSpec(b"temporary provider failure", {}, 503),
            retry_failure_release,
        ),
        fixture.sse_answer(
            "reuse-second-answer",
            "reuse-second-reasoning",
            "reuse-second-message",
            "second-turn-answer",
        )[0],
    ]
    endpoint = fixture.SuccessEndpoint(responses)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    endpoint_url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    host = None
    milestones = None
    reuse_submitted = False
    try:
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-retry-waits-ms",
            f"{retry_wait_ms},{retry_wait_ms},{retry_wait_ms}",
            "--test-bash-cleanup-gate-path",
            cleanup_gate,
            "--test-model-cleanup-gate-path",
            model_cleanup_gate,
            "--test-phase-trace",
            accelerated_retries=False,
            active_capacity=5,
        )
        milestones = HostDiagnostics(host)
        configure(state, store, "reuse-config", "direct/reuse")
        first_admission = fixture.message(
            state, store, "reuse-first", "direct/reuse", "first work"
        )
        reuse_submitted = True
        actions = fixture.wait_for(
            lambda: actions_for(store, "direct/reuse", 2),
            "two permission-blocked reused-Session Actions",
        )
        actions_by_ordinal = {action["call_ordinal"]: action for action in actions}
        assert set(actions_by_ordinal) == {"0", "2"}, actions

        queued_admission = fixture.message(
            state,
            store,
            "reuse-queued",
            "direct/reuse",
            "queued during permission",
        )
        queued = fixture.observe(store, "reuse-queued")
        assert queued["queue"]["status"] == "queued", queued
        first_processing = fixture.observe(store, "reuse-first")["processing"]
        report = fixture.command(
            "inspect-session",
            "--store",
            store,
            "--session",
            "direct/reuse",
            "--profile",
            "full",
        )
        rejected = [
            call for call in report["full"]["tool_calls"] if call["rejection"] is not None
        ]
        assert [(call["call_ordinal"], call["rejection"]) for call in rejected] == [
            ("1", "unknown_tool"),
            ("3", "invalid_arguments"),
        ], report

        slow_decision = allow(
            state,
            store,
            "reuse-slow-allow",
            "direct/reuse",
            actions_by_ordinal["0"]["action"],
        )
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "inspect-session", "--store", store, "--session", "direct/reuse"
                )["execution"]["custody_occupied"]
            )
            >= 1,
            "slow reused-Session Bash launch",
        )
        allow(
            state,
            store,
            "reuse-fast-allow",
            "direct/reuse",
            actions_by_ordinal["2"]["action"],
        )

        def reverse_settlement():
            unresolved = actions_for(store, "direct/reuse", 1)
            return (
                unresolved
                if unresolved is not None and unresolved[0]["call_ordinal"] == "0"
                else None
            )

        fixture.wait_for(reverse_settlement, "reverse sibling settlement")
        reverse_rows = action_rows_by_id(store, "direct/reuse")
        assert reverse_rows[actions_by_ordinal["2"]["action"]]["resolution"] == "succeeded", reverse_rows
        assert reverse_rows[actions_by_ordinal["0"]["action"]]["resolution"] is None, reverse_rows
        assert settlement_order.read_text() == "fast"
        assert len(endpoint.requests) == 1, endpoint.requests
        milestones.wait(
            "cleanup_started",
            action=str(actions_by_ordinal["2"]["action"]),
        )
        slow_release.touch()
        first_completed = fixture.wait_for(
            lambda: fixture.completed_observation(store, "reuse-first"),
            "first reused-Session result",
        )
        queued_completed = fixture.wait_for(
            lambda: fixture.completed_observation(store, "reuse-queued"),
            "queued message progress without another submission",
        )
        assert queued_completed["processing"]["turn"] == first_processing["turn"], queued_completed
        assert fixture.read_result(store, "reuse-first") == b"first-turn-answer"
        assert fixture.read_result(store, "reuse-queued") == b"first-turn-answer"
        assert settlement_order.read_text() == "fastslow"
        settled_rows = action_rows_by_id(store, "direct/reuse")
        assert int(
            reverse_rows[actions_by_ordinal["2"]["action"]]["acceptance_position"]
        ) < int(
            settled_rows[actions_by_ordinal["0"]["action"]]["acceptance_position"]
        ), settled_rows
        first_continuation = json.loads(endpoint.requests[1])
        continuation_outputs = [
            item
            for item in first_continuation["input"]
            if item.get("type") == "function_call_output"
        ]
        output_by_call = {item["call_id"]: item["output"] for item in continuation_outputs}
        assert list(output_by_call) == [
            "reuse-slow-call",
            "reuse-unknown-call",
            "reuse-fast-call",
            "reuse-invalid-call",
        ], continuation_outputs
        assert output_by_call["reuse-slow-call"].startswith(
            "Bash failed. Exit code: 7.\n"
        ), output_by_call
        assert output_by_call["reuse-unknown-call"] == "Unknown tool: missing-tool."
        assert output_by_call["reuse-fast-call"].startswith(
            "Bash succeeded. Exit code: 0.\n"
        ), output_by_call
        assert output_by_call["reuse-invalid-call"] == "Invalid arguments for tool 'bash'."
        first_semantic_input = [
            ("user", item["content"][0]["text"])
            if item.get("role") == "user"
            else ("call", item["call_id"])
            if item.get("type") == "function_call"
            else ("output", item["call_id"])
            for item in first_continuation["input"]
            if item.get("role") == "user"
            or item.get("type") in ("function_call", "function_call_output")
        ]
        assert first_semantic_input == [
            ("user", "first work"),
            ("call", "reuse-slow-call"),
            ("call", "reuse-unknown-call"),
            ("call", "reuse-fast-call"),
            ("call", "reuse-invalid-call"),
            ("output", "reuse-slow-call"),
            ("output", "reuse-unknown-call"),
            ("output", "reuse-fast-call"),
            ("output", "reuse-invalid-call"),
            ("user", "queued during permission"),
        ], first_semantic_input
        milestones.wait(
            "cleanup_started",
            action=str(actions_by_ordinal["0"]["action"]),
        )
        for action in actions_by_ordinal.values():
            assert milestones.matching(
                "cleanup_completed",
                action=str(action["action"]),
            ) == [], milestones.records
        delayed = fixture.command(
            "inspect-session", "--store", store, "--session", "direct/reuse"
        )["execution"]
        assert int(delayed["custody_occupied"]) >= len(actions_by_ordinal), delayed
        assert int(delayed["scratch_used_bytes"]) > 0, delayed

        fixture.message(
            state,
            store,
            "reuse-second",
            "direct/reuse",
            "second ordinary turn",
        )
        fixture.wait_for(
            lambda: len(endpoint.requests) == 3,
            "second Turn provider request during delayed cleanup",
        )
        second_live = fixture.command(
            "inspect-session", "--store", store, "--session", "direct/reuse"
        )["execution"]
        second_live_custody = int(second_live["custody_occupied"])
        assert second_live_custody >= 2, second_live
        second_processing = fixture.observe(store, "reuse-second")["processing"]
        model_cleanup_gate.write_text("blocked")
        retry_failure_release.set()
        milestones.wait(
            "cleanup_started",
            operation=str(second_processing["operation"]),
        )
        time.sleep(retry_wait_ms / 1000 + 0.25)
        retry_wait = fixture.observe(store, "reuse-second")
        retry_execution = fixture.command(
            "inspect-session", "--store", store, "--session", "direct/reuse"
        )["execution"]
        assert retry_wait["processing"] == second_processing, retry_wait
        assert retry_wait["processing"]["attempt"] == "1", retry_wait
        assert "result" not in retry_wait, retry_wait
        assert len(endpoint.requests) == 3, endpoint.requests
        assert int(retry_execution["custody_occupied"]) >= len(actions_by_ordinal) + 1
        assert int(retry_execution["scratch_used_bytes"]) > 0
        assert retry_execution["dispatch_fenced"] is False, retry_execution
        assert second_processing["turn"] != first_processing["turn"], retry_wait
        assert milestones.matching(
            "cleanup_completed",
            operation=str(second_processing["operation"]),
            attempt="1",
        ) == [], milestones.records
        for action in actions_by_ordinal.values():
            assert milestones.matching(
                "cleanup_completed",
                action=str(action["action"]),
            ) == [], milestones.records
        model_cleanup_gate.unlink()
        model_release = milestones.wait(
            "cleanup_release_observed",
            operation=str(second_processing["operation"]),
            attempt="1",
        )[0]
        model_completion = milestones.wait(
            "cleanup_completed",
            operation=str(second_processing["operation"]),
            attempt="1",
        )[0]
        assert int(model_release["at_ns"]) <= int(model_completion["at_ns"])
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "reuse-second"),
            "second reused-Session Turn",
            timeout=15,
        )
        assert fixture.read_result(store, "reuse-second") == b"second-turn-answer"
        assert len(endpoint.requests) == 4, endpoint.requests
        initial_request = json.loads(endpoint.requests[0])
        assert initial_request["input"] == [
            {"role": "system", "content": [{"type": "input_text", "text": ""}]},
            {"role": "user", "content": [{"type": "input_text", "text": "first work"}]},
        ], initial_request
        second_request = json.loads(endpoint.requests[2])
        second_semantic_input = [
            ("user", item["content"][0]["text"])
            if item.get("role") == "user"
            else ("assistant", item["content"][0]["text"])
            if item.get("role") == "assistant"
            else ("call", item["call_id"])
            if item.get("type") == "function_call"
            else ("output", item["call_id"])
            for item in second_request["input"]
            if item.get("role") in ("user", "assistant")
            or item.get("type") in ("function_call", "function_call_output")
        ]
        assert second_semantic_input == first_semantic_input + [
            ("assistant", "first-turn-answer"),
            ("user", "second ordinary turn"),
        ], second_semantic_input
        assert endpoint.requests[2] == endpoint.requests[3]

        replayed_message = fixture.command(
            "retry",
            "--store",
            store,
            "--record",
            state / "reuse-first.json",
            "--kind",
            "message",
        )
        expected_first_answer = dict(first_admission["answer"])
        expected_first_answer["replayed"] = True
        assert replayed_message["answer"] == expected_first_answer, replayed_message
        assert fixture.observe(store, "reuse-first") == first_completed
        replayed_queued = fixture.command(
            "retry",
            "--store",
            store,
            "--record",
            state / "reuse-queued.json",
            "--kind",
            "message",
        )
        expected_queued_answer = dict(queued_admission["answer"])
        expected_queued_answer["replayed"] = True
        assert replayed_queued["answer"] == expected_queued_answer, replayed_queued
        replayed_permission = fixture.command(
            "retry",
            "--store",
            store,
            "--record",
            state / "reuse-slow-allow.json",
            "--kind",
            "permission-decision",
        )
        expected_permission_answer = dict(slow_decision["answer"])
        expected_permission_answer["replayed"] = True
        assert replayed_permission["answer"] == expected_permission_answer, replayed_permission
        assert len(endpoint.requests) == 4, endpoint.requests
        assert fixture.read_result(store, "reuse-first") == b"first-turn-answer"
        assert fixture.read_result(store, "reuse-second") == b"second-turn-answer"
        cleanup_gate.unlink()
        for action in actions_by_ordinal.values():
            released = milestones.wait(
                "cleanup_release_observed",
                action=str(action["action"]),
                attempt="1",
            )[0]
            completed = milestones.wait(
                "cleanup_completed",
                action=str(action["action"]),
                attempt="1",
            )
            assert len(completed) == 1, completed
            assert int(released["at_ns"]) <= int(completed[0]["at_ns"])
        fixture.wait_for(
            lambda: execution_idle(store, "direct/reuse"),
            "reused-Session delayed cleanup",
            timeout=15,
        )
        for action in actions_by_ordinal.values():
            assert len(
                milestones.matching(
                    "cleanup_completed",
                    action=str(action["action"]),
                    attempt="1",
                )
            ) == 1, milestones.records
        assert fixture.read_result(store, "reuse-first") == b"first-turn-answer"
        assert fixture.read_result(store, "reuse-second") == b"second-turn-answer"
    finally:
        active_failure = sys.exception()
        retry_failure_release.set()
        slow_release.touch(exist_ok=True)
        cleanup_gate.unlink(missing_ok=True)
        model_cleanup_gate.unlink(missing_ok=True)
        if host is not None and reuse_submitted:
            try:
                fixture.wait_for(
                    lambda: execution_idle(store, "direct/reuse"),
                    "failed reused-Session fixture cleanup",
                    timeout=5,
                )
            except Exception:
                if active_failure is None:
                    raise
        if host is not None:
            fixture.stop_host(host)
        if milestones is not None:
            milestones.close()
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-bash."))
    prove_reused_session(state)
    responses = []
    success_workspace = state / "success-workspace"
    success_workspace.mkdir()
    counter = success_workspace / "launch-counter"
    large_command = (
        "printf x >> launch-counter; "
        "head -c 12000 /dev/zero | tr '\\0' z; printf '\\377'; printf stderr-marker >&2"
    )
    success_arguments = json.dumps(
        {"cmd": large_command, "timeout_ms": None}, separators=(",", ":")
    )
    responses.append(
        fixture.sse_tool_calls(
            "success-calls",
            [
                ("bash", "success-call", success_arguments),
                ("missing-tool", "success-unknown-call", "{}"),
                ("bash", "success-invalid-call", '{"cmd":7}'),
            ],
        )
    )
    responses.append(
        fixture.sse_answer(
            "success-answer",
            "success-reasoning",
            "success-message-result",
            "continued",
        )[0]
    )
    rollback_marker = state / "rollback-marker"
    add_exchange(responses, "rollback", f"printf x >> {rollback_marker}")
    unattempted_marker = state / "unattempted-marker"
    responses.append(
        fixture.sse_tool_calls(
            "unattempted-calls",
            [("bash", "unattempted-call", json.dumps({"cmd": f"printf x >> {unattempted_marker}", "timeout_ms": None}))],
        )
    )
    prelaunch_stop_marker = state / "prelaunch-stop-marker"
    responses.append(
        fixture.sse_tool_calls(
            "prelaunch-stop-calls",
            [("bash", "prelaunch-stop-call", json.dumps({"cmd": f"printf x >> {prelaunch_stop_marker}", "timeout_ms": None}))],
        )
    )
    before_launch_marker = state / "before-launch-marker"
    add_exchange(responses, "before-launch", f"printf x >> {before_launch_marker}")
    changed_marker = state / "changed-marker"
    add_exchange(responses, "changed", f"printf x >> {changed_marker}; sleep 30")
    responses.append(
        fixture.sse_tool_calls(
            "stop-calls",
            [("bash", "stop-call", json.dumps({"cmd": "trap '' TERM; sleep 30", "timeout_ms": None}, separators=(",", ":")))],
        )
    )
    responses.append(
        fixture.sse_tool_calls(
            "settlement-stop-calls",
            [("bash", "settlement-stop-call", json.dumps({"cmd": "printf sealed", "timeout_ms": None}))],
        )
    )
    exited_child_pid = state / "exited-child-pid"
    responses.append(
        fixture.sse_tool_calls(
            "exited-pipes-calls",
            [(
                "bash",
                "exited-pipes-call",
                json.dumps(
                    {
                        "cmd": f"(trap '' TERM; exec >/dev/null 2>&1; sleep 30) & printf $! > {exited_child_pid}",
                        "timeout_ms": None,
                    },
                    separators=(",", ":"),
                ),
            )],
        )
    )
    responses.append(
        fixture.sse_answer(
            "exited-pipes-answer",
            "exited-pipes-reasoning",
            "exited-pipes-message-result",
            "continued",
        )[0]
    )
    stopped_pipes_child_pid = state / "stopped-pipes-child-pid"
    stopped_pipes_leader_release = state / "stopped-pipes-leader-release"
    responses.append(
        fixture.sse_tool_calls(
            "stopped-pipes-calls",
            [(
                "bash",
                "stopped-pipes-call",
                json.dumps(
                    {
                        "cmd": (
                            f"(trap '' TERM; sleep 30) & child=$!; "
                            f"printf '%s\\n' \"$child\" > {stopped_pipes_child_pid}.tmp; "
                            f"mv {stopped_pipes_child_pid}.tmp {stopped_pipes_child_pid}; "
                            f"while [ ! -e {stopped_pipes_leader_release} ]; do sleep 0.01; done"
                        ),
                        "timeout_ms": None,
                    },
                    separators=(",", ":"),
                ),
            )],
        )
    )
    add_exchange(responses, "timeout", "sleep 30", timeout_ms=100)
    detached_pid = state / "detached-pid"
    add_exchange(
        responses,
        "detached-timeout",
        start_detached_shell(
            f"trap '' TERM PIPE; echo $$ > {detached_pid}; "
            "head -c 32768 /dev/zero; while :; do printf detached; sleep 1; done",
            detached_pid,
        ),
        timeout_ms=1000,
    )
    same_group_pid = state / "same-group-pid"
    add_exchange(
        responses,
        "same-group-timeout",
        f"(trap '' TERM; exec >/dev/null 2>&1; sleep 30) & child=$!; "
        f"printf '%s\n' \"$child\" > {same_group_pid}.tmp; "
        f"mv {same_group_pid}.tmp {same_group_pid}; wait \"$child\"",
        timeout_ms=100,
    )
    add_exchange(
        responses,
        "busy-output",
        "head -c 2097152 /dev/zero | tr '\\0' q",
        timeout_ms=None,
    )
    add_exchange(responses, "cleanup", "printf cleaned")
    add_exchange(responses, "preparation", "printf never")
    add_exchange(responses, "spawn", "printf never")
    add_exchange(responses, "capture-read", "printf captured")
    add_exchange(responses, "capture", "printf captured")
    add_exchange(responses, "seal", "printf sealed")
    add_exchange(responses, "preparation-cleanup", "printf never")
    service_marker = state / "service-marker"
    add_exchange(responses, "service", f"printf x >> {service_marker}; sleep 30")
    import_marker = state / "import-marker"
    add_exchange(responses, "import", f"printf x >> {import_marker}")
    commit_marker = state / "commit-marker"
    add_exchange(responses, "commit", f"printf x >> {commit_marker}")
    responses.append(
        fixture.sse_tool_calls(
            "post-resolution-calls",
            [("bash", "post-resolution-call", json.dumps({"cmd": "printf complete", "timeout_ms": None}))],
        )
    )
    sibling_marker = state / "sibling-marker"
    responses.append(
        fixture.sse_tool_calls(
            "sibling-calls",
            [
                (
                    "bash",
                    "sibling-call-0",
                    json.dumps(
                        {"cmd": f"sleep 0.2; printf a >> {sibling_marker}", "timeout_ms": None},
                        separators=(",", ":"),
                    ),
                ),
                (
                    "bash",
                    "sibling-call-1",
                    json.dumps(
                        {"cmd": f"printf b >> {sibling_marker}", "timeout_ms": None},
                        separators=(",", ":"),
                    ),
                ),
            ],
        )
    )
    responses.append(
        fixture.sse_answer(
            "sibling-answer", "sibling-reasoning", "sibling-message", "continued"
        )[0]
    )

    endpoint = fixture.SuccessEndpoint(responses)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    endpoint_url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    store = state / "store"
    success_cleanup_gate = state / "success-cleanup-gate"
    success_cleanup_gate.write_text("blocked")
    host = None
    success_milestones = None
    milestones = None
    detached_process = None
    observed_exit_gate = None
    observed_exit_gate_keeper = None
    stopped_pipes_stop = None
    completed = False
    resource_samples = []
    try:
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-bash-cleanup-gate-path",
            success_cleanup_gate,
            "--test-phase-trace",
            active_capacity=3,
        )
        success_milestones = HostDiagnostics(host)
        resource_samples.append({"phase": "cold", **process_resources(host), **scratch_resources(store)})

        fixture.configure_lost_reply(
            state,
            store,
            "success-config",
            "direct/success",
            "model-a",
            workspace=success_workspace,
            tools="bash",
            permission="ask",
        )
        recovered_configuration = fixture.command(
            "retry",
            "--store",
            store,
            "--record",
            state / "success-config.json",
            "--kind",
            "configure",
        )
        assert recovered_configuration["answer"]["status"] == "accepted", recovered_configuration
        assert recovered_configuration["answer"]["replayed"] is True, recovered_configuration
        fixture.message_lost_reply(
            state, store, "success-message", "direct/success", "execute"
        )
        recovered_message = fixture.command(
            "retry",
            "--store",
            store,
            "--record",
            state / "success-message.json",
            "--kind",
            "message",
        )
        assert recovered_message["answer"]["status"] == "accepted", recovered_message
        assert recovered_message["answer"]["replayed"] is True, recovered_message
        success_action = fixture.wait_for(
            lambda: action_for(store, "direct/success"), "successful Bash Action"
        )
        proposal = fixture.command(
            "inspect-session",
            "--store",
            store,
            "--session",
            "direct/success",
            "--profile",
            "full",
        )
        assert proposal["actions"]["count"] == "1", proposal
        assert proposal["actions"]["unresolved"] == [success_action], proposal
        assert success_action["call_ordinal"] == "0", proposal
        assert success_action["authorization"] == "pending", proposal
        assert success_action["permission_revision"] == "1", proposal
        assert fixture.read_action(
            store, "direct/success", success_action["action"], "call-id"
        ) == b"success-call"
        assert fixture.read_action(
            store, "direct/success", success_action["action"], "arguments"
        ) == success_arguments.encode()
        rejected = [
            call for call in proposal["full"]["tool_calls"] if call["rejection"] is not None
        ]
        assert [(call["call_ordinal"], call["rejection"]) for call in rejected] == [
            ("1", "unknown_tool"),
            ("2", "invalid_arguments"),
        ], proposal
        assert all(int(call["acceptance_position"]) > 0 for call in rejected), proposal
        assert len(endpoint.requests) == 1, endpoint.requests
        decision = allow(state, store, "success-allow", "direct/success", success_action["action"])
        assert decision["answer"]["replayed"] is False, decision
        replay = fixture.command(
            "retry",
            "--store",
            store,
            "--record",
            state / "success-allow.json",
            "--kind",
            "permission-decision",
        )
        assert replay["answer"]["replayed"] is True, replay
        conflict = fixture.command(
            "deny-action",
            "--store",
            store,
            "--record",
            state / "success-conflict.json",
            "--key",
            "success-allow",
            "--session",
            "direct/success",
            "--action",
            success_action["action"],
        )
        assert conflict["answer"]["status"] == "conflict", conflict
        bash_cleanup_started = success_milestones.wait(
            "cleanup_started",
            action=str(success_action["action"]),
        )[-1]
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "success-message"),
            "successful Bash continuation",
        )
        assert counter.read_text() == "x"
        assert fixture.read_result(store, "success-message") == b"continued"
        recovered_completed_message = fixture.command(
            "retry",
            "--store",
            store,
            "--record",
            state / "success-message.json",
            "--kind",
            "message",
        )
        assert recovered_completed_message["answer"]["status"] == "accepted", recovered_completed_message
        assert recovered_completed_message["answer"]["replayed"] is True, recovered_completed_message
        assert len(endpoint.requests) == 2, endpoint.requests
        continuation = json.loads(endpoint.requests[1])
        outputs = [item for item in continuation["input"] if item.get("type") == "function_call_output"]
        assert [item["call_id"] for item in outputs] == [
            "success-call",
            "success-unknown-call",
            "success-invalid-call",
        ], outputs
        assert outputs[1]["output"] == "Unknown tool: missing-tool.", outputs
        assert outputs[2]["output"] == "Invalid arguments for tool 'bash'.", outputs
        output = outputs[0]["output"]
        assert "Bash succeeded." in output and "stderr-mark" in output, output
        assert "�" in output and "[earlier output omitted]" in output, output
        assert "Full stdout:" in output and "Full stderr:" in output, output
        answer_report = fixture.command(
            "inspect-session",
            "--store",
            store,
            "--session",
            "direct/success",
            "--profile",
            "full",
        )
        success_actions = answer_report["full"]["actions"]
        assert len(success_actions) == 1, answer_report
        assert success_actions[0]["action"] == success_action["action"], answer_report
        assert success_actions[0]["resolution"] == "succeeded", answer_report
        success_resources = answer_report["execution"]
        assert success_resources["custody_occupied"] != "0", success_resources
        assert success_milestones.matching(
            "cleanup_completed", action=str(success_action["action"])
        ) == [], success_milestones.records
        resource_samples.append(
            {
                "phase": "retained-output-idle",
                **process_resources(host),
                **scratch_resources(store),
                "accounted_scratch_bytes": int(success_resources["scratch_used_bytes"]),
            }
        )
        success_cleanup_gate.unlink()
        bash_cleanup_completed = success_milestones.wait(
            "cleanup_completed",
            action=str(success_action["action"]),
        )[-1]
        assert int(bash_cleanup_completed["at_ns"]) >= int(bash_cleanup_started["at_ns"])

        fixture.stop_host(host)
        host = None
        success_milestones.close()
        success_milestones = None
        host = fixture.start_host(store, endpoint_url, active_capacity=0)
        configure(state, store, "rollback-config", "direct/rollback")
        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url)
        fixture.message(state, store, "rollback-message", "direct/rollback", "execute")
        rollback_action = fixture.wait_for(
            lambda: action_for(store, "direct/rollback"), "rollback Bash Action"
        )
        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url, "--fault", "attempt-before-commit")
        allow(state, store, "rollback-allow", "direct/rollback", rollback_action["action"])
        time.sleep(0.2)
        assert not rollback_marker.exists()
        fixture.stop_host(host)
        assert rows(
            store,
            "SELECT attempt_ordinal,resolution_code FROM action_operation WHERE session_ref=?",
            ("direct/rollback",),
        ) == [(0, None)]
        host = fixture.start_host(store, None)
        fixture.wait_for(lambda: rollback_marker.exists(), "Bash launch without provider transport")
        fixture.wait_for(
            lambda: resolution(store, "direct/rollback") == "succeeded",
            "Bash settlement without provider transport",
        )
        assert host.poll() is None
        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url)
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "rollback-message"),
            "rolled-back Bash continuation",
        )
        assert rollback_marker.read_text() == "x"

        configure(state, store, "unattempted-config", "direct/unattempted")
        fixture.message(state, store, "unattempted-message", "direct/unattempted", "execute")
        fixture.wait_for(
            lambda: action_for(store, "direct/unattempted"), "unattempted stoppable Action"
        )
        stopped = fixture.command(
            "stop-session",
            "--store",
            store,
            "--record",
            state / "unattempted-stop.json",
            "--key",
            "unattempted-stop",
            "--session",
            "direct/unattempted",
        )
        assert stopped["answer"]["status"] == "accepted", stopped
        assert resolution(store, "direct/unattempted") == "cancelled"
        assert not unattempted_marker.exists()

        configure(state, store, "prelaunch-stop-config", "direct/prelaunch-stop")
        fixture.message(state, store, "prelaunch-stop-message", "direct/prelaunch-stop", "execute")
        prelaunch_stop_action = fixture.wait_for(
            lambda: action_for(store, "direct/prelaunch-stop"), "pre-launch stoppable Action"
        )
        fixture.stop_host(host)
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-before-launch-delay-ms",
            "1000",
            "--test-phase-trace",
        )
        milestones = HostDiagnostics(host)
        allow(
            state,
            store,
            "prelaunch-stop-allow",
            "direct/prelaunch-stop",
            prelaunch_stop_action["action"],
        )
        milestones.wait(
            "prepared_before_handoff",
            action=str(prelaunch_stop_action["action"]),
        )
        fixture.command(
            "stop-session",
            "--store",
            store,
            "--record",
            state / "prelaunch-stop.json",
            "--key",
            "prelaunch-stop",
            "--session",
            "direct/prelaunch-stop",
        )
        fixture.wait_for(
            lambda: resolution(store, "direct/prelaunch-stop") == "cancelled",
            "pre-launch stopped Action",
        )
        assert not prelaunch_stop_marker.exists()

        configure(state, store, "before-launch-config", "direct/before-launch")
        fixture.message(state, store, "before-launch-message", "direct/before-launch", "execute")
        pending = fixture.wait_for(
            lambda: action_for(store, "direct/before-launch"), "pre-launch Bash Action"
        )
        host, milestones = stop_traced_host(host, milestones)
        host = fixture.start_host(store, endpoint_url, active_capacity=0)
        allow(state, store, "before-launch-allow", "direct/before-launch", pending["action"])
        rejected_allow = fixture.command(
            "allow-action",
            "--store",
            store,
            "--record",
            state / "before-launch-rejected-allow.json",
            "--key",
            "before-launch-rejected-allow",
            "--session",
            "direct/before-launch",
            "--action",
            pending["action"],
        )
        assert rejected_allow["answer"]["status"] == "rejected", rejected_allow
        assert rejected_allow["answer"]["code"] == "action_not_pending", rejected_allow
        assert rejected_allow["answer"]["replayed"] is False, rejected_allow
        configure(state, store, "before-launch-mode-change", "direct/before-launch", "bypass")
        report = fixture.command(
            "inspect-session", "--store", store, "--session", "direct/before-launch"
        )
        assert len(report["actions"]["unresolved"]) == 1, report
        assert report["actions"]["unresolved"][0]["authorization"] == "allow_once", report
        fixture.stop_host(host)
        assert rows(
            store,
            "SELECT permission_state,attempt_ordinal FROM action_operation WHERE session_ref=?",
            ("direct/before-launch",),
        ) == [(1, 0)]
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-before-launch-delay-ms",
            "5000",
            "--test-phase-trace",
        )
        milestones = HostDiagnostics(host)
        milestones.wait("prepared_before_handoff", action=str(pending["action"]))
        named_first_acquisition = sorted((store / "scratch").glob("bash-*-*.tmp"))
        assert len(named_first_acquisition) >= 3, named_first_acquisition
        assert not before_launch_marker.exists()
        crash = fixture.crash_host(host, state, "before-launch-crash", milestones)
        host = None
        milestones = None
        assert crash["returncode"] == -signal.SIGKILL
        host = fixture.start_host(store, endpoint_url)
        assert not list((store / "scratch").glob("bash-*-*.tmp"))
        fixture.wait_for(
            lambda: resolution(store, "direct/before-launch") == "indeterminate",
            "pre-launch indeterminate recovery",
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "before-launch-message"),
            "pre-launch recovery continuation",
        )
        assert not before_launch_marker.exists()

        configure(state, store, "changed-config", "direct/changed")
        fixture.message(state, store, "changed-message", "direct/changed", "execute")
        changed_action = fixture.wait_for(
            lambda: action_for(store, "direct/changed"), "changed Bash Action"
        )
        allow(state, store, "changed-allow", "direct/changed", changed_action["action"])
        fixture.wait_for(lambda: changed_marker.exists(), "Bash side effect")
        crash = fixture.crash_host(host, state, "changed-crash")
        host = None
        assert crash["returncode"] == -signal.SIGKILL
        host = fixture.start_host(store, endpoint_url)
        fixture.wait_for(
            lambda: resolution(store, "direct/changed") == "indeterminate",
            "changed-command indeterminate recovery",
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "changed-message"),
            "changed-command recovery continuation",
        )
        assert changed_marker.read_text() == "x"

        configure(state, store, "stop-config", "direct/stop")
        fixture.message(state, store, "stop-message", "direct/stop", "execute")
        stop_action = fixture.wait_for(lambda: action_for(store, "direct/stop"), "stoppable Bash Action")
        allow(state, store, "stop-allow", "direct/stop", stop_action["action"])
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "inspect-session", "--store", store, "--session", "direct/stop"
                )["execution"]["custody_occupied"]
            )
            > 0,
            "launched stoppable Bash",
        )
        active_resources = fixture.command(
            "inspect-session", "--store", store, "--session", "direct/stop"
        )["execution"]
        resource_samples.append(
            {
                "phase": "active-descendant-pipes",
                **process_resources(host),
                **scratch_resources(store),
                "accounted_scratch_bytes": int(active_resources["scratch_used_bytes"]),
            }
        )
        stopped = fixture.command(
            "stop-session",
            "--store",
            store,
            "--record",
            state / "stop.json",
            "--key",
            "stop",
            "--session",
            "direct/stop",
        )
        assert stopped["answer"]["status"] == "accepted", stopped
        assert stopped["completion"]["status"] == "pending", stopped
        fixture.wait_for(lambda: resolution(store, "direct/stop") == "cancelled", "cancelled Bash")
        fixture.stop_host(host)
        assert rows(store, "SELECT outcome_code FROM turn WHERE session_ref=?", ("direct/stop",)) == [
            ("cancelled",)
        ]

        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-before-result-delay-ms",
            "5000",
            "--test-cleanup-delay-ms",
            "1000",
            "--test-phase-trace",
        )
        milestones = HostDiagnostics(host)
        configure(state, store, "settlement-stop-config", "direct/settlement-stop")
        fixture.message(
            state,
            store,
            "settlement-stop-message",
            "direct/settlement-stop",
            "execute",
        )
        settlement_stop_action = fixture.wait_for(
            lambda: action_for(store, "direct/settlement-stop"),
            "settlement-stop Bash Action",
        )
        allow(
            state,
            store,
            "settlement-stop-allow",
            "direct/settlement-stop",
            settlement_stop_action["action"],
        )
        milestones.wait(
            "sealed_before_settlement",
            action=str(settlement_stop_action["action"]),
        )
        fixture.command(
            "stop-session",
            "--store",
            store,
            "--record",
            state / "settlement-stop.json",
            "--key",
            "settlement-stop",
            "--session",
            "direct/settlement-stop",
        )
        fixture.wait_for(
            lambda: resolution(store, "direct/settlement-stop") == "cancelled",
            "stop winning sealed Bash settlement",
        )
        assert result_text(store, "direct/settlement-stop") == "Cancelled by Session stop."
        assert int(
            fixture.command(
                "inspect-session", "--store", store, "--session", "direct/settlement-stop"
            )["execution"]["custody_occupied"]
        ) > 0
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "inspect-session", "--store", store, "--session", "direct/settlement-stop"
                )["execution"]["custody_occupied"]
            )
            == 0,
            "post-settlement Bash cleanup",
        )
        host, milestones = stop_traced_host(host, milestones)
        host = fixture.start_host(store, endpoint_url)

        configure(state, store, "exited-pipes-config", "direct/exited-pipes")
        fixture.message(state, store, "exited-pipes-message", "direct/exited-pipes", "execute")
        exited_action = fixture.wait_for(
            lambda: action_for(store, "direct/exited-pipes"), "exited-with-open-pipes Action"
        )
        allow(state, store, "exited-pipes-allow", "direct/exited-pipes", exited_action["action"])
        fixture.wait_for(
            exited_child_pid.exists,
            "descendant process identity",
        )
        child_pid = int(exited_child_pid.read_text())
        assert process_exists(child_pid)
        fixture.wait_for(
            lambda: resolution(store, "direct/exited-pipes") == "succeeded",
            "natural Bash result after descendant cleanup",
            timeout=20,
        )
        fixture.wait_for(lambda: not process_exists(child_pid), "natural Bash descendant cleanup")
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "exited-pipes-message"),
            "natural Bash continuation",
        )

        fixture.stop_host(host)
        observed_exit_gate = state / "stopped-pipes-observed-exit-gate"
        os.mkfifo(observed_exit_gate, mode=0o600)
        observed_exit_gate_keeper = os.open(observed_exit_gate, os.O_RDWR | os.O_NONBLOCK)
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-bash-observed-exit-gate-path",
            observed_exit_gate,
            "--test-phase-trace",
        )
        milestones = HostDiagnostics(host)
        configure(state, store, "stopped-pipes-config", "direct/stopped-pipes")
        fixture.message(state, store, "stopped-pipes-message", "direct/stopped-pipes", "execute")
        stopped_pipes_action = fixture.wait_for(
            lambda: action_for(store, "direct/stopped-pipes"), "stopped-with-open-pipes Action"
        )
        allow(
            state,
            store,
            "stopped-pipes-allow",
            "direct/stopped-pipes",
            stopped_pipes_action["action"],
        )
        fixture.wait_for(
            stopped_pipes_child_pid.exists,
            "stopped descendant identity",
        )
        stopped_child = int(stopped_pipes_child_pid.read_text())
        assert process_exists(stopped_child)
        stopped_pipes_leader_release.touch()
        milestones.wait(
            "bash_leader_observed_with_open_pipes",
            action=str(stopped_pipes_action["action"]),
        )
        stopped_pipes_stop = fixture.start_command(
            "stop-session",
            "--store",
            store,
            "--record", state / "stopped-pipes-stop.json",
            "--key",
            "stopped-pipes-stop",
            "--session",
            "direct/stopped-pipes",
        )
        milestones.wait(
            "control_store_complete",
            subject_kind="command_key",
            subject="stopped-pipes-stop",
        )
        os.write(observed_exit_gate_keeper, b"x")
        stopped = fixture.finish_command(stopped_pipes_stop)
        os.close(observed_exit_gate_keeper)
        observed_exit_gate.unlink()
        observed_exit_gate_keeper = None
        observed_exit_gate = None
        stopped_pipes_stop = None
        assert stopped["answer"]["status"] == "accepted", stopped
        fixture.wait_for(
            lambda: resolution(store, "direct/stopped-pipes") == "cancelled",
            "stop after observed leader exit with descendant pipes open",
            timeout=20,
        )
        fixture.wait_for(lambda: not process_exists(stopped_child), "stopped Bash descendant cleanup")

        host, milestones = stop_traced_host(host, milestones)
        host = fixture.start_host(store, endpoint_url, "--bash-timeout-ms", "30000")
        configure(state, store, "timeout-config", "direct/timeout")
        fixture.message(state, store, "timeout-message", "direct/timeout", "execute")
        timeout_action = fixture.wait_for(
            lambda: action_for(store, "direct/timeout"), "timeout Bash Action"
        )
        allow(state, store, "timeout-allow", "direct/timeout", timeout_action["action"])
        fixture.wait_for(
            lambda: resolution(store, "direct/timeout") == "timed_out",
            "timed-out Bash",
            timeout=20,
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "timeout-message"), "timeout continuation"
        )

        configure(state, store, "detached-timeout-config", "direct/detached-timeout")
        fixture.message(
            state, store, "detached-timeout-message", "direct/detached-timeout", "execute"
        )
        detached_action = fixture.wait_for(
            lambda: action_for(store, "direct/detached-timeout"), "detached timeout Action"
        )
        allow(
            state,
            store,
            "detached-timeout-allow",
            "direct/detached-timeout",
            detached_action["action"],
        )
        fixture.wait_for(
            detached_pid.exists,
            "detached writer identity",
        )
        detached_process = int(detached_pid.read_text())
        fixture.wait_for(
            lambda: resolution(store, "direct/detached-timeout") == "succeeded",
            "detached writer leader result",
            timeout=20,
        )
        result = result_text(store, "direct/detached-timeout")
        assert "Capture may be incomplete" in result, result
        stdout_path = pathlib.Path(
            next(line for line in result.splitlines() if line.startswith("Full stdout: "))[
                len("Full stdout: ") :
            ]
        )
        assert stdout_path.stat().st_size >= 32768, stdout_path.stat().st_size
        assert process_exists(detached_process)
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "inspect-session",
                    "--store",
                    store,
                    "--session",
                    "direct/detached-timeout",
                )["execution"]["custody_occupied"]
            )
            == 0,
            "detached timeout custody release",
        )
        os.kill(detached_process, signal.SIGKILL)
        detached_process = None

        configure(state, store, "same-group-timeout-config", "direct/same-group-timeout")
        fixture.message(
            state, store, "same-group-timeout-message", "direct/same-group-timeout", "execute"
        )
        same_group_action = fixture.wait_for(
            lambda: action_for(store, "direct/same-group-timeout"), "same-group timeout Action"
        )
        allow(
            state,
            store,
            "same-group-timeout-allow",
            "direct/same-group-timeout",
            same_group_action["action"],
        )
        fixture.wait_for(lambda: same_group_pid.exists(), "same-group child identity")
        same_group_process = int(same_group_pid.read_text())
        fixture.wait_for(
            lambda: resolution(store, "direct/same-group-timeout") == "timed_out",
            "same-group child timeout",
            timeout=20,
        )
        fixture.wait_for(
            lambda: not process_exists(same_group_process),
            "TERM-ignoring same-group child KILL escalation",
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "same-group-timeout-message"),
            "same-group timeout continuation",
        )

        configure(state, store, "busy-output-config", "direct/busy-output")
        fixture.message(state, store, "busy-output-message", "direct/busy-output", "execute")
        busy_output_action = fixture.wait_for(
            lambda: action_for(store, "direct/busy-output"), "busy-output Bash Action"
        )
        allow(
            state,
            store,
            "busy-output-allow",
            "direct/busy-output",
            busy_output_action["action"],
        )
        fixture.wait_for(
            lambda: resolution(store, "direct/busy-output") == "succeeded",
            "productive capture service without idle throttling",
            timeout=20,
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "busy-output-message"),
            "busy-output continuation",
        )

        fixture.stop_host(host)
        host = fixture.start_host(
            store,
            endpoint_url,
            "--fault",
            "bash-cleanup",
            "--fault",
            "bash-fault-gated",
        )
        cleanup_gate = store / "scratch" / "bash-fault-gate"
        cleanup_gate.write_text("blocked")
        configure(state, store, "cleanup-config", "direct/cleanup")
        fixture.message(state, store, "cleanup-message", "direct/cleanup", "execute")
        cleanup_action = fixture.wait_for(
            lambda: action_for(store, "direct/cleanup"), "cleanup-failure Bash Action"
        )
        allow(state, store, "cleanup-allow", "direct/cleanup", cleanup_action["action"])
        fixture.wait_for(
            lambda: resolution(store, "direct/cleanup") == "succeeded",
            "known result before cleanup failure",
        )
        cleanup_report = fixture.command(
            "inspect-session", "--store", store, "--session", "direct/cleanup"
        )
        assert cleanup_report["execution"]["dispatch_fenced"] is True, cleanup_report
        assert int(cleanup_report["execution"]["custody_occupied"]) > 0, cleanup_report
        assert list((store / "scratch").glob("bash-*-*.tmp"))
        cleanup_gate.unlink()
        fixture.wait_for(
            lambda: fixture.command(
                "inspect-session", "--store", store, "--session", "direct/cleanup"
            )["execution"]["custody_occupied"]
            == "0",
            "cleanup-failure original owner reclamation",
        )
        cleanup_attempt = f"{cleanup_action['action']}-1.tmp"
        assert not (store / "scratch" / f"bash-input-{cleanup_attempt}").exists()
        assert (store / "scratch" / f"bash-stdout-{cleanup_attempt}").exists()
        assert (store / "scratch" / f"bash-stderr-{cleanup_attempt}").exists()
        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url)
        assert resolution(store, "direct/cleanup") == "succeeded"
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "cleanup-message"),
            "cleanup-failure continuation",
        )

        for name, fault, expected in (
            ("preparation", "bash-preparation", "storage_failed"),
            ("spawn", "bash-spawn", "spawn_failed"),
            ("capture-read", "bash-capture-read", "storage_failed"),
            ("capture", "bash-capture-write", "storage_failed"),
            ("seal", "bash-seal", "storage_failed"),
        ):
            fixture.stop_host(host)
            host = fixture.start_host(store, endpoint_url, "--fault", fault)
            session = f"direct/{name}"
            configure(state, store, f"{name}-config", session)
            fixture.message(state, store, f"{name}-message", session, "execute")
            action = fixture.wait_for(lambda: action_for(store, session), f"{name} Bash Action")
            allow(state, store, f"{name}-allow", session, action["action"])
            fixture.wait_for(lambda: resolution(store, session) == expected, f"{name} result")
            fixture.wait_for(
                lambda: fixture.completed_observation(store, f"{name}-message"),
                f"{name} continuation",
            )

        fixture.stop_host(host)
        host = fixture.start_host(
            store,
            endpoint_url,
            "--fault",
            "bash-preparation-after-script",
            "--fault",
            "bash-cleanup",
            "--fault",
            "bash-fault-gated",
        )
        preparation_cleanup_gate = store / "scratch" / "bash-fault-gate"
        preparation_cleanup_gate.write_text("blocked")
        configure(state, store, "preparation-cleanup-config", "direct/preparation-cleanup")
        fixture.message(
            state,
            store,
            "preparation-cleanup-message",
            "direct/preparation-cleanup",
            "execute",
        )
        action = fixture.wait_for(
            lambda: action_for(store, "direct/preparation-cleanup"),
            "preparation-cleanup Bash Action",
        )
        allow(
            state,
            store,
            "preparation-cleanup-allow",
            "direct/preparation-cleanup",
            action["action"],
        )
        fixture.wait_for(
            lambda: resolution(store, "direct/preparation-cleanup") == "storage_failed",
            "preparation failure settlement",
        )
        assert int(
            fixture.command(
                "inspect-session", "--store", store, "--session", "direct/preparation-cleanup"
            )["execution"]["custody_occupied"]
        ) > 0
        assert list((store / "scratch").glob("bash-input-*-1.tmp"))
        preparation_cleanup_gate.unlink()
        fixture.wait_for(
            lambda: not list((store / "scratch").glob("bash-input-*-1.tmp")),
            "preparation cleanup by original owner",
        )
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "inspect-session",
                    "--store",
                    store,
                    "--session",
                    "direct/preparation-cleanup",
                )["execution"]["custody_occupied"]
            )
            == 0,
            "preparation cleanup custody release",
        )
        assert host.poll() is None
        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url)
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "preparation-cleanup-message"),
            "preparation-cleanup continuation",
        )

        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url, "--fault", "bash-service")
        configure(state, store, "service-config", "direct/service")
        fixture.message(state, store, "service-message", "direct/service", "execute")
        action = fixture.wait_for(lambda: action_for(store, "direct/service"), "service Bash Action")
        allow(state, store, "service-allow", "direct/service", action["action"])
        fixture.wait_for(lambda: host.poll() is not None, "persistent Bash service failure shutdown")
        host.communicate(timeout=5)
        host = None
        assert rows(
            store,
            "SELECT attempt_ordinal,resolution_code FROM action_operation WHERE session_ref=?",
            ("direct/service",),
        ) == [(1, None)]
        host = fixture.start_host(store, endpoint_url)
        fixture.wait_for(
            lambda: resolution(store, "direct/service") == "indeterminate",
            "service failure indeterminate recovery",
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "service-message"),
            "service failure continuation",
        )
        if service_marker.exists():
            assert service_marker.read_text() == "x"

        fixture.stop_host(host)
        host = None
        for name, fault, marker in (
            ("import", "content-import", import_marker),
            ("commit", "result-before-commit", commit_marker),
        ):
            host = fixture.start_host(store, endpoint_url, active_capacity=0)
            session = f"direct/{name}"
            configure(state, store, f"{name}-config", session)
            fixture.stop_host(host)
            host = fixture.start_host(store, endpoint_url)
            fixture.message(state, store, f"{name}-message", session, "execute")
            action = fixture.wait_for(lambda: action_for(store, session), f"{name} Bash Action")
            fixture.stop_host(host)
            host = fixture.start_host(store, endpoint_url, "--fault", fault)
            allow(state, store, f"{name}-allow", session, action["action"])
            fixture.wait_for(lambda: marker.exists(), f"{name} side effect")
            fixture.wait_for(lambda: host.poll() is not None, f"{name} canonical shutdown")
            host.communicate(timeout=5)
            host = None
            assert rows(
                store,
                "SELECT attempt_ordinal,resolution_code FROM action_operation WHERE session_ref=?",
                (session,),
            ) == [(1, None)]
            host = fixture.start_host(store, endpoint_url)
            fixture.wait_for(
                lambda: resolution(store, session) == "indeterminate",
                f"{name} indeterminate recovery",
            )
            fixture.wait_for(
                lambda: fixture.completed_observation(store, f"{name}-message"),
                f"{name} recovery continuation",
            )
            assert marker.read_text() == "x"
            fixture.stop_host(host)
            host = None

        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-cleanup-delay-ms",
            "1000",
        )
        configure(state, store, "post-resolution-config", "direct/post-resolution", "bypass")
        fixture.message(state, store, "post-resolution-message", "direct/post-resolution", "execute")
        fixture.wait_for(
            lambda: resolution(store, "direct/post-resolution") == "succeeded",
            "post-Resolution Bash result",
        )
        delayed = fixture.command(
            "inspect-session", "--store", store, "--session", "direct/post-resolution"
        )
        assert delayed["execution"]["custody_occupied"] == "1", delayed
        fixture.command(
            "stop-session",
            "--store",
            store,
            "--record",
            state / "post-resolution-stop.json",
            "--key",
            "post-resolution-stop",
            "--session",
            "direct/post-resolution",
        )
        fixture.wait_for(
            lambda: fixture.command(
                "inspect-session", "--store", store, "--session", "direct/post-resolution"
            )["execution"]["custody_occupied"]
            == "0",
            "post-Resolution physical cleanup",
        )
        assert resolution(store, "direct/post-resolution") == "succeeded"
        fixture.stop_host(host)
        host = None

        host = fixture.start_host(store, endpoint_url, active_capacity=2)
        configure(state, store, "sibling-config", "direct/sibling", "bypass")
        fixture.message(state, store, "sibling-message", "direct/sibling", "execute")
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "sibling-message"),
            "independent sibling continuation",
        )
        sibling_rows = fixture.command(
            "inspect-session",
            "--store",
            store,
            "--session",
            "direct/sibling",
            "--profile",
            "full",
        )["full"]["actions"]
        assert [(row["call_ordinal"], row["resolution"]) for row in sibling_rows] == [
            ("0", "succeeded"),
            ("1", "succeeded"),
        ], sibling_rows
        assert int(sibling_rows[1]["acceptance_position"]) < int(
            sibling_rows[0]["acceptance_position"]
        ), sibling_rows
        assert sibling_marker.read_text() == "ba"
        sibling_request = json.loads(endpoint.requests[-1])
        sibling_outputs = [
            item for item in sibling_request["input"] if item.get("type") == "function_call_output"
        ]
        assert [item["call_id"] for item in sibling_outputs] == [
            "sibling-call-0",
            "sibling-call-1",
        ], sibling_outputs
        sibling_resources = fixture.command(
            "inspect-session", "--store", store, "--session", "direct/sibling"
        )["execution"]
        resource_samples.append(
            {
                "phase": "two-sibling-retained-idle",
                **process_resources(host),
                **scratch_resources(store),
                "accounted_scratch_bytes": int(sibling_resources["scratch_used_bytes"]),
            }
        )

        fixture.stop_host(host)
        host = None
        assert rows(
            store,
            "SELECT count(*) FROM action_operation WHERE attempt_ordinal=1 AND resolution_code IS NULL",
        ) == [(0,)]
        settled = rows(
            store,
            "SELECT count(*),count(acceptance_position),min(acceptance_position) FROM action_operation "
            "WHERE resolution_code IS NOT NULL AND resolution_content_id IS NOT NULL",
        )[0]
        assert settled[0] == settled[1] == 27 and settled[2] > 0, settled
        print(json.dumps({"bash_resource_samples": resource_samples}, sort_keys=True))
        completed = True
    finally:
        if stopped_pipes_stop is not None and stopped_pipes_stop.poll() is None:
            stopped_pipes_stop.kill()
            stopped_pipes_stop.wait(timeout=10)
        if observed_exit_gate_keeper is not None:
            try:
                os.write(observed_exit_gate_keeper, b"x")
            except OSError:
                pass
            os.close(observed_exit_gate_keeper)
        if observed_exit_gate is not None:
            observed_exit_gate.unlink(missing_ok=True)
        if host is not None:
            fixture.stop_host(host)
        if milestones is not None:
            milestones.close()
        if success_milestones is not None:
            success_milestones.close()
        if detached_process is not None and process_exists(detached_process):
            os.kill(detached_process, signal.SIGKILL)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained Bash integration failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
