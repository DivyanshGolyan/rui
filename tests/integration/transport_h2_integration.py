#!/usr/bin/env python3
"""Native owner/ALPN/stream witness; requires h2==4.3.0 and OpenSSL CLI."""
import http.server
import json
import os
import pathlib
import re
import socket
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time

import h2.config
import h2.connection
import h2.events
import h2.errors
import h2.settings

import control_integration as control
import model_fixture as dispatch
import host_process
from host_process import HostDiagnostics, TestHTTPServer, TRANSPORT_EXCHANGE_LIMIT, _failure_destination, preserve_failure_metadata, wait_for_execution_release as wait_for_drain
import os_semantics


class Endpoint(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, tls, population, refuse_at=None, dead_reuse=False, bad_header=False, drop_once=False, sse=False, isolation=None, after_progress=False, early_protocol_error=False, eager_sse=False, observed_shape=False, held=False):
        super().__init__(("127.0.0.1", 0), StreamHandler)
        self.tls = tls
        self.population = population
        self.connections = []
        self.streams = []
        self.request_headers = []
        self.refuse_at = refuse_at
        self.refused = False
        self.dead_reuse = dead_reuse
        self.bad_header = bad_header
        self.drop_once = drop_once
        self.dropped = False
        self.sse = sse
        self.after_progress = after_progress
        self.early_protocol_error = early_protocol_error
        self.eager_sse = eager_sse
        self.observed_shape = observed_shape
        self.answers = {}
        self.isolation = isolation
        self.stream_ids = {}
        self.resets = []
        self.offered_bytes = 0
        # Held: the peer sends each response's head and `held_bytes` of its
        # body, then withholds the rest until `release` is set.
        self.release = threading.Event() if held else None
        self.held_bytes = 0
        self.held_prefix_bytes = 0  # Body bytes sent before the hold, all streams.
        self.held_prefixes = {}  # The same, by request text.
        self.held = threading.Event()
        self.ready = threading.Event()
        self.lock = threading.Lock()

    def get_request(self):
        sock, address = super().get_request()
        return self.tls.wrap_socket(sock, server_side=True), address


class HeldEndpoint(TestHTTPServer):
    """Cleartext h2 peer that withholds the first response until released."""
    allow_reuse_address = True
    daemon_threads = True
    # Share DNS-free binding without changing this witness's polling cadence.
    serve_forever = http.server.ThreadingHTTPServer.serve_forever

    def __init__(self):
        super().__init__(("127.0.0.1", 0), HeldHandler)
        self.lock = threading.Lock()
        self.first_ready = threading.Event()
        self.release_first = threading.Event()
        self.requests = []
        self.connections = set()
        # Responses whose complete Content-Length body has not been sent,
        # not Python handler lifetimes or server-side socket retirement.
        self.active = 0
        self.maximum_active = 0


class HeldHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        assert self.path == "/responses"
        body = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(body)
        text = next(item["content"][0]["text"] for item in reversed(request["input"])
                    if item.get("role") == "user")
        with self.server.lock:
            self.server.requests.append((text, body))
            self.server.connections.add(self.client_address)
            self.server.active += 1
            self.server.maximum_active = max(self.server.maximum_active, self.server.active)
            first = len(self.server.requests) == 1
        retired = False
        try:
            payload, _, _ = dispatch.sse_answer(
                f"response-{text}", f"reasoning-{text}", f"message-{text}", f"answer-{text}",
            )
            if first:
                self.server.first_ready.set()
                assert self.server.release_first.wait(20), "first held response was never released"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload[:-1])
            # The client can complete the stream as soon as the final byte
            # arrives. Retire response accounting before another handler can
            # enter it, independently of this handler's remaining cleanup.
            with self.server.lock:
                self.wfile.write(payload[-1:])
                self.wfile.flush()
                self.server.active -= 1
                retired = True
            self.close_connection = True
        finally:
            if not retired:
                with self.server.lock:
                    self.server.active -= 1

    def log_message(self, *_):
        pass


def observed_shape_answer(text):
    return "x" * (48 * 32 - len(text)) + text


def observed_shape_sse(stream, text):
    # Mac Codex 0.154.0 HTTP SSE: small deltas, but response lifecycle data
    # measured 37–39 KiB. Padding is synthetic; no private payload is replayed.
    answer = observed_shape_answer(text)
    response_id = f"response-{stream}"
    body, _, _ = dispatch.sse_answer(response_id, f"reasoning-{stream}", f"message-{stream}", answer)
    events = [json.loads(record[6:]) for record in body.split(b"\n\n") if record.startswith(b"data: {")]

    def padded(event, container, field, size):
        container[field] = ""
        remaining = size - len(json.dumps(event, separators=(",", ":")).encode())
        assert remaining >= 0
        container[field] = "x" * remaining
        assert len(json.dumps(event, separators=(",", ":")).encode()) == size
        return event

    response = {"id": response_id, "status": "in_progress", "output": [], "metadata": {}}
    created = padded({"type": "response.created", "response": response}, response["metadata"], "synthetic_padding", 37_217)
    progress = {"type": "response.in_progress", "response": response}
    assert len(json.dumps(progress, separators=(",", ":")).encode()) == 37_221
    deltas = []
    for index in range(0, len(answer), 32):
        delta = {"type": "response.output_text.delta", "item_id": f"message-{stream}",
                 "output_index": 1, "content_index": 0, "delta": answer[index:index + 32]}
        deltas.append(padded(delta, delta, "obfuscation", 218))
    assert len(deltas) == 48
    completed = events[-1]
    completed["response"]["metadata"] = {}
    padded(completed, completed["response"]["metadata"], "synthetic_padding", 39_316)
    return dispatch.encode_sse([created, progress, *events[:3], *deltas, *events[3:]]), answer


def assert_observed_shape_work(payload):
    records = payload.split(b"\n\n")
    assert records[-2:] == [b"data: [DONE]", b""], "shape terminal framing"
    values = [record.removeprefix(b"data: ") for record in records[:-2]]
    events = [json.loads(value) for value in values]
    expected = ["response.created", "response.in_progress", "response.output_item.added",
                "response.output_item.done", "response.output_item.added"]
    expected += ["response.output_text.delta"] * 48
    expected += ["response.output_item.done", "response.completed"]
    assert [event["type"] for event in events] == expected, "shape per-stream event sequence"
    for index, size in [(0, 37_217), (1, 37_221), (54, 39_316)]:
        assert len(values[index]) == size, "shape lifecycle bytes"
    assert all(len(value) == 218 for value in values[5:53]), "shape delta bytes"


