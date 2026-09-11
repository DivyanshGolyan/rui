# SQLite content memory experiment

The pinned SQLite representation admitted, imported and exactly reread 64 MiB of file-backed content with **523,248 bytes of peak SQLite heap and 8,192 bytes of explicit application buffers**. It did not allocate a complete serialized value. This is a native representation prototype, not implementation or qualification of the redesigned OnePage runtime. SQLite's overflow-page index still grows with value size, so this is not evidence of constant memory or arbitrary-size support.

## Reproduce and evidence

From the repository root on macOS:

```sh
python3 research/sqlite-memory/run.py
python3 research/sqlite-memory/production.py
```

Both runners hold `/tmp/onepage-memory-experiments.lock` through their heavy work, share the sibling tasks' advisory lock, use bounded cases and delete disposable database/source directories. Compilation and dependency preparation can precede the lock. The native runner compiles the repository-pinned amalgamation with Apple Clang, using build.zig's macros, then uses `THREADSAFE=1` for the selected-contract cases and `0` for two compatibility controls. It does not use Apple's system SQLite. Generated dependencies/binaries stay in ignored `generated/`; no provider, credential or root-checkout writes are involved.

- [Raw native results](results.json): 22 fresh-process cases; all expected-outcome, hard-bound and cleanup assertions passed. Exit 77 is intentional only in the crash case; its fresh recovery process passed.
- [Provenance](provenance.json): revision `b1d25138f70e6a7b4c1d27523d5b051f6de34d7a`, file hashes, exact macros/schema, dependency hash, compiler, machine, filesystem and system VM counters. Recorded on macOS 15.7.7 ARM64, MacBookPro18,1, 16 GiB RAM; SQLite 3.53.4; Zig 0.16.0; Apple Clang 17.0.0.
- [Production results](production-results.json): unmodified `zig build host-store-density`, exit 0. The command compiles and executes the existing production Store fixture.
- [Primary documentation and pinned source](sources.md) explain API limits and overflow-page ownership.
- [Native probe](probe.c), [runner](run.py) and [production runner](production.py) are the runnable artifacts. Research-only changes passed `git diff --check`; no architecture or production source was changed. The broader `zig build check`/workflow/live-provider gates were not run for this research-only change.

## What actually exists

`src/host_store.zig` owns a rowid `content` table with fixed identity/digest columns and a BLOB payload (lines 61–72). `insertContent` (1433) uses `zeroblob`, scalar `RETURNING content_id`, 4 KiB file reads, incremental BLOB writes and a streaming digest. `readContentWindow` (1277) fetches only metadata, then opens/reads/closes a BLOB into the caller's buffer. It does not select the content payload as a whole. Fixed-size transition payloads are separately materialized and capped at 1,012 bytes; they are not large canonical content.

Production still rejects content above 1 MiB; its schema and SQLite row-length limit enforce that earlier boundary. Duplicate content handling compares length/digest and rejects an existing reference; it is not the redesigned exact request-key comparison. The current build also has `SQLITE_THREADSAFE=0`, a database page quota, and a 64 KiB default cache. These are implementation facts, not the accepted redesign. This experiment removes none of those production guards.

The prototype extracts the actual content schema, changing only its 1 MiB CHECK for large cases. Its reduced parent table and `accepted` relation model atomic content plus first reference, not the full Session/Turn schema. A pre-existing committed witness must survive every failure. A real source file is generated incrementally, hashed through a bounded window, then imported and compared byte-for-byte. The SHA-256 probe domain is local to this harness, not OnePage's persisted binding encoding. Every content byte participates; a last-byte source mutation must conflict. Restoring that byte must restore equality. No preloaded whole-value buffer or item collection is used.

## Allocation and item-count results

All figures are bytes. These normal cases use the thread-safe build, spill enabled, one serial connection owner, a 262,144-byte cache target and a 4,194,304-byte hard heap limit. `SQLite peak` includes SQLite page cache, statement and BLOB-cursor allocations; do not add cache bytes to it.

