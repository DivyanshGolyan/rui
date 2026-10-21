#!/usr/bin/env python3
"""Compare instrumented whole-run counts only after matching workload inputs."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def syscalls(path):
    result = {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0][0].isdigit():
            result[parts[-1]] = int(parts[3])
    assert result["total"] == sum(value for name, value in result.items() if name != "total")
    return result


def inputs(report):
    case = report["active_capacity_growth"][0]
    rows = []
    for row in case["rounds"]:
        offer = row["fixture_completion"]
        assert row["all_results_audited"] and row["offline_audit_after_host_reaped"]
        assert all(value == "passed" for name, value in row["host_dimensions"].items() if name != "memory")
        assert offer["offer_failed_streams"] == offer["terminal_failed_streams"] == 0
        assert offer["completed_events"] == offer["expected_events"] == 600000
        assert len(row["audit_rows"]) == 100
        rows.append({"round": row["round"], "offer_seconds": row["offer_seconds"],
                     "events_per_second": row["events_per_second_per_stream"], "expected_work": row["expected_provider_work"],
                     "messages": len(row["audit_rows"]),
                     **{key: offer[key] for key in ("h2_streams", "h2_connections", "event_bytes", "completed_events", "offer_bytes", "terminal_finished_streams")}})
    return {"capacity": case["active_capacity"], "same_host_rounds": case["same_host_rounds"], "same_sessions": case["same_sessions"], "rounds": rows}


baseline_report = ROOT / "raw/stream100-strace.json"
candidate_report = ROOT / "raw/stream100-sse-candidate.json"
baseline = json.loads(baseline_report.read_text())
candidate = json.loads(candidate_report.read_text())
identities = {}
for line in (ROOT / "raw/sse-candidate-identity.txt").read_text().splitlines():
    parts = line.split()
    if len(parts) == 2 and len(parts[0]) == 64:
        identities[parts[1]] = parts[0]
assert identities[".amp/p2/bin/model-output"] == "ab97a07f53f63d8b78a96c992bd8a0ab18b2adf9ed710ceb8f41f4fe94b41d46"
assert identities[".amp/p2/bin/rui-baseline"] == "b843b47aca5f06488101f52ea5714716d96d8e039068b7a11bf03362d16cdbb2"
assert baseline["binary_sha256"] == identities[".amp/p2/bin/rui-strace"]
assert candidate["binary_sha256"] == identities[".amp/p2/bin/rui-candidate-strace"]
workload = inputs(baseline)
assert workload == inputs(candidate)
counts = [syscalls(ROOT / "raw" / name) for name in ("stream100-strace.txt", "stream100-sse-candidate-strace.txt")]
events = sum(row["completed_events"] for row in workload["rounds"])
messages = sum(row["messages"] for row in workload["rounds"])
assert events == 1200000 and messages == 200
rows = []
for name, report, count in zip(("baseline240", "candidate12f84075"), (baseline, candidate), counts):
    rows.append({"name": name, "reported_launcher_sha256": report["binary_sha256"], "harness_status": report["status"],
                 "syscalls": count, "preadv_per_event": count["preadv"] / events,
                 "syscalls_per_event": count["total"] / events, "fsync_per_message": count["fsync"] / messages,
                 "timing_invalid_streams_per_round": [row["fixture_completion"]["timing_invalid_streams"] for row in report["active_capacity_growth"][0]["rounds"]]})
print(json.dumps({"instrumented_counts_only": True, "fixture_inputs_match": workload,
                  "recorded_binary_identities": {path: digest for path, digest in identities.items() if "/bin/" in path},
                  "events": events, "messages": messages, "runs": rows,
                  "preadv_reduction": counts[0]["preadv"] - counts[1]["preadv"],
                  "preadv_reduction_per_event": (counts[0]["preadv"] - counts[1]["preadv"]) / events,
                  "total_syscall_reduction": counts[0]["total"] - counts[1]["total"],
                  "other_syscall_increase": (counts[1]["total"] - counts[1]["preadv"]) - (counts[0]["total"] - counts[0]["preadv"]),
                  "raw_report_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (baseline_report, candidate_report)},
                  "limits": "Same original runner/provider binary and requested workload, distinct fresh Stores/ephemeral endpoints. Actual pacing differs under strace. Counts include whole-run setup and audits; no elapsed/CPU timing acceptance. Recorded binary_sha256 identifies launchers; actual Rui binary identities are separate."}, indent=2))
