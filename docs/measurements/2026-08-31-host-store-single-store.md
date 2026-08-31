# Host Store single-store cutover measurement

This issue-specific measurement compares fixed base `59a97ec` with the issue-#49 head. The head population fixture was rerun after fixing its scratch lifetime: each `TransientScratch` and Session now closes inside its population-loop iteration, before RSS and footprint sampling. Both shapes create fresh stores containing 100, 1,000, and 10,000 Dormant Sessions and use the same original 36-byte task `Measure one durable agent lifecycle.`. Each Session stores the task, root Conversation row, and initial Session-ledger transaction. The base also creates the former Session directory, owner lock, and custom durable content file; the head creates none of them.

Run the head fixture with:

```sh
zig build host-store-density
```

Environment: `MacBookPro18,1`, Apple arm64, 16 GiB RAM, macOS 15.7.7, Zig 0.16.0, ReleaseSafe fixtures. SQLite used 4 KiB pages, rollback-journal `DELETE`, `synchronous=EXTRA`, the 64 KiB page-cache profile, and the existing 8 MiB process heap allowance. Each population used a fresh database. Raw machine-readable records are in [`2026-08-31-host-store-single-store.jsonl`](2026-08-31-host-store-single-store.jsonl).

The first three JSONL rows are historical base evidence from the older extended schema and remain the baseline. The final six rows are the verbatim stdout from `zig build host-store-density` in a clean detached checkout of implementation commit `0f0b324541ae96af1e0aea764c6d18da138f4545`; this evidence commit is its child. The current fixture emits only its documented fields, so this report does not enrich those rows. For the head durable-footprint table, `database_file_bytes` and `database_allocated_bytes` are aliases for the logical and allocated durable-store bytes because SQLite is the sole durable store and the fixture creates no Session files. Results are one run per point, not medians or statistically stable performance claims.

## Durable footprint

“Allocated” uses `st_blocks * 512` for the database and every former Session file. “Logical” uses file lengths. The head has only the database; the base total adds the database and Session files.

| Dormant Sessions | Logical content | Base durable logical / allocated | Head durable logical / allocated | Allocated reduction |
| ---: | ---: | ---: | ---: | ---: |
| 100 | 3,600 B | 91,920 / 491,520 B | 106,496 / 106,496 B | 78.3% |
| 1,000 | 36,000 B | 583,328 / 4,628,480 B | 622,592 / 622,592 B | 86.5% |
| 10,000 | 360,000 B | 5,259,840 / 46,243,840 B | 5,591,040 / 6,316,032 B | 86.3% |

The base Session files have 100 logical bytes and one 4 KiB allocated block per Session: the 36-byte task plus the custom content framing, while zero-length lock files add no allocated blocks on this filesystem. The head removes that per-Session allocation floor. At 10,000 Sessions, durable allocated bytes fell from 46.2 MB to 6.32 MB.

## SQLite and process I/O

Process disk bytes are the actual `proc_pid_rusage(RUSAGE_INFO_V2)` disk-byte deltas around each population, not output-block counters or inferred page bytes. SQLite writes and spills are SQLite connection counters. The journal high water is the greatest `st_size` and `st_blocks * 512` observed immediately before commit; the `DELETE` journal was absent after every commit.

| Sessions | Base / head SQLite writes | Base / head cache spills | Base / head process disk read | Base / head process disk write | Base / head journal allocated high water |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 939 / 1,039 | 0 / 2 | 57,344 / 16,384 B | 12,529,664 / 13,426,688 B | 53,248 / 57,344 B |
| 1,000 | 10,030 / 11,197 | 593 / 1,099 | 520,192 / 45,056 B | 181,841,920 / 196,722,688 B | 86,016 / 81,920 B |
| 10,000 | 105,805 / 116,801 | 11,351 / 17,019 | 5,193,728 / 7,303,168 B | 2,333,978,624 / 2,336,788,480 B | 98,304 / 106,496 B |

The single-store cutover does not eliminate SQLite write work: it moves task content into the same transaction. Process I/O and cache-counter samples vary materially across runs, so the fixture reports them without claiming a stable delta. The important simplification is that all recoverable writes now share one transaction boundary and one observable owner; further write optimization no longer coordinates two stores.

