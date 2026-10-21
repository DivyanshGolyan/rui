"""Audit retained raw observations without recapturing the workload."""
import gzip
import json
import math
import os
from pathlib import Path
import statistics
import sys


def read_snapshot(path):
    return path.read_text() if path.exists() else gzip.open(str(path) + ".gz", "rt").read()


root = Path(sys.argv[1] if len(sys.argv) > 1 else ".amp/p1")
summary = json.loads((root / "summary.json").read_text())
rows = summary["rows"]
assert len(rows) == 15 and all(row["status"] == "passed" for row in rows)
assert sum(row["hold"] for row in rows) == 6
identities = []
for row in rows:
    raw = json.loads((root / "raw" / row["file"]).read_text())
    expected = ("ec8400832970ba2d4f13a8ffdb706c2b4513615a6abbafe0a3335562d973b439"
                if row["file"].startswith("run-hold-B") else
                "e2835cb25a7e45851df6dac35de0977de8a88b9d2861eea8ee5b43bd993b3a50")
    assert raw["binary_sha256"] == expected
    assert raw["harness_sha256"] == "7f4fe110b5efbab175a51006d5a563cd2624ab6d0b86c35554ccbe9a2e05ade6"
    assert raw["active_capacity"] == 100 and raw["host_exit"]["exited"]
    assert raw["window_seconds"] >= 60
    cpu = raw["cpu_second"]["host_cpu_seconds"] - raw["cpu_first"]["host_cpu_seconds"]
    assert math.isclose(cpu, raw["host_cpu_seconds"], abs_tol=1e-12)
    assert math.isclose(cpu / raw["window_seconds"], raw["host_average_cores"], abs_tol=1e-12)
    assert raw["steady_state_clients"]["count"] == raw["steady_state_clients"]["pss_bytes"] == 0
    for phase in ("start", "end"):
        endpoint = raw[f"host_window_{phase}"]
        memory = {}
        directory = root / "raw" / Path(row["file"]).stem
        for line in read_snapshot(directory / f"host-window-{phase}.txt.smaps_rollup").splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                if value.strip().endswith(" kB"):
                    memory[key] = int(value.split()[0]) * 1024
        assert endpoint["live_descendant_processes"] == 0
        for key, value in endpoint["linux_memory"]["smaps_rollup_bytes"].items():
            assert memory[key] == value
        fields = dict(line.split(":", 1) for line in read_snapshot(directory / f"host-window-{phase}.txt.status").splitlines() if ":" in line)
        assert int(fields["TracerPid"]) == 0 and int(fields["Pid"]) == raw["host_pid"]
        assert int(fields["VmHWM"].split()[0]) * 1024 == endpoint["linux_memory"]["status_rss_high_water_bytes"]
        if raw["sessions"]:
            facts = raw[f"fixture_window_{phase}"]
            assert facts["h2_connections"] == 1 and facts["ready_streams"] == raw["sessions"]
            if raw["hold"]:
                assert facts["held_streams"] == 100 and facts["offer_bytes"] == 0
    if raw["hold"]:
        snapshots = []
        for phase in ("start", "end"):
            threads = {}
            text = read_snapshot(directory / f"host-threads-{phase}.txt")
            for block in text.strip().split("\n\n"):
                fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
                assert int(fields["Tgid"]) == raw["host_pid"]
                tid = int(fields["Pid"])
                assert tid not in threads
                threads[tid] = tuple(int(fields[name]) for name in ("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches"))
            assert len(threads) == 5
            snapshots.append(threads)
        assert snapshots[0].keys() == snapshots[1].keys()
        deltas = {str(tid): [after - before for before, after in zip(snapshots[0][tid], snapshots[1][tid])] for tid in snapshots[0]}
        assert deltas == row["thread_switch_deltas"]
        assert sum(pair[0] for pair in deltas.values()) == row["voluntary_switches"]
        assert sum(pair[1] for pair in deltas.values()) == row["nonvoluntary_switches"]
    identities.extend([raw["host_pid"], raw["provider_pid"]])
assert len(set(identities)) == 30
if "--live" in sys.argv:
    assert all(not os.path.exists(f"/proc/{pid}") for pid in identities)
    print("PASS: 30 distinct recorded Host/provider PID identities absent in /proc after teardown")
print("PASS: 15 observations; 30 smaps endpoints/all recorded counters, CPU endpoints/ratios, zero descendants/TracerPid and exact binary/harness identities")
print("PASS: six HOLD cases independently match five thread identities and sum raw switch counters; held100/oneH2/zero response bytes at both endpoints")
for group in ("A", "B"):
    cases = [row for row in rows if row["file"].startswith("run-hold-" + group)]
    assert len(cases) == 3
    for field in ("voluntary_switches", "nonvoluntary_switches", "voluntary_switches_per_second_lower", "voluntary_switches_per_second_upper", "host_cpu_seconds", "host_pss_end_bytes"):
        values = [row[field] for row in cases]
        print(group, field, "values=", values, "median=", statistics.median(values), "inclusive_IQR=", (max(values) - min(values)) / 2)
