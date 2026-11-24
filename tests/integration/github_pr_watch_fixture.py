"""Disposable loopback fixtures for real-Host GitHub PR watcher tests.

The calling test must enter host_process.enter() before creating a Host, use its
own temporary Store, and explicitly configure the Host's test-only API route.
"""
import contextlib
import http.server
import ipaddress
import json
import os
import pathlib
import threading
from urllib.parse import parse_qs, urlsplit

from host_process import TestHTTPServer


TOKEN = "rui-fixture-credential-should-never-be-persisted"
SHA = "0123456789abcdef0123456789abcdef01234567"


def loopback_url(server, path=""):
    """Return a URL only for the already-bound numeric loopback socket."""
    address, port = server.server_address[:2]
    ip = ipaddress.ip_address(address)
    if not ip.is_loopback or port <= 0:
        raise ValueError("fixture socket must be bound to loopback")
    host = f"[{ip}]" if ip.version == 6 else str(ip)
    url = f"http://{host}:{port}{path}"
    parsed = urlsplit(url)
    if parsed.username or parsed.password or not ipaddress.ip_address(parsed.hostname).is_loopback:
        raise ValueError("invalid loopback fixture URL")
    return url


def install_gh(directory, *, accounts=("alice",)):
    """Install a fake gh that records arguments and presence, never token values."""
    directory = pathlib.Path(directory)
    directory.mkdir(mode=0o700)
    (directory / "accounts.json").write_text(json.dumps(list(accounts)))
    script = directory / "gh"
    script.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(__file__).resolve().parent
names = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps({"argv": sys.argv[1:], "ambient_token_names": [n for n in names if n in os.environ], "prompt_disabled": os.environ.get("GH_PROMPT_DISABLED")}) + "\\n")
if sys.argv[1:] == ["auth", "status", "--hostname", "github.com", "--json", "hosts", "--no-refresh"]:
    names = json.loads((root / "accounts.json").read_text())
    print(json.dumps({"hosts": {"github.com": [{"login": n, "state": "success"} for n in names]}}))
elif len(sys.argv) == 8 and sys.argv[1:5] == ["auth", "token", "--hostname", "github.com"] and sys.argv[5] == "--user" and sys.argv[7] == "--no-refresh":
    if sys.argv[6] not in json.loads((root / "accounts.json").read_text()):
        sys.exit(1)
    print("rui-fixture-credential-should-never-be-persisted")
else:
    sys.exit(2)