## Latency, throughput, and process memory

| Sessions | Base / head wall time | Base / head p50 | Base / head p95 | Base / head p99 | Base / head Sessions/s |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 155.4 / 79.885 ms | 1.423 / 0.771 ms | 2.279 / 1.031 ms | 3.190 / 1.113 ms | 643 / 1,251 |
| 1,000 | 1.570 s / 906.194 ms | 1.466 / 0.856 ms | 2.280 / 1.289 ms | 3.403 / 1.578 ms | 637 / 1,103 |
| 10,000 | 17.590 s / 11.138 s | 1.571 / 1.032 ms | 2.504 / 1.638 ms | 4.600 / 2.346 ms | 568 / 897 |

The corrected head run performs the intended allocation teardown on every iteration. Its timing is a single lifecycle-correctness measurement, not a statistically stable throughput comparison with the prior retaining fixture.

| Sessions | Base / head resident bytes | Base / head physical footprint | Head SQLite heap current / high water |
| ---: | ---: | ---: | ---: |
| 100 | 3,489,792 / 4,554,752 B | 1,967,040 / 3,032,384 B | 200,960 / 321,392 B |
| 1,000 | 3,817,472 / 5,177,344 B | 2,294,720 / 3,638,592 B | 200,960 / 419,696 B |
| 10,000 | 3,702,784 / 5,898,240 B | 2,802,752 / 4,392,384 B | 200,960 / 419,696 B |

The issue-#49 executable has a larger fixed process footprint than the older base fixture, so this comparison does not claim lower absolute RSS. Within the corrected head run, 9,900 additional Dormant Sessions increased RSS by 1,312 KiB and physical footprint by 1.30 MiB. Every raw head population record states `live_transient_scratch_owners_before_sampling: 0`; no dormant Harness, Session object, directory handle, lock handle, or scratch allocation survives.

## Transient capture

The head executable separately measures the production unlinked spool and SQLite import window. The ordinary sample encodes the 26-byte text `The failing test is fixed.` as a 50-byte canonical text response, so spool occupancy is 50 bytes while the fixed import window is 4,096 resident bytes. The 98,372-byte sample writes raw content sized to `model_protocol.max_response_size`; it measures spool and import-window occupancy only, not canonical-response decoding. The final sample stages three generic 1 MiB contents as facts and measures the declared simultaneous pending/import capacity only, not the shipped Patch Intent or Tool Call semantic closure. The spool and import window are distinct resources; the import path does not retain another complete payload.

| Sample | Response / spool occupancy | Import window | SQLite writes / spills | SQLite heap high water |
| --- | ---: | ---: | ---: | ---: |
| Canonical response with 26-byte text | 50 / 50 B | 4,096 B | 7 / 0 | 318,336 B |
| Raw content at the model-response size bound | 98,372 / 98,372 B | 4,096 B | 55 / 43 | 318,336 B |
| Maximum live-Session spool: three 1 MiB values | 3,145,728 / 3,145,728 B | 4,096 B | 1,543 / 1,531 | 416,640 B |

These are measured occupancies. One content value is bounded at 1 MiB, while the three-slot capacity sample reaches one live Session's measured and theoretical aggregate spool maximum of 3 MiB. A transaction may reference more content that is already durable; only first imports consume this cap. The ordinary model-response path is bounded more tightly by 98,372 bytes. Dormant Sessions own no spool or pending metadata.

The opaque Harness-local scratch allocation is 208 metadata bytes per live Harness: 20,800 bytes (20.312 KiB) at `active_capacity = 100`. This metadata is separate from the unlinked spool's disk-backed payload, which reaches 3,145,728 bytes only for one live Session with three generic maximum contents pending. The spool uses three fixed 1 MiB logical slots and writes only appended content bytes; releasing a committed slot makes that slot immediately reusable without moving the other pending values. Dormant Sessions allocate neither category. This reports the current ownership choice without changing it; any future topology change remains an explicit allocation decision.
