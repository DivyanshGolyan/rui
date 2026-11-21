#!/usr/bin/env python3
"""Loopback-only evidence for immutable new-Session profile selection."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading

import codex_fixture
import codex_integration
import model_fixture as fixture
from host_process import retain_failure_state


A = "a" * 32
B = "b" * 32


def profile(path, profile_id):
    codex_fixture.credentials(path)
    text = path.read_text().replace("version=3\n", f"version=4\nprofile_id={profile_id}\n", 1)
    path.write_text(text)
    path.chmod(0o600)


def text_command(*args):
    completed = subprocess.run([str(fixture.RUI), *map(str, args)], text=True,
                               capture_output=True, timeout=15)
    if completed.returncode:
        raise AssertionError(f"command failed {args}: {completed.stderr}")
    return completed.stdout


def run():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-profiles.")).resolve()
    home = state / "home"
    profiles = home / ".config/rui/profiles"
    profiles.mkdir(mode=0o700, parents=True)
    for parent in (home, home / ".config", home / ".config/rui"):
        parent.chmod(0o700)
    os.environ["HOME"] = str(home)
    os.environ.pop("RUI_CODEX_CREDENTIAL_FILE", None)
    os.environ.pop("RUI_CHATGPT_CREDENTIAL_FILE", None)
    os.environ.pop("OPENAI_API_KEY", None)
    a_path, b_path = profiles / A, profiles / B
    profile(a_path, A)
    profile(b_path, B)
    a_generation = codex_integration.credential_facts(a_path)
    b_initial = b_path.read_bytes()
    assert not (profiles.parent / "codex.json").exists()
    assert not (profiles.parent / "chatgpt.json").exists()
    release = threading.Event()
    endpoint = fixture.SuccessEndpoint([
        (fixture.ResponseSpec(b"stale token", {"X-Request-Id": "stale-a"}, 401), release),
        fixture.sse_answer("answer-a", "reasoning-a", "message-a", "answer A")[0],
        fixture.sse_answer("answer-b", "reasoning-b", "message-b", "answer B")[0],
    ])
    endpoint.RequestHandlerClass = codex_integration.ManagedHandler
    endpoint.header_observations = []
    endpoint.user_agents = []
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = state / "store"
    host = None
    complete = False
    try:
        text_command("defaults", "configure", "--provider", "codex", "--profile", A)
        host = codex_integration.start(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        created = fixture.command("session", "configure", "--store", store, "--record", state / "a.json",
                                  "--key", "profile-a", "--workspace", fixture.ROOT,
                                  "--provider", "codex", "--model", "gpt-6-sol", "--tools", "none")
        session_a = created["answer"]["session"]
        fixture.message(state, store, "work-a", session_a, "work on A")
        fixture.wait_for(lambda: len(endpoint.requests) == 1, "A request before 401")
        text_command("defaults", "configure", "--provider", "codex", "--profile", B)
        created = fixture.command("session", "configure", "--store", store, "--record", state / "b.json",
                                  "--key", "profile-b", "--workspace", fixture.ROOT,
                                  "--provider", "codex", "--model", "gpt-6-sol", "--tools", "none")
        session_b = created["answer"]["session"]
        release.set()
        fixture.wait_for(lambda: fixture.completed_observation(store, "work-a"), "A after refresh")
        assert fixture.read_result(store, "work-a") == b"answer A"
        assert codex_integration.credential_facts(a_path) == (str(int(a_generation[0]) + 1), "ready")
        assert b_path.read_bytes() == b_initial
        text_command("auth", "logout", "chatgpt", "--profile", A)
        fixture.message(state, store, "after-logout", session_a, "do not switch")
        failure = fixture.wait_for(lambda: (value := fixture.observe(store, "after-logout")).get("result") and value,
                                   "A signed-out failure")
        assert failure["result"]["code"].startswith("provider_sign_in"), failure
        assert len(endpoint.requests) == 2, "signed-out A used another source"
        fixture.message(state, store, "work-b", session_b, "work on B")
        fixture.wait_for(lambda: fixture.completed_observation(store, "work-b"), "B answer")
        assert fixture.read_result(store, "work-b") == b"answer B"
        assert b_path.read_bytes() == b_initial
        assert not (profiles.parent / "codex.json").exists()
        assert not (profiles.parent / "chatgpt.json").exists()
        complete = True
    finally:
        release.set()
        if host is not None:
            fixture.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
        if complete:
            shutil.rmtree(state)
        else:
            retain_failure_state("profile integration failure state", state)


if __name__ == "__main__":
    run()
