# Execution-control experiments

> **Historical evidence published 6 September 2026.** The observations and recommendations below retain their investigation context. Subsequent accepted decisions and retired implementation tickets do not change the measured results; this publication makes no production-certification claim.

Throwaway evidence from 5 September 2026. These probes answer narrow design questions; they are not production code or release certification. No paid LLM calls or application Stores were used. The work is isolated on `codex/execution-control-experiments`, based on repository commit `3bdadc8` and the subsequent accepted [Session/cancellation design](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667). The baseline still implements the older runtime; these probes must not become a second implementation.

## Results and recommended decisions

| Question | Evidence | Recommendation |
| --- | --- | --- |
| Does a small custody table need an index? | At capacity 100: 0.053 microseconds per state sweep, 1.633 per dispatch sweep, and 15.491 for the exploratory full completion/reuse burst. | Keep the simple fixed table at these tested capacities. No indexed competitor is justified yet. Capacity 1,000 exposed quadratic repeated lookup/reuse and remains a sensitivity experiment. |
| Is an empty-table scan the whole idle cost? | At capacity 100, measured synthetic process CPU was 0.0189% of one core with one external wake and 0.2440% with 5 ms timed waits. | Sleep until an event when no deadline or durable polling obligation requires a wake. Do not choose the retry poll cadence from scan arithmetic. |
| Must physical slots be durable database rows? | 100 safe protocol runs passed; all 80 deliberately unsafe variants were caught. Half ran under ASan/UBSan. Real SQLite DELETE/EXTRA commits/reopen, child pipes, and controlled owner exits were exercised. | Keep physical custody in memory and recoverable Attempt/Resolution facts in SQLite. The tested handoffs do not require a second durable slot table. This is not a performance comparison against SQLite slots or an exhaustive proof. |
| Does bounded-memory inspection preserve prompt stopping? | At capacity 100, four ordinary 100,000-record reports delayed acknowledgement by 227.2 ms median; handling the stop after the current report reduced it to 52.2 ms. One wide report still imposed about 347 ms. | Let ready controls run before starting another queued capture. The acceptable pause from one complete capture still needs the existing resource decision; no new storage architecture or record quota is selected. |

These are recommendations from the experiments, not silently accepted product-policy changes. The measurements support keeping the small memory table and avoiding extra indexes, while concentrating further work on Storage Owner responsiveness. There is no benchmark evidence here that SQLite itself is too slow to mediate admission; durable admission already uses SQLite.

## Detailed evidence

- [Slot scans, bursts, and limitations](SLOT_RESULTS.md), [raw timings](slot-results.json).
- [Measured idle wakes](IDLE_RESULTS.md), [raw timings](idle-results.json).
- [SQLite/custody handoff and negative controls](CUSTODY_RESULTS.md), [raw results](custody-results.json).
- [Inspection/stop contention](INSPECTION_RESULTS.md), [normal matrix](inspection-results.json), [sanitized checks](inspection-sanitizer-results.json).

No source file in `src/`, production schema, or accepted resource limit was changed. Existing implementation and resource owners remain [Build the bounded foreground advancement engine](https://github.com/DivyanshGolyan/onepage/issues/34), [Set Host Runtime admission controls and budgets](https://github.com/DivyanshGolyan/onepage/issues/68), and [Choose SQLite storage and command-work limits](https://github.com/DivyanshGolyan/onepage/issues/95).

## Reproduce

Requirements: macOS, clang, Python 3, Zig, and the repository's pinned SQLite package already present in Zig's cache. No dependencies are downloaded. Each runner compiles temporary executables and cleans up fixture resources. Run sequentially to avoid experiment-induced timing interference:

```sh
python3 research/execution-control-experiments/run_all.py
```

The runner rewrites result files with the new machine's observations; the accompanying prose records this run and should be refreshed when interpreting a new run. Individual commands appear in the detailed reports. Required production Zig checks were not run because production source did not change; the evidence is native probe execution, sanitizer controls, artifact syntax, references, and whitespace checks.

## Prior art

[Matklad's static allocation and constant work](https://matklad.github.io/2026/09/02/static-allocation-constant-work.html) motivated the fixed-table scan and saturation questions. [His cancellation terminology](https://matklad.github.io/2026/08/31/cancelation-terminology.html) motivated keeping resource ownership through asynchronous cleanup. [Shopify's inventory-reservation account](https://shopify.engineering/scaling-inventory-reservations) motivated checking whether reservation belongs with durable authority and measuring contention across the complete shared database path. These articles informed the questions; the OnePage conclusions are scoped to the local evidence above.
