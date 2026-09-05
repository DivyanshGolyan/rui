# Reuse submission identity for workflow results

> **Historical experiment, published 6 September 2026.** Sources, fixtures, and recorded observations retain their original investigation scope. Historical decision/implementation status is not a current plan or production verification claim.

Checked 5 September 2026 for [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101). This is investigation evidence and a recommendation, not an accepted interface change or production recovery proof.

Subsequent decision: the user selected the message-result Promise behavior on 5 September 2026. See the [current interface note](../../docs/design/session-workflow-interface.md). The checks and their limitations below are unchanged; this selection does not establish Session creation or durable Host integration.

## Finding

One workflow key can identify both a submission and the outcome of the work that accepted it. A separate key for waiting is unnecessary **if the workflow operation includes completion**. The existing design already has that shape: `(Run, key, binding)` selects one membership and its immutable Turn Outcome. It does not select the Session's latest answer on every evaluation.

An independent `session.wait()` has different semantics: select current work when that observation begins. Reusing a submission key cannot silently change it to observing the work that accepted that submission. Caller trust does not settle this distinction.

The minimal counterexample needs only one workflow: submit draft, observe draft, submit revision, observe revision, then restart before committing Workflow Output. Looking up Session-current state for the first wait now selects revision. The original result must remain associated with an identifiable operation if replay is to preserve downstream decisions.

## What already exists

- [Workflow Run contract](../../ARCHITECTURE.md#workflow-runs): equal key and binding recover an exact membership; outcomes are immutable. These sections still describe the older Turn-facing interface, not all accepted Session amendments.
- [Add durable Workflow Run and keyed Turn membership](https://github.com/DivyanshGolyan/onepage/issues/35): specifies durable key lookup, lost acknowledgement recovery, and changed-binding conflicts. Open with implementation proofs unchecked at inspection.
- [Replay workflows through disposable QuickJS evaluations](https://github.com/DivyanshGolyan/onepage/issues/36): specifies fresh evaluation against recorded outcomes. Also open with proofs unchecked.
- [Evaluator source](../../src/workflow_evaluator.zig): `agentCall` checks duplicate descriptors within an evaluation; `promiseForVisible` supplies a pending promise or a frozen cached value/failure. The descriptor supports `key`, `task`, `input`, `schema`, and `agent_profile`; reusable Session operations are not implemented there.
- [Host Store source](../../src/host_store.zig): current schema does not implement the proposed durable Run membership. The investigation cannot claim end-to-end crash recovery is implemented.

## Executable checks

Run `python3 research/workflow-result-identity/probe.py` from the repository root. [Results](results.json) record the script and existing evaluator executable SHA-256 values.

Eight assertions cover initial draft blocking, draft recovery into revision input, recovery of both completed results, repeat completed evaluation, aliases and repeated awaits, cached failure, cached cancellation, and conflicting same-key descriptors within one evaluation. Every evaluation starts a new native process. Completed success/failure cases request no additional work. A structured revision value returns without an answer envelope.

The fixture uses the existing local native evaluator binary, not a fresh build. That artifact uses `TurnFailed`, `TurnCancelled`, `turn_key`, and `TurnRequestInvalid`; current source uses corresponding Job names. Initial fixture attempts using current-source names failed protocol validation; the final fixture explicitly targets the recorded artifact. This is not evidence of a current-source protocol bug.

Visible results are supplied by the fixture. `input.session` is ordinary strict data, not a functioning Session API. The alias check establishes keyed promise identity, not Host scheduling of concurrent same-Session messages. No provider, SQLite Store, process-kill recovery, or cross-evaluation Host binding validation is exercised. This verifies evaluator composition; source and live contracts supply the separate design argument about durable lookup. The earlier [call-order probe](../workflow-call-order/README.md) already rejects replacing stable keys with a naive global invocation counter.

## Recommendation and tradeoff

For the durable workflow consumer, let one keyed message operation resolve to its recorded result:

```js
// writer is an already obtained Session handle; this is a proposed completion change.
const draft = await writer.send("Draft the plan", { key: "draft" });
const revision = await writer.send("Revise the plan", {
  key: "revise",
  input: draft,
});
```

This keeps one key per submitted message. Waiting is ordinary awaiting of that operation. A caller can keep a promise and await it later; independent Sessions can compose with `Promise.all`. No per-caller conversational position, observation key, ownership lock, or new scheduling mechanism follows from this choice.

This deliberately revises the workflow proposal in which `send` resolves on admission and `wait` independently selects current Session work. The server and direct CLI can retain their accepted current-state operations. A workflow adapter can bind completion to the admitted work using internal durable facts without exposing Turn IDs. It must not implement this merely as two live CLI calls, since an independent current-work wait can select different work after submission.

The workflow's return value belongs to the work that accepted the message. Other inputs joining that work can affect its eventual answer; several messages can share an outcome. This promises neither a separate answer for every message nor isolation from other callers. Already-frozen model requests remain unchanged.

### Costs that remain

The older membership contract permits one membership per Turn. Multiple keyed workflow messages joining the same active Turn therefore require message-level admission bindings or an amended membership relationship. Separate wait keys would not remove this requirement. Outcomes can still be referenced once rather than copied per message; storage layout remains unselected.

This is compatible with disk-first storage: reuse small admission/result references and reconstruct bounded values in temporary evaluators. It does not establish measured RSS or SQLite cost, and it adds no justification for retaining dormant handles or conversation copies.

Session creation and early Session-ID availability still need a coherent spelling alongside this completion contract. Do not infer a new empty-Session creation operation, result envelope, or receipt object from this limited example. Standalone historical reads/waits inside workflows would likewise be a separate capability to justify; this recommendation only covers submission and its result.

No normative documents or GitHub contracts were changed by these checks. The completion behavior was subsequently selected; the remaining interface and storage choices are still open.
