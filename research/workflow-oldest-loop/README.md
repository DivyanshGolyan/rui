# Oldest-eligible workflow loop probe

Use the simple oldest-eligible loop. The fixtures support it when evaluations take milliseconds and Turns take seconds to minutes. No rotating cursor, ready queue or per-Run timer is needed for these traces. This is a throwaway prototype, not production qualification.

Run `python3 research/workflow-oldest-loop/run.py` from this worktree. It requires clang and the repository's pinned SQLite archive in the local Zig cache. `results.json` records the complete run and query plans. `oldest.sql` is the candidate selection query. The schema represents original result ownership and pending keyed dependencies; its integer keys are fixture conveniences, not a proposed public format.

## Query evidence

The harness calls pinned SQLite 3.53.4 directly through ctypes, using DELETE journaling, EXTRA synchronization, a 256 KiB cache, file-backed temporary storage and no mmap. Each warm prepared-query case has nine repetitions. Reported CPU includes Python/ctypes overhead and is not whole-Host CPU. A partial creation-order index excludes cancelled and terminal Runs. Eligibility includes new Runs, interrupted evaluations and at least one newly available unresolved result.

| Waiting Runs | Dependencies each | Empty-query median CPU |
|---:|---:|---:|
| 10 | 1 | 0.014 ms |
| 1,000 | 1 | 0.574 ms |
| 10,000 | 1 | 5.212 ms |
| 100,000 | 1 | 59.077 ms |
| 1,000 | 16 | 4.115 ms |
| 10,000 | 16 | 43.728 ms |

Adding 100,000 terminal Runs to the 1,000-waiter case yielded 0.560 ms. Selecting the oldest ready Run took approximately 0.007–0.011 ms; finding only the newest ready Run cost approximately the empty scan. LIMIT 1 bounds returned rows, not examined dependencies. At one empty query per second, 59 ms CPU per query alone implies approximately 5.9% of one core; it cannot qualify the existing idle-CPU target at that population. These measurements do not establish an unavoidable lower bound or select new product limits.

## Loop evidence

Virtual-time traces execute the actual SQLite query and update saved facts, assuming a 20 ms complete evaluation lifecycle. SQLite execution time is measured separately and is not added to virtual time. These are conditional scheduling models, not measured QuickJS or Host throughput. Completion events live in a harness heap representing external Turns; that heap is not proposed Host scheduling state.

| Trace | Result |
|---|---|
| 100 Runs, two-second Turns, 180 seconds | Every Run evaluated 60 times; maximum ready-to-start delay 0.99 seconds |
| 1,000 Runs, minute-long Turns, 240 seconds | Every Run evaluated 3–4 times; maximum delay 0.98 seconds |
| 1,000 Runs becoming ready together | All evaluated once; 20 seconds evaluation work, final start 20.73 seconds after readiness |

The burst includes idle discovery delay and does not insert a one-second gap between evaluations. Ordinary traces consume each completed dependency before waiting for the next result, so an already-consumed result cannot repeatedly select a Run.

A separate overload sensitivity uses 1,000 Runs with ten-second Turns: 498 younger Runs were never selected in the 180-second observation. Each Turn is still 500 times longer than one evaluation, but aggregate demand exceeds serial evaluator capacity. Oldest-first is not unconditionally starvation-free. This does not change the selected baseline or justify an additional scheduler by itself.

The real five-second asyncio fixture uses actual SQLite selection, a one-second asynchronous idle timer and a 20 ms simulated evaluator delay. A shared result completed at 1.254 seconds. Evaluations started at 2.004 and 2.029 seconds, 24.7 ms apart. An independent 50 ms heartbeat ran 81 times with a maximum observed gap of 70.5 ms. This demonstrates the asynchronous wait and immediate recheck shape, not production control latency.

## Scope

All query assertions and four recorded check groups passed, including creation-time ties, cancellation/terminal exclusion, interruption/new-Run discovery, multi-dependency eligibility, and the asynchronous loop. No production code changed. No live provider, actual QuickJS evaluation, real Host service integration, concurrent cancellation/admission fence, crash recovery or release resource gate was exercised here. The earlier evaluator prototypes provide separate measurements; a fixed 20 ms model cannot substitute for their workload-dependent lifecycle costs. Production discovery work and existing resource/control-response targets still need qualification.
