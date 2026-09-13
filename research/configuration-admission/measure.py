#!/usr/bin/env python3
"""Measure the issue-170 production Host at dormant-Session idle points on macOS."""

import json
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time


SESSION_COUNTS = (0, 100, 1_000, 10_000)


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
    expected = int(length_line.split(b":", 1)[1])
    if len(raw_body) != expected:
        raise RuntimeError("incomplete response framing")
    return json.loads(raw_body)


def database_size(store: pathlib.Path) -> dict[str, int]:
    stat = (store / "latifa.sqlite3").stat()
    return {
        "database_logical_bytes": stat.st_size,
        "database_allocated_bytes": stat.st_blocks * 512,
    }


def client_peak(binary: pathlib.Path, store: pathlib.Path) -> int:
    result = subprocess.run(
        [
            "/usr/bin/time",
            "-l",
            str(binary),
            "inspect-session",
            "--store",
            str(store),
            "--session",
            "measure/00000000",
        ],
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=True,
    )
    match = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
    if match is None:
        raise RuntimeError("could not parse direct-client peak RSS")
    return int(match.group(1))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: measure.py /absolute/path/to/latifa")
    if sys.platform != "darwin":
        raise SystemExit("measure-admission currently requires macOS footprint counters")
    binary = pathlib.Path(sys.argv[1]).resolve()
    workspace = pathlib.Path.cwd().resolve()
    started = time.monotonic()
    stages = []
    with tempfile.TemporaryDirectory(prefix="latifa-configuration-measure-") as temporary:
        store = pathlib.Path(temporary) / "store"
        host = subprocess.Popen(
            [str(binary), "serve", "--store", str(store), "--active-capacity", "1000"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            ready = host.stdout.readline().strip()
            if not ready.startswith("ready "):
                raise RuntimeError(host.stderr.read())
            canonical_store = re.search(r"store=([^ ]+)", ready).group(1)
            socket_path = re.search(r"socket=([^ ]+)", ready).group(1)
            admitted = 0
            for target in SESSION_COUNTS:
                while admitted < target:
                    identity = f"measure/{admitted:08d}"
                    answer = exchange(
                        socket_path,
                        "/v1/configure",
                        {
                            "version": "1",
                            "kind": "configure",
                            "store": canonical_store,
                            "key": identity,
                            "session": identity,
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
                    if answer["answer"]["status"] != "accepted":
                        raise RuntimeError(answer)
                    admitted += 1
                time.sleep(0.1)
                stages.append(
                    {
                        "dormant_sessions": admitted,
                        **sample_process(host.pid),
                        **database_size(store),
                    }
                )
            result = {
                "scope": "issue-170 production Host configuration admission",
                "status": "passed",
                "tested_revision": command("git", "rev-parse", "HEAD"),
                "working_tree_dirty": bool(command("git", "status", "--porcelain")),
                "binary": str(binary),
                "binary_sha256": command("shasum", "-a", "256", str(binary)).split()[0],
                "zig": command("zig", "version"),
                "platform": command("uname", "-a"),
                "active_capacity": 1_000,
                "stages": stages,
                "direct_client_peak_rss_bytes": client_peak(binary, store),
                "elapsed_seconds": round(time.monotonic() - started, 3),
                "limits": [
                    "macOS-only physical-footprint evidence on the available Apple Silicon host",
                    "sequential configuration then idle sampling; not concurrent connection qualification",
                    "allocator-live, private-dirty, descriptor and SQLite high-water counters are unavailable here",
                    "direct-client RSS is separate and may double-count shared pages if added to Host footprint",
                    "process termination is crash evidence, not power-loss qualification",
                ],
            }
            print(json.dumps(result, indent=2))
        finally:
            host.kill()
            host.wait()


if __name__ == "__main__":
    main()
