# Workflow readiness cost probe

Throwaway experiment, 7 September 2026. Run `python3 research/workflow-readiness/probe.py` from the repository root. Scratch databases are deleted on exit. Captured output is [results.json](results.json); the script is [probe.py](probe.py).

This compares one result commit with the same commit also inserting affected Run IDs into a unique ready relation. It also observes targeted dependency lookup, one derived-readiness query and ready-list selection. It is not production OnePage schema, a complete scheduling model, a crash test or Host qualification.

## Fixture and limits

- Python SQLite 3.53.4 on macOS 15.7.7 arm64; not the repository-pinned native build.
- DELETE journal, EXTRA synchronization, mmap disabled and a 256 KiB suggested cache. No SQLite heap cap or whole-process memory measurement.
- One current dependency per Run, 100,000 unrelated waiting Runs and 100,000 historical completed work rows without current dependents. Target dependents vary independently. The fixture omits generation selection, keyed admission multiplicity, cancellation, terminal Run filtering, large content and production triggers/constraints.
- Each observed transaction updates the result; the ready variant additionally inserts dependent Run IDs before committing. Each observation is reset beforehand, outside measurement. Result counts are checked after every transaction.
- Seven repetitions per variant, sequential mode order, warm filesystem/database state on a shared laptop. Medians are not p95, cold-storage or maximum-latency guarantees. Setup, resets and ready-row deletion are excluded from transaction timing.
- Queries use `LIMIT 1` only for selection. The captured plans show the derived query scanning dependencies, including irrelevant waiting rows. This demonstrates a concrete access-path cost, not that all derived-readiness queries must perform that scan. Targeted first-row selection does not measure draining all dependents.
- Ready insertion can spill database work to disk; the number of inserted rows and owner transaction time still grow with fan-out. No population limit is selected.

## Observations

Milliseconds, medians of seven observations:

| Target dependent Runs | Result commit only | Result + ready rows commit | Targeted first ID | Derived first eligible ID | Ready first ID |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 | 0.3885 | 0.4442 | 0.0058 | 4.5346 | 0.0062 |
| 1 | 0.4514 | 0.4781 | 0.0067 | 4.3257 | 0.0063 |
| 1,000 | 0.4776 | 0.7647 | 0.0064 | 4.5104 | 0.0065 |
| 100,000 | 0.3453 | 18.2045 | 0.0067 | 6.8573 | 0.0069 |

The targeted empty lookup is cheap in this fixture. Maintaining ready rows makes later selection simple, while moving fan-out work into the result transaction. The tested derived query avoids maintaining those rows but searches unrelated waiting dependencies. Better query shapes and the production representation remain to be investigated; these numbers do not select the design by themselves.

The [design comparison](../../docs/design/workflow-readiness-comparison.md) evaluates the required transitions and failure boundaries separately from these timings. No provider calls, external effects, production code or owning contracts were changed.

## Idle poll cost follow-up

The script also records per-query process CPU and permits fixture sizes through `PROBE_WAITERS` and `PROBE_FANOUTS`. Captured no-ready-work probes: [100,000 waiters](poll-100k.json) and [1,000,000 waiters](poll-1m.json). Reproduce with `PROBE_FANOUTS=0 python3 research/workflow-readiness/probe.py` and `PROBE_WAITERS=1000000 PROBE_FANOUTS=0 python3 research/workflow-readiness/probe.py`.

| Waiting dependencies | Median derived-query wall ms | Median process CPU ms | Query-only CPU attribution if run once/second |
| --- | ---: | ---: | ---: |
| 100,000 | 4.1854 | 4.1580 | 0.42% of one core |
| 1,000,000 | 42.9309 | 42.8650 | 4.29% of one core |

The percentages are arithmetic extrapolations from seven consecutive warm queries, not measured idle Host CPU. Both plans scan `dependency` and probe `work` by primary key. All unrelated waiters share one pending work row; each fixture also has the same number of unreferenced historical completed work rows as waiters. No other query shape is compared here, so these results do not prove an unavoidable full-scan cost or select a polling interval. A realistic production model and reference population are required before judging the accepted below-1%-of-one-core idle target.

## Generation visibility model

Run `python3 research/workflow-readiness/generation_model.py` for fresh-evaluation recovery and the publication candidate. The [recorded result](generation-model-results.json) reports the checked scenario families; the [design note](../../docs/design/workflow-generation-publication.md) explains the model and omissions. This is relational fixture evidence with supplied pending sets, not JavaScript execution, an exhaustive state-space search, or production process-crash testing. No runtime implementation changed.
