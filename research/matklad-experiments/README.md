# OnePage: matklad architecture experiments

> **Historical experiment published 6 September 2026.** See the [publication notes](PUBLICATION.md) for current contract ownership, preserved evidence, privacy substitutions, and reproduction limits.

The experiments support the proposed architecture. The best next step for memory efficiency and simplicity is to implement its bounded post-seal parser/import path, retain explicit replay references and existing recovery fixtures, and avoid adding workspace infrastructure before real layouts justify it. One concrete verification improvement emerged: record the effective SQLite spill threshold alongside cache and heap settings.

These are experiments and recommendations, not accepted contract amendments or release certification. No production source or original-checkout documents were edited. All work lives on `codex/matklad-architecture-experiments` in the adjacent isolated worktree. The [provenance](contract-provenance.json) records the source commit and hashes of the working-copy documents used; [contracts](contracts) preserves that proposed design during concurrent edits.

## Design assessed

The proposal gives SQLite durable semantic authority, a single Storage Owner, a separate I/O reactor, and a fixed content-free Physical Custody table. Durable Attempt admission precedes dispatch; logical Resolution and eventual physical cleanup have distinct lifetimes. Payloads travel through scratch and fixed windows; serial validation/import publishes content and semantic settlement atomically. Retry eligibility lives in SQLite with bounded polling, and workflow evaluation uses disposable QuickJS instances at durable barriers. Inspection captures one complete read view into scratch, with controls taking turns between captures.

Those choices already apply the most relevant article ideas: bounded populations, reservation before work, explicit ownership and cancellation boundaries, durable retry state, and scenario-oriented verification. The historical source implements an earlier single-Session ledger runtime; the reusable Session/Turn relational design remains proposed. Existing fixture success cannot certify new custody, scheduling or schema behavior. Numeric limits and remaining provider/inspection decisions remain governed by the open design work, not this report.

## Findings and recommendations

| Question | Evidence | Recommendation |
|---|---|---|
| Can large payloads pass through small resident parser state? | At 0.2/3/12 MiB input, counted streaming allocator peak stayed 140 B, declared parser plus read buffer 9,904 B, process peak RSS about 2.7–2.8 MiB. DOM allocation control grew to 45.6 MB. | Implement the already accepted streaming path. This narrow validator proves feasibility, not full provider correctness. |
| Does incremental SQLite import secretly materialize the full value? | Pinned SQLite imported 1/4/16 MiB with a constant 467,344 B SQLite high-water in the RETURNING probe. Apple library's default retained dirty pages; explicit spill removed that slope, while disabling spill on pinned SQLite reproduced it. | Use pinned dependencies in benchmarks and record effective spill behavior. No new buffering layer is justified. |
| Should validation and inspection share memory? | With two synthetic 8 MiB stages, separate retained footprint was 16.063 MiB; shared was 8.063 MiB. Lazy separate allocation converged after both stages ran. | Share only substantial mutually exclusive storage. Prefer lexical ownership or a small union; actual parser state here is small, so no generic workspace manager. |
| Should request manifests use a range rather than explicit references? | At 256 requests without compaction, database size fell from 2,486,272 to 212,992 B. With compaction every 16 requests, the difference fell to 159,744 B. Range reconstruction required more validation queries and stronger ordering assumptions. No RSS saving was measured. | Keep explicit references for V1. Revisit only if measured metadata cost dominates and the canonical ordering contract suffices without another authority/log. |
| Is a new recovery scenario framework useful? | Eight scenarios passed through existing production fixtures; two negative controls rejected duplicate effects and an incorrect publication oracle. Existing shell integration tests already provide similar orchestration more simply. | Preserve/adapt those behavior checks during the rewrite; add fault hooks only where concrete boundaries lack coverage. |

The parser result is not a 140-byte Host or an allocation-free implementation: the number covers requested dynamic Scanner allocation only. SQLite, fixed arrays, stack, libraries, I/O state and resident pages are separately accounted or explicitly excluded. Input bytes and item count still increase scratch use and processing time. No latency bound for nonpreemptive inspection or maximum active workload was established.

