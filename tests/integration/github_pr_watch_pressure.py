"""Real-Host watcher deadline and delivery pressure cases."""
import json
import pathlib
import sys
import threading
import time

import model_fixture as fixture
from bash_fixture import action_for, allow, dispose_owner_case, execution_custody_idle
from github_pr_watch_fixture import GitHubFixture, TOKEN, install_gh, isolated_environment, loopback_url
from host_process import HostDiagnostics, PauseGate, dispose_all
from pause_client import ChildExited, PauseError


def prove_watch_deadline(state):
    """PRW-23: An expired watch settles and releases custody while its worker is parked."""
    case = pathlib.Path(state) / "watch-deadline"
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
        fixture.sse_answer("final", "final-r", "final-m", "deadline received")[0],
        fixture.sse_answer("barrier", "barrier-r", "barrier-m", "barrier complete")[0],
    ])
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    gate = PauseGate("watch.after_observation", occurrence=1)
    host = diagnostics = session = None
    deadline = time.monotonic() + 90

    def wait(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    def release_gate():
        if gate.arrival is None:
            return
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
            fixture.command("action", "background", "--store", store, "--session", session,
                            "--action", action, "--key", "promote", "--record", case / "promote.json")
            wait(lambda: fixture.completed_observation(store, "message"), "promotion continuation")
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/1"),
                 "baseline delivered")
            request_count = len(github.requests)
            gate.client.expire_action(action)
            final = wait(lambda: (value if (value := fixture.command(
                "action", "read", "--store", store, "--session", session, "--action", action
            ))["state"] == "resolved" else None), "expired watch")
            assert final["final"]["code"] == "timed_out", final
            terminal = json.loads(final["final"]["window"]["text"])
            assert terminal["outcome"] == "deadline_expired", terminal
            assert terminal["last_snapshot"]["lifecycle"] == "open", terminal
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-final/{action}"),
                 "deadline delivered")
            assert fixture.read_result(store, f"rui.core/action-final/{action}") == b"deadline received"
            wait(lambda: execution_custody_idle(store, session), "expired watch cleanup")
            gate.arrival = None  # Timeout cancellation consumes the parked worker's arrival.
            fixture.message(case, store, "barrier", session, "Continue after the watch")
            wait(lambda: fixture.completed_observation(store, "barrier"), "post-deadline turn")
            assert fixture.read_result(store, "barrier") == b"barrier complete"
            wait(lambda: execution_custody_idle(store, session), "post-deadline cleanup")
            assert len(provider.requests) == 5, provider.requests
            assert len(github.requests) == request_count, github.requests
            assert TOKEN.encode() not in b"\n".join(provider.requests) + json.dumps(final).encode()
    finally:
        failed = sys.exception() is not None

        def dispose_session():
            if failed and session is not None and host is not None and host.poll() is None:
                with isolated_environment(home, gh.parent):
                    fixture.command("session", "stop", "--store", store, "--session", session,
                                    "--key", "dispose", "--record", case / "dispose.json")

        dispose_all(release_gate, gate.close, dispose_session,
                    lambda: dispose_owner_case(host, provider, thread), github.close)
    assert TOKEN.encode() not in diagnostics.tail()
    return {"action": action}


class ReceiptRetryGate(PauseGate):
    def started(self, process):
        self.client.attach_process(process)
        self.child.close()
        self.client.arm(self.point, occurrence=1)
        self.client.arm(self.point, occurrence=2)
        self.client.arm("watch.receipt_dropped")
        self.client.arm("watch.receipt_replayed")
        self.client.start()


