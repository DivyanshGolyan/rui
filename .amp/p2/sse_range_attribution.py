#!/usr/bin/env python3
"""Match isolated validation read calls to actual preadv ranges and prior consumption."""
import gzip
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
log = gzip.decompress((ROOT / "raw/sse-replay.log.gz").read_bytes()).decode()
trace = gzip.decompress((ROOT / "raw/sse-replay-preadv.txt.gz").read_bytes()).decode()
records = []
for line in log.splitlines():
    if line.startswith("P2_RANGE\t"):
        _, role, fd, offset, count, frontier = line.split("\t")
        records.append({"role": role, "fd": int(fd), "offset": int(offset), "count": int(count),
                        "consumed_frontier": int(frontier), "already_consumed": int(offset) + int(count) <= int(frontier)})
actual = []
for line in trace.splitlines():
    if "preadv(" not in line or "/provider-sse>" not in line:
        continue
    match = re.search(r"preadv\((\d+)<.*?/provider-sse>, .*iov_len=(\d+)\}\], 1, (\d+)\) = (\d+)$", line)
    assert match, line
    fd, wanted, offset, count = map(int, match.groups())
    assert wanted == count
    actual.append((fd, offset, count))
assert actual == [(row["fd"], row["offset"], row["count"]) for row in records]
assert "P2_REPLAY\t3\t260\t1215" in log
events = []
expected_roles = Counter({"line_last": 2, "line_cr_check": 1, "line_prefix": 1, "leading_space": 1, "json_fields": 1, "json_string": 1})
for ordinal in range(3):
    start, end = ordinal * 260, (ordinal + 1) * 260
    reads = [row for row in records if start <= row["offset"] and row["offset"] + row["count"] <= end]
    assert Counter(row["role"] for row in reads) == expected_roles
    assert all(row["already_consumed"] for row in reads)
    events.append({"ordinal": ordinal, "byte_range": [start, end], "reread_calls": len(reads),
                   "reread_bytes": sum(row["count"] for row in reads), "reads": reads})
print(json.dumps({"fixture": True, "instrumented_counts_only": True,
                  "nonterminal_events": 3, "event_bytes": 260, "source_bytes_including_terminal": 1215,
                  "instrumented_calls_matched_to_preadv": len(actual), "events": events,
                  "scope": "One completed-response validate call. Five framing rereads plus JSON-object and type-string rereads per nonterminal event. No repeated whole-response validation per network event, CPU cost or timing claim."}, indent=2))
