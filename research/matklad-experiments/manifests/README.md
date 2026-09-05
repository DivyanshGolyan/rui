# Model-context manifest representation experiment

> **Historical experiment published 6 September 2026.** See the [publication notes](../PUBLICATION.md) for current contract ownership, preserved evidence, privacy substitutions, and reproduction limits.

The range representation saved database references in this experiment, but it did not demonstrate a resident-memory improvement or a simpler implementation. Keep the explicit per-request reference representation as the V1 baseline for now. Consider ranges only after the production schema and provider fixtures establish a stable canonical ordering anchor for every replay-contributing ordinary model Resolution. This is a representation experiment, not a OnePage runtime implementation or release guarantee.

## Question and contract

The frozen contract in [`../contracts/ARCHITECTURE.md`](../contracts/ARCHITECTURE.md) requires exact model request inputs, one optional Compaction Base, a complete ordered suffix of canonical host inputs and accepted model Resolutions, and one canonical copy of provider output. See lines 151–174 and 297–303. Each request currently freezes each ordered source identity; `model_context_items` is an accepted baseline relationship, while exact SQL mapping remains implementation work.

If every request inserts all preceding context references, reference rows grow quadratically between compactions. The candidate keeps each manifest's selected configuration, selected compaction Resolution, exact upper Conversation position, recipe item count and streaming digest. It reconstructs suffix order from existing Conversation rows: host entries are used directly; adjacent assistant/Tool Call projections identify one complete Completion-owned provider round, including its private opaque items. The creating compaction Operation's existing source manifest identifies the lower frontier. There is no new replay log, recursive manifest chain, checkpoint entity, provider request copy, or provider replay copy.

The fixture rejects ordinary accepted output without a semantic projection anchor. Compaction has an explicit selected-base anchor. Failed, interrupted, and unresolved model Operations contribute no continuation. A response consisting only of private output cannot silently disappear: if such a successful ordinary response is valid in the eventual provider contract, this candidate must be rejected or redesigned. This experiment does not justify adding an ordering log to make it work.

## Run

```sh
./research/matklad-experiments/manifests/run.sh
```

Python's standard library and SQLite are sufficient. Temporary SQLite stores are created in an OS temporary directory and removed at the end. Each store uses 4 KiB pages, WAL, `synchronous=FULL`, and disabled autocheckpointing. Stores are checkpointed before recording final database size. The matrix uses 32, 64, 128 and 256 ordinary requests, both without compaction and with compaction every 16 requests. The largest database plus accumulated WAL stayed below 30 MB. No live provider, credentials, production Store, or production source is used.

`raw.json` contains the exact measured outputs, Python/SQLite versions, semantic replay hashes and rejection results. `experiment.py` owns both the fixture schema and algorithms. It is intentionally readable Python rather than a performance model for Zig.

## Results

Single samples on the shared development host; timings are exploratory. Paired rows produced identical exact replay digests.

| 256 ordinary requests | Explicit references | Range | Interpretation |
| --- | ---: | ---: | --- |
| No compaction: database bytes | 2,486,272 | 212,992 | Range avoids 65,536 repeated reference rows |
| No compaction: accumulated WAL frames | 6,313 | 4,195 | Approximately 34% fewer page-write frames |
| No compaction: total admission time | 1,438.5 ms | 1,353.7 ms | Both still walk/hash the complete recipe |
| No compaction: last replay time | 6.54 ms | 7.43 ms | Range pays to recover order and anchors |
| No compaction: last replay SQL statements | 1,790 | 2,045 | Range uses more validation queries |
| Compaction every 16: database bytes | 380,928 | 221,184 | Difference falls to 159,744 bytes |
| Compaction every 16: accumulated WAL frames | 5,188 | 4,361 | Approximately 16% fewer page-write frames |
| Compaction every 16: total admission time | 245.1 ms | 222.6 ms | Difference is too small/noisy for a speed claim |
| Compaction every 16: last replay time | 0.503 ms | 0.537 ms | Both small; no meaningful latency conclusion |
| Compaction every 16: last replay SQL statements | 113 | 129 | Extra range-validation work remains |

