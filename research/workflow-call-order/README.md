# Cached answers can change invocation order

> **Historical experiment, published 6 September 2026.** Sources, fixtures, and recorded observations retain their original investigation scope. Historical decision/implementation status is not a current plan or production verification claim.

A narrow JavaScript probe for the proposed Session workflow interface, checked 5 September 2026. It tests automatic global call numbering against disposable evaluation. The Node probe does not execute OnePage. A companion native probe exercises an existing evaluator binary. Neither changes the implementation or makes model calls.

Run from the repository root:

```sh
node research/workflow-call-order/probe.mjs
```

The first evaluation has no visible answers. Its two branches invoke A and B, which both remain pending. Before replay, the probe makes **both** available: it does not use partial completion or a physical completion-order race. One branch can now proceed from cached A to a new C earlier than the other branch reaches B.

Observed output:

```json
{
  "first": {"calls": ["A", "B"], "pending": ["A", "B"]},
  "replay": {"calls": ["A", "C", "B"], "pending": ["C"]}
}
```

Thus invocation ordinal 2 identified B originally and C during replay. Exact binding validation would produce a conflict; removing validation would risk returning the wrong recorded result. Globally numbering calls does not preserve identity for this legal Promise.all composition.

The probe uses named answers as an oracle to show the call sequence that correct keyed replay permits. It is not an implementation of an ordinal-based store. Two resolved Promise awaits in one branch create an ordinary, deterministic JavaScript scheduling difference once the other branch's external result changes from pending to fulfilled.

This matches the relevant shape of the current evaluator: [promiseForVisible](../../src/workflow_evaluator.zig) returns an unresolved promise for missing results and an already-settled promise for visible outputs; the evaluator drains queued jobs. Its API remains the older keyed agent capability. The first probe runs under Node. A [native verification](native-verification.md) also reproduced the collision against the existing QuickJS evaluator binary, whose hash is recorded there. Run `python3 research/workflow-call-order/native_probe.py` with that binary available. The fixture supplies outputs directly by key without Host binding validation; this is evidence against the proposed global counter, not a claim of a production Host bug or a test of a fresh build. A future identity implementation still needs checks covering nested branches, loops, errors, and admission-returning Session methods.

The result rejects the simple global-counter proposal, not automatic identity in principle. Historical visibility replay, controlled promise delivery, branch-aware identities, or language restrictions might make automatic identity possible. Their state, resource cost, and allowed-program tradeoffs need explicit evaluation. Keeping the existing workflow keys avoids those changes. Direct CLI submissions remain keyless by user decision.
