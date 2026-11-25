"""Real-Host `watch_github_pr` cases: a change wakes the model, Stop settles, a lost Host never replays.

The Host runs in a pause build with `--test-github-api-origin`, so its requests reach a loopback GitHub stand-in
instead of api.github.com; `gh` is a fake that logs every call and never prints a token the fixture did not mint.
"""
import http.server
import ipaddress
import json
import os
import pathlib
import signal
import threading
import time

import model_fixture as fixture
from bash_fixture import action_for, allow, dispose_owner_case, execution_custody_idle
from host_process import HostDiagnostics, TestHTTPServer, dispose_all

TOKEN = "rui-fixture-credential-should-never-be-persisted"
FIRST_HEAD = "1" * 40
SECOND_HEAD = "2" * 40
URL = "https://github.com/org/repo/pull/42"
AMBIENT = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN")


def loopback_url(server, path=""):
    address, port = server.server_address[:2]
    assert ipaddress.ip_address(address).is_loopback and port > 0
    return f"http://{address}:{port}{path}"


def install_gh(directory, accounts):
    """A gh that answers `auth status` and `auth token`, logging each call with the ambient token names it saw."""
    directory.mkdir(mode=0o700)
    (directory / "accounts.json").write_text(json.dumps(accounts))
    script = directory / "gh"
    script.write_text(f'''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(__file__).resolve().parent
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps({{"argv": sys.argv[1:], "ambient": [n for n in {AMBIENT!r} if n in os.environ]}}) + "\\n")
accounts = json.loads((root / "accounts.json").read_text())
if sys.argv[1:] == ["auth", "status", "--hostname", "github.com", "--json", "hosts", "--no-refresh"]:
    print(json.dumps({{"hosts": {{"github.com": [{{"login": n, "state": "success"}} for n in accounts]}}}}))
elif len(sys.argv) == 8 and sys.argv[1:5] == ["auth", "token", "--hostname", "github.com"] and sys.argv[5] == "--user" and sys.argv[7] == "--no-refresh":
    if sys.argv[6] not in accounts:
        sys.exit(1)
    print({TOKEN!r})
else:
    sys.exit(2)
''')
    script.chmod(0o700)
    return directory


def gh_calls(directory):
    path = directory / "calls.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


class GitHub(TestHTTPServer):
    """Serves one open pull request whose head the test moves."""

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.head = FIRST_HEAD
        self.requests = []
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return loopback_url(self)

    def move_head(self):
        with self.lock:
            self.head = SECOND_HEAD

    def request_count(self):
        with self.lock:
            return len(self.requests)

    def close(self):
        if self.thread.is_alive():
            self.shutdown()
        self.server_close()
        self.thread.join(timeout=15)
        assert not self.thread.is_alive(), "GitHub fixture did not stop"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        with self.server.lock:
            head = self.server.head
            self.server.requests.append({"path": self.path, "authorized": self.headers.get("Authorization") == f"Bearer {TOKEN}"})
        path = self.path.split("?")[0]
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            status, body = 401, {}
        elif path == "/user":
            status, body = 200, {"login": "alice"}
        elif path == "/repos/org/repo/pulls/42":
            status, body = 200, {"state": "open", "draft": False, "merged_at": None, "head": {"sha": head},
                                 "requested_reviewers": [], "requested_teams": []}
        elif path == "/repos/org/repo/pulls/42/reviews":
            status, body = 200, []
        elif path == f"/repos/org/repo/commits/{head}/check-runs":
            status, body = 200, {"total_count": 0, "check_runs": []}
        elif path == f"/repos/org/repo/commits/{head}/status":
            status, body = 200, {"sha": head, "state": "pending", "total_count": 0, "statuses": []}
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


def scrubbed_environment(home, gh_directory):
    """The Host and its callers see a clean HOME, the fake gh first on PATH and ambient tokens that must be ignored."""
    saved = os.environ.copy()
    for name in list(os.environ):
        if name.startswith(("RUI_", "GH_", "GITHUB_")):
            del os.environ[name]
    os.environ["HOME"] = str(home)
    os.environ["GH_CONFIG_DIR"] = str(pathlib.Path(home) / "gh-config")
    os.environ["PATH"] = str(gh_directory) + os.pathsep + saved.get("PATH", os.defpath)
    for name in AMBIENT:
        os.environ[name] = "rui-fixture-ambient-token"
    return saved


