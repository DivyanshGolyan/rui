# Linux fixture attribution appendix

These are measured Linux fixture counts, not live-provider results, Mac footprint results, or elapsed-time benchmarks. Rui production code and durability settings are unchanged. Positional reads dominate syscall counts, but curl/OpenSSL names dominate the sampled user stacks. Those observations measure different costs.

## Work and counter scope

The product is an explicit ReleaseFast build of [main/stable baseline](https://github.com/DivyanshGolyan/rui/commit/240aef2e46d7240ce31a02ce4cefceb695551a56). Its SHA-256 is `b843b47aca5f06488101f52ea5714716d96d8e039068b7a11bf03362d16cdbb2`. The VM has two logical x86-64 CPUs, Linux 6.1.158+, Zig 0.17.0 and Go 1.27.1. File-descriptor soft limit is 1,024, not a raised Mac terminal limit. [Initial identity](raw/identity.txt) and [final binary/source hashes](raw/final-binary-source-identity.sha256) retain the environment and artifact identities.

A Message means one admitted user Message. An event means one 260-byte nonterminal SSE record emitted by the fixture and covered by capture/result checks. Terminal protocol traffic remains in the numerator but outside the event denominator.

| Measured fixture | Messages | Events | Transport and offered work |
| --- | ---: | ---: | --- |
| STREAM N=1 | 2 | 3,600 | H1, 30 events/second/stream, two 60-second rounds on one Host |
| STREAM N=100 | 200 | 1,200,000 | Trusted local TLS/H2, 100 events/second/stream, two 60-second rounds on one Host |
| HOLD N=100 | 100 | 0 | Trusted local TLS/H2, 100 accepted requests, no response bytes during observation |

All Host counters exclude provider, controller and CLI processes. Whole-run counts include initialization, configuration, observation, result delivery and teardown. Per-Message numbers amortize those costs and are not marginal costs. N=1 and N=100 have different offered rates and transports, so this is not a controlled scaling curve. Instrumented runs provide counts only. Their retained JSON and tool output contain times that are not reported as performance results.

## Measured syscall and SQLite counts

Each row is a separate run. `fdatasync` was observed zero times in each complete strace summary, not inferred from an unavailable counter.

| Measured Host count | STREAM N=1, quiet | STREAM N=100, quiet | HOLD N=100 |
| --- | ---: | ---: | ---: |
| All syscalls | 170,960 | 12,625,760 | 792,106 |
| Syscalls/event | 47.48889 | 10.52147 | Undefined, zero events |
| Syscalls/Message | 85,480 | 63,128.8 | 7,921.06 |
| `fsync` calls | 59 | 4,812 | 1,705 |
| `fsync`/Message | 29.5 | 24.06 | 17.05 |
| SQLite statement first-executions | 8,909 | 433,586 | Not measured |
| Statements/Message | 4,454.5 | 2,167.93 | Not measured |
| Explicit `BEGIN` executions | 19 | 1,511 | Not measured |
| Explicit `COMMIT` executions | 9 | 801 | Not measured |
| Explicit `ROLLBACK` executions | 10 | 710 | Not measured |
| `COMMIT` executions/Message | 4.5 | 4.005 | Not measured |

SQLite is statically linked. A separate research-only binary registers `sqlite3_trace_v2(SQLITE_TRACE_STMT)` before opening the Store. The retained [instrumentation patch](sql-instrumentation.patch.gz) changes no SQLite configuration. The callback observes first execution, not successful completion. Automatic read transactions are not separately counted. Both Stores have 17 tables, 39 indexes and zero triggers. `BEGIN = COMMIT + ROLLBACK` in both logs; canonical durable audits pass. These checks do not turn a trace-start callback into a commit-completion counter.

SELECT accounts for 8,773 of 8,909 statements at N=1 and 425,912 of 433,586 at N=100. Statement count is mostly repeated reads, not durable writes. Statement counts come from a separate instrumented binary, so they do not partition the strace run exactly.

N=100 records 8,491,607 `preadv` calls, 7.076 per event and 67.3% of all calls. Baseline `src/provider_output.zig:1650–1745` scans each SSE record and rereads line endings, prefix, whitespace, event JSON and type ranges. About seven reads per event plus bulk scanning matches the count. This is source-supported attribution, not a measured exclusive CPU cost. No optimization was implemented.

Diagnostic-enabled N=1 records 284,834 calls, compared with 170,960 in the quiet control. The pre-control estimate subtracts 22,830 diagnostic events × five calls = 114,150 calls. The observed reduction is 113,874, within 276 calls of that estimate. Phase tracing performs three `fcntl` calls, a write and a `getpid` per diagnostic event. Optional trace records report loss; the complete strace totals do not depend on optional trace completeness.

## Measured native allocations and sampled user stacks

Heaptrack ran only at N=1. It recorded 21,021 libc allocation calls, or 10,510.5 per Message. `sqlite3MemMalloc` contributes 16,726 and `sqlite3MemRealloc` 811, together 83.43%. `CRYPTO_malloc` contributes 3,067, or 14.59%, including initialization even on the H1 fixture. This is cumulative allocation traffic, not retained bytes. Arena suballocations and direct-page allocations are outside this counter.

The existing Go controller ordinarily kills the Host after drain. An isolated opt-in controller instead requests `host stop`, waits for process exit, and then uses the existing reap and offline audit. That lets heaptrack finish. The Host reports `EffectAwareShutdown` and exits 1, which is retained in [its raw stderr](raw/heap1-host.log.gz). Baseline `src/server.zig:705` returns that fallback after listener closure and exchange drain. A finished heaptrack profile is not evidence of a clean Host exit.

The sole N=100 profile has 4,466 `cpu-clock:u` samples and zero reported lost samples. The regex-based groups below overlap and are not exclusive CPU percentages. [The reducer](analyze.py) records the exact patterns.

| Measured named stack family | Samples | Fraction of user samples |
| --- | ---: | ---: |
| curl/OpenSSL prefixes | 3,481 | 77.9445% |
| SQLite | 613 | 13.7259% |
| `provider_output` | 222 | 4.9709% |
| Positional I/O | 52 | 1.1644% |

Leaf symbols are unresolved in 567 samples, including 540 in the vDSO. In total, 4,294 samples contain an unknown frame. Kernel stacks are unavailable. The profile therefore cannot assign complete end-to-end stacks or kernel cost. The [flamegraph SVG](raw/stream100-flamegraph.svg) uses sample counts, not sample-period weights. Folded weights sum to 4,466. Chromium rendered the SVG and the resulting PNG was inspected for readable labels and correct units.

## HOLD separates natural counters from ptrace effects

HOLD uses [P1 source](https://github.com/DivyanshGolyan/rui/commit/b13caa4b603e44de482694e241f18b4d752a5456), separately from the frozen Rui binary. A temporary [attribution test](p2_attribution_test.go.txt) reuses its provider and the existing Host/client owners. Both runs assert 100 held streams on one H2 connection, zero events and zero offer bytes at the end of the observation. They do not complete or settle those Messages, so the HOLD table describes admission-and-hold only.

The untraced control records 5,300 voluntary context switches across the Host's five threads over a 60-second interior window. Two threads contribute 2,980 and 2,320; the other three contribute zero. Nonvoluntary switches total 419. With strace, voluntary switches rise to 1,212,768. Traced switches are not natural wakeups. Even the untraced Linux task counter is not Mac `IDLEW` or a count of distinct timer wakeups. No before/after production fix or Mac wakeup result is claimed.

## Uninstrumented Linux CPU diagnostics

The CPU follow-up invokes the existing Go capacity runner directly against the same baseline ReleaseFast binary. It uses no strace, perf, heaptrack, SQL callback or phase diagnostics. Only these new uninstrumented runs supply CPU times. Existing instrumented clock outputs remain excluded.

| Fixture | Pre-run estimate | Measured Host user+system CPU | Actual events | CPU/event |
| --- | ---: | ---: | ---: | ---: |
| STREAM N=1 | About 0.158 CPU-seconds | 1.53 CPU-seconds | 3,600 | 425 µs |
| STREAM N=100 | About 14.12 CPU-seconds | 42.40 CPU-seconds | 1,200,000 | 35.3 µs |
| HOLD N=100, interior window | About 0.054 CPU-seconds | 1.84 CPU-seconds over 60.01 seconds | 0 | Undefined |

N=1 has two complete-work deltas of 0.77 and 0.76 CPU-seconds. Complete-work CPU includes Message admission, fixture readiness, paced offer, result delivery and Host drain. It excludes Configure and Host startup. Host CPU excludes provider, controller and CLI processes. The 40-second interior windows independently measure about 0.01274 and 0.01199 average cores. Both rounds pass functional and offline durable audits; the report remains incomplete for unavailable Mac physical footprint.

N=100 has complete-work deltas of 20.62 and 21.78 CPU-seconds. Its 40-second interior windows measure about 0.310 and 0.300 average cores. Both rounds pass capture, request integrity, result delivery, cleanup and post-reap durable audits. Its aggregate also remains incomplete for unavailable Mac physical footprint.

HOLD measures Host CPU from 0.90 to 2.74 seconds over a bracketed 60.01-second interior window, about 0.03066 average cores, or 3.07% of one core. The existing provider confirms 100 held streams on one H2 connection, zero response events and zero offer bytes. This measures waiting CPU, not admission or settlement CPU, and not distinct wakeups. The test passes. The CPU/event denominator is zero and the ratio is undefined.

The estimates use previous counts and explicitly assumed unit costs, not instrumented timings. Observed CPU is about 9.7 times the N=1 estimate, 3.0 times the N=100 estimate and 34 times the HOLD estimate. The original estimates remain unchanged. Linux CLK_TCK is 100; ratios are derived from coarse process counters, not microsecond-resolution observations. Each fixture has one fresh Host, with two rounds for streaming and one HOLD window, not five-repeat statistics. Runs are serial, and compilation occurs between measured intervals. These are Linux fixture diagnostics, never Mac headlines or qualification of a production fix. Raw reports and derived summaries are [N=1](raw/stream1-uninstrumented.json), [N=1 summary](raw/cpu-stream1-summary.json), [N=100](raw/stream100-uninstrumented.json), [N=100 summary](raw/cpu-stream100-summary.json) and [HOLD](raw/hold100-cpu/evidence.json).

## Original estimates remain beside the measurements

The [run notes](NOTES.md) retain the arithmetic recorded before each run. Large gaps are findings, not revised estimates.

| Quantity | Estimated before run | Measured |
| --- | ---: | ---: |
| STREAM N=1 total syscalls, initial diagnostic run | About 12,000 | 284,834 |
| STREAM N=1 quiet diagnostic control | 170,684 | 170,960 |
| STREAM N=100 total syscalls | About 1,300,000 | 12,625,760 |
| STREAM `fsync`/Message | About 12 | 29.5 at N=1; 24.06 at N=100 |
| SQL N=1 first-executions | About 500 | 8,909 |
| SQL N=100 first-executions | About 40,100 | 433,586 |
| N=1 libc allocations | About 1,000 | 21,021 |
| N=100 transport/capture sample family | More than 50% | curl/OpenSSL prefixes in 77.9445% |
| HOLD polling calls | About 7,500 | 7,200 `poll` calls |
| HOLD admission/configuration `fsync` calls | About 1,200 | 1,705 |
| Untraced HOLD voluntary switches | About 6,200 | 5,300 |
| N=100 page faults | Less than 10,000 | 14,039 |

## Limits and reproducibility

Hardware cycles, instructions, branches, branch misses and cache misses are unsupported. Perf context-switch and CPU-migration counters report zero despite independent task-switch evidence, so those metrics are unavailable. Page faults and user sampling work. Instrumented clock outputs are retained only as raw tool output.

The seven original instrumented streaming, SQL, heap and perf JSON reports remain `incomplete`, with process exit 1 because Mac physical footprint is unavailable. Capture, request integrity, result delivery, cleanup and post-reap durable audits pass in both rounds. The two new uninstrumented streaming reports retain the same missing-footprint limitation. Linux RSS, profile memory, CPU and switch counts do not replace Mac headline results. Normal-install, previous-release and live-provider qualification were not performed here.

The failed SQL build caused by a dependency symlink and the failed perf post-processing field request remain in raw logs. Corrected infrastructure and post-processing did not rerun workloads for green. The original partial HOLD implementation remains frozen and unused by HOLD measurements. [Commands](COMMANDS.md) identify each executable, option, source export and post-processing step. [Count summary](raw/count-summary.json) is regenerated from the published raw evidence with `python3 .amp/p2/analyze.py`. Raw profiles and patches use gzip without deleting local originals. Final product-file hash verification is in [source-recheck-final.txt](raw/source-recheck-final.txt).

## SELECT call-site attribution from existing traces

The [SQL owner reduction](raw/sql-owner-summary.json), regenerated with `python3 .amp/p2/sql_read_attribution.py`, groups the original traces by exact statement text. No workload was repeated. SELECTs account for98.47% of8,909 first executions atN1 and98.23% of433,586 atN100. These remain whole-run counts, including startup, admission, streaming, result inspection and shutdown.

| SELECT owner in baseline240 | N1,2 Messages | N100,200 Messages |
| --- | ---: | ---: |
| `recoverOneUncertainActionLocked` | 7,249 | 285,818 |
| `operationSupersededByControlLocked` | 1,140 | 124,156 |
| `recoverOneExhaustedModelAttemptLocked` | 123 | 139 |
| `validateBlockedToolCalls` | 11 | 1,183 |
| Bash admission probe | 7 | 692 |
| Message admission probe | 7 | 692 |
| Tool-continuation probe | 6 | 691 |
| Retry admission probe | 3 | 18 |
| Retry clock read | 4 | 19 |
| Other work or observation SELECTs | 223 | 12,504 |

The first two owners contribute8,389/8,909 and409,974/433,586 of all statement executions, about94% in both fixtures. `recoverOneUncertainActionLocked` at `src/store.zig:4568` executes the unresolved-Action SELECT on every execution turn through `src/execution_turn.zig:60`, before checking free capacity. Both retained fixture Stores contain zero Actions, so these scans find no Action to recover. No transaction begins on that empty return. They are repeated discovery, not Message or model-output mutation.

`serviceLifecycle` reconciles controls every100ms or on a control hint. `cancelSupersededTransfers` at `src/server.zig:1769` calls `operationSupersededByControlLocked` at `src/store.zig:5606` once per active model slot. This explains the approximately100× population multiplier. The pre-reduction estimate was120,000 such SELECTs atN100 versus124,156 measured, and1,200 atN1 versus1,140 measured.

The25ms transport wait is an upper bound, not an unconditional sleep. Network readiness and immediate-progress turns can cause more turns and uncertain-Action scans than40/second. The N100 trace contains285,818 scans, far above a40Hz×120second estimate. The older traces have no phase timestamps or turn markers, so they cannot partition those counts into timeout turns, readiness turns, admission or settled waiting. Additional phase instrumentation is being used for that distinction. SQL ownership is not CPU attribution, and no poll-driven optimization or durability change is implemented.

## HOLD SQL phase counts distinguish waiting from admission

One additional instrumented fixture ran from 20:07:32 to 20:09:22 UTC and passed. Its separately hashed ReleaseFast binary adds SQLite first-execution timestamps and execution-turn markers to an isolated baseline export. The existing P1 b13caa4 provider, Host and client owners supply 100 Messages, accepted HOLD streams, public cancellation and result drainage. No original count run was repeated.

| Observed phase | Interval, seconds | SELECT first executions | SELECTs per observed second | BEGIN / COMMIT / ROLLBACK |
| --- | ---: | ---: | ---: | --- |
| Empty Host, no Messages | 10.00899 | 629 | 62.84 | 110 / 0 / 110 |
| Configure and admit 100 Messages | 5.34185 | 5,655 | 1,058.62 | 436 / 300 / 136 |
| 100 accepted streams, no response bytes | 60.00801 | 60,067 | 1,000.98 | 0 / 0 / 0 |
| Explicit stop and result drain | 2.64845 | 6,137 | 2,317.20 | 232 / 100 / 132 |
| All 100 Messages cancelled and settled | 20.01841 | 1,248 | 62.34 | 218 / 0 / 218 |

The held window contains 57,700 control-reconciliation reads, 2,307 uncertain-Action scans and 60 exhausted-retry scans. All 2,307 recorded turns have zero free slots and return to transport wait. There are no admission probes, mutations or explicit transactions in that window. The pre-run estimate was 62,460 SELECTs, about 3.8% above the measured 60,067. This confirms approximately 1,000 SELECTs per second without any response bytes or model events, not a cost per completed Message.

Once every Message is cancelled and settled, all 198 turn starts have 100 free slots and use the 100ms idle wait. Each turn performs one uncertain-Action scan, one Bash admission scan, one Message probe, one tool-continuation probe and two blocked-tool scans. Twenty retry-maintenance cycles add one exhausted-retry scan, one SQLite clock read and one retry-admission scan each. Empty Bash and retry admissions issue BEGIN/ROLLBACK even though no work is selected. These are statement executions, not fsync counts or successful commits.

The cancelled-settled window is not successful model completion. Read-only Store inspection confirms 100 cancelled Turns, no unresolved model operations and zero Actions. The [phase summary](raw/sql-phase-summary.json) retains every exact SELECT text, phase boundaries, turn counts and free-slot histograms. [Raw host logging](raw/sql-phases-hold100/host-stderr.log.gz), [fixture evidence](raw/sql-phases-hold100/evidence.json), [source patch](sql-phase-instrumentation.patch.gz) and [temporary test](p2_sql_phases_test.go.txt) permit independent reduction with `python3 .amp/p2/sql_phase_attribution.py`. Interval lengths only normalize instrumented counts. They are not uninstrumented CPU or latency measurements, and the original streaming traces still have no exact historical phase split.

## SSE validation rereads bytes already consumed by its line scanner

A tiny isolated replay drives the unchanged validation algorithm with three fixture-shaped 260-byte `response.in_progress` records and valid terminal output. The instrumented source logs each read's role, offset, size and scanner-consumed frontier. All 56 logged source reads match actual `preadv` calls one-for-one in the [raw syscall trace](raw/sse-replay-preadv.txt.gz). The focused ReleaseSafe build exits 0 and reports 2/2 tests passed. No N100 workload was repeated for this range proof.

The first record occupies bytes [0,260). The scanner initially reads [0,1215), then consumes the first line through offset 259 and its blank separator through offset 260. Each subsequent read below lies behind that consumed frontier. Offsets are half-open ranges in the same source file.

| Baseline read owner | Range for first record | Read calls |
| --- | --- | ---: |
| `validate`, data-line LF and preceding CR check | [258,259), [257,258) | 2 |
| `linePrefix`, data field name | [0,5) | 1 |
| `validate`, leading payload space | [5,6) | 1 |
| `validate`, blank-line LF | [259,260) | 1 |
| `processEvent → readFields → FileSource.peek`, JSON object | [6,258) | 1 |
| `processEvent → readString → FileSource.peek`, type string | [14,36) | 1 |

Each of the three nonterminal records has exactly seven rereads totaling 283 requested bytes: five framing reads totaling nine bytes and two JSON/type reads totaling 274 bytes. The JSON type range is itself inside the object range. The original N100 observation of 7.07634 `preadv` calls per event is consistent with these seven reads, one broad scanner refill per 4,096 bytes, and additional terminal/metadata/Store reads. The small replay proves the mechanism, not an exact partition of every historical `preadv` call.

The caller is `completeSuccessfulTransfer → model_adapter.interpretOutput → provider_output.validate`, after the response capture completes. This is not repeated whole-response validation on every arriving network event. The [range summary](raw/sse-range-summary.json), [source patch](sse-range-instrumentation.patch.gz) and [raw replay output](raw/sse-replay.log.gz) retain the exact roles and frontiers. `python3 .amp/p2/sse_range_attribution.py` independently checks all syscall matches and seven already-consumed reads for each record. The result attributes calls, not CPU time. P4's separate framing candidate removes the five framing reads; its JSON/type rereads remain outside that change.

## The framing candidate removes approximately five preadv calls per event

One additional N100 count run compares frozen baseline `240aef2e46d7240ce31a02ce4cefceb695551a56` with P4's candidate `12f84075a2f5e73dcd5e4c8b38ed0ea890f1beef`. Both use ReleaseFast and the identical original Go runner/provider binary. The existing baseline capture is reused only after matching the requested and emitted workload. Each case has two fresh-Session rounds on one Host, 100 Messages and 600,000 emitted 260-byte events per round, one H2 connection, 100 streams and a nominal 60-second offer at 100 events/second/stream. Distinct temporary Store paths and endpoints are expected. These are whole-run Host-only `strace -D -f -c` counts, including setup and audits, with SQLite and phase diagnostics disabled.

| Instrumented count | Baseline 240 | Candidate 12f84075 |
| --- | ---: | ---: |
| Actual event denominator | 1,200,000 | 1,200,000 |
| Message denominator | 200 | 200 |
| `preadv` calls | 8,491,607 | 2,487,410 |
| `preadv` per event | 7.07634 | 2.07284 |
| All syscalls | 12,625,760 | 9,895,882 |
| All syscalls per event | 10.52147 | 8.24657 |
| `fsync` calls | 4,812 | 4,815 |
| `fsync` per Message | 24.06 | 24.075 |

The pre-run estimate predicted 6,000,000 fewer `preadv` calls, leaving 2,491,607. The measured reduction is 6,004,197, or 5.00350 calls/event. The estimate that every other count would remain fixed was wrong. Other syscalls increased by 3,274,319, principally `recvfrom` by 2,482,223. Total calls therefore fell by 2,729,878, not the estimated 6,000,000. These scheduling and network-sensitive whole-run differences are not a CPU attribution or a speedup measurement. No `fdatasync` call appears in either unfiltered syscall summary, and neither journal configuration nor durability changed.

The candidate ran from 20:32:45 to 20:35:50 UTC. Both rounds passed capture, request-integrity, result-delivery, cleanup and offline durable audits. The controller retained exit 1 and `incomplete` because Mac footprint is unavailable. Both the reused baseline and candidate have 100 timing-invalid streams per round under tracing. Their nominal offer durations do not establish accepted pacing or uninstrumented cost. The candidate's remaining JSON-object and type-string rereads are not fixed by this comparison.

The [comparison reducer](sse_candidate_comparison.py) checks matching fixture inputs, emitted denominators, launcher identities and syscall row sums before producing the [comparison](raw/sse-candidate-comparison.json). The [raw candidate syscalls](raw/stream100-sse-candidate-strace.txt), [canonical report](raw/stream100-sse-candidate.json), [controller outcome](raw/stream100-sse-candidate-controller.log), [build log](raw/build-sse-candidate.log.gz) and [source/binary identities](raw/sse-candidate-identity.txt) retain exact evidence. The candidate binary hash is `8c3add2e42b2173c47a86f3ec11759087f1b310b94f57546af1812ccc2c123c6`; the baseline remains `b843b47a…`. All 87 candidate product/build files were byte-compared to the published candidate and rehashed after execution. No product source, REPORT or landing ref was changed by P2.

## Matched HOLD0 versus HOLD100 shows polling amplification, not CPU causality

The older 62.8435-versus-1,000.9831 SELECT/second comparison is descriptive, not strictly matched. Its empty-idle phase precedes Session configuration, has no warmup and lasts 10 seconds. Its held phase follows configuration and admission, has a 10-second warmup and lasts 60 seconds. The approximate 15.93× ratio must not be presented as a matched HOLD0 experiment.

A new observation ran 21:52:49–21:55:16 UTC and passed. Both windows use the same Host PID 2903747, capacity 100, Store, 100 already-configured Sessions with tools disabled, SQL-instrumented baseline binary and corrected P1 HOLD provider. Each follows 10 seconds of warmup and requests a 60-second window. The zero window has no Messages or provider requests. All 100 Message admissions occur between the windows. The held window has 100 accepted Operations and one H2 connection, with no response bytes, events or terminal completions. Population and resulting transport/Message rows intentionally differ. This is one sequential same-Host observation, not repeated or randomized statistics.

| Instrumented first executions | Configured HOLD0 | HOLD100 |
| --- | ---: | ---: |
| Observed interval, seconds | 60.055861641 | 60.009824453 |
| SELECT count | 3,750 | 60,273 |
| SELECTs per observed second | 62.4419 | 1,004.3855 |
| BEGIN / ROLLBACK count | 655 / 655 | 0 / 0 |
| All statement count | 5,060 | 60,273 |
| All statements per observed second | 84.2549 | 1,004.3855 |

The SELECT rate rises **16.0851×**, or **941.9437 extra SELECTs/second**. The all-statement rate rises **11.9208×**, or **920.1307 extra statements/second**. These ratios differ because zero-population admission probes execute BEGIN/ROLLBACK even when they find no work. Neither window issues COMMIT or data-changing SQL. The estimates were approximately 3,770 versus 60,060 SELECTs and 5,090 versus 60,060 total statements. Actual SELECT counts differ by about −0.5% and +0.4%, respectively.

| SELECT caller | HOLD0 per second | HOLD100 per second | Difference per second |
| --- | ---: | ---: | ---: |
| Per-active-Operation control reconciliation | 0 | 964.8420 | +964.8420 |
| Global uncertain-Action recovery scan | 9.9074 | 38.5437 | +28.6362 |
| Global exhausted-retry recovery scan | 0.9991 | 0.9998 | +0.0008 |
| Empty Bash, Message, tool and retry probes plus retry clock | 51.5354 | 0 | −51.5354 |

`serviceLifecycle` reconciles controls approximately every 100ms. Its `cancelSupersededTransfers` loop calls `Store.operationSupersededByControl` for each active slot. The held window executes that SELECT 57,900 times, or **9.6484 control reads per held Operation per second**. All checks observe unchanged, uncancelled work because the test sends no control until after the window. Global uncertain-Action recovery executes once in each of 2,313 transport-wait turns, even with all slots full and no Actions. Exhausted-retry recovery adds 60 scans. There are no admission probes in the held window because free slots remain zero. At HOLD0, 595 idle turns instead run empty admission/continuation checks with 100 free slots, plus 60 retry-maintenance cycles. Read-only post-reap inspection confirms zero Actions and 100 subsequently cancelled Messages.

This is substantial repeated SQL observation with no model progress or new admissions during the measured windows. The control queries dominate held SQL volume, so avoiding repeated unchanged-state reads is a concrete investigation target. It does not prove that all polling can be removed while preserving control responsiveness, nor establish a universal threshold for "extremely wasteful." Count amplification is not CPU attribution, an uninstrumented cost measurement or an optimization-speedup claim. No Store-wakeup, production or durability change is implemented.

The [matched summary and exact caller contributions](raw/hold-population-summary.json), [raw Host trace](raw/hold-population/host-stderr.log.gz), [fixture snapshots and boundaries](raw/hold-population/evidence.json), [temporary test](p2_hold_population_test.go.txt), [binary/source identity](raw/hold-population-identity.txt) and [controller outcome](raw/hold-population-controller.log) retain the comparison. Run `python3 .amp/p2/sql_phase_attribution.py raw/hold-population` to reproduce it. The [first reduction failure](raw/hold-population-reduction-attempt1.txt) is retained: the reducer initially rejected the provider's documented omission of zero `held_streams`. The schema correction reused the same capture without rerunning the workload. All rates normalize instrumented first-execution counts, not statement completions or CPU time.
