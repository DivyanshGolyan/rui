#!/usr/bin/env python3
"""Deterministic Session-stop and exact model-interruption integration proof."""

import http.server
import concurrent.futures
import json
import pathlib
import shutil
import socket
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import threading
import time

from host_process import start_ready_process, stop_process


LATIFA = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()
MAX_CLIENTS = 128
ORDINARY_CLIENTS = 120
CONTROL_HEADROOM = MAX_CLIENTS - ORDINARY_CLIENTS
MAX_STORE_BYTES = 4096
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


def successful_sse(index):
    message_item = {
        "type": "message",
        "id": f"message-{index}",
        "status": "completed",
        "role": "assistant",
        "phase": "final_answer",
        "content": [
            {"type": "output_text", "text": f"answer-{index}", "annotations": []}
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

    def __init__(self):
        super().__init__(("127.0.0.1", 0), SuccessfulHandler)
        self.condition = threading.Condition()
        self.requests = 0
        self.release = threading.Event()

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
        body = successful_sse(index)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("OpenAI-Model", "model-a")
        self.send_header("X-Request-Id", f"request-{index}")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


class MilestoneLog:
    def __init__(self, process):
        self.process = process
        self.condition = threading.Condition()
        self.records = []
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        for raw_line in self.process.stderr:
            try:
                record = json.loads(raw_line)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if "latifa_test_phase" not in record:
                continue
            with self.condition:
                self.records.append(record)
                self.condition.notify_all()

    def matching(self, phase, **fields):
        with self.condition:
            return [
                record
                for record in self.records
                if record["latifa_test_phase"] == phase
                and all(record.get(name) == value for name, value in fields.items())
            ]

    def wait(self, phase, count=1, timeout=10, **fields):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                matches = [
                    record
                    for record in self.records
                    if record["latifa_test_phase"] == phase
                    and all(
                        record.get(name) == value for name, value in fields.items()
                    )
                ]
                if len(matches) >= count:
                    return matches
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(
                        f"timed out waiting for {count} {phase} milestones: "
                        f"{self.records[-12:]}"
                    )
                self.condition.wait(remaining)

    def close(self):
        self.thread.join(timeout=3)


def command(*args, expect=0):
    completed = subprocess.run(
        [str(LATIFA), *map(str, args)],
        text=True,
        capture_output=True,
        timeout=15,
    )
    if completed.returncode != expect:
        raise AssertionError(
            f"command returned {completed.returncode}, wanted {expect}: {args}\n"
            f"stdout: {completed.stdout}\nstderr: {completed.stderr}"
        )
    return json.loads(completed.stdout)


def start_host(store, endpoint=None, *extra, active_capacity=2):
    args = [
        str(LATIFA),
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
            b"X-Latifa-Wire-Version: 1\r\n\r\n{"
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
            + b"X-Latifa-Wire-Version: 1\r\n\r\n"
            + body
        )
        return read_http_response(connection)
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
        + b"X-Latifa-Wire-Version: 1\r\n\r\n"
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


def inspect_execution(store, session):
    return command(
        "inspect-session", "--store", store, "--session", session
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
        assert database.execute("PRAGMA user_version").fetchone()[0] == 9
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


def assert_ordinary_capacity_busy(socket_path):
    extra = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        extra.settimeout(3)
        extra.connect(socket_path)
        extra.sendall(b"POST /v1/inspect-session HTTP/1.1\r\n")
        extra_head, extra_body = read_http_response(extra)
        assert b" 503 " in extra_head, extra_head
        assert b"ordinary_capacity_exhausted" in extra_body, extra_body
    finally:
        extra.close()


def start_success_endpoint():
    endpoint = SuccessfulEndpoint()
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
                str(LATIFA),
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
        process, fields = start_host(store, url, *extra, active_capacity=8)
        milestones = MilestoneLog(process)
        resource_samples = {}
        if sample_host is not None:
            resource_samples["idle"] = sample_host(process.pid)
        sessions = [f"contention/{index}" for index in range(8)]
        for index, session in enumerate(sessions):
            configure(state, store, f"contention-config-{index}", session)
            message(
                state,
                store,
                f"contention-message-{index}",
                session,
                f"contention {index}",
            )
        wait_for(lambda: endpoint.count() == 8, "eight held successful responses")
        processings = [
            wait_for(
                lambda index=index: observe(
                    store, f"contention-message-{index}"
                ).get("processing"),
                f"contention processing identity {index}",
            )
            for index in range(8)
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
                process.pid
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
            futures = [pool.submit(run_stop, index) for index in range(8)]
            barrier.wait()
            results = [future.result(timeout=10) for future in futures]
        for reply, _ in results:
            assert reply["answer"]["status"] == "accepted", reply
        timings = milestones.wait("control_timing", count=8, timeout=8)
        assert len({record["command_key"] for record in timings}) == 8
        milestones.wait("model_settlement_superseded", timeout=8)
        if sample_host is not None:
            resource_samples["controls_acknowledged"] = sample_host(process.pid)

        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
            responses = list(
                pool.map(lambda connection: read_http_response(connection, 12), inspections)
            )
        for head, body in responses:
            assert b" 200 " in head, (head, body)
        for connection in inspections:
            connection.close()
        inspections.clear()
        for index in range(8):
            result = wait_for(
                lambda index=index: observe(
                    store, f"contention-message-{index}"
                ).get("result"),
                f"contention result {index}",
            )
            assert result["status"] == "cancelled", result
        cleanup_records = milestones.wait("cleanup_completed", count=8, timeout=8)
        execution = inspect_execution(store, sessions[0])
        assert execution["dispatch_fenced"] is False, execution
        assert execution["custody_occupied"] == "0", execution
        if sample_host is not None:
            resource_samples["physically_released"] = sample_host(process.pid)
        timing_by_key = {record["command_key"]: record for record in timings}
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


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="latifa-control-integration-"))
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
                str(LATIFA),
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
        wait_for(lambda: endpoint.counts()[1] >= 1, "exact transport cancellation")
        exact_message = observe(store, "exact-message")
        assert exact_message["result"]["status"] == "cancelled", exact_message

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
                str(LATIFA),
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
            for _ in range(CONTROL_HEADROOM)
        ]
        ninth = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        ninth.settimeout(3)
        ninth.connect(socket_path)
        ninth_head, ninth_body = read_http_response(ninth)
        ninth.close()
        assert b" 503 " in ninth_head, ninth_head
        assert b"classification_capacity_exhausted" in ninth_body, ninth_body
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
        check_schema(store / "latifa.sqlite3")

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

        process, _ = start_host(store, None, "--fault", "scratch-acquire")
        no_scratch = stop_session(
            state, store, "no-scratch-stop", "direct/headroom"
        )
        assert no_scratch["answer"]["status"] == "accepted", no_scratch
        stop_process(process)
        process = None

        prove_pre_handoff_stop(state)
        prove_sealed_interruption_and_cleanup(state)
        contention = prove_delivery_and_settlement_contention(state)
        contention_ack = contention["acknowledgment_ms"]
        contention_p95_ms = percentile_95(contention_ack)
        completed = True
        print(
            "control integration: "
            f"stalled_ingress={ORDINARY_CLIENTS} controls=25 p95_ms={p95_ms:.1f} "
            f"delivery_contention={ORDINARY_CLIENTS} concurrent_controls=8 "
            f"contention_p95_ms={contention_p95_ms:.1f} "
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
