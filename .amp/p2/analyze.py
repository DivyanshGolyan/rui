#!/usr/bin/env python3
"""Reduce retained count evidence, never profiler times, into a small appendix input."""
import hashlib
import gzip
import json
import re
from collections import Counter
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

for name in ("sql1", "sql100"):
    report_path = raw / (name + ".json")
    trace_path = raw / (name + "-host.log.gz")
    if not report_path.exists() or not trace_path.exists():
        continue
    report = json.loads(report_path.read_text())
    rounds = report["active_capacity_growth"][0]["rounds"]
    messages = sum(len(row["audit_rows"]) for row in rounds)
    assert messages and all(row["all_results_audited"] for row in rounds)
    trace = gzip.decompress(trace_path.read_bytes()).decode()
    assert "P2_SQL_REGISTRATION_FAILED" not in trace
    sql = [line.removeprefix("P2_SQL\t").strip() for line in trace.splitlines() if line.startswith("P2_SQL\t")]
    mix = Counter(statement.split()[0].upper() for statement in sql)
    assert mix["BEGIN"] == mix["COMMIT"] + mix["ROLLBACK"]
    rows.append({"run": name, "fixture": True, "instrumented_counts_only": True,
                 "harness_verdict": report["status"], "messages": messages,
                 "sql_trace_stmt_callbacks": len(sql), "statement_mix": dict(mix),
                 "statements_per_message": len(sql) / messages,
                 "commit_statement_executions_per_message": mix["COMMIT"] / messages,
                 "begin_statement_executions_per_message": mix["BEGIN"] / messages,
                 "scope": "Host only; SQLite TRACE_STMT at first execution, not completion; explicit transactions only; startup, configuration, two Message rounds and observations; no schema triggers",
                 "raw_report": report_path.name, "raw_sql": trace_path.name,
                 "host_dimensions": [row["host_dimensions"] for row in rounds]})

heap_report = json.loads((raw / "heap1.json").read_text())
heap_rounds = heap_report["active_capacity_growth"][0]["rounds"]
messages = sum(len(row["audit_rows"]) for row in heap_rounds)
assert messages == 2 and all(row["all_results_audited"] for row in heap_rounds)
heap_text = gzip.decompress((raw / "heap1-print.txt.gz").read_bytes()).decode()
allocations = int(re.search(r"calls to allocation functions: (\d+)", heap_text)[1])
allocator_calls = {symbol: int(re.search(r"(?m)^(\d+) calls to allocation functions[^\n]*\n" + symbol + r"\n", heap_text)[1])
                   for symbol in ("sqlite3MemMalloc", "sqlite3MemRealloc", "CRYPTO_malloc")}
rows.append({"run": "heap1", "fixture": True, "instrumented_counts_only": True,
             "messages": messages, "libc_allocation_calls": allocations,
             "allocations_per_message": allocations / messages, "allocator_calls": allocator_calls,
             "harness_verdict": heap_report["status"],
             "scope": "Host startup through graceful-stop exit1/EffectAwareShutdown; libc allocator only, not arena suballocations or direct-page allocations",
             "raw_profile": "heap1.raw.gz", "raw_interpretation": "heap1-print.txt.gz"})

stacks = gzip.decompress((raw / "stream100-perf-samples.stacks.gz").read_bytes()).decode()
blocks = [block for block in stacks.split("\n\n") if "cpu-clock:u:" in block]
patterns = {"provider_output": r"provider_output", "curl_OpenSSL": r"\b(?:Curl_|curl_|SSL_|ssl_|CRYPTO_|ossl_)",
            "SQLite": r"sqlite", "positional_IO": r"pread|readPositional"}
families = {name: {"pattern": pattern, "samples": sum(bool(re.search(pattern, block)) for block in blocks)}
            for name, pattern in patterns.items()}
for family in families.values():
    family["percent"] = family["samples"] * 100 / len(blocks)
perf_report = gzip.decompress((raw / "stream100-perf-report.txt.gz").read_bytes()).decode()
lost = int(re.search(r"Total Lost Samples: (\d+)", perf_report)[1])
folded_samples = sum(int(line.rsplit(" ", 1)[1]) for line in (raw / "stream100-perf-samples.folded").read_text().splitlines())
assert len(blocks) == folded_samples == 4466 and lost == 0
rows.append({"run": "stream100-perf", "fixture": True, "instrumented_counts_only": True,
             "samples": len(blocks), "lost_samples": lost, "families": families,
             "unknown_leaf_samples": sum("[unknown]" in block.splitlines()[1] for block in blocks),
             "unknown_any_frame_samples": sum("[unknown]" in block for block in blocks),
             "scope": "Host user stacks only; named families overlap; no kernel stacks, complete ancestor unwinds or elapsed-time claim"})

for name in ("hold100", "hold100-untraced"):
    directory = raw / name
    evidence = json.loads((directory / "evidence.json").read_text())
    assert evidence["messages"] == 100 and evidence["events"] == 0
    end = evidence["window_end"]
    assert end["held_streams"] == 100 and end["offer_bytes"] == end["completed_events"] == end["terminal_finished_streams"] == 0
    deltas = []
    for start in sorted(directory.glob("start-thread-*.status.gz")):
        finish = directory / start.name.replace("start-", "end-")
        def counters(path):
            value = gzip.decompress(path.read_bytes()).decode()
            return {key: int(value) for key, value in re.findall(r"(?m)^(voluntary_ctxt_switches|nonvoluntary_ctxt_switches):\s*(\d+)", value)}
        before, after = counters(start), counters(finish)
        deltas.append({"tid": start.name.split("-")[-1].split(".")[0], **{key: after[key] - before[key] for key in before}})
    assert len(deltas) == 5
    row = {"run": name, "fixture": True, "messages": 100, "events": 0, "syscalls_per_event": None,
           "thread_deltas": deltas, "voluntary_total": sum(delta["voluntary_ctxt_switches"] for delta in deltas),
           "nonvoluntary_total": sum(delta["nonvoluntary_ctxt_switches"] for delta in deltas),
           "scope": "Host status counter differences over a 60s interior HOLD window; context switches, not Mac wakeups; traced run includes ptrace distortion"}
    if name == "hold100":
        counts = {}
        for line in (raw / "hold100-strace.txt").read_text().splitlines():
            parts = line.split()
            if len(parts) >= 5 and parts[0][0].isdigit():
                counts[parts[-1]] = int(parts[3])
        row.update(syscalls=counts, syscalls_per_message=counts["total"] / 100,
                   fsync_per_message=counts.get("fsync", 0) / 100,
                   count_scope="Whole initialization/admission/hold/teardown, not only the counter window; no Message settlement")
    rows.append(row)
print(json.dumps(rows, indent=2))
