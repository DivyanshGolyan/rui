> Historical tool-landscape research, written before the trial and Xcode installation. See [completed trial](memory-trial/README.md) for executed evidence. Statements about tools not yet run describe this earlier research stage.

# Existing tools for explaining memory

Research for [#188](https://github.com/DivyanshGolyan/rui/issues/188), under [#187](https://github.com/DivyanshGolyan/rui/issues/187). Primary sources inspected 2026-09-15; source baseline `d559412ac37dbdc98049f1ad59c36ec013445b8e`.

## Answer

The smallest promising combination is **existing type inspection + the platform's native allocation history + its OS memory view**, joined initially by a short source-backed explanation. Start with LLVM/LLDB and Instruments on macOS; evaluate LLVM/pahole and heaptrack on Linux. This is a candidate for a human decision, not a selected implementation. No inspected tool independently establishes Rui's semantic cleanup owner or allocated slot population. Those facts must come from the owning source and observed workload state.

No package was installed, profiler attached, workload executed or product code changed. Tool documentation was verified; optimized Zig interoperability, local availability of each profiler, trace completeness and overhead were **not tested**. The installed compiler identifies itself as Zig 0.16.0 on ARM64 macOS. The older resource-profiling note supplied leads only; its proposed bundle, runner and viewer are not adopted here.

## The inline-field example

Suppose a type contains a `[4096]u8` path and an array allocates 1,000 elements. The field accounts for 4,096,000 bytes (3.90625 MiB) of logical inline storage, even if only eight slots are occupied. That is a derivation, not a measured footprint or a judgment of usefulness. An eight-slot occupancy count would describe work, not the allocated array's storage.

The explanation needs the field's type/size/offset, enclosing type size and padding, array allocation length, cleanup owner and interval from allocation through release. A heap allocation stack can identify the array allocation; it cannot subdivide that block into path fields. A field in a union overlaps other variants: do not add variant sizes or claim removing a field saves its size without recomputing the enclosing layout. Stack/global instances also require their actual population and lifetime, not heap-event counting. Zig exposes `@sizeOf`, `@alignOf`, `@offsetOf` and type information; layout must follow the exact target/compiler rather than declaration-order arithmetic. [Zig language reference](https://ziglang.org/documentation/0.16.0/).

At the inspected revision, [server.zig](../src/server.zig) allocates custody records using `active_capacity`; `executionMain` allocates `ExecutionSlot` using that record-array length, initializes all entries and frees the array on execution-thread exit after shutdown cleanup. `ExecutionSlot` is a tagged union. Startup already reports custody and execution-slot byte sizes. [cli.zig](../src/cli.zig) passes `std.heap.c_allocator` to `serve`. These source facts make native malloc tracing a plausible first attempt; they do not prove interception or symbolization. The current contract already says execution slots need no duplicate Store path: this example is an explanatory acceptance case, not a claim that the defect remains.

## Candidate coverage

| Existing component | What it can explain | Boundary and adoption cost |
| --- | --- | --- |
| `llvm-dwarfdump` | DWARF types, members, source references, debug-information verification; accepts ELF and Mach-O/dSYM inputs | Shared first choice for static inspection. Raw output needs interpretation; no live population or semantic owner. Verify emitted Zig union/array members. Its JSON statistics describe debug-info quality, not a ready memory inventory. [LLVM manual](https://llvm.org/docs/CommandGuide/llvm-dwarfdump.html) |
| LLDB type API | Type byte size and fields through `SBType`; useful for inspecting matching debug types | Potential Mac/Linux alternative when raw DWARF is awkward. Do not assume Zig expression evaluation or automatic pointer ownership. A small one-off inspection is less commitment than building a new viewer. [SBType API](https://lldb.llvm.org/python_api/lldb.SBType.html) |
| `pahole` | Readable structure members, offsets, sizes, padding, nested expansion from DWARF/CTF/BTF | Promising Linux ELF presentation. Its documented C-oriented output and DWARF support do not establish correct Zig tagged-union handling or a supported Mach-O path. Do not adopt reorganization suggestions as judgments. [Project manual](https://github.com/acmel/dwarves/blob/master/man-pages/pahole.1) |
| Instruments Allocations + VM Tracker; `malloc_history`, `heap`, `vmmap` | Allocation/free history, stacks, growth intervals, VM snapshots; command-line inspection of processes or captured memory graphs | Native Mac candidate, including native allocations visible at its hooks. Apple documents recording cost. Zig field names and ownership graphs are not guaranteed by C allocation stacks; VM regions are not individual logical allocations. Existing native traces can remain the presentation. [Apple heap analysis](https://developer.apple.com/videos/play/wwdc2024/10173/) |
| heaptrack | Linux heap allocation events with stacks, live/peak allocation analysis, temporary allocations, GUI and command-line analysis | Plausible with current C allocator and native libraries. Pool/custom allocators need explicit tracking API to expose suballocations; do not confuse their backing allocation with all logical objects. Native library debug symbols and stack quality matter. Project performance comparisons are not a Rui overhead measurement. [Project documentation](https://github.com/KDE/heaptrack) |
| Massif | Heap growth snapshots and allocation trees; optional page-level profiling includes mappings | Linux fallback when mapping provenance is the unanswered question. Page mode replaces ordinary heap-block profiling; it is not a simultaneous fine-grained explanation or RSS measurement. Instrumented execution adds adoption/perturbation cost. [Massif manual](https://valgrind.org/docs/manual/ms-manual.html) |
| DHAT | Block sizes, lifetimes and access statistics with its existing browser viewer | Secondary Linux investigation if allocation lifetimes remain unclear. Extra access analysis is beyond the initial descriptive need; no default waste judgment. Do not assume current ARM64 macOS compatibility. [DHAT manual](https://valgrind.org/docs/manual/dh-manual.html) |

Allocation **site** and cleanup **owner** are different: a helper can allocate a block and transfer it. None of these documented stack views proves the transfer or the last safe callback use. Source tracing supplies that explanation until a concrete case demonstrates missing runtime evidence. A pointer reachability graph likewise does not establish Rui's contractual custody.

## Native memory and overlapping measurements

SQLite has existing descriptive counters: global `SQLITE_STATUS_MEMORY_USED` reports outstanding SQLite allocations; connection `CACHE_USED`, `SCHEMA_USED` and `STMT_USED` offer component attribution. They have distinct scopes and should be read through the owning connection, where available. They overlap intercepted process allocations; adding them to heap totals double-counts. They do not report the whole process's resident memory. [Global status definitions](https://sqlite.org/c3ref/c_status_malloc_count.html), [connection status definitions](https://sqlite.org/c3ref/c_dbstatus_options.html).

libcurl offers global replacement allocation callbacks, but that is an intervention with initialization constraints, not a prerequisite for native tracing. It does not by itself establish coverage of TLS and resolver dependencies. Prefer observing the actual linked libraries first; introduce callbacks only for a demonstrated attribution gap. [libcurl memory initialization](https://curl.se/libcurl/c/curl_global_init_mem.html).

On Linux, `smaps` explains mappings with RSS, PSS and private/shared fields; `smaps_rollup` aggregates them. PSS apportions shared pages. These OS views include more than malloc blocks and do not attribute resident bytes to individual fields. On macOS, retain Apple's footprint and VM categories under their own names. Logical live bytes, allocator-reserved/free capacity, virtual size and resident/physical accounting are overlapping views, not parts of one additive total. In particular, footprint minus logical live bytes is **not** an exact allocator-retention measure. [Linux proc documentation](https://docs.kernel.org/filesystems/proc.html), [Apple memory accounting](https://developer.apple.com/videos/play/wwdc2022/10106/).

After a logical free, allocator arenas/pages may remain mapped. Compare allocation history and mapping snapshots at the same drain boundary; name any unexplained remainder. Keep Host/helpers separate from model-requested subprocesses and collectors, as the existing contract requires. Snapshot tools can miss short peaks; periodic samples do not become an allocation history.

## Smallest combinations to compare

1. **Static explanation only:** LLVM/LLDB (pahole as a Linux alternative), exact array-allocation source, and a small table. Fully answers the hypothetical inline-field contribution and owner lifetime once population is known. Cannot explain native dynamic lifetimes or allocator retention alone.
2. **Recommended prototype candidate:** add Instruments on Mac or heaptrack on Linux, plus native OS snapshots. This addresses dynamic blocks and OS context using established viewers. Keep any initial joining of evidence manual and source-linked. No custom allocator, trace schema, unified dashboard or replacement harness follows from this research.
3. **Escalation only:** Massif page mode or DHAT for a specific remaining mapping/lifetime question; SQLite counters for library subdivision. Avoid simultaneously collecting every profiler's output merely for completeness.

The serious investment is establishing trustworthy coverage and interpretation across the two platforms. A uniform collector is not necessary for a coherent explanation; the same questions can be answered with platform-specific evidence and explicit gaps.

## Evidence needed before selecting implementation

A later human-approved disposable prototype should use one known inline-array case and one bounded allocate/use/free cycle, then inspect an existing Rui fill/drain fixture without a live provider. Preserve the production allocator. Check:

- Can the selected type tool recover the actual optimized Zig field, array and union layout, matching compiler-derived sizes? Try ReleaseSafe and the intended ReleaseSmall artifact with matching symbols; classify missing/eliminated types and optimized-out variables rather than reporting zero. Native library symbol availability is separate.
- Can native tracing identify a known Zig C-allocator block and a native-library allocation, with allocation/free events and usable source stacks? Establish launch-time coverage; attach-only recording misses earlier allocations. Show any pool/mapping blind spots.
- Can the reader reproduce the 4,096 × allocated-population calculation and distinguish it from occupied work and page footprint? Can they identify the source-owned release boundary and observe the block survive until it?
- At startup, occupied work, logical completion, safe cleanup and retained idle, what do native history and OS views each say? Record timestamp scope; disclose snapshots taken at different instants.
- Compare a short untraced run with the traced run for elapsed time, footprint and completed work; report capture/collector size and unavailable or lost evidence. Do not infer overhead from vendor claims or equate a diagnostic build with production qualification.

Keep exact revision, target, optimization, compiler, binary and matching symbols with the native outputs and a short explanation. These are prototype provenance needs, not a new permanent bundle specification. No latency/CPU gate, alert, automatic classification or migration decision is proposed.

**Next human decision:** is static layout plus native allocation/OS evidence the right first prototype boundary, and which additional concrete memory situation beyond the inline slot should it demonstrate? Tool selection remains open until the interoperability evidence above exists. This research resolves the tool-landscape question; it does not resolve [#189](https://github.com/DivyanshGolyan/rui/issues/189) or production qualification.
