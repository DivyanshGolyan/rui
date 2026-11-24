"""Real-Host tests of bounded gh discovery and helper process custody."""
import json
import os
import pathlib
import signal
import sys
import threading
import time

import model_fixture as fixture
from bash_fixture import action_for, allow, dispose_owner_case, execution_custody_idle, process_exists
from github_pr_watch_fixture import GitHubFixture, TOKEN, isolated_environment, loopback_url
from host_process import PauseGate, dispose_all


URL = "https://github.com/org/repo/pull/42"


def install_script(directory, script):
    directory.mkdir(mode=0o700)
    executable = directory / "gh"
    executable.write_text(script)
    executable.chmod(0o700)
    return executable


def session_for(case, store, workspace):
    configured = fixture.command(
        "session", "configure", "--store", store, "--key", "configure",
        "--record", case / "configure.json", "--workspace", workspace,
        "--provider", "codex", "--model", "gpt-6-sol", "--tools", "watch_github_pr",
        "--permission-mode", "ask",
    )
    return configured["context"]["session"]


def start_case(case, arguments, gh_script):
    case.mkdir()
    workspace = case / "workspace"
    workspace.mkdir()
    home = case / "home"
    home.mkdir()
    gh = install_script(case / "bin", gh_script)
    store = case / "store"
    github = GitHubFixture()
    provider = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("watch-call", [("watch_github_pr", "watch", json.dumps(arguments))]),
        fixture.sse_answer("continued", "continued-r", "continued-m", "continued")[0],
    ])
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    gate = PauseGate("watch.after_observation", occurrence=1)
    return workspace, home, gh, store, github, provider, thread, gate


def output_for(provider, call_id):
    outputs = [item for item in json.loads(provider.requests[1])["input"]
               if item.get("type") == "function_call_output" and item.get("call_id") == call_id]
    assert len(outputs) == 1, outputs
    return json.loads(outputs[0]["output"])


def prove_public_discovery(state):
    """PRW-53: Public discovery validates, bounds and sorts gh account results."""
    names = [f"a{i:03d}" + "z" * 35 for i in range(100)]
    cases = [
        ("none", {"hosts": {}}, "auth_required", None),
        ("sole", {"hosts": {"github.com": [
            {"login": "alice", "state": "success"}
        ]}}, "account_unavailable", None),
        ("deduplicated", {"hosts": {"github.com": [
            {"login": "zoe", "state": "success"},
            {"login": "alice", "state": "success"},
            {"login": "Alice", "state": "success"},
        ]}}, "account_required", ["alice", "zoe"]),
        ("maximum", {"hosts": {"github.com": [
            {"login": name, "state": "success"} for name in reversed(names)
        ]}}, "account_required", names),
        ("over-limit", {"hosts": {"github.com": [
            {"login": name, "state": "success"} for name in names + ["extra"]
        ]}}, "account_discovery_failed", None),
        ("partial", {"hosts": {"github.com": [
            {"login": "alice", "state": "success"}, {"login": "bob", "state": "timeout"}
        ]}}, "account_discovery_failed", None),
        ("malformed", '{"hosts":', "account_discovery_failed", None),
        ("bad-login", {"hosts": {"github.com": [
            {"login": "a--b", "state": "success"}
        ]}}, "account_discovery_failed", None),
        ("missing-state", {"hosts": {"github.com": [
            {"login": "alice"}
        ]}}, "account_discovery_failed", None),
    ]
    script = '''#!/bin/sh
[ "${GH_PROMPT_DISABLED}" = 1 ] || exit 24
[ -z "${GH_TOKEN+x}${GITHUB_TOKEN+x}${GH_ENTERPRISE_TOKEN+x}${GITHUB_ENTERPRISE_TOKEN+x}" ] || exit 25
if [ "$1 $2 $3 $4 $5 $6 $7" = "auth status --hostname github.com --json hosts --no-refresh" ]; then
    exec /bin/cat "$HOME/status.json"
fi
if [ "$1 $2 $3 $4 $5 $6 $7" = "auth token --hostname github.com --user alice --no-refresh" ]; then
    echo alice > "$HOME/token-call"
    exit 5
fi
exit 23
'''
    completed = []
    for label, status, expected, expected_names in cases:
        case = pathlib.Path(state) / label
        workspace, home, gh, store, github, provider, thread, gate = start_case(case, {"url": URL}, script)
        (home / "status.json").write_text(status if isinstance(status, str) else json.dumps(status))
        host = session = None
        deadline = time.monotonic() + 90

        def wait(observe, description):
            return fixture.wait_for(observe, description, deadline=deadline)

        try:
            with isolated_environment(home, gh.parent):
                for name in ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"):
                    os.environ[name] = "synthetic-ambient-token"
                api_url = github.start()
                provider_url = loopback_url(provider, "/responses")
                thread.start()
                host = fixture.start_host(store, provider_url, "--test-github-api-origin", api_url,
                                          active_capacity=2, pause=gate)
                session = session_for(case, store, workspace)
                fixture.message(case, store, "message", session, "Watch the pull request")
                action = wait(lambda: action_for(store, session), "discovery awaiting approval")["action"]
                assert len(provider.requests) == 1 and not github.requests
                allow(case, store, "allow", session, action)
                wait(lambda: fixture.completed_observation(store, "message"), "discovery result delivered")
                output = output_for(provider, "watch")
                assert output["outcome"] == expected, output
                if expected_names is not None:
                    assert output["usernames"] == expected_names, output
                assert not github.requests, github.requests
                if label == "sole":
                    assert (home / "token-call").read_text().strip() == "alice"
                else:
                    assert not (home / "token-call").exists()
                assert TOKEN.encode() not in b"\n".join(provider.requests)
                assert b"synthetic-ambient-token" not in b"\n".join(provider.requests)
                completed.append(label)
        finally:
            failed = sys.exception() is not None

            def dispose_session():
                if failed and session is not None and host is not None and host.poll() is None:
                    with isolated_environment(home, gh.parent):
                        fixture.command("session", "stop", "--store", store, "--session", session,
                                        "--key", "dispose", "--record", case / "dispose.json")

            dispose_all(gate.close, dispose_session, lambda: dispose_owner_case(host, provider, thread), github.close)
    return completed


