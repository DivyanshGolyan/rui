# Post-seal streaming parser and import feasibility

> **Historical experiment published 6 September 2026.** See the [publication notes](../PUBLICATION.md) for current contract ownership, preserved evidence, privacy substitutions, and reproduction limits.

The narrow prototype processes larger strings without retaining decoded copies. With the repository-pinned SQLite build, process memory also stays approximately flat over the tested sizes. This supports implementing the already accepted disk-first design; it does not certify a complete provider adapter.

## Results

Five shuffled fresh processes per synthetic size/mode; medians in bytes:

| Encoded input | Streaming requested allocator peak | SQLite allocation peak | Streaming peak RSS | DOM requested allocator peak | DOM peak RSS |
|---:|---:|---:|---:|---:|---:|
| 196,883 | 140 | 308,608 | 2,867,200 | 720,612 | 1,982,464 |
| 3,146,003 | 140 | 358,528 | 2,932,736 | 11,411,172 | 8,863,744 |
| 12,583,187 | 140 | 371,328 | 2,965,504 | 45,620,964 | 30,883,840 |

The streaming parser's declared struct plus read window total 9,904 bytes. This excludes other stack locals, Scanner value, stdio state and import buffer; it is not total workspace or process memory. The counted allocator delegates to Zig's page allocator and counts requested bytes, not page-rounded reservation. Its 140-byte peak covers the Scanner's dynamic allocation. SQLite is accounted separately. RSS includes code, stack, libraries and allocator backing; DOM requested capacity may exceed touched resident pages. Physical footprint is recorded separately and is not direct private dirty memory.

Each synthetic input contains a message text, encrypted reasoning string and unknown-extension string of the selected size, plus a small function call. A 4 MiB string therefore makes an approximately 12 MiB input. The DOM is `std.json.Value` with allocated strings, an allocation positive control rather than a model of current production or an alternative architecture recommendation.

The final run passed 23 correctness checks and 47 measurements, including five payloads selected from local Codex transcripts in both modes and arrays of 10/100/1,000 items. At 1,000 items the counted allocator remains 140 bytes; the raw-range index lives in scratch and costs 16 bytes per item. Growing output/cardinality still consumes disk and processing time.

The separate historical production `Capture` measurement accepts the 1 KiB and 8 KiB text fixtures and rejects 32 KiB and 64 KiB as oversized. Its existing decoded-text capacity is approximately 20 KiB. These are capture eligibility checks (terminal completion, candidate count, malformed/resource flags and candidate failure), not actual CandidateWriter publication. Bounded memory caused by rejection must not be described as successful large-response handling.

## What is implemented

`probe.zig` feeds fixed byte windows into Zig 0.16's `std.json.Scanner`. It validates a deliberately narrow output-item array, records each exact object's byte range into anonymous scratch, and only after the whole document validates imports those bytes with `zeroblob` and 4 KiB incremental BLOB writes in one SQLite transaction. Python independently decodes source ranges and compares every stored ordinal byte-for-byte, including equivalent objects with different escape spellings. No DOM is built in the streaming path.

Checks cover 1/7/127/4,096-byte fragmentation, escaped keys, Unicode, unknown nested fields, duplicate consumed fields, malformed UTF-8/surrogates, truncation, wrong shape, missing fields, trailing bytes, depth overflow, a late invalid item, and import rollback after an initial row. Unknown item variants remain evidence with `supported=false`. A negative control demonstrates that syntactic DOM parsing alone accepts a semantically incomplete object.

The parser is intentionally incomplete: consumed-field recognition is global rather than variant-specific, so a reasoning extension named `text` with a numeric value is rejected, while a message with role `user` is accepted. It does not implement complete provider policy, output schema validation, transport/SSE handling, opaque continuation compatibility, digests or semantic Completion/Resolution rows. Its input is a closed private fixture file, not actual OS-sealed, unlinked provider scratch. The range index is an unlinked `tmpfile`.

## Reproduce

```sh
python3 research/matklad-experiments/parser/run.py
python3 research/matklad-experiments/parser/run.py --smoke
```

Requires macOS, Zig 0.16 and Python 3.12+. The runner fetches/extracts repository-pinned SQLite if needed and reads SQLite macros from `build.zig`. The import uses DELETE/EXTRA, mmap disabled and a 256 KiB cache; production currently defaults to 64 KiB. Generated binaries, databases and fixture contents reside in a private temporary directory. Normal exit and handled failures remove it; abrupt process death can leave files behind. Reports retain only sizes, hashes and source record coordinates. `--skip-transcripts` permits running without the local source transcripts. Saved samples refer to the frozen profile, rather than silently selecting new records on every run.

Local transcript records are semantic messages/tool inputs/tool outputs, not raw provider SSE. Tool outputs are rewrapped as message strings solely to exercise realistic text, escaping and length. No live provider requests were made. Samples include active experiment activity and are not an unbiased workload distribution.

Initial runs used Apple system SQLite and showed input-sized transient RSS growth. The independent [SQLite diagnosis](../sqlite-import/README.md) traced this to its effective spill threshold. Final `results.json` and `smoke.json` use the pinned build. Do not transplant system-library measurements into OnePage guarantees.

## Recommendation

Implement and measure the complete post-seal validator with bounded tokens/ranges and incremental import, preserving the accepted architecture. Add malformed late input and failed-import rollback tests through the real authority boundary. Include effective SQLite spill threshold in memory evidence. Do not add a generic shared-workspace framework based on this probe: its parser state is already small. Whole-Host accounting, maximum active custody, inspection capture, schema validation, disk exhaustion and actual provider fixtures remain required evidence.
