#!/usr/bin/env python3
"""Measure issue-173 production output capture, import, and retained-idle growth."""

import argparse
import hashlib
import http.server
import json
import pathlib
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time


ANSWER_BYTES = (1024, 1024 * 1024, 8 * 1024 * 1024)
REASONING_ITEMS = (1, 128, 1000)


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def footprint_bytes(report, name):
    match = re.search(rf"{name}:\s+([0-9.]+) (B|KB|MB|GB)", report)
    if match is None:
        raise RuntimeError(f"could not parse macOS {name} counter")
    scale = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}[match.group(2)]
    return round(float(match.group(1)) * scale)


def sample(pid):
    rss_kib, virtual_kib = map(int, command("ps", "-o", "rss=,vsz=", "-p", str(pid)).split())
    report = command("/usr/bin/footprint", "-p", str(pid))
    descriptors = command("/usr/sbin/lsof", "-n", "-P", "-p", str(pid)).splitlines()
    return {
        "rss_bytes": rss_kib * 1024,
        "virtual_bytes": virtual_kib * 1024,
        "physical_footprint_bytes": footprint_bytes(report, "phys_footprint"),
        "lifetime_peak_physical_footprint_bytes": footprint_bytes(report, "phys_footprint_peak"),
        "open_descriptor_rows": max(0, len(descriptors) - 1),
        "open_response_file_descriptors": sum("response-" in row for row in descriptors),
    }


def encode_sse(response_id, reasoning_count, answer):
    items = []
    events = []
    for index in range(reasoning_count):
        item = {
            "type": "reasoning",
            "id": f"{response_id}-reasoning-{index}",
            "summary": [],
            "encrypted_content": f"private-{index}",
            "extension": {"ordinal": index},
        }
        items.append(item)
        events.extend(
            (
                {
                    "type": "response.output_item.added",
                    "output_index": index,
                    "item": {"type": "reasoning", "id": item["id"]},
                },
                {"type": "response.output_item.done", "output_index": index, "item": item},
            )
        )
    message = {
        "type": "message",
        "id": f"{response_id}-message",
        "role": "assistant",
        "content": [{"type": "output_text", "text": answer, "annotations": []}],
    }
    items.append(message)
    events.extend(
        (
            {
                "type": "response.output_item.added",
                "output_index": reasoning_count,
                "item": {"type": "message", "id": message["id"]},
            },
            {
                "type": "response.output_item.done",
                "output_index": reasoning_count,
                "item": message,
            },
            {
                "type": "response.completed",
                "response": {
                    "id": response_id,
                    "status": "completed",
                    "model": "model-a-served",
                    "output": items,
                    "usage": {"input_tokens": 7, "output_tokens": 11, "total_tokens": 18},
                },
            },
        )
    )
    return b"".join(
        b"data: " + json.dumps(event, separators=(",", ":")).encode() + b"\n\n"
        for event in events
    ) + b"data: [DONE]\n\n"


