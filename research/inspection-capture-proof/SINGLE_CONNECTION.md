# Single-connection inspection capture

> **Historical experiment, published 6 September 2026.** Sources, fixtures, and recorded observations retain their original investigation scope. Historical decision/implementation status is not a current plan or production verification claim.

Decision follow-up: the user accepted this starting approach in [ADR-0024](../../docs/adr/0024-capture-run-inspection-before-delivery.md). Measurement limitations below still apply.

Measured 5 September 2026 on MacBookPro18,1, 16 GiB RAM, macOS 15.7.7 arm64.
This is a synthetic native measurement, not the unimplemented Run inspection API.
Repository baseline: `3bdadc8395716e587f3da11f0b85ecdb3b91274a`.

## Decision supported

Start with capture on the existing connection, using private batches rather than
preparing a query per record. The measured pause is small for modest reports.
These results do not justify switching to WAL solely to enable inspection.
They also do not establish trivial pauses for arbitrarily large complete reports.

The single connection cannot admit or settle other database work during the
capture. The measured capture interval is the added wait for a command ready at
capture start, before its own execution or any existing queue. All Runs sharing
the Host are affected, not just the inspected Run. Repeated inspections can add
queueing delay; this experiment measures one capture at a time.

## Results

Five runs per strategy and size, with strategy order rotated. The recommended
starting strategy uses keyset batches of 100; records are processed individually
inside each batch, without building an in-memory collection.

| Inspection records | Report size, decimal | Batched capture median | Observed range |
| ---: | ---: | ---: | ---: |
| 100 | 38.5 kB | 0.56 ms | 0.50–0.65 ms |
| 1,000 | 386 kB | 1.11 ms | 0.95–1.27 ms |
| 10,000 | 3.88 MB | 8.72 ms | 8.01–9.41 ms |
| 100,000 | 39.0 MB | 94.05 ms | 92.16–98.74 ms |
| 1,000,000 | 392 MB | 880.69 ms | 843.08–942.32 ms |

These are record counts, not model calls or Runs. A real inspection may emit
several records for one Turn. The fixture emits membership-like status records
with identifiers, digests, references, and a 128-byte synthetic binding field.
Large model output is not copied into the report.

A wider synthetic binding field of 1,024 bytes increased batched capture medians
to 30.37 ms for 10,000 records (12.8 MB report) and 299.55 ms for 100,000 records
(128.6 MB report). This is a width sensitivity check, not a proposed wire field
or accepted identifier limit.

A single retained cursor was slightly faster: 7.46 ms at 10,000 ordinary records,
85.83 ms at 100,000, and 759.33 ms at one million. Preparing and finalizing a
separate query for every ordinary record took 82.56 ms, 848.90 ms, and 8,357.87 ms
respectively. Private batching captures most of the gain without requiring a
cursor to remain open between batches. The read transaction still spans capture.

SQLite heap high water was 176,704 bytes for ordinary records and 178,256 bytes
for wider records, independent of record count in this sweep. The baseline after
opening and configuring SQLite was 176,688 bytes. That baseline already includes
the configured page cache and other connection allocations; it is not the
incremental cost of adding inspection to the actual Host.

The fixture uses a 4 KiB formatting buffer and 8 KiB buffers for each of writing
and later reading. It does not materialize the report in RAM. Sampled total
process physical footprint ranged from 1,016,384 to 1,557,248 bytes across all
cases. Sampling every 4,096 records plus endpoints can miss peaks. These figures
are not whole-system memory accounting and exclude filesystem cache outside the
process. Report scratch consumption grows with report size.

## Method and checks

`single_connection.c` links the repository's pinned SQLite 3.53.4 amalgamation
from its Zig package cache. The runner extracts only `sqlite3.c` and `sqlite3.h`
into a temporary directory, and applies the SQLite compile definitions from
`build.zig`. It builds with Apple Clang `-O2`, rather than the Zig build pipeline.

The fixture uses one connection and one thread, `journal_mode=DELETE`,
`synchronous=EXTRA`, disabled mmap, a 64 KiB suggested page cache, and the
existing cell-size check. It does not reproduce every Host hardening setting,
allocation limit, authority query, state classifier, or schema constraint.

Data consists of an indexed Run membership table joined to a Turn table by
primary key. Status is precomputed in this fixture; the real design derives it
from committed relational facts. All strategies use the same ordered join.
Assertions require zero full-scan steps and zero sorts. This is intentionally a
well-indexed query shape, not evidence that the real inspection queries are ready.

Timing starts before private temporary-file creation and covers `BEGIN`, the
initial revision read, all queries, JSON formatting and buffered writes, the end
record, `fflush`, and `COMMIT`. Scratch is temporary and reconstructable, so it
is not fsynced. Time spent waiting for a client is excluded. Generated strings
do not require JSON escaping; the real encoder may do more work.

Each capture starts a fresh process/SQLite cache. Filesystem caches are not
purged, so these are not cold-disk measurements. There is no simultaneous load,
disk-pressure injection, or real HTTP reactor. Five observations per case are
insufficient to establish tail-latency guarantees.

After capture, the fixture asserts autocommit and commits a revision change
before delivering any report bytes. That commit took 0.38–1.55 ms across the
105 runs. During delivery it asserts no transaction is retained, checks the
total byte count and expected newline count, and deletes scratch on close.
Row-order, row-count, SQLite result codes, and successful flush/close assertions
also passed. The earlier Python probe separately exercises simulated slow
delivery; this native sweep does not simulate a slow network.

## Reproduction and remaining decision

From the repository root, on macOS with the dependency already in Zig's cache:

```sh
python3 research/inspection-capture-proof/measure_single_connection.py
```

Raw observations and summaries are in `single-connection-results.json`.
All fixture databases and temporary reports are removed automatically. No LLM
calls, application stores, or production source modifications are involved.

The next implementation check is to run the actual complete inspection queries,
encoder, and scratch path through the same size sweep, then check command latency
under concurrent polling. No logical collection cap is selected by this test.
Whether a roughly 0.1–1 second pause for very large reports is acceptable remains
a product/resource decision; ordinary workflow progress should not be confused
with resource exhaustion or an unlimited latency promise.

The proposed change still needs to amend the current revision-guard scan rules
and allow the capture read transaction to span private scratch writes. Client
transfer must remain outside that transaction. WAL and an extra read connection
remain alternatives if integrated measurements make them necessary.