| Bytes/value | Rows in one transaction | SQLite peak, no RETURNING | SQLite peak, scalar RETURNING | SQLite retained idle, no RETURNING |
| ---: | ---: | ---: | ---: | ---: |
| 4,096 | 1 | 188,496 | 299,616 | 183,792 |
| 1,048,576 | 1 | 363,504 | 474,720 | 358,896 |
| 16,777,216 | 1 | 424,944 | 474,720 | 358,896 |
| 67,108,864 | 1 | 523,248 | 523,312 | 358,896 |
| 4,096 | 100 | 363,504 | not run | 358,896 |
| 4,096 | 1,000 | 376,816 | not run | 358,896 |

Explicit application buffers stay at 8,192 bytes throughout all cases; stack hash/metadata state and libc/measurement allocations are additional. Larger row count increases disk and transaction work without a resident row list. The two `THREADSAFE=0` controls differ by only 160 bytes of SQLite peak from matching thread-safe cases; dropping thread safety is not an optimization proposal.

Scalar RETURNING did **not** create a payload-sized allocation in this pinned build. Omitting it saved 111,216 bytes of peak at 1 MiB, but only 64 bytes of overall peak at 64 MiB, where another phase dominates. An initial exploratory assertion expecting large RETURNING failure was disproved; the final sweep verifies successful complete imports instead. It would be wrong to carry the earlier hypothesis into a production finding.

The largest successful allocation request in the 64 MiB case was 131,200 bytes. Pinned `accessPayload` allocates an overflow-page index at approximately `8 × ceil(payload_bytes / 4092)` bytes per cursor. This is about 0.2% of payload size, released at cursor close, rather than a complete payload copy. A live cursor therefore has a value-dependent library cost. The finite global SQLite heap contains it; these measurements do not establish behavior above the tested sizes or remove SQLite's row/API limits.

## Failure and recovery evidence

| Control | Observed result |
| --- | --- |
| Request a 4 MiB SQLite allocation while the connection is live | Allocation rejected; subsequent 16 MiB incremental import succeeds. The hard limit is actively enforced. |
| Disable dirty-page spill, import 16 MiB | `SQLITE_NOMEM` (7); peak 4,194,288 bytes, below the 4,194,304-byte limit; no content/reference survives. |
| Diagnostic `max_page_count=64`, import 16 MiB | `SQLITE_FULL` (13) during insertion; no content/reference survives. This injects bounded storage exhaustion, not a proposed production quota and not real volume ENOSPC. |
| Third 16 MiB item's source is one byte short | Explicit probe error 1001; all three items/references roll back, including the first two completed imports. |
| Third item's expected digest is wrong | Explicit probe error 1002 after streaming; all items/references roll back. |
| `_exit(77)` after a complete 16 MiB import but before commit | Fresh process recovers the real rollback journal; no uncommitted content/reference, committed witness intact. Process-crash evidence only. |
| Whole `SELECT payload` after successful 16 MiB incremental import | `SQLITE_NOMEM`; largest attempted allocation 16,777,228 bytes. Incremental reread had already succeeded under the same limit. |
| Whole `SELECT payload` for 1 MiB | Succeeds, but SQLite peak rises to 1,442,288 bytes versus 363,504 with incremental access. |

On returned failures the probe closes the BLOB/finalizes statements, rolls back only if the transaction remains active, verifies autocommit and absence of both relations, then reopens and verifies again. A committed witness survives. No successful prefix or partial publication is returned. This does not qualify production Host fencing, injected VFS write/commit/rollback errors, real disk-full behavior, corruption or power loss.

## Retention, spill and physical costs

For the 64 MiB, no-RETURNING case:

