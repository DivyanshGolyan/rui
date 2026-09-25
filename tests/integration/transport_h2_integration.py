#!/usr/bin/env python3
"""Native owner/ALPN/stream witness; requires h2==4.3.0 and OpenSSL CLI."""
import http.server
import json
import os
import pathlib
import re
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

import dispatch_integration as dispatch
from host_process import HostDiagnostics


class Endpoint(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, tls, population, refuse_at=None, dead_reuse=False, bad_header=False, drop_once=False, sse=False, isolation=None, after_progress=False, early_protocol_error=False, eager_sse=False, observed_shape=False):
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
        self.ready = threading.Event()
        self.lock = threading.Lock()

    def get_request(self):
        sock, address = super().get_request()
        return self.tls.wrap_socket(sock, server_side=True), address


class H1Endpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, trickle_first=False):
        super().__init__(("127.0.0.1", 0), H1Handler)
        self.trickle_first = trickle_first
        self.lock = threading.Lock()
        self.first_ready = threading.Event()
        self.release_first = threading.Event()
        self.requests = []
        self.connections = set()
        self.active = 0
        self.maximum_active = 0


class H1Handler(http.server.BaseHTTPRequestHandler):
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
        try:
            payload, _, _ = dispatch.sse_answer(
                f"response-{text}", f"reasoning-{text}", f"message-{text}", f"answer-{text}",
            )
            if first:
                self.server.first_ready.set()
                if not self.server.trickle_first:
                    assert self.server.release_first.wait(20), "first H1 response was never released"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            if first and self.server.trickle_first:
                offset = 0
                while not self.server.release_first.is_set():
                    self.wfile.write(payload[offset:offset + 1])
                    self.wfile.flush()
                    offset += 1
                    assert self.server.release_first.wait(0.2) or offset < len(payload)
                self.wfile.write(payload[offset:])
            else:
                self.wfile.write(payload)
            self.close_connection = True
        finally:
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


