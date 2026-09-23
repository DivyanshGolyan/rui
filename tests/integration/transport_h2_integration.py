#!/usr/bin/env python3
"""Native owner/ALPN/stream witness; requires h2==4.3.0 and OpenSSL CLI."""
import json
import os
import pathlib
import socketserver
import sqlite3
import ssl
import subprocess
import tempfile
import threading

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

    def __init__(self, tls, population, refuse_at=None, dead_reuse=False, bad_header=False, drop_once=False, sse=False, isolation=None):
        super().__init__(("127.0.0.1", 0), StreamHandler)
        self.tls = tls
        self.population = population
        self.connections = []
        self.streams = []
        self.refuse_at = refuse_at
        self.refused = False
        self.dead_reuse = dead_reuse
        self.bad_header = bad_header
        self.drop_once = drop_once
        self.dropped = False
        self.sse = sse
        self.answers = {}
        self.isolation = isolation
        self.stream_ids = {}
        self.resets = []
        self.ready = threading.Event()
        self.lock = threading.Lock()

    def get_request(self):
        sock, address = super().get_request()
        return self.tls.wrap_socket(sock, server_side=True), address


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
                    pending.append(event.stream_id)
                    if len(pending) == self.server.population:
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
                                payload, _, _ = dispatch.sse_answer(
                                    f"response-{stream}", f"reasoning-{stream}",
                                    f"message-{stream}", self.server.answers[text].decode(),
                                )
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


def round_trip(root, endpoint, capacity):
    store = root / f"store-{capacity}"
    host = dispatch.start_host(
        store,
        f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file",
        str(root / "cert.pem"),
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
            observation = dispatch.command(
                "inspect-session", "--store", store, "--session", f"direct/h2-{capacity}-0"
            )["execution"]
            assert observation["custody_occupied"] == "0", observation
            assert observation["scratch_used_bytes"] == "0", observation
            if os.path.isdir(f"/proc/{host.pid}/fd"):
                idle_fds.append(len(os.listdir(f"/proc/{host.pid}/fd")))
        if idle_fds:
            assert idle_fds[1] <= idle_fds[0], idle_fds
        streams = list(endpoint.streams)
        assert len(streams) == 2 * capacity
        assert len({(address, stream) for address, stream, _, _ in streams}) == len(streams)
        assert {text for _, _, text, _ in streams} == {
            f"h2-{capacity}-{round_number}-{index}"
            for round_number in range(2) for index in range(capacity)
        }
        assert len(endpoint.connections) == 1, endpoint.connections
        print(json.dumps({
            "capacity": capacity, "rounds": 2, "alpn": "h2",
            "tcp_connections": len(endpoint.connections), "streams": len(streams),
            "request_bytes": sum(len(body) for _, _, _, body in streams),
            "completed_idle_fds": idle_fds or None,
        }), flush=True)
    finally:
        dispatch.stop_host(host)


def stalled_capture(root, endpoint):
    store = root / "stalled-capture-store"
    gate = root / "capture-write-gate"
    os.mkfifo(gate)
    keeper = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
    host = dispatch.start_host(
        store, f"https://localhost:{endpoint.server_address[1]}/responses",
        "--provider-ca-file", str(root / "cert.pem"),
        "--test-response-capture-gate-path", str(gate), "--test-phase-trace", active_capacity=100,
    )
    diagnostics = HostDiagnostics(host)
    released = False
    try:
        for index in range(100):
            session = f"direct/stalled-{index}"
            dispatch.configure(root, store, f"stalled-config-{index}", session, "model-a")
            dispatch.message(root, store, f"stalled-message-{index}", session, f"stalled-{index}")
        dispatch.wait_for(lambda: len(endpoint.streams) == 100, "100 live H2 streams", timeout=45)
        diagnostics.wait("capture_write_gate_entered", timeout=30)
        processing = dispatch.observe(store, "stalled-message-0")["processing"]
        reply = dispatch.command(
            "interrupt-model", "--store", store, "--record", root / "stalled-interrupt.json",
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
        print(json.dumps({"case": "stalled_local_capture", "live_streams": 100,
                          "connections": 1, "control_before_release": True,
                          "stalled_host_rss_kib": stalled_rss_kib,
                          "completed_idle_host_rss_kib": idle_rss_kib}), flush=True)
    finally:
        if not released:
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
        with sqlite3.connect(store / "rui.sqlite3") as database:
            attempts = database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation"
            ).fetchone()
            assert attempts == (1, 1), attempts
        assert len(endpoint.streams) == 2, endpoint.streams
        assert [text for _, _, text, _ in endpoint.streams] == (
            [None, "refused-request"] if phase == "headers" else ["refused-request"] * 2
        )
        assert len(endpoint.connections) == 2, endpoint.connections
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
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation "
                "WHERE session_ref='direct/dead'"
            ).fetchone() == (2, 2)
        assert [text for _, _, text, _ in endpoint.streams] == ["warm", "dead", "dead"]
        assert endpoint.streams[0][0] == endpoint.streams[1][0]
        assert endpoint.streams[2][0] != endpoint.streams[1][0]
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
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation ORDER BY operation_id"
            ).fetchall() == [(1, 1), (1, 1)]
            if mode == "cancel":
                assert database.execute(
                    "SELECT interrupted_by_command_key FROM model_operation WHERE session_ref='direct/target'"
                ).fetchone() == ("cancel-interrupt",)
        execution = dispatch.command(
            "inspect-session", "--store", store, "--session", "direct/target"
        )["execution"]
        assert execution["custody_occupied"] == "0", execution
        assert execution["scratch_used_bytes"] == "0", execution
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
        with sqlite3.connect(store / "rui.sqlite3") as database:
            assert database.execute(
                "SELECT attempt_ordinal,allowance_used FROM model_operation ORDER BY operation_id"
            ).fetchall() == [(2, 2), (2, 2)]
        assert len(endpoint.streams) == 4, endpoint.streams
        assert sorted(text for _, _, text, _ in endpoint.streams) == ["drop-0", "drop-0", "drop-1", "drop-1"]
        observation = dispatch.command(
            "inspect-session", "--store", store, "--session", "direct/drop-0"
        )["execution"]
        assert observation["custody_occupied"] == "0", observation
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


def main():
    with tempfile.TemporaryDirectory(prefix="rui-h2-") as tmp:
        root = pathlib.Path(tmp)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
            "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(root / "cert.pem", root / "key.pem")
        tls.set_alpn_protocols(["h2"])
        for capacity in (1, 100):
            endpoint = Endpoint(tls, capacity, sse=True)
            thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            try:
                round_trip(root, endpoint, capacity)
            finally:
                endpoint.shutdown()
                endpoint.server_close()
                thread.join(timeout=5)
        endpoint = Endpoint(tls, 100, sse=True)
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        try:
            stalled_capture(root, endpoint)
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
        unsupported_https(root)


if __name__ == "__main__":
    main()
