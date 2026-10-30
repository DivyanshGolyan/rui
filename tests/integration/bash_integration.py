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
from collections import Counter

import model_fixture as fixture
import host_process
from host_process import HostDiagnostics, ReleaseGate, canonical_fixture_root, dispose_all, retain_failure_state
import os_semantics


def assert_cleanup_population(diagnostics, *, actions, models, inspection_limit):
    # Reap/drain validates final native loss and sequence first. Endpoints cannot
    # be supplied by this census after their original waits have expired.
    def owners(phase):
        return Counter((r.get("turn"), r.get("operation"), r.get("attempt"), r.get("action"))
                       for r in diagnostics.matching(phase))

    # Only Bash delivery closure starts delayed, gated cleanup; a model
    # Attempt releases custody when it completes.
    started = owners("cleanup_started")
    assert all(count == 1 for count in started.values()), started
    assert Counter(owner[3] for owner in started) == Counter(map(str, actions)), started
    completed = owners("cleanup_completed")
    assert all(count == 1 for count in completed.values()), completed
    assert Counter({owner: count for owner, count in completed.items() if owner[3] is not None}) == started, diagnostics.records
    assert sum(1 for owner in completed if owner[3] is None) == models, completed
    assert owners("cleanup_release_observed") == started, diagnostics.records
    inspections = diagnostics.matching("inspection_captured")
    assert len(inspections) <= inspection_limit, inspections
    assert len(diagnostics.records) == sum(started.values()) * 2 + sum(completed.values()) + len(inspections), diagnostics.records


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


def publish_pid(path, value="$$"):
    """Publish a fixture-owned shell PID expression atomically for exists waits."""
    temporary = shlex.quote(str(path.with_suffix(".tmp")))
    return (
        f'printf "%s" "{value}" > {temporary} && '
        f"mv {temporary} {shlex.quote(str(path))}"
    )


def configure(state, store, key, permission="ask", workspace=fixture.ROOT):
    result = fixture.command(
        "session", "configure",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--workspace",
        workspace,
        "--provider",
        "codex",
        "--model",
        "gpt-6-sol",
        "--tools",
        "bash",
        "--permission-mode",
        permission,
    )
    assert result["answer"]["status"] == "accepted", result
    session = result["context"]["session"]
    assert len(session) == 6 and all(c in "0123456789abcdefghjkmnpqrstvwxyz" for c in session), result
    assert result["answer"]["created"] is True, result
    return session


def actions_for(store, session, count):
    report = fixture.command("session", "inspect", "--store", store, "--session", session)
    unresolved = report["actions"]["unresolved"]
    return unresolved if len(unresolved) == count else None


def action_for(store, session):
    actions = actions_for(store, session, 1)
    return actions[0] if actions is not None else None


