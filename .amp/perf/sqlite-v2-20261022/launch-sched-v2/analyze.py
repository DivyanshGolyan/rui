#!/usr/bin/env python3
"""Per-launch child timeline (predeclared metrics). Usage: analyze.py BLOCK... (reads BLOCK.script.txt)"""
import re, sys, json, statistics as st
R = re.compile(r'^\s*(.*?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+):\s*(.*)$')
rows = []
for blk in sys.argv[1:]:
    ev = [(m.group(1), int(m.group(2)), int(m.group(3)), float(m.group(4)), m.group(5), m.group(6))
          for m in map(R.match, open(f'{blk}.script.txt')) if m]
    forks = {}
    for e in ev:
        if e[4] == 'sched:sched_process_fork':
            m = re.search(r'comm=(\S+) pid=(\d+) child_comm=\S+ child_pid=(\d+)', e[5])
            if m: forks[int(m.group(3))] = (m.group(1), e[1], e[3])
    for ex in [e for e in ev if e[4] == 'sched:sched_process_exec' and 'filename=/bin/bash' in e[5]]:
        C = ex[1]
        if C not in forks or forks[C][0] != 'rui': continue
        P, tf = forks[C][1], forks[C][2]
        ce = [e for e in ev if e[1] == P and e[4] == 'raw_syscalls:sys_enter' and e[3] <= tf]
        cx = [e for e in ev if e[1] == P and e[4] == 'raw_syscalls:sys_exit' and e[3] >= tf]
        wake = [e for e in ev if e[4] == 'sched:sched_wakeup_new' and re.search(rf'pid={C}\b', e[5])][0][3]
        tend = ex[3]
        segs, cur = [], ('runnable', wake)
        for e in ev:
            if e[4] != 'sched:sched_switch' or not (wake <= e[3] <= tend): continue
            if re.search(rf'next_pid={C}\b', e[5]): segs.append((*cur, e[3])); cur = ('on', e[3])
            elif re.search(rf'prev_pid={C}\b', e[5]):
                s = re.search(r'prev_state=(\S+)', e[5]).group(1)
                segs.append((*cur, e[3])); cur = ('runnable' if s.startswith('R') else 'blocked', e[3])
        segs.append((*cur, tend))
        tot = lambda k: sum(b - a for s, a, b in segs if s == k) * 1000
        first_in = next((a for s, a, b in segs if s == 'on'), tend)
        cret = cx[0][3] if cx else None
        rows.append({'block': blk, 'arm': blk.split('-')[1], 'child': C,
            'clone_ms': round((cx[0][3] - ce[-1][3]) * 1000, 3) if ce and cx else None,
            'birth_to_exec_ms': round((tend - wake) * 1000, 3),
            'initial_runnable_ms': round((first_in - wake) * 1000, 3),
            'runnable_ms': round(tot('runnable'), 3), 'on_cpu_ms': round(tot('on'), 3), 'blocked_ms': round(tot('blocked'), 3),
            'child_faults': sum(1 for e in ev if e[1] == C and e[4] == 'exceptions:page_fault_user' and e[3] <= tend),
            'parent_faults': sum(1 for e in ev if e[1] == P and e[4] == 'exceptions:page_fault_user' and cret and cret <= e[3] <= tend),
            'migrations': sum(1 for e in ev if e[4] == 'sched:sched_migrate_task' and re.search(rf'pid={C}\b', e[5]) and e[3] <= tend)})
json.dump(rows, open('rows.json', 'w'), indent=1)
q = lambda xs, p: sorted(xs)[min(len(xs) - 1, int(p * len(xs)))]
for arm in ('base', 'cand'):
    r = [x for x in rows if x['arm'] == arm]
    share = [x['runnable_ms'] / x['birth_to_exec_ms'] for x in r if x['birth_to_exec_ms'] > 0]
    print(arm, 'n', len(r), '| birth->exec median', st.median(x['birth_to_exec_ms'] for x in r), 'p90', q([x['birth_to_exec_ms'] for x in r], .9),
          '| runnable share median', round(st.median(share), 4), 'min', round(min(share), 4),
          '| on-cpu median', st.median(x['on_cpu_ms'] for x in r), 'max', max(x['on_cpu_ms'] for x in r),
          '| on-cpu<=1ms', sum(x['on_cpu_ms'] <= 1 for x in r),
          '| clone median', st.median(x['clone_ms'] for x in r if x['clone_ms'] is not None), 'max', max(x['clone_ms'] for x in r if x['clone_ms'] is not None),
          '| child faults median', st.median(x['child_faults'] for x in r), '| parent faults median', st.median(x['parent_faults'] for x in r),
          '| blocked max', max(x['blocked_ms'] for x in r))
for blk in sorted({x['block'] for x in rows}):
    r = [x for x in rows if x['block'] == blk]
    print(' ', blk, 'n', len(r), 'birth->exec median', st.median(x['birth_to_exec_ms'] for x in r), 'on-cpu median', st.median(x['on_cpu_ms'] for x in r))
