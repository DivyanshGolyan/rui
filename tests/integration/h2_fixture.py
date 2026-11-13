"""The h2 model endpoint and Host request helpers that the transport and Codex H2
fixtures share."""
import json
import os_semantics
import socketserver
import threading
import time

import h2.config
import h2.connection
import h2.errors
import h2.events
import h2.settings

import control_fixture as control
import host_process
import model_fixture as dispatch


class Endpoint(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, tls, population, refuse_at=None, dead_reuse=False, bad_header=False, drop_once=False, sse=False, isolation=None, after_progress=False, early_protocol_error=False, eager_sse=False, observed_shape=False, held=False, flow_probe=False):
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
        # The body a GET of a model list is answered with; None answers 404.
        self.models = None
        self.catalog = None
        self.catalog_etag = '"catalog-v1"'
        self.catalog_release = None
        self.catalog_responses = []
        # Set: a model list GET waits unanswered until the event is set.
        self.models_release = None
        # Set: each connection allows this many concurrent streams.
        self.max_streams = None
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
        # Flow probe: "quick" is answered at once; "flow" gets its head, then
        # waits for `flow_release` before its long body and a PING follow.
        self.flow_probe = flow_probe
        self.flow_release = threading.Event()
        self.flow_ping_acked = threading.Event()
        self.flow_body_sent = threading.Event()
        # Isolation: the sibling's answer, queued when the target resets, is
        # withheld until `isolation_release` is set.
        self.isolation_release = threading.Event()
        self.ready = threading.Event()
        self.lock = threading.Lock()

    def get_request(self):
        sock, address = super().get_request()
        return self.tls.wrap_socket(sock, server_side=True), address


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


