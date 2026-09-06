# One-at-a-time real QuickJS evaluator experiment

6 September 2026. Throwaway investigation of serial evaluation's memory cost and queueing tradeoff. This does not select a new concurrency limit or certify the complete Host.

## Verdict

One evaluator at a time is a viable simple starting candidate, with an explicit burst-delay tradeoff. Most ordinary synthetic cases took roughly 10–20 ms including process startup and safe exit/capture. A 50-job tiny burst drained in 0.462 seconds; 1,000 tiny jobs drained in 11.409 seconds, so the last waited 11.398 seconds before starting. A runaway CPU loop delayed the following tiny job by 1.010 seconds under the historical one-second CPU budget.

Do not describe “1,000 active operations” as a guarantee of promptly evaluating 1,000 workflows simultaneously. Serial evaluation limits neither the already-launched model/Bash/Edit population nor their execution concurrency, but it does delay new evaluation at a burst. If all 1,000 workflows must advance within a second, this candidate fails that requirement. No such evaluator burst-latency target has been selected here.

Recommend one evaluator as the initial design candidate; revisit only if representative workflow arrival/replay demand requires more throughput. This is a recommendation, not approval of all historical heap/frame/output limits or a production implementation decision.

## Actual code and scope

Uses the repository's actual QuickJS-ng evaluator and historical private protocol, compiled with `zig build evaluator-probe -Doptimize=ReleaseSafe`. The prototype branch applies the already accepted construction amendments: remove the child descriptor-number scan and remove full input/output/bridge overwrite/free immediately before process exit. Parent `posix_spawn` uses `POSIX_SPAWN_CLOEXEC_DEFAULT`, three explicit stdio bindings and an empty environment. Main checkout production source is unchanged.

A small C parent runs exactly one child at a time, drains stdout/stderr with a fixed 4 KiB buffer, observes exit asynchronously and closes all per-job handles before launching the next. Input fixtures are read directly through inherited stdin files; output is copied to private temporary test files. This is a candidate disk-first boundary, not the historical parent API that retains a complete output buffer. It omits Store snapshot construction, durable publication, permissions and actual control commands. The command-line batch is a test schedule, not a proposed resident or durable queue implementation.

The historical 16 MiB engine heap, 512 KiB stack guard, 768 KiB input mapping, 512 KiB output mapping, 2 MiB bridge, 64 KiB final-output limit, cardinality rules and CPU/wall settings remain unchanged to expose their behavior. They are not newly accepted policies. The parent also has a two-second emergency kill threshold, unused in recorded cases; this fixture safeguard is not a product timeout recommendation.

Workloads are synthetic representatives of evaluation shapes, not ports of saved user scripts: tiny completion, 64-way fan-out, partial replay, aggregation of 256 KiB of prior results, a 60 KiB result, a rejected 700 KiB result, 20,000 temporary objects, heap exhaustion and runaway CPU. The historical `agent` protocol is not the accepted new keyed Session API.

## Measurements

Five shuffled repetitions of every workload, with one live child per parent. Values below are medians; output and expected failure classifications are independently decoded and checked by Python.

| Workload | Service ms | Child OS peak RSS MiB | Outcome |
| --- | ---: | ---: | --- |
| Tiny completion | 12.175 | 5.516 | Correct result |
| Aggregate 64 prior results, 256 KiB total | 14.897 | 5.922 | Correct total |
| 20,000 temporary objects | 21.452 | 9.453 | Correct count |
| Heap exhaustion | 55.544 | 19.578 | Existing `WorkflowRejected` result, not a forged memory-specific diagnosis |
| Runaway CPU | 1,012.193 | 5.547 | Existing `CpuTime` resource outcome |

Raw data also includes physical-footprint samples of child and parent, and the largest simultaneously sampled sum. For heap exhaustion, median sampled child physical footprint was 18.532 MiB and combined parent+child was 19.376 MiB. Increment above that parent's baseline was 18.626 MiB. The 256 KiB aggregation combined sample median was 5.626 MiB. These are sampled observations, not continuous physical-footprint maxima or final incremental Host costs.

**Short evaluations can finish useful work between samples.** For example tiny-case median sampled child physical peak was only 0.969 MiB versus OS lifetime RSS peak 5.516 MiB. RSS and physical footprint are different metrics, but the limited sampling cadence is another reason not to use the small sample as a complete resident-memory bound. Parent/child samples are sequential reads, not an atomic system snapshot. Whole-OnePage physical-footprint qualification remains required.

One initial 60 KiB result case took 375.706 ms despite a 14.889 ms median. Cold-start/system/storage effects were not isolated; do not claim every ordinary evaluation takes 20 ms or less. Input/output scratch uses cached file writes without fsync or SQLite; service time covers spawn through output/error closure and child reap.

## Serial batches and controls boundary

| Batch | Jobs | Last job starts after ms | Batch finishes after ms |
| --- | ---: | ---: | ---: |
| Tiny burst | 50 | 453.040 | 461.721 |
| Runaway then ten tiny jobs | 11 | 1,109.664 | 1,117.354 |
| 256 KiB aggregation burst | 20 | 229.938 | 239.718 |
| Tiny burst at planned population | 1,000 | 11,398.138 | 11,409.404 |

The first tiny job behind the runaway started after 1,009.609 ms. Poll-loop service gaps during active-child monitoring were at most 2.625 ms in the initial 126-job run. **These are synthetic loop gaps, not real control acknowledgements.** They exclude the synchronous spawn/setup interval and do not exercise database commits, command parsing, model transport or concurrent captures. The asynchronous shape permits servicing other work while JavaScript runs, but this is not p95 durable-control certification.

Both runs together passed 1,126 evaluations with expected outputs/outcomes, no parent emergency timeout, no abnormal child exit, and descriptor return to baseline after every evaluation. Tests verify 64 unique requested keys, the exact remaining half on partial replay, aggregate values, large output bytes and rejection codes. Repeated serial jobs exercise cleanup but do not certify indefinite allocator/Store history stability.

The 700 KiB report is rejected by `WorkflowOutputBytes` at the current 64 KiB output cap even though the observed child footprint is modest (sample median 6.485 MiB). This reinforces that the historical size caps need their own compatibility/containment review; the experiment does not establish support for large saved-workflow reports. Do not count rejection as successful bounded-memory execution of the requested large result.

## Remaining decisions

1. Accept serial evaluation's burst delay explicitly, or select a tested throughput requirement before adding parallel evaluators. Waiting work must remain derived from durable Run facts, without keeping evaluator processes alive.
2. Review actual heap/CPU/wall containment and the separate historical payload/frame/cardinality limits in their owning decision. The numbers above measure existing settings, not justify them all.
3. Integrate disk-first snapshot/results, safe subprocess construction and durable controls before adding the evaluator term to a whole-Host qualification result. Do not add standalone parent baselines twice.

## Reproduce

```sh
zig build evaluator-probe -Doptimize=ReleaseSafe
python3 research/evaluator-serial-probe/run.py
python3 research/evaluator-serial-probe/run.py --burst-only
```

Requires macOS, Apple Clang, Python 3 and repository Zig dependencies. Raw synthetic inputs/results exist only in temporary directories during the run; aggregate measurements remain in `results.json`, `summary.json`, `burst-results.json` and `burst-summary.json`. Binary hashes are recorded. No providers, user transcripts, machine-wide configuration changes or main-worktree production edits. Native crashes remain prototype limitations; timeout handling kills the active child. No separate benchmark of alternate concurrency was performed.
