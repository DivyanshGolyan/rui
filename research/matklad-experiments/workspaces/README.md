# Serial workspace lifetime probe

> **Historical experiment published 6 September 2026.** See the [publication notes](../PUBLICATION.md) for current contract ownership, preserved evidence, privacy substitutions, and reproduction limits.

Run from any directory:

```sh
python3 /Users/divyanshgolyan/code/personal/onepage-matklad-experiments/research/matklad-experiments/workspaces/run.py
```

Requires macOS, Python 3 and Clang. `--smoke` runs only three small processes. `--sanitize` runs that smoke matrix with ASan/UBSan and writes `sanitized-smoke.json`; all three instrumented cases passed. The runner compiles `probe.c`; `results.json` records every final sample, sequence, configuration, time and platform. `smoke.json` is the preliminary correctness run.

## Question and contract

Should serial validation/import and inspection capture borrow one large memory region, or retain separate stage regions? The reviewed architecture uses one Storage Owner and excludes settlements during inspection capture. See the frozen contracts in `../contracts`, especially ARCHITECTURE.md lines 197 and 263, and ADR-0024 lines 19–25. This probe does not propose changing those semantics.

Stage capacities of 1, 8 and 32 MiB are **synthetic sensitivity inputs**, not proposed limits, actual parser requirements or measured production layouts. Both stages use the same size in each case. For unequal capacities the allocation arithmetic is `max(A,B)` versus `A+B`, provided no bytes from the first stage must survive the second.

## Method

A fresh native process allocates either two separate fixed buffers or one shared buffer. Three modes distinguish eagerly touched separate storage, lazily touched separate storage, and eagerly touched shared storage. Each process executes 24 alternating validation/capture stand-ins; each writes every byte and checks one byte per page against its expected pattern. The probe invalidates the borrowed view when returning to idle but retains the allocation, modeling process-lifetime workspaces and retained-after-churn cost.

Seven repetitions per size/mode produce 63 fresh processes. A fixed-seed shuffled order reduces systematic ordering effects. There are no simultaneously running cases, and the coordinating agent reserved a benchmark slot. The computer remained a shared machine, so timing is exploratory. Maximum intentional allocation is 64 MiB per process.

`task_info(TASK_VM_INFO)` records resident size and `phys_footprint` before allocation, after initial touch, after churn and at retained idle. `getrusage` records maximum RSS. Footprint is the macOS accounting metric, **not a direct private-dirty measurement**; it may include compressed and other accounted memory. `allocated_bytes` is requested buffer capacity, not total virtual address-space reservation or malloc metadata. No explicit virtual reservation claim is made. Raw timing plus processed bytes supports calculating throughput.

The checked borrow example uses both stage and generation. A stale borrow after a mode transition is rejected. The negative control returns to the original stage: a stage-only check incorrectly accepts that old view, while the generation check rejects it. This demonstrates an ABA/lifetime hazard, not a proof that native pointers are automatically safe. The actual writes occur only inside the current stage; no raw pointer escapes to callbacks. Real code must enforce that interface or prove equivalent lexical lifetimes. The probe neither dereferences a stale pointer nor deliberately invokes undefined behavior.

## Observations

Medians; footprint is post-churn minus process baseline. Values in MiB use 1,048,576 bytes.

| Bytes per stage | Separate eager footprint | Separate lazy footprint | Shared footprint | Separate eager cycle time | Shared cycle time |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 MiB | 2.063 MiB | 2.063 MiB | 1.063 MiB | 0.789 ms | 0.774 ms |
| 8 MiB | 16.063 MiB | 16.063 MiB | 8.063 MiB | 6.879 ms | 6.396 ms |
| 32 MiB | 64.063 MiB | 64.063 MiB | 32.047 MiB | 28.773 ms | 27.615 ms |

Lazy separate storage delays touching memory; it does not avoid the retained footprint once both stages run. The shared buffer saves approximately one complete stage capacity, as elementary allocation arithmetic predicts. These tiny timing differences do not establish production throughput improvement. The lazy mode's timed first cycle includes initial page faults, so use the two eagerly touched modes for the closer warmed comparison.

All recorded lifetime and data checks passed; every stage-only negative control exhibited the expected stale acceptance. This is a topology/lifetime experiment, not an implementation or release-certification test.

## Recommendation

Use a single borrowed region **only if production layouts reveal substantial mutually exclusive stage memory**. A small local union or explicit owner borrow can express that lifetime. Keep validation metadata, Decision Snapshots, SQLite import state, or other data separate whenever it is live across a nested stage. Do not add a workspace registry, allocator framework or epoch scheme merely because this synthetic probe uses a checked token to demonstrate the hazard.

If both production windows are only a few KiB, separate lexical scratch arrays may be simpler and the saving negligible. This experiment establishes the cost of retaining two large buffers; it does not establish that OnePage currently does so. Actual parser/encoder workloads, overlapping lifetimes, reentrancy, callbacks, stage-size asymmetry, allocator release behavior and whole-Host baseline remain unmeasured.

## Recent transcript size profile

`transcript-profile.json` adds metadata from a bounded read-only inventory of 20 recent Codex sessions on 5 September 2026: 51,105,088 snapshot bytes, with no malformed/partial JSONL records. `profile_transcripts.py` reproduces the inventory with a 20-session, 100,000,000-byte cap; active session files may grow between invocations. It reads only dated session JSONL, not credentials/configuration. The checked-in report contains source IDs, snapshot/payload hashes, line numbers, counts and sizes, never transcript content.

| Semantic text category | Records | Median | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Assistant message | 434 | 374 B | 3,038 B | 6,488 B |
| Custom tool arguments | 648 | 509 B | 7,116 B | 36,113 B |
| Custom tool output | 647 | 4,617 B | 40,153 B | 66,580 B |
| Function arguments | 143 | 235 B | 1,515 B | 2,324 B |
| Function output | 223 | 115 B | 2,144 B | 21,780 B |

This samples recent coding activity, including active experiment conversations and potentially duplicated inherited fork history. It is not an unbiased independent-session distribution. Percentiles use nearest rank. Sizes count decoded UTF-8 strings, not tokens. Nontext blocks, such as image data, are not counted as text; serialized payload-size metadata is recorded separately. Wrapper event records are counted by type but excluded from text distributions to avoid a second event-stream copy of semantic messages.

These are semantic transcript records, **not raw provider SSE or the eventual provider-continuation schema**. They help choose realistic string/argument/Tool Result fixtures for parsing experiments. They do not tell us how large a streaming parser workspace or capture batch must be: a 66 KiB value could traverse a smaller fixed window, and one provider response can contain multiple records. Consequently the 1–32 MiB workspace sweep remains a synthetic sensitivity study; replacing stage capacities with transcript text lengths would conflate payload size with required resident memory. The modest individual text sizes strengthen the recommendation to measure actual stage layouts before introducing shared-buffer lifetime machinery.
