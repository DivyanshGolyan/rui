# Resource profiling evidence and reusable collection

Research date: 2026-09-15, with a native-counter investigation added on 2026-10-17. Recommendations, not an accepted contract or runtime qualification. ARCHITECTURE.md and VERIFICATION.md remain the behavior and proof owners. The original research ran no workloads; the dated addendum identifies its bounded native control separately.

## What the investment should answer

For a described workload: where does elapsed time go, what consumes CPU, what memory is owned versus retained by allocators, what creates storage work, and what remains after cleanup? Preserve an explanation by owner and lifecycle rather than only a percentage chart of functions.

| Artifact | Question and interpretation |
| --- | --- |
| Phase-aligned resource timeline | Align admission, preparation, transport, validation, Store waiting/service, delivery and cleanup with process counters. Overlapping intervals are not additive. |
| CPU call tree/flamegraph | Attribute sampled on-CPU work. Width is sample weight, not wall time or chronological order. Show event type, sample count and unresolved-stack share. |
| Allocation and retention account | Distinguish bytes currently allocated, total allocation churn, allocator reservations, virtual mappings and OS footprint. These overlapping views cannot be added. |
| Waiting evidence | Separate runnable-but-not-scheduled time, application lock waiting, I/O waiting and intended provider/retry waiting. A blocked stack alone is not proof of its semantic cause. |
| Storage account | Separate logical bytes processed, syscall bytes, SQLite cache activity, physical I/O and durability work. Repeated reads may hit caches. |
| Resource drain record | Track custody, scratch ownership, connections and handles to their release boundaries; compare repeated idle baselines without claiming RSS must immediately shrink. |

