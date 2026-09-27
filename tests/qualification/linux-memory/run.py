#!/usr/bin/env python3
"""Linux allocator diagnostic using the unchanged larger-event H2 oracle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "integration"))
import transport_h2_integration as fixture


def counters(text):
    result = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 3 and fields[2] == "kB":
            key = fields[0].removesuffix(":")
            assert key not in result, key
            result[key] = int(fields[1]) * 1024
    return result


def sample(pid):
    root = Path(f"/proc/{pid}")
    memory = counters((root / "smaps_rollup").read_text())
    for key in ("Rss", "Pss", "Pss_Anon", "Pss_File", "Pss_Shmem", "Swap", "Private_Dirty"):
        assert key in memory, key
    status = counters((root / "status").read_text())
    assert "VmHWM" in status
    stat = (root / "stat").read_text().rsplit(")", 1)[1].split()
    return {"monotonic_ns": time.monotonic_ns(), "memory_bytes": memory,
            "approximate_rss_high_water_bytes": status["VmHWM"],
            "cpu_seconds": (int(stat[11]) + int(stat[12])) / os.sysconf("SC_CLK_TCK"),
            "fds": len(list((root / "fd").iterdir()))}


def system_snapshot():
    result = {"cgroup_scope": "mounted cgroup root; ancestor/system diagnostics, not Host-only",
              "sampler_cgroup": Path("/proc/self/cgroup").read_text()}
    for name in ("memory.events", "memory.current", "memory.swap.current", "memory.pressure", "cpu.stat", "cpu.max", "memory.max"):
        try:
            result[name] = Path("/sys/fs/cgroup", name).read_text()
        except FileNotFoundError:
            if name != "memory.pressure":
                raise
            result[name] = {"status": "unavailable", "reason": "kernel does not expose PSI"}
    result["meminfo"] = Path("/proc/meminfo").read_text()
    result["vmstat"] = Path("/proc/vmstat").read_text()
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tunables", default="")
    parser.add_argument("--capacity", type=int, default=100)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--probe", type=Path)
    parser.add_argument("--trim-after", action="store_true")
    args = parser.parse_args()
    assert sys.platform == "linux" and args.capacity > 0 and args.rounds > 0
    assert not args.trim_after or args.probe
    binary, out = args.binary.resolve(), args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    fixture.dispatch.RUI = binary
    result = {"status": "failed", "scope": "Linux diagnostic; no macOS physical-footprint verdict",
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "platform": list(os.uname()), "glibc": os.confstr("CS_GNU_LIBC_VERSION"),
              "requested_glibc_tunables": args.tunables, "capacity": args.capacity, "rounds": args.rounds,
              "sampling_interval_seconds": 0.1, "instrumented": args.probe is not None,
              "before": system_snapshot(), "drains": []}
    sources = [Path(__file__), Path(fixture.__file__), Path(fixture.dispatch.__file__), Path(__file__).with_name("malloc_probe.c")]
    if args.probe:
        sources.append(args.probe.resolve())
    result["source_sha256"] = {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    result["probe_scope"] = "perturbed glibc accounting; does not isolate tcache; not additive with RSS/PSS" if args.probe else "not loaded"
    stopped = threading.Event()
    worker = None
    errors = []
    peaks = {"Rss": 0, "Pss": 0, "Pss_Anon": 0, "Pss_File": 0, "Swap": 0}
    sample_count = 0

    def monitor(pid):
        nonlocal sample_count
        with (out / "samples.jsonl").open("w") as log:
            while not stopped.is_set():
                try:
                    value = sample(pid)
                    for key in peaks:
                        peaks[key] = max(peaks[key], value["memory_bytes"][key])
                    sample_count += 1
                    log.write(json.dumps(value) + "\n")
                except Exception as error:
                    errors.append(str(error))
                    break
                stopped.wait(0.1)

    def probe(pid, sequence, command):
        fifo = os.open(out / f"{pid}.command", os.O_WRONLY | os.O_NONBLOCK)
        try:
            assert os.write(fifo, command) == 1
        finally:
            os.close(fifo)
        snapshot = out / f"{pid}-{sequence}.json"
        deadline = time.monotonic() + 10
        while not snapshot.exists():
            assert time.monotonic() < deadline, "malloc probe did not respond"
            time.sleep(0.01)
        return json.loads(snapshot.read_text())

    def observe(pid, wave):
        nonlocal worker
        row = sample(pid)
        row["wave"] = wave
        result["drains"].append(row)
        for name in ("smaps", "status"):
            (out / f"wave-{wave}-{name}.txt").write_bytes(Path(f"/proc/{pid}/{name}").read_bytes())
        if wave == 0:
            result["host_pid"] = pid
            result["host_cgroup"] = Path(f"/proc/{pid}/cgroup").read_text()
            environment = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
            assert ("GLIBC_TUNABLES=" + args.tunables).encode() in environment
            if args.probe:
                assert str(args.probe.resolve()) in Path(f"/proc/{pid}/maps").read_text()
            worker = threading.Thread(target=monitor, args=(pid,))
            worker.start()
        if args.probe:
            row["malloc"] = probe(pid, wave + 1, b"s")
        if wave == args.rounds:
            stopped.set()
            worker.join(timeout=10)
            assert not worker.is_alive()
            if args.trim_after:
                result["trim"] = {"before": sample(pid), "malloc": probe(pid, wave + 2, b"t"), "after": sample(pid)}
        (out / "result.json").write_text(json.dumps(result, indent=2))

    original = fixture.dispatch.start_ready_process

    def start_host(*positional, **keywords):
        additions = {"GLIBC_TUNABLES": args.tunables, "LD_PRELOAD": ""}
        if args.probe:
            additions.update(LD_PRELOAD=str(args.probe.resolve()), RUI_MALLOC_AUDIT_DIR=str(out))
        with patch.dict(os.environ, additions):
            return original(*positional, **keywords)

    try:
        with tempfile.TemporaryDirectory(prefix="rui-linux-memory-", dir="/tmp") as temporary:
            root = Path(temporary)
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(root / "key.pem"),
                            "-out", str(root / "cert.pem"), "-days", "1", "-subj", "/CN=localhost",
                            "-addext", "subjectAltName=DNS:localhost"], check=True, capture_output=True)
            tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls.load_cert_chain(root / "cert.pem", root / "key.pem")
            tls.set_alpn_protocols(["h2"])
            endpoint = fixture.Endpoint(tls, args.capacity, sse=True, observed_shape=True)
            server = threading.Thread(target=endpoint.serve_forever, daemon=True)
            server.start()
            try:
                with patch.object(fixture.dispatch, "start_ready_process", start_host):
                    fixture.round_trip(root, endpoint, args.capacity, root / "cert.pem", args.rounds, observe=observe)
                result.update(status="behavior_passed", streams=len(endpoint.streams), connections=len(endpoint.connections),
                              request_bytes=sum(len(body) for _, _, _, body in endpoint.streams), offered_sse_bytes=endpoint.offered_bytes)
            finally:
                endpoint.shutdown()
                endpoint.server_close()
                server.join(timeout=5)
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        stopped.set()
        if worker:
            worker.join(timeout=10)
            assert not worker.is_alive(), "sampler did not stop"
        result.update(after=system_snapshot(), sampled_peak_bytes=peaks, sample_count=sample_count, sampling_errors=errors)
        if errors or sample_count == 0:
            result["status"] = "failed"
        (out / "result.json").write_text(json.dumps(result, indent=2))
    assert result["status"] == "behavior_passed", result


if __name__ == "__main__":
    main()