| Stage | SQLite live | Explicit buffers | Physical footprint | RSS |
| --- | ---: | ---: | ---: | ---: |
| Cold process | 0 | 0 | 819,776 | 1,146,880 |
| Importing | 523,248 | 8,192 | 1,622,784 | 2,768,896 |
| Retained idle after comparison | 358,896 | 8,192 | 1,885,056 | 2,998,272 |
| Explicit cache release | 85,488 | 8,192 | 1,901,440 | 3,014,656 |
| Connection closed | 0 | 8,192 | 1,901,440 | 3,014,656 |
| Reopen verification and final cleanup | 0 | 0 | 2,065,280 | 3,178,496 |

SQLite's continuous high-water is distinct from stage-sampled physical footprint. Brief footprint peaks between samples can be missed. `malloc_in_use`/`malloc_reserved` are allocator statistics, overlap SQLite/libc, and are not additional physical memory. For this retained-idle sample they were 894,064 and 47,185,920 bytes; after cleanup 501,312 and 47,185,920. Neither SQLite frees nor `sqlite3_db_release_memory` made process footprint fall immediately. Retained idle here is the immediate post-burst boundary, not a long idle/churn qualification.

The live cache settled at 266,752 bytes, dropping to 5,632 after release. Statement bytes returned to zero between phases. File descriptors were 3 cold, 5 with source/database open, 6 with the journal, and 3 after final cleanup. BLOB/statement handles are separately closed and do not each imply an OS descriptor.

The 64 MiB transaction spilled 32,750 dirty pages. Before commit its database was 67,203,072 logical/allocated bytes and journal 17,936 logical bytes, alongside the 67,108,864-byte source. Zeroblob allocation and subsequent content writes both do work; staging was not removed to reduce copies. The pinned default spill setting and explicit low threshold behaved alike in the 16 MiB control (8,150 spills); spill-off failed. mmap read back as zero, synchronous as EXTRA (3), fullfsync as 1 and temp_store as FILE (1). No sorting/temp-workload spill was exercised.

System `vm_stat` before/after is saved for context only: other applications were active, and macOS file cache/kernel metadata cannot be attributed to this probe from those counters. Native-probe per-process disk I/O, per-file cache residency and kernel handle bytes are unavailable here, not zero. Filesystem block sizes are recorded separately from logical bytes. The production fixture does report process disk counters, which are not identical to durable file growth.

## Production-path measurement and smallest improvement

The existing fixture created 100 / 1,000 / 10,000 dormant Sessions through production interfaces. SQLite live remained **200,960 bytes** at each population; high-water was **321,392 / 419,696 / 433,008 bytes**. Physical footprint was **3,048,640 / 3,622,080 / 4,752,704 bytes**. At 10,000 Sessions the database was 5,402,624 logical bytes and 6,303,744 allocated bytes, while reported process disk writes were 2,334,601,216 bytes. Those are separate costs, not a memory sum. Its response fixture exercised up to 98,372 response bytes; the 3 × 1 MiB scratch fixture does not prove large canonical imports. The earlier runtime's fixture is not a complete redesigned Host workload.

The smallest optional code change supported here is replacing scalar RETURNING with immediate `sqlite3_last_insert_rowid` after a successful insert under the existing exclusive connection owner, with no intervening insert, triggers or virtual tables. It saves about 109 KiB of transient peak for a small import, shared once rather than multiplied by Active Capacity, and preserves the transaction and content bytes. Its benefit disappears at the largest measured peak; it is not urgent or a reason to redesign storage. No production change was made.

Keep bounded BLOB access and the hard heap limit. A targeted idle cache release can free 273,408 SQLite-accounted bytes, but these samples do not demonstrate a physical-memory benefit, so do not add a pool, registry or automatic cache policy on that evidence. Most importantly, do not replace incremental access with a whole-column fetch followed by slicing.

Linux was not executed or cross-compiled. SQLite APIs and overflow-index source are portable evidence; the current probe's CommonCrypto, Mach and libproc instrumentation is Mac-specific. Linux needs native hashing/metrics and actual filesystem/VFS/error tests before claiming equivalent allocation, RSS/private-dirty/cache or crash behavior. No <=256 MiB whole-Host or minimality claim follows from this experiment.
