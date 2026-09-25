#!/usr/bin/env python3
"""Public one-shot caller recovery and exact Bash authorization."""
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

import dispatch_integration as fixture


def run(home, *args, success=True):
    env = {**os.environ, "HOME": str(home)}
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
    sibling_started = state / "sibling-started"
    sibling_release = state / "sibling-release"
    sibling_effect = workspace / "sibling-effect"
    sibling_arguments = json.dumps({"cmd": f"touch {shlex.quote(str(sibling_started))}; "
        f"while [ ! -e {shlex.quote(str(sibling_release))} ]; do sleep 0.05; done; "
        "printf y >> sibling-effect", "timeout_ms": None}, separators=(",", ":"))
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("human-calls", [("bash", "human-call", arguments)]),
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
    completed = False
    try:
        host = fixture.start_host(store, url)
        config = admit(home, "configure", "--store", store, "--session", session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
        assert config["admission"]["answer"]["status"] == "accepted", config
        assert config["request"] in json.loads(run(home, "requests", "--json"))
        assert json.loads(run(home, "recover", config["request"], "--json"))["answer"]["replayed"] is True

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
        presentation = run(home, "inspect-action", "--store", store, "--session", session, "--action", action)
        assert f"Action {action}\ncall ID: human-call\nBash arguments: {arguments}" in presentation, presentation
        exact = json.loads(run(home, "inspect-action", "--store", store, "--session", session,
            "--action", action, "--json"))
        assert exact == {"action": action, "call_id": "human-call", "arguments": arguments}, exact
        assert run(home, "result", first) == "result: processing\n"
        assert not counter.exists()

        lost_decision = run(home, "allow-action", "--store", store, "--session", session,
            "--action", action, "--test-drop-reply", "after-commit", success=False)
        decision_key = lost_decision.split("request: ", 1)[1].splitlines()[0]
        assert decision_key in run(home, "requests").splitlines()
        recovered_decision = json.loads(run(home, "recover", decision_key, "--json"))["answer"]
        assert recovered_decision["status"] == "accepted" and recovered_decision["replayed"] is True
        fixture.wait_for(lambda: fixture.completed_observation(store, first), "first saved answer")
        stale = admit(home, "deny-action", "--store", store, "--session", session,
            "--action", action)
        assert stale["admission"]["answer"]["status"] == "rejected", stale
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        completed_result = json.loads(run(home, "result", first, "--json"))
        assert completed_result["answer"] == "first answer"
        assert completed_result["observation"]["result"]["status"] == "completed"
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
        caller.kill()
        output, _ = caller.communicate(timeout=5)
        assert caller.returncode == -signal.SIGKILL and output == b"", output
        assert second != first
        text.unlink()
        assert json.loads(run(home, "recover", second, "--json"))["answer"]["status"] == "accepted"
        fixture.wait_for(lambda: fixture.completed_observation(store, second), "second saved answer")
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        assert run(home, "result", second) == "result: completed\nsecond answer\n"
        assert counter.read_text() == "x" and len(endpoint.requests) == 3

        fixture.stop_host(host)
        host = fixture.start_host(store, url, active_capacity=2)
        sibling_session = "human/siblings"
        run(home, "configure", "--store", store, "--session", sibling_session,
            "--workspace", workspace, "--provider", "codex", "--model", "model-a",
            "--tools", "bash", "--permission-mode", "ask")
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

        fixture.crash_host(host, state, "human-cli-crash")
        failed_observation = run(home, "result", first, success=False)
        assert failed_observation == "", failed_observation
        host = fixture.start_host(store, url)
        assert json.loads(run(home, "recover", first, "--json"))["answer"]["replayed"] is True
        assert run(home, "result", first) == "result: completed\nfirst answer\n"
        assert counter.read_text() == "x" and sibling_effect.read_text() == "y" and len(endpoint.requests) == 8
        completed = True
        print("human CLI: saved capture, lost reply, exact approval, second key and Host restart passed")
    finally:
        sibling_release.touch()
        if failure_release is not None:
            failure_release.set()
        if stop_release is not None:
            stop_release.set()
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
