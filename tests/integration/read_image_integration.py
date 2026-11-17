#!/usr/bin/env python3
"""Real-Host image Action authorization, explicit failures and pending lifecycle."""
import base64
import json
import os
import re
import shutil
import sys
import tempfile
import threading
import time

import host_process
from host_process import canonical_fixture_root, dispose_all, retain_failure_state
import model_fixture as fixture
import os_semantics
from bash_fixture import action_for, allow, rows


CASES = (
    "ask-missing", "deny-missing", "deny-fifo", "stop-pending", "background-pending",
    "missing", "directory", "fifo", "text", "gif", "empty", "truncated-png",
    "truncated-jpeg", "oversized",
)
PNG = fixture.ROOT / "src/codecs/fixtures/image-input/pixel.png"


def prove_case(root, name):
    state = root / name
    state.mkdir(mode=0o700)
    workspace = state / "workspace"
    workspace.mkdir()
    source = workspace / "input.bin"
    if name in ("fifo", "deny-fifo"):
        os.mkfifo(source)
    elif name == "directory":
        source.mkdir()
    elif name in ("text", "gif", "empty", "truncated-png", "truncated-jpeg"):
        source.write_bytes({
            "text": b"This file is not an image.\n",
            "gif": b"GIF89a\x01\x00\x01\x00\x00\x00\x00;",
            "empty": b"",
            "truncated-png": PNG.read_bytes()[:20],
            "truncated-jpeg": b"\xff\xd8\xff\xe0\x00\x10JFIF\x00",
        }[name])
    elif name == "oversized":
        # Sparse input keeps this failure independent of fixture memory usage.
        with source.open("wb") as output:
            output.write(PNG.read_bytes())
            limits = (fixture.ROOT / "src/input_media.zig").read_text()
            cap = re.search(r"max_bytes: u64 = ([0-9_]+)", limits)
            assert cap is not None, "input_media.Limits.max_bytes moved"
            output.truncate(int(cap[1].replace("_", "")) + 1)
    arguments = json.dumps({"path": source.name})
    call_id = name + "-call"
    responses = [
        fixture.sse_tool_calls(name, [("read_image", call_id, arguments)]),
        fixture.sse_answer(name + "-answer", "reasoning", "message", "continued")[0],
    ]
    if name == "background-pending":
        responses.append(fixture.sse_answer("delivery-answer", "delivery-reasoning", "delivery-message", "delivered")[0])
    endpoint = fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoints = {endpoint: thread}
    processes = []
    thread.start()
    try:
        store = state / "store"
        pending = name.startswith(("ask-", "deny-")) or name.endswith("-pending")
        tracer = os_semantics.file_access_tracer() if pending else None
        trace = state / "file-access.trace"
        url = f"http://127.0.0.1:{endpoint.server_port}/responses"
        if tracer:
            processes.append(host_process.start_ready_process(
                [tracer, "--kill-on-exit", "-f", "-o", trace, "-s", "4096", "-e", "trace=%file",
                 *fixture.host_arguments(store, url, active_capacity=2)],
                required_fields={"execution": "enabled", "nghttp2": "1.70.0"},
            )[0])
        else:
            processes.append(fixture.start_host(store, url, active_capacity=2))
            if pending:
                print(name + ": syscall witness unavailable (Linux strace required)")

        def assert_no_file_access():
            if tracer:
                captured = trace.read_text()
                assert '"' + source.name + '"' not in captured and str(source) not in captured, captured

        configured = fixture.command(
            "session", "configure", "--store", store, "--workspace", workspace,
            "--record", state / "configure.json", "--key", "configure",
            "--provider", "codex", "--model", "gpt-6-sol", "--tools", "read_image",
            "--permission-mode", "ask" if pending else "bypass",
        )
        assert configured["answer"]["status"] == "accepted", configured
        session = configured["context"]["session"]
        deadline = time.monotonic() + 20

        def command(*args):
            return fixture.command(*args, timeout=min(15, max(.001, deadline - time.monotonic())))

        def read(action):
            return command("action", "read", "--store", store, "--session", session, "--action", action)

        def wait(check, description):
            return fixture.wait_for(check, name + ": " + description, deadline=deadline)

        fixture.message(state, store, "message", session, "Read the image")
        action = None
        expected = "failed"
        if pending:
            proposal = wait(lambda: action_for(store, session), "exact permission request")
            assert proposal["tool"] == "read_image" and proposal["authorization"] == "pending", proposal
            action = proposal["action"]
            current = read(action)
            assert current["state"] == "waiting_approval" and current["final"] is None, current
            assert fixture.observe(store, "message", deadline=deadline)["state"] == "waiting_for_permission"
            assert len(endpoint.requests) == 1, endpoint.requests
            assert_no_file_access()
            assert fixture.read_action(store, session, action, "arguments") == arguments.encode()
            if name == "ask-missing":
                # A missing path must be admitted without stat/open. The snapshot
                # must see bytes created only after the permission request exists.
                assert not source.exists()
                source.write_bytes(PNG.read_bytes())
                allow(state, store, "allow", session, action)
                expected = "succeeded"
            elif name.startswith("deny-"):
                denied = command("action", "deny", "--store", store, "--session", session,
                                 "--action", action, "--key", "deny", "--record", state / "deny.json")
                assert denied["answer"]["status"] == "accepted", denied
                expected = "denied"
            elif name == "stop-pending":
                stopped = command("session", "stop", "--store", store, "--session", session,
                                  "--key", "stop", "--record", state / "stop.json")
                assert stopped["answer"]["status"] == "accepted", stopped
                expected = "cancelled"
            else:
                promoted = command("action", "background", "--store", store, "--session", session,
                                   "--action", action, "--key", "background", "--record", state / "background.json")
                assert promoted["answer"]["status"] == "accepted", promoted
                wait(lambda: fixture.completed_observation(store, "message", deadline=deadline), "background receipt continuation")
                assert read(action)["state"] == "waiting_approval", read(action)
                assert not source.exists()
                assert_no_file_access()
                source.write_bytes(PNG.read_bytes())
                allow(state, store, "allow", session, action)
                expected = "succeeded"

        if name == "stop-pending":
            wait(lambda: (value if (value := fixture.observe(store, "message", deadline=deadline))["state"] == "cancelled" else None), "stopped Message")
        else:
            wait(lambda: fixture.completed_observation(store, "message", deadline=deadline), "model continuation after tool outcome")
            assert fixture.read_result(store, "message", deadline=deadline) == b"continued"
        if expected != "succeeded":
            report = command("session", "inspect", "--store", store, "--session", session, "--profile", "full")
            actions = report["full"]["actions"]
            assert len(actions) == 1, report
            action = actions[0]["action"] if action is None else action
            final = wait(lambda: (value if (value := read(action))["state"] == "resolved" else None), "saved explicit Resolution")
            assert final["final"]["code"] == expected, final
            assert int(final["final"]["content"]["bytes"]) > 0, final
        if expected in ("denied", "cancelled"):
            assert_no_file_access()
        elif tracer:
            assert source.name in trace.read_text(), "tracer did not observe the authorized read"
        assert fixture.read_action(store, session, action, "arguments") == arguments.encode()
        if name != "stop-pending":
            continuation = json.loads(endpoint.requests[1])
            outputs = [item for item in continuation["input"] if item.get("type") == "function_call_output"]
            assert len(outputs) == 1 and outputs[0]["call_id"] == call_id, outputs
            output = outputs[0]["output"]
            if name == "ask-missing":
                images = [part for part in output if part.get("type") == "input_image"]
                assert len(images) == 1, output
                assert base64.b64decode(images[0]["image_url"].split(",", 1)[1], validate=True) == PNG.read_bytes()
            elif name == "background-pending":
                assert json.loads(output) == {"action": action, "execution": "background", "accepted": True}, output
                wait(lambda: len(endpoint.requests) == 3, "final background delivery")
                delivered = json.loads(endpoint.requests[2])
                assert "data:image/png;base64," in json.dumps(delivered), delivered
                wait(lambda: command("session", "inspect", "--store", store, "--session", session)["work"]["latest_outcome"]["code"] == "completed", "background delivery completion")
            else:
                assert isinstance(output, str) and output.strip(), outputs
                assert "data:image/" not in output, outputs
        host_process.wait_for_execution_release(
            lambda remaining: fixture.command("session", "inspect", "--store", store, "--session", session,
                                              timeout=remaining)["execution"], deadline)
        if expected == "succeeded":
            # Byte-only readers refuse parts. The provider proves typed delivery;
            # inspect the committed Resolution after releasing the Store lease.
            fixture.stop_host(processes.pop())
            saved = rows(store, "SELECT resolution_code,acceptance_position FROM action_operation WHERE session_ref=? AND action_id=?", (session, int(action)))
            assert len(saved) == 1 and saved[0][0] == expected and saved[0][1] > 0, saved
        print("read_image " + name + ": " + expected)
    finally:
        fixture.dispose_dispatch(processes, endpoints, [])


def main():
    names = sys.argv[2:] or CASES
    assert all(name in CASES for name in names), names
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-read-image."))
    completed = False
    try:
        for name in names:
            prove_case(state, name)
        completed = True
    finally:
        dispose_all(lambda: shutil.rmtree(state) if completed else retain_failure_state("read_image integration failure state", state))


if __name__ == "__main__":
    host_process.enter()
    main()