def host_physical_peak(pid):
    if not os_semantics.FOOTPRINT:
        return None
    report = subprocess.run(
        ["/usr/bin/footprint", "-f", "bytes", "-p", str(pid)],
        capture_output=True, text=True, check=True, timeout=30,
    ).stdout
    return int(re.search(r"^\s*phys_footprint_peak: (\d+) B$", report, re.M).group(1))


def open_descriptors(pid):
    if os.path.isdir(f"/proc/{pid}/fd"):
        return len(os.listdir(f"/proc/{pid}/fd"))
    rows = subprocess.check_output(["/usr/sbin/lsof", "-n", "-P", "-p", str(pid)],
                                   text=True).splitlines()
    return sum(bool(re.fullmatch(r"\d+[rwu]?", row.split()[3])) for row in rows[1:])


class StreamHandler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        assert sock.selected_alpn_protocol() == "h2"
        sock.settimeout(45)
        conn = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False))
        conn.initiate_connection()
        if self.server.refuse_at == "headers" and not self.server.refused:
            conn.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 0})
        sock.sendall(conn.data_to_send())
        bodies = {}
        pending = []
        outgoing_bodies = {}
        held_bodies = {}
        with self.server.lock:
            self.server.connections.append(self.client_address)
        while True:
            try:
                data = sock.recv(65536)
            except TimeoutError:
                if not held_bodies:
                    return
                data = None  # Polling for release.
            except OSError:
                return
            if data == b"":
                return
            if held_bodies and self.server.release.is_set():
                outgoing_bodies.update(held_bodies)
                held_bodies.clear()
                sock.settimeout(45)
            for event in conn.receive_data(data) if data else ():
                if isinstance(event, h2.events.RequestReceived):
                    assert event.stream_id not in bodies
                    with self.server.lock:
                        self.server.request_headers.append(dict(event.headers))
                        refuse = self.server.refuse_at == "headers" and not self.server.refused
                        if refuse:
                            self.server.refused = True
                            self.server.streams.append((self.client_address, event.stream_id, None, b""))
                    if refuse:
                        conn.reset_stream(event.stream_id, error_code=h2.errors.ErrorCodes.REFUSED_STREAM)
                        # Reopen upload credit so the replay can send its body.
                        conn.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 65535})
                        continue
                    bodies[event.stream_id] = bytearray()
                elif isinstance(event, h2.events.DataReceived):
                    if event.stream_id in bodies:
                        bodies[event.stream_id].extend(event.data)
                    conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, h2.events.StreamEnded):
                    if event.stream_id not in bodies:
                        continue
                    body = bytes(bodies.pop(event.stream_id))
                    request = json.loads(body)
                    text = next(
                        item["content"][0]["text"]
                        for item in reversed(request["input"])
                        if item.get("role") == "user"
                    )
                    with self.server.lock:
                        self.server.streams.append((self.client_address, event.stream_id, text, body))
                        self.server.stream_ids[text] = event.stream_id
                        if self.server.sse:
                            if self.server.observed_shape:
                                answer = observed_shape_answer(text)
                            elif self.server.after_progress and text == "held-0":
                                # The interrupt target exceeds the 10-KiB prefix the peer sends.
                                answer = "L" * 80_000 + text
                            else:
                                answer = f"answer-{text}" if len(self.server.streams) % 2 else "L" * 8192 + text
                            self.server.answers[text] = answer.encode()
                        refuse = self.server.refuse_at == "upload" and not self.server.refused
                        if refuse:
                            self.server.refused = True
                        dead = self.server.dead_reuse and len(self.server.streams) == 2
                    if dead:
                        return
                    if refuse:
                        conn.reset_stream(event.stream_id, error_code=h2.errors.ErrorCodes.REFUSED_STREAM)
                        continue
                    if self.server.early_protocol_error:
                        # DATA on stream zero is an H2 connection protocol error,
                        # after the POST but before any response version is known.
                        sock.sendall(b"\x00\x00\x01\x00\x00\x00\x00\x00\x00x")
                        return
                    if self.server.eager_sse:
                        payload, _, _ = dispatch.sse_answer(
                            f"response-{event.stream_id}", f"reasoning-{event.stream_id}",
                            f"message-{event.stream_id}", self.server.answers[text].decode(),
                        )
                        conn.send_headers(event.stream_id, [
                            (":status", "200"), ("content-type", "text/event-stream"),
                            ("content-length", str(len(payload))),
                        ])
                        outgoing_bodies[event.stream_id] = payload
                        if len(self.server.streams) == self.server.population:
                            self.server.ready.set()
                        continue
                    pending.append(event.stream_id)
                    if len(pending) == self.server.population:
                        self.server.ready.set()
                        with self.server.lock:
                            drop = self.server.drop_once and not self.server.dropped
                            if drop:
                                self.server.dropped = True
                        if drop:
                            return
                        if self.server.isolation:
                            target = self.server.stream_ids["isolation-target"]
                            sibling = self.server.stream_ids["isolation-sibling"]
                            conn.send_headers(target, [(":status", "200"), ("content-type", "text/event-stream")])
                            conn.send_headers(sibling, [(":status", "200"), ("content-type", "text/event-stream")])
                            if self.server.isolation == "capture":
                                # Cross the capture limit within initial H2 credit; the
                                # target stays open so its abort has an observable reset.
                                payload, _, _ = dispatch.sse_answer("large", "reasoning-large", "message-large", "L" * 40_000)
                                outgoing_bodies[target] = payload
                            pending.clear()
                            continue
                        for stream in pending:
                            if self.server.sse:
                                text = next(text for _, stream_id, text, _ in self.server.streams if stream_id == stream)
                                if self.server.observed_shape:
                                    payload, answer = observed_shape_sse(stream, text)
                                    assert answer.encode() == self.server.answers[text]
                                    assert_observed_shape_work(payload)
                                else:
                                    payload, _, _ = dispatch.sse_answer(
                                        f"response-{stream}", f"reasoning-{stream}",
                                        f"message-{stream}", self.server.answers[text].decode(),
                                    )
                                with self.server.lock:
                                    self.server.offered_bytes += len(payload)
                                conn.send_headers(stream, [
                                    (":status", "200"), ("content-type", "text/event-stream"),
                                    ("content-length", str(len(payload))),
                                ])
                                if self.server.release is not None and not self.server.release.is_set():
                                    sent = min(self.server.held_bytes, len(payload) - 1)
                                    with self.server.lock:
                                        self.server.held_prefix_bytes += sent
                                        self.server.held_prefixes[text] = sent
                                    outgoing_bodies[stream] = payload[:sent]
                                    held_bodies[stream] = payload[sent:]
                                    continue
                                outgoing_bodies[stream] = payload
                                continue
                            headers = [
                                (":status", "422"),
                                ("content-length", "3"),
                                ("x-request-id", f"fixture-{stream}"),
                            ]
                            if self.server.bad_header and stream == pending[0]:
                                headers.append(("x-request-id", "contradictory"))
                            conn.send_headers(stream, headers)
                            conn.send_data(stream, b"bad", end_stream=True)
                        pending.clear()
                elif isinstance(event, h2.events.StreamReset):
                    with self.server.lock:
                        self.server.resets.append(event.stream_id)
                    outgoing_bodies.pop(event.stream_id, None)
                    held_bodies.pop(event.stream_id, None)
                    if self.server.isolation and event.stream_id == self.server.stream_ids["isolation-target"]:
                        payload, _, _ = dispatch.sse_answer(
                            "sibling", "reasoning-sibling", "message-sibling", "unaffected sibling",
                        )
                        outgoing_bodies[self.server.stream_ids["isolation-sibling"]] = payload
            for stream, body in list(outgoing_bodies.items()):
                # A single frame per recv can deadlock: no peer event need
                # arrive while an incomplete response waits in this queue.
                while body:
                    credit = min(conn.local_flow_control_window(stream), conn.max_outbound_frame_size, len(body))
                    if not credit:
                        break
                    hold_target_open = stream in held_bodies or (
                        self.server.isolation == "capture" and
                        stream == self.server.stream_ids["isolation-target"])
                    conn.send_data(stream, body[:credit], end_stream=credit == len(body) and not hold_target_open)
                    body = body[credit:]
                if not body:
                    del outgoing_bodies[stream]
                else:
                    outgoing_bodies[stream] = body
            outgoing = conn.data_to_send()
            if outgoing:
                sock.sendall(outgoing)
            if self.server.isolation and not pending and len(self.server.stream_ids) == 2:
                self.server.ready.set()
            if held_bodies and not outgoing_bodies and not self.server.held.is_set():
                # Every held prefix is on the wire; poll for release.
                self.server.held.set()
                sock.settimeout(0.05)


