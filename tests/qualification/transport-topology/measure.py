#!/usr/bin/env python3
"""Disposable Rui #263 topology measurement; not a production qualification gate."""
import hashlib
import http.server
import json
import pathlib
import re
import ssl
import subprocess
import sys
import tempfile
import threading
import time

import dispatch_integration as dispatch
import transport_h2_integration as h2_fixture


class H1Endpoint(http.server.ThreadingHTTPServer):
    request_queue_size = 128
    daemon_threads = True

    def __init__(self, tls):
        super().__init__(("127.0.0.1", 0), H1Handler)
        self.tls = tls
        self.lock = threading.Lock()
        self.ready = threading.Event()
        self.release = threading.Event()
        self.requests = {}
        self.connections = set()
        self.payload_hashes = {}

    def get_request(self):
        sock, address = super().get_request()
        try:
            return self.tls.wrap_socket(sock, server_side=True), address
        except BaseException:
            sock.close()
            raise


class H1Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        assert self.connection.selected_alpn_protocol() == "http/1.1"
        assert self.path == "/responses"
        body = self.rfile.read(int(self.headers["Content-Length"]))
        text = user_text(body)
        with self.server.lock:
            assert text not in self.server.requests
            self.server.requests[text] = body
            self.server.connections.add(self.client_address)
            if len(self.server.requests) == 100:
                self.server.ready.set()
        assert self.server.release.wait(90), "H1 measurement gate not released"
        answer = answer_for(text)
        payload = response_for(text, answer)
        with self.server.lock:
            self.server.payload_hashes[text] = hashlib.sha256(payload).hexdigest()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def log_message(self, *_):
        pass


def user_text(body):
    request = json.loads(body)
    return next(item["content"][0]["text"] for item in reversed(request["input"])
                if item.get("role") == "user")


def answer_for(text):
    return f"answer-{text}" if int(text.rsplit("-", 1)[1]) % 2 else "L" * 8192 + text


def response_for(text, answer):
    return dispatch.sse_answer(f"response-{text}", f"reasoning-{text}",
                               f"message-{text}", answer)[0]


def sample(pid, out, phase):
    measurements = {"phase": phase, "timestamp_unix": time.time(), "pid": pid}
    for name, argv in (
        ("footprint", ["/usr/bin/footprint", "-f", "bytes", "-p", str(pid)]),
        ("lsof", ["/usr/sbin/lsof", "-n", "-P", "-p", str(pid)]),
        ("rss", ["/bin/ps", "-o", "rss=", "-p", str(pid)]),
        ("children", ["/usr/bin/pgrep", "-P", str(pid)]),
    ):
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        (out / f"{phase}-{name}.txt").write_text(completed.stdout + completed.stderr)
        measurements[name + "_exit"] = completed.returncode
        if name not in ("children",) and completed.returncode:
            raise RuntimeError(f"{name}: {completed.stderr}")
        if name == "footprint":
            for key in ("phys_footprint", "phys_footprint_peak"):
                measurements[key] = int(re.search(rf"^\s*{key}: (\d+) B$", completed.stdout, re.M).group(1))
        elif name == "lsof":
            measurements["descriptor_rows"] = len(completed.stdout.splitlines()) - 1
            measurements["numbered_fds"] = sum(bool(re.fullmatch(r"\d+[rwu]?", line.split()[3]))
                                                   for line in completed.stdout.splitlines()[1:])
        elif name == "rss":
            measurements["rss_kib"] = int(completed.stdout.strip())
        elif name == "children":
            measurements["child_pids"] = completed.stdout.split()
    print(json.dumps(measurements), flush=True)
    return measurements


def main():
    binary, topology, upload, output = sys.argv[1:5]
    assert topology in ("h1", "h2") and int(upload) in (16384, 65536)
    out = pathlib.Path(output)
    out.mkdir(parents=True, exist_ok=False)
    (out / "binary.sha256").write_text(hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest() + "\n")
    with tempfile.TemporaryDirectory(prefix="rui-topology-") as tmp:
        root = pathlib.Path(tmp)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem"),
                        "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(root / "cert.pem", root / "key.pem")
        tls.set_alpn_protocols(["http/1.1" if topology == "h1" else "h2"])
        endpoint = H1Endpoint(tls) if topology == "h1" else h2_fixture.Endpoint(tls, 100, sse=True)
        if topology == "h2":
            endpoint.release = threading.Event()
            endpoint.payload_hashes = {}
        thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
        thread.start()
        store = root / "store"
        host = dispatch.start_host(store, f"https://localhost:{endpoint.server_address[1]}/responses",
                                   "--provider-ca-file", str(root / "cert.pem"), active_capacity=100)
        try:
            for index in range(100):
                text = f"compare-{index}"
                dispatch.configure(root, store, f"config-{index}", f"direct/{text}", "model-a")
                dispatch.message(root, store, f"message-{index}", f"direct/{text}", text)
            assert endpoint.ready.wait(45), "100 requests not simultaneously live"
            requests = endpoint.requests if topology == "h1" else {
                text: body for _, _, text, body in endpoint.streams
            }
            assert set(requests) == {f"compare-{i}" for i in range(100)}, len(requests)
            assert all(user_text(body) == text for text, body in requests.items())
            hashes = {text: hashlib.sha256(body).hexdigest() for text, body in sorted(requests.items())}
            (out / "request-hashes.json").write_text(json.dumps(hashes, sort_keys=True, indent=2) + "\n")
            live = sample(host.pid, out, "live")
            endpoint.release.set()
            for index in range(100):
                key = f"message-{index}"
                result = dispatch.wait_for(lambda key=key: dispatch.observe(store, key).get("result"),
                                           f"result {key}", timeout=60)
                assert result["status"] == "completed", result
                assert dispatch.read_result(store, key) == answer_for(f"compare-{index}").encode(), key
            expected_payload_hashes = {
                f"compare-{i}": hashlib.sha256(response_for(f"compare-{i}", answer_for(f"compare-{i}"))).hexdigest()
                for i in range(100)
            }
            assert endpoint.payload_hashes == expected_payload_hashes, "server response bytes differ"
            (out / "response-hashes.json").write_text(json.dumps(endpoint.payload_hashes, sort_keys=True, indent=2) + "\n")
            execution = dispatch.command("inspect-session", "--store", store,
                                         "--session", "direct/compare-0")["execution"]
            assert execution["custody_occupied"] == "0" and execution["scratch_used_bytes"] == "0", execution
            time.sleep(.25)
            execution = dispatch.command("inspect-session", "--store", store,
                                         "--session", "direct/compare-0")["execution"]
            assert execution["custody_occupied"] == "0", execution
            idle = sample(host.pid, out, "serviced-idle")
            connections = len(endpoint.connections)
            assert connections == (100 if topology == "h1" else 1), connections
            if topology == "h2":
                assert len(endpoint.streams) == 100
                assert len({stream for _, stream, _, _ in endpoint.streams}) == 100
            summary = {"topology": topology, "upload_bytes": int(upload),
                       "request_count": len(requests), "connections": connections,
                       "streams": 100 if topology == "h2" else None,
                       "response_sha256": hashlib.sha256(json.dumps(endpoint.payload_hashes, sort_keys=True).encode()).hexdigest(),
                       "requests_sha256": hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest(),
                       "live": live, "serviced_idle": idle}
            (out / "summary.json").write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
            print(json.dumps(summary), flush=True)
        finally:
            endpoint.release.set()
            dispatch.stop_host(host)
            endpoint.shutdown()
            endpoint.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    main()
