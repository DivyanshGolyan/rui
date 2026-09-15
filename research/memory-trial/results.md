# Whole-Host memory explanation trial

Disposable trial against merged main d559412ac37dbdc98049f1ad59c36ec013445b8e, macOS ARM64, Zig 0.16 ReleaseSafe. No production source changes. Local HTTP fixture; 8 allocated execution slots, one request, 100,000 answer bytes.

## Verified evidence

Both the run without allocation logging and the malloc-stack-logging run saved and returned the exact answer. Post-result inspection showed zero occupied custody records and zero scratch bytes. Phase logs recorded cleanup completion.

| Phase | Without allocation logging: footprint (tool KB) | With allocation logging: footprint (tool KB) |
|---|---:|---:|
| Startup idle | 3265 | 4593 |
| Waiting for provider | 4305 | 5857 |
| After result delivery | 4513 | 6321 |
| Retained idle | 4625 | 6433 |

These are individual sequential snapshots, not simultaneous measurements or statistically established overhead estimates. The run without logging still invokes diagnostic tools. Footprint is an OS accounting metric, not the sum of requested allocation sizes. Logging itself appears as performance-tool memory in the footprint report.

## What the tools explain

- `heap` describes live heap blocks and allocator size classes.
- `malloc_history` supplies allocation call paths with Zig, SQLite, curl and OpenSSL symbols. Allocation history totals must not be mistaken for live retained bytes.
- `vmmap` separates virtual reservations, resident pages and region categories, including stacks and mapped libraries.
- `footprint` reports process-level physical memory accounting.
- Existing SQLite diagnostics expose allocator current/high-water values and pager-cache usage. These overlap the native heap view and must not be added to it.
- `dsymutil` plus `dwarfdump` exposes type size and member layout. ExecutionSlot is 1,216 bytes; eight allocated elements occupy 9,728 logical bytes even with no active requests. CustodyRecord is 40 bytes, or 320 bytes for eight. Union variants overlap; their sizes are not additive.

Together these give allocation origin, physical footprint, fixed layout and lifecycle evidence. Semantic ownership and why a field is retained still require reading the owning code.

## Limits and next decision

Snapshots miss short-lived allocation peaks during response import and delivery. One request does not explain concurrency scaling. The local fixture exercises HTTP, not a TLS handshake. Allocation call sites do not establish current semantic ownership. Linux has not been trialed.

Xcode and Instruments were installed and initialized. An Allocations attachment run completed the workload but reported failed attachment on finalization; its saved trace is not accepted as allocation evidence. Launch mode failed similarly with the original binary. Signing a disposable copy with `com.apple.security.get-task-allow` enabled a successful recording. The complete workload then passed under Instruments, and its UI showed populated Allocations and VM Tracker tracks with no recording error. The original binary and production source were unchanged.

No production-path changes are justified by this trial yet. The valid Instruments recording establishes that existing tools can collect the evidence. Assess the remaining ownership/lifecycle explanation gaps before adding an adapter or counters.

## Reproduction and raw artifacts

Driver: `run.py` beside this report. It is a disposable experiment, not a supported harness.

- `/tmp/latifa-memory-trial-baseline`: successful workload, snapshots without allocation logging.
- `/tmp/latifa-memory-trial-logged3`: successful workload, snapshots and allocation histories.
- `/tmp/latifa-memory-trial-instruments2`: successful workload but failed Instruments attachment; preserve failure log.
- `/tmp/latifa-slot-dwarf.txt`: extracted type layout.
- `/tmp/latifa-memory-trial.dSYM`: matching debug information.

Earlier logged2 and first Instruments attempts failed in the disposable driver and are excluded from successful trial claims. Host processes are terminated at trial end; this is not graceful-shutdown qualification.

## Instruments result