def assert_round_trip_history(streams, capacity, rounds, answers):
    assert len(streams) == rounds * capacity, "history request population"
    assert {text for _, _, text, _ in streams} == {
        f"h2-{capacity}-{round_number}-{index}"
        for round_number in range(rounds) for index in range(capacity)
    }, "history request identities"
    requests = {text: (stream, body) for _, stream, text, body in streams}
    for index in range(capacity):
        expected = []
        for wave in range(rounds):
            text = f"h2-{capacity}-{wave}-{index}"
            stream, body = requests[text]
            expected.append({"role": "user", "content": [{"type": "input_text", "text": text}]})
            assert json.loads(body)["input"] == expected, f"complete request history for {text}"
            # Reconstruct fixture emissions, never expectations from Host input.
            _, reasoning, message = dispatch.sse_answer(
                f"response-{stream}", f"reasoning-{stream}", f"message-{stream}", answers[text].decode(),
            )
            del reasoning["created_by"]  # Response-only provenance is not replayed.
            expected.extend((reasoning, message))


def closed_host_request(socket_path, store, kind, *, timeout=15, deadline=None, **fields):
    if deadline is not None:
        deadline = min(deadline, time.monotonic() + timeout)
    payload = json.dumps({"version": "3", "kind": kind, "store": str(store.resolve()),
                          **fields}, separators=(",", ":")).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        def set_timeout():
            remaining = timeout if deadline is None else min(timeout, deadline - time.monotonic())
            assert remaining > 0, "Host request exhausted original deadline"
            connection.settimeout(remaining)

        set_timeout()
        connection.connect(socket_path)
        set_timeout()
        connection.sendall(
            f"POST /v1/{kind.replace('_', '-')} HTTP/1.1\r\n".encode()
            + b"Content-Type: application/json\r\nX-Rui-Wire-Version: 3\r\n"
            + f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload
        )
        head, body = control.read_http_response(connection, timeout=timeout, deadline=deadline)
        assert b" 200 " in head, (head, body)
        headers = dict(line.lower().split(b":", 1) for line in head.split(b"\r\n")[1:])
        assert len(body) == int(headers[b"content-length"]), "truncated Host response"
        expected_type = b"text/plain" if kind == "read_result" else b"application/json"
        assert headers[b"content-type"].strip().startswith(expected_type), head
        # EOF establishes peer closure, not retirement of reports or other
        # exchange resources. Idle sampling separately waits for native release.
        set_timeout()
        assert connection.recv(1) == b"", "Host must close after its response"
    result = body if kind == "read_result" else json.loads(body)
    assert deadline is None or time.monotonic() < deadline, "Host request exceeded original deadline"
    return result


class HostRequests:
    """Issue a bounded population; sample only after every native owner retires."""

    def __init__(self, host, socket_path, store):
        self.host, self.socket_path, self.store = host, socket_path, store
        self.diagnostics = HostDiagnostics(host)
        assert self.diagnostics.observations is not None and self.diagnostics.observations.plan == "transport", (
            "idle descriptors require native transport observation authority")
        self.routes = []

    def call(self, kind, **fields):
        assert len(self.routes) < TRANSPORT_EXCHANGE_LIMIT, "transport exhausted exchange population"
        self.routes.append({"observe_command": "observe", "inspect_session": "inspect"}.get(kind, kind))
        return closed_host_request(self.socket_path, self.store, kind, **fields)

    def idle_descriptors(self, deadline):
        self.diagnostics.borrower_census(deadline, self.routes)
        assert time.monotonic() < deadline, "exchange retirement exceeded original deadline"
        return open_descriptors(self.host.pid)