class StreamHandler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        assert sock.selected_alpn_protocol() == "h2"
        sock.settimeout(45)
        conn = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False))
        conn.initiate_connection()
        if self.server.max_streams is not None:
            conn.update_settings({h2.settings.SettingCodes.MAX_CONCURRENT_STREAMS: self.server.max_streams})
        if self.server.refuse_at == "headers" and not self.server.refused:
            conn.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 0})
        sock.sendall(conn.data_to_send())
        bodies = {}
        pending = []
        outgoing_bodies = {}
        held_bodies = {}
        held_models = []
        flow_bodies = {}
        isolation_bodies = {}
        flow_open = set()
        get_headers = {}

        def answer_models(stream_id):
            headers = get_headers.pop(stream_id)
            is_catalog = headers[b":path"] == b"/api.json"
            with self.server.lock:
                models = self.server.catalog if is_catalog else self.server.models
                etag = self.server.catalog_etag if is_catalog else None
            unchanged = etag is not None and headers.get(b"if-none-match") == etag.encode()
            payload = b"" if unchanged else models if models is not None else b"{}"
            status = "304" if unchanged else "200" if models is not None else "404"
            if is_catalog:
                # Record the selected reply before sending it, independently
                # of teardown or the Host consuming the body.
                with self.server.lock:
                    self.server.catalog_responses.append({"headers": headers, "status": status, "etag": etag})
            fields = [(":status", status), ("content-type", "application/json")]
            if etag is not None:
                fields.append(("etag", etag))
            if not unchanged:
                fields.append(("content-length", str(len(payload))))
            conn.send_headers(stream_id, fields, end_stream=not payload)
            if payload:
                outgoing_bodies[stream_id] = payload
        def listing_release(stream_id):
            if get_headers[stream_id][b":path"] == b"/api.json" and self.server.catalog_release is not None:
                return self.server.catalog_release
            return self.server.models_release

        with self.server.lock:
            self.server.connections.append(self.client_address)
        while True:
            try:
                data = sock.recv(65536)
            except TimeoutError:
                if not held_bodies and not held_models and not flow_bodies and not isolation_bodies:
                    return
                data = None  # Polling for release.
            except OSError:
                return
            if data == b"":
                return
            for stream_id in held_models[:]:
                release = listing_release(stream_id)
                if release is None or release.is_set():
                    held_models.remove(stream_id)
                    answer_models(stream_id)
            if not held_models and not held_bodies and not isolation_bodies and not flow_bodies:
                sock.settimeout(45)
            if held_bodies and self.server.release.is_set():
                outgoing_bodies.update(held_bodies)
                held_bodies.clear()
                sock.settimeout(45)
            if isolation_bodies and self.server.isolation_release.is_set():
                outgoing_bodies.update(isolation_bodies)
                isolation_bodies.clear()
                sock.settimeout(45)
            if flow_bodies and self.server.flow_release.is_set():
                outgoing_bodies.update(flow_bodies)
                flow_open.update(flow_bodies)
                flow_bodies.clear()
                conn.ping(b"rui-flow")
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
                    if dict(event.headers)[b":method"] == b"GET":
                        # A listing: it has no body and is not a model request.
                        get_headers[event.stream_id] = dict(event.headers)
                        release = listing_release(event.stream_id)
                        if release is not None and not release.is_set():
                            held_models.append(event.stream_id)
                            sock.settimeout(0.05)  # Poll for release.
                        else:
                            answer_models(event.stream_id)
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
                            elif self.server.flow_probe and text == "flow":
                                # Many times one stream's 16-KiB receive window.
                                answer = "F" * 256 * 1024
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
                                if self.server.flow_probe and text == "flow":
                                    flow_bodies[stream] = payload
                                    sock.settimeout(0.05)  # Poll for release.
                                    continue
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
                elif isinstance(event, h2.events.PingAckReceived):
                    if event.ping_data == b"rui-flow":
                        self.server.flow_ping_acked.set()
                elif isinstance(event, h2.events.StreamReset):
                    with self.server.lock:
                        self.server.resets.append(event.stream_id)
                    outgoing_bodies.pop(event.stream_id, None)
                    held_bodies.pop(event.stream_id, None)
                    if event.stream_id in held_models:
                        held_models.remove(event.stream_id)
                    if self.server.isolation and event.stream_id == self.server.stream_ids["isolation-target"]:
                        payload, _, _ = dispatch.sse_answer(
                            "sibling", "reasoning-sibling", "message-sibling", "unaffected sibling",
                        )
                        isolation_bodies[self.server.stream_ids["isolation-sibling"]] = payload
                        sock.settimeout(0.05)  # Poll for release.
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
            for stream in [stream for stream in flow_open if stream not in outgoing_bodies]:
                flow_open.discard(stream)
                self.server.flow_body_sent.set()
            outgoing = conn.data_to_send()
            if outgoing:
                sock.sendall(outgoing)
            if self.server.isolation and not pending and len(self.server.stream_ids) == 2:
                self.server.ready.set()
            if held_bodies and not outgoing_bodies and not self.server.held.is_set():
                # Every held prefix is on the wire; poll for release.
                self.server.held.set()
                sock.settimeout(0.05)


def closed_host_request(socket_path, store, kind, *, timeout=15, deadline=None, **fields):
    if deadline is not None:
        deadline = min(deadline, time.monotonic() + timeout)
    payload = json.dumps({"version": host_process.WIRE_VERSION, "kind": kind, "store": str(store.resolve()),
                          **fields}, separators=(",", ":")).encode()
    with os_semantics.unix_stream() as connection:
        def set_timeout():
            remaining = timeout if deadline is None else min(timeout, deadline - time.monotonic())
            assert remaining > 0, "Host request exhausted original deadline"
            connection.settimeout(remaining)

        set_timeout()
        connection.connect(socket_path)
        set_timeout()
        connection.sendall(
            f"POST /v1/{kind.replace('_', '-')} HTTP/1.1\r\n".encode()
            + b"Content-Type: application/json\r\nX-Rui-Wire-Version: " + host_process.WIRE_VERSION.encode() + b"\r\n"
            # A Message carries the sending terminal's environment; these carry none.
            + (b"X-Rui-Environment-Bytes: 0\r\n" if kind == "message" else b"")
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
