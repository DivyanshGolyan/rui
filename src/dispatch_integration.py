#!/usr/bin/env python3
import http.server
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


LATIFA = pathlib.Path(sys.argv[1]).resolve()
ROOT = pathlib.Path.cwd()


class FailureEndpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FailureHandler)
        self.requests = []
        self.received = threading.Event()
        self.release = threading.Event()


class FailureHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        body = self.rfile.read(length)
        self.server.requests.append(body)
        self.server.received.set()
        if not self.server.release.wait(10):
            raise RuntimeError("fixture response was never released")
        payload = b'{"error":"deterministic permanent failure"}'
        self.send_response(422)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

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


def start_host(store, endpoint, *extra):
    process = subprocess.Popen(
        [
            str(LATIFA),
            "serve",
            "--store",
            str(store),
            "--active-capacity",
            "1",
            "--provider-endpoint",
            endpoint,
            *extra,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        line = process.stdout.readline()
        if line.startswith("ready "):
            if "execution=enabled" not in line or "curl=8.22.0" not in line:
                raise AssertionError(f"missing transport readiness evidence: {line}")
            return process
        if process.poll() is not None:
            raise AssertionError(f"Host exited before ready: {process.stderr.read()}")
    raise AssertionError("Host did not become ready")


def stop_host(process):
    if process.poll() is None:
        process.kill()
    process.wait(timeout=10)


def configure(state, store, key, session, model, schema=None):
    record = state / f"{key}.json"
    args = [
        "configure",
        "--store",
        store,
        "--record",
        record,
        "--key",
        key,
        "--session",
        session,
        "--workspace",
        ROOT,
        "--model",
        model,
    ]
    if schema is not None:
        schema_path = state / f"{key}-schema.json"
        schema_path.write_text(json.dumps(schema, separators=(",", ":")))
        args += ["--output-schema", schema_path]
    result = command(*args)
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


def main():
    state = pathlib.Path(tempfile.mkdtemp(prefix="latifa-dispatch."))
    endpoint = FailureEndpoint()
    endpoint_thread = threading.Thread(target=endpoint.serve_forever, daemon=True)
    endpoint_thread.start()
    url = f"http://127.0.0.1:{endpoint.server_port}/responses"
    processes = []
    try:
        # A committed permit launches exactly one complete frozen request. The
        # endpoint holds the response so later settings and input arrive while
        # the admitted request is demonstrably in flight.
        store = state / "frozen-store"
        host = start_host(store, url, "--test-cleanup-delay-ms", "3000")
        processes.append(host)
        output_schema = {
            "type": "object",
            "properties": {"answer": {"type": "string"}},
            "required": ["answer"],
            "additionalProperties": False,
        }
        configure(state, store, "config-a", "direct/main", "model-a", output_schema)
        message(state, store, "message-a", "direct/main", 'first "message"\n')
        if not endpoint.received.wait(8):
            raise AssertionError("endpoint did not receive committed request")
        configure(state, store, "config-b", "direct/main", "model-b")
        message(state, store, "message-b", "direct/main", "later message")
        assert len(endpoint.requests) == 1
        endpoint.release.set()
        failed = wait_for(
            lambda: (value := observe(store, "message-a"))["status"] == "accepted"
            and value.get("result", {}).get("code") == "provider_http_422"
            and value,
            "saved permanent failure",
        )
        assert failed["queue"]["status"] == "failed", failed
        assert failed["processing"]["attempt"] == "1", failed
        later = observe(store, "message-b")
        assert later["queue"]["status"] == "queued", later
        assert len(endpoint.requests) == 1, "a permit launched more than once"

        observed = json.loads(endpoint.requests[0])
        expected = {
            "model": "model-a",
            "store": False,
            "stream": True,
            "include": ["reasoning.encrypted_content"],
            "input": [
                {"role": "system", "content": [{"type": "input_text", "text": ""}]},
                {
                    "role": "user",
                    "content": [{"type": "input_text", "text": 'first "message"\n'}],
                },
            ],
            "tools": [
                {"type": "function", "name": "bash", "description": "Run Bash"},
                {"type": "function", "name": "edit", "description": "Edit one file"},
            ],
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "latifa_output",
                    "strict": True,
                    "schema": output_schema,
                }
            },
        }
        assert observed == expected, (observed, expected)
        stop_host(host)
        processes.remove(host)

        # Killing the execution owner cannot erase the saved result or admit
        # input beyond the first Operation's cutoff.
        offline = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline)
        assert offline.stdout.readline().startswith("ready ")
        assert observe(store, "message-a")["result"]["code"] == "provider_http_422"
        assert observe(store, "message-b")["queue"]["status"] == "queued"
        stop_host(offline)
        processes.remove(offline)

        # One reactor fills two fixed custody records without allocating a
        # worker per Session. Both requests reach the endpoint before either
        # response is released.
        endpoint.received.clear()
        endpoint.release.clear()
        endpoint.requests.clear()
        capacity_store = state / "capacity-store"
        host = start_host(capacity_store, url, "--active-capacity", "2")
        processes.append(host)
        configure(state, capacity_store, "capacity-config-a", "direct/capacity-a", "model-a")
        configure(state, capacity_store, "capacity-config-b", "direct/capacity-b", "model-a")
        message(state, capacity_store, "capacity-message-a", "direct/capacity-a", "alpha")
        message(state, capacity_store, "capacity-message-b", "direct/capacity-b", "beta")
        wait_for(lambda: len(endpoint.requests) == 2, "two concurrent reactor requests")
        endpoint.release.set()
        wait_for(
            lambda: observe(capacity_store, "capacity-message-a").get("result", {}).get("code")
            == "provider_http_422",
            "first concurrent failure",
        )
        wait_for(
            lambda: observe(capacity_store, "capacity-message-b").get("result", {}).get("code")
            == "provider_http_422",
            "second concurrent failure",
        )
        stop_host(host)
        processes.remove(host)

        # A failed Attempt commit rolls back all provenance and cannot produce
        # an endpoint launch.
        endpoint.received.clear()
        endpoint.release.clear()
        endpoint.requests.clear()
        rollback_store = state / "rollback-store"
        host = start_host(rollback_store, url, "--fault", "attempt-before-commit")
        processes.append(host)
        configure(state, rollback_store, "rollback-config", "direct/rollback", "model-a")
        message(state, rollback_store, "rollback-message", "direct/rollback", "rollback")
        time.sleep(0.35)
        assert endpoint.requests == []
        assert observe(rollback_store, "rollback-message")["queue"]["status"] == "queued"
        stop_host(host)
        processes.remove(host)

        # The first fallible post-commit step consumes Attempt 1, saves a typed
        # failure, releases custody, and never reaches HTTP.
        first_store = state / "first-step-store"
        host = start_host(first_store, url, "--fault", "request-first-step")
        processes.append(host)
        configure(state, first_store, "first-config", "direct/first", "model-a")
        message(state, first_store, "first-message", "direct/first", "first step")
        failed = wait_for(
            lambda: (value := observe(first_store, "first-message"))["status"] == "accepted"
            and value.get("result", {}).get("code") == "request_preparation_failed"
            and value,
            "saved first-step preparation failure",
        )
        assert failed["processing"]["attempt"] == "1", failed
        assert endpoint.requests == []
        stop_host(host)
        processes.remove(host)

        for fault, expected_code in (
            ("request-scratch-acquire", "request_scratch_exhausted"),
            ("request-write", "request_write_failed"),
            ("request-seal", "request_seal_failed"),
        ):
            fault_store = state / f"{fault}-store"
            host = start_host(fault_store, url, "--fault", fault)
            processes.append(host)
            configure(state, fault_store, f"{fault}-config", f"direct/{fault}", "model-a")
            message(state, fault_store, f"{fault}-message", f"direct/{fault}", fault)
            failed = wait_for(
                lambda key=f"{fault}-message", code=expected_code: (
                    value := observe(fault_store, key)
                )["status"]
                == "accepted"
                and value.get("result", {}).get("code") == code
                and value,
                f"saved {fault} failure",
            )
            assert failed["processing"]["attempt"] == "1", failed
            assert endpoint.requests == []
            stop_host(host)
            processes.remove(host)

        # A canonical save fault rolls back the claimed failure, fences the
        # live dispatch owner, and leaves the admitted Attempt uncertain for
        # the following retry/restart slice rather than recreating its permit.
        endpoint.requests.clear()
        endpoint.release.set()
        save_store = state / "save-fault-store"
        host = start_host(save_store, url, "--fault", "result-before-commit")
        processes.append(host)
        configure(state, save_store, "save-config", "direct/save", "model-a")
        message(state, save_store, "save-message", "direct/save", "save fault")
        wait_for(lambda: len(endpoint.requests) == 1, "save-fault endpoint request")
        time.sleep(0.2)
        failed_observation = subprocess.run(
            [str(LATIFA), "observe-command", "--store", str(save_store), "--key", "save-message"],
            text=True,
            capture_output=True,
            timeout=10,
        )
        assert failed_observation.returncode != 0, failed_observation.stdout
        assert len(endpoint.requests) == 1
        stop_host(host)
        processes.remove(host)

        offline = subprocess.Popen(
            [str(LATIFA), "serve", "--store", str(save_store), "--active-capacity", "1"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        processes.append(offline)
        assert offline.stdout.readline().startswith("ready ")
        uncertain = observe(save_store, "save-message")
        assert uncertain["queue"]["status"] == "processing", uncertain
        assert uncertain["processing"]["attempt"] == "1", uncertain
        assert "result" not in uncertain, uncertain
        stop_host(offline)
        processes.remove(offline)
    finally:
        for process in processes:
            stop_host(process)
        endpoint.shutdown()
        endpoint.server_close()
        endpoint_thread.join(timeout=5)
        shutil.rmtree(state)


if __name__ == "__main__":
    main()
