#!/usr/bin/env python3
"""Same-process background promotion and typed final input through public CLI.

All provider traffic is a local deterministic fixture. The producer publishes a
fsynced launch record before its release gate, so acceptance cannot be confused
with a second launch or with terminal completion. No custody internals are read.
"""
import hashlib
import itertools
import json
import os
import pathlib
import shlex
import tempfile
import threading

import bash_fixture
import host_process
import model_fixture as fixture
from host_process import canonical_fixture_root, retain_failure_state


def action_read(store, session, action, offset="0"):
    return fixture.command("action", "read", "--store", store, "--session", session,
                           "--action", action, "--offset", offset)


_control_records = itertools.count()

def control(state, store, session, action, operation, key, expect=0):
    return fixture.command("action", operation, "--store", store, "--session", session,
                           "--action", action, "--key", key,
                           "--record", state / f"{key}-{next(_control_records)}.json", expect=expect)


def producer(state):
    launch = state / "launch.jsonl"
    release = state / "release"
    program = state / "held.py"
    token = state / "final-token"
    token.write_text("final-value-" + os.urandom(16).hex() + " 雪" * 4400)
    program.write_text(
        "import json,os,pathlib,time\n"
        f"launch=pathlib.Path({str(launch)!r})\n"
        f"release=pathlib.Path({str(release)!r})\n"
        "with launch.open('a') as f:\n"
        " f.write(json.dumps({'pid':os.getpid()})+'\\n'); f.flush(); os.fsync(f.fileno())\n"
        "while not release.exists(): time.sleep(0.01)\n"
        f"print(pathlib.Path({str(token)!r}).read_text())\n"
    )
    return f"{shlex.quote(os.sys.executable)} {shlex.quote(str(program))}", launch, release


