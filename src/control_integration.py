#!/usr/bin/env python3
"""Deterministic Session-stop and exact model-interruption integration proof."""

import http.server
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


def start_host(store, endpoint=None, *extra):
    args = [str(LATIFA), "serve", "--store", str(store), "--active-capacity", "2"]
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


def read_http_response(connection):
    connection.settimeout(3)
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
        started = time.monotonic()
        exact = interrupt_model(
            state, store, "exact-interrupt", "direct/exact", processing
        )
        exact_latency_ms = (time.monotonic() - started) * 1000
        assert exact["answer"]["status"] == "accepted", exact
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
                break
        else:
            raise AssertionError("ordinary admission never stabilized at capacity")

        extra = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        extra.settimeout(3)
        extra.connect(socket_path)
        extra.sendall(b"POST /v1/inspect-session HTTP/1.1\r\n")
        extra_head, extra_body = read_http_response(extra)
        extra.close()
        assert b" 503 " in extra_head, extra_head
        assert b"ordinary_capacity_exhausted" in extra_body, extra_body

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
        time.sleep(0.1)

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
        completed = True
        print(
            "control integration: "
            f"ordinary={ORDINARY_CLIENTS} controls=25 p95_ms={p95_ms:.1f} "
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
