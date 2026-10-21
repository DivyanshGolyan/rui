# Executed attribution commands

All run from `/home/user/workspace/repo` unless stated. Exact source/binary hashes are in `raw/identity.txt`; initial estimates and controls are in `NOTES.md`. Commands below describe Linux fixtures, not Mac headline qualification. Nonzero/incomplete results remain nonzero/incomplete.

```sh
zig build -Doptimize=ReleaseFast -j2 --summary all
cp zig-out/bin/rui .amp/p2/bin/rui-baseline
GOTOOLCHAIN=local go -C tests/qualification build -mod=readonly -o /home/user/workspace/repo/.amp/p2/bin/model-output ./model-output

# Host-only tracer uses -D so the Host retains the PID the canonical runner owns.
P2_SYSCALL_OUTPUT=/home/user/workspace/repo/.amp/p2/raw/stream1-strace.txt .amp/p2/bin/model-output --capacity 1 --output /home/user/workspace/repo/.amp/p2/raw/stream1-strace.json /home/user/workspace/repo/.amp/p2/bin/rui-strace
P2_DIAGNOSTICS=0 P2_SYSCALL_OUTPUT=/home/user/workspace/repo/.amp/p2/raw/stream1-no-trace-strace.txt .amp/p2/bin/model-output --capacity 1 --output /home/user/workspace/repo/.amp/p2/raw/stream1-no-trace.json /home/user/workspace/repo/.amp/p2/bin/rui-strace
```

Standard tools: Debian linux-perf 6.1.190, strace 6.1, heaptrack 1.4.0. Hardware-counter capability output is retained verbatim. FlameGraph tooling is upstream `brendangregg/FlameGraph` at 41fee1f99f9276008b7cd112fca19dc3ea84ac32. It only post-processes the one requested N=100 on-CPU profile.

Research SQL binary: export baseline with `git archive 240aef2e46d7240ce31a02ce4cefceb695551a56`; apply retained `sql-instrumentation.patch` (one C translation unit and registration in configureSqlite), use copied pinned `zig-pkg`, then `zig build -Doptimize=ReleaseFast -j2 --summary all` from that export. No product settings/durability changes. First build failed due to a dependency-directory symlink; its log remains separate from the corrected second build.

The retained patches are compressed without changing their content. Patch paths name the isolated exports, so apply the build, C-file and Go hunks to their corresponding export paths. The original controller's unused partial HOLD diff is retained separately in `partial-hold.patch.gz`. It never supplies a HOLD measurement.

```sh
P2_DIAGNOSTICS=0 P2_SYSCALL_OUTPUT="$PWD/.amp/p2/raw/stream100-strace.txt" .amp/p2/bin/model-output --capacity 100 --output "$PWD/.amp/p2/raw/stream100-strace.json" "$PWD/.amp/p2/bin/rui-strace"

.amp/p2/bin/model-output --capacity 1 --output "$PWD/.amp/p2/raw/sql1.json" "$PWD/.amp/p2/bin/rui-sql-research"
.amp/p2/bin/model-output --capacity 100 --output "$PWD/.amp/p2/raw/sql100.json" "$PWD/.amp/p2/bin/rui-sql-research"
# Copy each canonical artifact directory's capacity-N/host-stderr.log before compression.
# sqlite3 Store query used for schema verification:
# SELECT type,count(*) FROM sqlite_master WHERE type IN ('table','index','trigger') GROUP BY type;

# Opt-in graceful controller exported from baseline, compiled in tests/qualification.
P2_GRACEFUL_STOP=1 P2_HEAP_OUTPUT="$PWD/.amp/p2/raw/heap1.raw" .amp/p2/bin/model-output-graceful --capacity 1 --output "$PWD/.amp/p2/raw/heap1.json" "$PWD/.amp/p2/bin/rui-heap"
heaptrack_interpret < .amp/p2/raw/heap1.raw > .amp/p2/raw/heap1.interpreted 2> .amp/p2/raw/heap1-interpret.log
heaptrack_print -f .amp/p2/raw/heap1.interpreted > .amp/p2/raw/heap1-print.txt 2> .amp/p2/raw/heap1-print-errors.txt

P2_PERF_PREFIX="$PWD/.amp/p2/raw/stream100-perf" .amp/p2/bin/model-output --capacity 100 --output "$PWD/.amp/p2/raw/stream100-perf.json" "$PWD/.amp/p2/bin/rui-perf"
# rui-perf launches perf stat and the sole N100 capture attached to its own PID, then execs Rui.
# Counters: context-switches,cpu-migrations,page-faults,task-clock:u,cpu-clock:u.
# Record: perf record -e cpu-clock:u -F 99 --call-graph dwarf,16384 -p HOST_PID -o PROFILE.data
perf report -i .amp/p2/raw/stream100-perf.data --stdio --show-nr-samples > .amp/p2/raw/stream100-perf-report.txt
perf script -i .amp/p2/raw/stream100-perf.data -F comm,pid,tid,time,event,ip,sym,dso > .amp/p2/raw/stream100-perf-samples.stacks
.amp/p2/scratch/FlameGraph/stackcollapse-perf.pl < .amp/p2/raw/stream100-perf-samples.stacks > .amp/p2/raw/stream100-perf-samples.folded
.amp/p2/scratch/FlameGraph/flamegraph.pl --title 'Rui baseline N=100 user on-CPU samples (fixture; counts only)' --subtitle '4466 samples; user stacks only; no elapsed-time claim' --countname samples --bgcolors '#ffffff' < .amp/p2/raw/stream100-perf-samples.folded > .amp/p2/raw/stream100-flamegraph.svg
```

