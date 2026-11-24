"""Real-Host watcher selection under execution capacity constraints."""
import json
import pathlib
import sys
import threading
import time

import model_fixture as fixture
from bash_fixture import action_for, actions_for, allow, dispose_owner_case
from github_pr_watch_fixture import GitHubFixture, TOKEN, install_gh, isolated_environment, loopback_url
from host_process import HostDiagnostics, PauseGate, ReleaseGate, dispose_all
from pause_client import ChildExited, PauseError


URL = "https://github.com/org/repo/pull/42"


def prove_capacity(state):
    """PRW-50: Discovery and watches consume capacity according to their actual work."""
    outcomes = []
    for mode in ("one-credit-discovery", "maximum-accounts", "one-credit-watch", "discovery-during-watch"):
        case = pathlib.Path(state) / mode
        case.mkdir()
        workspace = case / "workspace"
        workspace.mkdir()
        home = case / "home"
        home.mkdir()
        accounts = tuple(f"a{i:038d}" for i in range(100)) if mode == "maximum-accounts" else ("alice", "bob")
        gh = install_gh(case / "bin", accounts=accounts)
        store = case / "store"
        github = GitHubFixture()
        discovery = ("watch_github_pr", "discover", json.dumps({"url": URL}))
        watch = ("watch_github_pr", "watch", json.dumps({"url": URL, "account": "alice"}))
        if mode == "discovery-during-watch":
            responses = [fixture.sse_tool_calls("watch-call", [watch]),
                         fixture.sse_tool_calls("discovery-call", [discovery]),
                         fixture.sse_answer("selected", "selected-r", "selected-m", "selection received")[0]]
        else:
            selected_call = watch if mode == "one-credit-watch" else discovery
            responses = [fixture.sse_tool_calls("first-call", [selected_call]),
                         fixture.sse_answer("continued", "continued-r", "continued-m", "result received")[0]]
        provider = fixture.SuccessEndpoint(responses)
        thread = threading.Thread(target=provider.serve_forever, daemon=True)
        gate = PauseGate("watch.after_observation", occurrence=1)
        host = session = diagnostics = None
        deadline = time.monotonic() + 90

        def wait(observe, description):
            return fixture.wait_for(observe, description, deadline=deadline)

        def release_gate():
            try:
                gate.release()
            except ChildExited:
                gate.arrival = None
            except PauseError as error:
                if "AlreadyReleased" not in str(error):
                    raise
                gate.arrival = None

        try:
            with isolated_environment(home, gh.parent):
                api_url = github.start()
                provider_url = loopback_url(provider, "/responses")
                thread.start()
                host = fixture.start_host(store, provider_url, "--test-github-api-origin", api_url,
                                          active_capacity=2 if mode == "discovery-during-watch" else 1,
                                          pause=gate)
                diagnostics = HostDiagnostics(host)
                configured = fixture.command(
                    "session", "configure", "--store", store, "--key", "configure",
                    "--record", case / "configure.json", "--workspace", workspace,
                    "--provider", "codex", "--model", "gpt-6-sol", "--tools", "watch_github_pr",
                    "--permission-mode", "ask",
                )
                session = configured["context"]["session"]
                fixture.message(case, store, "message", session, "Watch the pull request")
                first = wait(lambda: action_for(store, session), "first Action awaiting approval")["action"]
                assert not github.requests
                allow(case, store, "allow-first", session, first)
                if mode == "discovery-during-watch":
                    gate.wait(action=first)
                    request_count = len(github.requests)
                    fixture.command("action", "background", "--store", store, "--session", session,
                                    "--action", first, "--key", "promote", "--record", case / "promote.json")
                    actions = wait(lambda: actions_for(store, session, 2), "discovery alongside watch")
                    second = next(action["action"] for action in actions if action["action"] != first)
                    allow(case, store, "allow-discovery", session, second)
                    wait(lambda: fixture.completed_observation(store, "message"), "discovery continuation")
                    assert len(github.requests) == request_count, github.requests
                    output_request = json.loads(provider.requests[2])
                    read_action = second
                else:
                    wait(lambda: fixture.completed_observation(store, "message"), "Action result delivered")
                    output_request = json.loads(provider.requests[1])
                    read_action = first
                final = fixture.command("action", "read", "--store", store, "--session", session,
                                        "--action", read_action)
                assert final["state"] == "resolved", final
                outputs = [item["output"] for item in output_request["input"]
                           if item.get("type") == "function_call_output"
                           and item.get("call_id") == ("watch" if mode == "one-credit-watch" else "discover")]
                assert len(outputs) == 1, outputs
                if mode == "one-credit-watch":
                    assert "capacity_exceeded" in json.dumps(final) + outputs[0], (final, outputs)
                    assert not github.requests, github.requests
                else:
                    decoded = json.loads(outputs[0])
                    assert decoded["usernames"] == list(accounts), decoded
                    assert "account_required" in outputs[0], outputs
                    if mode != "discovery-during-watch":
                        assert not github.requests, github.requests
                assert TOKEN.encode() not in b"\n".join(provider.requests) + json.dumps(final).encode()
                outcomes.append(mode)
        finally:
            failed = sys.exception() is not None

            def dispose_session():
                if session is not None and host is not None and host.poll() is None and (failed or mode == "discovery-during-watch"):
                    with isolated_environment(home, gh.parent):
                        fixture.command("session", "stop", "--store", store, "--session", session,
                                        "--key", "dispose", "--record", case / "dispose.json")

            dispose_all(dispose_session, release_gate, gate.close,
                        lambda: dispose_owner_case(host, provider, thread), github.close)
        assert TOKEN.encode() not in diagnostics.tail()
    outcomes.append(_prove_temporary_pressure(pathlib.Path(state)))
    return outcomes


