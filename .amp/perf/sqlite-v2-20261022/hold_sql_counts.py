#!/usr/bin/env python3
"""Count instrumented SQL first executions inside each P2 HOLD fixture window.

Same raw inputs as P2's sql_phase_attribution.py, without its baseline-only
assertion that every turn begins with an uncertain-Action scan (the candidate
removes that scan by design). Applied identically to baseline and candidate."""
import gzip
import json
import sys
from collections import Counter
from pathlib import Path

directory = Path(sys.argv[1])
evidence = json.loads((directory / "evidence.json").read_text())
assert evidence["messages"] == 100 and evidence["events"] == 0
held = evidence["held_snapshot"]
assert held["held_streams"] == 100 and held["offer_bytes"] == held["completed_events"] == 0
records = []
turns = []
for line in gzip.decompress((directory / "host-stderr.log.gz").read_bytes()).decode().splitlines():
    if line.startswith("P2_SQL_PHASE\t"):
        _, timestamp, _tid, sql = line.split("\t", 3)
        records.append((int(timestamp), sql))
    elif line.startswith("P2_TURN\t"):
        turns.append(int(line.split("\t")[1]))
result = {"fixture": True, "instrumented_counts_only": True, "windows": []}
for window in evidence["windows"]:
    start, end = window["start_unix_ns"], window["end_unix_ns"]
    seconds = (end - start) / 1e9
    selected = [sql for timestamp, sql in records if start <= timestamp < end]
    verbs = Counter(sql.split()[0] for sql in selected)
    texts = Counter(sql for sql in selected if sql.split()[0] in ("SELECT", "WITH"))
    result["windows"].append({
        "name": window["name"], "observed_seconds": seconds,
        "statements": len(selected), "verbs": dict(verbs),
        "select_per_second": verbs["SELECT"] / seconds,
        "turn_begins": sum(1 for timestamp in turns if start <= timestamp < end),
        "select_texts": [{"count": count, "sql": sql} for sql, count in texts.most_common()],
    })
json.dump(result, sys.stdout, indent=1)
print()
