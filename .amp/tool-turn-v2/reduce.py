#!/usr/bin/env python3
"""Reduce tool-turn campaign JSONs into summary.json and a Markdown table.

Every value is copied or computed from the run JSONs and raw strace files;
nothing is estimated here. Failed runs are listed, never dropped.
"""
import json, pathlib, re, statistics, sys

campaign = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
rows, failures = [], []


def phase(run, name):
    return run["process_tree"]["phases"].get(name, {})


def peak(run, name, column):
    sample = phase(run, name).get("observed_peak_total_sample")
    return None if sample is None else sample["pss_bytes"].get(column, 0)


def column_peak(run, name, column):
    path = pathlib.Path(run["artifacts"]) / "tree-samples.jsonl"
    best = None
    for line in path.read_text().splitlines():
        sample = json.loads(line)
        if sample["phase"] == name:
            value = sample["pss_bytes"].get(column, 0)
            best = value if best is None else max(best, value)
    return best


def last(run, name, column):
    sample = phase(run, name).get("last_sample")
    return None if sample is None else sample["pss_bytes"].get(column, 0)


def forks(path):
    """Host fork (clone return in a Host thread) to the child's execve entry."""
    text = path.read_text()
    host_tids, clone_at, exec_at, exec_path = set(), {}, {}, {}
    pending = {}
    first_pid = None
    for line in text.splitlines():
        match = re.match(r"(\d+) +(\d+\.\d+) (.*)", line)
        if not match:
            continue
        tid, at, rest = int(match[1]), float(match[2]), match[3]
        if rest.startswith("clone(") or rest.startswith("<... clone resumed>"):
            result = re.search(r"= (\d+)$", rest)
            if rest.endswith("<unfinished ...>"):
                pending[tid] = True
                continue
            if result:
                clone_at[int(result[1])] = (tid, at)
        elif rest.startswith("execve("):
            target = re.match(r'execve\("([^"]+)"', rest)
            exec_at.setdefault(tid, at)
            exec_path.setdefault(tid, target[1] if target else None)
    # Host threads are the parents of bash children.
    rows = []
    for child, (parent, at) in clone_at.items():
        if child in exec_at:
            rows.append({"parent": parent, "child": child, "exec": exec_path[child], "fork_to_exec_seconds": exec_at[child] - at})
    host_rows = [row for row in rows if row["exec"] == "/bin/bash"]
    send_rows = [row for row in rows if row["exec"] and row["exec"].endswith("/rui")]
    def stats(values):
        if not values:
            return None
        values = sorted(values)
        return {"count": len(values), "min": values[0], "median": statistics.median(values), "max": values[-1]}
    return {"host_to_bash": stats([row["fork_to_exec_seconds"] for row in host_rows]),
            "bash_to_rui_send": stats([row["fork_to_exec_seconds"] for row in send_rows]),
            "pairs": len(rows)}


for path in sorted(campaign.glob("*.json")):
    run = json.loads(path.read_text())
    label = path.stem
    if run.get("status") != "passed":
        failures.append({"label": label, "status": run.get("status"), "error": run.get("error")})
        continue
    provider = run["provider"]
    points = {point["name"]: point for point in run["points"]}
    def store_bytes(point, kind="apparent_bytes"):
        return sum(entry.get(kind, 0) for entry in points[point]["store"]["entries"].values())
    seed_rows = run["seed"]["rows"]
    cats = run["process_tree"]["observed_categories"]
    row = {
        "label": label, "workload": run["workload"], "sessions": run["sessions"], "instrumented": run["instrumented"],
        "expectation": run["expectation"], "host_pid": run["host_pid"], "tui_pid": run["tui_pid"],
        "seed_bytes_per_session": sorted({r["bytes"] for r in seed_rows}),
        "seed_estimated_tokens_per_session_bytes_div_4": sorted({r["estimated_tokens_bytes_div_4"] for r in seed_rows}),
        "measured_request_bytes_median": statistics.median(f["measured_request_bytes"] for f in provider["session_facts"]),
        "dispatch_calls": provider["dispatch_calls"], "workload_calls": provider["workload_calls"],
        "succeeded_calls": provider["succeeded_calls"], "failed_calls": provider["failed_calls"],
        "model_requests": provider["requests"], "h2_connections": provider["h2_connections"],
        "workload_max_overlapping": run["concurrency"]["workload"]["max_overlapping"],
        "dispatch_max_overlapping": run["concurrency"]["dispatch"].get("max_overlapping"),
        "workload_shell_seconds": run["concurrency"]["workload"].get("shell_seconds"),
        "dispatch_shell_seconds": run["concurrency"]["dispatch"].get("shell_seconds"),
        "call_response_to_workload_shell_start": run["concurrency"]["workload"].get("call_response_to_shell_start_seconds"),
        "max_observed_counts_active": phase(run, "active").get("max_observed_counts"),
        "active_samples": phase(run, "active").get("samples"),
        "pss_idle_before": {c: last(run, "idle_before", c) for c in ("host", "bash", "clients", "tui", "total")},
        "pss_active_observed_peak_total_sample": {c: peak(run, "active", c) for c in ("host", "bash", "clients", "tui", "send", "total")},
        "pss_active_per_column_max": {c: column_peak(run, "active", c) for c in ("host", "bash", "clients", "send", "total")},
        "pss_idle_after": {c: last(run, "idle_after", c) for c in ("host", "bash", "clients", "tui", "total")},
        "observed_processes": {name: entry["processes"] for name, entry in cats.items()},
        "bash_shell_median_max_pss": cats.get("bash_shell", {}).get("median_max_pss_bytes"),
        "bash_child_median_max_pss": cats.get("bash_child", {}).get("median_max_pss_bytes"),
        "send_median_max_pss": cats.get("send", {}).get("median_max_pss_bytes"),
        "cpu": run["cpu"],
        "store_apparent_bytes": {name: store_bytes(name) for name in ("configured", "seeded", "before_submit", "active_end", "idle_after")},
        "meminfo_cached_bytes": {name: points[name]["meminfo_system"].get("Cached_bytes") for name in ("configured", "seeded", "before_submit", "active_end", "idle_after")},
        "observer_cpu_seconds_active": (points["active_end"]["observer_cpu_ns"] - points["before_submit"]["observer_cpu_ns"]) / 1e9,
        "fincore_idle_after": points["idle_after"]["store"].get("fincore_raw"),
        "tui": run["tui"],
        "barrier": run.get("barrier", False), "active_sample_interval_ms": run.get("active_sample_interval_ns", 200_000_000) / 1e6,
        "barrier_release": run.get("barrier_release"), "sample_coverage": run.get("sample_coverage"),
        "workload_park_to_start": run["concurrency"]["workload"].get("park_to_start_seconds"),
        "sampling_wall_seconds": run["process_tree"].get("sampling_wall_seconds"),
        "pss_steady_after_per_column": {c: last(run, "idle_after", c) for c in ("host", "bash", "clients", "tui", "send", "total")},
    }
    trace = pathlib.Path(run["artifacts"]) / "host-forks.strace"
    if run["instrumented"] and trace.exists():
        row["fork_to_exec"] = forks(trace)
    rows.append(row)

out.write_text(json.dumps({"runs": rows, "failures": failures}, indent=1, sort_keys=True) + "\n")
print(f"{len(rows)} passed, {len(failures)} failed")
