#!/usr/bin/env python3
"""Deterministic Session-stop and exact model-interruption integration proof."""

import http.server
import concurrent.futures
import errno
import hashlib
import json
import os
import pathlib
import select
import shutil
import socket
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import threading
import time

import host_process
from host_process import STORE_SCHEMA, HostDiagnostics, PeerCensus, ReleaseGate, TestHTTPServer, canonical_fixture_root, is_peer_disconnect, preserve_failure_metadata, retain_failure_state, start_ready_process, stop_process, wait_for, wait_for_execution_release


RUI = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()
# Independent fixture populations, not Host connection limits.
ORDINARY_CLIENTS = 10
CONTROL_HEADROOM = 2
MAX_STORE_BYTES = 492
MAX_KEY_BYTES = 128
MAX_SESSION_BYTES = 128


def maximum_json_string_bytes(length):
    return 2 + 6 * length


MAX_SESSION_STOP_REQUEST_BYTES = (
    len('{"version":"4","kind":"session_stop","store":')
    + maximum_json_string_bytes(MAX_STORE_BYTES)
    + len(',"key":')
    + maximum_json_string_bytes(MAX_KEY_BYTES)
    + len(',"session":')
    + maximum_json_string_bytes(MAX_SESSION_BYTES)
    + 1
)
MAX_MODEL_INTERRUPTION_REQUEST_BYTES = (
    len('{"version":"4","kind":"model_interruption","store":')
    + maximum_json_string_bytes(MAX_STORE_BYTES)
    + len(',"key":')
    + maximum_json_string_bytes(MAX_KEY_BYTES)
    + len(',"target":{"session":')
    + maximum_json_string_bytes(MAX_SESSION_BYTES)
    + len(',"turn":"')
    + 20
    + len('","operation":"')
    + 20
    + len('"}}')
)


class StreamingEndpoint(TestHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), StreamingHandler)
        self.condition = threading.Condition()
        self.requests = 0
        self.disconnects = 0
        self.release = threading.Event()

    def counts(self):
        with self.condition:
            return self.requests, self.disconnects


class StreamingHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        with self.server.condition:
            self.server.requests += 1
            self.server.condition.notify_all()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        while not self.server.release.wait(0.025):
            try:
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
            except OSError as error:
                if not is_peer_disconnect(error):
                    raise
                with self.server.condition:
                    self.server.disconnects += 1
                    self.server.condition.notify_all()
                return

    def log_message(self, _format, *_args):
        pass


def encode_sse(payloads):
    return b"".join(
        b"event: response\ndata: "
        + json.dumps(payload, separators=(",", ":")).encode()
        + b"\n\n"
        for payload in payloads
    )


def successful_sse(index, answer=None):
    if answer is None:
        answer = f"answer-{index}"
    message_item = {
        "type": "message",
        "id": f"message-{index}",
        "status": "completed",
        "role": "assistant",
        "phase": "final_answer",
        "content": [
            {"type": "output_text", "text": answer, "annotations": []}
        ],
    }
    return encode_sse(
        [
            {
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {"type": "message", "id": message_item["id"]},
            },
            {
                "type": "response.output_item.done",
                "output_index": 0,
                "item": message_item,
            },
            {
                "type": "response.completed",
                "response": {
                    "id": f"response-{index}",
                    "status": "completed",
                    "model": "gpt-6-sol",
                    "output": [message_item],
                    "usage": {
                        "input_tokens": 7,
                        "output_tokens": 11,
                        "total_tokens": 18,
                    },
                },
            },
        ]
    )


class SuccessfulEndpoint(TestHTTPServer):
    allow_reuse_address = True

    def __init__(self, large_answer_bytes=0):
        super().__init__(("127.0.0.1", 0), SuccessfulHandler)
        self.condition = threading.Condition()
        self.requests = 0
        self.release = threading.Event()
        self.large_answer_bytes = large_answer_bytes

    def count(self):
        with self.condition:
            return self.requests


class SuccessfulHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        with self.server.condition:
            self.server.requests += 1
            index = self.server.requests
            self.server.condition.notify_all()
        if not self.server.release.wait(10):
            raise RuntimeError("successful fixture response was never released")
        marker = "RUI_STREAMED_ANSWER_MARKER"
        if self.server.large_answer_bytes and index == 1:
            body_parts = successful_sse(index, marker).split(marker.encode())
            assert len(body_parts) == 3
            content_length = (
                sum(map(len, body_parts)) + 2 * self.server.large_answer_bytes
            )
        else:
            body = successful_sse(index)
            body_parts = [body]
            content_length = len(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(content_length))
        self.send_header("OpenAI-Model", "gpt-6-sol")
        self.send_header("X-Request-Id", f"request-{index}")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            chunk = b"x" * (64 * 1024)
            for part_index, part in enumerate(body_parts):
                self.wfile.write(part)
                if part_index == len(body_parts) - 1:
                    continue
                remaining = self.server.large_answer_bytes
                while remaining:
                    written = min(remaining, len(chunk))
                    self.wfile.write(chunk[:written])
                    remaining -= written
            self.wfile.flush()
        except OSError as error:
            if not is_peer_disconnect(error):
                raise
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


class RetryWaitEndpoint(TestHTTPServer):
    allow_reuse_address = True

    def __init__(self, label):
        super().__init__(("127.0.0.1", 0), RetryWaitHandler)
        self.condition = threading.Condition()
        self.label = label
        self.requests = 0

    def count(self):
        with self.condition:
            return self.requests


class RetryWaitHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        with self.server.condition:
            self.server.requests += 1
            request_number = self.server.requests
            self.server.condition.notify_all()
        if request_number == 1:
            body = b"temporary"
            status = 503
            content_type = "text/plain"
        else:
            body = successful_sse(f"late-{self.server.label}")
            status = 200
            content_type = "text/event-stream"
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def command(*args, expect=0, timeout=15, input=None):
    completed = subprocess.run(
        [str(RUI), *map(str, args)],
        text=True,
        input=input,
        capture_output=True,
        timeout=timeout,
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"command returned {completed.returncode}, wanted {expect}: {args}\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )
    return json.loads(completed.stdout)


def start_host(store, endpoint=None, *extra, active_capacity=2, observations=None):
    args = [
        str(RUI),
        "host", "serve",
        "--store",
        str(store),
        "--active-capacity",
        str(active_capacity),
    ]
    required = {"execution": "unavailable"}
    if endpoint is not None:
        args += ["--provider-endpoint", endpoint]
        required = {"execution": "enabled", "nghttp2": "1.70.0"}
    args += extra
    if observations is not None and "--test-phase-trace" not in args:
        args.append("--test-phase-trace")
    return start_ready_process(args, required_fields=required,
                               observations=observations or ("control" if "--test-phase-trace" in extra else None))


def configure(state, store, key, session=None):
    args = [
        "session", "configure",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--workspace",
        ROOT,
        "--provider",
        "codex",
        "--model",
        "gpt-6-sol",
    ]
    if session is not None:
        args += ["--session", session]
    result = command(*args)
    assert result["answer"]["status"] == "accepted", result
    return result["answer"]["session"]


def message(state, store, key, session, text):
    result = command(
        "session", "send",
        "--store",
        store,
        "--to",
        session,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        input=text,
    )
    assert result["answer"]["status"] == "accepted", result


def stop_session(state, store, key, session):
    return command(
        "session", "stop",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
    )


def interrupt_model(state, store, key, session, processing):
    return command(
        "session", "interrupt-model",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
        "--turn",
        processing["turn"],
        "--operation",
        processing["operation"],
    )


def observe(store, key, *, deadline=None):
    remaining = 15 if deadline is None else min(15, deadline - time.monotonic())
    assert remaining > 0, "result observation exhausted original deadline"
    return command("request", "inspect", "--store", store, "--key", key,
                   timeout=remaining)["observation"]


def percentile_95(values):
    ordered = sorted(values)
    return ordered[max(0, (95 * len(ordered) + 99) // 100 - 1)]


def read_http_response(connection, timeout=3, *, deadline=None):
    connection.settimeout(timeout)

    def receive():
        if deadline is not None:
            remaining = min(timeout, deadline - time.monotonic())
            assert remaining > 0, "Host response exhausted original deadline"
            connection.settimeout(remaining)
        chunk = connection.recv(4096)
        assert deadline is None or time.monotonic() < deadline, "Host response exceeded original deadline"
        return chunk

    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = receive()
        if not chunk:
            break
        response.extend(chunk)
    head, _, body = bytes(response).partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    while len(body) < length:
        chunk = receive()
        if not chunk:
            break
        body += chunk
    return head, body


def open_partial(socket_path, route, *, complete_headers=True):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(3)
        connection.connect(socket_path)
        connection.sendall(f"POST {route} HTTP/1.1\r\n".encode())
        if complete_headers:
            connection.sendall(
                b"Content-Type: application/json\r\n"
                b"Content-Length: 1024\r\n"
                b"X-Rui-Wire-Version: 4\r\n\r\n{"
            )
    except BaseException:
        connection.close()
        raise
    return connection


def environment_header(route):
    """A Message carries a client environment; these raw ones carry none."""
    return b"X-Rui-Environment-Bytes: 0\r\n" if route == "/v1/message" else b""


def raw_request(socket_path, route, body, declared_length=None):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(5)
        connection.connect(socket_path)
        length = len(body) if declared_length is None else declared_length
        connection.sendall(
            f"POST {route} HTTP/1.1\r\n".encode()
            + b"Content-Type: application/json\r\n"
            + f"Content-Length: {length}\r\n".encode()
            + environment_header(route)
            + b"X-Rui-Wire-Version: 4\r\n\r\n"
            + body
        )
        return read_http_response(connection)
    finally:
        connection.close()


def prepare_raw_request(socket_path, route, body):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(20)
    connection.connect(socket_path)
    request = (
        f"POST {route} HTTP/1.1\r\n".encode()
        + b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
        + environment_header(route)
        + b"X-Rui-Wire-Version: 4\r\n\r\n"
        + body
    )
    connection.sendall(request[:-1])
    return connection, request[-1:]


def submit_prepared_request(prepared, start):
    connection, suffix = prepared
    if not start.wait(20):
        raise TimeoutError("prepared control was not released")
    started = time.monotonic_ns()
    try:
        connection.sendall(suffix)
        head, body = read_http_response(connection, timeout=20)
        assert b" 200 " in head, (head, body)
        return json.loads(body), (time.monotonic_ns() - started) / 1_000_000
    finally:
        connection.close()


def open_complete_inspection(socket_path, store, session, profile):
    request = {
        "version": "4",
        "kind": "inspect_session",
        "store": str(store),
        "session": session,
    }
    if profile == "full":
        request["profile"] = "full"
    body = json.dumps(request, separators=(",", ":")).encode()
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(15)
        connection.connect(socket_path)
        connection.sendall(
            b"POST /v1/inspect-session HTTP/1.1\r\n"
            b"Content-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\n".encode()
            + b"X-Rui-Wire-Version: 4\r\n\r\n"
            + body
        )
    except BaseException:
        connection.close()
        raise
    return connection


def fill_complete_inspections(socket_path, store, session, peers):
    held = []
    try:
        for index in range(ORDINARY_CLIENTS):
            peers.diagnostics.claim_inspection()
            held.append(peers.open("inspect", lambda: open_complete_inspection(
                socket_path, store, session, "current" if index % 2 == 0 else "full")))
        return held
    except BaseException:
        for connection in held:
            connection.close()
        raise


def inspect_execution(store, session, *, timeout=15):
    return command(
        "session", "inspect",
        "--store",
        store,
        "--session",
        session,
        timeout=timeout,
    )["execution"]


def wait_execution_release(diagnostics, store, session, deadline, *, peers=None):
    execution = None

    def inspect(remaining):
        nonlocal execution
        diagnostics.claim_inspection()
        invoke = lambda: inspect_execution(store, session, timeout=remaining)
        execution = invoke() if peers is None else peers.call("inspect", invoke, deadline=deadline)
        return execution

    try:
        return wait_for_execution_release(inspect, deadline)
    except BaseException:
        # Retain this boundary's existing facts before destructive teardown;
        # optional capture failure cannot replace the original refusal.
        preserve_failure_metadata(store.parent / "probe.log", lambda: {
            "execution": execution,
            "deadline": deadline,
            "observed_at": time.monotonic(),
            "native": diagnostics.observations.snapshot(),
            "atomic_census": False,
        })
        raise


def retry(state, store, record_key, kind):
    return command(
        "request", "recover",
        "--store",
        store,
        "--record",
        state / f"{record_key}.json",
        "--kind",
        kind,
    )


def result_digest(store, key, destination):
    with destination.open("wb") as output:
        completed = subprocess.run(
            [
                str(RUI),
                "request", "read-result",
                "--store",
                str(store),
                "--key",
                key,
            ],
            stdout=output,
            stderr=subprocess.PIPE,
            timeout=30,
        )
    if completed.returncode != 0:
        raise AssertionError(
            f"read-result returned {completed.returncode}: {completed.stderr!r}"
        )
    digest = hashlib.sha256()
    with destination.open("rb") as source:
        while chunk := source.read(64 * 1024):
            digest.update(chunk)
    return destination.stat().st_size, digest.hexdigest()


def open_blocked_result(socket_path, store, key):
    body = json.dumps(
        {
            "version": "4",
            "kind": "read_result",
            "store": str(store),
            "key": key,
        },
        separators=(",", ":"),
    ).encode()
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    connection.settimeout(5)
    connection.connect(socket_path)
    connection.sendall(
        b"POST /v1/read-result HTTP/1.1\r\n"
        b"Host: local\r\n"
        b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
        + b"X-Rui-Wire-Version: 4\r\n"
        b"Connection: close\r\n\r\n"
        + body
    )
    prefix = connection.recv(len(b"HTTP/1.1 200 "), socket.MSG_PEEK)
    if not prefix.startswith(b"HTTP/1.1 200 "):
        connection.close()
        raise AssertionError(f"blocked result delivery returned {prefix!r}")
    return connection


def repeated_byte_digest(byte, length):
    digest = hashlib.sha256()
    chunk = byte * (64 * 1024)
    remaining = length
    while remaining:
        used = min(remaining, len(chunk))
        digest.update(chunk[:used])
        remaining -= used
    return digest.hexdigest()


def maximum_body(kind):
    encoded_store = "\\u0001" * MAX_STORE_BYTES
    encoded_key = "\\u0001" * MAX_KEY_BYTES
    encoded_session = "\\u0001" * MAX_SESSION_BYTES
    if kind == "session_stop":
        body = (
            '{"version":"4","kind":"session_stop","store":"'
            + encoded_store
            + '","key":"'
            + encoded_key
            + '","session":"'
            + encoded_session
            + '"}'
        )
        assert len(body) == MAX_SESSION_STOP_REQUEST_BYTES
        return body.encode()
    body = (
        '{"version":"4","kind":"model_interruption","store":"'
        + encoded_store
        + '","key":"'
        + encoded_key
        + '","target":{"session":"'
        + encoded_session
        + '","turn":"18446744073709551615","operation":"18446744073709551615"}}'
    )
    assert len(body) == MAX_MODEL_INTERRUPTION_REQUEST_BYTES
    return body.encode()


def check_schema(database_path):
    database = sqlite3.connect(database_path)
    try:
        assert database.execute("PRAGMA user_version").fetchone()[0] == STORE_SCHEMA
        stop_columns = [
            row[1] for row in database.execute("PRAGMA table_info(session_stop)")
        ]
        interruption_columns = [
            row[1]
            for row in database.execute("PRAGMA table_info(model_interruption_command)")
        ]
        operation_columns = [
            row[1] for row in database.execute("PRAGMA table_info(model_operation)")
        ]
        assert stop_columns == [
            "command_key",
            "session_ref",
            "selected_turn_id",
            "position",
            "admission_cutoff",
            "stopped_at",
        ]
        assert interruption_columns == [
            "command_key",
            "session_ref",
            "turn_id",
            "operation_id",
        ]
        assert "interrupted_by_command_key" in operation_columns
        provenances = database.execute(
            "SELECT resolution_code,interrupted_by_command_key FROM model_operation "
            "WHERE interrupted_by_command_key IS NOT NULL ORDER BY operation_id"
        ).fetchall()
        assert provenances == [("interrupted", "exact-interrupt"), ("interrupted", "active-stop")]
    finally:
        database.close()


def open_held_population(socket_path, peers):
    """Open each fixture member once and witness its native borrower."""
    held = []
    try:
        for _ in range(ORDINARY_CLIENTS):
            held.append(peers.open("inspect", lambda: open_partial(socket_path, "/v1/inspect-session"), timeout=3))
        peers.held(peers.borrowers.values())
        return held
    except BaseException:
        for candidate in held:
            candidate.close()
        raise


def assert_intake_progress(socket_path, store, peers=None):
    """Both Store observation and protected discovery progress beside borrowers."""
    for kind, route in (("observe_command", "/v1/observe-command"),
                        ("host_info", "/v1/host-info")):
        request = {"version": "4", "kind": kind, "store": str(store)}
        if kind == "observe_command":
            request["key"] = "intake-progress-absent"
        def invoke():
            return raw_request(socket_path, route, json.dumps(request).encode())
        head, body = invoke() if peers is None else peers.call(
            "observe" if kind == "observe_command" else kind, invoke)
        assert head.startswith(b"HTTP/1.1 200 "), (head, body)
        value = json.loads(body)
        if kind == "observe_command":
            assert value["observation"]["status"] == "absent", value
        else:
            assert value["store"] == str(store) and len(value["instance"]) == 32, value


def start_success_endpoint(*, large_answer_bytes=0):
    endpoint = SuccessfulEndpoint(large_answer_bytes)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    return endpoint, thread


def stop_success_endpoint(endpoint, thread):
    endpoint.release.set()
    endpoint.shutdown()
    endpoint.server_close()
    thread.join(timeout=5)


def stop_control_case(process, diagnostics, endpoint, thread, *releases, connections=()):
    incoming_error = sys.exc_info()[1]
    errors = []

    def attempt(dispose):
        try:
            dispose()
        except BaseException as error:
            errors.append(error)

    for connection in connections:
        attempt(connection.close)
    if process is not None:
        attempt(lambda: stop_process(process))
    for release in releases:
        attempt(release)
    if diagnostics is not None:
        attempt(diagnostics.close)
    attempt(endpoint.release.set)
    attempt(endpoint.shutdown)
    attempt(endpoint.server_close)

    def join():
        thread.join(timeout=5)
        assert not thread.is_alive(), "Control endpoint thread did not retire"

    attempt(join)
    if errors:
        for error in errors:
            try:
                print(f"Control cleanup failed: {type(error).__name__}: {error}", file=sys.stderr)
            except Exception:
                pass  # Reporting cannot replace the original assertion or cleanup failure.
        if incoming_error is None:
            raise errors[0]


def prove_pre_handoff_stop(state):
    store = state / "pre-handoff-store"
    store.mkdir(mode=0o700)
    endpoint, endpoint_thread = start_success_endpoint()
    endpoint.release.set()
    process = None
    milestones = None
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        process, _ = start_host(
            store,
            url,
            "--test-phase-trace",
            "--test-before-launch-delay-ms",
            "3000",
            "--test-suppress-first-control-hint",
            observations="control_peers",
        )
        milestones = HostDiagnostics(process)
        peers = PeerCensus(milestones)
        session = peers.call("configure", lambda: configure(state, store, "pre-handoff-config"))
        peers.call("message", lambda: message(
            state,
            store,
            "pre-handoff-message",
            session,
            "must never launch",
        ))
        prepared = milestones.wait("prepared_before_handoff")[0]
        stopped = peers.call("session_stop", lambda: stop_session(
            state, store, "pre-handoff-stop", session
        ))
        assert stopped["answer"]["status"] == "accepted", stopped
        milestones.wait(
            "control_hint_suppressed", subject="pre-handoff-stop"
        )
        semantic = peers.call("observe", lambda: observe(store, "pre-handoff-message"))
        assert semantic["result"]["status"] == "cancelled", semantic
        replayed = peers.call("session_stop", lambda: retry(state, store, "pre-handoff-stop", "session-stop"))
        assert replayed["answer"]["status"] == "accepted", replayed
        assert replayed["answer"]["replayed"] is True, replayed
        milestones.wait("control_hint_published", subject="pre-handoff-stop")
        release_deadline = time.monotonic() + 8
        superseded = milestones.wait(
            "canonical_handoff_superseded",
            operation=prepared["operation"],
            timeout=release_deadline - time.monotonic(),
        )[0]
        assert isinstance(superseded["trace_lost"], bool), superseded
        # The marker precedes finishCustodyNow. Only the same execution owner's
        # next lifecycle boundary proves that the superseded branch returned.
        with milestones.condition:
            while True:
                boundaries = [
                    record for record in milestones.records
                    if record["rui_test_phase"] == "lifecycle_boundary"
                    and record["process"] == superseded["process"]
                    and record["run"] == superseded["run"]
                    and int(record["sequence"]) > int(superseded["sequence"])
                    and int(record["at_ns"]) >= int(superseded["at_ns"])
                ]
                if boundaries:
                    boundary = boundaries[0]
                    assert isinstance(boundary["trace_lost"], bool), boundary
                    assert not superseded["trace_lost"] or boundary["trace_lost"], boundary
                    break
                remaining = release_deadline - time.monotonic()
                assert remaining > 0, ("missing post-superseded execution boundary", superseded)
                milestones.condition.wait(remaining)
        assert endpoint.count() == 0, endpoint.count()

        def inspection():
            remaining = release_deadline - time.monotonic()
            assert remaining > 0, ("superseded custody did not release within 8s", boundary)
            execution = peers.call("inspect", lambda: inspect_execution(
                store, session, timeout=remaining,
            ), deadline=release_deadline)
            assert execution["dispatch_fenced"] is False, execution
            assert execution["scratch_used_bytes"] == "0", execution
            return execution
        # Inspection can sample a temporary no-work admission reservation;
        # require an actual zero, never an allowance or a stable idle census.
        execution = wait_for(inspection, f"superseded custody release within 8s after boundary {boundary}",
                             interval=0.01, deadline=release_deadline,
                             ready=lambda execution: execution["custody_occupied"] == "0")
        assert endpoint.count() == 0, endpoint.count()
        print("pre-handoff release:", json.dumps({
            "superseded": superseded,
            "execution_boundary": boundary,
            "execution": execution,
            "release_budget_seconds": 8,
            "release_elapsed_seconds": 8 - (release_deadline - time.monotonic()),
        }), flush=True)
    finally:
        stop_control_case(process, milestones, endpoint, endpoint_thread)
    peers.finish(time.monotonic() + 5)


def prove_sealed_interruption_and_cleanup(state):
    store = state / "sealed-store"
    store.mkdir(mode=0o700)
    endpoint, endpoint_thread = start_success_endpoint()
    process = None
    milestones = None
    settlement_gate = ReleaseGate(state / "sealed-result-gate")
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        process, _ = start_host(
            store,
            url,
            "--test-phase-trace",
            "--test-model-result-gate-path",
            settlement_gate.path,
            "--test-suppress-first-control-hint",
        )
        milestones = HostDiagnostics(process)
        session = configure(state, store, "sealed-config")
        message(state, store, "sealed-message", session, "sealed race")
        wait_for(lambda: endpoint.count() == 1, "sealed provider request")
        processing = wait_for(
            lambda: observe(store, "sealed-message").get("processing"),
            "sealed processing identity",
        )
        endpoint.release.set()
        milestones.wait(
            "sealed_before_settlement", operation=processing["operation"]
        )
        interrupted = interrupt_model(
            state,
            store,
            "sealed-interrupt",
            session,
            processing,
        )
        assert interrupted["answer"]["status"] == "accepted", interrupted
        milestones.wait("control_hint_suppressed", subject="sealed-interrupt")
        semantic = observe(store, "sealed-message")
        assert semantic["result"]["status"] == "cancelled", semantic
        milestones.claim_inspection()
        execution = inspect_execution(store, session)
        assert execution["custody_occupied"] == "1", execution
        # Host information counts the same held record, read from memory.
        host = command("host", "status", "--store", store)
        assert host["status"] == "ready" and host["custody_occupied"] == "1", host

        replayed = retry(state, store, "sealed-interrupt", "model-interruption")
        assert replayed["answer"]["status"] == "accepted", replayed
        assert replayed["answer"]["replayed"] is True, replayed
        milestones.wait("control_hint_published", subject="sealed-interrupt")
        settlement_gate.release()
        release_deadline = time.monotonic() + 8
        milestones.wait(
            "model_settlement_superseded", operation=processing["operation"]
        )
        milestones.wait_model_cleanup(processing, release_deadline)
        wait_execution_release(
            milestones, store, session, release_deadline,
        )
        assert observe(store, "sealed-message") == semantic
        assert len(
            milestones.matching(
                "cleanup_completed", operation=processing["operation"]
            )
        ) == 1
        unavailable = subprocess.run(
            [
                str(RUI),
                "request", "read-result",
                "--store",
                str(store),
                "--key",
                "sealed-message",
            ],
            text=True,
            capture_output=True,
            timeout=15,
        )
        assert unavailable.returncode != 0, unavailable
        # A reader may resolve the FIFO name just before its sole writer
        # closes. Reproduce that no-writer state without a scheduler race.
        os.mkfifo(settlement_gate.path, mode=0o600)
        message(state, store, "released-gate-message", session, "after release")
        successor_deadline = time.monotonic() + 8
        released = wait_for(
            lambda: (value := observe(store, "released-gate-message", deadline=successor_deadline))
            .get("result", {}).get("status") == "completed" and value,
            "settlement gate with no writer does not strand its reader",
            deadline=successor_deadline,
        )
        milestones.wait_model_cleanup(released["processing"], successor_deadline)
        wait_execution_release(milestones, store, session, successor_deadline)
    finally:
        stop_control_case(
            process, milestones, endpoint, endpoint_thread,
            settlement_gate.release,
            lambda: settlement_gate.path.unlink(missing_ok=True),
        )
        if milestones is not None and sys.exc_info()[1] is None:
            milestones.assert_model_cleanup_census(processing, released["processing"])


def prove_delivery_and_settlement_contention(state, *, sample_host=None):
    store = state / "contention-store"
    store.mkdir(mode=0o700)
    endpoint, endpoint_thread = start_success_endpoint()
    process = None
    milestones = None
    inspections = []
    inspection_gate = ReleaseGate(state / "contention-inspection-gate")
    settlement_gate = ReleaseGate(state / "contention-result-gate")
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        extra = [
            "--test-phase-trace",
            "--test-inspection-reply-gate-path",
            inspection_gate.path,
            "--test-model-result-gate-path",
            settlement_gate.path,
        ]
        # Keep two independently held fixture responses while exercising the
        # two client control places.
        process, fields = start_host(store, url, *extra, active_capacity=101, observations="control_peers")
        milestones = HostDiagnostics(process)
        peers = PeerCensus(milestones)
        resource_samples = {}
        if sample_host is not None:
            resource_samples["idle"] = sample_host(process.pid, "idle")
        sessions = []
        for index in range(CONTROL_HEADROOM):
            session = peers.call("configure", lambda: configure(state, store, f"contention-config-{index}"))
            sessions.append(session)
            peers.call("message", lambda: message(
                state,
                store,
                f"contention-message-{index}",
                session,
                f"contention {index}",
            ))
        wait_for(
            lambda: endpoint.count() == CONTROL_HEADROOM,
            "held successful responses for both control places",
        )
        processings = []
        for index in range(CONTROL_HEADROOM):
            deadline = time.monotonic() + 8
            processings.append(wait_for(
                lambda index=index: peers.call("observe", lambda: observe(
                    store, f"contention-message-{index}", deadline=deadline
                ), deadline=deadline).get("processing"),
                f"contention processing identity {index}", deadline=deadline,
            ))

        inspections = fill_complete_inspections(
            fields["socket"], fields["store"], sessions[0], peers
        )
        milestones.wait(
            "inspection_captured",
            count=ORDINARY_CLIENTS,
            timeout=10,
            subject=sessions[0],
        )
        milestones.wait(
            "test_gate_waiting", count=ORDINARY_CLIENTS, timeout=10,
            subject=str(inspection_gate.path),
        )
        assert_intake_progress(fields["socket"], store, peers)
        if sample_host is not None:
            resource_samples["reports_captured_and_responses_held"] = sample_host(
                process.pid, "reports_captured_and_responses_held"
            )

        endpoint.release.set()
        milestones.wait("sealed_before_settlement", timeout=8)
        control_requests = [peers.expect("session_stop") for _ in range(CONTROL_HEADROOM)]
        control_deadline = time.monotonic() + 10
        barrier = threading.Barrier(CONTROL_HEADROOM + 1, timeout=10)

        def run_stop(index):
            barrier.wait()
            started = time.monotonic_ns()
            reply = stop_session(
                state,
                store,
                f"contention-stop-{index}",
                sessions[index],
            )
            return reply, (time.monotonic_ns() - started) / 1_000_000

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=CONTROL_HEADROOM
        ) as pool:
            try:
                futures = [
                    pool.submit(run_stop, index) for index in range(CONTROL_HEADROOM)
                ]
                barrier.wait()
            except BaseException:
                # Wake submitted workers before the executor waits for them.
                barrier.abort()
                raise
            results = [future.result(timeout=10) for future in futures]
        for reply, _ in results:
            assert reply["answer"]["status"] == "accepted", reply
        # Accepted controls establish the race. Evidence collection must not
        # extend the workload's deliberate settlement gate.
        settlement_gate.release()
        for request in control_requests:
            peers.release(request, control_deadline)
        timings = milestones.wait(
            "control_timing", count=CONTROL_HEADROOM, timeout=8
        )
        assert len({record["command_key"] for record in timings}) == CONTROL_HEADROOM
        publications = milestones.wait(
            "control_hint_published", count=CONTROL_HEADROOM, timeout=8
        )
        publication_by_key = {
            record["subject"]: record for record in publications
        }
        assert set(publication_by_key) == {
            f"contention-stop-{index}" for index in range(CONTROL_HEADROOM)
        }
        timing_by_key = {record["command_key"]: record for record in timings}
        for command_key, publication in publication_by_key.items():
            assert int(publication["at_ns"]) <= int(
                timing_by_key[command_key]["reply_complete_at_ns"]
            )
        milestones.wait("model_settlement_superseded", timeout=8)
        if sample_host is not None:
            resource_samples["controls_acknowledged"] = sample_host(
                process.pid, "controls_acknowledged"
            )

        inspection_deadline = time.monotonic() + 12
        inspection_gate.release()
        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
            responses = list(
                pool.map(lambda connection: read_http_response(connection, 12, deadline=inspection_deadline), inspections)
            )
        for head, body in responses:
            assert b" 200 " in head, (head, body)
        peers.close(inspections, inspection_deadline)
        inspections.clear()
        for index in range(CONTROL_HEADROOM):
            deadline = time.monotonic() + 8
            result = wait_for(
                lambda index=index: peers.call("observe", lambda: observe(
                    store, f"contention-message-{index}", deadline=deadline
                ), deadline=deadline).get("result"),
                f"contention result {index}", deadline=deadline,
            )
            assert result["status"] == "cancelled", result
        release_deadline = time.monotonic() + 8
        cleanup_records = [
            milestones.wait_model_cleanup(processing, release_deadline)
            for processing in processings
        ]
        wait_execution_release(
            milestones, store, sessions[0], release_deadline, peers=peers,
        )
        if sample_host is not None:
            resource_samples["physically_released"] = sample_host(
                process.pid, "physically_released"
            )
        cleanup_by_operation = {
            record["operation"]: record for record in cleanup_records
        }
        physical_release_ms = []
        for index, processing in enumerate(processings):
            timing = timing_by_key[f"contention-stop-{index}"]
            cleanup = cleanup_by_operation[processing["operation"]]
            physical_release_ms.append(
                (
                    int(cleanup["at_ns"])
                    - int(timing["store_complete_at_ns"])
                )
                / 1_000_000
            )
        return {
            "acknowledgment_ms": [latency for _, latency in results],
            "control_timings": timings,
            "physical_release_ms": physical_release_ms,
            "resource_samples": resource_samples,
        }
    finally:
        stop_control_case(
            process, milestones, endpoint, endpoint_thread,
            inspection_gate.release, settlement_gate.release,
            connections=inspections,
        )
        if milestones is not None and sys.exc_info()[1] is None:
            milestones.assert_model_cleanup_census(*processings)
            peers.finish(time.monotonic())


def prove_real_settlement_contention(
    state, *, sample_host=None, large_answer_bytes=100_000
):
    store = state / "real-settlement-contention-store"
    store.mkdir(mode=0o700)
    endpoint, endpoint_thread = start_success_endpoint(
        large_answer_bytes=large_answer_bytes
    )
    process = None
    milestones = None
    inspections = []
    prepared_controls = []
    controls_start = threading.Event()
    blocked_results = []
    replacement_ordinary = []
    inspection_gate = ReleaseGate(state / "real-inspection-gate")
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        extra = [
            "--test-phase-trace",
            "--test-inspection-reply-gate-path",
            inspection_gate.path,
            "--test-client-send-buffer-bytes",
            "4096",
        ]
        process, fields = start_host(store, url, *extra, active_capacity=1, observations="control_peers")
        milestones = HostDiagnostics(process)
        peers = PeerCensus(milestones)
        resource_samples = {}
        if sample_host is not None:
            resource_samples["idle"] = sample_host(process.pid, "idle")

        session = peers.call("configure", lambda: configure(state, store, "real-settlement-config"))
        peers.call("message", lambda: message(
            state,
            store,
            "real-settlement-message",
            session,
            "large committed output",
        ))
        wait_for(lambda: endpoint.count() == 1, "large provider request")
        deadline = time.monotonic() + 8
        processing = wait_for(
            lambda: peers.call("observe", lambda: observe(store, "real-settlement-message", deadline=deadline),
                               deadline=deadline).get("processing"),
            "large-output processing identity", deadline=deadline,
        )
        inspections = fill_complete_inspections(
            fields["socket"], fields["store"], session, peers
        )
        milestones.wait(
            "inspection_captured",
            count=ORDINARY_CLIENTS,
            timeout=10,
            subject=session,
        )
        milestones.wait(
            "test_gate_waiting", count=ORDINARY_CLIENTS, timeout=10,
            subject=str(inspection_gate.path),
        )
        if sample_host is not None:
            resource_samples["reports_captured_before_settlement"] = sample_host(
                process.pid, "reports_captured_before_settlement"
            )

        control_requests = []
        for index in range(CONTROL_HEADROOM):
            if index == 0:
                route = "/v1/control/model-interruption"
                body = json.dumps(
                    {
                        "version": "4",
                        "kind": "model_interruption",
                        "store": fields["store"],
                        "key": "settlement-later-interrupt",
                        "target": {
                            "session": session,
                            "turn": processing["turn"],
                            "operation": processing["operation"],
                        },
                    },
                    separators=(",", ":"),
                ).encode()
            else:
                route = "/v1/control/session-stop"
                body = json.dumps(
                    {
                        "version": "4",
                        "kind": "session_stop",
                        "store": fields["store"],
                        "key": f"settlement-later-stop-{index}",
                        "session": session,
                    },
                    separators=(",", ":"),
                ).encode()
            deadline = time.monotonic() + 20
            control_requests.append(peers.expect("model_interruption" if index == 0 else "session_stop"))
            prepared_controls.append(
                prepare_raw_request(fields["socket"], route, body)
            )
            peers.started(control_requests[-1], deadline)
        assert_intake_progress(fields["socket"], store, peers)

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=CONTROL_HEADROOM
        ) as pool:
            futures = [
                pool.submit(
                    submit_prepared_request,
                    prepared_controls[index],
                    controls_start,
                )
                for index in range(CONTROL_HEADROOM)
            ]
            endpoint.release.set()
            settlement_lock = milestones.wait(
                "settlement_lock_acquired",
                operation=processing["operation"],
                timeout=15,
            )[0]
            control_deadline = time.monotonic() + 20
            controls_start.set()
            results = [future.result(timeout=20) for future in futures]
        prepared_controls.clear()
        for request in control_requests:
            peers.release(request, control_deadline)

        settlement_complete = milestones.wait(
            "settlement_complete",
            operation=processing["operation"],
            timeout=20,
        )[0]
        milestones.wait(
            "model_settlement_committed",
            operation=processing["operation"],
            timeout=20,
        )
        timings = milestones.wait(
            "control_timing", count=CONTROL_HEADROOM, timeout=20
        )
        overlap = [
            record
            for record in timings
            if int(record["store_queued_at_ns"])
            < int(settlement_complete["at_ns"])
            < int(record["lock_acquired_at_ns"])
        ]

        exact = results[0][0]
        assert exact["answer"]["status"] == "rejected", exact
        assert exact["answer"]["code"] == "operation_resolved", exact
        for reply, _ in results[1:]:
            assert reply["answer"]["status"] == "accepted", reply
            assert reply["answer"]["selection"]["turn"] is None, reply

        if sample_host is not None:
            resource_samples["controls_acknowledged"] = sample_host(
                process.pid, "controls_acknowledged"
            )
        inspection_deadline = time.monotonic() + 10
        inspection_gate.release()
        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
            responses = list(
                pool.map(
                    lambda connection: read_http_response(connection, 10, deadline=inspection_deadline),
                    inspections,
                )
            )
        for head, body in responses:
            assert b" 200 " in head, (head, body)
        peers.close(inspections, inspection_deadline)
        inspections.clear()

        deadline = time.monotonic() + 8
        message_result = wait_for(
            lambda: peers.call("observe", lambda: observe(store, "real-settlement-message", deadline=deadline),
                               deadline=deadline).get("result"),
            "committed large result", deadline=deadline,
        )
        assert message_result["status"] == "completed", message_result
        blocked_session = peers.call("configure", lambda: configure(
            state,
            store,
            "blocked-result-config",
        ))
        try:
            for _ in range(ORDINARY_CLIENTS):
                blocked_results.append(
                    peers.open("read_result", lambda: open_blocked_result(
                        fields["socket"],
                        fields["store"],
                        "real-settlement-message",
                    ), timeout=5)
                )
            peers.held(peers.borrowers.values())
            assert_intake_progress(fields["socket"], store, peers)
            if sample_host is not None:
                resource_samples["blocked_result_delivery"] = sample_host(
                    process.pid, "blocked_result_delivery"
                )
            blocked_control_started = time.monotonic_ns()
            blocked_control_request = peers.expect("session_stop")
            blocked_control = stop_session(
                state,
                store,
                "blocked-result-stop",
                blocked_session,
            )
            blocked_control_ms = (
                time.monotonic_ns() - blocked_control_started
            ) / 1_000_000
            assert blocked_control["answer"]["status"] == "accepted", blocked_control
            assert blocked_control_ms <= 1000, blocked_control_ms
            peers.release(blocked_control_request, blocked_control_started / 1e9 + 15)
            partial_result = blocked_results[0].recv(4096)
            assert partial_result.startswith(b"HTTP/1.1 200 "), partial_result
        except BaseException:
            for blocked_result in blocked_results:
                blocked_result.close()
            raise
        peers.close(blocked_results, time.monotonic() + 3)
        blocked_results.clear()
        replacement_ordinary = open_held_population(fields["socket"], peers)
        assert_intake_progress(fields["socket"], store, peers)
        peers.close(replacement_ordinary, time.monotonic() + 3)
        replacement_ordinary.clear()
        size, digest = peers.call("read_result", lambda: result_digest(
            store,
            "real-settlement-message",
            state / "real-settlement-answer.txt",
        ), timeout=30)
        assert size == large_answer_bytes, size
        assert digest == repeated_byte_digest(b"x", large_answer_bytes), digest
        post_disconnect_execution = peers.call("inspect", lambda: inspect_execution(
            store,
            session,
            timeout=10,
        ), timeout=10)
        assert post_disconnect_execution["dispatch_fenced"] is False

        cleanup = milestones.wait(
            "cleanup_completed",
            operation=processing["operation"],
            timeout=20,
        )[0]
        if sample_host is not None:
            resource_samples["physically_released"] = sample_host(
                process.pid, "physically_released"
            )
        return {
            "large_answer_bytes": large_answer_bytes,
            "large_answer_sha256": digest,
            "blocked_result_clients": ORDINARY_CLIENTS,
            "blocked_result_partial_bytes": len(partial_result),
            "blocked_result_control_acknowledgment_ms": blocked_control_ms,
            "blocked_result_clean_reread": True,
            "post_disconnect_dispatch_fenced": post_disconnect_execution[
                "dispatch_fenced"
            ],
            "acknowledgment_ms": [latency for _, latency in results],
            "control_timings": timings,
            "overlapping_control_keys": [
                record["command_key"] for record in overlap
            ],
            "settlement_lock_acquired_at_ns": int(settlement_lock["at_ns"]),
            "settlement_complete_at_ns": int(settlement_complete["at_ns"]),
            "settlement_service_ms": (
                int(settlement_complete["at_ns"])
                - int(settlement_lock["at_ns"])
            )
            / 1_000_000,
            "physical_release_ms": (
                int(cleanup["at_ns"])
                - int(settlement_complete["at_ns"])
            )
            / 1_000_000,
            "resource_samples": resource_samples,
            "resolved_interruption_key": "settlement-later-interrupt",
            "idle_stop_keys": [
                f"settlement-later-stop-{index}"
                for index in range(1, CONTROL_HEADROOM)
            ],
        }
    finally:
        controls_start.set()
        for connection, _ in prepared_controls:
            connection.close()
        for blocked_result in blocked_results:
            blocked_result.close()
        for connection in replacement_ordinary:
            connection.close()
        for connection in inspections:
            connection.close()
        if process is not None:
            stop_process(process)
        inspection_gate.release()
        if milestones is not None:
            milestones.close()
        stop_success_endpoint(endpoint, endpoint_thread)
        if milestones is not None and sys.exc_info()[1] is None:
            peers.finish(time.monotonic())


def prove_idle_stop_wire_recovery(state):
    store = state / "queued-stop-reuse-store"
    process = None
    try:
        # Store tests own replay after newer work. This native witness owns the
        # lost-reply record and nullable idle selection across a Host restart.
        process, _ = start_host(store)
        target_session = configure(state, store, "queued-stop-target-config")
        message(
            state,
            store,
            "queued-stop-excluded-message",
            target_session,
            "must remain excluded",
        )
        queued = observe(store, "queued-stop-excluded-message")
        assert queued["queue"]["status"] == "queued", queued

        record = state / "queued-stop-original.json"
        dropped = subprocess.run(
            [
                str(RUI),
                "session", "stop",
                "--store",
                str(store),
                "--record",
                str(record),
                "--key",
                "queued-stop-original",
                "--session",
                target_session,
                "--test-drop-reply",
                "after-commit",
            ],
            text=True,
            capture_output=True,
            timeout=15,
        )
        assert dropped.returncode != 0, dropped
        excluded = observe(store, "queued-stop-excluded-message")
        assert excluded["queue"]["status"] == "excluded", excluded
        assert excluded["result"] == {
            "status": "cancelled",
            "code": "session_stopped",
        }, excluded
        assert "processing" not in excluded, excluded

        replayed = command(
            "request", "recover",
            "--store",
            store,
            "--record",
            record,
            "--kind",
            "session-stop",
        )
        assert replayed["answer"]["status"] == "accepted", replayed
        assert replayed["answer"]["replayed"] is True, replayed
        assert replayed["answer"]["selection"] == {
            "turn": None,
            "admission_cutoff": excluded["queue"]["admission"],
        }, replayed
        assert observe(store, "queued-stop-excluded-message") == excluded

        stop_process(process)
        process = None
        process, _ = start_host(store)
        restarted = command(
            "request", "recover",
            "--store",
            store,
            "--record",
            record,
            "--kind",
            "session-stop",
        )
        assert restarted["answer"] == replayed["answer"], restarted
        assert observe(store, "queued-stop-excluded-message") == excluded
    finally:
        if process is not None:
            stop_process(process)


def prove_retry_wait_control(state, kind):
    retry_wait_ms = 2500
    endpoint = RetryWaitEndpoint(kind)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    store = state / f"retry-wait-{kind}-store"
    process = None
    milestones = None
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        retry_waits = f"{retry_wait_ms},{retry_wait_ms},{retry_wait_ms}"
        process, _ = start_host(
            store,
            url,
            "--test-retry-waits-ms",
            retry_waits,
            "--test-suppress-first-control-hint",
            "--test-phase-trace",
            active_capacity=1,
        )
        milestones = HostDiagnostics(process)
        session = configure(state, store, f"retry-wait-{kind}-config")
        message(state, store, f"retry-wait-{kind}-message", session, "retry then control")
        wait_for(lambda: endpoint.count() == 1, f"{kind} temporary provider response")

        def retry_wait_observation():
            observation = observe(store, f"retry-wait-{kind}-message")
            execution = command(
                "session", "inspect", "--store", store, "--session", session
            )["execution"]
            if (
                observation.get("processing", {}).get("attempt") == "1"
                and "result" not in observation
                and execution["custody_occupied"] == "0"
                and execution["dispatch_fenced"] is False
            ):
                return observation, time.monotonic()
            return None

        waiting, observed_at = wait_for(
            retry_wait_observation, f"{kind} committed retry wait"
        )
        processing = waiting["processing"]
        control_key = f"retry-wait-{kind}-control"
        record = state / f"{control_key}.json"
        args = [
            str(RUI),
            "session",
            "stop" if kind == "stop" else "interrupt-model",
            "--store",
            str(store),
            "--record",
            str(record),
            "--key",
            control_key,
            "--session",
            session,
        ]
        retry_kind = "session-stop" if kind == "stop" else "model-interruption"
        if kind == "interruption":
            args += [
                "--turn",
                processing["turn"],
                "--operation",
                processing["operation"],
            ]
        args += ["--test-drop-reply", "after-commit"]
        dropped = subprocess.run(args, text=True, capture_output=True, timeout=15)
        assert dropped.returncode != 0, dropped
        milestones.wait("control_hint_suppressed", subject=control_key)
        stop_process(process)
        process = None
        milestones.close()
        milestones = None

        process, _ = start_host(
            store,
            url,
            "--test-retry-waits-ms",
            retry_waits,
            active_capacity=1,
        )
        replayed = command(
            "request", "recover",
            "--store",
            store,
            "--record",
            record,
            "--kind",
            retry_kind,
        )
        assert replayed["answer"]["status"] == "accepted", replayed
        assert replayed["answer"]["replayed"] is True, replayed
        if kind == "stop":
            assert replayed["answer"]["selection"]["turn"] == processing["turn"], replayed
        else:
            assert replayed["answer"]["target"] == {
                "session": session,
                "turn": processing["turn"],
                "operation": processing["operation"],
            }, replayed

        cancelled = observe(store, f"retry-wait-{kind}-message")
        assert cancelled["result"]["status"] == "cancelled", cancelled
        unreadable = subprocess.run(
            [
                str(RUI),
                "request", "read-result",
                "--store",
                str(store),
                "--key",
                f"retry-wait-{kind}-message",
            ],
            capture_output=True,
            timeout=15,
        )
        assert unreadable.returncode != 0, unreadable

        deadline = observed_at + retry_wait_ms / 1000 + 1.25
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        assert endpoint.count() == 1, endpoint.count()
        assert observe(store, f"retry-wait-{kind}-message") == cancelled

        stop_process(process)
        process = None
        database = sqlite3.connect(store / "rui.sqlite3")
        try:
            assert database.execute(
                "SELECT attempt_ordinal FROM model_operation ORDER BY operation_id LIMIT 1"
            ).fetchall() == [(1,)]
            assert database.execute(
                "SELECT count(*) FROM model_output_item WHERE operation_id=(SELECT min(operation_id) FROM model_operation)"
            ).fetchone()[0] == 0
        finally:
            database.close()
    finally:
        if process is not None:
            stop_process(process)
        if milestones is not None:
            milestones.close()
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)


