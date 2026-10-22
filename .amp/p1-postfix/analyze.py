"""Reduce the existing model-output JSON and retained Linux observations."""
import gzip
import json
from pathlib import Path
import statistics
import sys


root = Path(sys.argv[1] if len(sys.argv) > 1 else ".amp/p1")
rows = []
for path in sorted((root / "raw").glob("run-*.json")):
    raw = json.loads(path.read_text())
    row = {"file": path.name, "status": raw["status"],
           "measurement_revision": raw.get("measurement_revision"),
           "binary_sha256": raw.get("binary_sha256"),
           "harness_sha256": raw.get("harness_sha256"),
           "sessions": raw["sessions"], "hold": raw["hold"]}
    if raw["status"] != "passed":
        row["error"] = raw.get("error")
        rows.append(row)
        continue
    assert raw["memory_metric"] == "Linux PSS (macOS footprint pending)"
    assert raw["steady_state_clients"]["count"] == 0
    assert raw["steady_state_clients"]["pss_bytes"] == 0
    row.update(host_pss_start_bytes=raw["host_window_start"]["linux_memory"]["smaps_rollup_bytes"]["Pss"],
               host_pss_end_bytes=raw["host_window_end"]["linux_memory"]["smaps_rollup_bytes"]["Pss"],
               steady_state_client_count=0, steady_state_client_pss_bytes=0,
               transient_client_peak_pss_bytes=None,
               host_cpu_seconds=raw["host_cpu_seconds"],
               window_seconds=raw["window_seconds"], host_average_cores=raw["host_average_cores"],
               host_threads=raw["host_window_end"]["threads"], host_pid=raw["host_pid"])
    if raw["sessions"]:
        row.update(actual_fixture_events_between_queries=0 if raw["hold"] else None,
                   fixture_events_per_second_lower=0 if raw["hold"] else None,
                   fixture_events_per_second_upper=0 if raw["hold"] else None,
                   host_cpu_us_per_fixture_event_approximate=None,
                   rate_status="zero response bytes enforced by HOLD" if raw["hold"] else "unavailable: provider publishes delivery totals only after the complete offer; mid-offer zero counters are not measured zero delivery")
    if raw["hold"]:
        counts = []
        for suffix in ("start", "end"):
            snapshot = raw[f"linux_thread_window_{suffix}"]
            thread_path = root / "raw" / path.stem / f"host-threads-{suffix}.txt"
            text = thread_path.read_text() if thread_path.exists() else gzip.open(str(thread_path) + ".gz", "rt").read()
            threads = {}
            for block in text.strip().split("\n\n"):
                fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
                tid = int(fields["Pid"].strip())
                assert tid not in threads
                threads[tid] = [int(fields[key].strip()) for key in ("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")]
            assert len(threads) == snapshot["threads"]
            counts.append(threads)
        assert counts[0].keys() == counts[1].keys(), "thread population changed; no complete switch delta"
        deltas = {tid: [after - before for before, after in zip(counts[0][tid], counts[1][tid])] for tid in counts[0]}
        assert all(value >= 0 for pair in deltas.values() for value in pair)
        first, second = raw["linux_thread_window_start"], raw["linux_thread_window_end"]
        minimum = (second["begin_unix_ns"] - first["end_unix_ns"]) / 1e9
        maximum = (second["end_unix_ns"] - first["begin_unix_ns"]) / 1e9
        assert maximum >= minimum > 0
        voluntary = sum(pair[0] for pair in deltas.values())
        row.update(distinct_wakeups_per_second=None, switch_counter_scope="per-thread voluntary switches, not distinct wakeups",
                   thread_switch_deltas=deltas, voluntary_switches=voluntary,
                   nonvoluntary_switches=sum(pair[1] for pair in deltas.values()),
                   voluntary_switches_per_second_lower=voluntary / maximum,
                   voluntary_switches_per_second_upper=voluntary / minimum)
    rows.append(row)

populations = []
for count in (0, 10, 100):
    cases = [row for row in rows if row["sessions"] == count and not row["hold"] and row["status"] == "passed"]
    values = [row["host_pss_end_bytes"] for row in cases]
    population = {"sessions": count, "completed_repeats": len(cases), "host_pss_end_bytes": values,
                  "median_host_pss_bytes": statistics.median(values) if values else None,
                  "iqr_host_pss_bytes": (max(values) - min(values)) / 2 if len(values) == 3 else None}
    assert len(values) <= 3
    populations.append(population)

fit = None
if all(row["completed_repeats"] == 3 for row in populations):
    xs = [row["sessions"] for row in populations]
    ys = [row["median_host_pss_bytes"] for row in populations]
    mean_x, mean_y = statistics.mean(xs), statistics.mean(ys)
    slope = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / sum((x - mean_x) ** 2 for x in xs)
    intercept = mean_y - slope * mean_x
    fit = {"method": "ordinary least squares over three population medians; not a universal per-Session allocation",
           "intercept_bytes": intercept, "slope_bytes_per_active_session": slope,
           "residuals_bytes": {x: y - intercept - slope * x for x, y in zip(xs, ys)}}

print(json.dumps({"label": "Linux PSS (macOS footprint pending)",
                  "iqr_method": "inclusive quartiles for three repeats: (max-min)/2",
                  "event_rate_limit": "STREAM in-window delivery counts unavailable; fixture counters publish only after the offer, so no CPU/event ratio is derived",
                  "rows": rows, "populations": populations, "fit": fit}, indent=2))
