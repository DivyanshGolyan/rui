# SQLite incremental-import memory diagnosis

> **Historical experiment published 6 September 2026.** See the [publication notes](../PUBLICATION.md) for current contract ownership, preserved evidence, privacy substitutions, and reproduction limits.

## Result

The response-size RSS slope was real SQLite dirty-page memory, caused by the **Apple system SQLite spill threshold**, rather than a response-sized parser buffer, a full-row allocation, or an OS file-cache accounting artifact. The exact pinned SQLite build used by OnePage does not show that slope in this probe.

With `cache_size=-256`, Apple SQLite 3.43.2 reports an effective `cache_spill` threshold of **20,000 pages**, while repository-pinned SQLite 3.53.4 reports **61 pages**. The tested 1/4/16 MiB imports remain below Apple's threshold and retain the transaction's dirty pages. Explicit `cache_spill=ON` resets Apple's threshold to 61 and removes the slope. Conversely, disabling spill on pinned SQLite reproduces the memory growth.

16 MiB payload, INSERT RETURNING, 4 KiB incremental writes:

| Library and spill setting | Effective threshold, pages | SQLite high-water, bytes | Cache after writes, bytes | Spills | Peak RSS, bytes |
|---|---:|---:|---:|---:|---:|
| Apple default | 20,000 | 18,272,240 | 17,857,536 | 0 | 19,988,480 |
| Apple explicit ON | 61 | 613,648 | 397,312 | 8,112 | 2,031,616 |
| Pinned default | 61 | 467,344 | 266,752 | 8,148 | 2,523,136 |
| Pinned explicit OFF | 0 | 19,161,488 | 17,857,536 | 0 | 21,430,272 |

The matching pinned default INSERT RETURNING high-water is **467,344 bytes at all three tested sizes**. Largest single SQLite allocation is 87,360 bytes pinned and 122,400 bytes Apple, not payload-sized. Stage samples locate growth at zeroblob INSERT, before incremental blob opening/writes. Both with and without RETURNING exhibit the same slope or absence of slope, ruling out RETURNING as the cause here.

`SQLITE_CONFIG_MEMSTATUS=1` before initialization enables Apple's otherwise missing memory accounting. OS physical footprint grows alongside SQLite accounting on Apple default, and drops after transaction completion; therefore this is not merely mapped-file RSS or page-cache accounting outside the process.

A requested 4 MiB hard heap limit reads back **0** on Apple and **4,194,304** on pinned SQLite. The runner records the readback so success on Apple cannot be mistaken for success under an enforced bound. Pinned 16 MiB incremental imports complete under that enforced limit. A hard limit is a diagnostic in this disposable database, not a production recommendation.

## Run

```sh
python3 research/matklad-experiments/sqlite-import/run.py
```

Requires macOS (Mach physical-footprint API), C compiler, Python 3.12+, and Zig for locating/fetching the repository-pinned dependency. The runner extracts the cached pinned package, fetching through Zig only if absent. This probe compiles one binary against Apple SQLite and one against the repository-pinned amalgamation using the SQLite compilation macros read from `build.zig`. It creates temporary databases and writes `results.json`; generated binaries stay in ignored `generated/`.

24 independent processes cover library, 1/4/16 MiB sizes, plain/RETURNING INSERT, and selected spill/hard-limit controls. Each transaction inserts zeroblob storage, opens an incremental blob, writes fixed 4 KiB windows, closes and commits. Samples include version, requested and effective PRAGMAs, Mach resident bytes and physical footprint, getrusage peak RSS, SQLite current/high-water allocation, largest allocation, page-cache bytes, and spill count. These are single-process observations per point, not a repeated performance benchmark.

The pattern follows `src/host_store.zig:1470` (zeroblob plus RETURNING and incremental writes) and `src/host_store.zig:1552` (DELETE, EXTRA, mmap disabled). This diagnostic intentionally uses a 256 KiB cache for comparison with the parser experiment. Production permits 32/64/128 KiB and defaults to 64 KiB (`src/host_store.zig:330`, `src/host_store.zig:1814`); the probe is not a whole Host Store measurement and its absolute totals should not be presented as production totals. It omits production indexes/foreign-key workload, concurrent operations, actual response parsing, and fault injection.

## Recommendation

Use the repository-pinned SQLite when evaluating the proposed bounded importer. Record both cache size and **effective spill threshold** in memory evidence; cache size alone is not a hard resident-memory limit. Consider explicitly setting and verifying spill behavior in the eventual importer/configuration contract, but no architecture redesign or current production bug is established: the existing pinned build already has the desired behavior in this probe. Keep the root-cause controls as experimental evidence rather than introducing a new buffering layer.