''')
    script.chmod(0o700)
    return script


class GitHubFixture(TestHTTPServer):
    """Serve typed GitHub responses with an externally controlled PR lifecycle."""

    def __init__(self, *, pr_accessible=True):
        super().__init__(("127.0.0.1", 0), GitHubHandler)
        self.pr_accessible = pr_accessible
        self.condition = threading.Condition()
        self.requests = []
        self.lifecycle = "open"
        self.checks_passing = False
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return loopback_url(self)

    def set_lifecycle(self, lifecycle):
        if lifecycle not in ("open", "closed", "merged"):
            raise ValueError(lifecycle)
        with self.condition:
            self.lifecycle = lifecycle

    def set_checks_passing(self):
        with self.condition:
            self.checks_passing = True

    def wait_for_requests(self, count, timeout=15):
        with self.condition:
            if not self.condition.wait_for(lambda: len(self.requests) >= count, timeout):
                raise TimeoutError(f"fixture received {len(self.requests)} requests; expected {count}")
            return list(self.requests)

    def close(self):
        if self.thread.is_alive():
            self.shutdown()
        self.server_close()
        if self.thread.ident is not None:
            self.thread.join(timeout=15)
        if self.thread.is_alive():
            raise TimeoutError("GitHub fixture server did not stop")


class GitHubHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        with self.server.condition:
            lifecycle = self.server.lifecycle
            checks_passing = self.server.checks_passing
            self.server.requests.append({"path": self.path, "authorized": self.headers.get("Authorization") == f"Bearer {TOKEN}"})
            self.server.condition.notify_all()
        path = urlsplit(self.path).path
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            status, body = 401, {}
        elif path == "/user":
            status, body = 200, {"login": "alice"}
        elif path == "/repos/org/repo/pulls/42" and not self.server.pr_accessible:
            status, body = 404, {}
        elif path == "/repos/org/repo/pulls/42":
            status, body = 200, {"state": "open" if lifecycle == "open" else "closed", "draft": False,
                                 "merged_at": "2026-01-01T00:00:00Z" if lifecycle == "merged" else None,
                                 "head": {"sha": SHA}, "requested_reviewers": [], "requested_teams": []}
        elif path == "/repos/org/repo/pulls/42/reviews":
            status, body = 200, []
        elif path == f"/repos/org/repo/commits/{SHA}/check-runs":
            query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
            if (set(query) != {"per_page", "page", "filter"} or query["per_page"] != ["100"]
                    or query["filter"] != ["all"] or len(query["page"]) != 1
                    or not query["page"][0].isdigit() or int(query["page"][0]) < 1):
                status, body = 400, {}
            else:
                checks = [{"id": 1, "app": {"id": 1}, "name": "fixture", "status": "completed", "conclusion": "success", "head_sha": SHA}] if checks_passing else []
                status, body = 200, {"total_count": len(checks), "check_runs": checks}
        elif path == f"/repos/org/repo/commits/{SHA}/status":
            status, body = 200, {"sha": SHA, "state": "pending", "total_count": 0, "statuses": []}
        else:
            status, body = 404, {}
        encoded = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        pass


@contextlib.contextmanager
def isolated_environment(home, gh_directory):
    """Scrub inherited Rui and credential context for Host and CLI children."""
    saved = os.environ.copy()
    try:
        for name in list(os.environ):
            if name.startswith(("RUI_", "GH_", "GITHUB_")):
                del os.environ[name]
        os.environ["HOME"] = str(home)
        os.environ["GH_CONFIG_DIR"] = str(pathlib.Path(home) / "gh-config")
        os.environ["PATH"] = str(gh_directory) + os.pathsep + saved.get("PATH", os.defpath)
        yield
    finally:
        os.environ.clear()
        os.environ.update(saved)


def prove_watcher_wakes_model(state):
    """PRW-7: A promoted watch delivers progress and its terminal result to the model."""
    import sys
    import time

    import model_fixture as fixture
    from bash_fixture import action_for, allow, dispose_owner_case, execution_custody_idle
    from host_process import HostDiagnostics, PauseGate, dispose_all

    case = pathlib.Path(state)
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
        fixture.sse_answer("progress", "progress-r", "progress-m", "progress received")[0],
        fixture.sse_answer("transition", "transition-r", "transition-m", "transition received")[0],
        fixture.sse_answer("final", "final-r", "final-m", "final received")[0],
    ])
    provider_thread = threading.Thread(target=provider.serve_forever, daemon=True)
    class ObservationGates(PauseGate):
        def started(self, process):
            self.client.attach_process(process)
            self.child.close()
            for occurrence in (1, 2, 3):
                self.client.arm(self.point, occurrence=occurrence)
            self.client.start()

    gate = ObservationGates("watch.after_observation", occurrence=1)
    host = diagnostics = session = None
    deadline = time.monotonic() + 90

    def wait(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    try:
        with isolated_environment(home, gh.parent):
            # These are deliberate sentinels: gh must not inherit any of them.
            for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
                os.environ[name] = "rui-fixture-ambient-token"
            api_url = github.start()
            provider_url = loopback_url(provider, "/responses")
            provider_thread.start()
            host = fixture.start_host(store, provider_url, "--test-github-api-origin", api_url,
                                      active_capacity=2, pause=gate)
            diagnostics = HostDiagnostics(host)
            configured = fixture.command(
                "session", "configure", "--store", store, "--key", "configure", "--record", case / "configure.json",
                "--workspace", workspace, "--provider", "codex", "--model", "gpt-6-sol",
                "--tools", "watch_github_pr", "--permission-mode", "ask",
            )
            session = configured["context"]["session"]
            fixture.message(case, store, "message", session, "Watch the pull request")
            action = wait(lambda: action_for(store, session), "watch awaiting approval")["action"]
            proposal = fixture.command("action", "inspect", "--store", store, "--session", session, "--action", action)
            assert json.loads(proposal["approved_descriptor"]) == {
                "kind": "watch", "url": "https://github.com/org/repo/pull/42", "login": "alice",
            }, proposal
            assert github.requests == [], "PR read before approval"
            allow(case, store, "allow", session, action)
            gate.wait(action=action)
            assert len(provider.requests) == 1, "foreground observation woke model"
            fixture.command("action", "background", "--store", store, "--session", session, "--action", action,
                            "--key", "promote", "--record", case / "promote.json")
            wait(lambda: fixture.completed_observation(store, "message"), "watch promotion continuation")
            gate.release()
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/1"), "baseline wakes model")
            second = gate.client.wait("watch.after_observation", {"action": int(action)}, occurrence=2)
            progress_request = json.loads(provider.requests[2])
            progress = [item["content"] for item in progress_request["input"] if item.get("role") == "user"][-1]
            assert f"background Action {action} published value 1" in progress[0]["text"], progress
            assert "open" in progress[1]["text"], progress
            github.set_checks_passing()
            gate.client.release(second["id"])
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-value/{action}/2"), "transition wakes model")
            third = gate.client.wait("watch.after_observation", {"action": int(action)}, occurrence=3)
            transition_request = json.loads(provider.requests[3])
            transition = [item["content"] for item in transition_request["input"] if item.get("role") == "user"][-1]
            assert f"background Action {action} published value 2" in transition[0]["text"], transition
            assert "passing" in transition[1]["text"], transition
            github.set_lifecycle("merged")
            gate.client.release(third["id"])
            wait(lambda: fixture.completed_observation(store, f"rui.core/action-final/{action}"), "terminal result wakes model")
            final = fixture.command("action", "read", "--store", store, "--session", session, "--action", action)
            assert final["state"] == "resolved" and "merged" in json.dumps(final), final
            assert fixture.read_result(store, f"rui.core/action-final/{action}") == b"final received"
            wait(lambda: execution_custody_idle(store, session), "watch custody released")
            assert all(request["authorized"] for request in github.requests), github.requests
            checks_requests = [request for request in github.requests if urlsplit(request["path"]).path.endswith("/check-runs")]
            assert checks_requests and all(parse_qs(urlsplit(request["path"]).query).get("filter") == ["all"]
                                           for request in checks_requests), checks_requests
            calls = [json.loads(line) for line in (gh.parent / "calls.jsonl").read_text().splitlines()]
            token_calls = [call for call in calls if call["argv"][:2] == ["auth", "token"]]
            assert token_calls and all(call["argv"][5:7] == ["--user", "alice"] for call in token_calls), calls
            assert all(not call["ambient_token_names"] and call["prompt_disabled"] == "1" for call in calls), calls
            visible = b"\n".join(provider.requests) + json.dumps(final).encode()
            assert TOKEN.encode() not in visible and b"rui-fixture-ambient-token" not in visible
    finally:
        failed = sys.exception() is not None
        def dispose_session():
            if failed and session is not None and host is not None and host.poll() is None:
                with isolated_environment(home, gh.parent):
                    fixture.command("session", "stop", "--store", store, "--session", session,
                                    "--key", "dispose", "--record", case / "dispose.json")

        dispose_all(
            gate.release,
            gate.close,
            dispose_session,
            lambda: dispose_owner_case(host, provider, provider_thread),
            github.close,
        )
    assert TOKEN.encode() not in diagnostics.tail()
    for path in store.rglob("*"):
        if path.is_file():
            assert TOKEN.encode() not in path.read_bytes(), path
    return {"action": action, "provider_requests": len(provider.requests)}


def prove_account_discovery(state):
    """PRW-14: Account discovery requires authorization before disclosure."""
    import sys
    import time

    import model_fixture as fixture
    from bash_fixture import action_for, allow, dispose_owner_case
    from host_process import PauseGate, dispose_all

    outcomes = []
    for label, accounts, expected in (
        ("none", (), "auth_required"),
        ("multiple", ("charlie", "bob", "bob"), "account_required"),
    ):
        case = pathlib.Path(state) / label
        case.mkdir()
        workspace = case / "workspace"
        workspace.mkdir()
        home = case / "home"
        home.mkdir()
        gh = install_gh(case / "bin", accounts=accounts)
        store = case / "store"
        github = GitHubFixture()
        provider = fixture.SuccessEndpoint([
            fixture.sse_tool_calls("discover-call", [("watch_github_pr", "discover", json.dumps({
                "url": "https://github.com/org/repo/pull/42",
            }))]),
            fixture.sse_answer("selected", "selected-r", "selected-m", "selection received")[0],
        ])
        thread = threading.Thread(target=provider.serve_forever, daemon=True)
        # The test-only API origin requires an inherited pause control socket.
        gate = PauseGate("watch.after_observation", occurrence=1)
        host = session = None
        deadline = time.monotonic() + 60

        def wait(observe, description):
            return fixture.wait_for(observe, description, deadline=deadline)

        try:
            with isolated_environment(home, gh.parent):
                api_url = github.start()
                provider_url = loopback_url(provider, "/responses")
                thread.start()
                host = fixture.start_host(store, provider_url, "--test-github-api-origin", api_url,
                                          active_capacity=2, pause=gate)
                configured = fixture.command(
                    "session", "configure", "--store", store, "--key", "configure",
                    "--record", case / "configure.json", "--workspace", workspace,
                    "--provider", "codex", "--model", "gpt-6-sol", "--tools", "watch_github_pr",
                    "--permission-mode", "ask",
                )
                session = configured["context"]["session"]
                fixture.message(case, store, "message", session, "Watch the pull request")
                action = wait(lambda: action_for(store, session), "discovery awaiting approval")["action"]
                assert len(provider.requests) == 1 and not github.requests
                for name in accounts:
                    assert name.encode() not in provider.requests[0]
                allow(case, store, "allow", session, action)
                wait(lambda: fixture.completed_observation(store, "message"), "discovery result delivered")
                assert fixture.read_result(store, "message") == b"selection received"
                outputs = [item for item in json.loads(provider.requests[1])["input"]
                           if item.get("type") == "function_call_output" and item.get("call_id") == "discover"]
                assert len(outputs) == 1, outputs
                output = outputs[0]["output"]
                assert expected in output, output
                if accounts:
                    decoded = json.loads(output)
                    assert decoded["usernames"] == ["bob", "charlie"], decoded
                assert not github.requests, github.requests
                calls = [json.loads(line) for line in (gh.parent / "calls.jsonl").read_text().splitlines()]
                assert all(call["argv"][:2] != ["auth", "token"] for call in calls), calls
                assert TOKEN.encode() not in b"\n".join(provider.requests)
                outcomes.append(label)
        finally:
            failed = sys.exception() is not None

            def dispose_session():
                if failed and session is not None and host is not None and host.poll() is None:
                    with isolated_environment(home, gh.parent):
                        fixture.command("session", "stop", "--store", store, "--session", session,
                                        "--key", "dispose", "--record", case / "dispose.json")

            dispose_all(gate.close, dispose_session, lambda: dispose_owner_case(host, provider, thread), github.close)
    return outcomes


def prove_account_binding(state):
    """PRW-57: Approval binds the sole login and inaccessible reads never switch accounts."""
    import sys
    import time

    import model_fixture as fixture
    from bash_fixture import action_for, allow, dispose_owner_case, execution_custody_idle
    from host_process import PauseGate, dispose_all

    outcomes = []
    for label in ("sole-account", "inaccessible"):
        case = pathlib.Path(state) / label
        case.mkdir()
        workspace = case / "workspace"
        workspace.mkdir()
        home = case / "home"
        home.mkdir()
        explicit = label == "inaccessible"
        gh = install_gh(case / "bin", accounts=("alice", "bob") if explicit else ("alice",))
        store = case / "store"
        github = GitHubFixture(pr_accessible=not explicit)
        args = {"url": "https://github.com/org/repo/pull/42"}
        if explicit:
            args["account"] = "alice"
        provider = fixture.SuccessEndpoint([
            fixture.sse_tool_calls("binding-call", [("watch_github_pr", "binding", json.dumps(args))]),
            fixture.sse_answer("binding-done", "binding-r", "binding-m", "binding complete")[0],
        ])
        thread = threading.Thread(target=provider.serve_forever, daemon=True)
        gate = PauseGate("watch.after_observation", occurrence=1)
        host = diagnostics = session = None
        deadline = time.monotonic() + 90

        def wait(observe, description):
            return fixture.wait_for(observe, description, deadline=deadline)

        def gh_calls():
            path = gh.parent / "calls.jsonl"
            return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

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
                proposal = fixture.command("action", "inspect", "--store", store, "--session", session, "--action", action)
                assert json.loads(proposal["approved_descriptor"]) == {
                    "kind": "watch", "url": "https://github.com/org/repo/pull/42", "login": "alice",
                }, proposal
                assert not github.requests, github.requests
                assert all(call["argv"][:2] != ["auth", "token"] for call in gh_calls())
                allow(case, store, "allow", session, action)
                if not explicit:
                    gate.wait(action=action)
                    fixture.command("action", "stop", "--store", store, "--session", session,
                                    "--action", action, "--key", "stop", "--record", case / "stop.json")
                    gate.arrival = None  # Cancellation releases the worker's pause.
                wait(lambda: fixture.completed_observation(store, "message"), "watch result delivered")
                assert fixture.read_result(store, "message") == b"binding complete"
                final = fixture.command("action", "read", "--store", store, "--session", session, "--action", action)
                assert final["state"] == "resolved", final
                if explicit:
                    assert json.loads(final["final"]["window"]["text"])["outcome"] == "pr_inaccessible", final
                    outputs = [item["output"] for item in json.loads(provider.requests[1])["input"]
                               if item.get("type") == "function_call_output" and item.get("call_id") == "binding"]
                    assert len(outputs) == 1 and "pr_inaccessible" in outputs[0], outputs
                    assert any(urlsplit(request["path"]).path == "/repos/org/repo/pulls/42"
                               for request in github.requests), github.requests
                wait(lambda: execution_custody_idle(store, session), "watch cleanup")
                calls = gh_calls()
                tokens = [call["argv"] for call in calls if call["argv"][:2] == ["auth", "token"]]
                assert tokens == [["auth", "token", "--hostname", "github.com", "--user", "alice", "--no-refresh"]], calls
                assert all(call["argv"][:2] != ["auth", "switch"] for call in calls), calls
                assert all(not call["ambient_token_names"] and call["prompt_disabled"] == "1" for call in calls), calls
                assert all(request["authorized"] for request in github.requests), github.requests
                visible = b"\n".join(provider.requests) + json.dumps(final).encode()
                assert TOKEN.encode() not in visible
                outcomes.append(label)
        finally:
            failed = sys.exception() is not None

            def dispose_session():
                if failed and session is not None and host is not None and host.poll() is None:
                    with isolated_environment(home, gh.parent):
                        fixture.command("session", "stop", "--store", store, "--session", session,
                                        "--key", "dispose", "--record", case / "dispose.json")

            dispose_all(gate.close, dispose_session, lambda: dispose_owner_case(host, provider, thread), github.close)
        assert TOKEN.encode() not in diagnostics.tail()
        for path in store.rglob("*"):
            if path.is_file():
                assert TOKEN.encode() not in path.read_bytes(), path
    return outcomes
