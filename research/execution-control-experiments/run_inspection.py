"""Synthetic queue/inspection contention with local streams and an owned shell only."""
import argparse
import json
import os
import re
import signal
from pathlib import Path
import statistics
import subprocess
import tempfile
import time
from build_native import build, metadata, output

HERE = Path(__file__).resolve().parent


def invoke(binary, db, policy, rows, width, capacity, depth):
    args = list(map(str, (binary, db, policy, rows, width, capacity, depth)))
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        process.terminate()  # native handler kills/reaps its owned shell group
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, args, stdout, stderr)
    return json.loads(stdout) if policy != "seed" else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--sanitize", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--output", type=Path, default=HERE / "inspection-results.json")
    args = parser.parse_args()
    assert args.repeats > 0
    data = {"metadata": metadata(), "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "load_start": output("sysctl", "-n", "vm.loadavg"), "observations": []}
    cases = [(10000, 128, 10, 4), (0, 128, 100, 1), (1000, 128, 100, 4),
             (10000, 128, 100, 4), (100000, 128, 100, 4), (100000, 1024, 100, 4),
             (1000000, 128, 100, 1)]
    if args.smoke:
        cases = [(10000, 128, 10, 4)]
    with tempfile.TemporaryDirectory(prefix="onepage-inspection-load-") as temp:
        temp = Path(temp)
        binary = temp / "inspection"
        data["build"] = build(HERE / "inspection.c", binary, args.sanitize)
        cleanup_db = temp / "cleanup.db"
        invoke(binary, cleanup_db, "seed", 10000, 128, 10, 4)
        data["cleanup_checks"] = []
        for requested_signal in (signal.SIGABRT, signal.SIGTERM):
            env = dict(os.environ, ONEPAGE_PROBE_SIGNAL=str(int(requested_signal)))
            result = subprocess.run(list(map(str, (binary, cleanup_db, "fifo", 10000, 128, 10, 4))),
                                    env=env, text=True, capture_output=True, timeout=20)
            assert result.returncode == 128 + requested_signal, (result.returncode, result.stderr)
            assert "Assertion failed" not in result.stderr and "ERROR: AddressSanitizer" not in result.stderr and "runtime error:" not in result.stderr, result.stderr
            group = int(re.search(r"owned_shell_group=(\d+)", result.stderr)[1])
            deadline = time.monotonic() + 5
            while True:
                try:
                    os.killpg(group, 0)
                except ProcessLookupError:
                    break
                assert time.monotonic() < deadline, f"Owned group {group} survived emergency cleanup"
                time.sleep(0.01)
            data["cleanup_checks"].append({"signal": int(requested_signal), "owned_group_removed": True})
        cleanup_db.unlink()
        for rows, width, capacity, depth in cases:
            db = temp / "fixture.db"
            invoke(binary, db, "seed", rows, width, capacity, depth)
            for repeat in range(args.repeats):
                policies = ["fifo", "control_first"] if rows and depth > 1 else ["fifo"]
                if repeat % 2:
                    policies.reverse()
                for policy in policies:
                    observation = invoke(binary, db, policy, rows, width, capacity, depth)
                    assert observation["capacity"] == capacity
                    assert observation["streamed_bytes"] > 0
                    if rows:
                        assert 1 <= observation["completed_before_stop"] <= depth
                    else:
                        assert observation["completed_before_stop"] == 0
                    if policy == "fifo" and rows:
                        assert observation["completed_before_stop"] == depth
                    observation["repeat"] = repeat
                    observation["database_bytes"] = db.stat().st_size
                    data["observations"].append(observation)
            db.unlink()
            args.output.write_text(json.dumps(data, indent=2) + "\n")
            print(f"Completed {rows:,} rows, width {width}, capacity {capacity}, queue {depth}", flush=True)
    data["load_end"] = output("sysctl", "-n", "vm.loadavg")
    data["summaries"] = []
    keys = sorted({(o["rows"], o["width"], o["capacity"], o["queued_inspections"], o["policy"])
                   for o in data["observations"]})
    for rows, width, capacity, depth, policy in keys:
        observations = [o for o in data["observations"]
                        if (o["rows"], o["width"], o["capacity"], o["queued_inspections"], o["policy"]) ==
                        (rows, width, capacity, depth, policy)]
        summary = {"rows": rows, "width": width, "capacity": capacity, "depth": depth, "policy": policy,
                   "samples": len(observations),
                   "arrivals_during_capture": sum(o["arrived_during_capture"] for o in observations)}
        for key in ("queue_wait_ms", "stop_ack_ms", "sql_commit_ms", "all_interruptions_ms", "local_drain_ms",
                    "reactor_max_tick_gap_including_warmup_ms", "process_cpu_ms", "elapsed_ms", "bytes_drained_during_captures",
                    "sqlite_heap_peak", "physical_end", "completed_before_stop"):
            values = [o[key] for o in observations]
            summary[key] = {"median": statistics.median(values), "max": max(values)}
        data["summaries"].append(summary)
    args.output.write_text(json.dumps(data, indent=2) + "\n")
    print("PASS: measured independent stop arrival, durable acknowledgement, reactor interruption, and cleanup", flush=True)


if __name__ == "__main__":
    main()
