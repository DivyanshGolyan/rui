# Reliable inspection while a Run progresses

> **Research record, published 6 September 2026.** Findings and proposals below reflect the dated investigation. Subsequent decisions are owned by [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCT.md](../../PRODUCT.md); historical recommendations and implementation-ticket references do not override them.

Research and synthetic proof, 5 September 2026. The single-connection approach
is now accepted in [ADR-0024](../adr/0024-capture-run-inspection-before-delivery.md).
The WAL alternatives below remain research, not the selected implementation.

Follow-up: the [native single-connection sweep](../../research/inspection-capture-proof/SINGLE_CONNECTION.md)
supports trying the existing connection first. Batched capture took about 1 ms
for 1,000 ordinary records and 9 ms for 10,000; large reports took longer.
This supersedes the initial preference for a WAL reader as the starting point.
WAL remains an alternative if the actual implementation's write delays require it.

## Finding

Normal execution need not invalidate an inspection. Capture a consistent report
using SQLite's read view, close that view, and then stream the report from private
scratch. The report describes one point in time; exact control preconditions
still protect against changes after capture.

SQLite WAL supports a fixed read snapshot while another connection commits.
Separate connections remain isolated even when used by the same thread.
[SQLite isolation](https://www.sqlite.org/isolation.html).

The important boundary is the duration of report preparation, not client transfer.
A WAL reader can prevent checkpoint progress and retain WAL storage while it is
open. A completed scratch report has no such database dependency.
[SQLite WAL](https://www.sqlite.org/wal.html).

## Minimal alternatives

- Capture on the existing writer connection, finish the read, then send scratch.
  This has the fewest moving parts but prevents interleaved semantic writes
  throughout capture. Physical effects can continue; admission and settlement
  wait. Complete uncapped reports have no established acceptable worst-case delay.
- Use one shared read connection under the existing Storage Owner, in WAL mode.
  Interleave bounded capture steps with writer work on the same owner thread.
  Release the read transaction before HTTP transfer. This permits reliable
  capture without a database connection or snapshot per client.
- Merely spool the existing revision-guarded scan faster. This reduces exposure
  to changes but does not remove invalidation or starvation under activity.

The first is now the preferred starting point, subject to measuring the actual
inspection queries and acceptable command delays. The second remains an option
if ongoing mutation must remain possible during large reports. Neither needs a
new reader thread, historical snapshot API, event log, public cursor, or per-Run
read object.

## Synthetic check

Run `python3 research/inspection-capture-proof/probe.py` from the repository.
It uses a temporary database and unlinked temporary report, then deletes them.
Raw output is in `research/inspection-capture-proof/results.json`.

The fixture has 10,000 small records, reads batches of 100, and uses one thread
with two SQLite connections. It deliberately interleaves writes:

- Revision-guarded scans invalidated on all 20 attempts when a write was forced
  between batches. This is an adversarial schedule, not an estimated production
  failure rate.
- Removing the guard without a snapshot produced mixed record generations.
- Snapshot capture returned all 10,000 records from revision zero while 100
  writer transactions committed. The complete report was 518,982 bytes.
- The WAL reached 898,192 bytes. A passive checkpoint during capture reported
  218 log frames and zero checkpointed frames; the snapshot did retain WAL.
- Releasing the snapshot allowed a truncate checkpoint. During simulated slow
  report delivery, 64 additional writes and truncate checkpoints succeeded with
  no read transaction retained.

This ran against Python's SQLite 3.53.4, not OnePage's compiled engine. The report
capture took about 34 ms in this one small synthetic run, including interleaved
writes; it is not a latency guarantee, throughput benchmark, memory proof, or
production certification. Delivery was simulated by draining the file in chunks
with delays, not by an HTTP client. The fixture omits OnePage joins, authority,
content ownership, scheduler fairness and failure injection.

## Required changes and remaining costs for the WAL alternative

Current `src/host_store.zig` uses one database handle and explicitly selects
`journal_mode=DELETE` and `synchronous=EXTRA`. WAL plus a shared read connection
is a real storage-policy change. `build.zig` sets `SQLITE_THREADSAFE=0`; retain
single-thread SQLite ownership rather than introducing a reader thread.

`ARCHITECTURE.md`'s Run-interface section, ADR-0022, and selected design B currently
prohibit retained read transactions and prescribe revision invalidation. Those
clauses need an explicit amendment. Clarify that private scratch capture may
span a read transaction, while client transfer and external-effect execution
remain outside semantic transactions.

The capture snapshot begins at the first database read, not merely `BEGIN`.
Read revision and authorized report facts within that view; finalize statements
and end the transaction before transmission or capture-connection reuse.
[SQLite transaction control](https://www.sqlite.org/lang_transaction.html).

One shared capture limits resident read machinery. Complete report size and
capture duration are not inherently bounded by that choice. Charge report scratch,
WAL growth, read-connection memory, and retained reports for slow clients; allow
checkpoint progress between captures and fair admission/settlement work during
capture. Resource exhaustion or interrupted capture may still fail explicitly.
There is no unlimited-reliability or unlimited-storage promise.

The existing [SQLite policy decision](https://github.com/DivyanshGolyan/onepage/issues/95)
and [Host budget decision](https://github.com/DivyanshGolyan/onepage/issues/68) own
the resource settings. The proposed user-facing guarantee is narrower and useful:
ordinary changes in a running workflow do not invalidate its completed inspection.
