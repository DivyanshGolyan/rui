# Launch follow-up results (design in PREDECLARED.md, written before data)

Arms: base = exact bbabd879 fork baseline (rui 0b202d4ab3adba3c…), cand = af5ecee8 SQLite v2 on bbabd879, 100 ms
(rui 6cd7670789a29fa5…). Observer: system-wide perf only, no strace (perf sha256 in identity.sha256). 12 Hosts, order
(B C C B) x3, 10 launches each, CPU load 4 busy loops on 2 vCPU. All blocks exited 0; all 120 launches resolved
timed_out. PID published before kill: base 47/60, cand 50/60 (failure history, not used as a rate test).

| metric (60 launches/arm) | base | cand |
|---|---|---|
| birth→exec median / p90 | 12.46 / 64.25 ms | 13.08 / 42.29 ms |
| initial runnable wait median | 11.42 ms | 11.80 ms |
| runnable share of birth→exec, median (min) | 97.2% (86.2%) | 97.3% (86.5%) |
| child on-CPU birth→exec, median (max) | 0.347 (0.889) ms | 0.347 (0.569) ms |
| launches with child on-CPU ≤ 1 ms | 60/60 | 60/60 |
| clone duration median (max) | 0.146 (3.617) ms | 0.155 (0.792) ms |
| child / parent user faults, median | 27 / 11 | 26 / 10 |
Per-block birth→exec medians (ms): 01B 9.51, 02C 8.01, 03C 8.11, 04B 15.70 | 05B 9.92, 06C 14.71, 07C 15.90, 08B 11.13 |
09B 27.67, 10C 20.56, 11C 23.10, 12B 22.24. Per-quad C−B: −4.5, +4.8, −3.1 ms.

Predeclared verdict: scheduler attribution holds in both arms (median runnable share ≥ 90%, on-CPU ≤ 1 ms in 60/60).
Fork/CoW attribution does not: clone plus all child on-CPU time (which bounds fault service, pre-exec syscalls and exec)
is ~0.5 ms median and equal across arms. Arm difference: +0.62 ms median, sign varies by quad; not powered for ~3.5 ms,
so this does not prove zero v2 effect, but no consistent candidate delay appears.
Limits: perf reported lost chunks / overload in 8 of 12 blocks (04,05,06,07,08,09,11,12); lost switch events can
mislabel segments. Loss-free blocks only (base n=10, cand n=30): runnable share 96.4% / 95.8%, on-CPU max 0.365 /
0.569 ms, same conclusion. perf itself competes for CPU. Fault counts are not durations. One orb; times drift upward
across the session (later blocks slower in both arms). perf.data/script.txt (~1.2 GB) stay in the orb; hashes in
perf-data.sha256; per-launch rows in rows.json.
