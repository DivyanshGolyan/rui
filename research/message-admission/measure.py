#!/usr/bin/env python3
"""Measure issue-171 message admission and observation scaling on macOS."""

import json
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time


PAYLOAD_BYTES = (0, 4 * 1024, 8 * 1024 * 1024, 32 * 1024 * 1024)
HISTORY_COUNTS = (0, 100, 1_000, 10_000)


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def footprint_bytes(report: str, name: str) -> int:
    match = re.search(rf"{name}:\s+([0-9.]+) (B|KB|MB|GB)", report)
    if match is None:
        raise RuntimeError(f"could not parse macOS {name} counter")
    multiplier = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3}[match.group(2)]
    return round(float(match.group(1)) * multiplier)


def sample_process(pid: int) -> dict[str, int]:
    rss_kib, virtual_kib = map(
        int,
        command("ps", "-o", "rss=,vsz=", "-p", str(pid)).split(),
    )
    report = command("/usr/bin/footprint", "-p", str(pid))
    return {
        "rss_bytes": rss_kib * 1024,
        "virtual_bytes": virtual_kib * 1024,
        "physical_footprint_bytes": footprint_bytes(report, "phys_footprint"),
        "lifetime_peak_physical_footprint_bytes": footprint_bytes(report, "phys_footprint_peak"),
    }


def database_size(store: pathlib.Path) -> dict[str, int]:
    stat = (store / "latifa.sqlite3").stat()
    return {
        "database_logical_bytes": stat.st_size,
        "database_allocated_bytes": stat.st_blocks * 512,
    }


def exchange(socket_path: str, route: str, value: dict) -> dict:
    body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    header = (
        f"POST {route} HTTP/1.1\r\n"
        "Host: local\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        "X-Latifa-Wire-Version: 1\r\n"
        "Connection: close\r\n\r\n"
    ).encode()
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(socket_path)
        client.sendall(header)
        client.sendall(body)
        chunks = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    response = b"".join(chunks)
    raw_header, raw_body = response.split(b"\r\n\r\n", 1)
    lines = raw_header.split(b"\r\n")
    if not lines[0].startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(response.decode(errors="replace"))
    length_line = next(line for line in lines if line.lower().startswith(b"content-length:"))
    if len(raw_body) != int(length_line.split(b":", 1)[1]):
        raise RuntimeError("incomplete response framing")
    return json.loads(raw_body)


def timed_exchange(socket_path: str, route: str, value: dict) -> tuple[dict, float]:
    started = time.monotonic()
    result = exchange(socket_path, route, value)
    return result, round((time.monotonic() - started) * 1_000, 3)


def configure(socket_path: str, store: str, workspace: pathlib.Path, session: str) -> None:
    result = exchange(
        socket_path,
        "/v1/configure",
        {
            "version": "1",
            "kind": "configure",
            "store": store,
            "key": f"configure-{session}",
            "session": session,
            "configuration": {
                "workspace": {"state": "value", "value": str(workspace)},
                "model": {"state": "value", "value": "measurement-model"},
                "instructions": {"state": "omitted"},
                "tools": {"state": "omitted"},
                "permission_mode": {"state": "omitted"},
                "output_schema": {"state": "omitted"},
            },
        },
    )
    if result["answer"]["status"] != "accepted":
        raise RuntimeError(result)