def prove_partial_setup_cleanup():
    from unittest.mock import Mock, patch

    for complete_headers in (False, True):
        for stage in (None, "settimeout", "connect", "sendall", "broken-pipe", "reset", "not-connected"):
            connection = Mock()
            if stage is not None:
                failure = (
                    BrokenPipeError("setup failed") if stage == "broken-pipe" else
                    OSError(errno.ENOTCONN, "setup failed") if stage == "not-connected" else
                    ConnectionResetError("setup failed") if stage == "reset" else TimeoutError("setup failed")
                )
                getattr(connection, "sendall" if stage in ("broken-pipe", "reset", "not-connected") else stage).side_effect = failure
            with patch.object(socket, "socket", return_value=connection):
                try:
                    candidate = open_partial("unused", "/v1/inspect-session", complete_headers=complete_headers)
                except OSError as error:
                    assert stage is not None and error is failure
                    connection.close.assert_called_once()
                else:
                    assert stage is None and candidate is connection
                    assert connection.sendall.call_count == (2 if complete_headers else 1)
                    connection.settimeout.assert_called_once_with(3)
                    connection.close.assert_not_called()

    # The native population cases require each exact classification and release;
    # silence and repeated saturation attempts no longer establish membership.
    print("Partial callers: both write failures and setup cleanup passed; native census owns membership")


