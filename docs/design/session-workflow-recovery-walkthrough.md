# Session workflow recovery walkthrough

> **Historical design exploration, published 6 September 2026.** The [normative architecture](../../ARCHITECTURE.md) and [product contract](../../PRODUCT.md) own the current design. Earlier signatures, issue ownership, status statements, and unselected alternatives below retain their original context; they are not a second current specification.

Status: decision walkthrough, 5 September 2026. The sequence below exercises accepted Session/workflow behavior. The configuration return value remains proposed. The user accepted that workflow cancellation composes ordinary Session-stop completion, regardless of who submitted the stopped work; ordinary stop completion now means the selected work's durable terminal outcome and atomic Session occupancy release. This is a paper trace, not an executed recovery test or production implementation.

Decision owner: [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101). The [Session workflow interface](session-workflow-interface.md) and its linked accepted decision record define the existing contract.

## One workflow

Illustrative option names; complete creation options and the supported configuration fields remain with their owning contracts.

```js
export default async function workflow(
  { createSession, configureSession, sendMessage },
  args,
) {
  const session = await createSession({
    key: "review-session",
    ...args.sessionOptions,
  });

  await configureSession(session, { effort: "high" }, { key: "effort" });

  const review = await sendMessage(session, "Review the change.", {
    key: "review",
  });

  const followup = await sendMessage(
    session,
    "Also check the timeout handling.",
    { key: "timeouts" },
  );

  return { review, followup };
}
```

The example deliberately awaits each message so the follow-up depends on settled earlier work. Another client's admissions may still interleave. Neither call requires a public Turn ID or a Session wrapper.

## Saved facts and recovery

| Boundary | Committed facts | Recovery after commit, before the caller receives the result |
| --- | --- | --- |
| Create Session | Session, complete baseline configuration, and Run-local creation binding commit together. | The same creation key returns the same Session ID. No model call was started. |
| Configure | The sparse configuration change and keyed operation result commit together. | The same key recovers success without applying the old change again. Another client's later settings remain current. |
| Submit review | The keyed message binding and ordinary Session message admission commit together, identifying the work accepting the message. | Recover that admission. Do not append another message or select newer Session work. |
| Construct a model request | The request's manifest freezes the selected configuration and exact canonical inputs. | Reuse that manifest for an eligible replacement Attempt. Do not select current settings for the old request. |
| Settle review | The original work has a recorded outcome from which the keyed message result is recovered. | Return its original answer or rejection. No new model call is needed to reconstruct the workflow's `review` variable. |
| Submit follow-up | A different key binds a new message admission to current Session work. | If already admitted, recover it; otherwise submit it once when evaluation reaches this call. |
| Finish evaluation | Ordinary Run outcome rules govern workflow completion. | Recover the committed Run outcome; do not re-execute completed message work. |

Before any admission transaction commits, that admission does not exist. After commit, its binding remains authoritative even if acknowledgement is lost. This is the existing keyed workflow protocol, not an extra receipt mechanism. Exact relational columns remain implementation work.

Provider execution has a separate failure boundary: an in-flight external request may need an eligible replacement Attempt and may incur duplicate work or billing. Replaying a completed workflow call itself does not spend another model call. Restart and explicit resumption retain the existing Host lifecycle contract; this trace does not introduce automatic resumption.

## Configuration interleaving

1. This workflow commits `effort: high`.
2. Another client commits `effort: low`.
3. The evaluator is restarted and revisits the completed `effort` key.
4. Replay recovers its original success; it does not restore `high`.
5. A newly constructed model request selects the then-current settings, including `low` if nothing else changed them.

That outcome follows the accepted caller-agnostic Session model. Awaiting configuration orders this workflow's calls; it does not acquire a lock or guarantee that a later request uses that value.

Proposed return shape: `configureSession(...): Promise<void>`. Fulfilment would mean the change committed, not that a model consumed it. Internal provenance would remain stored even though this function returned no revision. The alternative under discussion is returning the saved revision; neither option would establish a freshness precondition or wait for model application.

## Cancellation while the follow-up is pending

