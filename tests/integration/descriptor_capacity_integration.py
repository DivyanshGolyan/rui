#!/usr/bin/env python3
import http.server
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time

from host_process import HostDiagnostics, start_ready_process, stop_process


RUI = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()


class HeldEndpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), HeldHandler)
        self.condition = threading.Condition()
        self.requests = 0
        self.completed = 0
        self.release = threading.Event()

    def wait_for(self, field, count, timeout=10):
        deadline = time.monotonic() + timeout
        with self.condition:
            while getattr(self, field) < count:
                remaining = deadline - time.monotonic()
                assert remaining > 0, f"timed out waiting for {field}={count}"
                self.condition.wait(remaining)


class HeldHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        self.rfile.read(length)
        with self.server.condition:
            self.server.requests += 1
            self.server.condition.notify_all()
        assert self.server.release.wait(10), "provider fixture was never released"
        body = b'{"error":"descriptor capacity fixture"}'
        self.send_response(422)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
        with self.server.condition:
            self.server.completed += 1
            self.server.condition.notify_all()

    def log_message(self, _format, *_args):
        pass


def limited_host(limit, *arguments):
    return [
        "sh",
        "-c",
        'ulimit -n "$1"; shift; exec "$@"',
        "rui-descriptor-limit",
        str(limit),
        str(RUI),
        *map(str, arguments),
    ]


def command(state, *arguments):
    completed = subprocess.run(
        [str(RUI), *map(str, arguments)],
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert completed.returncode == 0, completed.stderr
    return json.loads(completed.stdout)


def configure(state, store, ordinal):
    session = f"direct/descriptors-{ordinal}"
    result = command(
        state,
        "configure",
        "--store",
        store,
        "--record",
        state / f"configure-{ordinal}.json",
        "--key",
        f"configure-{ordinal}",
        "--session",
        session,
        "--workspace",
        ROOT,
        "--model",
        "model-a",
    )
    assert result["answer"]["status"] == "accepted", result
    return session


def message(state, store, session, ordinal):
    text = state / f"message-{ordinal}.txt"
    text.write_text(f"descriptor fill {ordinal}")
    result = command(
        state,
        "message",
        "--store",
        store,
        "--record",
        state / f"message-{ordinal}.json",
        "--key",
        f"message-{ordinal}",
        "--session",
        session,
        "--text",
        text,
    )
    assert result["answer"]["status"] == "accepted", result


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="rui-descriptor-capacity-"))
    state.chmod(0o700)
    endpoint = HeldEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    host = None
    diagnostics = None
    try:
        required = 72 if sys.platform == "darwin" else 70
        rejected_store = state / "rejected-store"
        rejected = subprocess.run(
            limited_host(
                required - 1,
                "serve",
                "--store",
                rejected_store,
                "--active-capacity",
                "2",
                "--provider-endpoint",
                f"http://127.0.0.1:{endpoint.server_port}/responses",
            ),
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert rejected.returncode != 0, rejected.stdout
        assert not rejected.stdout.startswith("ready "), rejected.stdout
        assert "descriptor capacity insufficient" in rejected.stderr, rejected.stderr
        assert f"required={required}" in rejected.stderr, rejected.stderr
        assert f"soft_limit={required - 1}" in rejected.stderr, rejected.stderr
        assert not rejected_store.exists(), "descriptor rejection followed startup side effects"

        store = state / "adequate-store"
        host, ready = start_ready_process(
            limited_host(
                required,
                "serve",
                "--store",
                store,
                "--active-capacity",
                "2",
                "--provider-endpoint",
                f"http://127.0.0.1:{endpoint.server_port}/responses",
            ),
            required_fields={
                "descriptor_requirement": str(required),
                "descriptor_limit": str(required),
            },
        )
        diagnostics = HostDiagnostics(host)
        sessions = [configure(state, store, ordinal) for ordinal in range(3)]
        message(state, store, sessions[0], 0)
        message(state, store, sessions[1], 1)
        endpoint.wait_for("requests", 2)
        assert host.poll() is None, diagnostics.tail()

        endpoint.release.set()
        endpoint.wait_for("completed", 2)
        message(state, store, sessions[2], 2)
        endpoint.wait_for("requests", 3)
        endpoint.wait_for("completed", 3)
        assert host.poll() is None, diagnostics.tail()
    finally:
        if host is not None:
            stop_process(host)
        if diagnostics is not None:
            diagnostics.close()
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=3)
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