def round_trip(root, endpoint, capacity, ca_file, rounds=2, *, observe=None):
    assert 0 < capacity <= 100 and 0 < rounds <= 20, "transport workload exceeds observed population"
    store = root / f"store-{capacity}"
    host, ready = dispatch.start_ready_process(
        dispatch.host_arguments(
            store,
            f"https://localhost:{endpoint.server_address[1]}/responses",
            "--provider-ca-file",
            str(ca_file),
            active_capacity=capacity,
        ),
        required_fields={"execution": "enabled", "nghttp2": "1.70.0"},
        observations="transport",
    )
    try:
        requests = HostRequests(host, ready["socket"], store)
        idle_fds = []
        physical_peaks = []
        sessions = []
        if observe is not None:
            observe(host.pid, 0)
        for round_number in range(rounds):
            for index in range(capacity):
                if round_number == 0:
                    configured = requests.call(
                        "configure", key=f"config-{capacity}-{index}",
                        session="", configuration={
                            "workspace": {"state": "value", "value": str(dispatch.ROOT)},
                            "provider": {"state": "value", "value": "codex"},
                            "model": {"state": "value", "value": "gpt-6-sol"},
                            "instructions": {"state": "omitted"},
                            "tools": {"state": "value", "value": ["bash"]},
                            "permission_mode": {"state": "value", "value": "ask"},
                            "output_schema": {"state": "omitted"},
                        },
                    )
                    assert configured["answer"]["status"] == "accepted", configured
                    sessions.append(configured["answer"]["session"])
                session = sessions[index]
                submitted = requests.call(
                    "message", key=f"message-{capacity}-{round_number}-{index}",
                    session=session, sender=None, sender_handle=None, text={"state": "value", "value": f"h2-{capacity}-{round_number}-{index}"},
                )
                assert submitted["answer"]["status"] == "accepted", submitted
            expected = (round_number + 1) * capacity
            dispatch.wait_for(
                lambda: len(endpoint.streams) == expected,
                f"{expected} H2 streams at capacity {capacity}", timeout=45,
            )
            result_deadline = time.monotonic() + 45
            for index in range(capacity):
                key = f"message-{capacity}-{round_number}-{index}"
                result = dispatch.wait_for(
                    lambda key=key: requests.call(
                        "observe_command", key=key,
                        deadline=result_deadline,
                    )["observation"].get("result"),
                    f"H2 result {key}", deadline=result_deadline,
                )
                assert result["status"] == "completed", result
                assert requests.call("read_result", key=key,
                                     deadline=result_deadline) == endpoint.answers[f"h2-{capacity}-{round_number}-{index}"]
            drain_deadline = min(result_deadline, time.monotonic() + 20)
            wait_for_drain(
                lambda remaining: requests.call(
                    "inspect_session", session=sessions[0],
                    timeout=remaining, deadline=drain_deadline,
                )["execution"],
                drain_deadline,
            )
            idle_fds.append(requests.idle_descriptors(drain_deadline))
            if endpoint.observed_shape:
                physical_peaks.append(host_physical_peak(host.pid))
                # Flush completed-wave evidence before starting work that can fail.
                print(json.dumps({"case": "observed_shape_wave", "round": round_number + 1,
                                  "capacity": capacity, "host_physical_peak_bytes": physical_peaks[-1],
                                  "native_connection_observations": True,
                                  "completed_idle_fds": idle_fds[-1]}), flush=True)
            if observe is not None:
                observe(host.pid, round_number + 1)
        assert all(count <= idle_fds[0] for count in idle_fds), idle_fds
        streams = list(endpoint.streams)
        assert len(streams) == rounds * capacity
        assert len({(address, stream) for address, stream, _, _ in streams}) == len(streams)
        assert_round_trip_history(streams, capacity, rounds, endpoint.answers)
        assert len(endpoint.connections) == 1, endpoint.connections
        if endpoint.observed_shape:
            assert endpoint.offered_bytes >= rounds * capacity * (37_217 + 37_221 + 39_316 + 48 * 218)
        peak = physical_peaks[-1] if physical_peaks else None
        print(json.dumps({
            "case": "observed_shape" if endpoint.observed_shape else "round_trip",
            "capacity": capacity, "rounds": rounds, "alpn": "h2",
            "tcp_connections": len(endpoint.connections), "streams": len(streams),
            "complete_request_histories_validated": len(streams),
            "request_bytes": sum(len(body) for _, _, _, body in streams),
            "offered_sse_bytes": endpoint.offered_bytes,
            "native_connection_observations": True,
            "host_physical_peak_bytes": peak,
            "host_physical_peaks_by_round": physical_peaks,
            "completed_idle_fds": idle_fds,
        }), flush=True)
        return peak
    except Exception as error:
        print(json.dumps({"case": "observed_shape" if endpoint.observed_shape else "round_trip",
                          "status": "failed", "error": str(error),
                          "host_physical_peaks_by_round": physical_peaks,
                          "completed_idle_fds": idle_fds}), flush=True)
        raise
    finally:
        dispatch.stop_host(host)


def stop_held_case(host, endpoint, thread):
    incoming_error = sys.exc_info()[1]
    errors = []

    def attempt(dispose):
        try:
            dispose()
        except BaseException as error:
            errors.append(error)

    def stop():
        if host is not None:
            dispatch.stop_host(host)

    attempt(endpoint.release_first.set)
    attempt(stop)
    attempt(endpoint.shutdown)
    attempt(endpoint.server_close)

    def join():
        thread.join(timeout=5)
        assert not thread.is_alive(), "held endpoint thread did not retire"

    attempt(join)
    if errors:
        for error in errors:
            try:
                print(f"Held endpoint cleanup failed: {type(error).__name__}: {error}", file=sys.stderr)
            except BaseException:
                pass  # Optional reporting cannot replace the primary failure.
        if incoming_error is None:
            raise errors[0]


