# Research evidence

These artifacts answer bounded questions; they are not production implementation or release certification. [ARCHITECTURE.md](../ARCHITECTURE.md) owns current behavior and [VERIFICATION.md](../VERIFICATION.md) owns required proof. Recorded native measurements are Mac-specific. Synthetic SQLite schemas, historical evaluator binaries, model assumptions and experimental limits do not establish current Linux behavior, wire compatibility or whole-Host guarantees.

Run commands below from the repository root, sequentially in a disposable checkout: some runners overwrite adjacent results or generate reports. Native probes generally need macOS, Apple Clang, Python 3, Zig 0.16 and the pinned SQLite package; inspect each runner's dependency handling. Pure Python probes use the standard library unless stated. Keep source, compiler/library metadata, raw results and counterexamples together. New observations must identify their own machine/build rather than silently inheriting recorded provenance.

Historical contract snapshots and longer reports are available at [commit 4ee987e](https://github.com/DivyanshGolyan/onepage/tree/4ee987e6479b8010d052b3fd31a5acca044eb269). Retained provenance JSON refers to that revision's files and hashes, including removed snapshots. This index replaces their narrative, not their measured data.

## Session and workflow behavior

| Artifact and reproduction | What it tests; limits |
| --- | --- |
| [Session API protocol](session-api-prototype/prototype.py): `python3 research/session-api-prototype/prototype.py` | Separate core/workflow SQLite transactions, lost acknowledgements, changed-input conflicts, stable rejection, abrupt exits and submit-then-stop cancellation. Stops are synthetic/immediate. Its earlier creation operation does not verify first-configuration initialization, real effects, permissions, streaming, resource limits or power-loss durability. |
| [Failure mapping](session-failure-mapping/probe.py): `python3 research/session-failure-mapping/probe.py` | Prospective SQLite failure/outcome constraints, pending-message exclusion, same-Turn provenance and rollback. Uses an earlier schema with separate result relations; this does not qualify the Operation-owned production representation. |
| [Call-order counterexample](workflow-call-order/probe.mjs): `node research/workflow-call-order/probe.mjs` | Cached answers change invocation order, disproving a simple global call counter. [Native probe](workflow-call-order/native_probe.py) reproduces the case against `zig-out/bin/onepage-workflow-evaluator`; it supplies answers directly through the historical `agent` protocol. |
| [Result identity](workflow-result-identity/probe.py): `python3 research/workflow-result-identity/probe.py` | Original keyed answers/failures compose through an existing evaluator binary at the same path. No durable Session/core integration or fresh-source correctness follows from a prebuilt binary. |
| [Readiness costs](workflow-readiness/probe.py) and [generation model](workflow-readiness/generation_model.py): run each with `python3` | Compare derived queries with a maintained ready set, and model generation/publication races. Recorded `poll-*.json` are historical observations; no dedicated poll runner is retained. Synthetic dependencies and earlier shared-owner assumptions do not implement the current independent Runtime. |
| [Observation batching](observation-batch-prototype/bench.py): `python3 research/observation-batch-prototype/bench.py` | Same indexed reads locally, over scalar Unix-socket requests, or in a batch. Hot small records, one persistent Python connection, no concurrent writes or large results. Neither an atomic snapshot nor a required batching endpoint is established. |

## Bounded TLA+ models

These models assume atomic durable transitions. Their finite states and checker-only histories are not proposed tables or proofs for arbitrary workloads. Correct configurations must pass; deliberately broken configurations must produce the expected counterexample. Witness configurations intentionally violate a “never reaches this state” assertion to prove reachability.

- [Session replay](session-replay-model/SessionReplay.tla): one Session, two messages, up to one/two crashes. Negative controls cover duplicate admission, retargeted answers and stranded messages. It includes a keyless external caller and explicit resume, which are historical assumptions.
- [Terminal outcomes](session-terminal-model/SessionTerminal.tla): one Session, two Turns, three messages, one crash and bounded request preparation. Tests excluded-message carry-forward, truthful projection and late-result authority. Its modeled cleanup-before-release ordering and early failure fence do not select current storage or cleanup ownership.
- Run either checker with `python3 research/<model-directory>/check.py --jar /path/to/tla2tools.jar --output /tmp/<unique-results>`. They verify the pinned v1.7.4 jar hash and expected positive, negative and witness results. Progress assumes finite crashes/messages, eventual explicit restart/resume, fair enabled actions and eventual provider return; safety has no such progress guarantee.
- [Request protocol](request-protocol-model/RequestProtocol.tla): two fixed keys and one crash, independent intents/answers and cancellation. `broken-cancellation.cfg` detects premature completion; `broken-replay.cfg` detects uncertain-tool replay. Input binding/atomic admission are assumptions; shared-Session interference and real cleanup are absent. Progress requires weak fairness of send/process/record/stop/commit and eventual availability. From its directory run `java -cp /path/to/tla2tools.jar tlc2.TLC -workers 1 -metadir /tmp/unique-model-state -config correct.cfg RequestProtocol.tla`; repeat with each configuration and a distinct directory. Correct/progress runs exit 0; negative controls exit 12. [tools.sha256](request-protocol-model/tools.sha256) identifies the recorded checker.

## Resources and inspection

| Artifact and reproduction | What it tests; limits |
| --- | --- |
| [Execution control](execution-control-experiments/run_all.py): `python3 research/execution-control-experiments/run_all.py` | Fixed-table scans, event waits, real SQLite/custody handoffs, sanitizer negative controls and inspection/stop contention. Historical schema and synthetic commands exclude full provider/tool settlement. |
| [Idle loop](idle-loop-prototype/bench.c) | Continuous scan, zero-timeout poll and blocking wait, with child-generated events. Build `clang -O2 -Wall -Wextra research/idle-loop-prototype/bench.c -o /tmp/onepage-idle`; run `/tmp/onepage-idle 64 wait idle` (modes: `scan`, `busy`, `wait`; scenarios: `idle`, `events`). Short shared-machine samples exclude child CPU and do not measure production scheduling. |
| [HTTP memory](http-memory-probe/run.py): `python3 research/http-memory-probe/run.py` | Native nonblocking loopback TCP and Zig header-parser memory. Experimental connection/windows differ from accepted budgets; no complete HTTP server, SQLite or workflow integration. |
| [Inspection capture](inspection-capture-proof/measure_single_connection.py): run with `python3`; [alternative probe](inspection-capture-proof/probe.py) | Native single-connection capture plus an earlier ownership comparison. [Query-cost runner](run-inspection-query-cost/run.py) tests history/current-fact index sensitivity. These synthetic Run memberships and globally consistent captures predate independent core/workflow observation. They expose query/encoding costs, not current API completeness or control latency. |
| [Continuous streams](host-runtime/reactor-capacity-100/run_matrix.sh) | libcurl TLS/SSE-to-spool load; no semantic parser. Run from its directory with `CERT_FILE`/`KEY_FILE` pointing to a temporary localhost certificate. Profiles are selected by `MATRIX_PROFILE`. System-curl results do not qualify the selected bundled transport. |
| [Integrated capacity](host-runtime/integrated-capacity-proof/run_smoke_matrix.sh) | Mixed model/Bash capture, shared import, cleanup and storage faults. Run from its directory; other adjacent `run_*.sh` cover rotation, churn, cache and retained footprint. The optional serial Patch lane, old result schema and preliminary file checks are superseded. `run_disk_full.sh` mounts a disposable disk image. No current whole-Host recovery proof follows. |

## Parser and storage experiments

Under `matklad-experiments/`, retain the adjacent raw JSON and provenance for:

- [Parser](matklad-experiments/parser/run.py): `python3 research/matklad-experiments/parser/run.py --smoke --skip-transcripts --output /tmp/parser-results.json`. Narrow streaming validation versus DOM and failed-import rollback; not complete provider grammar.
- [SQLite import](matklad-experiments/sqlite-import/run.py): library, spill and heap controls. Run with `python3`; results distinguish pinned SQLite from Apple system SQLite.
- [Workspace lifetimes](matklad-experiments/workspaces/run.py): allocation overlap and stale-borrow controls. Transcript profiles retain hashes/neutral labels, not private payloads. Public reproduction cannot reconstruct private samples; `profile_transcripts.py` is a machine-specific collector, not an anonymizer.
- [Manifest representations](matklad-experiments/manifests/experiment.py): use `--semantics-only --output /tmp/manifest-results.json`. Explicit references versus ranges, replay and corruption controls. WAL/FULL frame counts do not measure OnePage's DELETE/EXTRA writes.
- [Recovery scenarios](matklad-experiments/scenarios/run.py): builds historical production fixtures. Three selected faults exit abruptly; others unwind. Old Patch reconciliation and ledger assertions are not current requirements.
- [Inspection latency](matklad-experiments/inspection-latency/run.py): encoding, ready-settlement service and unselected cooperative-abort variants. Experimental timeouts are not product limits.

The relocated [measurement files](measurements/) preserve the August runtime sweep and single-Store JSON/JSONL without changing their baseline or claims.

## Opt-in provider timing

[Stream inactivity](stream-inactivity/probe.py) makes a real Codex request only with explicit `--live`. It reads local sign-in credentials; never include it in default reproduction. Example: `python3 research/stream-inactivity/probe.py --live --model gpt-6-astra --case reasoning --output /tmp/new-timing.jsonl`. It records arrival timing without payloads, tools, retries or refresh. Python HTTP/1.1 buffering and a few samples cannot establish provider silence bounds or qualify OnePage's libcurl callbacks.
