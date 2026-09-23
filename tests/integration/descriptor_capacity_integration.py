#!/usr/bin/env python3
import http.server
import json
import os
import pathlib
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

import bash_integration as bash
import control_integration as control
import dispatch_integration as fixture
from host_process import HostDiagnostics, start_ready_process, stop_process


RUI = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()
fixture.RUI = RUI
control.RUI = RUI


class HeldEndpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), HeldHandler)
        self.condition = threading.Condition()
        self.requests = 0
        self.completed = 0
        self.release = threading.Event()

    def wait_for(self, field, count, timeout=10):
        deadline = time.monotonic() + timeout
        with self.condition:
            while getattr(self, field) < count:
                remaining = deadline - time.monotonic()
                assert remaining > 0, f"timed out waiting for {field}={count}"
                self.condition.wait(remaining)


class HeldHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        with self.server.condition:
            self.server.requests += 1
            self.server.condition.notify_all()
        assert self.server.release.wait(10), "provider fixture was never released"
        body = b'{"error":"descriptor capacity fixture"}'
        self.send_response(422)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
        with self.server.condition:
            self.server.completed += 1
            self.server.condition.notify_all()

    def log_message(self, _format, *_args):
        pass


def limited_host(limit, *arguments):
    return [
        "sh",
        "-c",
        'ulimit -n "$1"; shift; exec "$@"',
        "rui-descriptor-limit",
        str(limit),
        str(RUI),
        *map(str, arguments),
    ]


def command(state, *arguments):
    completed = subprocess.run(
        [str(RUI), *map(str, arguments)],
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout)


def configure(state, store, ordinal):
    session = f"direct/descriptors-{ordinal}"
    result = command(
        state,
        "configure",
        "--store",
        store,
        "--record",
        state / f"configure-{ordinal}.json",
        "--key",
        f"configure-{ordinal}",
        "--session",
        session,
        "--workspace",
        ROOT,
        "--provider",
        "codex",
        "--model",
        "model-a",
    )
    assert result["answer"]["status"] == "accepted", result
    return session


def message(state, store, session, ordinal):
    text = state / f"message-{ordinal}.txt"
    text.write_text(f"descriptor fill {ordinal}")
    result = command(
        state,
        "message",
        "--store",
        store,
        "--record",
        state / f"message-{ordinal}.json",
        "--key",
        f"message-{ordinal}",
        "--session",
        session,
        "--text",
        text,
    )
    assert result["answer"]["status"] == "accepted", result


def observe(state, store, ordinal):
    return command(
        state,
        "observe-command",
        "--store",
        store,
        "--key",
        f"message-{ordinal}",
    )["observation"]


def wait_for(predicate, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.025)
    raise AssertionError(f"timed out waiting for {description}")


def failed_result(state, store, ordinal):
    observation = observe(state, store, ordinal)
    return observation if observation.get("result", {}).get("code") == "provider_http_422" else None


def execution_idle(state, store, session):
    report = command(state, "inspect-session", "--store", store, "--session", session)
    execution = report["execution"]
    return report if execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0" else None


def open_gate(path):
    os.mkfifo(path)
    return os.open(path, os.O_RDWR | os.O_NONBLOCK)


def fill_classification_capacity(socket_path, expected_exhaustion):
    held = []
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            while len(held) < 2:
                try:
                    candidate = control.open_partial(
                        socket_path,
                        "/v1/control/held",
                        complete_headers=False,
                    )
                except (BrokenPipeError, ConnectionResetError):
                    continue
                candidate.settimeout(0.01)
                try:
                    early = candidate.recv(1, socket.MSG_PEEK)
                except TimeoutError:
                    candidate.settimeout(5)
                    held.append(candidate)
                else:
                    if early:
                        head, body = control.read_http_response(candidate)
                        assert b" 503 " in head, (head, body)
                    candidate.close()

            try:
                extra = control.open_partial(
                    socket_path,
                    "/v1/control/extra",
                    complete_headers=False,
                )
            except (BrokenPipeError, ConnectionResetError):
                continue
            try:
                head, body = control.read_http_response(extra)
            except TimeoutError:
                held.append(extra)
            else:
                extra.close()
                if expected_exhaustion in body:
                    assert b" 503 " in head, (head, body)
                    for connection in held[2:]:
                        connection.close()
                    return held[:2]

            live = []
            for candidate in held:
                candidate.settimeout(0.001)
                try:
                    early = candidate.recv(1, socket.MSG_PEEK)
                except TimeoutError:
                    candidate.settimeout(5)
                    live.append(candidate)
                    continue
                if early:
                    head, body = control.read_http_response(candidate)
                    assert b" 503 " in head, (head, body)
                candidate.close()
            held = live
    except BaseException:
        for connection in held:
            connection.close()
        raise
    for connection in held:
        connection.close()
    raise AssertionError("classification admission never stabilized at capacity")