Without compaction, explicit reference counts were 1,024 / 4,096 / 16,384 / 65,536. With compaction every 16 they were 593 / 1,203 / 2,423 / 4,863, including the compaction manifests. Range mode inserts no `model_context_items` rows. Compaction every 16 is a fixture setting, not a proposed production limit or provider context policy.

WAL frames are a page-write proxy: `(wal_bytes - 32) / (4096 + 24)`. They are not physical device-write measurements; filesystem caching, WAL sync, journal reuse, write amplification and checkpoint writes are not captured by that number. Admission time includes request construction and its SQLite commit, not network I/O or provider work. Both modes share the canonical integrity checks, digest construction, and frozen configuration. Request construction remains proportional to its suffix even when no reference rows are inserted; ranges do not magically remove repeated validation work.

## Semantic evidence

The deterministic fixture asserts the exact source identities expected before and after a compaction, including:

- host User/System Instruction/Tool Result entries interleaved with accepted provider rounds;
- a provider round containing opaque binary private material before two Tool Calls;
- child effects settling in reverse physical order, while Tool Results enter canonical call order;
- request admission rejecting pending or misordered Tool Results;
- an admitted but unprojected User Message excluded from the recipe;
- failed, interrupted and unresolved model effects excluded from continuation;
- a selected compaction Resolution supplying the replacement base, with no replay of its covered history;
- later configuration, input and provider output leaving old manifest replay hashes unchanged;
- each representation producing identical hashes after opening the database in a separate fresh Python process.

Adversarial mutations reject a host-entry hole, changed content/order, corrupted private bytes, output ordinal holes, unknown consequential output, missing Resolution, missing semantic projection, reordered Tool Call projections, invalid selected compaction, corrupted selected-base bytes, and an unanchored accepted ordinary model response. Range mode additionally rejects a frontier cutting a provider round in half. Explicit mode accepts that isolated frontier-metadata mutation because its complete explicit recipe is unchanged; the test records this difference rather than claiming equivalent metadata authority.

These checks compare the synthetic exact replay stream, including provider-private bytes and a frozen instruction binding. They are not a wire-format equivalence proof for Codex/OpenAI. The schema is a compact relational fixture, not a proposal for actual production SQL names, constraints or Action evidence storage.

## Memory and bounded work

SQLite cursors use `fetchmany(8)`; reconstruction does not retain the complete context or all request references. Each payload read is deliberately tiny in this experiment. It does **not** prove bounded streaming of large BLOBs: `read_content` fetches an entire fixture item, and semantic projection validation uses a list bounded by the fixture's two Tool Calls. Production needs the existing fixed-window BLOB and output/catalog limits. Python allocations, SQLite internal query memory and page cache, process RSS, memory-mapped I/O, long provider outputs, and total Session population were not measured.

The candidate also introduces a canonical integrity check for unanchored accepted ordinary outputs. In this fixture it queries across the stored model population at admission. That is additional work and could require a better schema constraint in production. Do not hide this cost by adding a cached applied flag, new ordering log, or persistent derived frontier; the accepted design forbids unnecessary duplicate authority.

## Verdict and remaining proof

The original quadratic-reference concern is real for a literal per-request-list implementation. It primarily concerns persistent storage and writes, not orchestration memory. Compaction substantially reduces it, while explicit references are easier to inspect and directly bind exact source identities.

The range candidate safely reconstructs the tested fixtures from existing canonical relations, with no new ordered authority. It is not ready to replace the baseline. Production must establish that every accepted ordinary provider response has a complete stable semantic projection anchor; that selected-base lineage and request compatibility are checked across repeated compactions; that causal Tool Result parentage and all meaningful protocol options are frozen correctly; and that bounded BLOB reads preserve the observed semantics. No release-level crash injection or SQLite transaction-boundary fault campaign was run; the fresh-process reopen verifies persisted replay, not all crash windows. Fixture hashes do not replace direct source validation or provider compatibility checks.

If those invariants fit existing canonical constraints naturally, ranges remain a plausible disk optimization. If they require a new replay log, persistent chain, or another derived ordering authority, reject the candidate. The measured database savings alone do not justify making V1 recovery harder.
