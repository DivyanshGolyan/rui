#!/usr/bin/env python3
"""Disposable HTTP/2 receive-credit latency comparison against the real Host."""
import hashlib
import json
import pathlib
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time

import h2.config
import h2.connection
import h2.events

import dispatch_integration as dispatch
from host_process import HostDiagnostics


ANSWER = "X" * (128 * 1024)
PAYLOAD, _, _ = dispatch.sse_answer("response", "reasoning", "message", ANSWER)


class Endpoint(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, tls, update_delay):
        super().__init__(("127.0.0.1", 0), Handler)
        self.tls = tls
        self.update_delay = update_delay
        self.ready = threading.Event()
        self.release = threading.Event()
        self.request_sha256 = None
        self.streams = 0
        self.updates = 0

    def get_request(self):
        sock, address = super().get_request()
        return self.tls.wrap_socket(sock, server_side=True), address


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        assert sock.selected_alpn_protocol() == "h2"
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(60)
        conn = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=False))
        conn.initiate_connection()
        sock.sendall(conn.data_to_send())
        body = bytearray()
        stream = None
        remaining = None
        while True:
            data = sock.recv(65536)
            if not data:
                return
            for event in conn.receive_data(data):
                if isinstance(event, h2.events.RequestReceived):
                    assert stream is None
                    stream = event.stream_id
                    self.server.streams += 1
                elif isinstance(event, h2.events.DataReceived):
                    body.extend(event.data)
                    conn.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, h2.events.StreamEnded):
                    assert event.stream_id == stream
                    self.server.request_sha256 = hashlib.sha256(body).hexdigest()
                    self.server.ready.set()
                    assert self.server.release.wait(30), "response not released"
                    conn.send_headers(stream, [
                        (":status", "200"), ("content-type", "text/event-stream"),
                        ("content-length", str(len(PAYLOAD))),
                    ])
                    remaining = PAYLOAD
                elif isinstance(event, h2.events.WindowUpdated) and remaining is not None and event.stream_id == stream:
                    self.server.updates += 1
                    time.sleep(self.server.update_delay)
            while remaining:
                credit = min(conn.local_flow_control_window(stream), conn.max_outbound_frame_size, len(remaining))
                if not credit:
                    break
                conn.send_data(stream, remaining[:credit], end_stream=credit == len(remaining))
                remaining = remaining[credit:]
            pending = conn.data_to_send()
            if pending:
                sock.sendall(pending)


def run(binary, update_delay, iteration):
    with tempfile.TemporaryDirectory(prefix="rui-window-latency-") as directory:
        root = pathlib.Path(directory)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
            "-days", "1", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(root / "cert.pem", root / "key.pem")
        tls.set_alpn_protocols(["h2"])
        endpoint = Endpoint(tls, update_delay)
        server_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        server_thread.start()
        store = root / "store"
        host = dispatch.start_host(store, f"https://localhost:{endpoint.server_address[1]}/responses",
                                   "--provider-ca-file", str(root / "cert.pem"), "--test-phase-trace",
                                   active_capacity=1)
        diagnostics = HostDiagnostics(host)
        try:
            dispatch.configure(root, store, "config", "direct/latency", "model-a")
            dispatch.message(root, store, "message", "direct/latency", "latency")
            assert endpoint.ready.wait(30), "H2 request not ready"
            started = time.monotonic_ns()
            endpoint.release.set()
            diagnostics.wait("model_settlement_committed", timeout=60)
            elapsed_ms = (time.monotonic_ns() - started) / 1_000_000
            result = dispatch.observe(store, "message")["result"]
            assert result["status"] == "completed", result
            assert dispatch.read_result(store, "message") == ANSWER.encode()
            execution = dispatch.command("inspect-session", "--store", store,
                                         "--session", "direct/latency")["execution"]
            assert execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0", execution
            assert endpoint.streams == 1 and endpoint.updates > 0 and endpoint.request_sha256 is not None
            return {"iteration": iteration, "update_delay_ms": update_delay * 1000,
                    "settlement_ms": elapsed_ms, "window_updates": endpoint.updates,
                    "request_sha256": endpoint.request_sha256,
                    "response_sha256": hashlib.sha256(PAYLOAD).hexdigest()}
        finally:
            endpoint.release.set()
            dispatch.stop_host(host)
            diagnostics.close()
            endpoint.shutdown()
            endpoint.server_close()
            server_thread.join(timeout=5)


if __name__ == "__main__":
    binary = pathlib.Path(sys.argv[1]).resolve()
    for delay in (0, 0.025):
        for index in range(3):
            print(json.dumps(run(binary, delay, index), sort_keys=True), flush=True)