HOLD uses `git archive b13caa4b603e44de482694e241f18b4d752a5456` in `.amp/p2/p1-source`, with the retained `p2_attribution_test.go.txt` copied to `tests/qualification/model-output/p2_attribution_test.go`. Compile with `GOTOOLCHAIN=local go test -c -o /home/user/workspace/repo/.amp/p2/bin/p1-attribution-test ./model-output` from that export's `tests/qualification`. This is a temporary test reusing existing owners, not a shipped runner or a changed Mac entry point.

```sh
P2_DIAGNOSTICS=0 P2_SYSCALL_OUTPUT="$PWD/.amp/p2/raw/hold100-strace.txt" P2_HOLD_BINARY="$PWD/.amp/p2/bin/rui-strace" P2_HOLD_DIRECTORY="$PWD/.amp/p2/raw/hold100" .amp/p2/bin/p1-attribution-test -test.run '^TestP2HoldAttribution$' -test.v -test.timeout 5m
P2_HOLD_BINARY="$PWD/.amp/p2/bin/rui-baseline" P2_HOLD_DIRECTORY="$PWD/.amp/p2/raw/hold100-untraced" .amp/p2/bin/p1-attribution-test -test.run '^TestP2HoldAttribution$' -test.v -test.timeout 5m

# Compress copies, retain local originals, then reduce the published evidence.
python3 .amp/p2/analyze.py > .amp/p2/raw/count-summary.json
sha256sum -c .amp/p2/raw/product-source.sha256
```

The temporary HOLD test reads every Host task's `/proc/PID/task/TID/status` at 10 and 70 seconds after offer start. `analyze.py` subtracts those counters. The traced run's context switches are ptrace-distorted. The second run has no strace, heaptrack, SQL callback or perf collector. Both assert 100 held streams, zero SSE events and zero offer bytes before teardown. Provider and controller share one process only in this temporary HOLD test, and neither enters Host counts.

The final PNG is a Chromium rendering of the retained SVG, inspected for visible labels and correct sample units. No additional workload capture produced it. Large raw profiles, SQL logs and patches are gzip copies; decompress them to reproduce downstream tools. `raw/identity.txt` records initial environment and binary identity. `raw/final-binary-source-identity.sha256` adds the research and HOLD binary hashes. `raw/source-recheck-final.txt` verifies product files stayed unchanged.

## Uninstrumented CPU follow-up

The estimates precede execution in NOTES.md. STREAM1 started18:58:49UTC and ended19:00:51UTC with retained exit1/incomplete for missing Mac footprint. STREAM100 started19:01:24UTC. The actual Rui binary is passed directly, not through an instrumentation launcher. LD_PRELOAD was unset. Product/source identities remain baseline240, independently of the controller checkout revision recorded in JSON.

```sh
.amp/p2/bin/model-output --capacity 1 --output "$PWD/.amp/p2/raw/stream1-uninstrumented.json" "$PWD/.amp/p2/bin/rui-baseline"
.amp/p2/bin/model-output --capacity 100 --output "$PWD/.amp/p2/raw/stream100-uninstrumented.json" "$PWD/.amp/p2/bin/rui-baseline"
# Apply this reduction independently to each completed raw report:
jq '{fixture:true, uninstrumented_cpu:true, scope:"Host user+system complete-work CPU; Linux fixture diagnostic only", binary_sha256, harness_verdict:.status,
     messages:([.active_capacity_growth[0].rounds[].audit_rows|length]|add),
     events:([.active_capacity_growth[0].rounds[].paced_offer.completed_events]|add),
     host_cpu_seconds:([.active_capacity_growth[0].rounds[].cpu.complete_work_cpu_seconds]|add),
     rounds:[.active_capacity_growth[0].rounds[]|{round,events:.paced_offer.completed_events,cpu,host_dimensions,all_results_audited,offline_audit_after_host_reaped}]}
    | . + {cpu_seconds_per_event:(.host_cpu_seconds/.events),microseconds_per_event:(1000000*.host_cpu_seconds/.events)}' .amp/p2/raw/stream1-uninstrumented.json > .amp/p2/raw/cpu-stream1-summary.json
```