Successful trace: `/tmp/latifa-memory-trial-instruments-debug/host.trace`, opened and verified in Instruments. The full-range Statistics view reports 1.28 MiB persistent heap across 4,448 allocations and 7.19 MiB total heap allocation volume across 21,501 allocations. Anonymous VM is a separate category, including stack reservations; it is not physical footprint. These values include the instrumented process and are not production memory qualification. Startup stacks are not recovered by this attach-mode recording.

The useful distinction is retained memory versus allocation volume: memory can be allocated and freed repeatedly without all of it being live together. Existing Instruments views expose that distinction directly. Fixed field layout still comes from debug type information; semantic ownership still comes from source.

## Whole-Host ownership map

This map describes the implemented model Host at the recorded commit. Workflow evaluators and model-requested tools are not implemented in this slice and were not exercised. Values marked “bound” describe source capacity, not observed consumption. Rows overlap where one is contained inside another; do not sum this table.

| Memory owner / storage | Population and lifetime | Evidence and amount | What remains unexplained |
|---|---|---|---|
| Host and Store control state | One per running Host; outlives execution and connection drains | `server.serve` owns stack-local Host, Store and lease | Full nested field layout and actual stack contribution not yet attributed |
| Execution workspace | One array of configured capacity; execution-thread lifetime, including idle slots | 8 × 1,216 = **9,728 logical bytes**; compiler layout and ready diagnostics agree | Separate physical-page cost is not meaningful for this small allocation |
| Custody bookkeeping | One array of configured capacity; Host lifetime | 8 × 40 = **320 logical bytes** | Allocator rounding is additional; occupancy does not change array length |
| Provider transfer state | One active union variant per occupied execution slot; remains until safe cleanup | `ProviderSlot` embeds `Transfer`; request/capture handles and callback state reside inside the execution workspace | This is already included in slot size; native allocations behind pointers are additional |
| curl reactor, transfer handles and headers | Reactor per execution thread; easy handle and headers per transfer | `Reactor.deinit`, `curl_easy_cleanup`, `curl_slist_free_all` are release boundaries; native call paths available | Per-owner live byte totals need trace drill-down; avoid assigning all curl allocations to the last request |
| OpenSSL and platform initialization | Library/global initialization plus transport-specific state | Native allocation histories expose OpenSSL and macOS initialization paths | HTTP fixture does not establish TLS connection costs or reuse behavior |
| SQLite | One Store connection plus process-global SQLite state; cache may survive each request | Logged run after cleanup: **407,264 bytes** current SQLite allocator usage; **766,352 bytes** high-water; **261,760 bytes** approximate pager cache | Pager cache is a subset, not an extra amount. Counters belong to this run, not the Instruments run |
| Incoming client Connection objects | Allocated on accept, bounded by 12 clients; destroyed after connection handling | `allocator.create(Connection)` and connection cleanup | Observed byte attribution not yet extracted |
| Client thread stacks | Spawned per connection; configured **1 MiB per thread**, at most 12 concurrent client threads | **12 MiB virtual reservation bound** for client stacks only | Not resident usage; runtime may retain freed stack mappings; main/execution/library threads are additional |
| Result-delivery windows | Scoped to result delivery; up to 10 ordinary clients | **64 KiB window**, **640 KiB simultaneous bound** | Buffer storage may be part of a stack; do not add again to stack footprint |
| Request preparation / parsing / output validation windows | Temporary work inside the relevant call; bounded buffers and disk-backed payloads | Source contains fixed read windows; successful exact 100,000-byte answer readback | Complete overlapping stack-frame layout and transient peak attribution remain open |
| Allocator pages and bookkeeping | Shared across all heap owners; pages can remain after individual frees | Unlogged retained-idle footprint report: medium 1,328 KB, small 496 KB, tiny 464 KB, metadata 144 KB | These are allocator-region dirty bytes, not application-requested live bytes; no per-owner split asserted |
| All thread stack mappings | Main, execution, client and library threads; OS-managed | Unlogged retained-idle VM snapshot: **32.6 MiB virtual**, **224 KiB resident** | This snapshot does not identify each stack's owning thread |
| Binary / shared-library data and mappings | Process/library lifetime; mixture of shared and private pages | `vmmap` and `footprint` identify TEXT, DATA, mappings and page-table categories | Shared mapped size must not be charged as wholly private Host memory |
| Scratch and SQLite payload files | Disk-backed request/response/content, with ownership transferred or released by lifecycle | After completion: zero charged scratch; answer remains durable in SQLite | Logical file bytes are not heap bytes. Filesystem cache and kernel memory are not fully attributed here |
| Measurement machinery | Only when diagnostics are enabled | Separate unlogged and logged runs; Instruments is a third run | Instrumentation changes memory and timing; one pair is not an overhead calibration |