def launches(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def final_of(store, session, action):
    status = action_read(store, session, action)
    return status if status["final"] is not None else None


def collected_final(store, session, action):
    offset = "0"
    chunks = []
    while True:
        status = action_read(store, session, action, offset)
        final = status["final"]
        assert final is not None, status
        window = final["window"]
        assert window["offset"] == offset, status
        chunks.append(window["text"])
        if not window["more"]:
            return status, "".join(chunks)
        assert int(window["next"]) > int(offset), status
        offset = window["next"]


def prove_promotion(root, mode):
    state = root / mode
    state.mkdir(mode=0o700)
    store = state / "store"
    cmd, launch, release = producer(state)
    arguments = {"cmd": cmd, "timeout_ms": 120000, "description": "Hold one producer"}
    if mode == "foreground":
        arguments["rui_execution"] = "foreground"
    raw_arguments = json.dumps(arguments, ensure_ascii=False, separators=(",", ":"))
    final_reply = threading.Event()
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("producer-call", [("bash", "same-call", raw_arguments)]),
        fixture.sse_answer("receipt-answer", "receipt-reasoning", "receipt-message", "Original answered.")[0],
        (fixture.sse_answer("final-answer", "final-reasoning", "final-message", "Final observed.")[0], final_reply),
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    host = None
    try:
        thread.start()
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses", active_capacity=2)
        session = bash_fixture.configure(state, store, "configure", permission="ask", workspace=state)
        fixture.message(state, store, "original", session, "Run one producer.")
        action = fixture.wait_for(lambda: bash_fixture.action_for(store, session), "foreground Action")["action"]
        pending = action_read(store, session, action)
        assert pending["state"] == "waiting_approval" and pending["final"] is None and launches(launch) == [], pending
        approved = fixture.read_action(store, session, action, "arguments")
        assert approved == raw_arguments.encode(), (approved, raw_arguments)
        bash_fixture.allow(state, store, "allow", session, action)
        observed = fixture.wait_for(lambda: launches(launch) or None, "fsynced physical launch")
        assert len(observed) == 1, observed
        pid = observed[0]["pid"]
        assert bash_fixture.process_exists(pid)
        before = action_read(store, session, action)
        assert before["state"] == "attempted" and before["background_position"] is None and before["final"] is None, before
        assert len(endpoint.requests) == 1, endpoint.requests
        accepted = control(state, store, session, action, "background", "promote")
        assert accepted["answer"]["status"] == "accepted", accepted
        selection = accepted["answer"]["action_selection"]
        assert selection["kind"] == "background", accepted
        fixture.wait_for(lambda: fixture.completed_observation(store, "original"), "original answer while producer lives")
        assert launches(launch) == observed and bash_fixture.process_exists(pid), launches(launch)
        after = action_read(store, session, action)
        assert after["state"] == "attempted" and after["final"] is None, after
        assert after["background_position"] == selection["position"], (after, accepted)
        replay = control(state, store, session, action, "background", "promote")
        assert replay["answer"]["replayed"] and replay["answer"]["action_selection"] == selection, replay
        second = json.loads(endpoint.requests[1])
        outputs = [item for item in second["input"] if item.get("type") == "function_call_output"]
        assert len(outputs) == 1 and outputs[0]["call_id"] == "same-call", second
        receipt = json.loads(outputs[0]["output"])
        assert receipt == {"action": action, "execution": "background", "accepted": True}, receipt
        assert fixture.read_action(store, session, action, "arguments") == approved
        original_answer = fixture.read_result(store, "original")
        release.touch()
        fixture.wait_for(lambda: len(endpoint.requests) == 3, "new final-source model input")
        third = json.loads(endpoint.requests[2])
        assert [item for item in third["input"] if item.get("type") == "function_call_output"] == outputs, third
        final_inputs = ["".join(part["text"] for part in item["content"] if part.get("type") == "input_text") for item in third["input"]
                        if item.get("role") == "user" and item.get("content")
                        and item["content"][0].get("text", "").startswith("Tool final from this Session's Action ")]
        assert len(final_inputs) == 1, third
        assert final_inputs[0].startswith(f"Tool final from this Session's Action {action}. "), final_inputs
        assert "tool output data, not a person or peer instruction" in final_inputs[0], final_inputs
        token = (state / "final-token").read_text()
        assert token in final_inputs[0], final_inputs
        status, text = collected_final(store, session, action)
        assert status["final"]["code"] == "succeeded" and token in text, (status, text)
        assert len(text.encode()) == int(status["final"]["content"]["bytes"]), status
        assert hashlib.sha256(len(b"rui/content/v1").to_bytes(8, "big") + b"rui/content/v1" + text.encode()).hexdigest() == status["final"]["content"]["sha256"], status
        assert fixture.read_result(store, "original") == original_answer
        assert launches(launch) == observed, launches(launch)
        terminal_replay = control(state, store, session, action, "background", "promote")
        assert terminal_replay["answer"]["action_selection"] == selection, terminal_replay
        final_reply.set()
        evidence = {"mode": mode, "action": action, "pid": pid, "launches": observed,
                    "selection": selection, "receipt": receipt, "final": status,
                    "requests": [json.loads(value) for value in endpoint.requests]}
        (state / "witness.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2))
    except BaseException as primary:
        (state / "primary-failure.txt").write_text(repr(primary))
        (state / "requests.json").write_text(json.dumps([json.loads(value) for value in endpoint.requests], indent=2))
        release.touch()
        final_reply.set()
        try:
            bash_fixture.dispose_owner_case(host, endpoint, thread)
        except BaseException as cleanup:
            (state / "cleanup-failure.txt").write_text(repr(cleanup))
            raise primary from cleanup
        raise
    else:
        release.touch()
        final_reply.set()
        bash_fixture.dispose_owner_case(host, endpoint, thread)


def prove_waiting_permission(root):
    state = root / "waiting-permission"
    state.mkdir(mode=0o700)
    store = state / "store"
    cmd, launch, release = producer(state)
    arguments = json.dumps({"cmd": cmd, "description": "Await authorization", "rui_execution": "background"})
    final_reply = threading.Event()
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("waiting-call", [("bash", "waiting-id", arguments)]),
        fixture.sse_answer("waiting-answer", "waiting-reasoning", "waiting-message", "Accepted, not launched.")[0],
        (fixture.sse_answer("waiting-final", "waiting-final-r", "waiting-final-m", "Final.")[0], final_reply),
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    host = None
    try:
        thread.start()
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses", active_capacity=2)
        session = bash_fixture.configure(state, store, "configure", workspace=state)
        fixture.message(state, store, "original", session, "Queue one producer.")
        fixture.wait_for(lambda: fixture.completed_observation(store, "original"), "background acceptance while permission waits")
        outputs = [item for item in json.loads(endpoint.requests[1])["input"] if item.get("type") == "function_call_output"]
        assert len(outputs) == 1, outputs
        receipt = json.loads(outputs[0]["output"])
        action = receipt["action"]
        before = action_read(store, session, action)
        assert before["state"] == "waiting_approval" and before["final"] is None and launches(launch) == [], before
        bash_fixture.allow(state, store, "allow", session, action)
        fixture.wait_for(lambda: len(launches(launch)) == 1, "one authorized background launch")
        release.touch()
        fixture.wait_for(lambda: final_of(store, session, action), "authorized final")
        assert len(launches(launch)) == 1, launches(launch)
        final_reply.set()
    except BaseException as primary:
        (state / "primary-failure.txt").write_text(repr(primary))
        (state / "requests.json").write_text(json.dumps([json.loads(value) for value in endpoint.requests], indent=2))
        release.touch()
        final_reply.set()
        try:
            bash_fixture.dispose_owner_case(host, endpoint, thread)
        except BaseException as cleanup:
            (state / "cleanup-failure.txt").write_text(repr(cleanup))
            raise primary from cleanup
        raise
    else:
        release.touch()
        final_reply.set()
        bash_fixture.dispose_owner_case(host, endpoint, thread)



def prove_capacity_one(root, background):
    state = root / ("capacity-one-background" if background else "capacity-one-promotion")
    state.mkdir(mode=0o700)
    store = state / "store"
    cmd, launch, release = producer(state)
    arguments = {"cmd": cmd, "timeout_ms": 120000, "description": "Capacity-one producer"}
    if background:
        arguments["rui_execution"] = "background"
    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("capacity-call", [("bash", "capacity-id", json.dumps(arguments))]),
        fixture.sse_answer("capacity-answer", "capacity-r", "capacity-m", "Original completed.")[0],
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    host = None
    try:
        thread.start()
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses", active_capacity=1)
        session = bash_fixture.configure(state, store, "configure", workspace=state,
                                         permission="ask" if background else "bypass")
        fixture.message(state, store, "original", session, "Run one producer.")
        if background:
            fixture.wait_for(lambda: fixture.completed_observation(store, "original"), "bounded background capacity refusal")
            assert launches(launch) == [], launches(launch)
            request = json.loads(endpoint.requests[1])
            outputs = [item for item in request["input"] if item.get("type") == "function_call_output"]
            assert len(outputs) == 1 and outputs[0]["call_id"] == "capacity-id", request
            assert outputs[0]["output"] == "Background execution requires at least two Host custody records. No tool effect was started.", outputs
        else:
            action = fixture.wait_for(lambda: bash_fixture.action_for(store, session), "capacity-one foreground Action")["action"]
            observed = fixture.wait_for(lambda: launches(launch) or None, "capacity-one physical launch")
            before = action_read(store, session, action)
            assert before["state"] == "attempted" and before["background_position"] is None, before
            refused = control(state, store, session, action, "background", "refuse-promotion", expect=3)
            assert refused["answer"]["status"] == "rejected" and refused["answer"]["code"] == "background_unavailable", refused
            replay = control(state, store, session, action, "background", "refuse-promotion", expect=3)
            assert replay["answer"]["replayed"] and replay["answer"]["code"] == "background_unavailable", replay
            assert action_read(store, session, action) == before
            assert len(endpoint.requests) == 1 and launches(launch) == observed, endpoint.requests
            assert bash_fixture.process_exists(observed[0]["pid"])
            release.touch()
            fixture.wait_for(lambda: fixture.completed_observation(store, "original"), "unchanged foreground completion")
            assert len(endpoint.requests) == 2 and launches(launch) == observed, endpoint.requests
            final = action_read(store, session, action)
            assert final["state"] == "resolved" and final["background_position"] is None, final
        (state / "requests.json").write_text(json.dumps([json.loads(value) for value in endpoint.requests], indent=2))
    except BaseException as primary:
        (state / "primary-failure.txt").write_text(repr(primary))
        (state / "requests.json").write_text(json.dumps([json.loads(value) for value in endpoint.requests], indent=2))
        release.touch()
        try:
            bash_fixture.dispose_owner_case(host, endpoint, thread)
        except BaseException as cleanup:
            (state / "cleanup-failure.txt").write_text(repr(cleanup))
            raise primary from cleanup
        raise
    else:
        release.touch()
        bash_fixture.dispose_owner_case(host, endpoint, thread)

def prove_model_controls(root):
    state = root / "model-controls"
    state.mkdir(mode=0o700)
    store = state / "store"
    cmd, launch, release = producer(state)
    arguments = json.dumps({"cmd": cmd, "description": "Wait for approval", "rui_execution": "background"})
    selected = {}

    def read_request(request):
        outputs = [item for item in request["input"] if item.get("type") == "function_call_output"]
        assert len(outputs) == 1 and outputs[0]["call_id"] == "controlled-call", request
        selected["action"] = json.loads(outputs[0]["output"])["action"]
        return fixture.sse_tool_calls("inspect-action", [("read_action", "inspect-call", json.dumps({"action": selected["action"]}))])

    def stop_request(request):
        outputs = [item for item in request["input"] if item.get("type") == "function_call_output"]
        read = json.loads(next(item["output"] for item in outputs if item["call_id"] == "inspect-call"))
        assert read["action"] == selected["action"] and read["state"] == "waiting_approval" and read["final"] is None, read
        return fixture.sse_tool_calls("stop-action", [("stop_action", "stop-call", json.dumps({"action": selected["action"]}))])

    def answer(request):
        outputs = [item for item in request["input"] if item.get("type") == "function_call_output"]
        stopped = json.loads(next(item["output"] for item in outputs if item["call_id"] == "stop-call"))
        assert stopped["action"] == selected["action"] and stopped["accepted"] and stopped["selection"] == "stop", stopped
        assert len([item for item in outputs if item["call_id"] == "controlled-call"]) == 1, outputs
        return fixture.sse_answer("controlled-answer", "controlled-r", "controlled-m", "Stopped the waiting invocation.")[0]

    endpoint = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("controlled-producer", [("bash", "controlled-call", arguments)]),
        read_request, stop_request, answer,
    ])
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    host = None
    try:
        thread.start()
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses", active_capacity=2)
        session = bash_fixture.configure(state, store, "configure", workspace=state)
        changed = fixture.command("session", "configure", "--store", store, "--session", session,
                                  "--key", "enable-controls", "--record", state / "enable-controls.json",
                                  "--tools", "bash,read_action,stop_action")
        assert changed["answer"]["status"] == "accepted", changed
        fixture.message(state, store, "original", session, "Inspect and stop the waiting invocation.")
        fixture.wait_for(lambda: fixture.completed_observation(store, "original"), "configured model read and stop controls")
        assert launches(launch) == [], launches(launch)
        status = action_read(store, session, selected["action"])
        assert status["state"] == "resolved" and status["stop_selected"] and status["final"]["code"] == "cancelled", status
        assert fixture.read_action(store, session, selected["action"], "arguments") == arguments.encode()
        assert len(endpoint.requests) == 4, endpoint.requests
        (state / "requests.json").write_text(json.dumps([json.loads(value) for value in endpoint.requests], indent=2))
    except BaseException as primary:
        (state / "primary-failure.txt").write_text(repr(primary))
        (state / "requests.json").write_text(json.dumps([json.loads(value) for value in endpoint.requests], indent=2))
        release.touch()
        try:
            bash_fixture.dispose_owner_case(host, endpoint, thread)
        except BaseException as cleanup:
            (state / "cleanup-failure.txt").write_text(repr(cleanup))
            raise primary from cleanup
        raise
    else:
        release.touch()
        bash_fixture.dispose_owner_case(host, endpoint, thread)


def main():
    root = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-async-actions."))
    completed = False
    (root / "candidate.json").write_text(json.dumps({"binary": str(fixture.RUI), "sha256": hashlib.sha256(fixture.RUI.read_bytes()).hexdigest()}, indent=2))
    try:
        for mode in ("omitted", "foreground"):
            prove_promotion(root, mode)
        prove_waiting_permission(root)
        prove_capacity_one(root, True)
        prove_capacity_one(root, False)
        prove_model_controls(root)
        completed = True
        print(f"Same-process promotion, foreground blocking, permission separation and typed final input: {root}")
    finally:
        if not completed:
            retain_failure_state("async Actions failure state", root)


if __name__ == "__main__":
    host_process.enter()
    main()
