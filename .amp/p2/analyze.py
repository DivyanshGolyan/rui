#!/usr/bin/env python3
"""Reduce retained count evidence, never profiler times, into a small appendix input."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent
raw = root / "raw"
rows = []
for name in ("stream1-strace", "stream1-no-trace", "stream100-strace"):
    report_path = raw / (name + ".json")
    syscall_path = raw / (name + "-strace.txt")
    if name == "stream1-strace":
        syscall_path = raw / "stream1-strace.txt"
    if name == "stream100-strace":
        syscall_path = raw / "stream100-strace.txt"
    if not report_path.exists() or not syscall_path.exists():
        continue
    report = json.loads(report_path.read_text())
    rounds = report["active_capacity_growth"][0]["rounds"]
    messages = sum(len(row["audit_rows"]) for row in rounds)
    events = sum(row["paced_offer"]["completed_events"] for row in rounds)
    assert messages and events and all(row["all_results_audited"] for row in rounds)
    counts = {}
    for line in syscall_path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 5 and parts[0][0].isdigit():
            counts[parts[-1]] = int(parts[3])
    assert counts.get("total", 0) > 0
    rows.append({"run": name, "fixture": True, "instrumented_counts_only": True,
                 "harness_verdict": report["status"], "messages": messages, "events": events,
                 "syscalls": counts, "syscalls_per_event": counts["total"] / events,
                 "syscalls_per_message": counts["total"] / messages,
                 "fsync_per_message": counts.get("fsync", 0) / messages,
                 "fdatasync_per_message": counts.get("fdatasync", 0) / messages,
                 "host_dimensions": [row["host_dimensions"] for row in rounds],
                 "raw_report": report_path.name, "raw_syscalls": syscall_path.name,
                 "raw_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (report_path, syscall_path)}})
print(json.dumps(rows, indent=2))
