#!/usr/bin/env python3
"""CPU occupancy by comm during the child's runnable interval from wakeup_new to first switch-in."""
import json, re, sys, collections
R = re.compile(r'^\s*(.*?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+):\s*(.*)$')
A = json.load(open('analysis.json'))
for run in sys.argv[1:]:
    a = A[run]; C = a['child_pid']
    sw = []
    for line in open(f'{run}.script.txt'):
        m = R.match(line)
        if m and m.group(5) == 'sched:sched_switch': sw.append((int(m.group(3)), float(m.group(4)), m.group(6)))
    wake = next(float(R.match(l).group(4)) for l in open(f'{run}.script.txt') if 'sched_wakeup_new' in l and f'pid={C} ' in l)
    seg = a['child_segments_ms'][0]; lo = wake; hi = wake + (seg[2] - seg[1]) / 1000
    occ = collections.Counter(); cur = {}
    for cpu, t, tr in sw:
        nxt = re.search(r'next_comm=(.*?) next_pid=(\d+)', tr); prv = re.search(r'prev_comm=(.*?) prev_pid=(\d+)', tr)
        if cpu in cur:
            c0, t0 = cur[cpu]; a0, b0 = max(t0, lo), min(t, hi)
            if b0 > a0: occ[c0] += (b0 - a0) * 1000
        elif t > lo:
            a0, b0 = lo, min(t, hi)
            if b0 > a0: occ[f'{prv.group(1)}(before-first-switch)'] += (b0 - a0) * 1000
        cur[cpu] = (f'{nxt.group(1)}', t)
    for cpu, (c0, t0) in cur.items():
        a0, b0 = max(t0, lo), hi
        if b0 > a0: occ[c0] += (b0 - a0) * 1000
    print(run, f'runnable {round((hi-lo)*1000,3)} ms x 2 CPUs; occupancy ms:', {k: round(v, 3) for k, v in occ.most_common(8)})
