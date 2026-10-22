# Launch scheduler-vs-fork/CoW follow-up: predeclared before data (2026-10-22)

Question: across many launches without ptrace, is clone-return→bash-exec time runnable-not-scheduled wait (scheduler) or
child on-CPU time (fork/CoW faults, pre-exec work)? Does the candidate differ from the fork baseline?
Arms: B = exact bbabd879 fork baseline, rui 0b202d4a…; C = af5ecee8 (SQLite v2 on bbabd879, 100 ms), rui 6cd76707….
Not newer main (posix_spawn is a different mechanism).
Design: 12 Hosts, order (B C C B) x3, 10 trials each = 60 launches per arm, exact fixture command via
control/same_group_control_v2.py (timeout_ms=100), CPU load 4 busy loops on 2 vCPU. Observer: system-wide perf only (no
strace): sched_switch, sched_wakeup_new, sched_process_fork, sched_process_exec, sched_migrate_task,
exceptions:page_fault_user, raw_syscalls sys_enter/sys_exit filtered to clone/clone3 (clone duration only).
Per launch (child = /bin/bash exec whose fork parent is a rui thread): clone duration; wakeup_new→first switch-in
(runnable wait); child on-CPU from birth to exec completion; runnable time after first switch-in; child faults and parent
faults from clone return to exec; birth→exec total.
Primary: share of birth→exec spent runnable-not-running, per launch.
Decision rule:
- Scheduler attribution holds if, in both arms, median runnable share ≥ 90% AND child on-CPU birth→exec ≤ 1 ms in ≥ 95%
  of launches.
- Fork/CoW attribution would require child on-CPU (where faults are serviced) or clone duration to account for most of
  the birth→exec time, or to differ between arms by ≥ 1 ms in median.
- Arm difference: report median birth→exec difference and per-block medians; with 5 B/C block pairs this is not powered
  to detect ~3.5 ms (control-v2 spread); non-difference does not prove absence.
Limits stated up front: perf CPU overhead and buffer loss (check perf.log for lost samples); one orb; fault counts are not
durations (fault time is bounded by child on-CPU time).
