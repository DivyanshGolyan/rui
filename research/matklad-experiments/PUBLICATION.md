# Publication notes — 6 September 2026

These experiments assessed the working-copy contracts captured on 5 September 2026. The [provenance manifest](contract-provenance.json) records the source commit and hashes of 26 frozen files in `contracts/`. Those files are an intentionally partial historical snapshot: their relative links, statuses, and source line references retain their original context, and some targets were not captured. Their bytes are preserved for hash verification. Current requirements belong to the repository's [architecture](../../ARCHITECTURE.md) and [verification contract](../../VERIFICATION.md), not this snapshot or the experiment recommendations.

The publication preserves all probe sources, runners, measurements, and snapshot bytes. It excludes generated executables, debug-symbol bundles, and caches. In the transcript profile and parser reports, 20 local transcript filenames are consistently replaced with neutral source labels. Counts, sizes, line positions, timings, and all source/payload hashes remain unchanged. The original files and private mapping remain outside this repository. No transcript payloads are published.

## Reproduction

Run from the repository root and write new observations outside the recorded dataset. For the parser's synthetic smoke cases:

```sh
python3 research/matklad-experiments/parser/run.py --smoke --skip-transcripts --output /tmp/onepage-parser-smoke.json
```

For manifest correctness without the size sweep:

```sh
python3 research/matklad-experiments/manifests/experiment.py --semantics-only --output /tmp/onepage-manifest-checks.json
```

Some historical runners write adjacent result files or generated binaries. Use a disposable checkout when reproducing those runs. The workspace README's original absolute invocation identifies its source machine; the portable invocation is `python3 research/matklad-experiments/workspaces/run.py` from the repository root.

The transcript-assisted parser path needs private source files and the original profile; neutral labels cannot locate those files. Use `--skip-transcripts` for public reproduction. `profile_transcripts.py` is the original local collection script with its dated source directory, not a portable benchmark input or a publication-safe anonymizer. It does not run as part of the synthetic checks.

## What the evidence establishes

The narrow parser and SQLite probes support bounded resident processing of larger payloads. They do not implement complete provider validation, output schemas, production settlement, or the new relational runtime. Existing recovery fixtures cover the historical runtime only. Workspace sharing and manifest-range alternatives remain unselected; numeric experimental values are not defaults or product ceilings. Original recommendations and “not published” statements below the publication notices describe the investigation, not the current publication state.

The [inspection-latency follow-up](inspection-latency/README.md) extends the [earlier inspection measurements](../execution-control-experiments/INSPECTION_RESULTS.md) with encoding, settlement scheduling, and cooperative abort comparisons. Its separate `contract.md` is a byte-preserved historical ADR snapshot with original relative links; its provenance records the source hashes. Ready controls and ordinary settlement/advancement receive bounded turns between captures in the accepted follow-up contract. Representative whole-Host cost, single-capture delay, sustained-load fairness, and acceptable incomplete-report failure remain with [the SQLite resource decision](https://github.com/DivyanshGolyan/onepage/issues/95), coordinated with [Host budgets](https://github.com/DivyanshGolyan/onepage/issues/68). Experimental 8 KiB windows, 10 ms abort budgets, and 1 MiB quotas are not product limits. The follow-up runner overwrites adjacent result files; reproduce in a disposable checkout.