def host_physical_peak(pid):
    if sys.platform != "darwin":
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
        with self.server.lock:
            self.server.connections.append(self.client_address)
        while True:
            try:
                data = sock.recv(65536)
            except (OSError, TimeoutError):
                return
            if not data:
                return
            for event in conn.receive_data(data):
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
                            elif self.server.after_progress and text == "stalled-0":
                                # Only the interrupt target exceeds the 10-KiB write-gate threshold.
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
                    hold_target_open = (self.server.isolation == "capture" and
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


def round_trip(root, endpoint, capacity, ca_file):
    store = root / f"store-{capacity}"
    host = dispatch.start_host(
        store,
        f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file",
        str(ca_file),
        active_capacity=capacity,
    )
    try:
        idle_fds = []
        for round_number in range(2):
            for index in range(capacity):
                session = f"direct/h2-{capacity}-{index}"
                if round_number == 0:
                    dispatch.configure(root, store, f"config-{capacity}-{index}", session, "model-a")
                dispatch.message(
                    root, store, f"message-{capacity}-{round_number}-{index}", session,
                    f"h2-{capacity}-{round_number}-{index}",
                )
            expected = (round_number + 1) * capacity
            dispatch.wait_for(
                lambda: len(endpoint.streams) == expected,
                f"{expected} H2 streams at capacity {capacity}", timeout=45,
            )
            for index in range(capacity):
                key = f"message-{capacity}-{round_number}-{index}"
                dispatch.wait_for(
                    lambda key=key: dispatch.observe(store, key).get("result"),
                    f"H2 result {key}", timeout=45,
                )
                assert dispatch.observe(store, key)["result"]["status"] == "completed"
                assert dispatch.read_result(store, key) == endpoint.answers[f"h2-{capacity}-{round_number}-{index}"]
            # Store settlement precedes the execution owner's custody release.
            dispatch.wait_for(
                lambda: dispatch.command(
                    "inspect-session", "--store", store, "--session", f"direct/h2-{capacity}-0"
                )["execution"]["custody_occupied"] == "0",
                f"H2 custody drainage after round {round_number}", timeout=20,
            )
            observation = dispatch.command(
                "inspect-session", "--store", store, "--session", f"direct/h2-{capacity}-0"
            )["execution"]
            assert observation["custody_occupied"] == "0", observation
            assert observation["scratch_used_bytes"] == "0", observation
            idle_fds.append(open_descriptors(host.pid))
        assert idle_fds[1] <= idle_fds[0], idle_fds
        streams = list(endpoint.streams)
        assert len(streams) == 2 * capacity
        assert len({(address, stream) for address, stream, _, _ in streams}) == len(streams)
        assert {text for _, _, text, _ in streams} == {
            f"h2-{capacity}-{round_number}-{index}"
            for round_number in range(2) for index in range(capacity)
        }
        assert len(endpoint.connections) == 1, endpoint.connections
        if endpoint.observed_shape:
            assert endpoint.offered_bytes >= 2 * capacity * (37_217 + 37_221 + 39_316 + 48 * 218)
        print(json.dumps({
            "case": "observed_shape" if endpoint.observed_shape else "round_trip",
            "capacity": capacity, "rounds": 2, "alpn": "h2",
            "tcp_connections": len(endpoint.connections), "streams": len(streams),
            "request_bytes": sum(len(body) for _, _, _, body in streams),
            "offered_sse_bytes": endpoint.offered_bytes,
            "host_physical_peak_bytes": host_physical_peak(host.pid) if endpoint.observed_shape else None,
            "completed_idle_fds": idle_fds,
        }), flush=True)
    finally:
        dispatch.stop_host(host)


def queued_h1(root):
    capacity = 8
    endpoint = H1Endpoint()
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = root / "bounded-h1-store"
    host = None
    try:
        host = dispatch.start_host(store, f"http://127.0.0.1:{endpoint.server_port}/responses",
                                   active_capacity=capacity)
        idle_fds = []
        for round_number in range(2):
            for index in range(capacity):
                session = f"direct/h1-{index}"
                if round_number == 0:
                    dispatch.configure(root, store, f"h1-config-{index}", session, "model-a")
                dispatch.message(root, store, f"h1-message-{round_number}-{index}", session,
                                 f"h1-{round_number}-{index}")
            if round_number == 0:
                assert endpoint.first_ready.wait(15), "first H1 request never arrived"
                # An all-eight-ready barrier would strand work behind the one-connection cap.
                # Hold only the first response; the Host must keep serving controls without spinning.
                def cpu_seconds():
                    value = subprocess.check_output(["ps", "-o", "time=", "-p", str(host.pid)], text=True).strip()
                    return sum(float(part) * 60 ** index for index, part in enumerate(reversed(value.split(":"))))

                time.sleep(0.2)
                before_cpu = cpu_seconds()
                time.sleep(3)
                held_cpu = cpu_seconds() - before_cpu
                with endpoint.lock:
                    assert len(endpoint.requests) == 1 and endpoint.active == 1, endpoint.requests
                    assert len(endpoint.connections) == 1, endpoint.connections
                held_fds = open_descriptors(host.pid)
                assert held_cpu <= 1, f"queued H1 Host used {held_cpu} CPU seconds in 3 wall seconds"
                for index in range(capacity):
                    pending = dispatch.observe(store, f"h1-message-0-{index}")
                    assert (pending.get("processing") or {}).get("attempt") == "1", pending
                    assert pending.get("result") is None, pending
                inspection = dispatch.command("inspect-session", "--store", store,
                                              "--session", "direct/h1-1")["execution"]
                assert int(inspection["custody_occupied"]) > 0, inspection
                endpoint.release_first.set()
            for index in range(capacity):
                key = f"h1-message-{round_number}-{index}"
                result = dispatch.wait_for(lambda key=key: dispatch.observe(store, key).get("result"),
                                           f"queued H1 result {key}", timeout=40)
                assert result["status"] == "completed", result
                assert dispatch.read_result(store, key) == f"answer-h1-{round_number}-{index}".encode()
            execution = dispatch.command("inspect-session", "--store", store,
                                         "--session", "direct/h1-0")["execution"]
            assert execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0", execution
            idle_fds.append(open_descriptors(host.pid))
        with endpoint.lock:
            assert len(endpoint.requests) == 2 * capacity, endpoint.requests
            assert {text for text, _ in endpoint.requests} == {
                f"h1-{round_number}-{index}" for round_number in range(2) for index in range(capacity)
            }
            assert endpoint.maximum_active == 1 and endpoint.active == 0, endpoint.maximum_active
            assert len(endpoint.connections) == 2 * capacity, endpoint.connections
        assert idle_fds[1] <= idle_fds[0], idle_fds
        print(json.dumps({"case": "bounded_loopback_h1", "capacity": capacity, "rounds": 2,
                          "requests": len(endpoint.requests), "tcp_connections": len(endpoint.connections),
                          "maximum_simultaneous_requests": endpoint.maximum_active,
                          "held_host_cpu_seconds_in_3s": held_cpu, "held_fds": held_fds,
                          "completed_idle_fds": idle_fds}), flush=True)
    finally:
        endpoint.release_first.set()
        if host is not None:
            dispatch.stop_host(host)
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)