The manifest experiment uses WAL/FULL to observe page-write frames, whereas OnePage uses DELETE/EXTRA. Its write counts are a fixture comparison, not production I/O estimates or a recommendation to change journal mode.

## Real workload evidence

A bounded read-only scan covered 20 recent local Codex sessions, 51.1 MB of JSONL. Custom tool output text had median 4,617 B, p95 40,153 B and maximum 66,580 B; assistant text had median 374 B and maximum 6,488 B. Five selected payloads exercised the parser and DOM control. No transcript contents are stored in this worktree: reports contain metadata and hashes; extracted text was confined to private temporary fixtures.

This is recent coding activity, including experiment/fork history, rather than an unbiased production distribution. Semantic transcripts are not raw provider streams, and nontext content is not represented by those text sizes. Large tool-output values do not imply equally large resident windows. Claude transcripts were unnecessary for these experiments.

## Evidence and reproduction

- [Parser](parser/README.md): 23 checks, 47 measurements; malformed late input and failed-import rollback; pinned SQLite; actual historical Capture eligibility measured separately.
- [SQLite import diagnosis](sqlite-import/README.md): 24 native processes, library/spill/heap controls, per-stage accounting and build provenance.
- [Workspace lifetimes](workspaces/README.md): 63 native processes, stale-borrow negative control, three ASan/UBSan smoke cases, transcript profile.
- [Manifest representations](manifests/README.md): eight paired sizes/compaction configurations, fresh-process replay and adversarial integrity cases.
- [Recovery scenarios](scenarios/README.md): real historical fixture execution; three abrupt exits, remaining injected failures unwind cleanly. No power-loss or new-runtime crash guarantee.

Run each documented command sequentially to avoid benchmark contention. Raw JSON, source and runners accompany every experiment. macOS is required for native Mach accounting; Zig 0.16 and the pinned SQLite package are used where applicable. Times are exploratory on a shared workstation. No live provider checks, commits, pushes or publication were performed.

## Articles read and their relevance

These ten posts were read during the architecture review; the recommendations above are OnePage-specific inferences tested where possible, not prescriptions attributed to the author.

| Post | Connection to this review |
|---|---|
| [Static Allocation, Constant Work](https://matklad.github.io/2026/09/02/static-allocation-constant-work.html) | Fixed custody population and bounded scans; tested the memory cost of retained stage storage. |
| [Cancelation Terminology](https://matklad.github.io/2026/08/31/cancelation-terminology.html) | Keep logical interruption distinct from physical cleanup and released custody. |
| [Reserve First](https://matklad.github.io/2025/08/16/reserve-first.html) | Reserve resources before dispatching irreversible external work. |
| [What Is an Invariant?](https://matklad.github.io/2023/10/06/what-is-an-invariant.html) | State the observation boundary for authority, scratch and resource conservation. |
| [How to Test](https://matklad.github.io/2021/05/31/how-to-test.html) | Exercise recovery behavior through real runtime interfaces. |
| [UNIX Structured Concurrency](https://matklad.github.io/2023/10/11/unix-structured-concurrency.html) | Tie subprocess cleanup and external execution to explicit ownership. |
| [Retry Loop Retry](https://matklad.github.io/2025/08/23/retry-loop-retry.html) | Keep retry control visible and avoid independently retained task/timer state. |
| [Push Ifs Up and Fors Down](https://matklad.github.io/2023/11/15/push-ifs-up-and-fors-down.html) | Choose stage policy at its owner and process bounded batches/windows below it. |
| [Zig's Io.Threaded is Neat](https://matklad.github.io/2026/08/06/neat-io-threaded.html) | Evaluate the executor boundary separately from durable authority and memory accounting. |
| [Underusing Snapshot Testing](https://matklad.github.io/2025/04/15/underusing-snapshot-testing.html) | Capture meaningful observable recovery results while avoiding a parallel simulator. |

No architectural rewrite is justified by these results. The remaining consequential work is complete provider validation, maximum-capacity whole-Host measurement, scratch-exhaustion behavior, inspection/control scheduling evidence, and recovery tests against the actual relational implementation.