CPU sampling and allocation histories answer different questions. Apple documents allocation/free history, VM snapshots and footprint as complementary views; Linux documents separate RSS/PSS mappings and process I/O counters. [Apple heap analysis](https://developer.apple.com/videos/play/wwdc2024/10173/), [Linux proc](https://cdn.kernel.org/doc/html/latest/filesystems/proc.html).

Recommendation: extend the existing research measurement package, not a second framework. The published stack's `research/measurement/measurement.go` and `research/model-output/main.go` already collect process CPU, RSS, footprint, descriptors, custody and scratch evidence. The root README describes the older single-Session implementation; code in `/Users/divyanshgolyan/.codex/worktrees/1e5b/rui` describes the reviewed stacked implementation. Do not benchmark the root and label it the current stack.

## Preserve evidence before choosing a viewer

Recommended per-run bundle:

```text
run/
  manifest.json         # source/build/tool/machine identities, commands, exit status
  workload.json         # bytes, items, concurrency, history, arrival schedule
  metric-dictionary.json # unit, scope, counter/gauge, reset and missing semantics
  counters.jsonl        # timestamped original counter values
  lifecycle.jsonl       # bounded owner/operation phase facts, clock domain
  profiles/             # original .trace, perf.data, maps, symbol references
  report/               # reproducible derived tables, timeline and profiles
```

Record offered/admitted/completed/cancelled work and arrival delay; otherwise backpressure can make an overloaded system appear inexpensive. Record Host and Rui helpers as orchestration, model-requested Bash descendants as workload, fixture and collector processes separately. CPU totals need matching windows; process RSS sums double-count shared pages. Linux PSS apportions sharing; cgroup memory is a different group accounting scope including charges beyond process heaps. [Linux proc](https://cdn.kernel.org/doc/html/latest/filesystems/proc.html), [cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html).

Keep raw integer timestamps (strings in JSON when precision requires), unit, clock source, process/thread identity and calibration/anchor information. Never subtract unrelated clocks. Preserve raw native profiles; conversion can discard stack, scheduling or clock metadata. A Perfetto-compatible timeline is a useful derived view, not a requirement to embed a new tracing SDK. [Perfetto external formats](https://perfetto.dev/docs/getting-started/other-formats), [track-event clocks](https://perfetto.dev/docs/instrumentation/track-events).

The existing `SampleProcess` performs sequential queries, including external `footprint` and `lsof` processes: it is not an atomic snapshot or a suitable default high-frequency sampler. Recommendation: split cheap periodic counters from expensive phase snapshots, bracket each query with timestamps, and preserve missing/error states. Attribute collector cost separately.

## macOS collection

### CPU and elapsed-time explanations

Use Instruments CPU profiling for sampled call stacks; a time-filtered call tree provides a focused explanation of a lifecycle phase. Use System Trace/scheduling evidence when CPU alone cannot explain delay, and existing application phase timestamps for Store ownership and provider waiting. Signpost intervals with distinct IDs can correlate overlapping work in Instruments. Zig would need a small native boundary for Apple signpost APIs; do not impose that dependency on every platform or replace existing diagnostic facts. [Apple CPU profiling](https://developer.apple.com/videos/play/wwdc2025/308/), [signpost recording](https://developer.apple.com/documentation/os/recording-performance-data), [signpost interval IDs](https://developer.apple.com/videos/play/wwdc2018/405/).

Processor Trace is a later targeted tool, not the default capture: supported recent Apple silicon can reconstruct executed control flow, but captures can produce gigabytes per second. Start with sampling and only investigate a short unresolved CPU hotspot this way. [Apple CPU profiling and Processor Trace](https://developer.apple.com/videos/play/wwdc2025/308/).

### Memory explanations

Capture whole-process footprint plus Allocations and VM Tracker on separate focused runs. Allocations exposes allocation/free history; VM Tracker and `vmmap` explain mappings that heap-only tools cannot. `vmmap` is useful at cold idle, peak owner occupancy and retained idle; system-wide `vm_stat` describes machine pressure, not Rui's ownership. [Apple heap analysis](https://developer.apple.com/videos/play/wwdc2024/10173/), [Apple virtual-memory tools](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/ManagingMemory/Articles/VMPages.html).

Do not equate malloc events with every Zig allocation: arenas or page-backed allocators may suballocate from a larger native mapping. An allocator wrapper can count requested live bytes and churn at selected owning boundaries, while VM tools explain physical backing. Label coverage; do not claim the difference between totals is a proven leak or fragmentation measurement. This is a recommendation derived from the distinction between heap events and VM regions, pending an explicit allocator-path inventory of the measured build.

### Availability checked on this Mac

- `xcode-select -p`: `/Library/Developer/CommandLineTools`.
- `xcrun --find xctrace`: unavailable under the selected developer directory.
- `/usr/bin/vmmap`, `/usr/bin/footprint`, `/usr/bin/sample`, `/usr/bin/leaks`: present.
- Zig: 0.16.0, aarch64 macOS target.
- No Linux `perf` found in PATH; no Linux runtime evidence was gathered.

Full Xcode selection may enable Instruments; this research did not install or switch developer tools. Presence of a binary does not establish attachment permissions or useful symbolization.

Prospective skeletons, not executed; check the installed version's help and available templates first:

```sh
xcrun xctrace list templates
xcrun xctrace record --template 'Time Profiler' --attach PID --time-limit 10s --output run/profiles/cpu.trace
xcrun xctrace export --input run/profiles/cpu.trace --toc
vmmap -summary PID > run/profiles/vmmap-retained.txt
```

Choose the available CPU template, a disposable fixture PID and a bounded observation window. Export selectors depend on the recorded trace schema; retain `.trace` rather than assuming a stable undocumented format.

## Linux collection

### CPU, scheduler and pressure

Start with process-scoped `perf stat` CPU/event totals, then a bounded `perf record` sampled profile. Event availability, permissions and stack unwinding vary. `perf record` supports frame-pointer and DWARF call graphs; frame-pointer unwinding is not reliable for binaries omitting them, and DWARF stack capture adds overhead/data. Preserve the raw `perf.data`, executable, library identities and symbols. [Kernel perf record](https://raw.githubusercontent.com/torvalds/linux/master/tools/perf/Documentation/perf-record.txt), [kernel workload tracing](https://kernel.org/doc/html/latest/admin-guide/workload-tracing.html).

Use scheduler tracing when runnable delay matters; it does not replace application spans identifying intentional waits and lock ownership. PSI provides CPU/memory/I/O stall pressure at system or cgroup scope, not a per-function profile. A quiet blocked provider socket is not inherently CPU saturation. [Kernel perf sched](https://raw.githubusercontent.com/torvalds/linux/master/tools/perf/Documentation/perf-sched.txt), [kernel PSI](https://cdn.kernel.org/doc/html/latest/accounting/psi.html).

Prospective Linux skeletons, not verified on this Mac:

```sh
perf stat -p PID -e task-clock,context-switches,page-faults -- sleep 10
perf record -p PID -F 99 --call-graph dwarf -o run/profiles/perf.data -- sleep 10
perf report -i run/profiles/perf.data --stdio
cat /proc/PID/smaps_rollup
cat /proc/PID/io
```

The frequency/window are examples, not qualification defaults. Confirm supported events and permissions instead of silently dropping counters. Attaching misses earlier startup; use launch-scoped capture if startup is the question. No system-wide recording is needed for the first pass.

### Memory and I/O

Use `smaps_rollup` for aggregate RSS/PSS/private/shared categories and `smaps` for selected detailed snapshots; reading mapping details has cost. `/proc/PID/io` separates bytes passed through I/O syscalls from storage-layer counters; retain field names and definitions. Neither logical SQLite reads nor syscall bytes directly establish physical device traffic. [Linux proc](https://cdn.kernel.org/doc/html/latest/filesystems/proc.html).

For future Bash/helper accounting, cgroup v2 can supply group memory, CPU and I/O accounting when available. Keep it an optional platform collector rather than a new containment guarantee. Record membership and descendant handling, and retain separate workload/orchestration groups where the runtime contract distinguishes them. [cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html).

## Native-library and future evaluator coverage

- SQLite exposes current/high-water global status, per-connection status and statement counters. Collect these through the owning Store; do not open a second SQLite connection during a Host measurement to infer its allocator state. Cache-used is a component, not total Host memory. [SQLite status](https://sqlite.org/c3ref/status.html), [statement status](https://www.sqlite.org/c3ref/stmt_status.html).
- libcurl offers replacement memory callbacks through `curl_global_init_mem`, with global initialization constraints. Consider them only if native attribution remains unresolved; changing allocators can change the behavior being measured. These callbacks are not proof that TLS, resolver and all other dependencies are covered. [libcurl memory callbacks](https://curl.se/libcurl/c/curl_global_init_mem.html).
- QuickJS provides runtime memory limits and custom allocator support through `JS_NewRuntime2`. Future evaluator evidence should distinguish engine allocation from the child process's native stacks/libraries and parent orchestration. An engine heap limit is not a whole-process footprint limit. [QuickJS memory handling](https://bellard.org/quickjs/quickjs.html#Memory-handling).
- For Zig, first inventory allocator consumers in the measured revision. Preserve the production allocator for qualification. A debug allocator or profiling wrapper is a diagnostic intervention and needs an overhead comparison; avoid a global replacement merely to obtain a tidy chart.

## Build fidelity and observer effects

Recommendations:

1. Profile the actual optimized workload build first, with usable matching debug information. Preserve source SHA and dirty diff, binary hash, compiler/dependency versions, optimization settings, architecture, symbols and native library identities.
2. Run a short known-path symbolization check before expensive captures. Report unknown frames and truncated stacks. Inline functions and optimized-away frames mean the source-level tree is not a literal execution trace.
3. If preserving frame pointers or adding instrumentation requires a different binary, label it diagnostic and measure its difference from the reference build. Do not compare a debug profile to release latency as though they were one experiment.
4. Keep baseline qualification, CPU sampling, allocation tracing and scheduler tracing separate initially. Compare elapsed time, CPU, footprint and throughput with and without each observer; report measured perturbation rather than declare an arbitrary safe percentage.
5. Bound duration, event rate, capture size and collector memory. Report dropped events, incomplete spans, unavailable metrics and collector failures explicitly; absence of evidence is not zero cost.
6. Keep output local and bounded; profile metadata may contain paths/arguments. Lifecycle diagnostics need identifiers and sizes, not captured provider payloads.

Apple explicitly discusses deferred recording to reduce observer work and trace-volume costs; Linux exposes sampling and unwinding choices. These support calibrating the selected configuration rather than assuming all profiling is cheap. [Apple CPU profiling](https://developer.apple.com/videos/play/wwdc2025/308/), [kernel perf record](https://raw.githubusercontent.com/torvalds/linux/master/tools/perf/Documentation/perf-record.txt).

## Comparisons that remain useful across revisions

Recommendations, not new qualification thresholds:

- Name the unit of useful work: a verified answer, processed input byte, validated output item, or completed tool action. Report CPU seconds per unit alongside absolute peak footprint, throughput and failures. More work must not masquerade as a regression; fewer completed results must not masquerade as an optimization. [Abseil optimization success](https://abseil.io/fast/70).
- Preserve offered versus actual arrival timing for scheduled-load cases. A producer that waits for each completion can hide demand during stalls; closed-loop interactive scenarios remain useful but answer a different question. Keep the existing provider fixture's pacing evidence rather than replacing it with a generic HTTP benchmark. [wrk2 measurement rationale](https://github.com/giltene/wrk2).
- Establish repeatability with a predetermined number/order of baseline runs before interpreting small differences. Interleave baseline/candidate runs where practical, retain every result, record thermal/power/background-load conditions, and distinguish fresh-process, cold-cache and warm-cache experiments. Do not purge caches or change host settings silently. Report sample count and spread; choose repetitions from observed variability and decision size, not a universal count. Two observations cannot support broad tail claims.
- Separate fresh-case scaling from same-process churn. Hold workload dimensions fixed while varying one; include an explicit interaction case only when the hypothesis calls for it. A microbenchmark can test identity-scan algorithm growth, but the candidate must also improve the actual assembled path. [Abseil microbenchmark guidance](https://abseil.io/fast/75).
- Preserve both absolute profile weight and percentage when comparing profiles. A function's share can rise because another function became cheaper. Keep the same event, workload denominator and meaningful capture interval; overlapping spans and inclusive call-tree totals are not additive.
- Generate one comparison report with baseline/candidate manifests, correctness outcome, resource deltas, measurement uncertainty and remaining attribution gaps. Keep native raw files immutable, version parsers/metric definitions, and test derived calculations against small known traces. Instrumentation owns bounded buffers and must report loss; it cannot block canonical work merely to preserve diagnostics.

For presentation, use Perfetto for phase/counter correlation and optionally Speedscope for stack exploration; both are replaceable views over retained evidence. Speedscope documents native Instruments/perf imports and local/offline use. Do not begin with a custom dashboard or assume conversion preserves every native trace field. [Speedscope](https://github.com/jlfwong/speedscope), [Perfetto external formats](https://perfetto.dev/docs/getting-started/other-formats).

## Smallest useful sequence

First: a reproducible bundle and metric definitions extending existing collectors; phase-aligned resource account for one representative fixture and its drain cycle. Second: independent scaling curves over active work, payload bytes, item count and history. Third: targeted native profiles for unexplained CPU, retained memory or waits. Later: Linux collectors and evaluator/Bash/Edit attribution as those capabilities need qualification. Each new collector should answer an unanswered question, not become an always-on observability platform.

## macOS current-versus-peak investigation, 2026-10-17

### Observed failure and control

The [PR508](https://github.com/DivyanshGolyan/rui/pull/508) repeat-work run at exact source [`c4224bb`](https://github.com/DivyanshGolyan/rui/commit/c4224bbbb8f33743f430be07e349933e42f3423a) failed on macOS 15.7.7 (24G720), Apple M1 Pro, kernel `xnu-11417.140.69.710.16`. The retained `/usr/bin/footprint -p 17459` report contains auxiliary counters `phys_footprint: 5201 KB` and `phys_footprint_peak: 5057 KB`. The 144 KiB inversion exceeds the collector's rounding tolerance. Both saved Host reports identify PID 17459; the inconsistency is in the raw auxiliary fields, not the parser's unit conversion or a mistaken headline total.

The command exited 1 after 77.39 seconds; collector execution lasted 20.18 seconds. First-wave controller facts record 100 history-valid and terminal-finished streams, 60,000 events, 15,600,000 offered bytes, and zero final Host custody/scratch. The final rounds array is empty. Offline audits, composition snapshots and the remaining 19 waves did not run. This is failed qualification, not a demonstrated 25,000,000-byte target miss or a passing first round.

A separate owned C process allocated and touched up to 8 MiB, waited for two external reports, then freed the mapping and exited. The 0.506-second control used Apple Clang 17, checked successful `TASK_VM_INFO` return and revision capacity, and recorded PID/start identity. All five queries requested and returned 93 words, matching SDK revision 7. Selected results:

| Phase | Direct current bytes | Direct lifetime peak bytes |
| --- | ---: | ---: |
| Baseline | 1,131,264 | 1,164,032 |
| After touching 8 MiB | 9,519,872 | 9,519,872 |
| After freeing the mapping | 1,131,264 | 9,519,872 |

Both external reports agreed at the held plateau: default output gave 9297 KB for each auxiliary counter; `-f bytes` gave 9,519,872 B for each. The inversion was not reproduced. This small idle control does not reproduce Rui's concurrent workload or explain the original failure. There was no direct kernel sample at that failure; historical PID reuse is not independently excluded. C and Python monotonic timestamps in the control use different absolute epochs and cannot be cross-subtracted.

The [intake evidence thread](https://ampcode.com/threads/T-01a13a9b-f479-7237-9c52-0aefe95d63c9) retains the independently checked nonsecret packets. The failed-run packet SHA-256 is `4ff9464b8ad10017ef50b4a879145577116ce90a7197b25644f68efb3370c92a` (71 regular members, 70 payload hashes). The control packet SHA-256 is `10c05698b2f5e03e7009fa9d311ea82105521e8d0f7c1ed2dd16fc14d3bf3989` (55 regular members, 54 payload hashes). Sources, raw reports, commands, native tool/header identities, cleanup and source manifests are retained. Neither packet turns the failed run into acceptance.

### What Apple's sources establish

- Apple's installed `footprint(1)` manual describes current `phys_footprint` as the kernel ledger's dirty-memory charge and `phys_footprint_peak` as its lifetime maximum. It documents `-f bytes` and optional JSON output. The captured manual and successful byte-format control establish these options on this machine, rather than assuming an online manual matches the installed tool.
- [XNU's `TASK_VM_INFO` implementation](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/osfmk/kern/task.c#L6040-L6060) reads current footprint and stored lifetime maximum separately. [Ledger credits](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/osfmk/kern/ledger.c#L1133-L1185) change the balance before checking it; [the check updates the maximum](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/osfmk/kern/ledger.c#L1015-L1029), while [the getter copies that stored maximum](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.140.69/osfmk/kern/ledger.c#L1418-L1443). These paths do not establish an atomic current/peak pair. Update ordering is a plausible mechanism, not the proven cause of Rui's report. This published tag is related source, not verified correspondence with the installed `.710.16` kernel or the closed `footprint` implementation.
- [Apple's footprint guidance](https://developer.apple.com/documentation/xcode/analyzing-the-memory-usage-of-your-metal-app) distinguishes allocations and resident size from footprint. Dirty compressed/swapped memory remains charged at its original size. RSS, live heap bytes and sums of VM regions are therefore not interchangeable substitutes for this target.
- [Apple's memory tools guide](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use) distinguishes allocation history from snapshots. Its Xcode report shows current use and the highest value seen; that wording does not promise a kernel lifetime bound. A maximum over periodic current samples can miss intervening peaks. A later low reading cannot repair missing earlier evidence.

### Gaps in the current collector

Inspection applies to the exact source above, not later revisions. The owning code is [measurement.go](../tests/qualification/measurement/measurement.go) and [model-output/main.go](../tests/qualification/model-output/main.go).

1. `SampleProcess` uses formatted text, sequential gopsutil calls, an external `footprint` scan and `lsof`. It records neither per-query capture brackets nor a before/after process start identity. These observations are not one atomic process snapshot. Byte format removes rounding uncertainty but would not itself fix this 144 KiB inversion.
2. The footprint parser returns an error for the inconsistent pair. `measureCapacityRound` propagates it after the `host_complete` fact but before returning a row. `measureCapacity` then returns before appending that row, collecting composition or reaching post-reap durable audits. Required resource evidence must remain nonpassing, but independent completed-work observations could still be retained and audited after safe cleanup. Fail-closed acceptance does not require discarding independent evidence.
3. A failed external footprint command returns before its raw output is written to the report file. The error includes output, but a separate original stdout/stderr/exit record would preserve stronger diagnostic evidence.
4. Full VM/heap scans and phase tracing can affect the experiment. The failed Host log contains 76,709 `trace_lost`-flagged records among 77,365 records. That is a count of flagged records, not a dropped-event count, and cannot establish a complete allocation/lifecycle history. No observer-effect comparison explains the current/peak inversion.
5. The repeat-work target measures the Host, not representative peer collaboration's aggregate Host, overlapping Rui CLI/helpers and routing shells. Even a valid Host-only result cannot complete the aggregate 25 MB or live-collaboration requirements. Retained allocation growth also needs attribution before claiming stable churn.

### Recommended next steps

These are proposed measurement corrections and diagnostics, not a changed acceptance policy:

1. Preserve raw current and peak independently, with exact byte output, command exit, sample brackets and stable process identity. Report contradictory lifetime evidence as unavailable/nonpassing. Do not clamp peak to current or substitute sampled maxima for lifetime high-water evidence.
2. Separate workload observations and post-reap durable audits from memory-sample validity in the existing runner. Publish completed facts even if a required metric fails; keep the final result nonzero and the unperformed work explicit. Continue only operations whose safety and prerequisites remain established, not arbitrary later load after a failure.
3. Diagnose the actual Rui phase with a bounded, explicitly diagnostic comparison of byte-format tool output and a supported native counter path, recording return codes and structure revisions. The idle control does not justify changing the parser or retrying until green. Two interfaces backed by the same ledger are corroboration, not independent memory accounting.
4. Keep optimized low-instrumentation qualification separate from allocation/VM/stack diagnosis. Use Allocations or VM Tracker to explain retention, with matching binary identity and observer costs stated. Confirm tool availability; do not install or switch developer tools merely to make a report look complete.
5. After a demonstrated correction, run the affected regression controls and canonical qualification again. Preserve the original failure. The 25,000,000-byte target, required audits, cleanup and full-work populations remain unchanged.

### Collector corrections and limits

The follow-up changes the collector, not Rui's runtime or resource target. `SampleProcess` retains independent core counters, names unavailable groups, and writes a full JSON receipt even when an initial sample fails. Mac captures request exact bytes and record command, exit, timestamps, and process-start identity. Valid footprint values survive a later descriptor-query failure, but the required sample remains nonpassing. The compact periodic `SamplePortableProcess` interface retains its existing all-or-nothing contract.

Capacity and retry/churn now share completed-round retention. A later observation error stops further load, preserves completed rows, and permits independent audits only after confirmed Host stop and reap. Earlier successful audits survive a later audit failure. The original observation, audit, and cleanup failures remain in the final nonzero result.

Focused regressions first reproduced lost samples and audits. Targeted mutations also demonstrated that the core-counter and completed-row tests reject their old failure mechanisms. Bounded Linux runs injected real retained-report write failures into capacity and retry/churn. Capacity kept one delivered, drained, and audited round; churn kept two rounds and audited 40 terminal operations after 80 requests. Neither launched its next wave. The first capacity control failed before workload because its temporary test executable did not dispatch provider-child mode; the corrected control passed. These checks establish evidence retention, not Mac memory correctness. The original Mac contradiction still needs an actual-Rui diagnostic, and full repeated-work qualification remains open.