def queued_h1_inactivity(root):
    endpoint = H1Endpoint(trickle_first=True)
    thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    thread.start()
    store = root / "bounded-h1-inactivity-store"
    host = dispatch.start_host(
        store, f"http://127.0.0.1:{endpoint.server_port}/responses",
        "--test-provider-inactivity-seconds", "1", "--test-retry-waits-ms", "60000,60000,60000",
        active_capacity=2,
    )
    try:
        for index in range(2):
            dispatch.configure(root, store, f"queued-config-{index}", f"direct/queued-{index}", "model-a")
            dispatch.message(root, store, f"queued-message-{index}", f"direct/queued-{index}", f"queued-{index}")
        assert endpoint.first_ready.wait(15), "first H1 request never arrived"
        time.sleep(1.7)
        with endpoint.lock:
            assert len(endpoint.requests) == 1 and endpoint.active == 1, endpoint.requests
            held = endpoint.requests[0][0]
        queued = 1 if held == "queued-0" else 0
        assert dispatch.observe(store, f"queued-message-{queued}").get("result") is None
        endpoint.release_first.set()
        held_result = dispatch.wait_for(
            lambda: dispatch.observe(store, f"queued-message-{1 - queued}").get("result"),
            "trickling H1 request completes", timeout=10,
        )
        assert held_result["status"] == "completed", held_result
        assert dispatch.read_result(store, f"queued-message-{1 - queued}") == f"answer-{held}".encode()
    finally:
        dispatch.stop_host(host)
        endpoint.release_first.set()
        endpoint.shutdown()
        endpoint.server_close()
        thread.join(timeout=5)
    with sqlite3.connect(store / "rui.sqlite3") as database:
        rows = database.execute(
            "SELECT attempt_ordinal,allowance_used,uncertain,retry_due_at_ms,last_failure_code "
            "FROM model_operation ORDER BY operation_id"
        ).fetchall()
        assert rows[queued][:3] == (1, 1, 0) and rows[queued][3] > 0, rows
        assert rows[queued][4] == "provider_transport_failure", rows
    print(json.dumps({"case": "queued_h1_inactivity", "received_requests": 1,
                      "queued_attempt_failure": rows[queued][4]}), flush=True)


