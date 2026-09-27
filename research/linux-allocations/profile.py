#!/usr/bin/env python3
"""Diagnostic wrapper over the existing Linux/H2 workload; arguments match run.py.

Requires heaptrack 1.5.0 and stop_profiler.so beside this file. Evidence is
requested heap bytes, not uninstrumented footprint or semantic ownership.
"""
import hashlib
import json
import os
from pathlib import Path
import sys
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests/qualification/linux-memory"))
import run as workload


def main():
    assert "--probe" not in sys.argv and "--trim-after" not in sys.argv
    out = Path(sys.argv[sys.argv.index("--output") + 1]).resolve()
    collector = Path(os.environ.get("HEAPTRACK_PRELOAD", "/usr/lib/heaptrack/libheaptrack_preload.so")).resolve()
    controller = Path(__file__).with_name("stop_profiler.so").resolve()
    start = workload.fixture.dispatch.start_ready_process
    round_trip = workload.fixture.round_trip
    evidence = {"instrumented": True, "scope": "heaptrack allocation origins; final live snapshot before Host kill, not a leak verdict",
                "source_sha256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in (Path(__file__), Path(__file__).with_name("stop_profiler.c"), collector, controller)},
                "phases": []}

    def start_host(*args, **kwargs):
        os.mkfifo(out / "stop.fifo", 0o600)
        with patch.dict(os.environ, {"LD_PRELOAD": f"{collector}:{controller}",
                                    "DUMP_HEAPTRACK_OUTPUT": str(out / "heaptrack.raw"),
                                    "RUI_HEAPTRACK_STOP_FIFO": str(out / "stop.fifo"),
                                    "RUI_HEAPTRACK_STOP_ACK": str(out / "stopped")}):
            host, ready = start(*args, **kwargs)
        try:
            evidence["pid"] = host.pid
            maps = Path(f"/proc/{host.pid}/maps").read_text()
            assert str(collector) in maps and str(controller) in maps
            return host, ready
        except BaseException:
            workload.fixture.dispatch.stop_process(host)
            raise

    def observed_trip(root, endpoint, capacity, ca_file, rounds=2, *, observe=None):
        def sample(pid, wave):
            observe(pid, wave)
            evidence["phases"].append({"wave": wave, "monotonic_ns": time.monotonic_ns()})
            if wave == rounds:
                fd = os.open(out / "stop.fifo", os.O_WRONLY | os.O_NONBLOCK)
                try:
                    assert os.write(fd, b"s") == 1
                finally:
                    os.close(fd)
                deadline = time.monotonic() + 10
                while not (out / "stopped").exists():
                    assert time.monotonic() < deadline, "heaptrack did not stop/flush"
                    time.sleep(0.01)
        return round_trip(root, endpoint, capacity, ca_file, rounds, observe=sample)

    try:
        with patch.object(workload.fixture.dispatch, "start_ready_process", start_host), \
             patch.object(workload.fixture, "round_trip", observed_trip):
            workload.main()
        evidence["status"] = "behavior_passed"
    finally:
        if out.is_dir():
            evidence.setdefault("status", "failed")
            (out / "profile.json").write_text(json.dumps(evidence, indent=2))
            result_path = out / "result.json"
            if result_path.exists():
                result = json.loads(result_path.read_text())
                result.update(instrumented=True, probe_scope=evidence["scope"])
                result_path.write_text(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
