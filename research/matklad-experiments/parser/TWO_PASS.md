# Prototype: replace the item index with a second parse

6 September 2026. Throwaway experiment, not production implementation or complete provider qualification.

## Answer

Both representations work for the existing narrow sealed-array validator. The no-index variant is bounded-memory, but does not demonstrate a memory saving over the already disk-backed index. It reparses inside the import transaction and takes longer. Recommend retaining the existing simple sequential range file for now, charged to shared scratch, rather than changing the accepted architecture for memory savings that did not materialize. This recommendation is not a new accepted user decision.

The index is not required for recovery or canonical authority. It is an implementation tradeoff: 16 logical disk bytes per item avoids reparsing before each item's import. No per-item files or resident list are needed. File runtime overhead is additional to those logical bytes.

## Controlled comparison

One binary, validator, pinned SQLite build, 256 KiB cache, DELETE/EXTRA durability and 4 KiB windows. Both variants use the same item importer and positional reads; this refactors the historical indexed importer too, so the comparison isolates indexing rather than mixing copy implementations.

- Indexed: validate the entire input and write start/length pairs into one anonymous file; import pairs sequentially in one transaction.
- Two-pass: validate without creating the index; rewind, parse again and import one completed item at a time in one transaction. Positional reads copy that item's raw bytes without disturbing the parser's cursor. This adds a complete parsing traversal; raw item copying is still a separate read, so “two-pass” does not mean every byte is read only twice.

Both preserve raw bytes and ordinal order. No whole-item allocation. A late validation failure starts no import; an injected failure after the first imported row rolls back all rows. The source is a private immutable fixture, not a live changing file or production sealing implementation.

## Results

Each full run passed 44 streaming correctness cases (22 per variant) plus one DOM negative control. Checks include fragmentation at 1/7/127/4096 bytes, escaped spellings, malformed Unicode, duplicate fields, late invalid input, depth rejection, unsupported item evidence and rollback. Python independently verifies every successful item's raw bytes and order and checks empty results on failures.

First run: 60 paired streaming measurements, five repetitions each for six fixtures, plus 19 legacy DOM/production controls. No transcripts or live providers were used.

| Input | Items | Index logical bytes | Indexed median import ms | Two-pass median import ms |
| --- | ---: | ---: | ---: | ---: |
| 196,883 bytes | 3 | 48 | 0.845 | 1.235 |
| 3,146,003 bytes | 3 | 48 | 8.427 | 11.906 |
| 12,583,187 bytes | 3 | 48 | 42.572 | 113.403 |
| 901 bytes | 10 | 160 | 0.467 | 0.429 |
| 90,001 bytes | 1,000 | 16,000 | 1.722 | 2.191 |
| 900,001 bytes | 10,000 | 160,000 | 13.553 | 18.145 |

Large-case first-run timing was noisy (indexed range 36.9–443.3 ms), so a separate ten-pair repeat checked it. Median import was **28.641 ms indexed vs 46.442 ms two-pass**; ranges 25.836–43.316 vs 42.447–49.519 ms. Median validation-plus-import was 45.630 vs 63.579 ms. This supports the expected extra parse cost; the first run's 2.7x ratio is not a stable performance claim. Local cached input and real SQLite sync on a shared machine; no absolute latency guarantee.

Requested parser allocator peak was 140 bytes for both, with zero outstanding tracked allocation at exit. This excludes parser/read/copy stack state, stdio buffers, SQLite and process/runtime memory. SQLite peaks were identical per fixture (about 177–363 KiB). Full-run median RSS was roughly 2.6–2.8 MiB, without an input-size or item-count slope comparable to a DOM. The repeated large-case medians were 2,850,816 vs 2,916,352 bytes. These process measurements do not establish exact incremental Host memory or a significant RAM improvement in either direction. Raw physical-footprint observations are retained too.

The import timer wraps BEGIN through completion/rollback and statement cleanup; it is a close transaction-duration proxy, not an instrumented SQLite lock timer. Validation is timed separately. Process elapsed includes startup and database setup. The deferred stderr timing write happens after the measured interval.

## Limits and next decision

The parser still has all limitations of the original README: a narrow JSON output-item array, incomplete variant validation, no complete Responses/SSE/event ordering, schema validation, semantic publication, continuation assembly or production Host integration. The experiment shows representation feasibility and cost here, not that all provider metadata can disappear. Repeated parsing also requires an immutable source and deterministic interpretation, already assumed in the sealed-source design.

No additional metadata-file quota or buffer pool follows. If the sequential index is retained, its bytes join the existing scratch allowance and its file lifetime is the shared serial import. Normative documents remain unchanged by this experiment.

## Reproduce

From this worktree:

```sh
python3 research/matklad-experiments/parser/run.py --skip-transcripts --output research/matklad-experiments/parser/two-pass-results.json
python3 research/matklad-experiments/parser/run.py --skip-transcripts --focus-large --output research/matklad-experiments/parser/two-pass-large-repeat.json
python3 research/matklad-experiments/parser/summarize_two_pass.py
```

Raw inputs are synthetic and created in a temporary directory. Results and summary are adjacent to this report. Existing historical results are preserved. Abrupt termination can leave temporary files; normal completion cleans them.