def main():
    from host_process_test import prove_control_disposal_oracle
    prove_partial_setup_cleanup()
    prove_control_disposal_oracle(stop_control_case)
    state = canonical_fixture_root(tempfile.mkdtemp(prefix="rui-control-integration-"))
    store = state / "store"
    store.mkdir(mode=0o700)
    endpoint = StreamingEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    process = None
    completed = False
    held = []
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        process, fields = start_host(store, url)
        socket_path = fields["socket"]

        exact_session = configure(state, store, "exact-config")
        message(state, store, "exact-message", exact_session, "first")
        wait_for(lambda: endpoint.counts()[0] >= 1, "first provider request")
        processing = wait_for(
            lambda: observe(store, "exact-message").get("processing"),
            "exact target",
        )
        exact_record = state / "exact-interrupt.json"
        dropped_exact = subprocess.run(
            [
                str(RUI),
                "session", "interrupt-model",
                "--store",
                str(store),
                "--record",
                str(exact_record),
                "--key",
                "exact-interrupt",
                "--session",
                exact_session,
                "--turn",
                processing["turn"],
                "--operation",
                processing["operation"],
                "--test-drop-reply",
                "after-commit",
            ],
            text=True,
            capture_output=True,
            timeout=15,
        )
        assert dropped_exact.returncode != 0, dropped_exact
        wait_for(
            lambda: endpoint.counts()[1] >= 1,
            "exact transport cancellation before acknowledgment replay",
        )
        exact_message = observe(store, "exact-message")
        assert exact_message["result"]["status"] == "cancelled", exact_message
        started = time.monotonic()
        exact = command(
            "request", "recover",
            "--store",
            store,
            "--record",
            exact_record,
            "--kind",
            "model-interruption",
        )
        exact_latency_ms = (time.monotonic() - started) * 1000
        assert exact["answer"]["status"] == "accepted", exact
        assert exact["answer"]["replayed"] is True, exact
        assert exact_latency_ms < 1000, exact_latency_ms

        stop_target = configure(state, store, "stop-config")
        message(state, store, "stop-message", stop_target, "second")
        wait_for(lambda: endpoint.counts()[0] >= 2, "second provider request")
        stop_processing = wait_for(
            lambda: observe(store, "stop-message").get("processing"),
            "stop target",
        )
        message(state, store, "stop-later-message", stop_target, "later queued input")
        later_queued = observe(store, "stop-later-message")
        assert later_queued["queue"]["status"] == "queued", later_queued
        active_stop = stop_session(state, store, "active-stop", stop_target)
        assert active_stop["answer"]["status"] == "accepted", active_stop
        assert active_stop["answer"]["selection"]["turn"] == stop_processing["turn"]
        wait_for(lambda: endpoint.counts()[1] >= 2, "stop transport cancellation")
        stopped_message = observe(store, "stop-message")
        assert stopped_message["result"]["status"] == "cancelled", stopped_message
        excluded_later = observe(store, "stop-later-message")
        assert excluded_later["queue"]["status"] == "excluded", excluded_later
        assert excluded_later["result"] == {
            "status": "cancelled",
            "code": "session_stopped",
        }, excluded_later
        assert endpoint.counts()[0] == 2

        headroom_session = configure(state, store, "headroom-config")
        lost_stop_record = state / "lost-stop.json"
        dropped_stop = subprocess.run(
            [
                str(RUI),
                "session", "stop",
                "--store",
                str(store),
                "--record",
                str(lost_stop_record),
                "--key",
                "lost-stop",
                "--session",
                headroom_session,
                "--test-drop-reply",
                "after-commit",
            ],
            text=True,
            capture_output=True,
            timeout=15,
        )
        assert dropped_stop.returncode != 0, dropped_stop
        recovered_stop = command(
            "request", "recover",
            "--store",
            store,
            "--record",
            lost_stop_record,
            "--kind",
            "session-stop",
        )
        assert recovered_stop["answer"]["status"] == "accepted", recovered_stop
        assert recovered_stop["answer"]["replayed"] is True, recovered_stop
        assert recovered_stop["answer"]["selection"]["turn"] is None, recovered_stop
        # The intake witness owns a separate bounded native census. Earlier
        # cancellation/replay traffic is not an uncounted admission baseline.
        stop_process(process)
        process, fields = start_host(store, observations="control_peers")
        milestones = HostDiagnostics(process)
        peers = PeerCensus(milestones)
        socket_path = fields["socket"]
        held = open_held_population(socket_path, peers)
        assert_intake_progress(socket_path, store, peers)

        latencies = []
        for index in range(25):
            started = time.monotonic()
            request = peers.expect("session_stop")
            reply = stop_session(
                state,
                store,
                f"headroom-stop-{index}",
                headroom_session,
            )
            latencies.append((time.monotonic() - started) * 1000)
            assert reply["answer"]["status"] == "accepted", reply
            peers.release(request, started + 15)
        p95_ms = statistics.quantiles(latencies, n=20)[18]
        assert p95_ms < 1000, p95_ms

        peers.close(held, time.monotonic() + 3)
        held.clear()

        classification = [
            open_partial(socket_path, "/v1/control/session-stop", complete_headers=False)
            for _ in range(CONTROL_HEADROOM + 1)
        ]
        assert_intake_progress(socket_path, store, peers)
        assert not select.select(classification, [], [], 0)[0], "incomplete headers were refused"
        for connection in classification:
            peers.release_place("classification", connection.close)

        for kind, route, limit in (
            ("session_stop", "/v1/control/session-stop", MAX_SESSION_STOP_REQUEST_BYTES),
            (
                "model_interruption",
                "/v1/control/model-interruption",
                MAX_MODEL_INTERRUPTION_REQUEST_BYTES,
            ),
        ):
            body = maximum_body(kind)
            max_head, max_response = peers.call(kind, lambda: raw_request(socket_path, route, body), timeout=5)
            assert b" 409 " in max_head, (kind, max_head, max_response)
            assert b"wrong_store_identity" in max_response, (kind, max_response)
            oversized_head, oversized_response = peers.call(kind, lambda: raw_request(
                socket_path, route, b"", declared_length=limit + 1
            ), timeout=5)
            assert b" 400 " in oversized_head, (kind, oversized_head)
            assert b"control_request_too_large" in oversized_response, (
                kind,
                oversized_response,
            )

        stop_process(process)
        process = None
        peers.finish(time.monotonic())
        check_schema(store / "rui.sqlite3")

        process, _ = start_host(store)
        replay_stop = command(
            "request", "recover",
            "--store",
            store,
            "--record",
            state / "active-stop.json",
            "--kind",
            "session-stop",
        )
        assert replay_stop["answer"]["status"] == "accepted", replay_stop
        assert replay_stop["answer"]["replayed"] is True, replay_stop
        replay_interrupt = command(
            "request", "recover",
            "--store",
            store,
            "--record",
            state / "exact-interrupt.json",
            "--kind",
            "model-interruption",
        )
        assert replay_interrupt["answer"]["status"] == "accepted", replay_interrupt
        assert replay_interrupt["answer"]["replayed"] is True, replay_interrupt
        stop_process(process)
        process = None

        process, _ = start_host(store, None, "--fault", "content-acquire")
        no_scratch = stop_session(
            state, store, "no-scratch-stop", headroom_session
        )
        assert no_scratch["answer"]["status"] == "accepted", no_scratch
        stop_process(process)
        process = None

        prove_pre_handoff_stop(state)
        prove_sealed_interruption_and_cleanup(state)
        prove_idle_stop_wire_recovery(state)
        prove_retry_wait_control(state, "stop")
        prove_retry_wait_control(state, "interruption")
        control_first = prove_delivery_and_settlement_contention(state)
        control_first_p95_ms = percentile_95(
            control_first["acknowledgment_ms"]
        )
        settlement = prove_real_settlement_contention(state)
        settlement_p95_ms = percentile_95(settlement["acknowledgment_ms"])
        completed = True
        print(
            "control integration: "
            f"stalled_ingress={ORDINARY_CLIENTS} controls=25 p95_ms={p95_ms:.1f} "
            f"control_first_p95_ms={control_first_p95_ms:.1f} "
            f"real_settlement_p95_ms={settlement_p95_ms:.1f} "
            f"overlap_controls={len(settlement['overlapping_control_keys'])} "
            f"blocked_result_control_ms={settlement['blocked_result_control_acknowledgment_ms']:.1f} "
            f"exact_ack_ms={exact_latency_ms:.1f}"
        )
    finally:
        for connection in held:
            connection.close()
        if process is not None:
            stop_process(process)
        endpoint.release.set()
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        if completed:
            shutil.rmtree(state)
        else:
            retain_failure_state("control integration failure state", state)


if __name__ == "__main__":
    host_process.enter()
    main()
