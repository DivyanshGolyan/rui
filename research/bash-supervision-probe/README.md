# Throwaway Bash supervision and disk-capture probe

6 September 2026. Question: can real child supervision and stdout/stderr disk capture stay small without one worker/stack/output buffer per command?

**Yes, for this narrow native prototype.** Three full 1,000-child output cohorts reached their readiness barrier and completed: median sampled parent physical footprint **1.563 MiB**, about **768 KiB above its own baseline**, on one thread. This supports the selected reactor/disk-first topology. It is not the final OnePage Bash implementation or a whole-Host memory budget.

## Method

`probe.c` is one C parent with `posix_spawn`, `poll`, `waitpid(WNOHANG)`, immediately unlinked scratch files and a shared 16 KiB read/copy window. Each launch runs `/bin/bash --noprofile --norc -c` with a constant command that execs this binary's tiny fixture producer. There is a real shell dispatch, but the producer replaces Bash; this does not measure a shell interpreter remaining resident or arbitrary model commands. All fixture process memory is excluded from the parent measurement, as required for model-selected workload accounting.

A shared readiness pipe proves every child reached the fixture before a shared stdin gate releases the full cohort. Stdout and stderr have separate nonblocking read ends and separate scratch files. The parent drains at most one window per ready stream per iteration and handles child exit independently of pipe EOF. File writes are synchronous. Logical scratch growth is reserved before each write and refunded on partial completion; quota failure kills the affected process group and retains captures until safe cleanup. No SQLite, permissions, durable results, provider work, external network or production source is involved.

One owner is 56 bytes in this prototype; two poll entries add 16 bytes per child. At 1,000, their arrays total 72,000 bytes, plus the shared 16,384-byte window. These are named allocations, not final Host structs or total incremental RAM. The fixture has one common readiness/deadline arrangement and does not include production per-operation intent, timeout/control identity or command materialization.

macOS task VM info samples parent physical footprint/RSS during spawning, at the ready barrier and each processing iteration. The OS lifetime RSS peak is separate. Sampling can miss short peaks. FD observer storage (65,536 bytes) is pre-touched before baseline; measurement overhead remains part of this small process. No allocator high-water instrumentation or separate kernel/child-memory total is claimed. The initial smoke run exposed an observer bug: querying FD buffer capacity is not an exact FD count; it was corrected to enumerate actual descriptors before recorded runs.

## Results

Three repetitions per population/output size, rotated 100/500/1,000 cohort order and alternating silent/output order; fresh parent for each cell. Native Apple Clang `-O2 -Wall -Wextra -Werror`; exact platform and source hash are in raw results.

| Ready children | Bytes per stdout/stderr | Median sampled parent peak MiB | Median added KiB | Observed peak parent FDs |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 0 | 1.313 | 512.125 | 404 |
| 100 | 65,536 | 1.313 | 512.125 | 404 |
| 500 | 0 | 1.454 | 656.125 | 2,004 |
| 500 | 65,536 | 1.329 | 528.125 | 2,004 |
| 1,000 | 0 | 1.548 | 752.188 | 4,004 |
| 1,000 | 65,536 | 1.563 | 768.250 | 4,004 |

All recorded cases have one parent thread, no launch errors and exact requested cohort readiness. Parent descriptors return to three. The FD column is an observed sample, not a startup requirement: spawn briefly holds extra pipe ends, and the fixture has readiness/gate descriptors. Sizing must include transient overlap rather than treating 4,004 as an exact maximum. Retained footprint commonly equals the sampled peak after cleanup; free resources need not return allocator/library pages immediately.

The 22-case main run started/reaped **10,130 children**: 10,110 normal completions, ten expected cancellations and ten forced scratch-quota failures. Additional four-case output-size comparison started/reaped 400 successful children. All successful stdout/stderr files are reread and every byte checked against an independent per-child/per-stream pattern, with exact lengths. Failed captures are checked as valid prefixes. Every recorded case ends with zero scratch charge and no named scratch files; every child is reaped.

Coverage includes both output streams, silent children, pipe EOF before delayed child exit, killing a held cohort, quota exhaustion, and five waves of 100 children in one parent. Churn verifies repeated cleanup, not indefinite resident-memory stability; per-wave footprint snapshots were not retained separately.

The separate output-size check, at 100 children, compares 64 KiB versus 1 MiB per stream in A/B/B/A order. Total captured data rises from **12.5 MiB to 200 MiB**. Both large-output runs have sampled parent footprint **1,376,896 bytes (1.313 MiB)**; small-output runs have 1,376,896 and 1,311,360 bytes. Output size grows scratch usage without comparable parent memory growth. Cached file writes, no fsync; no storage throughput or control-latency guarantee follows.

## Limits

- Shared buffer reuse requires synchronous completion here. A production async write that retains a buffer must account for that concurrent owner rather than call the memory shared for free.
- No realistic large command/input materialization, descendant tree behavior, signals racing PID reuse, partial OS-write injection, process crash/recovery, per-command timeout policy, durable control admission or Store contention qualification.
- The 8 GiB default in the fixture is an experimental copy of the accepted allowance, not a new quota. It exercises a much smaller allowance for the failure case. Temporary directories/children belong solely to this run; normal completion removes everything. Timeout handlers kill owned children; abnormal native crashes remain prototype limitations.
- Runtime process limits were inspected but not changed system-wide. Only the child supervisor's own FD soft limit may be raised within its inherited hard limit if necessary. The tested Mac allowed all 1,000-child cohorts. Different launch environments and system load can differ.
- Parent cost is not a universal per-child rate: baseline/library initialization, allocation pages, descriptors and measurement state contribute. Do not add this whole process peak to the model prototype as if shared baselines were disjoint.

## Reproduce

```sh
python3 research/bash-supervision-probe/run.py
python3 research/bash-supervision-probe/large_output.py
```

Requires macOS, Python 3 and Apple Clang. Runners build inside private temporary directories, use synthetic data only, and record results alongside this report. `results.json`, `summary.json` and `large-output-results.json` retain every measured case. Build and whitespace checks passed; no production suite was run because production was unchanged.
