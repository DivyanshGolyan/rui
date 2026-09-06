# JavaScript heap sizing probe

6 September 2026. Throwaway experiment based on native workspace commit `399fa3f`. No production changes, provider calls or saved user content. Reproduce with `python3 research/evaluator-heap-sizing/run.py`.

## Recommendation

Use **16 MiB as a starting candidate for the engine-managed heap limit**, pending user acceptance and integrated qualification. It is a ceiling, not an up-front per-workflow allocation or whole-process bound. Native workspace capacity remains a separate unresolved numeric decision. This experiment does not approve evaluator concurrency.

| Fixture | 4 MiB | 8 MiB | 16 MiB | 32 MiB |
| --- | --- | --- | --- | --- |
| Tiny, 64-way fan-out, partial replay, 256 KiB prior-result aggregation | Correct | Correct | Correct | Correct |
| 20,000 small objects | Correct | Correct | Correct | Correct |
| Assemble/join/split 61 rows with 12,000-character text | Correct | Correct | Correct | Correct |
| Assemble/join/split 5,120 rows with 140-character text | Correct | Correct | Correct | Correct |
| Assemble/join/split 20,000 rows with 140-character text | Rejected | Rejected | Correct | Correct |
| Deliberate unbounded allocation | Rejected | Rejected | Rejected | Rejected |

The first two report shapes approximate the byte scale and object counts identified in the saved-workflow audit; they are generated shapes, not ports of saved workflows. The larger case is a synthetic margin probe. All 36 executions exited normally without the supervisor timeout. Thirty-four matched their intended completion/blocked/rejection outcomes; the larger report was rejected under the two smaller limits. The rejection wire code is the historical generic `WorkflowRejected`, not a proven memory-specific diagnostic. Only the heap constant varies across variants; every intended successful shape passes at 16 and 32 MiB.

Each generated report holds source row objects, a joined string and split result strings, then returns four small summary values checked independently by Python. This deliberately isolates JavaScript assembly from the historical output-frame, output-size and entry-count restrictions. It does **not** prove the full large report can be serialized, imported or replayed. Existing visible-input and request-count caps remain. One run per fixture/limit; no timing comparison or statistically qualified physical-memory claim. Raw supervisor RSS/physical samples are retained with input and binary hashes in `results.json`; they are distinct from the configured heap limit and may miss brief physical-footprint peaks.

An initial fixture used `JSON`, which the historical minimal realm does not expose. Those rejected exploratory results were discarded after checking `typeof JSON`; the recorded reproducible sweep uses supported string/array operations. Absence of that API is a compatibility observation, not a memory finding or a newly accepted product restriction.

The runner changes only the historical engine heap limit during builds and restores protocol source in `finally`. ReleaseSafe builds passed. The inherited evaluator includes prototype native-buffer reuse and diagnostic instrumentation; main production source is untouched. No complete production suite or whole-Host certification is claimed.
