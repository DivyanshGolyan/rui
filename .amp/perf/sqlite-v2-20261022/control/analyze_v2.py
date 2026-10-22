#!/usr/bin/env python3
"""Per-trial mechanism measures for the predeclared control-v2 (see attempts.md).

Usage: analyze_v2.py BLOCK.json BLOCK.perf.txt  -> JSON lines per trial on stdout.
BLOCK.perf.txt is `perf script -F comm,pid,tid,time,event,trace` of BLOCK.perf.data.
Window per trial: [spawn, spawn+100 ms], spawn = deadline_ns - 100 ms (CLOCK_MONOTONIC, same as perf -k mono).
m1 host fsync calls starting in window (+ ms of host fsync overlapping the window)
m2 jbd2 commits overlapping window
m3 host on-CPU ms in window
m4 trial shell tasks (bash/mv, not the Host): D-state ms, preempted-runnable ms, on-CPU ms in window
"""
import json
import re
import sys
from collections import defaultdict

block = json.load(open(sys.argv[1]))
host_pid = block["host_pid"]
host_tids = set(block["host_tids"])
import os
STORE_DIR = os.stat(os.path.join(block["state"], "store")).st_ino
SCRATCH_DIR = os.stat(os.path.join(block["state"], "store", "scratch")).st_ino
LINE = re.compile(r"^\s*(.+?)\s+(\d+)/(\d+)\s+([\d.]+):\s+(\S+):\s?(.*)$")
fs_enter, fs_spans, commits, exec_events = [], [], [], []
open_fsync, open_commit = {}, {}
# per tid list of (t, state) where state in running/R/D/S
timeline = defaultdict(list)
comm_of = {}
for raw in open(sys.argv[2], errors="replace"):
    m = LINE.match(raw)
    if not m:
        continue
    comm, pid, tid, t, event, trace = m.group(1), int(m.group(2)), int(m.group(3)), float(m.group(4)), m.group(5), m.group(6)
    if pid == host_pid:
        host_tids.add(tid)
    if event == "ext4:ext4_sync_file_enter" and tid in host_tids:
        parent = int(re.search(r"parent (\d+)", trace).group(1))
        fs_enter.append((t, "store" if parent == STORE_DIR else "scratch" if parent == SCRATCH_DIR else "other"))
        open_fsync[tid] = t
    elif event == "ext4:ext4_sync_file_exit" and tid in open_fsync:
        fs_spans.append((open_fsync.pop(tid), t))
    elif event == "jbd2:jbd2_start_commit":
        open_commit[re.search(r"transaction (\d+)", trace).group(1)] = t
    elif event == "jbd2:jbd2_end_commit":
        key = re.search(r"transaction (\d+)", trace).group(1)
        if key in open_commit:
            commits.append((open_commit.pop(key), t))
    elif event == "sched:sched_process_exec":
        exec_events.append((t, trace.split()[0].split("=", 1)[1], tid))
    elif event == "sched:sched_switch":
        f = dict(kv.split("=", 1) for kv in re.findall(r"(\w+=\S+)", trace))
        prev, nxt = int(f["prev_pid"]), int(f["next_pid"])
        state = f["prev_state"][0]
        timeline[prev].append((t, "R" if state == "R" else state))
        comm_of[prev] = f["prev_comm"]
        timeline[nxt].append((t, "running"))
        comm_of.setdefault(nxt, f["next_comm"])


def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def state_ms(tid, lo, hi):
    out = defaultdict(float)
    events = timeline.get(tid, [])
    for (t0, s), (t1, _) in zip(events, events[1:]):
        out[s] += overlap(t0, t1, lo, hi) * 1000
    return out


first_seen = {tid: ev[0][0] for tid, ev in timeline.items() if ev}
for row in block["rows"]:
    if row.get("deadline_ns") is None:
        print(json.dumps({**row, "mechanism": None}))
        continue
    hi = row["deadline_ns"] / 1e9
    lo = hi - 0.1
    execs = [(t - lo) * 1000 for t, name, _ in exec_events if name == "/bin/bash" and lo - 0.005 <= t <= hi]
    host = defaultdict(float)
    for tid in host_tids:
        for s, v in state_ms(tid, lo, hi).items():
            host[s] += v
    shell = defaultdict(float)
    # Trial tasks: bash/mv tasks that first appear in this window (excludes other shells in the orb).
    for tid in [x for x, c in comm_of.items() if c in ("bash", "mv") and x not in host_tids and lo - 0.005 <= first_seen.get(x, -1) <= hi]:
        for s, v in state_ms(tid, lo, hi).items():
            shell[s] += v
    print(json.dumps({**row, "mechanism": {
        "bash_exec_after_spawn_ms": round(execs[0], 3) if execs else None,
        "m1_host_store_fsyncs": sum(1 for t, k in fs_enter if lo <= t < hi and k == "store"),
        "m1_host_scratch_fsyncs": sum(1 for t, k in fs_enter if lo <= t < hi and k == "scratch"),
        "m1_host_other_fsyncs": sum(1 for t, k in fs_enter if lo <= t < hi and k == "other"),
        "m1_host_fsync_ms": round(sum(overlap(a, b, lo, hi) for a, b in fs_spans) * 1000, 3),
        "m2_jbd2_commits": sum(1 for a, b in commits if overlap(a, b, lo, hi) > 0 or lo <= a < hi),
        "m3_host_oncpu_ms": round(host["running"], 3),
        "m4_shell_D_ms": round(shell["D"], 3),
        "m4_shell_preempted_ms": round(shell["R"], 3),
        "m4_shell_oncpu_ms": round(shell["running"], 3),
    }}))