def action_rows_by_id(store, session):
    return {
        action["action"]: action
        for action in fixture.command(
            "session", "inspect",
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
        "action", "allow",
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
    report = fixture.command("session", "inspect", "--store", store, "--session", session)
    execution = report["execution"]
    return report if execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0" else None


def execution_custody_idle(store, session):
    report = fixture.command("session", "inspect", "--store", store, "--session", session)
    return report if report["execution"]["custody_occupied"] == "0" else None


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def resolution(store, session):
    report = fixture.command(
        "session", "inspect", "--store", store, "--session", session, "--profile", "full"
    )
    actions = report["full"]["actions"]
    return actions[0]["resolution"] if len(actions) == 1 else None


def result_text(store, session):
    report = fixture.command(
        "session", "inspect", "--store", store, "--session", session, "--profile", "full"
    )
    actions = report["full"]["actions"]
    assert len(actions) == 1 and actions[0]["resolution"] is not None, report
    return actions[0]["result"]["text"]


def add_exchange(responses, name, command, answer="continued", timeout_ms=None, stdin=None):
    arguments = {"cmd": command, "timeout_ms": timeout_ms, "description": f"Run {name} command"}
    if stdin is not None:
        arguments["stdin"] = stdin
    responses.append(
        fixture.sse_tool_calls(
            f"{name}-calls",
            [("bash", f"{name}-call", json.dumps(arguments, separators=(",", ":")))],
        )
    )
    responses.append(fixture.sse_answer(f"{name}-answer", f"{name}-reasoning", f"{name}-message", answer)[0])


def prove_stdin(state):
    """Canonical descriptors, real bidirectional pressure and restart identity."""
    store = state / "stdin-store"
    workspace = state / "stdin-workspace"
    workspace.mkdir()
    limit = 122880
    prefix = "`touch evaluated` $(touch substituted) 'single' \"double\"\n\x00\r\n"
    large = prefix + "x" * (limit - len(prefix.encode()) - 2) + "é"
    assert len(large.encode()) == limit
    program = (
        "import fcntl,os,pathlib,stat,sys; "
        "s=os.fstat(0); assert stat.S_ISREG(s.st_mode) and s.st_nlink==0 and stat.S_IMODE(s.st_mode)==0o600; "
        "assert fcntl.fcntl(0,fcntl.F_GETFL)&os.O_ACCMODE==os.O_RDONLY; assert os.lseek(0,0,os.SEEK_CUR)==0; "
        "sys.stdout.buffer.write(b'o'*262144); sys.stdout.flush(); "
        "sys.stderr.buffer.write(b'e'*262144); sys.stderr.flush(); "
        "pathlib.Path('input.bin').write_bytes(sys.stdin.buffer.read())"
    )
    probe = "import os,stat; print('null' if stat.S_ISCHR(os.fstat(0).st_mode) else 'file'); print(len(os.read(0,1)))"
    empty_send_error = "\nrui: failure during input_parse; cause follows.\nStandard input was empty; provide Message text. Nothing was sent.\n"
    retained_output_bytes = {"large": 524288, "over": 0, "null": 7, "missing": 7, "empty": 7,
                             "closed": 6, "timeout": 0, "empty-send": len(empty_send_error), "null-send": len(empty_send_error)}
    cases = [
        ("large", {"cmd": f"{shlex.quote(sys.executable)} -c {shlex.quote(program)}", "stdin": large}, "succeeded"),
        ("over", {"cmd": "touch forbidden-over-limit", "stdin": large + "z"}, "spawn_failed"),
        ("null", {"cmd": f"{shlex.quote(sys.executable)} -c {shlex.quote(probe)}", "stdin": None}, "succeeded"),
        ("missing", {"cmd": f"{shlex.quote(sys.executable)} -c {shlex.quote(probe)}"}, "succeeded"),
        ("empty", {"cmd": f"{shlex.quote(sys.executable)} -c {shlex.quote(probe)}", "stdin": ""}, "succeeded"),
        ("closed", {"cmd": "exec 0<&-; printf closed; sleep 0.1", "stdin": large}, "succeeded"),
        ("timeout", {"cmd": "sleep 30", "stdin": large, "timeout_ms": 100}, "timed_out"),
    ]
    endpoint = fixture.SuccessEndpoint([])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    host = None
    try:
        host = fixture.start_host(store, url, active_capacity=2)
        recipient = configure(state, store, "stdin-recipient-config", workspace=workspace)
        for name, input_text in (("empty-send", ""), ("null-send", None)):
            # Trusted Bash peers select the launching Action's Store.
            command = shlex.join([str(fixture.RUI), "session", "send", "--to", recipient,
                                  "--record", str(state / f"{name}.json"), "--key", name])
            cases.append((name, {"cmd": command, "stdin": input_text}, "failed"))
        descriptors = {}
        for name, arguments, _ in cases:
            arguments.setdefault("description", f"Read {name} input")
            arguments.setdefault("timeout_ms", 10000)
            descriptors[name] = json.dumps(arguments, ensure_ascii=True, separators=(",", ":"))
            endpoint.responses.append(fixture.sse_tool_calls(f"stdin-{name}", [("bash", f"stdin-{name}", descriptors[name])]))
            endpoint.responses.append(fixture.sse_answer(f"stdin-{name}-answer", f"stdin-{name}-reason", f"stdin-{name}-message", "input complete")[0])
        for name, arguments, expected in cases:
            session = configure(state, store, f"stdin-{name}-config", workspace=workspace)
            fixture.message(state, store, f"stdin-{name}-request", session, "read the input")
            action = fixture.wait_for(lambda: action_for(store, session), f"{name} Action")

            def saved_arguments():
                return fixture.read_action(store, session, action["action"], "arguments")

            assert saved_arguments() == descriptors[name].encode(), name
            if name == "large":
                # No Attempt yet: restart must execute this same admitted input,
                # not a fresh proposal or a reconstructed command string.
                fixture.stop_host(host)
                host = None
                host = fixture.start_host(store, url, active_capacity=2)
                assert saved_arguments() == descriptors[name].encode(), "restarted Action changed input"
            fixture.wait_for(lambda: execution_custody_idle(store, session), f"{name} model custody release")
            baseline = int(fixture.command("session", "inspect", "--store", store, "--session", session)
                           ["execution"]["scratch_used_bytes"])
            allow(state, store, f"stdin-{name}-allow", session, action["action"])
            fixture.wait_for(lambda: fixture.completed_observation(store, f"stdin-{name}-request"), f"{name} continuation")
            assert resolution(store, session) == expected, (name, result_text(store, session))
            result = result_text(store, session)
            if name == "large":
                assert (workspace / "input.bin").read_bytes() == large.encode(), "large input changed or stopped before EOF"
                assert "[earlier output omitted]" in result and "Full stdout:" in result and "Full stderr:" in result, result
                assert not (workspace / "evaluated").exists() and not (workspace / "substituted").exists()
            elif name == "over":
                assert result == "Bash was not started: decoded stdin exceeds 122880 bytes. Split the input across smaller calls or read an existing file.", result
                assert not (workspace / "forbidden-over-limit").exists(), "over-limit input launched"
            elif name in ("null", "missing", "empty"):
                expected_kind = "file" if name == "empty" else "null"
                assert result == f"Bash succeeded. Exit code: 0.\nstdout tail:\n{expected_kind}\n0\n", result
            elif name == "closed":
                assert "closed" in result, result
            elif name in ("empty-send", "null-send"):
                assert result == "Bash failed. Exit code: 1.\nstderr tail:\n" + empty_send_error, result
                assert not (state / f"{name}.json").exists(), "empty input published a capture"
                assert fixture.command("request", "inspect", "--store", store, "--key", name)["observation"]["status"] == "absent"
            fixture.wait_for(lambda: fixture.command("session", "inspect", "--store", store, "--session", session)
                             ["execution"]["custody_occupied"] == "0", f"{name} custody release")
            used = int(fixture.command("session", "inspect", "--store", store, "--session", session)
                       ["execution"]["scratch_used_bytes"])
            assert used == baseline + retained_output_bytes[name], (name, baseline, used, "input charge leaked")
            continuation = json.loads(endpoint.requests[-1])
            call = next(item for item in continuation["input"] if item.get("type") == "function_call")
            assert call["arguments"] == descriptors[name], (name, "continuation changed canonical input")
            assert [item["output"] for item in continuation["input"] if item.get("type") == "function_call_output"] == [result]
        fixture.stop_host(host)
        host = None
        host = fixture.start_host(store, url, active_capacity=2)
        assert (workspace / "input.bin").read_bytes() == large.encode()
        assert len(endpoint.requests) == len(cases) * 2, "recovery replayed a settled command"
        print("Bash stdin passed: decoded exact-limit bytes including NUL/Unicode, output-before-input pressure, EOF, "
              "durable Action/restart/continuation identity, explicit prelaunch over-limit refusal, null/missing /dev/null, "
              "private unlinked read-only offset-zero file, empty EOF, early close and unread-input timeout; custody released")
    except BaseException:
        retain_failure_state("Bash stdin failure state", state)
        raise
    finally:
        dispose_all(
            (lambda: fixture.stop_host(host)) if host is not None else lambda: None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )


def prove_reused_session(state):
    store = state / "reused-session-store"
    workspace = state / "reused-session-workspace"
    workspace.mkdir()
    cleanup_gate = workspace / "cleanup-gate"
    cleanup_gate.write_text("blocked")
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
                    json.dumps({"cmd": slow_command, "timeout_ms": None, "description": "Append slow settlement"}, separators=(",", ":")),
                ),
                ("missing-tool", "reuse-unknown-call", "{}"),
                (
                    "bash",
                    "reuse-fast-call",
                    json.dumps({"cmd": fast_command, "timeout_ms": None, "description": "Append fast settlement"}, separators=(",", ":")),
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
            "--test-phase-trace",
            accelerated_retries=False,
            active_capacity=5,
            observations="bash_cleanup",
        )
        milestones = HostDiagnostics(host)
        session = configure(state, store, "reuse-config")
        first_admission = fixture.message(
            state, store, "reuse-first", session, "first work"
        )
        reuse_submitted = True
        actions = fixture.wait_for(
            lambda: actions_for(store, session, 2),
            "two permission-blocked reused-Session Actions",
        )
        actions_by_ordinal = {action["call_ordinal"]: action for action in actions}
        assert set(actions_by_ordinal) == {"0", "2"}, actions

        queued_admission = fixture.message(
            state,
            store,
            "reuse-queued",
            session,
            "queued during permission",
        )
        queued = fixture.observe(store, "reuse-queued")
        assert queued["queue"]["status"] == "queued", queued
        first_processing = fixture.observe(store, "reuse-first")["processing"]
        report = fixture.command(
            "session", "inspect",
            "--store",
            store,
            "--session",
            session,
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
            session,
            actions_by_ordinal["0"]["action"],
        )
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "session", "inspect", "--store", store, "--session", session
                )["execution"]["custody_occupied"]
            )
            >= 1,
            "slow reused-Session Bash launch",
        )
        allow(
            state,
            store,
            "reuse-fast-allow",
            session,
            actions_by_ordinal["2"]["action"],
        )

        def reverse_settlement():
            unresolved = actions_for(store, session, 1)
            return (
                unresolved
                if unresolved is not None and unresolved[0]["call_ordinal"] == "0"
                else None
            )

        fixture.wait_for(reverse_settlement, "reverse sibling settlement")
        reverse_rows = action_rows_by_id(store, session)
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
        settled_rows = action_rows_by_id(store, session)
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
            "session", "inspect", "--store", store, "--session", session
        )["execution"]
        assert int(delayed["custody_occupied"]) >= len(actions_by_ordinal), delayed
        # Both commands write only files: delayed cleanup holds custody over
        # empty captures, and the command itself never reaches scratch.
        assert delayed["scratch_used_bytes"] == "0", delayed

        fixture.message(
            state,
            store,
            "reuse-second",
            session,
            "second ordinary turn",
        )
        fixture.wait_for(
            lambda: len(endpoint.requests) == 3,
            "second Turn provider request during delayed cleanup",
        )
        second_live = fixture.command(
            "session", "inspect", "--store", store, "--session", session
        )["execution"]
        second_live_custody = int(second_live["custody_occupied"])
        assert second_live_custody >= 2, second_live
        second_processing = fixture.observe(store, "reuse-second")["processing"]
        assert second_processing["turn"] != first_processing["turn"], second_processing
        retry_failure_release.set()
        # The failed Attempt releases its own custody at settlement, while
        # delayed Bash cleanup still holds the earlier Actions' custody.
        milestones.wait(
            "cleanup_completed",
            operation=str(second_processing["operation"]),
            attempt="1",
        )
        for action in actions_by_ordinal.values():
            assert milestones.matching(
                "cleanup_completed",
                action=str(action["action"]),
            ) == [], milestones.records
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "reuse-second"),
            "second reused-Session Turn",
            timeout=15,
        )
        assert fixture.read_result(store, "reuse-second") == b"second-turn-answer"
        assert len(endpoint.requests) == 4, endpoint.requests
        initial_request = json.loads(endpoint.requests[0])
        assert initial_request["instructions"] == fixture.model_instructions(fixture.ROOT, store=store, session=session), initial_request
        assert initial_request["input"] == [
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
            "request", "recover",
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
            "request", "recover",
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
            "request", "recover",
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
            )[0]
            completed = milestones.wait(
                "cleanup_completed",
                action=str(action["action"]),
            )
            assert len(completed) == 1, completed
            assert int(released["at_ns"]) <= int(completed[0]["at_ns"])
        fixture.wait_for(
            lambda: execution_idle(store, session),
            "reused-Session delayed cleanup",
            timeout=15,
        )
        for action in actions_by_ordinal.values():
            assert len(
                milestones.matching(
                    "cleanup_completed",
                    action=str(action["action"]),
                )
            ) == 1, milestones.records
        assert fixture.read_result(store, "reuse-first") == b"first-turn-answer"
        assert fixture.read_result(store, "reuse-second") == b"second-turn-answer"
    finally:
        active_failure = sys.exception()
        retry_failure_release.set()
        slow_release.touch(exist_ok=True)
        cleanup_gate.unlink(missing_ok=True)
        if host is not None and reuse_submitted:
            try:
                fixture.wait_for(
                    lambda: execution_idle(store, session),
                    "failed reused-Session fixture cleanup",
                    timeout=5,
                )
            except Exception:
                if active_failure is None:
                    raise
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        if host is not None and active_failure is None:
            assert_cleanup_population(milestones, actions=[a["action"] for a in actions_by_ordinal.values()],
                                      models=4,
                                      inspection_limit=3 * 321 + 601 + 201 + 6)


