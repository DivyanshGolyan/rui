# P2 Linux attribution — fixture, not Mac headline

Baseline: Rui main/stable 240aef2e46d7240ce31a02ce4cefceb695551a56. Product source stays unchanged. The two partial HOLD files are frozen for P1; ordinary capacity paths are unchanged and HOLD is not used here.

Definitions: an event is one 260-byte nonterminal SSE record successfully emitted by the qualification provider; a Message is one admitted user Message, not an SSE event or model token. Existing capacity runs have two fresh-Session rounds on one Host: N=1 has 3,600 events/2 Messages; N=100 has 1,200,000 events/200 Messages. Terminal SSE records are additional protocol traffic, excluded from the event denominator. Whole-run counts include startup/configuration, result inspection/delivery, shutdown and two rounds, and are explicitly amortized rather than incremental per-Message costs.

Instrumented runs supply counts only. Their existing JSON may contain times/resource verdicts; those are not performance-time claims. Provider/controller/CLI counters must not be mislabeled Host counters. Missing instrumentation is unavailable, never zero.

## Estimates recorded before execution

- Tool capability probe: expect software perf context-switch/page-fault counters to be permitted at paranoid=2 for child user processes, hardware cycles/instructions unavailable on this VM; controls are `perf stat` over `true`, not a workload result.
- Build/test preparation: expect no workload Messages/events; build ReleaseFast explicitly and compile existing Go runner; these are artifact preparation, not measurement.
- STREAM1 syscall estimate: 2 rounds × 1,800 events × (one socket receive + one capture write) ≈7,200 payload syscalls, plus ≈2,400 25/100ms polling waits and setup/audit; rough total 12,000, or 3.33/event and 6,000/Message. Estimate fsync ≈12/Message from Configure, Message admission, selection/admission/attempt, settlement and durable capture; SQL executions ≈200/Message from those transitions plus small result audits. Preserve discrepancy rather than revising this estimate.
- STREAM100 syscall estimate: 1,200,000 events with HTTP/2 multiplexing batch 100 contemporaneous streams: ≈12,000 socket receives + 1,200,000 capture writes plus poll/futex/setup: ≈1,300,000 total, 1.08/event, 6,500/Message. Estimate fsync ≈12/Message and SQL ≈200/Message; global polling/inspection may change amortization. This is an estimate, not a claim that every event maps to a write.
- N=1 native-allocation estimate: SQLite/curl allocate around 100 times per lifecycle Message plus startup ≈1,000 native allocations total, ≈500/Message. Zig direct mmap/page allocation is outside LD_PRELOAD heaptrack and must be reported separately.
- N=100 on-CPU profile estimate: event capture/transport is the largest sampled stack family (>50% of samples); no elapsed-time inference from an instrumented profile.

No attribution run relies on the partial HOLD implementation. P1 owns the completed HOLD source and validation.

## STREAM1 diagnostic-enabled observation and distinguishing control

Measured: 284,834 Host syscalls / 3,600 provider events / 2 Messages = 79.1206/event and 142,417/Message. fsync=59 (29.5/Message), fdatasync=0 calls observed. Original estimate 12,000 total was 23.74× too low. Results, capture, drain and stopped-Host audits passed; harness exit=1/incomplete because Linux lacks the Mac footprint counter. This is not a failed functional check and is not retried for green. Optional phase traces were lossy (`trace_lost=true`); syscall counts do not depend on their completeness.

- No-trace STREAM1 control estimate BEFORE run: 284,834 minus 22,830 observed diagnostic getpid × (3 fcntl + 1 write + 1 getpid) ≈170,684 syscalls (47.41/event); fsync stays ≈59 (29.5/Message). Source stderr.writeHeld performs three fcntl operations plus a write; phase production asks getpid. This explicit control tests diagnostic amplification; it is not a replay for qualification or a revised original estimate.

No-trace control measured 170,960 syscalls (47.4889/event; 85,480/Message), 59 fsync (29.5/Message), fdatasync zero observed. The control estimate differs by 276 calls (0.162%). All functional/audit dimensions passed; memory unavailable gives the retained incomplete/exit1. Difference from diagnostic-enabled run is 113,874 syscalls; source-based estimate predicted 114,150. This supports diagnostic amplification rather than a product regression.

## Measurement-only SQL and allocator instrumentation

SQLite is statically linked into Rui, so LD_PRELOAD cannot interpose SQLite entry points. A separate archived baseline source export under research-source adds a 24-line C automatic-extension callback using sqlite3_trace_v2(SQLITE_TRACE_STMT). This emits unexpanded SQL at first execution, including BEGIN/COMMIT/ROLLBACK, before any Host initialization SQL. No settings/durability changes. Its build.zig adds only that translation unit. SQL runs have a separately hashed research binary; ordinary strace/perf/heaptrack use the untouched ReleaseFast baseline binary.

The existing Go harness kills the Host after drain, which cannot flush heaptrack. Its isolated research copy adds an opt-in P2_GRACEFUL_STOP=1: normal exact-instance `host stop`, wait for zombie (exit/destructors completed), then existing reap and offline audits. Only the N=1 heaptrack run enables this; any failed graceful stop remains failed and cleanup still kills through the existing defer. The original runner and frozen partial HOLD files remain unchanged.

- SQL1 run estimate BEFORE run: 200 executions/Message ×2 plus ≈100 startup executions =500 statements, ≈16 committed transactions across startup+two Message lifecycles. Counts include reads, startup/schema work, configuration and audit observations; do not equate a statement with a durable transaction.
- SQL100 run estimate BEFORE run: 200×200 +100 startup ≈40,100 statement executions; ≈6 committed transactions/Message +startup ≈1,201 commits. Polling work can add read statements and empty transactions. Neither is estimated as zero.
- Heaptrack1 run estimate is the original ≈1,000 native allocations /2 Messages, plus shutdown; count native allocator events, not Zig page allocations. Graceful Host stop is used only to finish the profile, after canonical Message drain/result checks.
- PERF100 run estimate BEFORE run: >50% of on-CPU samples in transport/capture; context-switches ≈12,000 (one wake per 100Hz stream batch plus execution/intake), page faults <10,000 after baseline startup. Hardware cycles/instructions/branches/cache counters are unavailable and excluded. Sampling is instrumented; all times/task-clock outputs are retained but not reported as benchmark times.

Research build attempt 1 failed before producing an SQL binary: symlinked zig-pkg makes uucode's working-directory-relative `../../.zig-cache/.../tables.zig` resolve against the main checkout rather than the isolated export, yielding FileNotFound. Preserve build-sql-research-attempt1.log. Correct infrastructure by copying the pinned package tree into the export and rebuild once; this is not a workload rerun or product failure. Main baseline build passed 42/42 steps, despite Zig printing a `failed command` warning line for successful pinned-transport stderr; final summary and exit are authoritative.

- HOLD100 count estimate BEFORE run: zero response events, 100 accepted Messages, so per-event division is undefined; 70s held observation plus admission should yield ≈3,500 intake 20ms polls +≈2,800 curl25ms polls +≈100 setup/configuration ×12 ≈7,500 Host polling syscalls, ≈1,200 fsync admission/configuration calls. Estimate ≈1,300 voluntary switches/thread family from execution/intake/curl periodic wakeups; exact per-thread raw status deltas are retained. Use P1 harness commit 478973736ec1c11e91da9defd5bfc68655021b6e plus a temporary test calling its existing provider/StartHost/Client seams, never the partial HOLD or Mac-only headline entry point.
