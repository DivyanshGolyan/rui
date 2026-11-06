#!/usr/bin/env python3
"""Request wait observes saved work without admitting, resuming or retargeting it."""
import contextlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import threading
import time

import bash_integration as bash
import bash_recovery_integration as recovery
import canonical_failure_integration as canonical
import host_process
import model_fixture as fixture
from host_process import HostDiagnostics, canonical_fixture_root, dispose_all


RUI = pathlib.Path(sys.argv[1]).resolve()
fixture.RUI = RUI


def answer(name):
    return fixture.sse_answer(name, name + "-reason", name + "-message", name)[0]


@contextlib.contextmanager
def running(state, name, responses):
    home = state / name
    home.mkdir(mode=0o700)
    store = home / "store"
    endpoint = fixture.SuccessEndpoint(responses)
    thread = threading.Thread(target=endpoint.serve_forever)
    thread.start()
    host = None
    try:
        host = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                  "--test-phase-trace", observations="request_wait")
        yield home, store, endpoint, host, HostDiagnostics(host)
    finally:
        dispose_all(
            lambda: fixture.stop_host(host) if host is not None else None,
            endpoint.shutdown, endpoint.server_close, lambda: thread.join(timeout=5),
        )
        assert not thread.is_alive(), "request wait model peer did not retire"


@contextlib.contextmanager
def waiter(store, key, seconds=15, *, handle=None, home=None):
    address = [handle] if handle is not None else ["--store", str(store), "--key", key]
    process = subprocess.Popen([str(RUI), "request", "wait", *address,
                                "--timeout-seconds", str(seconds)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               env={**os.environ, "HOME": str(home)} if home is not None else None)
    try:
        yield process
    finally:
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)


def result(process, status, state, *, timeout=20, minimum_as_of=None):
    stdout, stderr = process.communicate(timeout=timeout)
    assert process.returncode == status, (process.returncode, stdout, stderr)
    value = json.loads(stdout)
    assert value["observation"]["state"] == state, value
    assert "since" not in value and "delta" not in value, value
    assert isinstance(value["as_of"], str) and value["as_of"].isdecimal(), value
    if minimum_as_of is not None:
        assert minimum_as_of <= int(value["as_of"]) <= int(time.time()), value
    return value["observation"], stderr


def pending(home, store, endpoint, name):
    session = fixture.configure(home, store, name + "-configure", None, "gpt-6-sol")
    fixture.message(home, store, name, session, name)
    fixture.wait_for(lambda: len(endpoint.requests) == 1, "model peer received request")
    return session


def completion(state):
    release = threading.Event()
    try:
        with running(state, "completion", [(answer("completed answer"), release)]) as (home, store, endpoint, host, diagnostics):
            # Generated captures exercise HANDLE resolution, not just explicit Store/key.
            started = canonical.invoke(home, "session", "start", "--store", store,
                                       "--workspace", home, "--provider", "codex", "--model", "gpt-6-sol",
                                       input="complete")
            assert started.returncode == 0, started
            handle = canonical.announced(started)
            key = json.loads(started.stdout)["context"]["key"]
            with waiter(store, key, handle=handle, home=home) as process:
                diagnostics.wait("request_observation_full", command_key=key)
                release.set()
                observation, _ = result(process, 0, "completed")
            assert observation["kind"] == "message", observation
            assert fixture.read_result(store, key) == b"completed answer"
            assert len(endpoint.requests) == 1, endpoint.requests
    finally:
        release.set()


def permission(state):
    responses = []
    bash.add_exchange(responses, "permission", "true")
    with running(state, "permission", responses) as (home, store, endpoint, host, diagnostics):
        session = bash.configure(home, store, "permission-configure", permission="ask")
        fixture.message(home, store, "permission", session, "ask first")
        with waiter(store, "permission") as process:
            observation, _ = result(process, 0, "waiting_for_permission")
        assert observation["work"]["state"]["kind"] == "approval", observation
        assert len(endpoint.requests) == 1, endpoint.requests
        assert bash.resolution(store, session) is None, "wait must not consent to Bash"


def timeout_and_absent(state):
    release = threading.Event()
    try:
        with running(state, "timeout", [(answer("timeout answer"), release)]) as (home, store, endpoint, host, diagnostics):
            pending(home, store, endpoint, "timeout")
            latest = fixture.observe(store, "timeout")
            before_wait = int(time.time())
            with waiter(store, "timeout", seconds=2) as process:
                # This asserts render-clock freshness, not actor ordering: an
                # unchanged full observation must not retain its first-read time.
                observation, errors = result(process, 5, "processing", minimum_as_of=before_wait + 1)
            assert observation == latest, (observation, latest)
            assert "[wait_timed_out]" in errors, errors
            unknown = canonical.invoke(home, "request", "wait", "--store", store, "--key", "never-admitted")
            assert unknown.returncode == 4, unknown
            assert json.loads(unknown.stdout)["observation"] == {"status": "absent"}, unknown
            assert "[request_absent]" in unknown.stderr, unknown
            assert "rui request recover" in unknown.stderr, unknown
            release.set()
            fixture.wait_for(lambda: fixture.completed_observation(store, "timeout"), "original request completes")
            assert len(endpoint.requests) == 1, endpoint.requests
    finally:
        release.set()


