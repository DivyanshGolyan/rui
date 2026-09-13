#!/usr/bin/env python3
"""Measure issue-172 production transport, scratch, descriptor and custody growth."""

import http.server
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import time


PAYLOAD_BYTES = (0, 1024 * 1024, 8 * 1024 * 1024)
CAPACITIES = (1, 16, 256, 1000)


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def footprint_bytes(report, name):
    match = re.search(rf"{name}:\s+([0-9.]+) (B|KB|MB|GB)", report)
    if match is None:
        raise RuntimeError(f"could not parse macOS {name} counter")
    scale = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}[match.group(2)]
    return round(float(match.group(1)) * scale)


def cpu_seconds(pid):
    fields = command("ps", "-o", "time=", "-p", str(pid)).split(":")
    seconds = float(fields[-1])
    if len(fields) >= 2:
        seconds += int(fields[-2]) * 60
    if len(fields) == 3:
        seconds += int(fields[0]) * 3600
    return seconds


def sample(pid):
    rss_kib, virtual_kib = map(int, command("ps", "-o", "rss=,vsz=", "-p", str(pid)).split())
    report = command("/usr/bin/footprint", "-p", str(pid))
    lsof = command("/usr/sbin/lsof", "-n", "-P", "-p", str(pid)).splitlines()
    return {
        "rss_bytes": rss_kib * 1024,
        "virtual_bytes": virtual_kib * 1024,
        "physical_footprint_bytes": footprint_bytes(report, "phys_footprint"),
        "lifetime_peak_physical_footprint_bytes": footprint_bytes(report, "phys_footprint_peak"),
        "open_descriptor_rows": max(0, len(lsof) - 1),
        "open_request_file_descriptors": sum("request-" in line for line in lsof),
    }


class Endpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.requests = []
        self.release = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.server.requests.append(len(body))
        if not self.server.release.wait(20):
            raise RuntimeError("measurement response was never released")
        result = b'{"error":"measured failure"}'
        self.send_response(422)
        self.send_header("Content-Length", str(len(result)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(result)
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def run(binary, *args):
    return subprocess.check_output([str(binary), *map(str, args)], text=True)


def execution(binary, store, session):
    return json.loads(run(binary, "inspect-session", "--store", store, "--session", session))[
        "execution"
    ]


def start_host(binary, store, endpoint, capacity, cleanup_ms=0):
    args = [
        str(binary), "serve", "--store", str(store), "--active-capacity", str(capacity),
        "--provider-endpoint", endpoint,
    ]
    if cleanup_ms:
        args += ["--test-cleanup-delay-ms", str(cleanup_ms)]
    host = subprocess.Popen(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    ready = host.stdout.readline().strip()
    if not ready.startswith("ready "):
        raise RuntimeError(host.stderr.read())
    fields = dict(value.split("=", 1) for value in ready.split()[1:])
    return host, fields


def stop(host):
    host.kill()
    host.wait()


def configure(binary, parent, store, key, session):
    answer = json.loads(run(
        binary, "configure", "--store", store, "--record", parent / f"{key}.json",
        "--key", key, "--session", session, "--workspace", pathlib.Path.cwd(), "--model", "model-a",
    ))
    if answer["answer"]["status"] != "accepted":
        raise RuntimeError(answer)


def message(binary, parent, store, key, session, size):
    source = parent / f"{key}.txt"
    with source.open("wb") as output:
        block = b"m" * 65536
        remaining = size
        while remaining:
            chunk = block[: min(remaining, len(block))]
            output.write(chunk)
            remaining -= len(chunk)
    answer = json.loads(run(
        binary, "message", "--store", store, "--record", parent / f"{key}.json",
        "--key", key, "--session", session, "--text", source,
    ))
    if answer["answer"]["status"] != "accepted":
        raise RuntimeError(answer)


def wait_for(predicate, description, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.025)
    raise RuntimeError(f"timed out waiting for {description}")


def request_count_or_host_error(endpoint_server, host, count):
    if host.poll() is not None:
        raise RuntimeError(f"Host exited during dispatch: {host.stderr.read()}")
    return len(endpoint_server.requests) == count


def idle_capacity(binary, root, endpoint):
    rows = []
    for capacity in CAPACITIES:
        host, ready = start_host(binary, root / f"idle-{capacity}", endpoint, capacity)
        try:
            cpu_before = cpu_seconds(host.pid)
            started = time.monotonic()
            time.sleep(2)
            elapsed = time.monotonic() - started
            cpu_percent = 100 * (cpu_seconds(host.pid) - cpu_before) / elapsed
            if cpu_percent >= 1:
                raise RuntimeError(
                    f"idle capacity {capacity} consumed {cpu_percent:.3f}% of one core"
                )
            rows.append({
                "active_capacity": capacity,
                "custody_record_bytes": int(ready["custody_record_bytes"]),
                "execution_slot_bytes": int(ready["execution_slot_bytes"]),
                "idle_cpu_percent_one_core": round(cpu_percent, 3),
                "idle_cpu_sample_seconds": round(elapsed, 3),
                **sample(host.pid),
            })
        finally:
            stop(host)
    return rows


def request_growth(binary, root, endpoint_server, endpoint):
    rows = []
    for size in PAYLOAD_BYTES:
        endpoint_server.requests.clear()
        endpoint_server.release.clear()
        store = root / f"payload-{size}"
        host, ready = start_host(binary, store, endpoint, 1, cleanup_ms=3000)
        try:
            session = f"measure/payload-{size}"
            configure(binary, root, store, f"config-{size}", session)
            message(binary, root, store, f"message-{size}", session, size)
            wait_for(
                lambda: request_count_or_host_error(endpoint_server, host, 1),
                "request materialization",
            )
            in_flight_execution = execution(binary, store, session)
            in_flight = sample(host.pid)
            endpoint_server.release.set()
            time.sleep(0.15)
            delayed_cleanup_execution = execution(binary, store, session)
            delayed_cleanup = sample(host.pid)
            rows.append({
                "input_bytes": size,
                "endpoint_request_bytes": endpoint_server.requests[0],
                "scratch_limit_bytes": int(ready["scratch_limit_bytes"]),
                "in_flight_execution": in_flight_execution,
                "in_flight": in_flight,
                "saved_failure_delayed_cleanup_execution": delayed_cleanup_execution,
                "saved_failure_delayed_cleanup": delayed_cleanup,
            })
        finally:
            endpoint_server.release.set()
            stop(host)
    return rows


def overlap(binary, root, endpoint_server, endpoint):
    endpoint_server.requests.clear()
    endpoint_server.release.clear()
    capacity = 8
    store = root / "overlap"
    host, ready = start_host(binary, store, endpoint, capacity)
    try:
        for index in range(capacity):
            session = f"measure/overlap-{index}"
            configure(binary, root, store, f"overlap-config-{index}", session)
            message(binary, root, store, f"overlap-message-{index}", session, 64 * 1024)
        wait_for(lambda: len(endpoint_server.requests) == capacity, "overlapping transfers")
        return {
            "active_capacity": capacity,
            "endpoint_requests": len(endpoint_server.requests),
            "execution": execution(binary, store, "measure/overlap-0"),
            "custody_record_bytes": int(ready["custody_record_bytes"]),
            "execution_slot_bytes": int(ready["execution_slot_bytes"]),
            **sample(host.pid),
        }
    finally:
        endpoint_server.release.set()
        stop(host)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: measure.py /absolute/path/to/latifa")
    if sys.platform != "darwin":
        raise SystemExit("measure-model-dispatch currently requires macOS footprint counters")
    binary = pathlib.Path(sys.argv[1]).resolve()
    endpoint_server = Endpoint()
    endpoint_thread = threading.Thread(target=endpoint_server.serve_forever, daemon=True)
    endpoint_thread.start()
    endpoint = f"http://127.0.0.1:{endpoint_server.server_port}/responses"
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="latifa-dispatch-measure-") as temporary:
            root = pathlib.Path(temporary)
            result = {
                "scope": "issue-172 production frozen-request dispatch",
                "status": "passed",
                "tested_revision": command("git", "rev-parse", "HEAD"),
                "working_tree_dirty": bool(command("git", "status", "--porcelain")),
                "binary_sha256": command("shasum", "-a", "256", str(binary)).split()[0],
                "zig": command("zig", "version"),
                "platform": command("uname", "-a"),
                "transport": {"curl": "8.22.0", "openssl": "3.6.3", "resolver": "threaded"},
                "idle_capacity_growth": idle_capacity(binary, root, endpoint),
                "request_growth_and_delayed_cleanup": request_growth(binary, root, endpoint_server, endpoint),
                "overlapping_transport": overlap(binary, root, endpoint_server, endpoint),
                "elapsed_seconds": round(time.monotonic() - started, 3),
                "limits": [
                    "macOS Apple Silicon runtime evidence only; supported Linux and x86 targets are compile-only",
                    "endpoint is deterministic loopback HTTP and qualifies no TLS trust store or live provider behavior",
                    "idle CPU is process CPU-time growth over a two-second quiet interval and must remain below 1% of one core",
                    "custody and scratch use are exported runtime counters sampled through inspect-session",
                    "lsof rows include libraries and SQLite descriptors; request-named rows identify already-unlinked request scratch still held by a descriptor",
                    "process termination is crash evidence, not power-loss qualification",
                ],
            }
            print(json.dumps(result, indent=2))
    finally:
        endpoint_server.release.set()
        endpoint_server.shutdown()
        endpoint_server.server_close()
        endpoint_thread.join(timeout=5)


if __name__ == "__main__":
    main()
