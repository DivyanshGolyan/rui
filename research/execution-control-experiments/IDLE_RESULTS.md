# Measured empty-table idle CPU

Machine: Apple M1 Pro; macOS-15.7.7-arm64-arm-64bit-Mach-O. Compiler: Apple clang version 17.0.0 (clang-1700.0.13.5), `-std=c11 -O2 -Wall -Wextra -Werror -pthread`.

Command: `python3 research/execution-control-experiments/run_idle.py` from the experiment worktree.

A reactor thread waits on a condition variable over a fixed empty table with 128-byte records. One helper thread signals it after a one-second sleep. The external-wake-only mode has no timeout; the comparison uses a 5 ms timeout and scans after every wait return. Both scan on the final external wake. No busy loop is used. The entire process's actual CPU time comes from `CLOCK_PROCESS_CPUTIME_ID`; wall time uses `CLOCK_MONOTONIC`.

| Capacity | Mode | Repetition | Wall ms | Process CPU ms | CPU % of one core | Wait returns / scans | Timeouts |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | external_wake_only | 1 | 1008.72 | 0.335 | 0.0332 | 1 | 0 |
| 100 | timed_wait_5ms | 1 | 1008.67 | 3.126 | 0.3099 | 154 | 153 |
| 1000 | external_wake_only | 1 | 1002.39 | 0.270 | 0.0269 | 1 | 0 |
| 1000 | timed_wait_5ms | 1 | 1010.38 | 3.143 | 0.3111 | 152 | 151 |
| 100 | timed_wait_5ms | 2 | 1004.33 | 1.749 | 0.1741 | 142 | 141 |
| 100 | external_wake_only | 2 | 1008.40 | 0.146 | 0.0145 | 1 | 0 |
| 1000 | timed_wait_5ms | 2 | 1010.13 | 2.788 | 0.2760 | 149 | 148 |
| 1000 | external_wake_only | 2 | 1006.85 | 0.160 | 0.0159 | 1 | 0 |
| 100 | external_wake_only | 3 | 1001.95 | 0.189 | 0.0189 | 1 | 0 |
| 100 | timed_wait_5ms | 3 | 1002.65 | 2.446 | 0.2440 | 152 | 151 |
| 1000 | external_wake_only | 3 | 1000.54 | 0.177 | 0.0177 | 1 | 0 |
| 1000 | timed_wait_5ms | 3 | 1010.22 | 3.362 | 0.3328 | 153 | 152 |

Median CPU percentages:

- 100, external_wake_only: 0.0189% of one core (range 0.0145%–0.0332%).
- 100, timed_wait_5ms: 0.2440% of one core (range 0.1741%–0.3099%).
- 1000, external_wake_only: 0.0177% of one core (range 0.0159%–0.0269%).
- 1000, timed_wait_5ms: 0.3111% of one core (range 0.2760%–0.3328%).

## Interpretation and limits

This measures synthetic idle scheduling cost, including the helper thread's creation, sleep, signal, and join; memory allocation and destruction are outside timing. It is not OnePage's whole-Host idle CPU baseline and does not include SQLite polling, real I/O multiplexing, transports, or evaluator work. Short one-second samples on an unpinned laptop cannot provide fine-grained energy or cross-machine guarantees. Capacity 1,000 is exploratory only.

The 5 ms timeout is a requested minimum wait, not an observed 200 Hz cadence: scheduler delay and timer coalescing can produce fewer returns. Use the measured wake counts, not a nominal poll frequency, when interpreting these CPU figures.

The comparison illustrates that scan-only arithmetic omits timed-wakeup overhead. Prefer sleeping until a real event when no deadline or durable poll requires a wake; the 5 ms setting is an experimental comparison, not a production cadence recommendation. It does not establish that the whole runtime may omit retry or command polling.

All scans assert the empty-table checksum is zero and scan count equals wait returns. The no-timeout mode asserts no timeout returns. Raw rows include the one intentional external signal; spurious successful wait returns would remain visible in the counts.