def show_command(*args, input=None):
    prefix = "" if input is None else "printf '%s' " + shlex.quote(input) + " | "
    print("$ " + prefix + "rui " + " ".join(shlex.quote(str(arg)) for arg in args), flush=True)


def show_observation(message):
    print(f"  -> {message}", flush=True)


def source_revision():
    try:
        result = subprocess.run(
            ["git", "describe", "--always", "--dirty"],
            cwd=fixture.ROOT,
            text=True,
            capture_output=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable-source-export"
    return result.stdout.strip() if result.returncode == 0 else "unavailable-source-export"


def walkthrough():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-bash-walkthrough."))
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    message_key = "walkthrough-message"
    message_record = state / f"{message_key}.json"
    counter = workspace / "effect-count"
    arguments = json.dumps(
        {"cmd": "printf x >> effect-count", "timeout_ms": None, "description": "Append effect counter"}, separators=(",", ":")
    )
    responses = [
        fixture.sse_tool_calls(
            "walkthrough-calls",
            [("bash", "walkthrough-call", arguments)],
        ),
        fixture.sse_answer(
            "walkthrough-answer",
            "walkthrough-reasoning",
            "walkthrough-message-result",
            "walkthrough complete",
        )[0],
    ]
    endpoint = fixture.SuccessEndpoint(responses)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    endpoint_url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    host = None
    completed = False
    try:
        print("Rui Bash approve-and-recover walkthrough")
        show_observation(
            f"exercise revision: {source_revision()}; platform: {os_semantics.DESCRIPTION}"
        )
        show_observation(f"temporary Store: {store}")
        show_observation(f"temporary Workspace (working directory, not a sandbox): {workspace}")
        host_args = fixture.host_arguments(store, endpoint_url)
        show_command(*host_args[1:])
        host = fixture.start_host(store, endpoint_url)
        show_observation("Host started with the deterministic local provider fixture")

        configure_args = (
            "session", "configure",
            "--store",
            store,
            "--record",
            state / "walkthrough-config.json",
            "--key",
            "walkthrough-config",
            "--workspace",
            workspace,
            "--provider",
            "codex",
            "--model",
            "gpt-6-sol",
            "--tools",
            "bash",
            "--permission-mode",
            "ask",
        )
        show_command(*configure_args)
        configured = fixture.command(*configure_args)
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["context"]["session"]
        assert len(session) == 6 and all(c in "0123456789abcdefghjkmnpqrstvwxyz" for c in session), configured
        assert configured["answer"]["created"] is True, configured
        show_observation("configuration accepted; ask mode requires an exact Action decision")

        message_args = (
            "session", "send",
            "--store",
            store,
            "--to",
            session,
            "--record",
            message_record,
            "--key",
            message_key,
        )
        message_text = "make one independently counted file effect"
        show_command(*message_args, input=message_text)
        submitted = fixture.command(*message_args, input=message_text)
        assert submitted["answer"]["status"] == "accepted", submitted
        captured_bytes = message_record.read_bytes()
        captured = json.loads(captured_bytes)
        assert captured["key"] == message_key, captured
        assert captured["session"] == session, captured
        assert captured["text"] == {
            "state": "value",
            "value": "make one independently counted file effect",
        }, captured
        show_observation(f"message accepted and exact retry record retained at {message_record}")

        action = fixture.wait_for(lambda: action_for(store, session), "walkthrough Bash Action")
        inspect_args = ("session", "inspect", "--store", store, "--session", session, "--profile", "full")
        show_command(*inspect_args)
        report = fixture.command(*inspect_args)
        assert report["actions"]["unresolved"] == [action], report
        assert action["authorization"] == "pending", action
        show_observation(
            f"Action {action['action']} is pending approval for call ordinal {action['call_ordinal']}"
        )

        call_id_args = (
            "action", "read-call-id",
            "--store",
            store,
            "--session",
            session,
            "--action",
            action["action"],
        )
        arguments_args = (
            "action", "read-arguments",
            "--store",
            store,
            "--session",
            session,
            "--action",
            action["action"],
        )
        show_command(*call_id_args)
        assert fixture.read_action(store, session, action["action"], "call-id") == b"walkthrough-call"
        show_observation("exact call ID: walkthrough-call")
        show_command(*arguments_args)
        assert fixture.read_action(store, session, action["action"], "arguments") == arguments.encode()
        show_observation(f"exact arguments: {arguments}")
        assert not counter.exists()
        assert len(endpoint.requests) == 1, endpoint.requests
        show_observation("zero file effects and no continuation request before approval")

        allow_args = (
            "action", "allow",
            "--store",
            store,
            "--record",
            state / "walkthrough-allow.json",
            "--key",
            "walkthrough-allow",
            "--session",
            session,
            "--action",
            action["action"],
        )
        show_command(*allow_args)
        allowed = fixture.command(*allow_args)
        assert allowed["answer"]["status"] == "accepted", allowed
        assert allowed["answer"]["replayed"] is False, allowed
        show_observation(f"keyed allow-once decision accepted for Action {action['action']}")

        fixture.wait_for(
            lambda: fixture.completed_observation(store, message_key),
            "walkthrough saved answer",
        )
        fixture.wait_for(lambda: execution_idle(store, session), "walkthrough owned cleanup")
        assert counter.read_text() == "x"
        assert len(endpoint.requests) == 2, endpoint.requests
        result_args = ("request", "read-result", "--store", store, "--key", message_key)
        show_command(*result_args)
        assert fixture.read_result(store, message_key) == b"walkthrough complete"
        show_observation("saved answer: walkthrough complete; independent effect count: 1")
        settled_action = action_rows_by_id(store, session)[action["action"]]
        assert settled_action["resolution"] == "succeeded", settled_action

        print(f"$ kill -9 {host.pid}", flush=True)
        crash = fixture.crash_host(host, state, "walkthrough-crash")
        host = None
        assert crash["returncode"] == -signal.SIGKILL, crash
        show_observation(
            "Host process crashed after the result and cleanup were committed; this is not power-loss evidence"
        )
        show_command(*host_args[1:])
        host = fixture.start_host(store, endpoint_url)
        show_observation("fresh Host reopened the same Store")

        retry_args = (
            "request", "recover",
            "--store",
            store,
            "--record",
            message_record,
            "--kind",
            "message",
        )
        show_command(*retry_args)
        recovered = fixture.command(*retry_args)
        assert recovered["answer"]["status"] == "accepted", recovered
        assert recovered["answer"]["replayed"] is True, recovered
        assert message_record.read_bytes() == captured_bytes
        show_command(*result_args)
        assert fixture.read_result(store, message_key) == b"walkthrough complete"
        show_observation("recovered saved answer: walkthrough complete")
        recovered_report = fixture.command(*inspect_args)
        recovered_actions = recovered_report["full"]["actions"]
        assert len(recovered_actions) == 1, recovered_report
        assert recovered_actions[0] == settled_action, recovered_report
        assert fixture.read_action(
            store, session, action["action"], "call-id"
        ) == b"walkthrough-call"
        assert fixture.read_action(
            store, session, action["action"], "arguments"
        ) == arguments.encode()
        assert counter.read_text() == "x"
        assert len(endpoint.requests) == 2, endpoint.requests
        show_observation(
            "original submission/result binding recovered; Action unchanged; Bash effects=1; provider requests=2"
        )
        completed = True
    finally:
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        assert not endpoint_thread.is_alive(), "walkthrough provider fixture did not stop"
        if completed:
            shutil.rmtree(state)
            show_observation("owned Host, provider, Store, Workspace, and caller records cleaned up")
        else:
            retain_failure_state("Bash walkthrough failure state", state)


def main():
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-bash."))
    prove_stdin(state)
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
        {"cmd": large_command, "timeout_ms": None, "description": "Write large captured output"}, separators=(",", ":")
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
    # The limit counts decoded UTF-8 bytes: each "é" is two command bytes,
    # six JSON bytes and one character.
    command_limit = 120 * 1024
    over_limit_marker = state / "over-limit-marker"
    limit_prefix = f"printf at-limit; printf x >> {over_limit_marker} #"
    limit_padding = command_limit - len(limit_prefix.encode())
    at_limit_command = limit_prefix + "é" * (limit_padding // 2) + "x" * (limit_padding % 2)
    assert len(at_limit_command.encode()) == command_limit
    add_exchange(responses, "at-limit", at_limit_command)
    add_exchange(responses, "over-limit", at_limit_command + "x")
    unattempted_marker = state / "unattempted-marker"
    responses.append(
        fixture.sse_tool_calls(
            "unattempted-calls",
            [("bash", "unattempted-call", json.dumps({"cmd": f"printf x >> {unattempted_marker}", "timeout_ms": None, "description": "Append unattempted marker"}))],
        )
    )
    prelaunch_stop_marker = state / "prelaunch-stop-marker"
    responses.append(
        fixture.sse_tool_calls(
            "prelaunch-stop-calls",
            [("bash", "prelaunch-stop-call", json.dumps({"cmd": f"printf x >> {prelaunch_stop_marker}", "stdin": "x" * 122880, "timeout_ms": None, "description": "Append prelaunch stop marker"}))],
        )
    )
    before_launch_marker = state / "before-launch-marker"
    add_exchange(responses, "before-launch", f"printf x >> {before_launch_marker}")
    changed_marker = state / "changed-marker"
    add_exchange(responses, "changed", f"printf x >> {changed_marker}; sleep 30")
    stop_pid = state / "stop-pid"
    responses.append(
        fixture.sse_tool_calls(
            "stop-calls",
            [("bash", "stop-call", json.dumps({"cmd": f"{publish_pid(stop_pid)}; trap '' TERM; sleep 30", "stdin": "x" * 122880, "timeout_ms": None, "description": "Wait through termination signal"}, separators=(",", ":")))],
        )
    )
    responses.append(
        fixture.sse_tool_calls(
            "settlement-stop-calls",
            [("bash", "settlement-stop-call", json.dumps({"cmd": "printf sealed", "timeout_ms": None, "description": "Print sealed output"}))],
        )
    )
    exited_child_pid = state / "exited-child-pid"
    exited_pipes_leader_release = state / "exited-pipes-leader-release"
    responses.append(
        fixture.sse_tool_calls(
            "exited-pipes-calls",
            [(
                "bash",
                "exited-pipes-call",
                json.dumps(
                    {
                        "cmd": (
                            f"(trap '' TERM; exec >/dev/null 2>&1; sleep 30) & "
                            f"{publish_pid(exited_child_pid, '$!')}; "
                            f"while [ ! -e {exited_pipes_leader_release} ]; do sleep 0.01; done"
                        ),
                        "timeout_ms": None,
                        "description": "Start detached pipe-free child",
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
                            f"{publish_pid(stopped_pipes_child_pid, '$child')}; "
                            f"while [ ! -e {stopped_pipes_leader_release} ]; do sleep 0.01; done"
                        ),
                        "timeout_ms": None,
                        "description": "Hold stopped child output pipes",
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
            f"trap '' TERM PIPE; {publish_pid(detached_pid)}; "
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
        f"{publish_pid(same_group_pid, '$child')}; wait \"$child\"",
        # The budget only has to outlast launch and PID publication: under CPU
        # load the shell can wait tens of ms for a CPU before it starts.
        timeout_ms=1000,
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
            [("bash", "post-resolution-call", json.dumps({"cmd": "printf complete", "timeout_ms": None, "description": "Print completed output"}))],
        )
    )
    sibling_marker = state / "sibling-marker"
    sibling_release = state / "sibling-release"
    responses.append(
        fixture.sse_tool_calls(
            "sibling-calls",
            [
                (
                    "bash",
                    "sibling-call-0",
                    json.dumps(
                        {"cmd": f"while [ ! -e {shlex.quote(str(sibling_release))} ]; do sleep 0.01; done; printf a >> {shlex.quote(str(sibling_marker))}", "timeout_ms": None, "description": "Append first sibling marker"},
                        separators=(",", ":"),
                    ),
                ),
                (
                    "bash",
                    "sibling-call-1",
                    json.dumps(
                        {"cmd": f"printf b >> {sibling_marker}", "timeout_ms": None, "description": "Append second sibling marker"},
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
    settlement_gate = None
    before_launch_gate = None
    settlement_cleanup_gate = state / "settlement-cleanup-gate"
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
            observations="bash_cleanup",
        )
        success_milestones = HostDiagnostics(host)
        resource_samples.append({"phase": "cold", **process_resources(host), **scratch_resources(store)})

        fixture.configure_lost_reply(
            state,
            store,
            "success-config",
            None,
            "gpt-6-sol",
            workspace=success_workspace,
            tools="bash",
            permission="ask",
        )
        recovered_configuration = fixture.command(
            "request", "recover",
            "--store",
            store,
            "--record",
            state / "success-config.json",
            "--kind",
            "configure",
        )
        assert recovered_configuration["answer"]["status"] == "accepted", recovered_configuration
        assert recovered_configuration["answer"]["replayed"] is True, recovered_configuration
        session = recovered_configuration["context"]["session"]
        assert len(session) == 6 and all(c in "0123456789abcdefghjkmnpqrstvwxyz" for c in session), recovered_configuration
        assert recovered_configuration["answer"]["created"] is True, recovered_configuration
        fixture.message_lost_reply(
            state, store, "success-message", session, "execute"
        )
        recovered_message = fixture.command(
            "request", "recover",
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
            lambda: action_for(store, session), "successful Bash Action"
        )
        proposal = fixture.command(
            "session", "inspect",
            "--store",
            store,
            "--session",
            session,
            "--profile",
            "full",
        )
        assert proposal["actions"]["count"] == "1", proposal
        assert proposal["actions"]["unresolved"] == [success_action], proposal
        assert success_action["call_ordinal"] == "0", proposal
        assert success_action["authorization"] == "pending", proposal
        assert success_action["permission_revision"] == "1", proposal
        assert fixture.read_action(
            store, session, success_action["action"], "call-id"
        ) == b"success-call"
        assert fixture.read_action(
            store, session, success_action["action"], "arguments"
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
        decision = allow(state, store, "success-allow", session, success_action["action"])
        assert decision["answer"]["replayed"] is False, decision
        replay = fixture.command(
            "request", "recover",
            "--store",
            store,
            "--record",
            state / "success-allow.json",
            "--kind",
            "permission-decision",
        )
        assert replay["answer"]["replayed"] is True, replay
        conflict = fixture.command(
            "action", "deny",
            "--store",
            store,
            "--record",
            state / "success-conflict.json",
            "--key",
            "success-allow",
            "--session",
            session,
            "--action",
            success_action["action"],
            expect=1,
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
            "request", "recover",
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
        # Only the truncated stream names its full file.
        assert "Full stdout:" in output and "Full stderr:" not in output, output
        answer_report = fixture.command(
            "session", "inspect",
            "--store",
            store,
            "--session",
            session,
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
        assert_cleanup_population(success_milestones, actions=[success_action["action"]],
                                  models=2, inspection_limit=321 + 2)
        success_milestones = None
        host = fixture.start_host(store, endpoint_url, "--test-phase-trace", active_capacity=0)
        # A zero-capacity Host with a provider endpoint runs no transport: its
        # execution loop serves and the Host stays up.
        HostDiagnostics(host).wait("lifecycle_service_observation", timeout=5)
        assert host.poll() is None, host.returncode
        session = configure(state, store, "rollback-config")
        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url)
        fixture.message(state, store, "rollback-message", session, "execute")
        rollback_action = fixture.wait_for(
            lambda: action_for(store, session), "rollback Bash Action"
        )
        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url, "--fault", "attempt-before-commit")
        allow(state, store, "rollback-allow", session, rollback_action["action"])
        # The failed Attempt commit rolls back and fences; the Host exits.
        host.wait(timeout=10)
        assert host.returncode != 0, host.returncode
        assert not rollback_marker.exists()
        fixture.stop_host(host)
        assert rows(
            store,
            "SELECT attempt_ordinal,resolution_code FROM action_operation WHERE session_ref=?",
            (session,),
        ) == [(0, None)]
        host = fixture.start_host(store, None)
        fixture.wait_for(lambda: rollback_marker.exists(), "Bash launch without provider transport")
        fixture.wait_for(
            lambda: resolution(store, session) == "succeeded",
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

        for name, expected, text in (
            ("at-limit", "succeeded", "at-limit"),
            ("over-limit", "spawn_failed", "Bash was not started: the decoded command exceeds 122880 bytes."),
        ):
            session = configure(state, store, f"{name}-config")
            fixture.message(state, store, f"{name}-message", session, "execute")
            action = fixture.wait_for(lambda: action_for(store, session), f"{name} Bash Action")
            allow(state, store, f"{name}-allow", session, action["action"])
            fixture.wait_for(lambda: resolution(store, session) == expected, f"{name} result")
            assert text in result_text(store, session)
            fixture.wait_for(
                lambda: fixture.completed_observation(store, f"{name}-message"),
                f"{name} continuation",
            )
        assert over_limit_marker.read_text() == "x"

        session = configure(state, store, "unattempted-config")
        fixture.message(state, store, "unattempted-message", session, "execute")
        fixture.wait_for(
            lambda: action_for(store, session), "unattempted stoppable Action"
        )
        stopped = fixture.command(
            "session", "stop",
            "--store",
            store,
            "--record",
            state / "unattempted-stop.json",
            "--key",
            "unattempted-stop",
            "--session",
            session,
        )
        assert stopped["answer"]["status"] == "accepted", stopped
        assert resolution(store, session) == "cancelled"
        assert not unattempted_marker.exists()

        session = configure(state, store, "prelaunch-stop-config")
        fixture.message(state, store, "prelaunch-stop-message", session, "execute")
        prelaunch_stop_action = fixture.wait_for(
            lambda: action_for(store, session), "pre-launch stoppable Action"
        )
        fixture.stop_host(host)
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-before-launch-delay-ms",
            "1000",
            "--test-phase-trace",
            observations="recovery",
        )
        milestones = HostDiagnostics(host)
        allow(
            state,
            store,
            "prelaunch-stop-allow",
            session,
            prelaunch_stop_action["action"],
        )
        milestones.wait(
            "prepared_before_handoff",
            action=str(prelaunch_stop_action["action"]),
        )
        fixture.command(
            "session", "stop",
            "--store",
            store,
            "--record",
            state / "prelaunch-stop.json",
            "--key",
            "prelaunch-stop",
            "--session",
            session,
        )
        fixture.wait_for(
            lambda: resolution(store, session) == "cancelled",
            "pre-launch stopped Action",
        )
        assert not prelaunch_stop_marker.exists()

        session = configure(state, store, "before-launch-config")
        fixture.message(state, store, "before-launch-message", session, "execute")
        pending = fixture.wait_for(
            lambda: action_for(store, session), "pre-launch Bash Action"
        )
        fixture.stop_host(host)
        host, milestones = None, None
        host = fixture.start_host(store, endpoint_url, active_capacity=0)
        allow(state, store, "before-launch-allow", session, pending["action"])
        fixture.stop_host(host)
        assert rows(
            store,
            "SELECT authorized,attempt_ordinal FROM action_operation WHERE session_ref=?",
            (session,),
        ) == [(1, 0)]
        before_launch_gate = ReleaseGate(state / "before-launch-gate")
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-transition",
            "prepared-before-handoff",
            "--test-transition-gate-path",
            before_launch_gate.path,
            "--test-phase-trace",
            observations="recovery",
        )
        milestones = HostDiagnostics(host)
        milestones.wait("prepared_before_handoff", action=str(pending["action"]))
        # The exact native receipt plus an unreleased, empty FIFO holds the
        # handoff; marker absence alone cannot establish that launch is barred.
        assert host.poll() is None
        before_launch_gate.assert_held()
        named_first_acquisition = sorted((store / "scratch").glob("bash-*-*.tmp"))
        assert {
            store / "scratch" / f"bash-{stream}-{pending['action']}-1.tmp"
            for stream in ("stdout", "stderr")
        } <= set(named_first_acquisition), named_first_acquisition
        assert not before_launch_marker.exists()
        crash = fixture.crash_host(host, state, "before-launch-crash", milestones)
        host = None
        milestones = None
        assert crash["returncode"] == -signal.SIGKILL
        before_launch_gate.release()
        before_launch_gate = None
        host = fixture.start_host(store, endpoint_url)
        assert not list((store / "scratch").glob("bash-*-*.tmp"))
        fixture.wait_for(
            lambda: resolution(store, session) == "indeterminate",
            "pre-launch indeterminate recovery",
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "before-launch-message"),
            "pre-launch recovery continuation",
        )
        assert not before_launch_marker.exists()

        session = configure(state, store, "changed-config")
        fixture.message(state, store, "changed-message", session, "execute")
        changed_action = fixture.wait_for(
            lambda: action_for(store, session), "changed Bash Action"
        )
        allow(state, store, "changed-allow", session, changed_action["action"])
        fixture.wait_for(lambda: changed_marker.exists(), "Bash side effect")
        crash = fixture.crash_host(host, state, "changed-crash")
        host = None
        assert crash["returncode"] == -signal.SIGKILL
        host = fixture.start_host(store, endpoint_url)
        fixture.wait_for(
            lambda: resolution(store, session) == "indeterminate",
            "changed-command indeterminate recovery",
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "changed-message"),
            "changed-command recovery continuation",
        )
        assert changed_marker.read_text() == "x"

        session = configure(state, store, "stop-config")
        fixture.message(state, store, "stop-message", session, "execute")
        stop_action = fixture.wait_for(lambda: action_for(store, session), "stoppable Bash Action")
        fixture.wait_for(lambda: execution_custody_idle(store, session), "stop proposal custody release")
        stop_baseline = int(fixture.command("session", "inspect", "--store", store, "--session", session)
                            ["execution"]["scratch_used_bytes"])
        allow(state, store, "stop-allow", session, stop_action["action"])
        fixture.wait_for(stop_pid.exists, "stoppable Bash with supplied stdin launched")
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "session", "inspect", "--store", store, "--session", session
                )["execution"]["custody_occupied"]
            )
            > 0,
            "launched stoppable Bash",
        )
        active_resources = fixture.command(
            "session", "inspect", "--store", store, "--session", session
        )["execution"]
        assert int(active_resources["scratch_used_bytes"]) == stop_baseline + 122880, active_resources
        assert not list((store / "scratch").glob("bash-stdin-*.tmp")), "input name remained linked after launch"
        resource_samples.append(
            {
                "phase": "active-descendant-pipes",
                **process_resources(host),
                **scratch_resources(store),
                "accounted_scratch_bytes": int(active_resources["scratch_used_bytes"]),
            }
        )
        stopped = fixture.command(
            "session", "stop",
            "--store",
            store,
            "--record",
            state / "stop.json",
            "--key",
            "stop",
            "--session",
            session,
        )
        assert stopped["answer"]["status"] == "accepted", stopped
        assert stopped["completion"]["status"] == "pending", stopped
        fixture.wait_for(lambda: resolution(store, session) == "cancelled", "cancelled Bash")
        fixture.wait_for(lambda: execution_custody_idle(store, session), "cancelled stdin custody release")
        assert int(fixture.command("session", "inspect", "--store", store, "--session", session)
                   ["execution"]["scratch_used_bytes"]) == stop_baseline
        fixture.stop_host(host)
        assert rows(store, "SELECT outcome_code FROM turn WHERE session_ref=?", (session,)) == [
            ("cancelled",)
        ]

        settlement_gate = ReleaseGate(state / "settlement-result-gate")
        settlement_cleanup_gate.touch()
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-transition",
            "action-result-ready",
            "--test-transition-gate-path",
            settlement_gate.path,
            "--test-bash-cleanup-gate-path",
            settlement_cleanup_gate,
            "--test-phase-trace",
        )
        milestones = HostDiagnostics(host)
        session = configure(state, store, "settlement-stop-config")
        fixture.message(
            state,
            store,
            "settlement-stop-message",
            session,
            "execute",
        )
        settlement_stop_action = fixture.wait_for(
            lambda: action_for(store, session),
            "settlement-stop Bash Action",
        )
        allow(
            state,
            store,
            "settlement-stop-allow",
            session,
            settlement_stop_action["action"],
        )
        milestones.wait(
            "action_result_ready",
            action=str(settlement_stop_action["action"]),
        )
        fixture.command(
            "session", "stop",
            "--store",
            store,
            "--record",
            state / "settlement-stop.json",
            "--key",
            "settlement-stop",
            "--session",
            session,
        )
        settlement_gate.release()
        fixture.wait_for(
            lambda: resolution(store, session) == "cancelled",
            "stop winning sealed Bash settlement",
        )
        assert result_text(store, session) == "Cancelled by Session stop."
        assert int(
            fixture.command(
                "session", "inspect", "--store", store, "--session", session
            )["execution"]["custody_occupied"]
        ) > 0
        settlement_cleanup_gate.unlink()
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "session", "inspect", "--store", store, "--session", session
                )["execution"]["custody_occupied"]
            )
            == 0,
            "post-settlement Bash cleanup",
        )
        fixture.stop_host(host)
        host, milestones = None, None
        host = fixture.start_host(store, endpoint_url)

        session = configure(state, store, "exited-pipes-config")
        fixture.message(state, store, "exited-pipes-message", session, "execute")
        exited_action = fixture.wait_for(
            lambda: action_for(store, session), "exited-with-open-pipes Action"
        )
        allow(state, store, "exited-pipes-allow", session, exited_action["action"])
        fixture.wait_for(
            exited_child_pid.exists,
            "descendant process identity",
        )
        child_pid = int(exited_child_pid.read_text())
        assert process_exists(child_pid)
        exited_pipes_leader_release.touch()
        fixture.wait_for(
            lambda: resolution(store, session) == "succeeded",
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
            observations="bash_pipes",
        )
        milestones = HostDiagnostics(host)
        session = configure(state, store, "stopped-pipes-config")
        fixture.message(state, store, "stopped-pipes-message", session, "execute")
        stopped_pipes_action = fixture.wait_for(
            lambda: action_for(store, session), "stopped-with-open-pipes Action"
        )
        allow(
            state,
            store,
            "stopped-pipes-allow",
            session,
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
            "session", "stop",
            "--store",
            store,
            "--record", state / "stopped-pipes-stop.json",
            "--key",
            "stopped-pipes-stop",
            "--session",
            session,
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
            lambda: resolution(store, session) == "cancelled",
            "stop after observed leader exit with descendant pipes open",
            timeout=20,
        )
        fixture.wait_for(lambda: not process_exists(stopped_child), "stopped Bash descendant cleanup")

        fixture.stop_host(host)
        host = None
        assert len(milestones.matching("bash_leader_observed_with_open_pipes")) == 1, milestones.records
        assert Counter(r["subject"] for r in milestones.matching("control_store_complete")) == Counter(
            ("stopped-pipes-allow", "stopped-pipes-stop")), milestones.records
        assert len(milestones.records) == 3, milestones.records
        milestones = None
        host = fixture.start_host(store, endpoint_url, "--bash-timeout-ms", "30000")
        session = configure(state, store, "timeout-config")
        fixture.message(state, store, "timeout-message", session, "execute")
        timeout_action = fixture.wait_for(
            lambda: action_for(store, session), "timeout Bash Action"
        )
        allow(state, store, "timeout-allow", session, timeout_action["action"])
        fixture.wait_for(
            lambda: resolution(store, session) == "timed_out",
            "timed-out Bash",
            timeout=20,
        )
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "timeout-message"), "timeout continuation"
        )

        session = configure(state, store, "detached-timeout-config")
        fixture.message(
            state, store, "detached-timeout-message", session, "execute"
        )
        detached_action = fixture.wait_for(
            lambda: action_for(store, session), "detached timeout Action"
        )
        allow(
            state,
            store,
            "detached-timeout-allow",
            session,
            detached_action["action"],
        )
        fixture.wait_for(
            detached_pid.exists,
            "detached writer identity",
        )
        detached_process = int(detached_pid.read_text())
        fixture.wait_for(
            lambda: resolution(store, session) == "succeeded",
            "detached writer leader result",
            timeout=20,
        )
        result = result_text(store, session)
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
                    "session", "inspect",
                    "--store",
                    store,
                    "--session",
                    session,
                )["execution"]["custody_occupied"]
            )
            == 0,
            "detached timeout custody release",
        )
        os.kill(detached_process, signal.SIGKILL)
        detached_process = None

        session = configure(state, store, "same-group-timeout-config")
        fixture.message(
            state, store, "same-group-timeout-message", session, "execute"
        )
        same_group_action = fixture.wait_for(
            lambda: action_for(store, session), "same-group timeout Action"
        )
        allow(
            state,
            store,
            "same-group-timeout-allow",
            session,
            same_group_action["action"],
        )
        fixture.wait_for(lambda: same_group_pid.exists(), "same-group child identity")
        same_group_process = int(same_group_pid.read_text())
        fixture.wait_for(
            lambda: resolution(store, session) == "timed_out",
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

        session = configure(state, store, "busy-output-config")
        fixture.message(state, store, "busy-output-message", session, "execute")
        busy_output_action = fixture.wait_for(
            lambda: action_for(store, session), "busy-output Bash Action"
        )
        allow(
            state,
            store,
            "busy-output-allow",
            session,
            busy_output_action["action"],
        )
        fixture.wait_for(
            lambda: resolution(store, session) == "succeeded",
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
        session = configure(state, store, "cleanup-config")
        fixture.message(state, store, "cleanup-message", session, "execute")
        cleanup_action = fixture.wait_for(
            lambda: action_for(store, session), "cleanup-failure Bash Action"
        )
        allow(state, store, "cleanup-allow", session, cleanup_action["action"])
        fixture.wait_for(
            lambda: resolution(store, session) == "succeeded",
            "known result before cleanup failure",
        )
        cleanup_report = fixture.command(
            "session", "inspect", "--store", store, "--session", session
        )
        assert cleanup_report["execution"]["dispatch_fenced"] is True, cleanup_report
        assert int(cleanup_report["execution"]["custody_occupied"]) > 0, cleanup_report
        assert list((store / "scratch").glob("bash-*-*.tmp"))
        cleanup_gate.unlink()
        fixture.wait_for(
            lambda: fixture.command(
                "session", "inspect", "--store", store, "--session", session
            )["execution"]["custody_occupied"]
            == "0",
            "cleanup-failure original owner reclamation",
        )
        cleanup_attempt = f"{cleanup_action['action']}-1.tmp"
        assert (store / "scratch" / f"bash-stdout-{cleanup_attempt}").exists()
        assert (store / "scratch" / f"bash-stderr-{cleanup_attempt}").exists()
        fixture.stop_host(host)
        host = fixture.start_host(store, endpoint_url)
        assert resolution(store, session) == "succeeded"
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
            session = configure(state, store, f"{name}-config")
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
            "bash-preparation-after-captures",
            "--fault",
            "bash-cleanup",
            "--fault",
            "bash-fault-gated",
        )
        preparation_cleanup_gate = store / "scratch" / "bash-fault-gate"
        preparation_cleanup_gate.write_text("blocked")
        session = configure(state, store, "preparation-cleanup-config")
        fixture.message(
            state,
            store,
            "preparation-cleanup-message",
            session,
            "execute",
        )
        action = fixture.wait_for(
            lambda: action_for(store, session),
            "preparation-cleanup Bash Action",
        )
        allow(
            state,
            store,
            "preparation-cleanup-allow",
            session,
            action["action"],
        )
        fixture.wait_for(
            lambda: resolution(store, session) == "storage_failed",
            "preparation failure settlement",
        )
        assert int(
            fixture.command(
                "session", "inspect", "--store", store, "--session", session
            )["execution"]["custody_occupied"]
        ) > 0
        preparation_captures = [
            store / "scratch" / f"bash-{stream}-{action['action']}-1.tmp"
            for stream in ("stdout", "stderr")
        ]
        assert all(capture.exists() for capture in preparation_captures)
        preparation_cleanup_gate.unlink()
        fixture.wait_for(
            lambda: not any(capture.exists() for capture in preparation_captures),
            "preparation cleanup by original owner",
        )
        fixture.wait_for(
            lambda: int(
                fixture.command(
                    "session", "inspect",
                    "--store",
                    store,
                    "--session",
                    session,
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
        session = configure(state, store, "service-config")
        fixture.message(state, store, "service-message", session, "execute")
        action = fixture.wait_for(lambda: action_for(store, session), "service Bash Action")
        allow(state, store, "service-allow", session, action["action"])
        fixture.wait_for(lambda: host.poll() is not None, "persistent Bash service failure shutdown")
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
            session = configure(state, store, f"{name}-config")
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

        post_resolution_gate = state / "post-resolution-cleanup-gate"
        post_resolution_gate.write_text("blocked")
        host = fixture.start_host(
            store,
            endpoint_url,
            "--test-bash-cleanup-gate-path",
            post_resolution_gate,
        )
        session = configure(state, store, "post-resolution-config", "bypass")
        fixture.message(state, store, "post-resolution-message", session, "execute")
        fixture.wait_for(
            lambda: resolution(store, session) == "succeeded",
            "post-Resolution Bash result",
        )
        fixture.wait_for(
            lambda: fixture.command(
                "session", "inspect", "--store", store, "--session", session
            )["execution"]["custody_occupied"]
            == "1",
            "post-Resolution held Bash cleanup",
        )
        fixture.command(
            "session", "stop",
            "--store",
            store,
            "--record",
            state / "post-resolution-stop.json",
            "--key",
            "post-resolution-stop",
            "--session",
            session,
        )
        assert resolution(store, session) == "succeeded"
        post_resolution_gate.unlink()
        fixture.wait_for(
            lambda: fixture.command(
                "session", "inspect", "--store", store, "--session", session
            )["execution"]["custody_occupied"]
            == "0",
            "post-Resolution physical cleanup",
        )
        assert resolution(store, session) == "succeeded"
        fixture.stop_host(host)
        host = None

        host = fixture.start_host(store, endpoint_url, active_capacity=2)
        session = configure(state, store, "sibling-config", "bypass")
        fixture.message(state, store, "sibling-message", session, "execute")
        # Observe the second sibling's durable result before releasing the first;
        # command duration alone cannot establish canonical acceptance order.
        def second_sibling_settled():
            actions = list(action_rows_by_id(store, session).values())
            return len(actions) == 2 and {
                row["call_ordinal"]: row["resolution"] for row in actions
            } == {"0": None, "1": "succeeded"}

        fixture.wait_for(second_sibling_settled, "second sibling accepted while first is held")
        assert sibling_marker.read_text() == "b"
        sibling_release.touch()
        fixture.wait_for(
            lambda: fixture.completed_observation(store, "sibling-message"),
            "independent sibling continuation",
        )
        sibling_rows = fixture.command(
            "session", "inspect",
            "--store",
            store,
            "--session",
            session,
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
            "session", "inspect", "--store", store, "--session", session
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
        assert settled[0] == settled[1] == 29 and settled[2] > 0, settled
        print(json.dumps({"bash_resource_samples": resource_samples}, sort_keys=True))
        completed = True
    finally:
        incoming_error = sys.exc_info()[1]
        cleanup_errors = []
        cleanups = []
        if stopped_pipes_stop is not None and stopped_pipes_stop.poll() is None:
            cleanups.extend((stopped_pipes_stop.kill, lambda: stopped_pipes_stop.wait(timeout=10)))
        if observed_exit_gate_keeper is not None:
            cleanups.extend((lambda: os.write(observed_exit_gate_keeper, b"x"),
                             lambda: os.close(observed_exit_gate_keeper)))
        if observed_exit_gate is not None:
            cleanups.append(lambda: observed_exit_gate.unlink(missing_ok=True))
        if before_launch_gate is not None:
            cleanups.append(before_launch_gate.release)
        if settlement_gate is not None:
            cleanups.append(settlement_gate.release)
        cleanups.append(lambda: settlement_cleanup_gate.unlink(missing_ok=True))
        cleanups.append(sibling_release.touch)
        if host is not None:
            cleanups.append(lambda: fixture.stop_host(host))
        if detached_process is not None and process_exists(detached_process):
            cleanups.append(lambda: os.kill(detached_process, signal.SIGKILL))

        def join_endpoint():
            endpoint_thread.join(timeout=5)
            assert not endpoint_thread.is_alive(), "Bash endpoint thread did not retire"

        cleanups.extend((endpoint.shutdown, endpoint.server_close, join_endpoint))
        for cleanup in cleanups:
            try:
                cleanup()
            except BaseException as error:
                cleanup_errors.append(error)  # Attempt every owned resource.
        if completed and incoming_error is None and not cleanup_errors:
            shutil.rmtree(state)
        else:
            try:
                retain_failure_state("Bash integration failure state", state)
            except Exception:
                pass  # Reporting cannot replace the original failure.
        if cleanup_errors:
            for error in cleanup_errors:
                try:
                    print(f"Bash cleanup failed: {type(error).__name__}: {error}", file=sys.stderr)
                except Exception:
                    pass
            if incoming_error is None:
                raise cleanup_errors[0]
            incoming_error.add_note("Bash cleanup failed: " + ", ".join(
                type(error).__name__ for error in cleanup_errors
            ))


if __name__ == "__main__":
    host_process.enter()
    if sys.argv[2:] == ["--walkthrough"]:
        walkthrough()
    elif sys.argv[2:]:
        raise SystemExit("usage: bash_integration.py RUI [--walkthrough]")
    else:
        main()