def held_population(root):
    """One withheld response cannot hold back its siblings or spin the Host."""
    capacity = 8
    endpoint = HeldEndpoint()
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = root / "held-population-store"
    host = None
    try:
        host = dispatch.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                   active_capacity=capacity, observations="transport")
        socket_path = host.rui_ready_fields["socket"]
        requests = HostRequests(host, socket_path, store)
        idle_fds = []
        sessions = []
        held_cpu = held_fds = None

        def wait_result(key, deadline):
            result = dispatch.wait_for(
                lambda: requests.call(
                    "observe_command", key=key, deadline=deadline,
                )["observation"].get("result"),
                f"held population result {key}", deadline=deadline,
            )
            assert result["status"] == "completed", result
            assert requests.call(
                "read_result", key=key, deadline=deadline,
            ) == ("answer-" + key.replace("held-message-", "held-")).encode()

        for round_number in range(2):
            for index in range(capacity):
                if round_number == 0:
                    configured = requests.call(
                        "configure", key=f"held-config-{index}",
                        session="", configuration={
                            "workspace": {"state": "value", "value": str(dispatch.ROOT)},
                            "provider": {"state": "value", "value": "codex"},
                            "model": {"state": "value", "value": "gpt-6-sol"},
                            "instructions": {"state": "omitted"},
                            "tools": {"state": "value", "value": ["bash"]},
                            "permission_mode": {"state": "value", "value": "ask"},
                            "output_schema": {"state": "omitted"},
                        },
                    )
                    assert configured["answer"]["status"] == "accepted", configured
                    sessions.append(configured["answer"]["session"])
                session = sessions[index]
                submitted = requests.call(
                    "message", key=f"held-message-{round_number}-{index}",
                    session=session, sender=None, sender_handle=None, text={"state": "value", "value": f"held-{round_number}-{index}"},
                )
                assert submitted["answer"]["status"] == "accepted", submitted
            result_deadline = time.monotonic() + 40
            keys = [f"held-message-{round_number}-{index}" for index in range(capacity)]
            if round_number == 0:
                assert endpoint.first_ready.wait(15), "first held request never arrived"
                dispatch.wait_for(lambda: len(endpoint.requests) == capacity,
                                  "every stream beside the held one", deadline=result_deadline)
                held_key = "held-message-" + endpoint.requests[0][0].removeprefix("held-")
                # Siblings share the connection and complete while one is held.
                for key in keys:
                    if key != held_key:
                        wait_result(key, result_deadline)

                def cpu_seconds():
                    value = subprocess.check_output(["ps", "-o", "time=", "-p", str(host.pid)], text=True).strip()
                    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(value.split(":"))))

                time.sleep(0.2)
                before_cpu = cpu_seconds()
                time.sleep(3)
                held_cpu = cpu_seconds() - before_cpu
                with endpoint.lock:
                    assert len(endpoint.requests) == capacity and endpoint.active == 1, endpoint.requests
                held_fds = open_descriptors(host.pid)
                assert held_cpu <= 1, f"held-stream Host used {held_cpu} CPU seconds in 3 wall seconds"
                pending = requests.call("observe_command", key=held_key)["observation"]
                assert (pending.get("processing") or {}).get("attempt") == "1", pending
                assert pending.get("result") is None, pending
                inspection = requests.call(
                    "inspect_session", session=sessions[int(held_key.rsplit("-", 1)[1])],
                )["execution"]
                assert int(inspection["custody_occupied"]) > 0, inspection
                endpoint.release_first.set()
                wait_result(held_key, result_deadline)
            else:
                for key in keys:
                    wait_result(key, result_deadline)
            wait_for_drain(
                lambda remaining: requests.call(
                    "inspect_session", session=sessions[0],
                    timeout=remaining, deadline=result_deadline,
                )["execution"],
                result_deadline,
            )
            idle_fds.append(requests.idle_descriptors(result_deadline))
        with endpoint.lock:
            assert len(endpoint.requests) == 2 * capacity, endpoint.requests
            assert {text for text, _ in endpoint.requests} == {
                f"held-{round_number}-{index}" for round_number in range(2) for index in range(capacity)
            }
            assert endpoint.active == 0, endpoint.active
            assert endpoint.h2_connections == 1, endpoint.h2_connections
        assert idle_fds[1] <= idle_fds[0], idle_fds
        print(json.dumps({"case": "held_population", "capacity": capacity, "rounds": 2,
                          "requests": len(endpoint.requests), "h2_connections": endpoint.h2_connections,
                          "maximum_simultaneous_requests": endpoint.maximum_active,
                          "held_host_cpu_seconds_in_3s": held_cpu, "held_fds": held_fds,
                          "completed_idle_fds": idle_fds}), flush=True)
    finally:
        stop_held_case(host, endpoint, thread)


def held_streams(root, endpoint, after_progress=False):
    """100 peer-held streams: controls keep working and an interrupt cancels
    its stream at once, before the peer releases anything."""
    phase = ("observed-" if endpoint.observed_shape else "") + (
        "after-progress" if after_progress else "before-first-byte"
    )
    records = root / phase
    records.mkdir(mode=0o700)
    store = root / f"held-streams-{phase}-store"
    endpoint.held_bytes = 10_000 if after_progress else 0
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-phase-trace", active_capacity=100, observations="interrupt",
    )
    diagnostics = HostDiagnostics(host)
    sessions = []
    try:
        for index in range(100):
            session = dispatch.configure(records, store, f"held-config-{index}", None, "gpt-6-sol")
            sessions.append(session)
            dispatch.message(records, store, f"held-message-{index}", session, f"held-{index}")
        dispatch.wait_for(lambda: len(endpoint.streams) == 100, "100 live H2 streams", timeout=45)
        assert endpoint.held.wait(30), "peer did not hold every stream"
        # Rui holds every stream and has written exactly the withheld prefixes.
        held = dispatch.wait_for(
            lambda: (value := dispatch.command("session", "inspect", "--store", store,
                                               "--session", sessions[0])["execution"])
            and int(value["scratch_used_bytes"]) == endpoint.held_prefix_bytes and value,
            "every held prefix captured", timeout=30,
        )
        assert int(held["custody_occupied"]) == 100, held
        # After progress, the interrupt target is mid-body: 10,000 bytes in.
        assert endpoint.held_prefixes["held-0"] == (10_000 if after_progress else 0), endpoint.held_prefixes
        processing = dispatch.observe(store, "held-message-0")["processing"]
        result_deadline = time.monotonic() + 45
        reply = dispatch.command(
            "session", "interrupt-model", "--store", store, "--record", records / "held-interrupt.json",
            "--key", "held-interrupt", "--session", sessions[0],
            "--turn", processing["turn"], "--operation", processing["operation"],
        )
        assert reply["answer"]["status"] == "accepted", reply
        diagnostics.wait("effect_stop_requested", control_key="held-interrupt", timeout=15,
                         turn=processing["turn"], operation=processing["operation"], attempt=processing["attempt"])
        cancelled = dispatch.wait_for(
            lambda: dispatch.observe(store, "held-message-0", deadline=result_deadline).get("result"),
            "interrupted held stream", deadline=result_deadline,
        )
        assert cancelled["status"] == "cancelled", cancelled
        dispatch.wait_for(lambda: endpoint.stream_ids.get("held-0") in endpoint.resets,
                          "interrupted stream reset", deadline=result_deadline)
        assert not endpoint.release.is_set()
        assert dispatch.observe(store, "held-message-1").get("result") is None
        held_rss_kib = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(host.pid)]))
        held_physical_peak = host_physical_peak(host.pid) if endpoint.observed_shape else None
        endpoint.release.set()
        for index in range(1, 100):
            key = f"held-message-{index}"
            result = dispatch.wait_for(
                lambda key=key: dispatch.observe(
                    store, key, deadline=result_deadline,
                ).get("result"),
                f"held result {index}", deadline=result_deadline,
            )
            assert result["status"] == "completed", result
            assert dispatch.read_result(store, key, deadline=result_deadline) == endpoint.answers[f"held-{index}"]
        wait_for_drain(
            lambda remaining: dispatch.command("session", "inspect", "--store", store,
                                              "--session", sessions[0], timeout=remaining)["execution"],
            result_deadline,
        )
        assert len(endpoint.connections) == 1, endpoint.connections
        idle_rss_kib = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(host.pid)]))
        idle_physical_peak = host_physical_peak(host.pid) if endpoint.observed_shape else None
        print(json.dumps({"case": "held_observed_shape" if endpoint.observed_shape else "held_streams",
                          "phase": phase, "live_streams": 100,
                          "connections": 1, "cancelled_before_release": True,
                          "body_bytes_before_hold": endpoint.held_prefix_bytes,
                          "held_host_rss_kib": held_rss_kib,
                          "completed_idle_host_rss_kib": idle_rss_kib,
                          "held_physical_peak_bytes": held_physical_peak,
                          "completed_idle_physical_peak_bytes": idle_physical_peak}), flush=True)
    finally:
        endpoint.release.set()
        diagnostics.dispose_interrupt(lambda: {
            "case": "held_streams", "after_progress": after_progress,
            "provider_stream_count": len(endpoint.streams), "provider_connection_count": len(endpoint.connections),
        }, controls=("held-interrupt",))


