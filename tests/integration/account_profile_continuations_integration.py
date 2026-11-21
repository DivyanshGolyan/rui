#!/usr/bin/env python3
"""Exercise profile-bound tool and compaction continuations on synthetic peers."""
import json
import os
import pathlib
import shutil
import tempfile
import threading

import account_profiles_integration as profiles
import codex_integration
import model_fixture as fixture
import os_semantics
from host_process import retain_failure_state


def run():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-profile-continuations.")).resolve()
    home = state / "home"
    directory = home / ".config/rui/profiles"
    directory.mkdir(mode=0o700, parents=True)
    for parent in (home, home / ".config", home / ".config/rui"):
        parent.chmod(0o700)
    os.environ["HOME"] = str(home)
    for name in ("RUI_CODEX_CREDENTIAL_FILE", "RUI_CHATGPT_CREDENTIAL_FILE", "OPENAI_API_KEY"):
        os.environ.pop(name, None)
    a_path, b_path = directory / profiles.A, directory / profiles.B
    profiles.profile(a_path, profiles.A)
    profiles.profile(b_path, profiles.B)
    b_original = b_path.read_bytes()
    witness = state / "witness"
    tool = codex_integration.proposal_with_private_reasoning(f"printf once > {witness}; printf tool-witness")
    answer = fixture.sse_answer("tool-answer", "tool-reason", "tool-message", "tool done")[0]
    anchor = {"type": "compaction", "id": "profile-anchor", "encrypted_content": "synthetic-anchor"}
    compact = fixture.encode_sse([
        {"type": "response.output_item.done", "output_index": 0, "item": anchor},
        {"type": "response.completed", "response": {"id": "profile-compact", "status": "completed", "output": [anchor]}},
    ])
    last = fixture.sse_answer("compact-answer", "compact-reason", "compact-message", "compact done")[0]
    endpoint = fixture.SuccessEndpoint([tool, answer, compact, last])
    endpoint.RequestHandlerClass = codex_integration.ManagedHandler
    endpoint.header_observations = []
    endpoint.user_agents = []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = state / "store"
    host = None
    lock = None
    complete = False
    try:
        profiles.text_command("defaults", "configure", "--provider", "codex", "--profile", profiles.A)
        host = codex_integration.start(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        created = fixture.command("session", "configure", "--store", store, "--record", state / "a.json",
                                  "--key", "profile-a", "--workspace", fixture.ROOT,
                                  "--provider", "codex", "--model", "gpt-6-sol", "--tools", "bash",
                                  "--permission-mode", "bypass")
        session = created["answer"]["session"]
        profiles.text_command("defaults", "configure", "--provider", "codex", "--profile", profiles.B)
        # A request that tries the latest default cannot acquire B while this lock is held.
        lock_path = directory / ("." + profiles.B + ".lock")
        lock = lock_path.open("a+b")
        lock_path.chmod(0o600)
        assert os_semantics.try_lock(lock)
        fixture.message(state, store, "tool-work", session, "run the witness")
        fixture.wait_for(lambda: fixture.completed_observation(store, "tool-work"), "profile tool continuation")
        assert fixture.read_result(store, "tool-work") == b"tool done"
        assert witness.read_text() == "once"
        continuation = json.loads(endpoint.requests[1])
        assert any(item.get("type") == "function_call_output" and item.get("call_id") == "managed-call" for item in continuation["input"])
        fixture.stop_host(host)
        host = None
        host = codex_integration.start(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        changed = fixture.command("session", "configure", "--store", store, "--session", session,
                                  "--record", state / "compact.json", "--key", "compact-setting",
                                  "--compaction-trigger", "1")
        assert changed["answer"]["status"] == "accepted", changed
        fixture.message(state, store, "compact-work", session, "continue after restart")
        fixture.wait_for(lambda: fixture.completed_observation(store, "compact-work"), "profile compaction continuation")
        assert fixture.read_result(store, "compact-work") == b"compact done"
        assert any(item.get("type") == "compaction_trigger" for item in json.loads(endpoint.requests[2])["input"])
        assert len(endpoint.requests) == 4 and witness.read_text() == "once"
        assert b_path.read_bytes() == b_original
        complete = True
    finally:
        if lock is not None:
            os_semantics.release_lock(lock)
            lock.close()
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if complete:
            shutil.rmtree(state)
        else:
            retain_failure_state("profile continuation failure state", state)


if __name__ == "__main__":
    run()