def stalled_capture(root, endpoint, after_progress=False):
    phase = ("observed-" if endpoint.observed_shape else "") + (
        "after-progress" if after_progress else "before-first-write"
    )
    records = root / phase
    records.mkdir(mode=0o700)
    store = root / f"stalled-capture-{phase}-store"
    gate = root / f"capture-write-{phase}-gate"
    os.mkfifo(gate)
    keeper = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-response-capture-gate-path", str(gate),
        *(["--test-response-capture-gate-min-written-bytes", "10000"] if after_progress else []),
        "--test-phase-trace", active_capacity=100,
    )
    diagnostics = HostDiagnostics(host)
    released = False
    try:
        for index in range(100):
            session = f"direct/stalled-{index}"
            dispatch.configure(records, store, f"stalled-config-{index}", session, "model-a")
            dispatch.message(records, store, f"stalled-message-{index}", session, f"stalled-{index}")
        dispatch.wait_for(lambda: len(endpoint.streams) == 100, "100 live H2 streams", timeout=45)
        gate_event = diagnostics.wait("capture_write_gate_entered", timeout=30)[0]
        assert (gate_event["written_bytes"] >= 10_000) == after_progress, gate_event
        processing = dispatch.observe(store, "stalled-message-0")["processing"]
        reply = dispatch.command(
            "interrupt-model", "--store", store, "--record", records / "stalled-interrupt.json",
            "--key", "stalled-interrupt", "--session", "direct/stalled-0",
            "--turn", processing["turn"], "--operation", processing["operation"],
        )
        assert reply["answer"]["status"] == "accepted", reply
        diagnostics.wait("effect_stop_requested", control_key="stalled-interrupt", timeout=15)
        held = dispatch.command("inspect-session", "--store", store,
                                "--session", "direct/stalled-0")["execution"]
        assert int(held["custody_occupied"]) > 0, held
        assert dispatch.observe(store, "stalled-message-1").get("result") is None
        stalled_rss_kib = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(host.pid)]))
        held_physical_peak = host_physical_peak(host.pid) if endpoint.observed_shape else None
        os.write(keeper, b"r")
        released = True
        for index in range(100):
            key = f"stalled-message-{index}"
            result = dispatch.wait_for(lambda key=key: dispatch.observe(store, key).get("result"),
                                       f"stalled result {index}", timeout=45)
            if index == 0:
                assert result["status"] == "cancelled", result
            else:
                assert result["status"] == "completed", result
                assert dispatch.read_result(store, key) == endpoint.answers[f"stalled-{index}"]
        execution = dispatch.command("inspect-session", "--store", store,
                                     "--session", "direct/stalled-0")["execution"]
        assert execution["custody_occupied"] == "0", execution
        assert execution["scratch_used_bytes"] == "0", execution
        assert len(endpoint.connections) == 1, endpoint.connections
        idle_rss_kib = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(host.pid)]))
        idle_physical_peak = host_physical_peak(host.pid) if endpoint.observed_shape else None
        print(json.dumps({"case": "stalled_observed_shape" if endpoint.observed_shape else "stalled_local_capture",
                          "phase": phase, "live_streams": 100,
                          "connections": 1, "control_before_release": True,
                          "capture_written_before_gate": gate_event["written_bytes"],
                          "stalled_host_rss_kib": stalled_rss_kib,
                          "completed_idle_host_rss_kib": idle_rss_kib,
                          "held_physical_peak_bytes": held_physical_peak,
                          "completed_idle_physical_peak_bytes": idle_physical_peak}), flush=True)
    finally:
        if not released:
            os.write(keeper, b"r")
        os.close(keeper)
        dispatch.stop_host(host)
        diagnostics.close()


def paused_capture_inactivity(root, endpoint):
    store = root / "paused-inactivity-store"
    gate = root / "paused-inactivity-gate"
    os.mkfifo(gate)
    keeper = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-response-capture-gate-path", str(gate),
        "--test-provider-inactivity-seconds", "3", "--test-phase-trace", active_capacity=20,
    )
    diagnostics = HostDiagnostics(host)
    try:
        for index in range(20):
            session = f"direct/paused-{index}"
            dispatch.configure(root, store, f"paused-config-{index}", session, "model-a")
            dispatch.message(root, store, f"paused-message-{index}", session, f"paused-{index}")
        assert endpoint.ready.wait(15), "20 H2 requests did not arrive"
        diagnostics.wait("capture_write_gate_entered", timeout=15)
        # The local writer is blocked, not the provider. Hold beyond the
        # provider inactivity interval while curl's receive queue fills.
        time.sleep(3.5)
        assert len(endpoint.streams) == 20, endpoint.streams
        os.write(keeper, b"r")
        for index in range(20):
            key = f"paused-message-{index}"
            result = dispatch.wait_for(lambda key=key: dispatch.observe(store, key).get("result"),
                                       f"paused capture result {index}", timeout=20)
            assert result["status"] == "completed", result
            assert dispatch.read_result(store, key) == endpoint.answers[f"paused-{index}"]
        execution = dispatch.command("inspect-session", "--store", store,
                                     "--session", "direct/paused-0")["execution"]
        assert execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0", execution
    finally:
        os.write(keeper, b"r")
        os.close(keeper)
        dispatch.stop_host(host)
        diagnostics.close()
    with sqlite3.connect(store / "rui.sqlite3") as database:
        attempts = database.execute("SELECT attempt_ordinal,allowance_used FROM model_operation").fetchall()
        assert attempts == [(1, 1)] * 20, attempts
    print(json.dumps({"case": "paused_capture_inactivity", "streams": len(endpoint.streams),
                      "attempts": 20, "hold_seconds": 3.5}), flush=True)