class Endpoint(http.server.ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.payload = None
        self.requests = []
        self.lock = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        request = self.rfile.read(int(self.headers["Content-Length"]))
        with self.server.lock:
            payload = self.server.payload
            if payload is None:
                raise RuntimeError("measurement request had no response")
            self.server.payload = None
            self.server.requests.append(len(request))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Request-Id", f"measurement-{len(self.server.requests)}")
        self.send_header("OpenAI-Model", "model-a-served")
        self.send_header("Connection", "close")
        self.end_headers()
        for offset in range(0, len(payload), 64 * 1024):
            try:
                self.wfile.write(payload[offset : offset + 64 * 1024])
            except (BrokenPipeError, ConnectionResetError):
                break
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass


def run(binary, *args, binary_output=False):
    return subprocess.check_output([str(binary), *map(str, args)], text=not binary_output)


def start_host(binary, store, endpoint):
    host = subprocess.Popen(
        [
            str(binary),
            "serve",
            "--store",
            str(store),
            "--active-capacity",
            "1",
            "--provider-endpoint",
            endpoint,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    ready = host.stdout.readline().strip()
    if not ready.startswith("ready "):
        raise RuntimeError(host.stderr.read())
    return host, dict(field.split("=", 1) for field in ready.split()[1:])


def stop(host):
    host.kill()
    host.wait(timeout=10)


def submit(binary, root, store, key, session):
    configured = json.loads(
        run(
            binary,
            "configure",
            "--store",
            store,
            "--record",
            root / f"{key}-configure.json",
            "--key",
            f"{key}-configure",
            "--session",
            session,
            "--workspace",
            pathlib.Path.cwd(),
            "--model",
            "model-a",
            "--tools",
            "none",
        )
    )
    if configured["answer"]["status"] != "accepted":
        raise RuntimeError(configured)
    source = root / f"{key}.txt"
    source.write_text("measure")
    admitted = json.loads(
        run(
            binary,
            "message",
            "--store",
            store,
            "--record",
            root / f"{key}.json",
            "--key",
            key,
            "--session",
            session,
            "--text",
            source,
        )
    )
    if admitted["answer"]["status"] != "accepted":
        raise RuntimeError(admitted)


def observation(binary, store, key):
    return json.loads(run(binary, "observe-command", "--store", store, "--key", key))[
        "observation"
    ]


def wait_complete(binary, store, key, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = observation(binary, store, key)
        if value.get("result", {}).get("status") == "completed":
            return value
        time.sleep(0.025)
    raise RuntimeError(f"timed out waiting for {key}")


def measure_case(binary, root, endpoint_server, endpoint, name, reasoning_count, answer):
    payload = encode_sse(name, reasoning_count, answer)
    endpoint_server.payload = payload
    store = root / name
    host, ready = start_host(binary, store, endpoint)
    try:
        cold = sample(host.pid)
        submit(binary, root, store, name, f"measure/{name}")
        wait_complete(binary, store, name)
        result = run(binary, "read-result", "--store", store, "--key", name, binary_output=True)
        if result != answer.encode():
            raise RuntimeError("saved result differs from response")
        execution = json.loads(
            run(binary, "inspect-session", "--store", store, "--session", f"measure/{name}")
        )["execution"]
        if execution["scratch_used_bytes"] != "0" or execution["custody_occupied"] != "0":
            raise RuntimeError(f"retained resources after completion: {execution}")
        database = sqlite3.connect(store / "latifa.sqlite3")
        counts = database.execute(
            "SELECT (SELECT count(*) FROM model_output_item), "
            "(SELECT count(*) FROM content WHERE private=1), "
            "(SELECT count(*) FROM conversation_entry WHERE entry_kind=3)"
        ).fetchone()
        database.close()
        retained = sample(host.pid)
        return {
            "answer_bytes": len(answer.encode()),
            "reasoning_items": reasoning_count,
            "total_output_items": reasoning_count + 1,
            "sse_bytes": len(payload),
            "request_bytes": endpoint_server.requests[-1],
            "scratch_limit_bytes": int(ready["scratch_limit_bytes"]),
            "canonical_output_items": counts[0],
            "private_content_rows": counts[1],
            "assistant_projections": counts[2],
            "database_bytes": (store / "latifa.sqlite3").stat().st_size,
            "cold": cold,
            "retained_idle": retained,
            "execution_after_completion": execution,
            "answer_sha256": hashlib.sha256(result).hexdigest(),
        }
    finally:
        stop(host)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("measure-model-output currently requires macOS footprint counters")
    if command("git", "status", "--porcelain"):
        raise SystemExit("measurement requires a clean working tree")
    endpoint_server = Endpoint()
    thread = threading.Thread(target=endpoint_server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"http://127.0.0.1:{endpoint_server.server_port}/responses"
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="latifa-output-measure-") as temporary:
            root = pathlib.Path(temporary)
            byte_rows = [
                measure_case(args.binary, root, endpoint_server, endpoint, f"bytes-{size}", 1, "x" * size)
                for size in ANSWER_BYTES
            ]
            item_rows = [
                measure_case(args.binary, root, endpoint_server, endpoint, f"items-{count}", count, "answer")
                for count in REASONING_ITEMS
            ]
            result = {
                "scope": "issue-173 production model-output capture, import, and retained idle",
                "status": "passed",
                "tested_revision": command("git", "rev-parse", "HEAD"),
                "working_tree_dirty": False,
                "binary_sha256": command("shasum", "-a", "256", str(args.binary.resolve())).split()[0],
                "zig": command("zig", "version"),
                "platform": command("uname", "-a"),
                "active_capacity": 1,
                "answer_byte_growth": byte_rows,
                "item_count_growth": item_rows,
                "elapsed_seconds": round(time.monotonic() - started, 3),
                "limits": [
                    "macOS Apple Silicon runtime evidence only; Linux and x86 targets are compile-only",
                    "deterministic loopback HTTP qualifies no TLS trust store, live provider, billing, or backend continuation",
                    "each row uses a fresh Store and Host so answer bytes and item count grow independently of durable history",
                    "physical footprint peak is the macOS lifetime counter; retained idle is sampled after canonical commit, result verification, zero scratch charge, and released custody",
                    "SQLite file bytes include complete private provider items and one public answer; rows do not isolate filesystem cache from process footprint",
                    "process termination and restart tests are crash evidence, not power-loss qualification",
                ],
            }
    finally:
        endpoint_server.shutdown()
        endpoint_server.server_close()
        thread.join(timeout=5)
    encoded = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()