def prove_watch_receipt_retry(state):
    """PRW-48: An unacknowledged committed value is replayed before a newer observation."""
    case = pathlib.Path(state) / "watch-receipt-retry"
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
        fixture.sse_answer("transition", "transition-r", "transition-m", "transition received")[0],
    ])
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    gate = ReceiptRetryGate("watch.after_observation", occurrence=1)
    host = diagnostics = session = None
    held = []
    deadline = time.monotonic() + 90

    def wait(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    def release_all():
        for arrival in reversed(held):
            try:
                gate.client.release(arrival["id"])
            except ChildExited:
                pass
            except PauseError as error:
                if "AlreadyReleased" not in str(error):
                    raise
        held.clear()
        if gate.arrival is not None:
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
            gate.client.drop_watch_receipt(action)
            fixture.command("action", "background", "--store", store, "--session", session,
                            "--action", action, "--key", "promote", "--record", case / "promote.json")
            dropped = gate.client.wait("watch.receipt_dropped", {"action": int(action)})
            held.append(dropped)
            github.set_checks_passing()
            gate.release()
            second = gate.client.wait("watch.after_observation", {"action": int(action)}, occurrence=2)
            held.append(second)
            gate.client.release(dropped["id"])
            held.remove(dropped)
            replay = gate.client.wait("watch.receipt_replayed", {"action": int(action)})
            held.append(replay)
            gate.client.release(replay["id"])
            held.remove(replay)
            wait(lambda: fixture.completed_observation(store, "message"), "promotion continuation")
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/1"),
                 "original value delivered")
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/2"),
                 "newer observation delivered")
            first_input = [item["content"] for item in json.loads(provider.requests[2])["input"]
                           if item.get("role") == "user"][-1]
            second_input = [item["content"] for item in json.loads(provider.requests[3])["input"]
                            if item.get("role") == "user"][-1]
            assert "published value 1" in first_input[0]["text"], first_input
            assert "published value 2" in second_input[0]["text"], second_input
            first_value, second_value = json.loads(first_input[1]["text"]), json.loads(second_input[1]["text"])
            assert first_value["sequence"] == 1 and first_value["snapshot"]["checks"] == "pending", first_value
            assert second_value["sequence"] == 2 and second_value["snapshot"]["checks"] == "passing", second_value
            assert len(provider.requests) == 4, provider.requests
            stopped = fixture.command("action", "stop", "--store", store, "--session", session,
                                      "--action", action, "--key", "stop", "--record", case / "stop.json")
            assert stopped["answer"]["status"] == "accepted", stopped
            wait(lambda: execution_custody_idle(store, session), "watch cleanup")
            held.clear()  # Stop cancellation consumes the observation pause.
            assert TOKEN.encode() not in b"\n".join(provider.requests)
    finally:
        failed = sys.exception() is not None

        def dispose_session():
            if failed and session is not None and host is not None and host.poll() is None:
                with isolated_environment(home, gh.parent):
                    fixture.command("session", "stop", "--store", store, "--session", session,
                                    "--key", "dispose", "--record", case / "dispose.json")

        dispose_all(release_all, gate.close, dispose_session,
                    lambda: dispose_owner_case(host, provider, thread), github.close)
    assert TOKEN.encode() not in diagnostics.tail()
    return {"action": action}


class BackpressureGate(PauseGate):
    def started(self, process):
        self.client.attach_process(process)
        self.child.close()
        for occurrence in range(1, 5):
            self.client.arm(self.point, occurrence=occurrence)
        self.client.arm("watch.values_filled")
        self.client.arm("watch.backlog_full")
        self.client.start()