def capture_failure_on_resume(root, endpoint):
    store = root / "resume-capture-failure-store"
    gate = root / "resume-capture-failure-gate"
    os.mkfifo(gate)
    keeper = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-response-capture-gate-path", str(gate),
        "--fault", "response-write-on-resume", "--test-phase-trace", active_capacity=20,
    )
    diagnostics = HostDiagnostics(host)
    try:
        for index in range(20):
            session = f"direct/resume-{index}"
            dispatch.configure(root, store, f"resume-config-{index}", session, "model-a")
            dispatch.message(root, store, f"resume-message-{index}", session, f"resume-{index}")
        assert endpoint.ready.wait(15), "20 H2 requests did not arrive"
        diagnostics.wait("capture_write_gate_entered", timeout=15)
        os.write(keeper, b"r")
        outcomes = []
        completed = 0
        for index in range(20):
            key = f"resume-message-{index}"
            result = dispatch.wait_for(lambda key=key: dispatch.observe(store, key).get("result"),
                                       f"resume result {index}", timeout=20)
            outcomes.append(result.get("code"))
            if result["status"] == "completed":
                completed += 1
                assert dispatch.read_result(store, key) == endpoint.answers[f"resume-{index}"]
        assert outcomes.count("response_write_failed") == 1, outcomes
        assert len(diagnostics.matching("transport_resume_capture_failure")) == 1, diagnostics.records[-12:]
        assert completed == 19, outcomes
        dispatch.configure(root, store, "resume-after-config", "direct/resume-after", "model-a")
        dispatch.message(root, store, "resume-after-message", "direct/resume-after", "resume-after")
        later = dispatch.wait_for(lambda: dispatch.observe(store, "resume-after-message").get("result"),
                                  "new admission after local capture failure", timeout=20)
        assert later["status"] == "completed", later
        assert dispatch.read_result(store, "resume-after-message") == endpoint.answers["resume-after"]
        execution = dispatch.command("inspect-session", "--store", store,
                                     "--session", "direct/resume-0")["execution"]
        assert execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0", execution
        assert len(endpoint.connections) == 1, endpoint.connections
        print(json.dumps({"case": "capture_failure_on_resume", "capture_failures": outcomes.count("response_write_failed"),
                          "unaffected_siblings": completed, "new_admission": later["status"]}), flush=True)
    finally:
        os.write(keeper, b"r")
        os.close(keeper)
        dispatch.stop_host(host)
        diagnostics.close()


