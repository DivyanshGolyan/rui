#!/usr/bin/env python3
"""Reduce instrumented SQL/turn counts by explicit fixture phase windows."""
import gzip
import json
from collections import Counter
from pathlib import Path

from sql_read_attribution import owner

ROOT = Path(__file__).resolve().parent
directory = ROOT / "raw/sql-phases-hold100"
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
    if window["name"] in ("empty_idle", "cancelled_settled_idle"):
        assert set(free_slots) == {100}, free_slots
        assert not groups["control_reconciliation"]
    rows.append(row)
print(json.dumps({"fixture": True, "instrumented_counts_only": True,
                  "execution_tid": execution_tids[0], "windows": rows,
                  "limits": evidence["limits"]}, indent=2))
