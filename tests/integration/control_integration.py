#!/usr/bin/env python3
"""Deterministic Session-stop and exact model-interruption integration proof."""

import http.server
import concurrent.futures
import hashlib
import json
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

from host_process import MilestoneLog, start_ready_process, stop_process


RUI = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()
MAX_CLIENTS = 12
ORDINARY_CLIENTS = 10
CONTROL_HEADROOM = MAX_CLIENTS - ORDINARY_CLIENTS
MAX_STORE_BYTES = 492
MAX_KEY_BYTES = 128
MAX_SESSION_BYTES = 128


def maximum_json_string_bytes(length):
    return 2 + 6 * length


MAX_SESSION_STOP_REQUEST_BYTES = (
    len('{"version":"1","kind":"session_stop","store":')
    + maximum_json_string_bytes(MAX_STORE_BYTES)
    + len(',"key":')
    + maximum_json_string_bytes(MAX_KEY_BYTES)
    + len(',"session":')
    + maximum_json_string_bytes(MAX_SESSION_BYTES)
    + 1
)
MAX_MODEL_INTERRUPTION_REQUEST_BYTES = (
    len('{"version":"1","kind":"model_interruption","store":')
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


class StreamingEndpoint(http.server.ThreadingHTTPServer):
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
            except (BrokenPipeError, ConnectionResetError):
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
                    "model": "model-a",
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


class SuccessfulEndpoint(http.server.ThreadingHTTPServer):
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
        self.send_header("OpenAI-Model", "model-a")
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
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


class RetryWaitEndpoint(http.server.ThreadingHTTPServer):
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


def command(*args, expect=0, timeout=15):
    completed = subprocess.run(
        [str(RUI), *map(str, args)],
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"command returned {completed.returncode}, wanted {expect}: {args}\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )
    return json.loads(completed.stdout)


def start_host(store, endpoint=None, *extra, active_capacity=2):
    args = [
        str(RUI),
        "serve",
        "--store",
        str(store),
        "--active-capacity",
        str(active_capacity),
    ]
    required = {"execution": "unavailable"}
    if endpoint is not None:
        args += ["--provider-endpoint", endpoint]
        required = {"execution": "enabled", "curl": "8.22.0"}
    args += extra
    return start_ready_process(args, required_fields=required)


def configure(state, store, key, session):
    result = command(
        "configure",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
        "--workspace",
        ROOT,
        "--model",
        "model-a",
    )
    assert result["answer"]["status"] == "accepted", result


def message(state, store, key, session, text):
    text_path = state / f"{key}.txt"
    text_path.write_text(text)
    result = command(
        "message",
        "--store",
        store,
        "--record",
        state / f"{key}.json",
        "--key",
        key,
        "--session",
        session,
        "--text",
        text_path,
    )
    assert result["answer"]["status"] == "accepted", result


def stop_session(state, store, key, session):
    return command(
        "stop-session",
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
        "interrupt-model",
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


def observe(store, key):
    return command("observe-command", "--store", store, "--key", key)["observation"]


def wait_for(predicate, description, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.025)
    raise AssertionError(f"timed out waiting for {description}")


def percentile_95(values):
    ordered = sorted(values)
    return ordered[max(0, (95 * len(ordered) + 99) // 100 - 1)]


def read_http_response(connection, timeout=3):
    connection.settimeout(timeout)
    response = bytearray()
    while b"\r\n\r\n" not in response:
        chunk = connection.recv(4096)
        if not chunk:
            break
        response.extend(chunk)
    head, _, body = bytes(response).partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    while len(body) < length:
        chunk = connection.recv(4096)
        if not chunk:
            break
        body += chunk
    return head, body


def open_partial(socket_path, route, *, complete_headers=True):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(3)
    connection.connect(socket_path)
    connection.sendall(f"POST {route} HTTP/1.1\r\n".encode())
    if complete_headers:
        connection.sendall(
            b"Content-Type: application/json\r\n"
            b"Content-Length: 1024\r\n"
            b"X-Rui-Wire-Version: 1\r\n\r\n{"
        )
    return connection


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
            + b"X-Rui-Wire-Version: 1\r\n\r\n"
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
        + b"X-Rui-Wire-Version: 1\r\n\r\n"
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


def open_complete_inspection(socket_path, store, session):
    body = json.dumps(
        {
            "version": "1",
            "kind": "inspect_session",
            "store": str(store),
            "session": session,
        },
        separators=(",", ":"),
    ).encode()
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(15)
    connection.connect(socket_path)
    connection.sendall(
        b"POST /v1/inspect-session HTTP/1.1\r\n"
        b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
        + b"X-Rui-Wire-Version: 1\r\n\r\n"
        + body
    )
    return connection


def fill_complete_inspections(socket_path, store, session):
    held = []
    attempts = 0
    while len(held) < ORDINARY_CLIENTS and attempts < ORDINARY_CLIENTS * 5:
        attempts += 1
        try:
            candidate = open_complete_inspection(socket_path, store, session)
        except (BrokenPipeError, ConnectionResetError):
            time.sleep(0.01)
            continue
        time.sleep(0.01)
        candidate.settimeout(0.001)
        try:
            early = candidate.recv(1, socket.MSG_PEEK)
        except TimeoutError:
            candidate.settimeout(15)
            held.append(candidate)
            continue
        if early:
            head, body = read_http_response(candidate)
            assert b" 503 " in head, (head, body)
        candidate.close()
    if len(held) != ORDINARY_CLIENTS:
        for connection in held:
            connection.close()
        raise AssertionError(
            f"complete inspection admission stopped at {len(held)} after {attempts} attempts"
        )
    return held


def inspect_execution(store, session, *, timeout=15):
    return command(
        "inspect-session",
        "--store",
        store,
        "--session",
        session,
        timeout=timeout,
    )["execution"]


def retry(state, store, record_key, kind):
    return command(
        "retry",
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
                "read-result",
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
            "version": "1",
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
        + b"X-Rui-Wire-Version: 1\r\n"
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
            '{"version":"1","kind":"session_stop","store":"'
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
        '{"version":"1","kind":"model_interruption","store":"'
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
        assert database.execute("PRAGMA user_version").fetchone()[0] == 12
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
            "admission_cutoff",
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


def fill_ordinary_capacity(socket_path):
    held = []
    for _ in range(10):
        while len(held) < ORDINARY_CLIENTS:
            candidate = open_partial(socket_path, "/v1/inspect-session")
            time.sleep(0.05)
            candidate.settimeout(0.001)
            try:
                early = candidate.recv(1, socket.MSG_PEEK)
            except TimeoutError:
                candidate.settimeout(3)
                held.append(candidate)
            else:
                if early:
                    head, body = read_http_response(candidate)
                    assert b" 503 " in head, (head, body)
                candidate.close()
                time.sleep(0.05)
        # A final pause lets the last accepted request line transfer before
        # the sweep distinguishes blocked bodies from early busy replies.
        time.sleep(1)
        live = []
        for candidate in held:
            candidate.settimeout(0.001)
            try:
                early = candidate.recv(1, socket.MSG_PEEK)
            except TimeoutError:
                candidate.settimeout(3)
                live.append(candidate)
                continue
            if early:
                head, body = read_http_response(candidate)
                assert b" 503 " in head, (head, body)
            candidate.close()
        held = live
        if len(held) == ORDINARY_CLIENTS:
            return held
    for connection in held:
        connection.close()
    raise AssertionError("ordinary admission never stabilized at capacity")


def assert_ordinary_capacity_busy(
    socket_path, expected_code=b"ordinary_capacity_exhausted"
):
    extra = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        extra.settimeout(3)
        extra.connect(socket_path)
        extra.sendall(b"POST /v1/inspect-session HTTP/1.1\r\n")
        extra_head, extra_body = read_http_response(extra)
        assert b" 503 " in extra_head, extra_head
        assert expected_code in extra_body, extra_body
    finally:
        extra.close()


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
        )
        milestones = MilestoneLog(process)
        configure(state, store, "pre-handoff-config", "phase/pre-handoff")
        message(
            state,
            store,
            "pre-handoff-message",
            "phase/pre-handoff",
            "must never launch",
        )
        prepared = milestones.wait("prepared_before_handoff")[0]
        stopped = stop_session(
            state, store, "pre-handoff-stop", "phase/pre-handoff"
        )
        assert stopped["answer"]["status"] == "accepted", stopped
        milestones.wait(
            "control_hint_suppressed", subject="pre-handoff-stop"
        )
        semantic = observe(store, "pre-handoff-message")
        assert semantic["result"]["status"] == "cancelled", semantic
        replayed = retry(state, store, "pre-handoff-stop", "session-stop")
        assert replayed["answer"]["status"] == "accepted", replayed
        assert replayed["answer"]["replayed"] is True, replayed
        milestones.wait("control_hint_published", subject="pre-handoff-stop")
        milestones.wait(
            "canonical_handoff_superseded",
            operation=prepared["operation"],
            timeout=8,
        )
        assert endpoint.count() == 0, endpoint.count()
        execution = inspect_execution(store, "phase/pre-handoff")
        assert execution["dispatch_fenced"] is False, execution
        assert execution["custody_occupied"] == "0", execution
        assert not milestones.matching(
            "transport_handoff_committed", operation=prepared["operation"]
        )
    finally:
        if process is not None:
            stop_process(process)
        if milestones is not None:
            milestones.close()
        stop_success_endpoint(endpoint, endpoint_thread)


def prove_sealed_interruption_and_cleanup(state):
    store = state / "sealed-store"
    store.mkdir(mode=0o700)
    endpoint, endpoint_thread = start_success_endpoint()
    process = None
    milestones = None
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        process, _ = start_host(
            store,
            url,
            "--test-phase-trace",
            "--test-before-result-delay-ms",
            "4000",
            "--test-cleanup-delay-ms",
            "1500",
            "--test-suppress-first-control-hint",
        )
        milestones = MilestoneLog(process)
        configure(state, store, "sealed-config", "phase/sealed")
        message(state, store, "sealed-message", "phase/sealed", "sealed race")
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
            "phase/sealed",
            processing,
        )
        assert interrupted["answer"]["status"] == "accepted", interrupted
        milestones.wait("control_hint_suppressed", subject="sealed-interrupt")
        semantic = observe(store, "sealed-message")
        assert semantic["result"]["status"] == "cancelled", semantic
        execution = inspect_execution(store, "phase/sealed")
        assert execution["custody_occupied"] == "1", execution

        replayed = retry(state, store, "sealed-interrupt", "model-interruption")
        assert replayed["answer"]["status"] == "accepted", replayed
        assert replayed["answer"]["replayed"] is True, replayed
        milestones.wait("control_hint_published", subject="sealed-interrupt")
        milestones.wait(
            "model_settlement_superseded", operation=processing["operation"]
        )
        milestones.wait("cleanup_started", operation=processing["operation"])
        during_cleanup = inspect_execution(store, "phase/sealed")
        assert during_cleanup["custody_occupied"] == "1", during_cleanup
        milestones.wait(
            "cleanup_completed", operation=processing["operation"], timeout=8
        )
        after_cleanup = inspect_execution(store, "phase/sealed")
        assert after_cleanup["custody_occupied"] == "0", after_cleanup
        assert after_cleanup["dispatch_fenced"] is False, after_cleanup
        assert len(
            milestones.matching("cleanup_started", operation=processing["operation"])
        ) == 1
        assert len(
            milestones.matching(
                "cleanup_completed", operation=processing["operation"]
            )
        ) == 1
        unavailable = subprocess.run(
            [
                str(RUI),
                "read-result",
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
    finally:
        if process is not None:
            stop_process(process)
        if milestones is not None:
            milestones.close()
        stop_success_endpoint(endpoint, endpoint_thread)


def prove_delivery_and_settlement_contention(
    state, *, sample_host=None, cleanup_delay_ms=0
):
    store = state / "contention-store"
    store.mkdir(mode=0o700)
    endpoint, endpoint_thread = start_success_endpoint()
    process = None
    milestones = None
    inspections = []
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        extra = [
            "--test-phase-trace",
            "--test-inspection-reply-delay-ms",
            "8000",
            "--test-before-result-delay-ms",
            "1200",
        ]
        if cleanup_delay_ms:
            extra += ["--test-cleanup-delay-ms", str(cleanup_delay_ms)]
        process, fields = start_host(store, url, *extra, active_capacity=CONTROL_HEADROOM)
        milestones = MilestoneLog(process)
        resource_samples = {}
        if sample_host is not None:
            resource_samples["idle"] = sample_host(process.pid, "idle")
        sessions = [f"contention/{index}" for index in range(CONTROL_HEADROOM)]
        for index, session in enumerate(sessions):
            configure(state, store, f"contention-config-{index}", session)
            message(
                state,
                store,
                f"contention-message-{index}",
                session,
                f"contention {index}",
            )
        wait_for(
            lambda: endpoint.count() == CONTROL_HEADROOM,
            "held successful responses for both control places",
        )
        processings = [
            wait_for(
                lambda index=index: observe(
                    store, f"contention-message-{index}"
                ).get("processing"),
                f"contention processing identity {index}",
            )
            for index in range(CONTROL_HEADROOM)
        ]

        inspections = fill_complete_inspections(
            fields["socket"], fields["store"], sessions[0]
        )
        milestones.wait(
            "inspection_captured",
            count=ORDINARY_CLIENTS,
            timeout=10,
            subject=sessions[0],
        )
        assert_ordinary_capacity_busy(fields["socket"])
        if sample_host is not None:
            resource_samples["reports_captured_and_responses_held"] = sample_host(
                process.pid, "reports_captured_and_responses_held"
            )

        endpoint.release.set()
        milestones.wait("sealed_before_settlement", timeout=8)
        barrier = threading.Barrier(CONTROL_HEADROOM + 1)

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
            futures = [
                pool.submit(run_stop, index) for index in range(CONTROL_HEADROOM)
            ]
            barrier.wait()
            results = [future.result(timeout=10) for future in futures]
        for reply, _ in results:
            assert reply["answer"]["status"] == "accepted", reply
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

        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
            responses = list(
                pool.map(lambda connection: read_http_response(connection, 12), inspections)
            )
        for head, body in responses:
            assert b" 200 " in head, (head, body)
        for connection in inspections:
            connection.close()
        inspections.clear()
        for index in range(CONTROL_HEADROOM):
            result = wait_for(
                lambda index=index: observe(
                    store, f"contention-message-{index}"
                ).get("result"),
                f"contention result {index}",
            )
            assert result["status"] == "cancelled", result
        cleanup_records = milestones.wait(
            "cleanup_completed", count=CONTROL_HEADROOM, timeout=8
        )
        execution = inspect_execution(store, sessions[0])
        assert execution["dispatch_fenced"] is False, execution
        assert execution["custody_occupied"] == "0", execution
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
        for connection in inspections:
            connection.close()
        if process is not None:
            stop_process(process)
        if milestones is not None:
            milestones.close()
        stop_success_endpoint(endpoint, endpoint_thread)


def prove_real_settlement_contention(
    state, *, sample_host=None, cleanup_delay_ms=0, large_answer_bytes=100_000
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
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        inspection_delay_ms = 20_000 if sample_host is not None else 8_000
        extra = [
            "--test-phase-trace",
            "--test-inspection-reply-delay-ms",
            str(inspection_delay_ms),
            "--test-client-send-buffer-bytes",
            "4096",
        ]
        if cleanup_delay_ms:
            extra += ["--test-cleanup-delay-ms", str(cleanup_delay_ms)]
        process, fields = start_host(store, url, *extra, active_capacity=1)
        milestones = MilestoneLog(process)
        resource_samples = {}
        if sample_host is not None:
            resource_samples["idle"] = sample_host(process.pid, "idle")

        session = "contention/real-settlement"
        configure(state, store, "real-settlement-config", session)
        message(
            state,
            store,
            "real-settlement-message",
            session,
            "large committed output",
        )
        wait_for(lambda: endpoint.count() == 1, "large provider request")
        processing = wait_for(
            lambda: observe(store, "real-settlement-message").get("processing"),
            "large-output processing identity",
        )
        inspections = fill_complete_inspections(
            fields["socket"], fields["store"], session
        )
        milestones.wait(
            "inspection_captured",
            count=ORDINARY_CLIENTS,
            timeout=10,
            subject=session,
        )
        if sample_host is not None:
            resource_samples["reports_captured_before_settlement"] = sample_host(
                process.pid, "reports_captured_before_settlement"
            )

        for index in range(CONTROL_HEADROOM):
            if index == 0:
                route = "/v1/control/model-interruption"
                body = json.dumps(
                    {
                        "version": "1",
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
                        "version": "1",
                        "kind": "session_stop",
                        "store": fields["store"],
                        "key": f"settlement-later-stop-{index}",
                        "session": session,
                    },
                    separators=(",", ":"),
                ).encode()
            prepared_controls.append(
                prepare_raw_request(fields["socket"], route, body)
            )
        assert_ordinary_capacity_busy(
            fields["socket"], b"connection_capacity_exhausted"
        )

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
            controls_start.set()
            results = [future.result(timeout=20) for future in futures]
        prepared_controls.clear()

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
        assert overlap, (
            "no control entered before real settlement completion and acquired "
            "the Store mutex afterward",
            settlement_lock,
            settlement_complete,
            timings,
        )

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
        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
            responses = list(
                pool.map(
                    lambda connection: read_http_response(
                        connection, inspection_delay_ms / 1000 + 5
                    ),
                    inspections,
                )
            )
        for head, body in responses:
            assert b" 200 " in head, (head, body)
        for connection in inspections:
            connection.close()
        inspections.clear()

        message_result = wait_for(
            lambda: observe(store, "real-settlement-message").get("result"),
            "committed large result",
        )
        assert message_result["status"] == "completed", message_result
        blocked_session = "contention/blocked-result-control"
        configure(
            state,
            store,
            "blocked-result-config",
            blocked_session,
        )
        try:
            for _ in range(ORDINARY_CLIENTS):
                blocked_results.append(
                    open_blocked_result(
                        fields["socket"],
                        fields["store"],
                        "real-settlement-message",
                    )
                )
            assert_ordinary_capacity_busy(fields["socket"])
            time.sleep(0.1)
            if sample_host is not None:
                resource_samples["blocked_result_delivery"] = sample_host(
                    process.pid, "blocked_result_delivery"
                )
            blocked_control_started = time.monotonic_ns()
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
            partial_result = blocked_results[0].recv(4096)
            assert partial_result.startswith(b"HTTP/1.1 200 "), partial_result
        finally:
            for blocked_result in blocked_results:
                blocked_result.close()
            blocked_results.clear()
        replacement_ordinary = fill_ordinary_capacity(fields["socket"])
        assert_ordinary_capacity_busy(fields["socket"])
        for connection in replacement_ordinary:
            connection.close()
        replacement_ordinary.clear()
        size, digest = result_digest(
            store,
            "real-settlement-message",
            state / "real-settlement-answer.txt",
        )
        assert size == large_answer_bytes, size
        assert digest == repeated_byte_digest(b"x", large_answer_bytes), digest
        post_disconnect_execution = inspect_execution(
            store,
            session,
            timeout=inspection_delay_ms / 1000 + 5,
        )
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
        if milestones is not None:
            milestones.close()
        stop_success_endpoint(endpoint, endpoint_thread)


def prove_queued_stop_reuse_after_newer_work(state):
    endpoint = StreamingEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    store = state / "queued-stop-reuse-store"
    blocker_session = "direct/queued-stop-blocker"
    target_session = "direct/queued-stop-target"
    process = None
    try:
        url = f"http://127.0.0.1:{endpoint.server_address[1]}/responses"
        process, _ = start_host(store, url, active_capacity=1)
        configure(state, store, "queued-stop-blocker-config", blocker_session)
        message(
            state,
            store,
            "queued-stop-blocker-message",
            blocker_session,
            "occupy capacity",
        )
        wait_for(lambda: endpoint.counts()[0] == 1, "queued-stop blocker request")

        configure(state, store, "queued-stop-target-config", target_session)
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
                "stop-session",
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

        blocker_stop = stop_session(
            state,
            store,
            "queued-stop-blocker-stop",
            blocker_session,
        )
        assert blocker_stop["answer"]["status"] == "accepted", blocker_stop
        wait_for(lambda: endpoint.counts()[1] == 1, "queued-stop blocker disconnect")
        wait_for(
            lambda: inspect_execution(store, blocker_session)["custody_occupied"]
            == "0",
            "queued-stop blocker cleanup",
        )
        assert endpoint.counts()[0] == 1

        message(
            state,
            store,
            "queued-stop-newer-message",
            target_session,
            "newer work",
        )
        newer = wait_for(
            lambda: observe(store, "queued-stop-newer-message").get("processing"),
            "newer work after queued stop",
        )
        wait_for(lambda: endpoint.counts()[0] == 2, "newer provider request")

        replayed = command(
            "retry",
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
        still_newer = observe(store, "queued-stop-newer-message")
        assert still_newer["processing"] == newer, still_newer
        assert "result" not in still_newer, still_newer
        assert observe(store, "queued-stop-excluded-message") == excluded

        fresh_stop = stop_session(
            state,
            store,
            "queued-stop-newer-stop",
            target_session,
        )
        assert fresh_stop["answer"]["status"] == "accepted", fresh_stop
        assert fresh_stop["answer"]["selection"]["turn"] == newer["turn"], fresh_stop
        wait_for(
            lambda: observe(store, "queued-stop-newer-message").get("result", {}).get(
                "status"
            )
            == "cancelled",
            "fresh stop of newer work",
        )

        stop_process(process)
        process = None
        process, _ = start_host(store)
        restarted = command(
            "retry",
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
        endpoint.release.set()
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)


def prove_retry_wait_control(state, kind):
    retry_wait_ms = 2500
    endpoint = RetryWaitEndpoint(kind)
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    store = state / f"retry-wait-{kind}-store"
    session = f"direct/retry-wait-{kind}"
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
        milestones = MilestoneLog(process)
        configure(state, store, f"retry-wait-{kind}-config", session)
        message(state, store, f"retry-wait-{kind}-message", session, "retry then control")
        wait_for(lambda: endpoint.count() == 1, f"{kind} temporary provider response")

        def retry_wait_observation():
            observation = observe(store, f"retry-wait-{kind}-message")
            execution = command(
                "inspect-session", "--store", store, "--session", session
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
            "stop-session" if kind == "stop" else "interrupt-model",
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
            "retry",
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
                "read-result",
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

        newer_key = f"retry-wait-{kind}-newer"
        message(state, store, newer_key, session, "newer work after recovered control")
        wait_for(lambda: endpoint.count() == 2, f"{kind} newer provider request")
        newer = wait_for(
            lambda: (
                value
                if (value := observe(store, newer_key)).get("result", {}).get(
                    "status"
                )
                == "completed"
                else None
            ),
            f"{kind} newer result",
        )
        replayed_after_newer = command(
            "retry",
            "--store",
            store,
            "--record",
            record,
            "--kind",
            retry_kind,
        )
        assert replayed_after_newer["answer"] == replayed["answer"], (
            replayed_after_newer,
            replayed,
        )
        assert observe(store, newer_key) == newer

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


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-control-integration-"))
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

        configure(state, store, "exact-config", "direct/exact")
        message(state, store, "exact-message", "direct/exact", "first")
        wait_for(lambda: endpoint.counts()[0] >= 1, "first provider request")
        processing = wait_for(
            lambda: observe(store, "exact-message").get("processing"),
            "exact target",
        )
        exact_record = state / "exact-interrupt.json"
        dropped_exact = subprocess.run(
            [
                str(RUI),
                "interrupt-model",
                "--store",
                str(store),
                "--record",
                str(exact_record),
                "--key",
                "exact-interrupt",
                "--session",
                "direct/exact",
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
            "retry",
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

        configure(state, store, "stop-config", "direct/stop")
        message(state, store, "stop-message", "direct/stop", "second")
        wait_for(lambda: endpoint.counts()[0] >= 2, "second provider request")
        stop_processing = wait_for(
            lambda: observe(store, "stop-message").get("processing"),
            "stop target",
        )
        active_stop = stop_session(state, store, "active-stop", "direct/stop")
        assert active_stop["answer"]["status"] == "accepted", active_stop
        assert active_stop["answer"]["selection"]["turn"] == stop_processing["turn"]
        wait_for(lambda: endpoint.counts()[1] >= 2, "stop transport cancellation")
        stopped_message = observe(store, "stop-message")
        assert stopped_message["result"]["status"] == "cancelled", stopped_message

        configure(state, store, "headroom-config", "direct/headroom")
        lost_stop_record = state / "lost-stop.json"
        dropped_stop = subprocess.run(
            [
                str(RUI),
                "stop-session",
                "--store",
                str(store),
                "--record",
                str(lost_stop_record),
                "--key",
                "lost-stop",
                "--session",
                "direct/headroom",
                "--test-drop-reply",
                "after-commit",
            ],
            text=True,
            capture_output=True,
            timeout=15,
        )
        assert dropped_stop.returncode != 0, dropped_stop
        recovered_stop = command(
            "retry",
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
        held = fill_ordinary_capacity(socket_path)
        assert_ordinary_capacity_busy(socket_path)

        latencies = []
        for index in range(25):
            started = time.monotonic()
            reply = stop_session(
                state,
                store,
                f"headroom-stop-{index}",
                "direct/headroom",
            )
            latencies.append((time.monotonic() - started) * 1000)
            assert reply["answer"]["status"] == "accepted", reply
        p95_ms = statistics.quantiles(latencies, n=20)[18]
        assert p95_ms < 1000, p95_ms

        for connection in held:
            connection.close()
        held.clear()
        time.sleep(1)

        classification = [
            open_partial(socket_path, "/v1/control/session-stop", complete_headers=False)
            for _ in range(CONTROL_HEADROOM + 1)
        ]
        readable, _, _ = select.select(classification, [], [], 3)
        assert readable, "classification overflow did not receive a response"
        overflow = readable[0]
        extra_head, extra_body = read_http_response(overflow)
        assert b" 503 " in extra_head, extra_head
        assert b"classification_capacity_exhausted" in extra_body, extra_body
        overflow.close()
        classification.remove(overflow)
        for connection in classification:
            connection.close()
        time.sleep(1)

        for kind, route, limit in (
            ("session_stop", "/v1/control/session-stop", MAX_SESSION_STOP_REQUEST_BYTES),
            (
                "model_interruption",
                "/v1/control/model-interruption",
                MAX_MODEL_INTERRUPTION_REQUEST_BYTES,
            ),
        ):
            body = maximum_body(kind)
            max_head, max_response = raw_request(socket_path, route, body)
            assert b" 409 " in max_head, (kind, max_head, max_response)
            assert b"wrong_store_identity" in max_response, (kind, max_response)
            oversized_head, oversized_response = raw_request(
                socket_path, route, b"", declared_length=limit + 1
            )
            assert b" 400 " in oversized_head, (kind, oversized_head)
            assert b"control_request_too_large" in oversized_response, (
                kind,
                oversized_response,
            )

        stop_process(process)
        process = None
        check_schema(store / "rui.sqlite3")

        process, _ = start_host(store)
        replay_stop = command(
            "retry",
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
            "retry",
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
            state, store, "no-scratch-stop", "direct/headroom"
        )
        assert no_scratch["answer"]["status"] == "accepted", no_scratch
        stop_process(process)
        process = None

        prove_pre_handoff_stop(state)
        prove_sealed_interruption_and_cleanup(state)
        prove_queued_stop_reuse_after_newer_work(state)
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
            print(f"retained control integration failure state: {state}", file=sys.stderr)


if __name__ == "__main__":
    main()