def prove_helper_cancellation(state):
    """PRW-54: Stopping a ready gh helper terminates its group and reaps its leader."""
    case = pathlib.Path(state) / "run"
    script = '''#!/bin/sh
if [ "$1 $2 $3 $4 $5 $6 $7" != "auth token --hostname github.com --user alice --no-refresh" ]; then exit 23; fi
trap '' TERM
/bin/sleep 300 </dev/null >/dev/null 2>&1 &
descendant=$!
exec 1>&- 2>&-
echo "$descendant" > "$HOME/descendant.tmp"
/bin/mv "$HOME/descendant.tmp" "$HOME/descendant"
echo "$$" > "$HOME/ready.tmp"
/bin/mv "$HOME/ready.tmp" "$HOME/ready"
wait
'''
    workspace, home, gh, store, github, provider, thread, gate = start_case(
        case, {"url": URL, "account": "alice"}, script,
    )
    host = session = None
    leader = descendant = None
    deadline = time.monotonic() + 90

    def wait(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    def ready():
        marker = home / "ready"
        child = home / "descendant"
        if not marker.exists() or not child.exists():
            return None
        return int(marker.read_text().strip()), int(child.read_text().strip())

    try:
        with isolated_environment(home, gh.parent):
            api_url = github.start()
            provider_url = loopback_url(provider, "/responses")
            thread.start()
            host = fixture.start_host(store, provider_url, "--test-github-api-origin", api_url,
                                      active_capacity=2, pause=gate)
            session = session_for(case, store, workspace)
            fixture.message(case, store, "message", session, "Watch the pull request")
            action = wait(lambda: action_for(store, session), "watch awaiting approval")["action"]
            allow(case, store, "allow", session, action)
            leader, descendant = wait(ready, "gh helper and descendant ready")
            assert leader != descendant and process_exists(leader) and process_exists(descendant)
            assert os.getpgid(leader) == leader and os.getpgid(descendant) == leader
            stopped = fixture.command("action", "stop", "--store", store, "--session", session,
                                      "--action", action, "--key", "stop", "--record", case / "stop.json")
            assert stopped["answer"]["status"] == "accepted", stopped
            wait(lambda: execution_custody_idle(store, session), "watch cleanup")
            wait(lambda: not process_exists(leader), "gh leader reaped")
            wait(lambda: not process_exists(descendant), "gh descendant terminated")
            assert not github.requests, github.requests
            assert TOKEN.encode() not in b"\n".join(provider.requests)
    finally:
        failed = sys.exception() is not None

        def dispose_session():
            if failed and session is not None and host is not None and host.poll() is None:
                with isolated_environment(home, gh.parent):
                    fixture.command("session", "stop", "--store", store, "--session", session,
                                    "--key", "dispose", "--record", case / "dispose.json")

        def dispose_fixture_group():
            if failed and leader is not None and process_exists(leader):
                try:
                    if os.getpgid(leader) == leader:
                        os.killpg(leader, signal.SIGKILL)
                except ProcessLookupError:
                    pass

        dispose_all(gate.close, dispose_session, dispose_fixture_group,
                    lambda: dispose_owner_case(host, provider, thread), github.close)
    return {"action": action, "leader": leader, "descendant": descendant}