def write_failure_isolated(root, endpoint):
    """One stream's local write failure leaves its 19 siblings and the shared
    connection untouched."""
    store = root / "write-failure-store"
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--fault", "response-write-once", active_capacity=20,
    )
    outcomes = []
    sessions = []
    try:
        for index in range(20):
            session = dispatch.configure(root, store, f"isolated-config-{index}", None, "gpt-6-sol")
            sessions.append(session)
            dispatch.message(root, store, f"isolated-message-{index}", session, f"isolated-{index}")
        assert endpoint.ready.wait(15), "20 H2 requests did not arrive"
        completed = 0
        population_deadline = time.monotonic() + 20
        for index in range(20):
            key = f"isolated-message-{index}"
            result = dispatch.wait_for(
                lambda key=key: dispatch.observe(
                    store, key, deadline=population_deadline,
                ).get("result"), f"isolated result {index}", deadline=population_deadline,
            )
            outcomes.append(result.get("code"))
            if result["status"] == "completed":
                completed += 1
                assert dispatch.read_result(store, key, deadline=population_deadline) == endpoint.answers[f"isolated-{index}"]
        assert outcomes.count("response_write_failed") == 1, outcomes
        assert completed == 19, outcomes
        later_session = dispatch.configure(root, store, "isolated-after-config", None, "gpt-6-sol")
        dispatch.message(root, store, "isolated-after-message", later_session, "isolated-after")
        result_deadline = time.monotonic() + 20
        later = dispatch.wait_for(
            lambda: dispatch.observe(
                store, "isolated-after-message", deadline=result_deadline,
            ).get("result"),
            "new admission after local write failure", deadline=result_deadline,
        )
        assert later["status"] == "completed", later
        assert dispatch.read_result(store, "isolated-after-message", deadline=result_deadline) == endpoint.answers["isolated-after"]
        wait_for_drain(
            lambda remaining: dispatch.command("session", "inspect", "--store", store,
                                              "--session", sessions[0], timeout=remaining)["execution"],
            min(population_deadline, result_deadline),
        )
        assert len(endpoint.connections) == 1, endpoint.connections
        print(json.dumps({"case": "write_failure_isolated", "write_failures": outcomes.count("response_write_failed"),
                          "unaffected_siblings": completed, "new_admission": later["status"]}), flush=True)
    finally:
        dispatch.stop_host(host)


def refused_stream(root, endpoint, phase):
    store = root / f"refused-{phase}-store"
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-retry-waits-ms", "60000,60000,60000",
    )
    try:
        session = dispatch.configure(root, store, f"refused-{phase}-config", None, "gpt-6-sol")
        dispatch.message(root, store, f"refused-{phase}-message", session, "refused-request")
        result_deadline = time.monotonic() + 20
        result = dispatch.wait_for(
            lambda: dispatch.observe(store, f"refused-{phase}-message", deadline=result_deadline).get("result"),
            "REFUSED_STREAM same-Attempt settlement", deadline=result_deadline,
        )
        assert result["code"] == "provider_http_422", result
        assert len(endpoint.streams) == 2, endpoint.streams
        assert [text for _, _, text, _ in endpoint.streams] == (
            [None, "refused-request"] if phase == "headers" else ["refused-request"] * 2
        )
        # REFUSED_STREAM means unprocessed: replayed on the same connection.
        assert len(endpoint.connections) == 1, endpoint.connections
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            attempts = database.execute(
                "SELECT attempt_ordinal FROM model_operation"
            ).fetchone()
            assert attempts == (1,), attempts
        print(json.dumps({
            "case": f"refused_{phase}", "attempts": 1,
            "observed_streams": len(endpoint.streams), "connections": len(endpoint.connections),
        }), flush=True)
    finally:
        dispatch.stop_host(host)


def dead_reused_connection(root, endpoint):
    store = root / "dead-reuse-store"
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-retry-waits-ms", "100,60000,60000",
    )
    try:
        for text in ("warm", "dead"):
            session = dispatch.configure(root, store, f"dead-{text}-config", None, "gpt-6-sol")
            dispatch.message(root, store, f"dead-{text}-message", session, text)
            result_deadline = time.monotonic() + 20
            result = dispatch.wait_for(
                lambda text=text: dispatch.observe(store, f"dead-{text}-message", deadline=result_deadline).get("result"),
                f"settled {text} after reused H2 failure", deadline=result_deadline,
            )
            assert result["code"] == "provider_http_422", result
        assert [text for _, _, text, _ in endpoint.streams] == ["warm", "dead", "dead"]
        assert endpoint.streams[0][0] == endpoint.streams[1][0]
        assert endpoint.streams[2][0] != endpoint.streams[1][0]
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal FROM model_operation "
                "WHERE session_ref=?", (session,)
            ).fetchone() == (2,)
        print(json.dumps({
            "case": "dead_reuse", "attempts_for_dead": 2,
            "observed_streams": len(endpoint.streams), "connections": len(endpoint.connections),
        }), flush=True)
    finally:
        dispatch.stop_host(host)


def isolated_bad_header(root, endpoint):
    store = root / "sibling-header-store"
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"), active_capacity=2,
    )
    try:
        sessions = []
        for index in range(2):
            session = dispatch.configure(root, store, f"sibling-config-{index}", None, "gpt-6-sol")
            sessions.append(session)
            dispatch.message(root, store, f"sibling-message-{index}", session, f"sibling-{index}")
        codes = []
        result_deadline = time.monotonic() + 20
        for index in range(2):
            result = dispatch.wait_for(
                lambda index=index: dispatch.observe(
                    store, f"sibling-message-{index}", deadline=result_deadline,
                ).get("result"),
                f"sibling {index} settlement", deadline=result_deadline,
            )
            codes.append(result["code"])
        assert sorted(codes) == ["invalid_provider_headers", "provider_http_422"], codes
        assert len(endpoint.streams) == 2
        assert len(endpoint.connections) == 1
        wait_for_drain(
            lambda remaining: dispatch.command("session", "inspect", "--store", store,
                                              "--session", sessions[0], timeout=remaining)["execution"],
            result_deadline,
        )
        print(json.dumps({"case": "sibling_header_failure", "streams": 2, "connections": 1}), flush=True)
    finally:
        dispatch.stop_host(host)


