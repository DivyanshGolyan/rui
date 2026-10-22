#!/usr/bin/env python3
"""Reduce instrumented SQL/turn counts by explicit fixture phase windows."""
import gzip
import json
import sys
from collections import Counter
from pathlib import Path

from sql_read_attribution import owner

ROOT = Path(__file__).resolve().parent
assert len(sys.argv) <= 2
directory = ROOT / (sys.argv[1] if len(sys.argv) == 2 else "raw/sql-phases-hold100")
evidence = json.loads((directory / "evidence.json").read_text())
assert evidence["messages"] == 100 and evidence["events"] == 0
held = evidence["held_snapshot"]
assert held["held_streams"] == 100 and held["offer_bytes"] == held["completed_events"] == 0
records = []
for line in gzip.decompress((directory / "host-stderr.log.gz").read_bytes()).decode().splitlines():
    if line.startswith("P2_SQL_PHASE\t"):
        _, timestamp, tid, sql = line.split("\t", 3)
        records.append((int(timestamp), "sql", int(tid), sql))
    elif line.startswith("P2_TURN\t"):
        _, timestamp, tid, stage, free = line.split("\t")
        records.append((int(timestamp), "turn", int(tid), (stage, int(free))))
assert records and all(timestamp > 0 for timestamp, *_ in records)
execution_tids = sorted({tid for _, kind, tid, _ in records if kind == "turn"})
assert len(execution_tids) == 1, execution_tids
rows = []
for window in evidence["windows"]:
    start, end = window["start_unix_ns"], window["end_unix_ns"]
    assert end > start
    selected = [record for record in records if start <= record[0] < end]
    groups, verbs, stages, free_slots, threads = (Counter() for _ in range(5))
    queries = Counter()
    for _, kind, tid, detail in selected:
        if kind == "sql":
            threads[tid] += 1
            verb = detail.split()[0]
            verbs[verb] += 1
            if verb == "SELECT":
                groups[owner(detail)[0]] += 1
                queries[detail] += 1
        else:
            stage, free = detail
            stages[stage] += 1
            if stage == "begin":
                free_slots[free] += 1
    seconds = (end - start) / 1e9
    row = {**window, "observed_seconds": seconds, "first_executions": sum(verbs.values()),
           "statement_verbs": dict(verbs), "select_owners": dict(groups),
           "select_first_executions_per_second": sum(groups.values()) / seconds,
           "turn_stages": dict(stages), "free_slot_histogram_at_turn_start": dict(free_slots),
           "first_executions_by_tid": dict(threads),
           "select_texts": [{"sql": sql, "count": count, "owner": owner(sql)[0]} for sql, count in queries.most_common()]}
    if window["name"] == "held_100":
        assert set(free_slots) == {0}, free_slots
        assert set(verbs) == {"SELECT"}, verbs
        assert set(groups) <= {"uncertain_action_recovery", "control_reconciliation", "exhausted_retry_recovery"}, groups
        assert abs(groups["uncertain_action_recovery"] - stages["begin"]) <= 1
    if window["name"] in ("empty_idle", "cancelled_settled_idle", "configured_zero"):
        assert set(free_slots) == {100}, free_slots
        assert not groups["control_reconciliation"]
    rows.append(row)
output = {"fixture": True, "instrumented_counts_only": True,
          "execution_tid": execution_tids[0], "windows": rows,
          "limits": evidence["limits"]}
# A single held-window confirmation intentionally has no matched-zero phase.
if len(sys.argv) == 2 and "zero_start_snapshot" in evidence:
    assert evidence["host_capacity"] == evidence["configured_sessions"] == 100
    assert evidence["warmup_seconds_each"] == 10 and evidence["requested_window_seconds_each"] == 60
    assert evidence["tools"] == "none"
    for key in ("zero_start_snapshot", "zero_end_snapshot"):
        snapshot = evidence[key]
        # Provider Snapshot.HeldStreams has json omitempty, so zero is absent.
        assert snapshot.get("held_streams", 0) == 0
        assert snapshot["ready_streams"] == snapshot["h2_streams"] == snapshot["completed_events"] == snapshot["offer_bytes"] == 0
    assert held["terminal_finished_streams"] == 0
    zero = next(row for row in rows if row["name"] == "configured_zero")
    full = next(row for row in rows if row["name"] == "held_100")
    admission = next(row for row in rows if row["name"] == "admit_100")
    assert zero["end_unix_ns"] <= admission["start_unix_ns"] < admission["end_unix_ns"] < full["start_unix_ns"]
    assert set(zero["statement_verbs"]) == {"SELECT", "BEGIN", "ROLLBACK"}
    assert zero["statement_verbs"]["BEGIN"] == zero["statement_verbs"]["ROLLBACK"]
    rates = []
    for row in (zero, full):
        assert row["observed_seconds"] >= 60
        rates.append({"phase": row["name"], "seconds": row["observed_seconds"],
                      "select_count": row["statement_verbs"]["SELECT"], "all_statement_count": row["first_executions"],
                      "selects_per_second": row["select_first_executions_per_second"],
                      "all_statements_per_second": row["first_executions"] / row["observed_seconds"]})
    contributions = []
    for group in sorted(set(zero["select_owners"]) | set(full["select_owners"])):
        before = zero["select_owners"].get(group, 0) / zero["observed_seconds"]
        after = full["select_owners"].get(group, 0) / full["observed_seconds"]
        contributions.append({"owner": group, "zero_per_second": before, "held100_per_second": after,
                              "extra_selects_per_second": after - before})
    select_delta = rates[1]["selects_per_second"] - rates[0]["selects_per_second"]
    assert abs(sum(row["extra_selects_per_second"] for row in contributions) - select_delta) < 1e-9
    output["matched_comparison"] = {
        "host_pid": evidence["host_pid"], "host_capacity": 100, "configured_sessions": 100,
        "warmup_seconds_each": 10, "requested_window_seconds_each": 60, "rates": rates,
        "select_rate_ratio": rates[1]["selects_per_second"] / rates[0]["selects_per_second"],
        "extra_selects_per_second": select_delta,
        "all_statement_rate_ratio": rates[1]["all_statements_per_second"] / rates[0]["all_statements_per_second"],
        "extra_all_statements_per_second": rates[1]["all_statements_per_second"] - rates[0]["all_statements_per_second"],
        "control_selects_per_held_operation_per_second": full["select_owners"]["control_reconciliation"] / full["observed_seconds"] / 100,
        "select_caller_contributions": contributions,
        "limits": "One sequential same-Host configured-zero versus held100 observation, not repeated/fresh-Host statistics. Admission lies outside both windows. Rates normalize instrumented first-execution counts; neither CPU causality nor an optimization speedup is measured. Held connections and durable Message/Operation rows are the intentional population difference."}
elif len(sys.argv) == 2:
    assert evidence["product_revision"] == "d4f870002b1eeef370fb8f4c7aa3fd8b14343159"
    assert evidence["host_capacity"] == evidence["configured_sessions"] == 100
    assert evidence["warmup_seconds"] == 10 and evidence["requested_window_seconds"] == 60
    assert held["terminal_finished_streams"] == 0 and held["h2_connections"] == 1
    assert [row["name"] for row in rows] == ["configure_and_admit", "held_100", "stop_and_drain"]
    assert rows[0]["end_unix_ns"] < rows[1]["start_unix_ns"] < rows[1]["end_unix_ns"] <= rows[2]["start_unix_ns"]
    assert rows[1]["observed_seconds"] >= 60
print(json.dumps(output, indent=2))
