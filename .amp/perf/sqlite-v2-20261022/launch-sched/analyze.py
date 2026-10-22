#!/usr/bin/env python3
"""Child launch timeline from system-wide perf (sched, page_fault_user, raw_syscalls). Usage: analyze.py RUN..."""
import re, sys, json, collections
R = re.compile(r'^\s*(.*?)\s+(\d+)\s+\[(\d+)\]\s+([\d.]+):\s+(\S+):\s*(.*)$')
def parse(path):
    for line in open(path):
        m = R.match(line)
        if m: yield m.group(1), int(m.group(2)), int(m.group(3)), float(m.group(4)), m.group(5), m.group(6)
out = {}
for run in sys.argv[1:]:
    ev = list(parse(f"{run}.script.txt"))
    ex = [e for e in ev if e[4] == 'sched:sched_process_exec' and 'filename=/bin/bash' in e[5]][0]
    C = ex[1]
    fk = [e for e in ev if e[4] == 'sched:sched_process_fork' and f'child_pid={C} ' in e[5] + ' '][0]
    P = fk[1]
    t_fork = fk[3]
    clone_enter = [e for e in ev if e[1] == P and e[4] == 'raw_syscalls:sys_enter' and e[3] <= t_fork and re.match(r'NR (56|435) ', e[5])][-1]
    clone_exit = [e for e in ev if e[1] == P and e[4] == 'raw_syscalls:sys_exit' and e[3] >= t_fork and re.match(r'NR (56|435) ', e[5])][0]
    wake = [e for e in ev if e[4] == 'sched:sched_wakeup_new' and f'pid={C} ' in e[5]][0]
    first_sys = [e for e in ev if e[1] == C and e[4] == 'raw_syscalls:sys_enter'][0]
    exec_enter = [e for e in ev if e[1] == C and e[4] == 'raw_syscalls:sys_enter' and e[5].startswith('NR 59 ')][0]
    t0, tend = clone_enter[3], ex[3]
    # Child state intervals from birth (wakeup_new) to exec completion.
    state, since, acc, segs = 'R', wake[3], collections.Counter(), []
    def close(t, s):
        global since
    cur = ('R', wake[3])
    marks = {'first_syscall': first_sys[3]}
    for e in ev:
        if e[3] < wake[3] or e[3] > tend: continue
        if e[4] != 'sched:sched_switch': continue
        t = e[5]
        if f'next_pid={C} ' in t + ' ':
            segs.append((cur[0], cur[1], e[3])); cur = ('on-cpu', e[3])
        elif f'prev_pid={C} ' in t:
            st = re.search(r'prev_state=(\S+)', t).group(1)
            segs.append((cur[0], cur[1], e[3])); cur = ('runnable' if st.startswith('R') else f'blocked:{st}', e[3])
    segs.append((cur[0], cur[1], tend))
    segs = [('runnable' if s == 'R' else s, a, b) for s, a, b in segs]
    def split(segs, lo, hi):
        c = collections.Counter()
        for s, a, b in segs:
            a2, b2 = max(a, lo), min(b, hi)
            if b2 > a2: c[s] += (b2 - a2) * 1000
        return {k: round(v, 3) for k, v in sorted(c.items())}
    faults = [e for e in ev if e[1] == C and e[4] == 'exceptions:page_fault_user' and e[3] <= tend]
    pfaults = [e for e in ev if e[1] == P and e[4] == 'exceptions:page_fault_user' and clone_exit[3] <= e[3] <= tend]
    nr = lambda e: int(re.match(r'NR (\d+)', e[5]).group(1))
    child_sys = [nr(e) for e in ev if e[1] == C and e[4] == 'raw_syscalls:sys_enter' and e[3] <= exec_enter[3]]
    mig = [e for e in ev if e[4] == 'sched:sched_migrate_task' and f'pid={C} ' in e[5] and e[3] <= tend]
    ms = lambda a, b: round((b - a) * 1000, 3)
    r = {
        'child_pid': C, 'parent_tid': P, 'child_exec_comm': ex[0],
        'clone_entry_to_return_ms': ms(clone_enter[3], clone_exit[3]),
        'clone_entry_to_fork_event_ms': ms(t0, t_fork), 'clone_entry_to_wakeup_new_ms': ms(t0, wake[3]),
        'clone_return_to_child_first_syscall_ms': ms(clone_exit[3], first_sys[3]),
        'wakeup_new_to_child_first_syscall_ms': ms(wake[3], first_sys[3]),
        'first_syscall_nr': nr(first_sys),
        'clone_entry_to_execve_entry_ms': ms(t0, exec_enter[3]), 'clone_entry_to_exec_done_ms': ms(t0, tend),
        'child_states_birth_to_first_syscall_ms': split(segs, wake[3], first_sys[3]),
        'child_states_first_syscall_to_exec_done_ms': split(segs, first_sys[3], tend),
        'child_user_faults_before_first_syscall': sum(1 for f in faults if f[3] < first_sys[3]),
        'child_user_faults_first_syscall_to_execve_entry': sum(1 for f in faults if first_sys[3] <= f[3] < exec_enter[3]),
        'child_user_faults_after_execve_entry_to_exec_done': sum(1 for f in faults if f[3] >= exec_enter[3]),
        'parent_user_faults_clone_return_to_exec_done': len(pfaults),
        'child_syscalls_before_execve': child_sys, 'child_migrations': len(mig),
        'child_segments_ms': [(s, ms(t0, a), ms(t0, b)) for s, a, b in segs],
    }
    # Who ran on CPUs while the child was runnable-not-running before its first syscall.
    others = collections.Counter()
    runnable = [(a, b) for s, a, b in segs if s == 'runnable' and a < first_sys[3]]
    for e in ev:
        if e[4] != 'sched:sched_switch': continue
    out[run] = r
    print(json.dumps({run: {k: v for k, v in r.items() if k != 'child_segments_ms'}}, indent=1))
    print(' segments (ms from clone entry):', r['child_segments_ms'])
json.dump(out, open('analysis.json', 'w'), indent=1)