def stopped_host(state):
    model_release = threading.Event()
    reply_release = threading.Event()
    first_reply = threading.Event()
    try:
        with running(state, "stopped", [(answer("stopped answer"), model_release)]) as (home, store, endpoint, host, diagnostics):
            pending(home, store, endpoint, "stopped")

            def hold_full_reply(response):
                # The Host reply is completely drained before its process dies.
                value = json.loads(response.split(b"\r\n\r\n", 1)[1])
                assert value["observation"]["state"] == "processing", value
                first_reply.set()
                assert reply_release.wait(10), "stopped Host reply was not released"
                return response

            proxy = canonical.ReplyProxy(host, "/v1/observe-command", hold_full_reply)
            try:
                with waiter(store, "stopped") as process:
                    fixture.wait_for(first_reply.is_set, "first wait reply drained")

                    def stop_before_reply():
                        try:
                            fixture.stop_host(host)
                        finally:
                            reply_release.set()

                    # Restore the direct socket before releasing the buffered
                    # reply: every subsequent read must reach the stopped Host,
                    # never a proxy handler or a partially delivered first read.
                    closing, proxy = proxy, None
                    closing.close(after_restore=stop_before_reply)
                    stdout, stderr = process.communicate(timeout=20)
                    assert process.returncode == 6, (process.returncode, stdout, stderr)
                    assert "[host_not_serving]" in stderr, stderr
                    problem = json.loads(stdout)
                    assert problem == {"key": "stopped", "error": {"status": 503,
                        "type": "invocation_error", "code": "host_not_serving"}}, problem
            finally:
                reply_release.set()
                if proxy is not None:
                    proxy.close()
    finally:
        model_release.set()
        reply_release.set()


def interrupted(state, signum):
    release = threading.Event()
    name = "signal-" + str(signum)
    try:
        with running(state, name, [(answer(name), release)]) as (home, store, endpoint, host, diagnostics):
            pending(home, store, endpoint, name)
            with waiter(store, name) as process:
                # A conditional poll proves the first full reply reached the
                # client and was retained before signal cancellation begins.
                diagnostics.wait("request_observation_tier1", command_key=name)
                process.send_signal(signum)
                observation, _ = result(process, 5, "processing")
            assert observation["binding"]["turn"], observation
            release.set()
            fixture.wait_for(lambda: fixture.completed_observation(store, name), "signal does not cancel work")
            assert len(endpoint.requests) == 1, endpoint.requests
    finally:
        release.set()


def tier_two(state):
    model_release = threading.Event()
    reply_release = threading.Event()
    first_reply = threading.Event()
    try:
        with running(state, "tier-two", [(answer("tier two answer"), model_release)]) as (home, store, endpoint, host, diagnostics):
            pending(home, store, endpoint, "tier-two")
            observed = []

            def gate_first_full(response):
                value = json.loads(response.split(b"\r\n\r\n", 1)[1])
                observed.append(value)
                if len(observed) == 1:
                    assert value["delta"] == "full", value
                    # Record peer observation before replying; sibling commit
                    # cannot race ahead of the token captured by this reply.
                    first_reply.set()
                    assert reply_release.wait(10), "sibling configuration did not release reply"
                return response

            proxy = canonical.ReplyProxy(host, "/v1/observe-command", gate_first_full)
            try:
                with waiter(store, "tier-two") as process:
                    fixture.wait_for(first_reply.is_set, "first full reply captured")
                    sibling = fixture.configure(home, store, "sibling-commit", None, "gpt-6-sol")
                    reply_release.set()
                    diagnostics.wait("request_observation_tier2", command_key="tier-two")
                    model_release.set()
                    observation, _ = result(process, 0, "completed")
                assert observation["target"] != sibling, observation
                unchanged = [value for value in observed if value["delta"] == "not_modified"]
                assert unchanged and unchanged[0]["since"] != observed[0]["since"], observed
                assert len(endpoint.requests) == 1, endpoint.requests
            finally:
                reply_release.set()
                proxy.close()
    finally:
        model_release.set()
        reply_release.set()


def restarted_bash(state):
    case = recovery.start_case(state, "wait-restart", "action_result_ready",
                               lambda marker: f"cat >> {marker}", stdin="x")
    store, marker, endpoint, thread, keeper, original, diagnostics, session = case
    recovered = None
    try:
        diagnostics.wait("action_result_ready", action="1")
        assert marker.read_text() == "x", "Bash effect must precede the crash"
        fixture.crash_host(original, state, "wait-restart-crash", diagnostics)
        recovered = fixture.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses")
        with waiter(store, "wait-restart-message") as process:
            observation, _ = result(process, 0, "completed")
        unknown = observation["recovery"]["unknown_outcomes"]
        assert len(unknown) == 1 and unknown[0]["action"] == "1", observation
        assert unknown[0]["description"] == "Run wait-restart command", unknown
        assert observation["recovery"]["more"] is False, observation
        assert bash.resolution(store, session) == "indeterminate"
        assert marker.read_text() == "x", "wait must not replay the recovered Bash"
        assert fixture.read_result(store, "wait-restart-message") == b"wait-restart completed"
        assert len(endpoint.requests) == 2, endpoint.requests
    finally:
        recovery.finish_case(original, recovered, keeper, endpoint, thread)


def main():
    with tempfile.TemporaryDirectory(prefix="rui-request-wait.") as temporary:
        state = canonical_fixture_root(temporary)
        for scenario in (completion, permission, timeout_and_absent, stopped_host,
                         lambda root: interrupted(root, signal.SIGINT),
                         lambda root: interrupted(root, signal.SIGTERM), tier_two, restarted_bash):
            scenario(state)
    print("request wait: completion, permission, timeout, absent, stopped Host, signals, tier 2 and Bash recovery passed")


if __name__ == "__main__":
    host_process.enter()
    main()
