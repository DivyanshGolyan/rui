#!/usr/bin/env python3
"""Public one-shot caller recovery and exact Bash authorization."""
import json
import os
import pathlib
import pty
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

import dispatch_integration as fixture


def run(home, *args, success=True, environment=None):
    env = {**os.environ, "HOME": str(home), **(environment or {})}
    result = subprocess.run([str(fixture.RUI), *map(str, args)], env=env, capture_output=True, text=True, timeout=20)
    if success:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (args, result.stdout, result.stderr)
    return result.stdout


def admit(home, *args):
    captured, admission = map(json.loads, run(home, *args, "--json").splitlines())
    assert captured == {"event": "captured", "request": admission["request"]}, (captured, admission)
    assert admission["event"] == "admission", admission
    return admission


def read_terminal(master, marker, timeout=15):
    output = b""
    deadline = time.monotonic() + timeout
    while marker.encode() not in output:
        remaining = deadline - time.monotonic()
        assert remaining > 0, (marker, output.decode(errors="replace"))
        assert select.select([master], [], [], remaining)[0], (marker, output.decode(errors="replace"))
        output += os.read(master, 65536)
        assert len(output) < 1024 * 1024, "unexpected unbounded terminal output"
    return output.decode(errors="replace").replace("\r\n", "\n")