For HOLD, the isolated P1b13caa4 export uses retained `p2_hold_cpu_test.go.txt` in place of its prior temporary count test. It calls existing sampleCPU twice, preserves query brackets, and checks the same100held/0events/0offer-bytes contract. Compile between measured streaming runs with `GOTOOLCHAIN=local go -C .amp/p2/p1-source/tests/qualification test -c -mod=readonly -o /home/user/workspace/repo/.amp/p2/bin/p1-hold-cpu-test ./model-output`. CPU-test source and binary hashes are in `raw/cpu-binary-source-identity.sha256`. No product/provider source changes or new shipped runner are involved.

STREAM100 ended19:03:42UTC with retained exit1/incomplete. Reduce its raw JSON with the same jq expression, changing input to `stream100-uninstrumented.json` and output to `cpu-stream100-summary.json`. HOLD started19:04:20UTC and ended19:05:33UTC, PASS/exit0, using:

```sh
P2_HOLD_BINARY="$PWD/.amp/p2/bin/rui-baseline" P2_HOLD_DIRECTORY="$PWD/.amp/p2/raw/hold100-cpu" .amp/p2/bin/p1-hold-cpu-test -test.run '^TestP2HoldAttribution$' -test.v -test.timeout 5m
getconf CLK_TCK # 100
```

The retained HOLD evidence has both CPU query brackets, cumulative values, delta and minimum/maximum window bounds. Streaming reports retain per-round CPU brackets, actual event counters, process identities, exact binary hash and post-reap audits. Instrumentation/count-source exports were not rebuilt during the CPU runs, and prior count evidence was not recaptured. Final verification regenerates the prior nine count cases and both new streaming summaries from raw inputs and checks the HOLD subtraction independently.

## SQL phases and consumed SSE ranges

`sql_read_attribution.py` reduces the original SQL traces without recapture. The temporary test in `p2_sql_phases_test.go.txt` reuses the corrected P1 b13caa4 provider and measurement owners. Its isolated baseline export adds only the retained SQL/turn-phase patch. The source and binary identities are in `raw/sql-phases-identity.sha256`.

```sh
python3 .amp/p2/sql_read_attribution.py > .amp/p2/raw/sql-owner-summary.json
P2_SQL_BINARY="$PWD/.amp/p2/bin/rui-sql-phases" P2_SQL_DIRECTORY="$PWD/.amp/p2/raw/sql-phases-hold100" .amp/p2/bin/p1-sql-phases-test -test.run '^TestP2SQLPhases$' -test.v -test.timeout 5m
python3 .amp/p2/sql_phase_attribution.py > .amp/p2/raw/sql-phase-summary.json
```

The range replay adds the retained `sse-range-instrumentation.patch.gz` to the isolated SQL research export. It records role, offset, requested bytes and scanner-consumed frontier without changing the baseline read algorithm. From `.amp/p2/research-source`:

```sh
strace -f -yy -e trace=preadv -s 1 -o /home/user/workspace/repo/.amp/p2/raw/sse-replay-preadv.txt zig build test -Dtest-filter='P2 isolated SSE consumed-range evidence' -j2 --summary all
```

Both output streams are retained in `raw/sse-replay.log.gz`. The trace and source patch are compressed byte-preserving copies. `python3 .amp/p2/sse_range_attribution.py` reproduces `raw/sse-range-summary.json` and checks every logged read against its actual syscall. These are counts and byte ranges, not CPU-cost measurements.

## Baseline versus framing-candidate counts

Export exact candidate `12f84075a2f5e73dcd5e4c8b38ed0ea890f1beef` into `.amp/p2/candidate-source`, copy the pinned dependencies and build there. No original binary or measurement source is replaced. The candidate launcher changes only the target binary relative to `rui-strace`.

```sh
# From .amp/p2/candidate-source:
zig build -Doptimize=ReleaseFast -j2 --cache-dir /home/user/workspace/repo/.zig-cache --summary all
cp zig-out/bin/rui /home/user/workspace/repo/.amp/p2/bin/rui-sse-candidate
# From the repository root, using the unchanged original runner/provider:
env -u LD_PRELOAD P2_DIAGNOSTICS=0 P2_SYSCALL_OUTPUT="$PWD/.amp/p2/raw/stream100-sse-candidate-strace.txt" .amp/p2/bin/model-output --capacity 100 --output "$PWD/.amp/p2/raw/stream100-sse-candidate.json" "$PWD/.amp/p2/bin/rui-candidate-strace"
python3 .amp/p2/sse_candidate_comparison.py > .amp/p2/raw/sse-candidate-comparison.json
```

The controller log retains actual UTC start/end and exit 1. `raw/sse-candidate-identity.txt` separates source revision, build mode, actual Rui hashes, original Go binary hash and launcher hashes. The canonical JSON's `binary_sha256` identifies its launcher, not the underlying Rui binary. Baseline count reuse requires identical runner/provider and matched requested/actual event populations. Both cases have pacing violations under tracing. No instrumented elapsed, syscall-time or CPU number is used as a cost result.