def _prove_temporary_pressure(state):
    case = state / "temporary-pressure"
    case.mkdir()
    workspace = case / "workspace"
    workspace.mkdir()
    home = case / "home"
    home.mkdir()
    gh = install_gh(case / "bin", accounts=("alice", "bob"))
    store = case / "store"
    github = GitHubFixture()
    fifo = ReleaseGate(workspace / "producer-gate")
    watch = ("watch_github_pr", "watch", json.dumps({"url": URL, "account": "alice"}))
    discovery = ("watch_github_pr", "discover", json.dumps({"url": URL}))
    bash = ("bash", "ordinary", json.dumps({"cmd": "printf ready > ready; cat producer-gate",
                                            "description": "Hold ordinary execution credit", "timeout_ms": 60000}))
    provider = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("watch-call", [watch]),
        fixture.sse_tool_calls("discovery-call", [discovery]),
        fixture.sse_tool_calls("ordinary-call", [bash]),
        fixture.sse_answer("selected", "selected-r", "selected-m", "selection received")[0],
        fixture.sse_answer("ordinary-done", "ordinary-r", "ordinary-m", "ordinary complete")[0],
    ])
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    gate = PauseGate("watch.after_observation", occurrence=1)
    host = diagnostics = None
    sessions = []
    deadline = time.monotonic() + 90

    def wait(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    def configure(name, tools):
        configured = fixture.command(
            "session", "configure", "--store", store, "--key", name + "-configure",
            "--record", case / (name + "-configure.json"), "--workspace", workspace,
            "--provider", "codex", "--model", "gpt-6-sol", "--tools", tools,
            "--permission-mode", "ask",
        )
        session = configured["context"]["session"]
        sessions.append(session)
        fixture.message(case, store, name, session, "Run the requested action")
        action = wait(lambda: action_for(store, session), name + " awaiting approval")["action"]
        return session, action

    def read(session, action):
        return fixture.command("action", "read", "--store", store, "--session", session, "--action", action)

    try:
        with isolated_environment(home, gh.parent):
            api_url = github.start()
            provider_url = loopback_url(provider, "/responses")
            thread.start()
            host = fixture.start_host(store, provider_url, "--test-github-api-origin", api_url,
                                      "--test-phase-trace", active_capacity=2, pause=gate)
            diagnostics = HostDiagnostics(host)
            watch_session, watch_action = configure("watch", "watch_github_pr")
            discovery_session, discovery_action = configure("discovery", "watch_github_pr")
            bash_session, bash_action = configure("ordinary", "bash")
            allow(case, store, "allow-ordinary", bash_session, bash_action)
            wait(lambda: (workspace / "ready").exists(), "ordinary Action holding credit")
            fifo.assert_held()
            assert read(bash_session, bash_action)["state"] == "attempted"
            previous = len(diagnostics.matching("github_watch_capacity_deferred"))
            allow(case, store, "allow-watch", watch_session, watch_action)
            diagnostics.wait("github_watch_capacity_deferred", count=previous + 1,
                             timeout=max(0.1, deadline - time.monotonic()))
            queued = read(watch_session, watch_action)
            assert queued["state"] == "queued" and queued["final"] is None, queued
            assert not github.requests, github.requests
            allow(case, store, "allow-discovery", discovery_session, discovery_action)
            wait(lambda: fixture.completed_observation(store, "discovery"), "discovery passes queued watch")
            outputs = [item["output"] for item in json.loads(provider.requests[3])["input"]
                       if item.get("type") == "function_call_output" and item.get("call_id") == "discover"]
            assert len(outputs) == 1 and json.loads(outputs[0])["usernames"] == ["alice", "bob"], outputs
            queued = read(watch_session, watch_action)
            assert queued["state"] == "queued" and queued["final"] is None, queued
            assert not github.requests, github.requests
            fifo.release()
            gate.wait(action=watch_action)
            running = read(watch_session, watch_action)
            assert running["state"] == "attempted" and running["final"] is None, running
            assert github.requests and all(request["authorized"] for request in github.requests)
            assert TOKEN.encode() not in b"\n".join(provider.requests)
    finally:
        def stop_sessions():
            if host is not None and host.poll() is None:
                with isolated_environment(home, gh.parent):
                    for index, session in enumerate(sessions):
                        fixture.command("session", "stop", "--store", store, "--session", session,
                                        "--key", f"dispose-{index}", "--record", case / f"dispose-{index}.json")

        def release_watch():
            try:
                gate.release()
            except ChildExited:
                gate.arrival = None
            except PauseError as error:
                if "AlreadyReleased" not in str(error):
                    raise
                gate.arrival = None

        dispose_all(fifo.release, stop_sessions, release_watch, gate.close,
                    lambda: dispose_owner_case(host, provider, thread), github.close)
    assert TOKEN.encode() not in diagnostics.tail()
    return "temporary-pressure"