def assert_connections_live(connections):
    for ordinal, connection in enumerate(connections):
        original_timeout = connection.gettimeout()
        connection.settimeout(0.001)
        try:
            unexpected = connection.recv(1, socket.MSG_PEEK)
        except TimeoutError:
            continue
        finally:
            connection.settimeout(original_timeout)
        raise AssertionError(
            f"held connection {ordinal} responded or closed before Bash spawn: {unexpected!r}"
        )


def prove_bash_spawn_with_full_client_population(state, required):
    store = state / "bash-client-overlap-store"
    gate_path = state / "bash-client-overlap-gate"
    keeper = open_gate(gate_path)
    releases = [state / f"bash-release-{ordinal}" for ordinal in range(2)]
    markers = [state / f"bash-marker-{ordinal}" for ordinal in range(2)]
    commands = [
        f"printf x > {shlex.quote(str(marker))}; "
        f"i=0; while [ ! -e {shlex.quote(str(release))} ] && [ \"$i\" -lt 3000 ]; "
        "do sleep 0.01; i=$((i+1)); done"
        for marker, release in zip(markers, releases)
    ]
    responses = [
        fixture.sse_tool_calls(
            f"descriptor-bash-{ordinal}-calls",
            [
                (
                    "bash",
                    f"descriptor-bash-{ordinal}-call",
                    json.dumps({"cmd": commands[ordinal], "timeout_ms": None}, separators=(",", ":")),
                )
            ],
        )
        for ordinal in range(2)
    ]
    responses += [
        fixture.sse_answer(
            f"descriptor-bash-{ordinal}-answer",
            f"descriptor-bash-{ordinal}-reasoning",
            f"descriptor-bash-{ordinal}-message",
            "done",
        )[0]
        for ordinal in range(2)
    ]
    endpoint = fixture.SuccessEndpoint(responses)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    host = None
    diagnostics = None
    held = []
    try:
        # The FIFO gate itself is test-only and consumes one descriptor while
        # it holds the production transition, so this witness supplies one
        # descriptor beyond the production requirement.
        witness_limit = required + 1
        host, ready = start_ready_process(
            limited_host(
                witness_limit,
                "serve",
                "--store",
                store,
                "--active-capacity",
                "2",
                "--provider-endpoint",
                f"http://127.0.0.1:{endpoint.server_port}/responses",
                "--test-phase-trace",
                "--test-transition",
                "action-attempt-admitted",
                "--test-transition-gate-path",
                gate_path,
            ),
            required_fields={"descriptor_requirement": str(required), "descriptor_limit": str(witness_limit)},
        )
        diagnostics = HostDiagnostics(host)
        sessions = [f"direct/descriptor-bash-{ordinal}" for ordinal in range(2)]
        for ordinal, session in enumerate(sessions):
            bash.configure(state, store, f"bash-configure-{ordinal}", session, permission="bypass")
            fixture.message(state, store, f"bash-message-{ordinal}", session, f"run bash {ordinal}")
            diagnostics.wait("action_attempt_admitted", action=str(ordinal + 1), attempt="1")
            if ordinal == 0:
                os.write(keeper, b"x")
                wait_for(markers[0].exists, "first Bash process")

        socket_path = ready["socket"]
        held = control.fill_ordinary_capacity(socket_path)
        control.assert_ordinary_capacity_busy(socket_path)
        held += fill_classification_capacity(
            socket_path, b"connection_capacity_exhausted"
        )
        assert len(held) == 12
        assert_connections_live(held)

        os.write(keeper, b"x")
        wait_for(markers[1].exists, "second Bash spawn with full clients")
        for connection in held:
            connection.close()
        held = []
        for release in releases:
            release.touch()
        for ordinal, session in enumerate(sessions):
            wait_for(lambda session=session: bash.resolution(store, session) == "succeeded", f"Bash {ordinal} result")
        wait_for(lambda: execution_idle(state, store, sessions[0]), "Bash overlap execution drain")
        assert host.poll() is None, diagnostics.tail()
    finally:
        for connection in held:
            connection.close()
        for release in releases:
            release.touch(exist_ok=True)
        if host is not None:
            stop_process(host)
        if diagnostics is not None:
            diagnostics.close()
        os.close(keeper)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=3)


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-descriptor-capacity-"))
    state.chmod(0o700)
    endpoint = HeldEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    host = None
    documented = None
    diagnostics = None
    try:
        required = 72 if sys.platform == "darwin" else 70
        rejected_store = state / "rejected-store"
        rejected = subprocess.run(
            limited_host(
                required - 1,
                "serve",
                "--store",
                rejected_store,
                "--active-capacity",
                "2",
                "--provider-endpoint",
                f"http://127.0.0.1:{endpoint.server_port}/responses",
            ),
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert rejected.returncode != 0, rejected.stdout
        assert not rejected.stdout.startswith("ready "), rejected.stdout
        assert "descriptor capacity insufficient" in rejected.stderr, rejected.stderr
        assert "active_capacity=2" in rejected.stderr, rejected.stderr
        assert f"required={required}" in rejected.stderr, rejected.stderr
        assert f"soft_limit={required - 1}" in rejected.stderr, rejected.stderr
        assert not rejected_store.exists(), "descriptor rejection followed startup side effects"

        store = state / "adequate-store"
        host, ready = start_ready_process(
            limited_host(
                required,
                "serve",
                "--store",
                store,
                "--active-capacity",
                "2",
                "--provider-endpoint",
                f"http://127.0.0.1:{endpoint.server_port}/responses",
            ),
            required_fields={
                "descriptor_requirement": str(required),
                "descriptor_limit": str(required),
            },
        )
        diagnostics = HostDiagnostics(host)
        sessions = [configure(state, store, ordinal) for ordinal in range(4)]
        message(state, store, sessions[0], 0)
        message(state, store, sessions[1], 1)
        endpoint.wait_for("requests", 2)
        assert host.poll() is None, diagnostics.tail()

        endpoint.release.set()
        endpoint.wait_for("completed", 2)
        for ordinal in range(2):
            wait_for(lambda ordinal=ordinal: failed_result(state, store, ordinal), f"message {ordinal} result")
        wait_for(lambda: execution_idle(state, store, sessions[0]), "first complete execution drain")

        endpoint.release.clear()
        message(state, store, sessions[2], 2)
        message(state, store, sessions[3], 3)
        endpoint.wait_for("requests", 4)
        assert endpoint.completed == 2, endpoint.completed
        endpoint.release.set()
        endpoint.wait_for("completed", 4)
        for ordinal in range(2, 4):
            wait_for(lambda ordinal=ordinal: failed_result(state, store, ordinal), f"message {ordinal} result")
        wait_for(lambda: execution_idle(state, store, sessions[2]), "second complete execution drain")
        assert host.poll() is None, diagnostics.tail()

        documented_store = state / "documented-store"
        documented, _ = start_ready_process(
            limited_host(
                256,
                "serve",
                "--store",
                documented_store,
                "--active-capacity",
                "8",
            ),
            required_fields={"active_capacity": "8", "descriptor_limit": "256"},
        )
        stop_process(documented)
        documented = None
        prove_bash_spawn_with_full_client_population(state, required)
    finally:
        if documented is not None:
            stop_process(documented)
        if host is not None:
            stop_process(host)
        if diagnostics is not None:
            diagnostics.close()
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=3)
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
