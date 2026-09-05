# Automatic invocation ordinals under complete blocked-set barriers

> **Historical experiment, published 6 September 2026.** Sources, fixtures, and recorded observations retain their original investigation scope. Historical decision/implementation status is not a current plan or production verification claim.

**Conclusion: a global incrementing call number is not replay-stable for the supported async JavaScript model. Waiting for every member of the blocked set does not fix this.**

## Counterexample

```js
export default async function ({ agent }) {
  let ordinal = 0;
  const call = name => agent({ key: String(++ordinal), task: name });

  const a = (async () => {
    await call("A");
    return await call("C");
  })();
  const b = (async () => {
    await Promise.resolve();
    await Promise.resolve();
    return await call("B");
  })();
  return await Promise.all([a, b]);
}
```

First evaluation: A is pending, so its continuation cannot run. The second branch drains its ordinary microtasks and invokes B. The complete blocked set is **A=1, B=2**.

Both A and B finish before re-evaluation. On replay, A's already-settled promise queues its continuation immediately. C is invoked before the delayed second branch reaches B. Invocation order is now **A=1, C=2, B=3**. C collides with B's recorded identity; B also appears to be new work.

This needs no race/any, clocks, randomness, partial completion visibility, source changes, mutable results, external input, or physical completion ordering. Plain nested async functions plus Promise.all suffice.

## Native evaluator verification

Ran `research/workflow-call-order/native_probe.py` against the existing local `zig-out/bin/onepage-workflow-evaluator` using the native binary protocol. No provider calls, Store mutations, or production source changes occurred.

Executable SHA-256: `8d974987af793506e1f79aceeb1e5b946e49f19402b8b92dc6a998d936228c24`. This is an existing build, not a rebuild of the current checkout.

Observed:

1. No visible results → blocked descriptors `{key:"1",task:"A"}`, `{key:"2",task:"B"}`.
2. Both prior outputs visible → blocked descriptor `{key:"3",task:"B"}`.
3. Third output also visible → completed `['answer B', 'second answer B']`.

The low-level fixture supplies results by key, so C consumes B's result. A Host that validates complete descriptor bindings on replay should reject the mismatch instead. Either behavior defeats the proposed automatic numbering; this is not a claim that the current production Host silently misroutes results.

Current source explains the behavior:

- `src/workflow_evaluator.zig:450`: drains pending microtasks until none remain, subject to bounds.
- `:518`: unseen calls return unresolved promise capabilities.
- `:546` and `:552`: visible successes/failures return `JS_NewSettledPromise`.
- `:388`: Promise.race and Promise.any are removed; Promise.resolve and async functions remain available.
- `:323`: pending requests are emitted as the blocked set after the drain.

## What would make automatic identity sound?

Keeping keys requires no new scheduling system: A, B, and C retain their semantic identities despite changing invocation order.

Removing keys while keeping broad async composition requires a replacement identity mechanism. Possible approaches include recording and reproducing historical barrier visibility/promise-release phases, or compiler/runtime-generated structural identities for call sites, loops, and async branches. Neither is equivalent to incrementing a counter. Historical phase replay would also require microtask draining and controlled promise settlement inside an evaluation, rather than making every previously completed call immediately fulfilled.

A narrower language can make numbering defensible. Strict sequential awaited calls are stable when source and prior results are fixed; likewise, explicit fixed batches that invoke all members synchronously and cross a single aggregate barrier before constructing the next batch. The proof follows the fixed sequential/batch call order by induction. Arbitrary nested async branches violate that premise, as the example demonstrates.

**Recommendation:** do not describe removing workflow keys as a trivial ergonomic cleanup. Keep the current identity contract for this Session-interface decision, or open a separate language/replay design decision with an explicit restriction or replacement mechanism.