def prove_watch(state, mode):
    """PRW-72: a model's watch call runs; a head change wakes the model with the snapshot inline; Stop settles
    the watch without waking it; a Host that dies leaves it indeterminate and the watch is never replayed."""
    case = pathlib.Path(state) / f"watch-{mode}"
    case.mkdir(mode=0o700)
    workspace = case / "workspace"
    workspace.mkdir()
    home = case / "home"
    home.mkdir()
    gh = install_gh(case / "bin", ["alice", "bob"])
    store = case / "store"
    github = GitHub()
    arguments = json.dumps({"url": URL, "account": "alice"})
    provider = fixture.SuccessEndpoint([
        fixture.sse_tool_calls("watch-call", [("watch_github_pr", "watch", arguments)]),
        fixture.sse_answer("continued", "continued-r", "continued-m", "watch started")[0],
        # Stop settles without waking the model, so only the other endings consume a wake answer.
        *([] if mode == "stop" else [fixture.sse_answer("woken", "woken-r", "woken-m", "watch result received")[0]]),
        fixture.sse_answer("barrier", "barrier-r", "barrier-m", "barrier complete")[0],
    ])
    thread = threading.Thread(target=provider.serve_forever, daemon=True)
    host = recovered = session = diagnostics = None
    saved = scrubbed_environment(home, gh)

    def wait(observe, description):
        return fixture.wait_for(observe, description, deadline=deadline)

    deadline = time.monotonic() + 90
    try:
        api = github.start()
        provider_url = loopback_url(provider, "/responses")
        thread.start()
        host = fixture.start_host(store, provider_url, "--test-github-api-origin", api, active_capacity=2)
        diagnostics = HostDiagnostics(host)
        session = fixture.command(
            "session", "configure", "--store", store, "--key", "configure", "--record", case / "configure.json",
            "--workspace", workspace, "--connection", "codex", "--model", "gpt-6-sol", "--tools", "watch_github_pr",
            "--permission-mode", "ask",
        )["context"]["session"]
        fixture.message(case, store, "message", session, "Watch the pull request")
        action = wait(lambda: action_for(store, session), "watch awaiting approval")["action"]
        # The exact arguments the model proposed are what the Host runs; there is no second binding step.
        assert fixture.read_action(store, session, action, "arguments") == arguments.encode()
        allow(case, store, "allow", session, action)
        wait(lambda: github.request_count() >= 6, "baseline observation")
        fixture.command("action", "background", "--store", store, "--session", session, "--action", action,
                        "--key", "promote", "--record", case / "promote.json")
        wait(lambda: fixture.completed_observation(store, "message"), "promotion continuation")
        assert len(provider.requests) == 2, provider.requests
        running = fixture.command("action", "read", "--store", store, "--session", session, "--action", action)
        assert running["state"] == "attempted" and running["final"] is None, running
        # Only the named account's token was ever asked for, and the ambient token variables never reached gh.
        calls = gh_calls(gh)
        assert [call["argv"][-2] for call in calls] == ["alice"] and all(not call["ambient"] for call in calls), calls
        assert all(request["authorized"] for request in github.requests), github.requests
        final_key = f"rui.core/action-final/{action}"

        if mode == "change":
            github.move_head()
            wait(lambda: fixture.completed_observation(store, final_key), "head change wakes the model")
            assert fixture.read_result(store, final_key) == b"watch result received"
            final = fixture.command("action", "read", "--store", store, "--session", session, "--action", action)
            assert final["state"] == "resolved" and final["final"]["code"] == "succeeded", final
            woken = json.loads(provider.requests[-1])
            message = [item for item in woken["input"] if item.get("role") == "user"][-1]["content"]
            assert message[0]["text"] == f"[Rui: background Action {action} reached its final Resolution. The result follows.]\n", message
            # The Resolution arrives inline: the model never needs another round trip to read it.
            resolution = json.loads(message[1]["text"])
            assert resolution["outcome"] == "changed" and resolution["changed"] == ["head"], resolution
            assert resolution["snapshot"]["head_sha"] == SECOND_HEAD and resolution["snapshot"]["lifecycle"] == "open", resolution
            assert set(resolution) == {"outcome", "snapshot", "changed", "coverage"}, resolution
            assert len(provider.requests) == 3, provider.requests
        elif mode == "stop":
            stopped = fixture.command("action", "stop", "--store", store, "--session", session, "--action", action,
                                      "--key", "stop", "--record", case / "stop.json")
            assert stopped["answer"]["status"] == "accepted", stopped
            final = wait(lambda: (value if (value := fixture.command(
                "action", "read", "--store", store, "--session", session, "--action", action
            ))["state"] == "resolved" else None), "cancelled watch")
            assert final["final"]["code"] == "cancelled", final
            wait(lambda: execution_custody_idle(store, session), "cancelled watch cleanup")
            assert fixture.command("request", "inspect", "--store", store, "--key", final_key)["observation"]["status"] == "absent"
            assert len(provider.requests) == 2, provider.requests
        else:
            crash = fixture.crash_host(host, case, "host-crash", diagnostics)
            assert crash["returncode"] == -signal.SIGKILL, crash
            before = github.request_count()
            recovered = fixture.start_host(store, provider_url, "--test-github-api-origin", api, active_capacity=2)
            wait(lambda: fixture.completed_observation(store, final_key), "Host loss wakes the model")
            final = fixture.command("action", "read", "--store", store, "--session", session, "--action", action)
            assert final["state"] == "resolved" and final["final"]["code"] == "indeterminate", final
            woken = json.loads(provider.requests[-1])
            message = [item for item in woken["input"] if item.get("role") == "user"][-1]["content"]
            assert "The Host stopped while watching this pull request." in message[1]["text"], message
            assert github.request_count() == before, "a recovered Host replayed the watch"
            assert len(gh_calls(gh)) == 1, gh_calls(gh)

        # A full Turn after settlement shows nothing was left behind to wake or restart.
        settled = github.request_count()
        calls_after = len(gh_calls(gh))
        fixture.message(case, store, "barrier", session, "Continue after the watch")
        wait(lambda: fixture.completed_observation(store, "barrier"), "post-settlement Turn")
        barrier_result = fixture.read_result(store, "barrier")
        assert barrier_result == b"barrier complete", (mode, barrier_result, len(provider.requests))
        wait(lambda: execution_custody_idle(store, session), "post-settlement cleanup")
        assert github.request_count() == settled and len(gh_calls(gh)) == calls_after
        visible = b"\n".join(provider.requests) + json.dumps(final).encode()
        assert TOKEN.encode() not in visible and b"rui-fixture-ambient-token" not in visible
        for path in store.rglob("*"):
            if path.is_file():
                assert TOKEN.encode() not in path.read_bytes(), path
    finally:
        os.environ.clear()
        os.environ.update(saved)
        dispose_all(
            lambda: fixture.stop_host(recovered) if recovered is not None else None,
            lambda: dispose_owner_case(host, provider, thread),
            github.close,
        )
    return {"mode": mode, "action": action}


def prove_watches(state):
    return [prove_watch(state, mode) for mode in ("change", "stop", "restart")]