def prove_watch_backpressure(state):
    """PRW-49: Full Action delivery retains and later sends the latest coalesced observation."""
    case = pathlib.Path(state) / "watch-backpressure"
    case.mkdir()
    workspace = case / "workspace"
    workspace.mkdir()
    home = case / "home"
    home.mkdir()
    gh = install_gh(case / "bin")
    store = case / "store"
    github = GitHubFixture()
    release_provider = threading.Event()
    provider = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("watch-call", [("watch_github_pr", "watch", json.dumps({
            "url": "https://github.com/org/repo/pull/42", "account": "alice",
        }))]),
        fixture.sse_answer("continued", "continued-r", "continued-m", "watch started")[0],
        fixture.sse_answer("baseline", "baseline-r", "baseline-m", "baseline received")[0],
        (fixture.sse_answer("hold", "hold-r", "hold-m", "hold released")[0], release_provider),
        *[fixture.sse_answer(f"queued-{i}", f"queued-r-{i}", f"queued-m-{i}", "queued received")[0]
          for i in range(35)],
    ])
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    gate = BackpressureGate("watch.after_observation", occurrence=1)
    host = diagnostics = session = None
    held = []
    deadline = time.monotonic() + 120

    def wait(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    def release_all():
        release_provider.set()
        for arrival in reversed(held):
            try:
                gate.client.release(arrival["id"])
            except ChildExited:
                pass
            except PauseError as error:
                if "AlreadyReleased" not in str(error):
                    raise
        held.clear()
        if gate.arrival is not None:
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
            fixture.command("action", "background", "--store", store, "--session", session,
                            "--action", action, "--key", "promote", "--record", case / "promote.json")
            wait(lambda: fixture.completed_observation(store, "message"), "promotion continuation")
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/1"),
                 "baseline delivered")
            fixture.message(case, store, "hold", session, "Hold this turn open")
            wait(lambda: len(provider.requests) >= 4, "held provider request")
            gate.client.fill_watch_values(action)
            github.set_checks_passing()
            gate.release()
            second = gate.client.wait("watch.after_observation", {"action": int(action)}, occurrence=2)
            held.append(second)
            filled = gate.client.wait("watch.values_filled", {"action": int(action)})
            held.append(filled)
            gate.client.release(filled["id"])
            held.remove(filled)
            full = gate.client.wait("watch.backlog_full", {"action": int(action)})
            held.append(full)
            # The 32 fixture values and the refused transition remain queued while
            # the current provider request is held, so no extra model wake occurs.
            assert len(provider.requests) == 4, provider.requests
            with github.condition:
                github.checks_passing = False
            gate.client.release(second["id"])
            held.remove(second)
            third = gate.client.wait("watch.after_observation", {"action": int(action)}, occurrence=3)
            held.append(third)
            github.set_checks_passing()
            gate.client.release(third["id"])
            held.remove(third)
            fourth = gate.client.wait("watch.after_observation", {"action": int(action)}, occurrence=4)
            held.append(fourth)
            release_provider.set()
            wait(lambda: fixture.completed_observation(store, "hold"), "held turn completed")
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/2"),
                 "queued values admitted")
            gate.client.release(full["id"])
            held.remove(full)
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/34"),
                 "coalesced observation delivered")
            matching = []
            for request in provider.requests:
                for item in json.loads(request)["input"]:
                    if item.get("role") != "user":
                        continue
                    parts = item.get("content", [])
                    if len(parts) >= 2 and f"background Action {action} published value 34" in parts[0].get("text", ""):
                        matching.append(json.loads(parts[1]["text"]))
            assert matching, provider.requests
            assert all(value == matching[0] for value in matching), matching
            value = matching[0]
            assert value["sequence"] == 2 and value["kind"] == "coalesced", value
            assert value["snapshot"]["checks"] == "passing" and "checks" in value["changed"], value
            stopped = fixture.command("action", "stop", "--store", store, "--session", session,
                                      "--action", action, "--key", "stop", "--record", case / "stop.json")
            assert stopped["answer"]["status"] == "accepted", stopped
            wait(lambda: execution_custody_idle(store, session), "watch cleanup")
            held.clear()  # Stop consumes the parked observation.
            assert TOKEN.encode() not in b"\n".join(provider.requests)
    finally:
        failed = sys.exception() is not None

        def dispose_session():
            if failed and session is not None and host is not None and host.poll() is None:
                with isolated_environment(home, gh.parent):
                    fixture.command("session", "stop", "--store", store, "--session", session,
                                    "--key", "dispose", "--record", case / "dispose.json")

        dispose_all(release_all, gate.close, dispose_session,
                    lambda: dispose_owner_case(host, provider, thread), github.close)
    assert TOKEN.encode() not in diagnostics.tail()
    return {"action": action}
