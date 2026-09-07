# Workflow input capture prototype

Throwaway experiment, 7 September 2026, for OnePage #114. Question: can one SQLite capture, one temporary input file, an ordinary QuickJS answer map, keyed request admission and atomic dependency publication serve the scanner/verifier workflow simply? No production implementation or new numeric policy is selected.

## Run

From this worktree: `python3 research/workflow-input-capture/run.py`.

Requires macOS, Clang, Python with tarfile data-filter support, and the repository's pinned QuickJS/SQLite archives already fetched into `~/.cache/zig/p`. The script extracts them into temporary storage, compiles the C harness, runs three sequential repetitions of eight fixture shapes, and writes `results.json`. It deletes scratch databases, files and binaries on exit. No providers or user workspaces are accessed. The script has a 90-second external timeout per fixture; it does not implement production evaluator time policies.

## What ran

- Actual pinned QuickJS-ng 1ab8676f4b6d6d669baeb5f21790fb9734636a20 and SQLite 3.53.4, compiled with Clang `-O2`; archive identifiers and binary hash are in the results. Core SQLite feature macros follow build.zig, with explicit DELETE/EXTRA, 256 KiB suggested cache, file-backed temp storage and mmap disabled. This is a standalone harness, not the production Zig build.
- The real JavaScript fixture uses stable scanner/verifier keys, async functions and nested Promise.all. Scanner results are arrays of findings; each finding has a text string. Verifiers consume its length and return 1. The final result must equal the number of findings.
- Four phases: no answers; only scanner A in captured input; all scanners answered; all verifiers answered. Another scanner finishes just after the second capture. Assertions ensure it stays absent from that view, A alone submits verifiers, the completed-but-unseen dependency remains discoverable, and the following evaluation sees all scanner answers.
- Each capture uses one read transaction and streams completed key/result rows into a temporary NDJSON file. The transaction ends before launching the child. The child parses one record at a time into an ordinary Map under the accepted 16 MiB QuickJS allocation ceiling, then executes the fixture and drains jobs.
- Child output records are staged in SQLite temporary storage and checked before canonical admission. Each encountered call uses its own equal-key/changed-input transaction. One final transaction replaces the complete pending set and writes final output, if any. Replayed calls must not increase the binding count.
- 90 evaluations: 84 succeeded with the expected pending sets/final value; six explicitly failed with QuickJS out-of-memory (two fixture shapes, three repetitions each). Failed evaluations exited normally with code 20, published no requests/dependency changes, and were not mistaken for signals or successful partial results.

## Observations

Medians of three sequential warm repetitions. Phase shown: all scanners answered, with their verifiers still pending. Admission includes equal-key checks and separately committed new verifier requests. Evaluation time includes fork/exec, file loading, JavaScript, output writing, memory reporting and teardown. Times are milliseconds.

| Scanners | Findings each | Bytes each | Captured MiB | Capture | Evaluate | Admit | Publish | Outcome |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 2 | 2 | 64 | 0.00 | 0.09 | 10.05 | 0.78 | 0.37 | passed |
| 16 | 2 | 4096 | 0.13 | 0.34 | 7.64 | 10.63 | 0.45 | passed |
| 128 | 2 | 4096 | 1.01 | 1.90 | 9.36 | 84.82 | 0.96 | passed |
| 512 | 2 | 4096 | 4.03 | 7.13 | 24.48 | 330.93 | 2.58 | passed |
| 1024 | 2 | 4096 | 8.05 | 13.35 | 37.93 | 663.25 | 4.56 | passed |
| 2048 | 2 | 4096 | 16.10 | 26.57 | 33.10 | 0.00 | 0.00 | heap exhausted; no publication |
| 128 | 2 | 32768 | 8.01 | 4.66 | 22.15 | 0.00 | 0.00 | heap exhausted; no publication |
| 16 | 128 | 64 | 0.15 | 0.40 | 17.20 | 632.69 | 4.02 | passed |

Output validation is separate from the table's admission/publication columns: about 20.7 ms for the 1,024-scanner case. Total phase time must include it. Full per-phase timing and native OS peak-RSS observations are in results.json.

The 1,024-scanner case captured 8.05 MiB, evaluated in 37.9 ms, and admitted 2,046 new verifiers plus rechecked existing calls in 663.2 ms. Its final dependency publication took 4.6 ms. The largest individual admission transaction observed anywhere in the sweep was 7.484 ms. These show a natural point for Host service between admissions; this synchronous harness does not execute a Host service loop or prove control responsiveness. Do not hold one transaction around the whole admission sequence merely to reduce commit count without addressing its recovery and service tradeoffs.

The 128-scanner case with two 32 KiB findings per result exhausted the heap during input loading, despite only about 8 MiB serialized input. At failure it had loaded 126 scanner records: QuickJS reported 8,408,802 bytes of live-accounted memory and 16,683,256 allocated bytes. The smaller-string 8 MiB fixture succeeded. Total serialized size is therefore not a reliable heap-admission rule; this experiment does not identify the exact allocator/parser contribution or propose another byte cap.

In the successful 1,024-scanner capture/evaluation phase, median child peak RSS was about 17.1 MiB and parent lifetime peak RSS about 3.8 MiB. The child can exceed the 16 MiB engine allocation limit in total RSS because native code/runtime memory is additional. Parent and child lifetime peaks are separate observations, not a simultaneous sum or whole-Host footprint. Parent peaks include fixture setup and increase over the four phases. No sampled macOS physical-footprint measurement was made.

## Verdict and limits

The straightforward path executes independent scanner/verifier progress and stable-key replay without reconstructing an older snapshot. There is no evidence here that an indexed/lazy answer store is needed for the smaller fixtures. It is not yet proof that the Map fits the full intended workload: a moderately sized serialized input can exhaust the chosen engine heap depending on value shape.

The largest measured cost is the number of separately committed new requests, not snapshot capture. Preserve the existing opportunity for Host service between those commits; next integration evidence should exercise actual controls and settlement while a large admission sequence is in progress. Fair workflow selection remains a separate question.

Important omissions:

- Synthetic scanner/verifier text shapes, three sequential repetitions, warm shared laptop storage. No percentile guarantee, cold-cache sweep, competing workload, unrelated historical Run population or whole-Host qualification.
- Capture serializes one complete result row through SQLite JSON functions; child `getline` and JSON parsing hold a complete record. Largest generated answer is about 64 KiB. This is bounded by fixture shape, **not a production fixed-window implementation for arbitrarily large single results**. Source also uses a small fixed prototype buffer. The final JavaScript map deliberately retains all visible answers.
- Temporary files have named paths in a private temporary directory; parent removes them on normal exit and the Python harness cleans the directory. Production unlinked-handle ownership, aggregate scratch charging and kill-safe cleanup are not implemented. There is no snapshot fsync because these inputs are disposable.
- Temporary frame validation only handles this fixture's record types. It is not production strict-data/schema validation, exact Session creation/configuration semantics, generation/cancellation fencing, typed failures or full terminal output import. The separate abstract recovery model remains the evidence for the proposed interruption trace, not this harness.
- No effect executions, power loss, process-kill recovery, stale-child publication injection, partial-admission crash injection, hardening or exhaustively explored interleavings. Native allocations and SQLite heap are not independently capped. Output I/O fault injection and all production cleanup paths remain untested.

Keep the simple map as a candidate; do not claim unlimited workflow size or close #114 from these measurements. No main production code or accepted memory limits changed.