def isolated_terminal_stream(root, endpoint, mode):
    store = root / f"isolation-{mode}-store"
    options = ("--test-request-scratch-limit", str(32 * 1024)) if mode == "capture" else ()
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"), *options, active_capacity=2,
    )
    try:
        sessions = {}
        for name in ("target", "sibling"):
            sessions[name] = dispatch.configure(root, store, f"{mode}-{name}-config", None, "gpt-6-sol")
            dispatch.message(root, store, f"{mode}-{name}-message", sessions[name], f"isolation-{name}")
        assert endpoint.ready.wait(20), f"both {mode} streams did not become live"
        if mode == "cancel":
            processing = dispatch.observe(store, "cancel-target-message")["processing"]
            reply = dispatch.command(
                "session", "interrupt-model", "--store", store, "--record", root / "cancel-interrupt.json",
                "--key", "cancel-interrupt", "--session", sessions["target"],
                "--turn", processing["turn"], "--operation", processing["operation"],
            )
            assert reply["answer"]["status"] == "accepted", reply
        target_deadline = time.monotonic() + 20
        target = dispatch.wait_for(
            lambda: dispatch.observe(store, f"{mode}-target-message", deadline=target_deadline).get("result"),
            f"{mode} target settlement", deadline=target_deadline,
        )
        assert (target["status"], target.get("code")) == (
            ("cancelled", "cancelled") if mode == "cancel" else ("failed", "response_scratch_exhausted")
        ), target
        result_deadline = target_deadline
        sibling = dispatch.wait_for(
            lambda: dispatch.observe(
                store, f"{mode}-sibling-message", deadline=result_deadline,
            ).get("result"),
            f"{mode} sibling completion", deadline=result_deadline,
        )
        assert sibling["status"] == "completed", sibling
        assert dispatch.read_result(store, f"{mode}-sibling-message", deadline=result_deadline) == b"unaffected sibling"
        dispatch.wait_for(lambda: endpoint.resets, f"{mode} stream reset", deadline=result_deadline)
        assert endpoint.resets == [endpoint.stream_ids["isolation-target"]], endpoint.resets
        assert len(endpoint.connections) == 1 and len(endpoint.streams) == 2
        assert {text for _, _, text, _ in endpoint.streams} == {"isolation-target", "isolation-sibling"}
        wait_for_drain(
            lambda remaining: dispatch.command("session", "inspect", "--store", store,
                                              "--session", sessions["target"], timeout=remaining)["execution"],
            result_deadline,
        )
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal FROM model_operation ORDER BY operation_id"
            ).fetchall() == [(1,), (1,)]
            if mode == "cancel":
                assert database.execute(
                    "SELECT interrupted_by_command_key FROM model_operation WHERE session_ref=?", (sessions["target"],)
                ).fetchone() == ("cancel-interrupt",)
        print(json.dumps({"case": f"sibling_{mode}", "streams": 2, "connections": 1,
                          "target_resets": len(endpoint.resets), "sibling": "completed"}), flush=True)
    finally:
        dispatch.stop_host(host)


def connection_failure(root, endpoint):
    store = root / "connection-failure-store"
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-retry-waits-ms", "100,60000,60000", "--test-phase-trace", active_capacity=2,
    )
    diagnostics = None
    observed = {}
    sessions = []
    try:
        diagnostics = HostDiagnostics(host)
        for index in range(2):
            session = dispatch.configure(root, store, f"drop-config-{index}", None, "gpt-6-sol")
            sessions.append(session)
            dispatch.message(root, store, f"drop-message-{index}", session, f"drop-{index}")
        result_deadline = time.monotonic() + 20

        def settled(index):
            observed[index] = dispatch.observe(store, f"drop-message-{index}", deadline=result_deadline)
            return observed[index].get("result")

        for index in range(2):
            result = dispatch.wait_for(
                lambda index=index: settled(index),
                f"connection failure settlement {index}", deadline=result_deadline,
            )
            assert result["code"] == "provider_http_422", result
        assert len(endpoint.streams) == 4, endpoint.streams
        assert sorted(text for _, _, text, _ in endpoint.streams) == ["drop-0", "drop-0", "drop-1", "drop-1"]
        wait_for_drain(
            lambda remaining: dispatch.command("session", "inspect", "--store", store,
                                              "--session", sessions[0], timeout=remaining)["execution"],
            result_deadline,
        )
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal FROM model_operation ORDER BY operation_id"
            ).fetchall() == [(2,), (2,)]
        print(json.dumps({"case": "connection_failure", "streams": 4, "attempts_per_operation": 2}), flush=True)
    except BaseException:
        retain_connection_failure(store, host, diagnostics, endpoint, observed, sessions)
        raise
    finally:
        dispatch.stop_host(host)


def retain_connection_failure(store, host, diagnostics, endpoint, observed, sessions):
    """Keep where each Attempt went: peer streams per connection, live Host
    execution facts, durable retry state and Attempt milestones. Fixture
    texts, codes, counts and clocks only; never bodies or the Store itself.

    Decide from Store rows, peer streams and execution facts. Trace and
    optional stderr are try-only and lossy, so milestones only corroborate.
    Retention is optional: no step of it may replace the original failure."""
    try:
        _retain_connection_failure(store, host, diagnostics, endpoint, observed, sessions)
    except Exception as error:
        try:
            print(f"Connection failure diagnostics unavailable: {type(error).__name__}", file=sys.stderr, flush=True)
        except Exception:
            pass


def _retain_connection_failure(store, host, diagnostics, endpoint, observed, sessions):
    execution = {}
    if host.poll() is None:
        for index, session in enumerate(sessions):  # Live facts first; a fence is visible only here.
            try:
                execution[index] = dispatch.command(
                    "session", "inspect", "--store", store, "--session", session, timeout=2,
                )["execution"]
            except Exception as error:
                execution[index] = type(error).__name__
    dispatch.stop_host(host)  # Reap: the Store and stderr are then final.

    def collect():
        with endpoint.lock:
            connections = list(endpoint.connections)
            streams = [{"connection": connections.index(address), "stream": stream_id, "text": text}
                       for address, stream_id, text, _ in endpoint.streams]
            dropped = endpoint.dropped
        with sqlite3.connect(store / "rui.sqlite3") as database:
            operations = database.execute(
                "SELECT operation_id,attempt_ordinal,(resolution_code IS NULL AND retry_due_at_ms IS 0),retry_due_at_ms,"
                "last_failure_code,resolution_code FROM model_operation ORDER BY operation_id"
            ).fetchall()
        records = diagnostics.records if diagnostics else []
        return {
            "case": "connection_failure", "collected_at_unix_ms": int(time.time() * 1000),
            "dropped": dropped, "connections": len(connections), "streams": streams,
            "operations": operations, "execution": execution, "last_observation": observed,
            "milestones": [{name: record.get(name) for name in ("sequence", "rui_test_phase", "operation", "attempt", "at_ns")}
                           for record in records
                           if "attempt" in record],
            "first_lost_sequence": next((record.get("sequence") for record in records
                                         if record.get("trace_lost")), None),
            "stderr_tail": [line for line in (diagnostics.tail() if diagnostics else b"").decode("utf-8", "replace").splitlines()
                            if '"trace_lost":' not in line],
        }

    path = _failure_destination(os.environ.get("RUI_FAILURE_ARTIFACTS")) / f"connection-failure-{host.pid}.json"
    if preserve_failure_metadata(path, collect):
        print(f"retained connection failure diagnostics: {path}", file=sys.stderr, flush=True)


