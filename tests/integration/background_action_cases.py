"""Real-Host background Action cases shared by the focused and Bash fixtures."""
import hashlib
import json
import shlex
import sys
import threading
import time

import model_fixture as fixture
from host_process import HostDiagnostics, ReleaseGate, dispose_all, retain_failure_state
from bash_fixture import action_for, add_exchange, allow, configure, execution_custody_idle, process_exists


def prove_native_background(state, *, deadline=None):
    from bash_fixture import dispose_owner_case

    deadline = time.monotonic() + 220 if deadline is None else deadline

    def command(*args, **options):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("native promotion body deadline")
        return fixture.command(*args, timeout=min(15, remaining), **options)

    def wait_for(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    outcomes = []
    for name, capacity in (("approval", 2), ("running", 2), ("stopped", 2), ("capacity-one", 1)):
        if deadline - time.monotonic() < 45:
            raise TimeoutError("native promotion case startup reserve")
        case = state / f"native-background-{name}"
        case.mkdir(mode=0o700)
        workspace = case / "workspace"
        workspace.mkdir()
        gate = ReleaseGate(workspace / "producer-gate")
        producer = (
            "import os,pathlib,secrets; "
            "f=open('launches','a'); f.write(str(os.getpid())+'\\n'); f.flush(); os.fsync(f.fileno()); f.close(); "
            "pathlib.Path('ready.tmp').write_text(str(os.getpid())); os.replace('ready.tmp','ready'); "
            "g=open('producer-gate','rb'); g.read(); g.close(); "
            "value='native-final-'+secrets.token_hex(16)+'\\n'+'é😀'*2200+'\\n'; "
            "f=open('expected-final','w'); f.write(value); f.flush(); os.fsync(f.fileno()); f.close(); "
            "print(value,end='')"
        )
        arguments = json.dumps({
            "cmd": "exec " + shlex.join([sys.executable, "-c", producer]),
            "description": "Wait for native release", "timeout_ms": 30000,
        }, ensure_ascii=False, separators=(",", ":"))
        responses = [
            fixture.sse_tool_calls(f"{name}-calls", [("bash", f"{name}-call", arguments)]),
            fixture.sse_answer(f"{name}-answer", f"{name}-reason", f"{name}-message", "original answer")[0],
        ]
        if name in ("approval", "running"):
            responses.append(fixture.sse_answer(f"{name}-final-answer", f"{name}-final-reason", f"{name}-final-message", "final delivered")[0])
        endpoint = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        host = session = pid = diagnostics = None
        evidence = {"case": name, "capacity": capacity}
        try:
            thread.start()
            host = fixture.start_host(case / "store", f"http://127.0.0.1:{endpoint.server_port}/responses", active_capacity=capacity)
            diagnostics = HostDiagnostics(host)
            store = case / "store"
            session = configure(case, store, "configure", workspace=workspace)
            fixture.message(case, store, "message", session, "run ordinary Bash")
            action = wait_for(lambda: action_for(store, session), "ordinary foreground Action")
            identity = action["action"]
            assert fixture.read_action(store, session, identity, "arguments") == arguments.encode(), action
            pending = command("action", "read", "--store", store, "--session", session, "--action", identity)
            assert pending["state"] == "waiting_approval" and pending["final"] is None, pending
            if name != "approval":
                allow(case, store, "allow", session, identity)
                wait_for(lambda: (workspace / "ready").exists(), "fsynced producer launch")
                pid = int((workspace / "launches").read_text())
                assert process_exists(pid)
            gate.assert_held()
            assert len(endpoint.requests) == 1, endpoint.requests
            assert fixture.completed_observation(store, "message") is None
            promoted = command(
                "action", "background", "--store", store, "--session", session,
                "--action", identity, "--key", "promote", "--record", case / "promote.json",
            )
            evidence["promotion"] = promoted
            answer = promoted["answer"]
            assert answer["status"] == "accepted" and answer["action_selection"]["kind"] == "background", promoted
            if capacity == 1:
                assert fixture.completed_observation(store, "message") is None
                assert len(endpoint.requests) == 1 and process_exists(pid)
            else:
                answer = promoted["answer"]
                assert answer["status"] == "accepted" and answer["replayed"] is False, promoted
                assert answer["action_selection"]["kind"] == "background" and int(answer["action_selection"]["position"]) > 0, promoted
                wait_for(lambda: fixture.completed_observation(store, "message"), "immutable original receipt continuation")
                assert fixture.read_result(store, "message") == b"original answer"
                assert len(endpoint.requests) == 2, endpoint.requests
                continuation = json.loads(endpoint.requests[1])
                outputs = [item for item in continuation["input"] if item.get("type") == "function_call_output"]
                assert len(outputs) == 1 and outputs[0]["call_id"] == f"{name}-call", outputs
                receipt = outputs[0]["output"]
                assert json.loads(receipt) == {"action": identity, "execution": "background", "accepted": True}, outputs
                assert "native-final-" not in receipt
                if name == "approval":
                    assert not (workspace / "launches").exists()
                    current = command("session", "inspect", "--store", store, "--session", session)
                    assert current["work"]["latest_outcome"]["code"] == "completed" and current["work"]["first_action"] == identity, current
                    assert any(item["turn"] == current["work"]["turn"] and item["outcome"] == "completed" for item in current["recent_messages"]), current
                    assert [item["action"] for item in current["actionable_permissions"]] == [identity], current
                    allow(case, store, "allow", session, identity)
                    wait_for(lambda: (workspace / "ready").exists(), "approval after original Turn closed")
                    pid = int((workspace / "launches").read_text())
                assert process_exists(pid)
                assert (workspace / "launches").read_text() == f"{pid}\n"
                replay = command("request", "recover", "--store", store, "--record", case / "promote.json", "--kind", "action-background")
                assert replay["answer"]["replayed"] is True and replay["answer"]["action_selection"] == answer["action_selection"], replay
                foreign = configure(case, store, "foreign-configure", workspace=workspace)
                refused = command("action", "background", "--store", store, "--session", foreign, "--action", identity, "--key", "foreign", "--record", case / "foreign.json", expect=3)
                assert refused["answer"]["status"] == "rejected" and refused["answer"]["code"] == "target_mismatch", refused
            gate.assert_held()
            assert (workspace / "launches").read_text() == f"{pid}\n" and process_exists(pid)
            if name == "stopped":
                stopped = command("session", "stop", "--store", store, "--session", session, "--key", "stop", "--record", case / "stop.json")
                assert stopped["answer"]["status"] == "accepted", stopped
            else:
                gate.release()
            first = wait_for(
                lambda: (value if (value := command("action", "read", "--store", store, "--session", session, "--action", identity))["state"] == "resolved" else None),
                "explicit sole final Resolution",
            )
            wait_for(lambda: not process_exists(pid), "exact producer PID retired")
            assert (workspace / "launches").read_text() == f"{pid}\n"
            assert fixture.read_action(store, session, identity, "arguments") == arguments.encode()
            metadata = {key: first["final"][key] for key in ("position", "code", "content")}
            assert metadata["code"] == ("cancelled" if name == "stopped" else "succeeded"), metadata
            page, assembled = first, bytearray()
            while True:
                assert {key: page["final"][key] for key in metadata} == metadata
                window = page["final"]["window"]
                chunk = window["text"].encode()
                assert int(window["offset"]) == len(assembled) and int(window["next"]) == len(assembled) + len(chunk), window
                assert len(chunk) <= 4096 and (chunk or not window["more"]), window
                assembled.extend(chunk)
                if not window["more"]:
                    break
                page = command("action", "read", "--store", store, "--session", session, "--action", identity, "--offset", window["next"])
            domain = b"rui/content/v1"
            digest = hashlib.sha256(len(domain).to_bytes(8, "big") + domain + assembled).hexdigest()
            assert metadata["content"] == {"bytes": str(len(assembled)), "sha256": digest}, metadata
            if name != "stopped":
                assert (workspace / "expected-final").read_bytes() in assembled
            assert command("action", "read", "--store", store, "--session", session, "--action", identity) == first
            replay = command("request", "recover", "--store", store, "--record", case / "promote.json", "--kind", "action-background")
            assert replay["answer"]["replayed"] is True
            assert replay["answer"]["action_selection"] == promoted["answer"]["action_selection"], replay
            if capacity == 1:
                wait_for(lambda: fixture.completed_observation(store, "message"), "original continuation waits for background credit release")
                delivered = json.loads(endpoint.requests[1])
                outputs = [item for item in delivered["input"] if item.get("type") == "function_call_output"]
                assert len(outputs) == 1 and json.loads(outputs[0]["output"])["execution"] == "background", outputs
                final_message = [item for item in delivered["input"] if item.get("role") == "user"][-1]
                assert final_message["content"][1]["text"].encode() == assembled, final_message
                assert fixture.read_result(store, f"rui.core/action-final/{identity}") == b"original answer"
            else:
                assert outputs[0]["output"] == receipt
            wait_for(lambda: execution_custody_idle(store, session), "producer cleanup before reuse")
            expected_requests = 3 if name in ("approval", "running") else 2
            if expected_requests == 3:
                final_key = f"rui.core/action-final/{identity}"
                wait_for(lambda: fixture.completed_observation(store, final_key), "final input wakes the idle Session")
                assert fixture.read_result(store, final_key) == b"final delivered"
                delivered = json.loads(endpoint.requests[2])
                messages = [item for item in delivered["input"] if item.get("role") == "user"]
                final_message = messages[-1]["content"]
                assert final_message[0]["text"].startswith(f"[Rui: background Action {identity} reached its final Resolution."), final_message
                assert final_message[1]["text"].encode() == assembled, final_message
            assert len(endpoint.requests) == expected_requests and fixture.read_result(store, "message") == b"original answer"
            evidence.update(action=identity, pid=pid, launches=1, final=metadata, requests=len(endpoint.requests))
            outcomes.append(evidence)
        finally:
            failed = sys.exception() is not None
            dispose_all(
                gate.release,
                lambda: fixture.command("session", "stop", "--store", store, "--session", session, "--key", "dispose", "--record", case / "dispose.json") if failed and session is not None and host.poll() is None else None,
                lambda: fixture.wait_for(lambda: not process_exists(pid), "owned producer disposal", timeout=5) if pid is not None else None,
                lambda: dispose_owner_case(host, endpoint, thread),
                lambda: (case / "witness.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n"),
                lambda: (case / "host.stderr").write_bytes(diagnostics.tail()) if failed and diagnostics is not None else None,
                lambda: print("Native background Host diagnostics: " + diagnostics.tail()[-4096:].decode(errors="replace"), file=sys.stderr) if failed and diagnostics is not None else None,
                lambda: retain_failure_state("native Bash background failure state", case) if failed else None,
            )
    return outcomes



def prove_model_action_read(state, *, deadline=None):
    from bash_fixture import dispose_owner_case

    deadline = time.monotonic() + 180 if deadline is None else deadline
    case = state / "model-action-read"
    case.mkdir(mode=0o700)
    workspace = case / "workspace"
    workspace.mkdir()
    store = case / "store"
    gate = ReleaseGate(workspace / "producer-gate")
    producer = (
        "import os,pathlib,secrets; "
        "f=open('launches','a'); f.write(str(os.getpid())+'\\n'); f.flush(); os.fsync(f.fileno()); f.close(); "
        "pathlib.Path('ready.tmp').write_text(str(os.getpid())); os.replace('ready.tmp','ready'); "
        "g=open('producer-gate','rb'); g.read(); g.close(); "
        "value='model-read-'+secrets.token_hex(16)+' é😀\\n'; "
        "f=open('expected-final','w'); f.write(value); f.flush(); os.fsync(f.fileno()); f.close(); "
        "print(value,end='')"
    )
    responses = []
    add_exchange(responses, "read-target", "exec " + shlex.join([sys.executable, "-c", producer]), answer="producer accepted", timeout_ms=30000)
    endpoint = fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    host = session = pid = None
    evidence = {}

    def command(*args, **options):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("model Action read body deadline")
        return fixture.command(*args, timeout=min(15, remaining), **options)

    def wait_for(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    def model_read(label, native):
        arguments = json.dumps({"action": identity}, separators=(",", ":"))
        with endpoint.lock:
            endpoint.responses.extend([
                fixture.sse_tool_calls(label + "-calls", [("read_action", label + "-call", arguments)]),
                fixture.sse_answer(label + "-answer", label + "-reason", label + "-message", label + " observed")[0],
            ])
        fixture.message(case, store, label, session, "Inspect your Action with read_action")
        wait_for(lambda: fixture.completed_observation(store, label), label + " model read continuation")
        assert fixture.read_result(store, label) == (label + " observed").encode()
        body = json.loads(endpoint.requests[-1])
        outputs = [item for item in body["input"] if item.get("type") == "function_call_output" and item.get("call_id") == label + "-call"]
        assert len(outputs) == 1, outputs
        assert json.loads(outputs[0]["output"]) == native, outputs
        evidence[label] = {"native": native, "provider_output": outputs[0]}

    try:
        thread.start()
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses", active_capacity=2)
        configured = command(
            "session", "configure", "--store", store, "--key", "configure", "--record", case / "configure.json",
            "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol",
            "--tools", "bash,read_action", "--permission-mode", "ask",
        )
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["context"]["session"]
        fixture.message(case, store, "target", session, "Start the ordinary gated Bash target")
        target = wait_for(lambda: action_for(store, session), "ordinary Bash awaiting approval")
        identity = target["action"]
        pending = command("action", "read", "--store", store, "--session", session, "--action", identity)
        assert pending["state"] == "waiting_approval" and pending["final"] is None, pending
        promoted = command("action", "background", "--store", store, "--session", session, "--action", identity, "--key", "promote", "--record", case / "promote.json")
        assert promoted["answer"]["status"] == "accepted", promoted
        wait_for(lambda: fixture.completed_observation(store, "target"), "original receipt continuation")
        assert len(endpoint.requests) == 2 and not (workspace / "launches").exists()
        first = json.loads(endpoint.requests[0])
        offered = [tool["name"] for item in first["input"] if item.get("type") == "additional_tools" for tool in item["tools"]]
        assert "read_action" in offered, first
        pending = command("action", "read", "--store", store, "--session", session, "--action", identity)
        model_read("pending-read", pending)
        assert len(endpoint.requests) == 4 and not (workspace / "launches").exists()
        allow(case, store, "allow", session, identity)
        wait_for(lambda: (workspace / "ready").exists(), "fsynced single producer launch")
        pid = int((workspace / "launches").read_text())
        assert process_exists(pid)
        with endpoint.lock:
            endpoint.responses.append(fixture.sse_answer("delivered-answer", "delivered-reason", "delivered-message", "final delivered")[0])
        gate.release()
        final = wait_for(
            lambda: value if (value := command("action", "read", "--store", store, "--session", session, "--action", identity))["state"] == "resolved" else None,
            "sole target Resolution",
        )
        assert final["final"]["code"] == "succeeded", final
        assert final["final"]["window"]["text"].encode() == b"Bash succeeded. Exit code: 0.\nstdout:\n" + (workspace / "expected-final").read_bytes()
        wait_for(lambda: fixture.completed_observation(store, f"rui.core/action-final/{identity}"), "final input before explicit model read")
        assert len(endpoint.requests) == 5
        model_read("final-read", final)
        assert len(endpoint.requests) == 7
        assert (workspace / "launches").read_text() == f"{pid}\n"
        wait_for(lambda: not process_exists(pid), "exact producer retirement")
        wait_for(lambda: execution_custody_idle(store, session), "model read and producer custody retirement")
        evidence.update(action=identity, pid=pid, launches=1, requests=len(endpoint.requests))
    finally:
        failed = sys.exception() is not None
        dispose_all(
            gate.release,
            lambda: command("session", "stop", "--store", store, "--session", session, "--key", "dispose", "--record", case / "dispose.json") if failed and session is not None and host is not None and host.poll() is None else None,
            lambda: fixture.wait_for(lambda: not process_exists(pid), "owned model-read producer disposal", timeout=5) if pid is not None else None,
            lambda: dispose_owner_case(host, endpoint, thread),
            lambda: (case / "witness.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n"),
            lambda: (case / "provider-requests.json").write_text(json.dumps([json.loads(body) for body in endpoint.requests], ensure_ascii=False, indent=2) + "\n"),
        )
    return evidence


def prove_automatic_background(state, *, deadline=None):
    from bash_fixture import dispose_owner_case

    deadline = time.monotonic() + 150 if deadline is None else deadline
    outcomes = []
    for name in ("threshold", "deadline"):
        case = state / ("auto-background-" + name)
        case.mkdir(mode=0o700)
        workspace = case / "workspace"
        workspace.mkdir()
        gate = ReleaseGate(workspace / "producer-gate")
        producer = (
            "import os,pathlib,time; "
            "pathlib.Path('launched').write_text(str(os.getpid())); "
            "time.sleep(0.25); "
            "pathlib.Path('slept').write_text('past threshold'); "
            "g=open('producer-gate','rb'); g.read(); g.close(); "
            "print('automatic final')"
        )
        timeout = 1200 if name == "deadline" else 10000
        responses = []
        add_exchange(responses, name, "exec " + shlex.join([sys.executable, "-c", producer]), answer="model continued", timeout_ms=timeout)
        responses.append(fixture.sse_answer(name + "-delivered", name + "-reason", name + "-message", "final woke model")[0])
        endpoint = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        host = session = pid = None
        evidence = {"case": name, "capacity": 2, "threshold_ms": 100, "timeout_ms": timeout}

        def wait_for(observe, description):
            return fixture.wait_for(observe, description, deadline=deadline)

        def command(*args, **options):
            return fixture.command(*args, timeout=min(15, max(0.1, deadline - time.monotonic())), **options)

        try:
            thread.start()
            host = fixture.start_host(case / "store", f"http://127.0.0.1:{endpoint.server_port}/responses", "--set", "execution.backgroundAfterMs=100", active_capacity=2)
            store = case / "store"
            session = configure(case, store, "configure", workspace=workspace)
            fixture.message(case, store, "message", session, "Sleep past the Host threshold")
            action = wait_for(lambda: action_for(store, session), "foreground Bash Action")
            identity = action["action"]
            allow(case, store, "allow", session, identity)
            wait_for(lambda: (workspace / "slept").exists(), "Bash slept past the threshold")
            pid = int((workspace / "launched").read_text())
            gate.assert_held()
            threshold_key = f"rui.core/action-threshold/{identity}"
            wait_for(lambda: fixture.observe(store, threshold_key, deadline=deadline), "Host promotion decision")
            wait_for(lambda: fixture.completed_observation(store, "message"), "model continues while Action runs")
            assert fixture.read_result(store, "message") == b"model continued"
            assert process_exists(pid) and len(endpoint.requests) == 2
            outputs = [item for item in json.loads(endpoint.requests[1])["input"] if item.get("type") == "function_call_output"]
            assert len(outputs) == 1 and json.loads(outputs[0]["output"]) == {"action": identity, "execution": "background", "accepted": True}, outputs
            if name != "deadline":
                gate.release()
            final = wait_for(lambda: value if (value := command("action", "read", "--store", store, "--session", session, "--action", identity))["state"] == "resolved" else None, "sole final Resolution")
            assert final["final"]["code"] == ("timed_out" if name == "deadline" else "succeeded"), final
            if name == "deadline":
                assert "1200 ms" in final["final"]["window"]["text"], final
            final_key = f"rui.core/action-final/{identity}"
            wait_for(lambda: fixture.completed_observation(store, final_key), "final Resolution wakes idle model")
            assert fixture.read_result(store, final_key) == b"final woke model"
            delivered = [item for item in json.loads(endpoint.requests[2])["input"] if item.get("role") == "user"][-1]
            assert delivered["content"][1]["text"] == final["final"]["window"]["text"], delivered
            wait_for(lambda: not process_exists(pid), "producer retirement")
            wait_for(lambda: execution_custody_idle(store, session), "all Action and model custody released")
            assert len(endpoint.requests) == 3
            evidence.update(action=identity, requests=len(endpoint.requests), final=final["final"])
            outcomes.append(evidence)
        finally:
            dispose_all(gate.release, lambda: dispose_owner_case(host, endpoint, thread), lambda: (case / "witness.json").write_text(json.dumps(evidence, indent=2) + "\n"))
    return outcomes
