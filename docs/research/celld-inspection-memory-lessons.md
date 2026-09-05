# Celld lessons for OnePage inspection and memory

> **Research record, published 6 September 2026.** Findings and proposals below reflect the dated investigation. Subsequent decisions are owned by [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCT.md](../../PRODUCT.md); historical recommendations and implementation-ticket references do not override them.

Source review, 5 September 2026. Local clone:
`/Users/divyanshgolyan/code/personal/celld`.
Pinned commit: `a52f9905425bc41134d817694bdc2c50bcc5e856` (v0.4.0).
The [article supplied by the user](https://flaviocopes.com/celld/) identified the
project; findings below come from the cloned source. No Celld build, fleet, or
performance test was run. The single-connection capture approach is now accepted
in [ADR-0024](../adr/0024-capture-run-inspection-before-delivery.md); the source
comparison below records supporting evidence and implementation lessons.

## Recommendation

Keep the current direction: one Host-owned connection, capture the required Run
facts into private scratch, close the read transaction, then deliver the report.
Celld provides a direct precedent for inspecting a private captured copy. It does
not establish that OnePage needs WAL, a second read connection, a database per
Run, or a public snapshot service.

The [single-connection measurements](../../research/inspection-capture-proof/SINGLE_CONNECTION.md)
remain the latency evidence for our proposed starting point. Celld's source is
architectural evidence, not a substitute for measuring our actual inspection
queries and concurrent command latency.

## 1. A real capture-before-inspection path

For an active cell, the management explorer runs a blocking task that calls
`snapshot_active`, then `inspect_snapshot`. The first creates a private
`.inspect-{cell}-e{epoch}/db.sqlite`; the second opens that copy read-only and
builds a JSON result. The native backup source and destination connections are
closed before the snapshot path is handed back. The snapshot owner attempts to
remove its temporary directory on drop.
[Explorer dispatch](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/control_plane.rs#L1250-L1266),
[snapshot creation](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/ltx_repl.rs#L2056-L2080),
[backup scope](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/replication.rs#L370-L409),
[cleanup](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/replication.rs#L39-L71).

This is stronger evidence than the separate `/state` endpoint, which collects
operational state in memory. Its actor-owned portion is captured synchronously,
but the wrapper subsequently adds drain-pin and deployment information from
other runtime state. It is not a precedent for one atomic database snapshot
covering every reported field.
[Actor capture](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/actor.rs#L2617-L2631),
[wrapper](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/actor.rs#L1582-L1623).

**Apply:** make the completed report own only its scratch file and delivery
state. Neither the client nor the network writer should own a live SQLite
cursor or transaction. Cleanup belongs to that private owner.

**Do not copy the whole mechanism:** Celld backs up an entire cell database
using separate source and destination connections, 64 pages per backup step,
and a configured 5 ms pause. OnePage has one Store containing multiple Runs and
immutable content. Copying that Store to inspect one Run would do unrelated work
and need extra storage. Serializing only the required facts is a better fit.

## 2. A small response does not imply cheap preparation

Celld's explorer caps its table preview at 25 rows and 32 columns, limits shown
values to 2 KiB, and uses a 96 KiB response budget. It explicitly marks truncated
tables, rows, and values. Those limits apply after the full active database copy
has been made.
[Limits](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/control_plane.rs#L29-L34),
[inspection and previews](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/control_plane.rs#L1380-L1520).

Its fleet CLI similarly uses bounded listings with explicit continuation.
This solves a different product problem from OnePage's complete inventory of
memberships and actionable permissions.
[CLI contract](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/cell_cli.rs#L133-L152).

**Apply:** measure the complete preparation path and its disk consumption,
not just output size or final JSON encoding. A batch size bounds working memory
and individual query work; it does not bound total capture time. Preserve the
distinction between a complete report and a preview. No silent truncation or
new collection cap follows from this precedent.

Its ordinary SQL iterator makes a different tradeoff: it copies one row per
step but retains the native SQLite statement across JavaScript iteration.
Incremental output alone therefore does not establish that the database view
has been released. Its D1 API instead materializes bounded results in memory,
with a 100,000-row limit and a 32 MiB result budget. Neither should replace our
complete report captured incrementally to disk.
[Retained cursor](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/storage.rs#L1472-L1553),
[D1 budgets](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/storage.rs#L1596-L1608).

## 3. Ownership and synchronous work are useful; the topology differs

Celld's storage operations exposed to JavaScript are synchronous Rust operations.
Each cell has its own connection and database; connections are opened when cells
activate and closed when they are evicted. Isolate entry uses an asynchronous
gate followed by a synchronous closure, and a round-robin scheduler shares
isolate turns among cells.
[Storage ownership](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/storage.rs#L6-L14),
[turn boundary](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/pool.rs#L192-L229).

This does not mean every logical database transaction is short or cannot cross
an asynchronous wait. Its JavaScript `storage.transaction` starts a transaction,
awaits the callback, then commits or rolls back.
[Transaction implementation](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/js/harness.js#L1570-L1598).

Celld selects WAL and `synchronous=NORMAL`; its stated durability boundary
depends on replication. Those settings are tied to its replicated architecture,
not evidence that they suit OnePage's local durable Store.
[WAL setup](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/storage.rs#L278-L288),
[durability rationale](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/storage.rs#L348-L355).

**Apply:** express capture as a synchronous operation whose return value has no
live database dependencies. Keep waiting for delivery outside it. Existing
scheduling should prevent repeated inspection requests from starving mutations;
there is no need to import Celld's isolate scheduler merely to obtain that rule.

**Do not infer a database-per-Run requirement:** that would multiply connections,
caches, and files, and force a redesign of our shared Session/content authority.
Celld itself budgets eight open file descriptors per resident cell.
[Descriptor budget](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/startup.rs#L111-L118).

## 4. Reuse statements and output buffers before adding concurrency

Celld configures a prepared-statement cache and separately limits the query-text
bytes accounted to its native SQL statement cache. That second limit is not a
bound on total compiled-statement memory. Its CLI uses one buffered output
writer to avoid a write syscall per row.
[Connection cache](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/storage.rs#L695-L698),
[native cache accounting](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/storage.rs#L1183-L1215),
[buffered output](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/cli_output.rs#L112-L148).

Our benchmark's slow one-record strategy prepared and finalized each query.
Its approximately tenfold penalty is not evidence that reading a record at a
time is inherently slow: it includes repeated preparation. Batching already
removed most of that cost. Reusing a small fixed set of statements is another
ordinary optimization to evaluate in the implementation.

**Apply:** use bounded buffers and efficient known queries. A reusable inactive
statement is different from an active cursor holding a read view. Keep any cache
inside the Storage Owner and account for it; do not copy Celld's cache sizes
without measuring our smaller memory budget.

## 5. Measure retained memory and operating-system charges

Celld records RSS, allocator-adjusted in-use memory, active cgroup working set,
and total cgroup charge separately. Its pressure classifier keeps an absolute
limit based on the full charge when available. It also explicitly handles
allocator pages that remain resident after objects are freed.
[Memory sample](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/memory.rs#L12-L30),
[allocator retention](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/celld/memory.rs#L164-L195),
[full-charge limit](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/logic/pressure.rs#L15-L43).

**Apply:** retain SQLite allocation measurements, but also measure process
footprint, scratch-file growth, and relevant OS/container memory during large
captures and repeated slow downloads. Reusable buffers and cleanup tests are
more immediately relevant than introducing a memory-pressure subsystem.
Our existing native sweep measured SQLite heap and sampled macOS process
footprint; it did not measure total filesystem-cache charges.

A related distinction is explicit in Celld: a request awaiting I/O stops
consuming an executing isolate turn, but its promise remains in the isolate
heap. Awaiting an LLM is not automatically equivalent to freeing its memory.
[CPU versus retained request state](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/logic/isolate.rs#L11-L22).
OnePage's existing choice to discard an evaluator at durable barriers remains
valuable; copying a cell-per-workflow runtime would not improve that by itself.

## What this changes next

The design direction stays the same. The implementation verification should
cover four concrete properties:

1. A report is complete and internally consistent; missing data is not hidden
   behind a successful preview.
2. Capture returns without live SQLite statements or transactions needed by the
   network writer, and private scratch is reclaimed on all exit paths.
3. Large captures and repeated polling have measured effects on command latency
   across the Host, including write completion and cancellation admission.
4. Repeated capture and slow delivery stay within the intended memory and disk
   budgets, including resources outside SQLite's allocator.

No public cursor, snapshot registry, extra workflow server, or per-Run database
is required by these lessons.