| Point | Accepted behavior |
| --- | --- |
| Cancellation intent commits | Further evaluation and new Session operations from this Run are fenced. A crash cannot erase the intent. |
| Stop pass visits the Session | Ordinary Session stop targets its current work. Creating or configuring a Session alone would not put it in this pass. |
| Crash before or after a stop | If Run cancellation is unfinished, recovery may repeat the entire pass. A repeated stop may affect newer work; callers coordinate Session reuse. |
| Stop reaches an admitted external effect | Existing effect-specific interruption, evidence, reconciliation, Tool Result publication, and settlement rules apply. Stop does not erase those obligations. |
| Crash after the final stop, before Run cancellation completion | The pass may repeat because completion has not committed. No per-Session propagation receipt is added. |
| Run cancellation completion commits | Recovery no longer propagates this cancellation. Remote provider processing or billing is not proven stopped. |

The user rejected a proposed distinction between work submitted by the cancelling Run and work submitted by other clients. The accepted composition is: fence the Run, apply ordinary stops to every Session in its message-derived set, and complete Run cancellation when those stops complete. Creation alone does not add a Session. Stop completion has one Session-level definition, independent of the requester or submitter; workflow cancellation adds no ownership-specific settlement rule.

Cancellation-intent acknowledgement remains distinct from completion. Ordinary Session-stop completion is the selected work's durable terminal outcome and atomic logical occupancy release, as detailed below. Existing effect-specific recovery and the absence of a remote-provider stop/billing guarantee remain unchanged. A completed cancellation does not permanently prevent later Session work.

The earlier proposal to require outcomes for all Turns originally bound to the Run is superseded, not an accepted additional predicate.

## Accepted ordinary Session-stop completion

An idle Session stop completes immediately. Otherwise, the stop selects and fences the current work; completion follows that work's durable terminal outcome and the atomic release of logical Session occupancy. It does not wait for future work or continuously test whether the Session remains idle. If ordinary settlement wins before stop admission, preserve its outcome; do not rewrite completed success as cancellation.

The command can acknowledge that stopping was durably requested before completion. Starting the stop promptly does not require waiting for every effect to finish first:

| Selected work | Existing obligation before the stopped work can settle |
| --- | --- |
| Model request | Commit interruption, exclude late output and further retry, and resolve remaining semantic obligations. Model transport suppression/detachment and Active Credit release retain their existing physical owner; no remote provider acknowledgement is required. |
| Tool not yet attempted | Resolve without executing and publish the required typed Tool Result. |
| Started Bash | Request process-group interruption and obtain the effect-specific terminal evidence or recovery resolution. A crash may produce an indeterminate result; do not replay the command or invent certainty about external effects. |
| Started Patch | Finish the existing bounded execution/reconciliation path and publish its result; do not abandon a partially applied mutation. |

Workflow composition promptly requests the required stops through bounded traversal before waiting for all of them to complete. A slow tool in one Session must not block requesting stops in later Sessions. Each completion follows the ordinary selected work regardless of its submitter. The existing unfinished-pass crash rule remains in force. Exact relational driving must be checked without introducing a resident Session population or per-Session propagation receipts.

The user accepted this boundary after discussing [Matklad's cancellation terminology](https://matklad.github.io/2026/08/31/cancelation-terminology.html). That article distinguishes cancellation requests from completion and keeps asynchronous cleanup with the resource-owning layer. OnePage's application preserves its existing separation of durable work outcomes and physical resource release; cancellation does not let resources be freed while still in use. This is a selected design, not an executed proof. It adds no new permanent Session state, provider-cancellation protocol, or effect certainty guarantee.

## Evidence still required

Implementation fixtures must exercise rollback and lost acknowledgement at each admission boundary, disposal of the evaluator between both messages, configuration interleaving, recovery of completed answers without redispatch, eligible recovery of incomplete external work, and the cancellation crash points above. Assert the committed facts and caller-visible results through the public interfaces. Do not require a durable JavaScript Promise graph, a new Session worker, a Turn Contract, or cancellation progress records.

The separate [limit-matrix decision](https://github.com/DivyanshGolyan/onepage/issues/89) remains an implementation prerequisite. This example neither chooses limits nor validates memory measurements.
