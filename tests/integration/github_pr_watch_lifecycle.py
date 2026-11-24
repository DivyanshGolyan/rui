"""Real-Host watcher cancellation and recovery cases for the fixture runner."""
import json
import os
import pathlib
import signal
import sys
import threading
import time

import model_fixture as fixture
from bash_fixture import action_for, allow, dispose_owner_case, execution_custody_idle
from github_pr_watch_fixture import GitHubFixture, TOKEN, install_gh, isolated_environment, loopback_url
from host_process import HostDiagnostics, PauseGate, dispose_all
from pause_client import ChildExited, PauseError


def prove_watch_stop_and_recovery(state):
    """PRW-19: Stop suppresses the final wake; Host loss never replays a watch."""
    results = []
    for mode in ("stop", "crash"):
        case = pathlib.Path(state) / f"watch-{mode}"
        case.mkdir()
        workspace = case / "workspace"
        workspace.mkdir()
        home = case / "home"
        home.mkdir()
        gh = install_gh(case / "bin")
        store = case / "store"
        github = GitHubFixture()
        provider = fixture.SuccessEndpoint([
            fixture.sse_tool_calls("watch-call", [("watch_github_pr", "watch", json.dumps({
                "url": "https://github.com/org/repo/pull/42", "account": "alice",
            }))]),
            fixture.sse_answer("continued", "continued-r", "continued-m", "watch started")[0],
            fixture.sse_answer("baseline", "baseline-r", "baseline-m", "baseline received")[0],
            *([fixture.sse_answer("lost", "lost-r", "lost-m", "host loss received")[0]] if mode == "crash" else []),
            fixture.sse_answer("barrier", "barrier-r", "barrier-m", "barrier complete")[0],
        ])
        thread = threading.Thread(target=provider.serve_forever, daemon=True)
        gate = PauseGate("watch.after_observation", occurrence=1)
        recovered_gate = None
        host = recovered = session = None
        diagnostics = None
        deadline = time.monotonic() + 90

        def wait(observe, description):
            return fixture.wait_for(observe, description, deadline=deadline)

        def release_original():
            if gate.arrival is None:
                return
            try:
                gate.release()
            except ChildExited:
                gate.arrival = None
            except PauseError as error:
                # Cancellation consumes the parked arrival before cleanup can release it.
                if "AlreadyReleased" not in str(error):
                    raise
                gate.arrival = None

        try:
            with isolated_environment(home, gh.parent):
                for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
                    os.environ[name] = "rui-fixture-ambient-token"
                api_url = github.start()
                provider_url = loopback_url(provider, "/responses")
                thread.start()
                host = fixture.start_host(store, provider_url, "--test-github-api-origin", api_url,
                                          active_capacity=2, pause=gate)
                diagnostics = HostDiagnostics(host)
                configured = fixture.command(
                    "session", "configure", "--store", store, "--key", "configure",
                    "--record", case / "configure.json", "--workspace", workspace,
                    "--provider", "codex", "--model", "gpt-6-sol", "--tools", "watch_github_pr",
                    "--permission-mode", "ask",
                )
                session = configured["context"]["session"]
                fixture.message(case, store, "message", session, "Watch the pull request")
                action = wait(lambda: action_for(store, session), "watch awaiting approval")["action"]
                allow(case, store, "allow", session, action)
                gate.wait(action=action)
                assert github.requests and all(request["authorized"] for request in github.requests)
                fixture.command("action", "background", "--store", store, "--session", session,
                                "--action", action, "--key", "promote", "--record", case / "promote.json")
                wait(lambda: fixture.completed_observation(store, "message"), "promotion continuation")
                wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/1"),
                     "baseline delivered")
                assert len(provider.requests) == 3, provider.requests
                request_count = len(github.requests)
                calls_before = (gh.parent / "calls.jsonl").read_text().splitlines()

                if mode == "stop":
                    stopped = fixture.command("action", "stop", "--store", store, "--session", session,
                                              "--action", action, "--key", "stop", "--record", case / "stop.json")
                    assert stopped["answer"]["status"] == "accepted", stopped
                    final = wait(lambda: (value if (value := fixture.command(
                        "action", "read", "--store", store, "--session", session, "--action", action
                    ))["state"] == "resolved" else None), "cancelled watch")
                    assert final["final"]["code"] == "cancelled", final
                    wait(lambda: execution_custody_idle(store, session), "cancelled watch cleanup")
                    # Cancellation itself releases this pause and consumes the arrival.
                    gate.arrival = None
                    final_input = fixture.command("request", "inspect", "--store", store,
                                                  "--key", f"rui.core/action-final/{action}")
                    assert final_input["observation"]["status"] == "absent", final_input
                    assert len(provider.requests) == 3, provider.requests
                else:
                    crash = fixture.crash_host(host, case, "host-crash", diagnostics)
                    assert crash["returncode"] == -signal.SIGKILL, crash
                    gate.arrival = None  # The killed process no longer has a parked worker.
                    recovered_gate = PauseGate("watch.after_observation", occurrence=1)
                    recovered = fixture.start_host(store, provider_url, "--test-github-api-origin", api_url,
                                                   active_capacity=2, pause=recovered_gate)
                    wait(lambda: fixture.completed_observation(store, f"rui.core/action-final/{action}"),
                         "Host loss delivered")
                    final = fixture.command("action", "read", "--store", store, "--session", session, "--action", action)
                    assert final["state"] == "resolved" and final["final"]["code"] == "indeterminate", final
                    assert fixture.read_result(store, f"rui.core/action-final/{action}") == b"host loss received"
                    wait(lambda: execution_custody_idle(store, session), "recovered watch cleanup")
                    assert len(provider.requests) == 4, provider.requests
                    assert len(github.requests) == request_count, github.requests
                    assert (gh.parent / "calls.jsonl").read_text().splitlines() == calls_before

                # Drive another complete Turn after settlement before checking for
                # unexpected queued wakes or a restarted watcher.
                fixture.message(case, store, "barrier", session, "Continue after the watch")
                wait(lambda: fixture.completed_observation(store, "barrier"), "post-settlement turn")
                assert fixture.read_result(store, "barrier") == b"barrier complete"
                wait(lambda: execution_custody_idle(store, session), "post-settlement cleanup")
                assert len(provider.requests) == (4 if mode == "stop" else 5), provider.requests
                if mode == "stop":
                    final_input = fixture.command("request", "inspect", "--store", store,
                                                  "--key", f"rui.core/action-final/{action}")
                    assert final_input["observation"]["status"] == "absent", final_input
                assert len(github.requests) == request_count, github.requests
                assert (gh.parent / "calls.jsonl").read_text().splitlines() == calls_before
                calls = [json.loads(line) for line in calls_before]
                assert all(not call["ambient_token_names"] and call["prompt_disabled"] == "1" for call in calls), calls
                visible = b"\n".join(provider.requests) + json.dumps(final).encode()
                assert TOKEN.encode() not in visible and b"rui-fixture-ambient-token" not in visible
                results.append({"mode": mode, "action": action})
        finally:
            failed = sys.exception() is not None

            def dispose_session():
                live = recovered if recovered is not None else host
                if failed and session is not None and live is not None and live.poll() is None:
                    with isolated_environment(home, gh.parent):
                        fixture.command("session", "stop", "--store", store, "--session", session,
                                        "--key", "dispose", "--record", case / "dispose.json")

            dispose_all(release_original, gate.close,
                        lambda: recovered_gate.close() if recovered_gate is not None else None,
                        dispose_session,
                        lambda: fixture.stop_host(recovered) if recovered is not None else None,
                        lambda: dispose_owner_case(host, provider, thread), github.close)
        if diagnostics is not None:
            assert TOKEN.encode() not in diagnostics.tail()
        for path in store.rglob("*"):
            if path.is_file():
                assert TOKEN.encode() not in path.read_bytes(), path
    return results