def refused_stream(root, endpoint, phase):
    store = root / f"refused-{phase}-store"
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-retry-waits-ms", "60000,60000,60000",
    )
    try:
        dispatch.configure(root, store, f"refused-{phase}-config", "direct/refused", "model-a")
        dispatch.message(root, store, f"refused-{phase}-message", "direct/refused", "refused-request")
        dispatch.wait_for(
            lambda: dispatch.observe(store, f"refused-{phase}-message").get("result"),
            "REFUSED_STREAM same-Attempt settlement", timeout=20,
        )
        assert dispatch.observe(store, f"refused-{phase}-message")["result"]["code"] == "provider_http_422"
        assert len(endpoint.streams) == 2, endpoint.streams
        assert [text for _, _, text, _ in endpoint.streams] == (
            [None, "refused-request"] if phase == "headers" else ["refused-request"] * 2
        )
        assert len(endpoint.connections) == 2, endpoint.connections
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            attempts = database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation"
            ).fetchone()
            assert attempts == (1, 1), attempts
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
            dispatch.configure(root, store, f"dead-{text}-config", f"direct/{text}", "model-a")
            dispatch.message(root, store, f"dead-{text}-message", f"direct/{text}", text)
            dispatch.wait_for(
                lambda text=text: dispatch.observe(store, f"dead-{text}-message").get("result"),
                f"settled {text} after reused H2 failure", timeout=20,
            )
            assert dispatch.observe(store, f"dead-{text}-message")["result"]["code"] == "provider_http_422"
        assert [text for _, _, text, _ in endpoint.streams] == ["warm", "dead", "dead"]
        assert endpoint.streams[0][0] == endpoint.streams[1][0]
        assert endpoint.streams[2][0] != endpoint.streams[1][0]
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation "
                "WHERE session_ref='direct/dead'"
            ).fetchone() == (2, 2)
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
        for index in range(2):
            dispatch.configure(root, store, f"sibling-config-{index}", f"direct/sibling-{index}", "model-a")
            dispatch.message(root, store, f"sibling-message-{index}", f"direct/sibling-{index}", f"sibling-{index}")
        for index in range(2):
            dispatch.wait_for(
                lambda index=index: dispatch.observe(store, f"sibling-message-{index}").get("result"),
                f"sibling {index} settlement", timeout=20,
            )
        assert sorted(dispatch.observe(store, f"sibling-message-{index}")["result"]["code"]
                      for index in range(2)) == ["invalid_provider_headers", "provider_http_422"]
        assert len(endpoint.streams) == 2
        assert len(endpoint.connections) == 1
        observation = dispatch.command(
            "inspect-session", "--store", store, "--session", "direct/sibling-0"
        )["execution"]
        assert observation["custody_occupied"] == "0", observation
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
        for name in ("target", "sibling"):
            dispatch.configure(root, store, f"{mode}-{name}-config", f"direct/{name}", "model-a")
            dispatch.message(root, store, f"{mode}-{name}-message", f"direct/{name}", f"isolation-{name}")
        assert endpoint.ready.wait(20), f"both {mode} streams did not become live"
        if mode == "cancel":
            processing = dispatch.observe(store, "cancel-target-message")["processing"]
            reply = dispatch.command(
                "interrupt-model", "--store", store, "--record", root / "cancel-interrupt.json",
                "--key", "cancel-interrupt", "--session", "direct/target",
                "--turn", processing["turn"], "--operation", processing["operation"],
            )
            assert reply["answer"]["status"] == "accepted", reply
        target = dispatch.wait_for(
            lambda: dispatch.observe(store, f"{mode}-target-message").get("result"),
            f"{mode} target settlement", timeout=20,
        )
        assert (target["status"], target.get("code")) == (
            ("cancelled", "cancelled") if mode == "cancel" else ("failed", "response_scratch_exhausted")
        ), target
        sibling = dispatch.wait_for(
            lambda: dispatch.observe(store, f"{mode}-sibling-message").get("result"),
            f"{mode} sibling completion", timeout=20,
        )
        assert sibling["status"] == "completed", sibling
        assert dispatch.read_result(store, f"{mode}-sibling-message") == b"unaffected sibling"
        dispatch.wait_for(lambda: endpoint.resets, f"{mode} stream reset", timeout=20)
        assert endpoint.resets == [endpoint.stream_ids["isolation-target"]], endpoint.resets
        assert len(endpoint.connections) == 1 and len(endpoint.streams) == 2
        assert {text for _, _, text, _ in endpoint.streams} == {"isolation-target", "isolation-sibling"}
        execution = dispatch.command(
            "inspect-session", "--store", store, "--session", "direct/target"
        )["execution"]
        assert execution["custody_occupied"] == "0", execution
        assert execution["scratch_used_bytes"] == "0", execution
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation ORDER BY operation_id"
            ).fetchall() == [(1, 1), (1, 1)]
            if mode == "cancel":
                assert database.execute(
                    "SELECT interrupted_by_command_key FROM model_operation WHERE session_ref='direct/target'"
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
        "--test-retry-waits-ms", "100,60000,60000", active_capacity=2,
    )
    try:
        for index in range(2):
            dispatch.configure(root, store, f"drop-config-{index}", f"direct/drop-{index}", "model-a")
            dispatch.message(root, store, f"drop-message-{index}", f"direct/drop-{index}", f"drop-{index}")
        for index in range(2):
            dispatch.wait_for(
                lambda index=index: dispatch.observe(store, f"drop-message-{index}").get("result"),
                f"connection failure settlement {index}", timeout=20,
            )
            assert dispatch.observe(store, f"drop-message-{index}")["result"]["code"] == "provider_http_422"
        assert len(endpoint.streams) == 4, endpoint.streams
        assert sorted(text for _, _, text, _ in endpoint.streams) == ["drop-0", "drop-0", "drop-1", "drop-1"]
        observation = dispatch.command(
            "inspect-session", "--store", store, "--session", "direct/drop-0"
        )["execution"]
        assert observation["custody_occupied"] == "0", observation
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation ORDER BY operation_id"
            ).fetchall() == [(2, 2), (2, 2)]
        print(json.dumps({"case": "connection_failure", "streams": 4, "attempts_per_operation": 2}), flush=True)
    finally:
        dispatch.stop_host(host)


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
        dispatch.configure(root, store, "non-h2-config", "direct/non-h2", "model-a")
        dispatch.message(root, store, "non-h2-message", "direct/non-h2", "non-h2")
        result = dispatch.wait_for(
            lambda: dispatch.observe(store, "non-h2-message").get("result"),
            "non-H2 HTTPS failure", timeout=20,
        )
        assert result["code"] == "provider_http2_required", result
        assert endpoint.requests == []
        dispatch.stop_host(host)
        with sqlite3.connect(store / "rui.sqlite3") as database:
            attempts = database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation"
            ).fetchone()
            assert attempts == (1, 1), attempts
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
        dispatch.configure(root, store, "early-h2-config", "direct/early-h2", "model-a")
        dispatch.message(root, store, "early-h2-message", "direct/early-h2", "early-h2")
        result = dispatch.wait_for(
            lambda: dispatch.observe(store, "early-h2-message").get("result"),
            "negotiated H2 protocol failure settlement", timeout=20,
        )
        assert result["code"] == "retry_exhausted", result
        assert len(endpoint.streams) == 4, endpoint.streams
        assert all(text == "early-h2" for _, _, text, _ in endpoint.streams)
    finally:
        dispatch.stop_host(host)
    with sqlite3.connect(store / "rui.sqlite3") as database:
        attempts = database.execute(
            "SELECT attempt_ordinal,allowance_used FROM model_operation"
        ).fetchone()
        assert attempts == (4, 4), attempts
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
        endpoint = Endpoint(tls, 100, sse=True, observed_shape=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            stalled_capture(root, endpoint, after_progress)
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)


def main():
    observed_only = len(sys.argv) == 3 and sys.argv[2] == "--observed-shape-only"
    assert len(sys.argv) == 2 or observed_only
    with tempfile.TemporaryDirectory(prefix="rui-h2-") as tmp:
        root = pathlib.Path(tmp)
        if not observed_only:
            queued_h1(root)
            queued_h1_inactivity(root)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
            "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(root / "cert.pem", root / "key.pem")
        tls.set_alpn_protocols(["h2"])
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
        for after_progress in (False, True):
            endpoint = Endpoint(tls, 100, sse=True, after_progress=after_progress)
            thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            try:
                stalled_capture(root, endpoint, after_progress)
            finally:
                endpoint.shutdown()
                endpoint.server_close()
                thread.join(timeout=5)
        endpoint = Endpoint(tls, 20, sse=True, eager_sse=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            paused_capture_inactivity(root, endpoint)
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
        endpoint = Endpoint(tls, 20, sse=True, eager_sse=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            capture_failure_on_resume(root, endpoint)
        finally:
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)
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
    main()
