# Workflow Session references

**Superseded 2026-09-10.** The accepted [caller-reference and initialization decision](session-initialization-proposal.md) removes the creation-result resolver, generated-ID accessor and dependent-failure machinery proposed below. References are caller-owned values; first configuration establishes durable Session state. The original proposal is retained as historical reasoning.

Proposed 2026-09-10. Interface discussion, not an accepted API or production implementation. This resolves the creation/reference question left open by the [fixed-input evaluator decision](evaluator-coordinator-boundary.md).

## Proposal

Creating a Session from workflow code immediately returns a Run-local reference to its keyed creation request. It does not return the core's Session ID or claim that creation succeeded. Message and configuration calls can target that reference. Workflow Runtime resolves it through the saved creation answer before making an ordinary Session core request.

An explicit accessor returns a Promise of the original creation result when code needs the actual Session ID or wants to catch creation failure directly. This observes the existing keyed call; it introduces no second operation, wait key or core request.

Illustrative names, not selected spellings:

```javascript
const worker = session(config, { key: "worker" });
const answer = await sendMessage(worker, "Summarize the changes", {
  key: "summary",
});
return answer;
```

`worker` is a logical reference, not a Promise or a live Session object. `await worker` does not wait for creation; there is no special thenable behavior. Use `await sessionId(worker)` when the actual ID or creation outcome is needed. References own no execution resources and retain no heap across evaluations.

## One evaluation can describe both operations

The first evaluation receives no creation result. Calling `session` emits a keyed creation description and returns a reference scoped by Run identity and creation key. Calling `sendMessage` emits a separate keyed message description whose target is that reference. Its Promise remains pending, so evaluation returns both encountered calls and a waiting root.

Workflow Runtime validates the complete output and existing bindings, then handles new calls under the accepted independent admission rules:

1. Save the creation identity and exact configuration; submit through the ordinary core create operation and record its original answer.
2. Save the message's logical target, exact message inputs and request identity. Resolve the target using the recorded creation answer. That immutable answer plus the saved message description determines the exact core request; no mutable Session lookup or duplicate resolved-input record is needed solely for recovery.
3. Submit the message using the real Session ID and stable request identity, then record its original admission answer and eventual result.
4. A later evaluation receives available original keyed results. The same source reconstructs the reference and the message call returns its original result. JavaScript alone determines the returned workflow outcome.

Core calls happen outside evaluation. Waiting for creation or message execution consumes no evaluator heap or lifetime budget. A creation reply can still make a waiting Run eligible under the existing policy, so this proposal does not guarantee exactly two evaluations. It removes the necessary creation-only evaluation before the message can be described.

## Creation failure

If the core commits a creation rejection, Workflow Runtime records it. A described message/configuration targeting that creation cannot be submitted. Record a stable workflow-call rejection identifying the failed creation and its original cause. Do not fabricate a core admission, Session ID or model failure. Replay returns that same rejection through the dependent call's Promise.

Thus the original example rejects at `await sendMessage(...)`. Ordinary `try/catch` or `Promise.allSettled` can handle it. Independent branches remain ordinary JavaScript:

```javascript
const left = session(leftConfig, { key: "left" });
const right = session(rightConfig, { key: "right" });
return await Promise.allSettled([
  sendMessage(left, "Inspect implementation", { key: "inspect" }),
  sendMessage(right, "Inspect tests", { key: "tests" }),
]);
```

One creation rejection produces one rejected message result; it does not itself cancel the other Session or override a successfully handled root outcome. The reference must not eagerly create a hidden rejected Promise when no code observes creation: message failure or the explicit creation-result accessor supplies the observable Promise.

A missing or uncertain reply is not a committed creation rejection. Recover it by retrying the same core request identity, leaving dependent submission unresolved until the original answer is established. Changing configuration under the same creation key conflicts; a deliberate new creation uses a new key. Temporary storage/communication failures retain the existing infrastructure/recovery behavior rather than being converted into a permanent creation failure.

## Actual IDs and existing Sessions

Code that creates a Session for later use outside the Run can return its real ID:

```javascript
const worker = session(config, { key: "worker" });
return await sessionId(worker);
```

The accessor returns a fulfilled or rejected Promise from the current evaluation's fixed original creation result, or a pending Promise if unavailable. It does not poll or receive a live reply. Calling it several times observes the same keyed result without repeating creation. Do not expose a speculative ID through an unresolved reference.

Existing Sessions supplied as arguments remain ordinary IDs:

```javascript
return await sendMessage(args.sessionId, "Continue the review", {
  key: "follow-up",
});
```

Message/configuration inputs distinguish an existing ID from a Run-local creation reference. The Session core sees only actual IDs. A logical reference is not a cross-Run identity or public serializable Session ID; use the explicit creation-result accessor when exporting one. No attachment operation, ownership lease or Session clone is introduced.

## Configuration and ordering

`configureSession` may target either form and retains its own keyed admission result. If subsequent messages must wait for successful configuration, code awaits that Promise before describing them. That can require another evaluation; it is an actual dependency on a result, not an ID bookkeeping requirement. An unawaited configuration failure does not automatically suppress later message calls.

Creation references resolve only the fixed prerequisite needed to address an existing core operation. They do not introduce a general dependency graph, interpret Promise joins or allow later unseen JavaScript continuations to run in native code. Ordinary call order, full output prevalidation, committed-prefix retention and final dependency/outcome publication remain under [closed #114](https://github.com/DivyanshGolyan/onepage/issues/114#issuecomment-5575748275), amended by the accepted independent core/workflow ownership.

## Crash, cancellation and unawaited work

| Situation | Proposed behavior |
| --- | --- |
| Creation committed; reply not recorded | Retry the same creation identity and save its original ID/rejection |
| Creation answer saved; message not submitted | Resolve the saved logical target to the same ID and submit the saved message identity |
| Message committed; reply lost | Recover its original acceptance; never bind it to newer Session work |
| Creation rejected; dependent rejection not yet saved | Derive and save that same rejection from the original creation answer; make no core message call |
| Run cancellation with saved unresolved creation/message intents | Recover creation first, then resolve dependent intents using the existing submit-then-stop policy; creation success may lead to message admission before stopping |
| Creation rejected during cancellation | Resolve dependent intents as not submitted; no Session is added to the stop set |
| Evaluator crash | Fresh evaluation uses current original results and stable references; no live handle or previous heap is recovered |
| Root finishes without awaiting a described call | Preserve required admission/validation before terminal publication; no implicit await-all rule, and later results cannot reopen the Run |

Cancellation cannot simply drop a saved message intent because its logical target was unresolved when cancellation arrived. Accepted messages determine the Session stop set; creation/configuration alone do not. This preserves the [accepted cancellation tradeoff](shared-request-identity.md), including possible work/cost before stop and effects on shared Sessions.

## Cost and alternatives

Keeping `createSession` as a Promise of a real ID needs no logical-reference representation, but JavaScript must learn the result in another evaluation before it can name the target of a message. Returning live IDs during evaluation breaks the selected fixed-input computation. Making workflow keys directly become core Session IDs would change core identity/admission semantics and is not necessary for this proposal.

The proposed cost is one small target variant and resolution through an already-recorded creation answer, plus stable dependent failure handling. These stay inside Workflow Runtime. The benefit is describing creation and subsequent operations in one evaluation while retaining ordinary IDs at the core interface.

## Evidence and decision needed

No implementation or tests were added. Required cases include create-plus-send without a live evaluator reply, direct creation-result observation, caught creation rejection without hidden unhandled rejection, independent `allSettled` branches, same-key conflicts, existing IDs, configuration ordering, crash recovery at each handoff, cancellation with an unresolved logical target and unawaited-root behavior.

This proposal would replace the earlier Promise-returning creation shape from [#101](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667) for workflow authors. The direct Session core API remains unchanged. Accepting the logical reference, explicit creation-result observation and dependent-rejection behavior is a product/interface choice; exact names and encoding can follow. Configuration acknowledgement shape and provider wire evidence remain separate open decisions.
