#!/usr/bin/env python3
"""Matched macOS CPU diagnostic over the existing 100-session H2 churn oracle.

Reported footprint is diagnostic only: the canonical Go gate separately rejects
inconsistent current/lifetime-peak counters on the measured baseline platform.
"""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import time
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tests/integration"))
import transport_h2_integration as fixture


def cpu_seconds(text):
    parts = text.strip().split(":")
    assert len(parts) in (2, 3), text
    total = 0.0
    for part in parts:
        total = total * 60 + float(part)
    return total


def main():
    assert sys.platform == "darwin" and len(sys.argv) == 3
    binary, output = map(lambda p: Path(p).resolve(), sys.argv[1:])
    assert not output.exists()
    result = {"status": "failed", "scope": "macOS CPU diagnostic; not memory qualification",
              "platform": platform.platform(), "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "source_sha256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in (Path(__file__), Path(fixture.__file__), Path(fixture.dispatch.__file__))},
              "drains": []}
    original = fixture.round_trip

    def observed(*args, **kwargs):
        def sample(pid, wave):
            started = time.monotonic_ns()
            raw = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "time="], text=True)
            result["drains"].append({"wave": wave, "query_start_ns": started,
                                     "query_end_ns": time.monotonic_ns(), "ps_cpu_time": raw.strip(),
                                     "cpu_seconds": cpu_seconds(raw)})
        peak = original(*args, **kwargs, observe=sample)
        result["reported_footprint_peak_bytes"] = peak
        return peak

    fixture.dispatch.RUI = binary
    try:
        with patch.object(sys, "argv", [sys.argv[0], str(binary), "--observed-shape-churn"]), \
             patch.object(fixture, "round_trip", observed):
            fixture.main()
        assert [r["wave"] for r in result["drains"]] == list(range(21))
        result["complete_work_cpu_seconds"] = result["drains"][-1]["cpu_seconds"] - result["drains"][0]["cpu_seconds"]
        result["status"] = "behavior_passed"
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