def terminal_step(master, command, marker="rui> "):
    os.write(master, (command + "\n").encode())
    return read_terminal(master, marker)


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-human-cli."))
    home = state / "home"
    home.mkdir()
    store = state / "store"
    workspace = state / "workspace"
    workspace.mkdir()
    session = "human/bash"
    counter = workspace / "effect-count"
    arguments = json.dumps({"cmd": "printf x >> effect-count", "timeout_ms": None}, separators=(",", ":"))
    control_call = "human-call\x1b[1Ghidden\u202e"
    control_arguments = arguments + "\r  "
    sibling_started = state / "sibling-started"
    sibling_release = state / "sibling-release"
    sibling_effect = workspace / "sibling-effect"
    sibling_arguments = json.dumps({"cmd": f"touch {shlex.quote(str(sibling_started))}; "
        f"while [ ! -e {shlex.quote(str(sibling_release))} ]; do sleep 0.05; done; "
        "printf y >> sibling-effect", "timeout_ms": None}, separators=(",", ":"))
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("human-calls", [("bash", control_call, control_arguments)]),
        fixture.sse_answer("human-answer", "human-reason", "human-message", "first answer")[0],
        fixture.sse_answer("second-answer", "second-reason", "second-message", "second answer")[0],
        fixture.sse_tool_calls("sibling-calls", [("bash", "pending-call", arguments),
            ("bash", "running-call", sibling_arguments)]),
        fixture.sse_answer("sibling-answer", "sibling-reason", "sibling-message", "siblings done")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    host = None
    failure_release = None
    stop_release = None
    race_predecessor_release = threading.Event()
    race_message_release = threading.Event()
    race_follower = None
    race_waiter = None
    terminal_waiter = None
    race_gate = state / "follow-queued-before-current"
    wait_gate = state / "wait-active-before-current"
    completed = False
    try:
        host = fixture.start_host(store, url)
        config = admit(home, "configure", "--store", store, "--session", session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert config["admission"]["answer"]["status"] == "accepted", config
        assert json.loads(run(home, "wait-session", "--store", store, "--session", session,
            "--json")) == {"return": "idle"}
        initial = fixture.command("inspect-session", "--store", store, "--session", session)
        assert initial["selected_message"] is None and initial["recent_messages"] == [], initial
        assert "InteractiveTerminalRequired" in subprocess.run(
            [str(fixture.RUI), "session", "--store", str(store), "--session", session],
            env={**os.environ, "HOME": str(home)}, capture_output=True, text=True, timeout=5).stderr
        assert config["request"] in json.loads(run(home, "requests", "--json"))
        assert json.loads(run(home, "recover", config["request"], "--json"))["answer"]["replayed"] is True
        assert run(home, "recover", config["request"]) == "admitted: accepted\nreplayed: true\n"

        text = state / "input"
        text.write_text("first input")
        dropped = run(home, "message", "--store", store, "--session", session,
            "--text", text, "--test-drop-reply", "after-commit", success=False)
        first = dropped.split("request: ", 1)[1].splitlines()[0]
        record = home / ".config/rui/requests" / f"{first}.json"
        captured = record.read_bytes()
        assert json.loads(captured)["text"]["value"] == "first input"
        text.write_text("changed after capture")
        assert first in run(home, "requests").splitlines()
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "first provider request")
        recovered = json.loads(run(home, "recover", first, "--json"))
        assert recovered["answer"]["status"] == "accepted" and recovered["answer"]["replayed"] is True
        assert record.read_bytes() == captured
        assert len(endpoint.requests) == 1, endpoint.requests

        attention = run(home, "follow", first)
        assert "return: attention" in attention and "status: waiting_for_permission" in attention, attention
        action = attention.split("action: ", 1)[1].splitlines()[0]
        selected, blocked = map(json.loads, run(home, "wait-session", "--store", store,
            "--session", session, "--json").splitlines())
        assert selected == {"event": "selection", "session": session, "message": first}, selected
        assert blocked == {"return": "attention", "status": "waiting_for_permission", "action": action}, blocked
        terminal_waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", session, "--terminal", "--json"],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert json.loads(terminal_waiter.stdout.readline()) == selected
        time.sleep(0.1)
        assert terminal_waiter.poll() is None, "terminal-only wait returned on permission"
        queued = admit(home, "message", "--store", store, "--session", session,
            "queued behind permission")["request"]
        assert run(home, "result", queued) == "result: queued\n"
        scratch = state / "render-scratch"
        scratch.mkdir()
        render_environment = {"TMPDIR": str(scratch)}
        queued_attention = json.loads(run(home, "follow", queued, "--json", environment=render_environment))
        assert queued_attention == {"return": "attention", "status": "waiting_for_permission", "action": action}, queued_attention
        presentation = run(home, "inspect-action", "--store", store, "--session", session, "--action", action)
        assert f"Action {action}\n" in presentation, presentation
        assert json.loads(presentation.split("call ID: ", 1)[1].splitlines()[0]) == control_call, presentation
        assert json.loads(presentation.split("Bash arguments: ", 1)[1].splitlines()[0]) == control_arguments, presentation
        assert "\\u001b" in presentation and "\\u202e" in presentation and "\\r  " in presentation, presentation
        assert "\x1b" not in presentation and "\u202e" not in presentation and "\r" not in presentation, presentation
        fresh_home = state / "fresh-home"
        fresh_home.mkdir()
        assert not (fresh_home / ".config").exists()
        assert json.loads(run(fresh_home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json", environment=render_environment)) == {"action": action, "call_id": control_call, "arguments": control_arguments}
        assert not (fresh_home / ".config").exists()
        assert list(scratch.iterdir()) == []
        unavailable = subprocess.run([str(fixture.RUI), "inspect-action", "--store", str(store),
            "--session", session, "--action", action, "--json"],
            env={**os.environ, "HOME": str(fresh_home), "TMPDIR": str(state / "missing-scratch")},
            capture_output=True, text=True, timeout=20)
        assert unavailable.returncode != 0 and unavailable.stdout == "", unavailable
        exact = json.loads(run(home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json"))
        assert exact == {"action": action, "call_id": control_call, "arguments": control_arguments}, exact
        assert run(home, "result", first) == "result: processing\n"
        assert not counter.exists()

        lost_decision = run(home, "allow-action", "--store", store, "--session", session,
            "--action", action, "--test-drop-reply", "after-commit", success=False)
        decision_key = lost_decision.split("request: ", 1)[1].splitlines()[0]
        assert decision_key in run(home, "requests").splitlines()
        recovered_decision = json.loads(run(home, "recover", decision_key, "--json"))["answer"]
        assert recovered_decision["status"] == "accepted" and recovered_decision["replayed"] is True
        fixture.wait_for(lambda: fixture.completed_observation(store, first), "first saved answer")
        fixture.wait_for(lambda: fixture.completed_observation(store, queued), "queued answer after permission")
        terminal_output, terminal_error = terminal_waiter.communicate(timeout=10)
        assert terminal_waiter.returncode == 0 and json.loads(terminal_output)["observation"]["result"]["status"] == "completed", terminal_error
        terminal_waiter = None
        stale = admit(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        assert stale["admission"]["answer"]["status"] == "rejected", stale
        assert run(home, "result", queued) == "result: completed\nfirst answer\n"
        current = fixture.command("inspect-session", "--store", store, "--session", session)
        assert current["selected_message"] is None and [r["message"] for r in current["recent_messages"]] == [queued, first], current
        assert [r["outcome"] for r in current["recent_messages"]] == ["completed", "completed"], current
        assert json.loads(run(home, "wait-session", "--store", store, "--session", session,
            "--json")) == {"return": "idle"}
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", session], env={**os.environ, "HOME": str(fresh_home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            greeting = read_terminal(master, "rui> ")
            assert f"Session: {session}" in greeting and f"Workspace (Bash cwd): {workspace}" in greeting, greeting
            assert "Permission: ask" in greeting and queued in greeting and first in greeting, greeting
            assert "first answer" in terminal_step(master, f"/result {queued}")
            assert "Local recovery handles" in terminal_step(master, "/requests")
            assert not (fresh_home / ".config/rui/requests").exists(), "re-entry should not require saved records"
            assert "return: idle" in terminal_step(master, "/wait")
            assert "Usage: /configure" in terminal_step(master, "/configure --session human/other")
            configured = terminal_step(master, "/configure --model model-a")
            assert "admitted: accepted" in configured, configured
            assert f"Session: {session}" in terminal_step(master, "/status")
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        assert run(home, "follow", queued) == "return: outcome\nstatus: completed\n"
        assert run(home, "recover", stale["request"]) == "admitted: rejected\nreplayed: true\ncode: action_not_pending\n"
        stale_default = run(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        assert stale_default.splitlines()[1:] == ["admitted: rejected", "replayed: false", "code: action_not_pending"], stale_default
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        completed_result = json.loads(run(home, "result", first, "--json", environment=render_environment))
        assert completed_result["answer"] == "first answer"
        assert completed_result["observation"]["result"]["status"] == "completed"
        assert list(scratch.iterdir()) == []
        completed_follow = json.loads(run(home, "follow", first, "--json"))
        assert completed_follow["return"] == "outcome"
        assert completed_follow["observation"]["result"]["status"] == "completed"
        assert counter.read_text() == "x"

        before = set(run(home, "requests").splitlines())
        gate = state / "captured-before-handle"
        caller = subprocess.Popen(
            [str(fixture.RUI), "message", "--store", str(store), "--session", session,
             "--text", str(text), "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_CAPTURE_GATE": str(gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        fixture.wait_for(lambda: pathlib.Path(f"{gate}.ready").exists(), "durable capture before handle output")
        after = set(run(home, "requests").splitlines())
        assert len(after - before) == 1, (before, after)
        second = (after - before).pop()
        assert caller.poll() is None
        assert fixture.command("observe-command", "--store", store,
            "--key", second)["observation"]["status"] == "absent"
        caller.kill()
        output, _ = caller.communicate(timeout=5)
        assert caller.returncode == -signal.SIGKILL and output == b"", output
        assert second != first
        text.unlink()
        initial_recovery = json.loads(run(home, "recover", second, "--json"))["answer"]
        assert initial_recovery["status"] == "accepted" and initial_recovery["replayed"] is False
        fixture.wait_for(lambda: fixture.completed_observation(store, second), "second saved answer")
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        assert run(home, "result", second) == "result: completed\nsecond answer\n"
        assert counter.read_text() == "x" and len(endpoint.requests) == 3

        fixture.stop_host(host)
        host = fixture.start_host(store, url, active_capacity=2)
        sibling_session = "human/siblings"
        sibling_config = run(home, "configure", "--store", store, "--session", sibling_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert f"configuration: {sibling_session} in {store}" in sibling_config
        assert "next: rui session (same Store and Session)" in sibling_config
        sibling_key = admit(home, "message", "--store", store, "--session", sibling_session,
            "two independent Actions")["request"]
        def two_actions():
            candidate = fixture.command("inspect-session", "--store", store, "--session", sibling_session)
            return candidate if len(candidate["actionable_permissions"]) == 2 else None

        report = fixture.wait_for(two_actions, "two actionable siblings")
        pending, running = [row["action"] for row in report["actionable_permissions"]]
        run(home, "allow-action", "--store", store, "--session", sibling_session,
            "--action", running)
        fixture.wait_for(lambda: sibling_started.exists(), "approved sibling in flight")
        attention = run(home, "follow", sibling_key, "--json")
        assert json.loads(attention) == {"return": "attention", "status": "in_flight", "action": pending}, attention
        assert run(home, "result", sibling_key) == "result: processing\n"
        run(home, "deny-action", "--store", store, "--session", sibling_session,
            "--action", pending)
        sibling_release.touch()
        fixture.wait_for(lambda: fixture.completed_observation(store, sibling_key), "sibling outcome")
        assert run(home, "result", sibling_key) == "result: completed\nsiblings done\n"
        assert sibling_effect.read_text() == "y" and counter.read_text() == "x"

        failure_release = threading.Event()
        endpoint.responses.extend([
            (fixture.ResponseSpec(b"permanent failure", {}, 422), failure_release),
            fixture.sse_answer("successor-answer", "successor-reason", "successor-message", "successor done")[0],
        ])
        failure_session = "human/failure"
        run(home, "configure", "--store", store, "--session", failure_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        failed_key = admit(home, "message", "--store", store, "--session", failure_session,
            "first failing Turn")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 6, "held first failed Turn")
        queued_key = admit(home, "message", "--store", store, "--session", failure_session,
            "queued successor")["request"]
        assert run(home, "result", queued_key) == "result: queued\n"
        follower = subprocess.Popen([str(fixture.RUI), "follow", failed_key],
            env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.15)
        assert follower.poll() is None, follower.communicate(timeout=5)
        follower.kill()
        follower.communicate(timeout=5)
        failure_release.set()
        fixture.wait_for(lambda: fixture.command("observe-command", "--store", store,
            "--key", failed_key)["observation"].get("result"), "failed first Turn")
        assert run(home, "result", failed_key) == "result: failed\ncode: provider_http_422\n"
        fixture.wait_for(lambda: fixture.completed_observation(store, queued_key), "queued successor")
        assert run(home, "result", queued_key) == "result: completed\nsuccessor done\n"

        stop_release = threading.Event()
        endpoint.responses.append((fixture.sse_answer("stopped-answer", "stopped-reason",
            "stopped-message", "must not appear")[0], stop_release))
        stop_session = "human/stopped"
        run(home, "configure", "--store", store, "--session", stop_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        stopped_key = admit(home, "message", "--store", store, "--session", stop_session,
            "running when stopped")["request"]
        fixture.wait_for(lambda: len(endpoint.requests) == 8, "held stopped Turn")
        excluded_key = admit(home, "message", "--store", store, "--session", stop_session,
            "queued when stopped")["request"]
        assert run(home, "result", excluded_key) == "result: queued\n"
        stopped = fixture.command("stop-session", "--store", store, "--session", stop_session,
            "--record", state / "stop.json", "--key", "human-stop")
        assert stopped["answer"]["status"] == "accepted", stopped
        stop_release.set()
        fixture.wait_for(lambda: fixture.command("observe-command", "--store", store,
            "--key", stopped_key)["observation"].get("result"), "stopped Turn")
        assert run(home, "result", stopped_key).startswith("result: cancelled\n")
        assert run(home, "result", excluded_key) == "result: cancelled\ncode: session_stopped\n"

        rejected = admit(home, "message", "--store", store, "--session", "human/absent",
            "unknown session")
        assert rejected["admission"]["answer"]["status"] == "rejected", rejected
        assert run(home, "result", rejected["request"]) == "result: rejected\ncode: unknown_session\n"
        assert run(home, "recover", rejected["request"]) == "admitted: rejected\nreplayed: true\ncode: unknown_session\n"

        large_answer = "x" * 4095 + "🍰" + "y" * (128 * 1024)
        endpoint.responses.append(fixture.sse_answer("large-answer", "large-reason",
            "large-message", large_answer)[0])
        large_session = "human/large"
        run(home, "configure", "--store", store, "--session", large_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a")
        large_key = admit(home, "message", "--store", store, "--session", large_session,
            "large output")["request"]
        fixture.wait_for(lambda: fixture.completed_observation(store, large_key), "large saved answer")
        reader = subprocess.Popen([str(fixture.RUI), "result", large_key, "--json"],
            env={**os.environ, "HOME": str(home), **render_environment},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert reader.stdout.read(256).startswith(b'{"observation":')
            assert reader.poll() is None, "large result should block on unread stdout"
            assert list(scratch.iterdir()) == [], "rendering must not leave a named payload"
        finally:
            if reader.poll() is None:
                reader.kill()
            reader.communicate(timeout=5)
        assert reader.returncode == -signal.SIGKILL and list(scratch.iterdir()) == []
        assert json.loads(run(home, "result", large_key, "--json", environment=render_environment))["answer"] == large_answer

        fixture.crash_host(host, state, "human-cli-crash")
        failed_observation = run(home, "result", first, success=False)
        assert failed_observation == "", failed_observation
        host = fixture.start_host(store, url)
        assert json.loads(run(home, "recover", first, "--json"))["answer"]["replayed"] is True
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        recovered_session = fixture.command("inspect-session", "--store", store, "--session", session)
        assert recovered_session["selected_message"] is None
        assert [row["message"] for row in recovered_session["recent_messages"]] == [second, queued, first]
        assert counter.read_text() == "x" and sibling_effect.read_text() == "y" and len(endpoint.requests) == 9

        endpoint.responses.extend([
            (fixture.sse_answer("race-prior", "race-prior-reason", "race-prior-message", "prior done")[0], race_predecessor_release),
            (fixture.sse_answer("race-a", "race-a-reason", "race-a-message", "A done")[0], race_message_release),
            fixture.sse_tool_calls("race-b", [("bash", "race-b-call", arguments)]),
            fixture.sse_answer("race-b-done", "race-b-done-reason", "race-b-done-message", "B done")[0],
        ])
        race_session = "human/follow-race"
        run(home, "configure", "--store", store, "--session", race_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        prior_receipt = run(home, "message", "--store", store, "--session", race_session, "prior")
        prior = prior_receipt.split("request: ", 1)[1].splitlines()[0]
        assert f"message: {race_session} in {store}" in prior_receipt
        assert f"next: rui follow {prior}" in prior_receipt
        fixture.wait_for(lambda: len(endpoint.requests) == 10, "held predecessor request")
        message_a = admit(home, "message", "--store", store, "--session", race_session, "A")["request"]
        assert run(home, "result", message_a) == "result: queued\n"
        race_follower = subprocess.Popen([str(fixture.RUI), "follow", message_a, "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_FOLLOW_GATE": str(race_gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: pathlib.Path(f"{race_gate}.ready").exists(), "queued A observed by follower")
        assert race_follower.poll() is None
        assert run(home, "result", message_a) == "result: queued\n"
        race_predecessor_release.set()
        fixture.wait_for(lambda: len(endpoint.requests) == 11, "A processing request")
        race_waiter = subprocess.Popen([str(fixture.RUI), "wait-session", "--store", str(store),
            "--session", race_session, "--json"],
            env={**os.environ, "HOME": str(home), "RUI_TEST_FOLLOW_GATE": str(wait_gate)},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        fixture.wait_for(lambda: pathlib.Path(f"{wait_gate}.ready").exists(), "Session wait selected A")
        race_message_release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, message_a), "A outcome before Current")
        fixture.wait_for(lambda: fixture.completed_observation(store, prior), "predecessor completion")
        message_b = admit(home, "message", "--store", store, "--session", race_session, "B")["request"]
        def b_action():
            report = fixture.command("inspect-session", "--store", store, "--session", race_session)
            return report["actionable_permissions"][0]["action"] if report["actionable_permissions"] else None

        action_b = fixture.wait_for(b_action, "B permission before Current")
        pathlib.Path(f"{race_gate}.release").touch()
        pathlib.Path(f"{wait_gate}.release").touch()
        output, error = race_follower.communicate(timeout=10)
        assert race_follower.returncode == 0, (output, error)
        followed = json.loads(output)
        assert followed["return"] == "outcome" and followed["observation"]["result"]["status"] == "completed", followed
        assert followed["observation"]["target"] == race_session, followed
        race_follower = None
        wait_output, wait_error = race_waiter.communicate(timeout=10)
        assert race_waiter.returncode == 0, wait_error
        selection, observed = map(json.loads, wait_output.splitlines())
        assert selection["message"] == prior and observed["return"] == "outcome", wait_output
        assert observed["observation"]["result"]["status"] == "completed", wait_output
        race_waiter = None
        assert b_action() == action_b
        assert json.loads(run(home, "inspect-action", "--store", store, "--session", race_session,
            "--action", action_b, "--json"))["call_id"] == "race-b-call"
        denied = admit(home, "deny-action", "--store", store, "--session", race_session,
            "--action", action_b)
        assert denied["admission"]["answer"]["status"] == "accepted", denied
        fixture.wait_for(lambda: fixture.completed_observation(store, message_b), "B outcome after decision")
        endpoint.responses.extend([
            fixture.sse_tool_calls("interactive-call", [("bash", "interactive-bash", arguments)]),
            fixture.sse_answer("interactive-answer", "interactive-reason", "interactive-message",
                "interactive complete")[0],
        ])
        interactive = "human/interactive"
        run(home, "configure", "--store", store, "--session", interactive,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        master, slave = pty.openpty()
        entered = subprocess.Popen([str(fixture.RUI), "session", "--store", str(store),
            "--session", interactive], env={**os.environ, "HOME": str(home)},
            stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        try:
            assert "Work: idle" in read_terminal(master, "rui> ")
            proposal = terminal_step(master, "interactive request", "Allow once, deny, or later?")
            assert "interactive-bash" in proposal and arguments in proposal, proposal
            interactive_key = proposal.split("request: ", 1)[1].splitlines()[0]
            action_id = proposal.split("Action ", 1)[1].splitlines()[0]
            mismatch = admit(home, "allow-action", "--store", store, "--session", session,
                "--action", action_id)
            assert mismatch["admission"]["answer"]["status"] == "rejected", mismatch
            assert mismatch["admission"]["answer"]["code"] == "target_mismatch", mismatch
            assert "No decision sent" in terminal_step(master, "l")
            assert "interactive-bash" in terminal_step(master, "/wait", "Allow once, deny, or later?")
            completed_turn = terminal_step(master, "a")
            assert "interactive complete" in completed_turn and "result: completed" in completed_turn, completed_turn
            assert "interactive complete" in terminal_step(master, "/result " + interactive_key)
            assert "Recent messages" in terminal_step(master, "/status")
            assert "Detached. Host work continues." in terminal_step(master, "/exit", "Detached.")
            assert entered.wait(timeout=5) == 0
            assert counter.read_text() == "xx", counter.read_text()
        finally:
            if entered.poll() is None:
                entered.kill()
                entered.wait(timeout=5)
            os.close(master)
        completed = True
        print("human CLI: saved recovery, Session wait/re-entry, PTY approval and Host restart passed")
    finally:
        sibling_release.touch()
        if failure_release is not None:
            failure_release.set()
        if stop_release is not None:
            stop_release.set()
        race_predecessor_release.set()
        race_message_release.set()
        if terminal_waiter is not None and terminal_waiter.poll() is None:
            terminal_waiter.kill()
            terminal_waiter.communicate(timeout=5)
        if race_follower is not None and race_follower.poll() is None:
            race_follower.kill()
            race_follower.communicate(timeout=5)
        if race_waiter is not None and race_waiter.poll() is None:
            race_waiter.kill()
            race_waiter.communicate(timeout=5)
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            print(f"retained human CLI failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