def unsupported_https(root):
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / "cert.pem", root / "key.pem")
    tls.set_alpn_protocols(["http/1.1"])
    endpoint = dispatch.SuccessEndpoint([])
    endpoint.socket = tls.wrap_socket(endpoint.socket, server_side=True)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = root / "non-h2-store"
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_port}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
    )
    try:
        session = dispatch.configure(root, store, "non-h2-config", None, "gpt-6-sol")
        dispatch.message(root, store, "non-h2-message", session, "non-h2")
        result_deadline = time.monotonic() + 20
        result = dispatch.wait_for(
            lambda: dispatch.observe(store, "non-h2-message", deadline=result_deadline).get("result"),
            "non-H2 HTTPS failure", deadline=result_deadline,
        )
        assert result["code"] == "provider_http2_required", result
        assert endpoint.requests == []
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            attempts = database.execute(
                "SELECT attempt_ordinal FROM model_operation"
            ).fetchone()
            assert attempts == (1,), attempts
        print(json.dumps({"case": "non_h2_https", "result": result["code"],
                          "posts": 0, "attempts": attempts[0]}), flush=True)
    finally:
        dispatch.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)


def negotiated_h2_early_error(root, endpoint):
    store = root / "early-h2-error-store"
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"), "--test-retry-waits-ms", "1,1,1",
    )
    try:
        session = dispatch.configure(root, store, "early-h2-config", None, "gpt-6-sol")
        dispatch.message(root, store, "early-h2-message", session, "early-h2")
        result_deadline = time.monotonic() + 20
        result = dispatch.wait_for(
            lambda: dispatch.observe(store, "early-h2-message", deadline=result_deadline).get("result"),
            "negotiated H2 protocol failure settlement", deadline=result_deadline,
        )
        assert result["code"] == "retry_exhausted", result
        assert len(endpoint.streams) == 4, endpoint.streams
        assert all(text == "early-h2" for _, _, text, _ in endpoint.streams)
    finally:
        dispatch.stop_host(host)
    with sqlite3.connect(store / "rui.sqlite3") as database:
        attempts = database.execute(
            "SELECT attempt_ordinal FROM model_operation"
        ).fetchone()
        assert attempts == (4,), attempts
    print(json.dumps({"case": "negotiated_h2_early_error", "posts": len(endpoint.streams),
                      "result": result["code"]}), flush=True)


def observed_shape_cases(root, tls):
    (root / "observed-shape").mkdir(mode=0o700)
    for capacity in (1, 100):
        endpoint = Endpoint(tls, capacity, sse=True, observed_shape=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            round_trip(root / "observed-shape", endpoint, capacity, root / "cert.pem")
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
    for after_progress in (False, True):
        endpoint = Endpoint(tls, 100, sse=True, observed_shape=True, held=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            held_streams(root, endpoint, after_progress)
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)


def held_case(root, tls, case):
    held = case in ("held-before", "held-progress")
    endpoint = Endpoint(tls, 100 if held else 20, sse=True, held=held,
                        after_progress=case == "held-progress", eager_sse=not held)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    try:
        if held:
            held_streams(root, endpoint, case == "held-progress")
        else:
            assert case == "write-failure", case
            write_failure_isolated(root, endpoint)
    finally:
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)


def main():
    observed_only = len(sys.argv) == 3 and sys.argv[2] == "--observed-shape-only"
    churn = len(sys.argv) == 3 and sys.argv[2] == "--observed-shape-churn"
    selected = sys.argv[2].removeprefix("--case=") if len(sys.argv) == 3 and sys.argv[2].startswith("--case=") else None
    held_cases = ("held-before", "held-progress", "write-failure")
    assert len(sys.argv) == 2 or observed_only or churn or selected in held_cases
    if churn and not os_semantics.FOOTPRINT:
        raise RuntimeError("Observed-shape churn footprint qualification requires macOS")
    with tempfile.TemporaryDirectory(prefix="rui-h2-") as tmp:
        root = pathlib.Path(tmp)
        if not observed_only and not churn and selected is None:
            held_population(root)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
            "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(root / "cert.pem", root / "key.pem")
        tls.set_alpn_protocols(["h2"])
        if selected is not None:
            held_case(root, tls, selected)
            return
        if churn:
            endpoint = Endpoint(tls, 100, sse=True, observed_shape=True)
            thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            try:
                peak = round_trip(root, endpoint, 100, root / "cert.pem", rounds=20)
                assert peak is not None and peak <= 25_000_000, f"Host footprint target miss: {peak} bytes"
            finally:
                endpoint.shutdown()
                endpoint.server_close()
                thread.join(timeout=5)
            return
        if observed_only:
            observed_shape_cases(root, tls)
            return
        for capacity in (1, 100):
            endpoint = Endpoint(tls, capacity, sse=True)
            thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            try:
                round_trip(root, endpoint, capacity, root / "cert.pem")
            finally:
                endpoint.shutdown()
                endpoint.server_close()
                thread.join(timeout=5)
        observed_shape_cases(root, tls)
        for case in held_cases:
            held_case(root, tls, case)
        for phase in ("headers", "upload"):
            endpoint = Endpoint(tls, 1, refuse_at=phase)
            thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            try:
                refused_stream(root, endpoint, phase)
            finally:
                endpoint.shutdown()
                endpoint.server_close()
                thread.join(timeout=5)
        endpoint = Endpoint(tls, 1, dead_reuse=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            dead_reused_connection(root, endpoint)
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
        endpoint = Endpoint(tls, 2, bad_header=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            isolated_bad_header(root, endpoint)
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
        for mode in ("cancel", "capture"):
            endpoint = Endpoint(tls, 2, isolation=mode)
            thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            try:
                isolated_terminal_stream(root, endpoint, mode)
            finally:
                endpoint.shutdown()
                endpoint.server_close()
                thread.join(timeout=5)
        endpoint = Endpoint(tls, 2, drop_once=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            connection_failure(root, endpoint)
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
        endpoint = Endpoint(tls, 1, early_protocol_error=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            negotiated_h2_early_error(root, endpoint)
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
        unsupported_https(root)


if __name__ == "__main__":
    host_process.enter()
    main()