def start_host(binary: pathlib.Path, store: pathlib.Path) -> tuple[subprocess.Popen, str, str]:
    host = subprocess.Popen(
        [str(binary), "serve", "--store", str(store), "--active-capacity", "1000"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    ready = host.stdout.readline().strip()
    if not ready.startswith("ready "):
        raise RuntimeError(host.stderr.read())
    canonical_store = re.search(r"store=([^ ]+)", ready).group(1)
    socket_path = re.search(r"socket=([^ ]+)", ready).group(1)
    return host, canonical_store, socket_path


def message_value(store: str, key: str, session: str, text: str) -> dict:
    return {
        "version": "1",
        "kind": "message",
        "store": store,
        "key": key,
        "session": session,
        "text": {"state": "value", "value": text},
    }


def observe_value(store: str, key: str) -> dict:
    return {"version": "1", "kind": "observe_command", "store": store, "key": key}


def inspect_value(store: str, session: str) -> dict:
    return {"version": "1", "kind": "inspect_session", "store": store, "session": session}


def payload_profile(binary: pathlib.Path, workspace: pathlib.Path, parent: pathlib.Path) -> list[dict]:
    store = parent / "payload-store"
    host, canonical_store, socket_path = start_host(binary, store)
    try:
        session = "measure/payload"
        configure(socket_path, canonical_store, workspace, session)
        stages = []
        for size in PAYLOAD_BYTES:
            key = f"payload-{size}"
            answer, admission_ms = timed_exchange(
                socket_path,
                "/v1/message",
                message_value(canonical_store, key, session, "p" * size),
            )
            if answer["answer"]["status"] != "accepted" or answer["input"]["bytes"] != str(size):
                raise RuntimeError(answer)
            observation, observation_ms = timed_exchange(
                socket_path,
                "/v1/observe-command",
                observe_value(canonical_store, key),
            )
            if observation["observation"]["queue"]["status"] != "queued":
                raise RuntimeError(observation)
            time.sleep(0.05)
            stages.append(
                {
                    "payload_bytes": size,
                    "queued_messages": len(stages) + 1,
                    "admission_elapsed_ms": admission_ms,
                    "observation_elapsed_ms": observation_ms,
                    **sample_process(host.pid),
                    **database_size(store),
                }
            )
        return stages
    finally:
        host.kill()
        host.wait()


def history_profile(binary: pathlib.Path, workspace: pathlib.Path, parent: pathlib.Path) -> list[dict]:
    store = parent / "history-store"
    host, canonical_store, socket_path = start_host(binary, store)
    try:
        session = "measure/history"
        configure(socket_path, canonical_store, workspace, session)
        stages = []
        admitted = 0
        last_admission_ms = None
        for target in HISTORY_COUNTS:
            while admitted < target:
                key = f"history-{admitted:08d}"
                answer, last_admission_ms = timed_exchange(
                    socket_path,
                    "/v1/message",
                    message_value(canonical_store, key, session, ""),
                )
                if answer["answer"]["status"] != "accepted":
                    raise RuntimeError(answer)
                admitted += 1
            inspected, inspect_ms = timed_exchange(
                socket_path,
                "/v1/inspect-session",
                inspect_value(canonical_store, session),
            )
            if inspected["pending_messages"] != str(admitted):
                raise RuntimeError(inspected)
            stage = {
                "queued_messages": admitted,
                "last_admission_elapsed_ms": last_admission_ms,
                "session_observation_elapsed_ms": inspect_ms,
            }
            if admitted:
                oldest, oldest_ms = timed_exchange(
                    socket_path,
                    "/v1/observe-command",
                    observe_value(canonical_store, "history-00000000"),
                )
                newest, newest_ms = timed_exchange(
                    socket_path,
                    "/v1/observe-command",
                    observe_value(canonical_store, f"history-{admitted - 1:08d}"),
                )
                if oldest["observation"]["queue"]["status"] != "queued" or newest["observation"]["queue"]["status"] != "queued":
                    raise RuntimeError("queued observation changed under history growth")
                stage["oldest_observation_elapsed_ms"] = oldest_ms
                stage["newest_observation_elapsed_ms"] = newest_ms
            time.sleep(0.05)
            stages.append({**stage, **sample_process(host.pid), **database_size(store)})
        return stages
    finally:
        host.kill()
        host.wait()


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: measure.py /absolute/path/to/latifa")
    if sys.platform != "darwin":
        raise SystemExit("measure-message-admission currently requires macOS footprint counters")
    binary = pathlib.Path(sys.argv[1]).resolve()
    workspace = pathlib.Path.cwd().resolve()
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="latifa-message-measure-") as temporary:
        parent = pathlib.Path(temporary)
        result = {
            "scope": "issue-171 production Host message admission and observation",
            "status": "passed",
            "tested_revision": command("git", "rev-parse", "HEAD"),
            "working_tree_dirty": bool(command("git", "status", "--porcelain")),
            "binary": str(binary),
            "binary_sha256": command("shasum", "-a", "256", str(binary)).split()[0],
            "zig": command("zig", "version"),
            "platform": command("uname", "-a"),
            "active_capacity": 1_000,
            "client_capacity": {"total": 128, "ordinary": 120, "control_headroom": 8},
            "content_window_bytes": 4_096,
            "sqlite_heap_limit_bytes": 16 * 1024 * 1024,
            "payload_growth": payload_profile(binary, workspace, parent),
            "queued_history_growth": history_profile(binary, workspace, parent),
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "limits": [
                "macOS-only runtime and physical-footprint evidence on the available Apple Silicon host",
                "Linux and other macOS targets are compile-only in this checkout",
                "payload and history grow in separate fresh Stores at fixed configured capacities",
                "measurement-client payload construction is outside the measured Host process",
                "sequential one-exchange connections do not qualify simultaneous 128-client behavior beyond the process integration gate",
                "allocator-live, private-dirty, descriptor and SQLite high-water counters are unavailable here",
                "model processing is intentionally unavailable; no provider or execution resources are measured",
                "process termination is crash evidence, not power-loss qualification",
            ],
        }
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