### How to read one owner

Execution workspace → 8 allocated elements → 1,216 bytes each → 9,728 bytes retained for execution-thread lifetime. One active request changes which union variant is used, not the number or size of allocated elements. The provider variant includes callback and capture metadata; native curl allocations sit behind pointers and are additional. This is the same reasoning that would explain an inline path buffer multiplied across unused slots.

Source links (the measured checkout):

- [Host and custody ownership](../../src/server.zig#L110)
- [Connection allocation and stack setup](../../src/server.zig#L237)
- [Execution workspace and union variants](../../src/server.zig#L259)
- [Provider transfer fields](../../src/provider.zig#L577)

## Smallest useful deliverable

Keep the native trace, the matching executable/debug information, the run inputs and lifecycle observations together with this short ownership map. Instruments answers allocation size, origin and lifetime; debug layout explains fields within an allocation; source supplies semantic ownership. OS snapshots cover the rest of the process. An unknown stays unknown instead of becoming a guessed category.

This first map is descriptive and incomplete: it does not yet assign every live heap byte to a semantic owner. The next focused investigation is native allocation drill-down and the largest retained blocks, then stack/thread attribution. If those tools cannot connect an allocation to its owner reliably, discuss a narrowly scoped production observation point with a concrete missing fact. No custom allocator, automatic waste verdict, threshold policy or production counter was added.

## Retained heap attribution follow-up

Native heap rows reconcile to 1,315,968 bytes. Grouped by allocation origin (not proof of current semantic owner):

- Thread-local signal-stack storage: 589,824 bytes.
- SQLite: 407,264 bytes.
- OpenSSL: 144,256 bytes.
- curl: 27,760 bytes.
- Zig allocator call sites: 23,968 bytes.
- Other / unattributed: 122,896 bytes.

The two dyld thread-local allocations have history stacks through Zig Thread.maybeAttachSignalStack. Installed Zig std.zig:125 defaults signal_stack_size to 1<<18 (256 KiB); Thread.zig:1735 embeds that in thread-local storage. The observed allocation request is 262,160 bytes per block, while heap reports a 294,912-byte size class. The two live blocks total 589,824 bytes. This identifies the major retained category without proposing a runtime change. Ordinary thread stack reservations are separate.

Visualization: /Users/divyanshgolyan/.codex/visualizations/2026/09/15/latifa-memory/index.html. Slot arithmetic is interactive and explicitly not a measured concurrency extrapolation. Browser preview was blocked by the browser URL policy; visual rendering has not been verified.

## Checkpoint reproduction

The packaged collector completed baseline, malloc-logging and Instruments runs on this Mac after a ReleaseSafe rebuild. All three manifests reported success, every snapshot tool exited successfully, exact 100,000-byte readback passed, and custody/scratch returned to zero. Build cache was reused through ZIG_LOCAL_CACHE_DIR; workload evidence was freshly collected. The historical chart above remains the original logged3 sample, not these later runs. Python compilation and git diff whitespace checks passed. Independent read-only review found no remaining collector or evidence-claim blockers. Browser rendering remains unverified because local URL navigation was blocked by tool policy.
