# Request admission and workflow cancellation — TLA+

Checked 2026-09-09 with TLC 2.19 (see log banner), Java 17. This is bounded model checking of a protocol abstraction, not a proof of OnePage implementation correctness.

## Model boundary

Two symbolic workflow calls have independent saved intents, in-transit requests, durable core admission answers, volatile replies and workflow-recorded answers. Core admission atomically assigns accepted/rejected once; duplicate delivery recovers that answer. Work is abstracted as ready, admitted, running, done, stopped or uncertain. A crash drops in-transit requests/replies and recovers admitted/running work as uncertain. Cancellation freezes new intents, resolves unanswered calls, then stops accepted work before completion.

Submission may occur during cancellation, including first delivery. Completion can race with stop. Crashes between commit and reply recording are expressible. `starts` is a ghost counter used only to detect external replay. Lost messages/replies are modeled by a bounded crash rather than an independently lossy network.

Each key represents one fixed input binding and at most one abstract accepted work item. Different-input conflict handling and concrete work-row uniqueness are abstracted into atomic admission, not independently proved here. They are exercised in the adjacent runnable protocol prototype. Core restart/recovery is one abstract action, not a staged production recovery algorithm. Stop completes through an explicit action, without modeling actual process or file cleanup. Workflow cancellation uses per-call work in this model; shared-Session stop interference is not modeled (it is exercised in the SQLite prototype).

## Results

| Configuration | Result |
| --- | --- |
| correct.cfg | Passed type/recorded-answer/no-replay/safe-cancellation invariants and committed-answer stability; 58,157 generated, 12,420 distinct states, depth 26 |
| progress.cfg | Passed the same checks plus cancellation eventually completes under the fairness assumptions below; same state graph |
| broken-cancellation.cfg | Expected counterexample: cancellation finishes with a saved but unanswered intent; SafeCancellation fails |
| broken-replay.cfg | Expected counterexample: recovery returns uncertain work to ready and an already-started tool executes again; NoReplay fails |

Raw logs contain the full counterexamples. The negative controls show failure sensitivity; they are deliberately broken variants, not discovered production bugs.

## Assumptions and limits

One workflow, two keys and at most one crash. SQLite atomicity/durability is assumed, not modeled. No provider, permissions, file bytes, resource limits, input canonicalization, namespace encoding, independent client, or transport implementation is present. Committed rejection cannot change; target validity changing over time is abstracted by the admission answer choice.

Progress requires weak fairness for sending, core processing, reply recording, requesting/finishing stops and final cancellation commit. This means continuously enabled steps eventually execute; combined with finitely many crashes it abstracts eventual service/storage availability and eventual stop completion. It does not promise progress during permanent failure, impose a wall-clock deadline, or require cancellation to be requested. Safety uses no fairness assumptions.

## Reproduce

From this directory, with Java 11+ and tla2tools.jar:

```
java -XX:+UseParallelGC -Xmx1g -cp /path/to/tla2tools.jar tlc2.TLC -workers 1 -metadir /tmp/request-model-correct -config correct.cfg RequestProtocol.tla
```

Use a distinct metadir for each config. The two correct configs should exit 0; the deliberately broken ones exit 12. Local run used `/tmp/onepage-tla-tools/tla2tools.jar`; its SHA-256 is recorded in tools.sha256. Official tool instructions: https://github.com/tlaplus/tlaplus .

Related: [Session API contract](../../docs/design/session-core-api-contract.md), [SQLite protocol experiment](../session-api-prototype/README.md).
