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


def scan_coverage(run, name):
    """Sequential-scan facts for the phase's peak-total sample and per-category
    identities seen versus identities with at least one successful PSS read
    (samples > pss_failures). A sample's sum spans [begin, end]; it is not a
    simultaneous snapshot and omits failed reads."""
    sample = phase(run, name).get("observed_peak_total_sample")
    seen, read = {}, {}
    for record in run["process_tree"]["processes"]:
        category = record["category"]
        seen[category] = seen.get(category, 0) + 1
        read[category] = read.get(category, 0) + (record["samples"] > record["pss_failures"])
    path = pathlib.Path(run["artifacts"]) / "tree-samples.jsonl"
    spans = [(json.loads(line)["end_unix_ns"] - json.loads(line)["begin_unix_ns"]) / 1e6 for line in path.read_text().splitlines() if json.loads(line)["phase"] == name]
    return {"peak_sample_scan_ms": None if sample is None else (sample["end_unix_ns"] - sample["begin_unix_ns"]) / 1e6,
            "peak_sample_pss_failures": None if sample is None else sample["pss_failures"],
            "peak_sample_processes": None if sample is None else sample["counts"].get("total"),
            "phase_scan_ms_median_max": [statistics.median(spans), max(spans)] if spans else None,
            "identities_seen": seen, "identities_with_pss_read": read}


def last(run, name, column):
    sample = phase(run, name).get("last_sample")
    return None if sample is None else sample["pss_bytes"].get(column, 0)


def forks(path):
    """Parent clone ENTRY to the child's first execve ENTRY.

    strace -ttt stamps each line when it starts printing it: a complete line
    or an `<unfinished ...>` line carries the syscall's entry time, and a
    `<... resumed>` line carries the return time. A resumed clone takes its
    entry time from the same thread's preceding unfinished line.
    """
    entry_pending, clone_entry, exec_at, exec_path = {}, {}, {}, {}
    for line in path.read_text().splitlines():
        match = re.match(r"(\d+) +(\d+\.\d+) (.*)", line)
        if not match:
            continue
        tid, at, rest = int(match[1]), float(match[2]), match[3]
        if rest.startswith("clone(") and rest.endswith("<unfinished ...>"):
            entry_pending[tid] = at
        elif rest.startswith("clone(") or rest.startswith("<... clone resumed>"):
            result = re.search(r"= (\d+)$", rest)
            entered = entry_pending.pop(tid) if rest.startswith("<...") else at
            if result:
                clone_entry[int(result[1])] = entered
        elif rest.startswith("execve("):
            target = re.match(r'execve\("([^"]+)"', rest)
            if tid not in exec_at:
                exec_at[tid], exec_path[tid] = at, target[1] if target else None
    rows = [{"child": child, "exec": exec_path[child], "seconds": exec_at[child] - at}
            for child, at in clone_entry.items() if child in exec_at]
    assert all(row["seconds"] >= 0 for row in rows), "clone entry after child execve"
    def stats(values):
        if not values:
            return None
        values = sorted(values)
        return {"count": len(values), "min": values[0], "median": statistics.median(values), "max": values[-1]}
    return {"method": "parent clone entry to child execve entry, strace -f -ttt (instrumented)",
            "host_to_bash": stats([r["seconds"] for r in rows if r["exec"] == "/bin/bash"]),
            "bash_to_rui_send": stats([r["seconds"] for r in rows if r["exec"] and r["exec"].endswith("/rui")]),
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
        "active_scan": scan_coverage(run, "active"),
        "workload_park_to_start": run["concurrency"]["workload"].get("park_to_start_seconds"),
        "sampling_wall_seconds": run["process_tree"].get("sampling_wall_seconds"),
        "pss_steady_after_per_column": {c: last(run, "idle_after", c) for c in ("host", "bash", "clients", "tui", "send", "total")},
    }
    # Request phases from raw provider facts, not the harness's 2N label.
    begin, end = points["before_submit"]["unix_ns"], points["active_end"]["unix_ns"]
    phases = {}
    for fact in provider["session_facts"]:
        for kind, field in (("seed", "seed_received_unix_ns"), ("measured", "measured_received_unix_ns"), ("continuation", "continuation_received_unix_ns")):
            at = fact[field]
            phases[kind + "_total"] = phases.get(kind + "_total", 0) + 1
            phases[kind + "_in_window"] = phases.get(kind + "_in_window", 0) + (begin <= at <= end)
    n = run["sessions"]
    assert phases == {"seed_total": n, "seed_in_window": 0, "measured_total": n, "measured_in_window": n, "continuation_total": n, "continuation_in_window": n}, (label, phases)
    assert provider["requests"] == 3 * n, (label, provider["requests"])
    in_window = phases["measured_in_window"] + phases["continuation_in_window"]
    row["model_requests"] = {"campaign_total_provider": provider["requests"], **phases, "cpu_window_denominator": in_window}
    row["host_cpu_seconds_per_model_request_in_window"] = run["cpu"]["host_self_cpu_seconds"] / in_window
    row["host_cpu_seconds_per_workload_call"] = run["cpu"]["host_self_cpu_seconds"] / provider["workload_calls"]
    row["host_cpu_seconds_per_tool_call_incl_dispatch"] = run["cpu"]["host_self_cpu_seconds"] / (provider["workload_calls"] + provider["dispatch_calls"])
    trace = pathlib.Path(run["artifacts"]) / "host-forks.strace"
    if run["instrumented"] and trace.exists():
        row["fork_to_exec"] = forks(trace)
    rows.append(row)

out.write_text(json.dumps({"runs": rows, "failures": failures}, indent=1, sort_keys=True) + "\n")
print(f"{len(rows)} passed, {len(failures)} failed")
