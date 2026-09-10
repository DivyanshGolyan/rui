# Reconsidering creation replies and evaluation wakeups

## Subsequent decision — 10 September 2026

The [Session initialization decision](../design/session-initialization-proposal.md) and [Workflow Runtime boundary](../design/evaluator-coordinator-boundary.md) now settle caller-owned references and first configuration without generated-ID discovery or a reference resolver. The closed #114 asynchronous pull policy remains selected; no replacement wakeup hook or resident queue was accepted. Earlier reconsideration below is historical.

Reviewed 2026-09-10 against live GitHub decisions. This is reference and comparison for an open discussion, not selection of a new evaluator policy. Root checkout inspected read-only. No issue or normative contract is changed by this review.

## Authoritative prior decisions

[Closed #114 final resolution](https://github.com/DivyanshGolyan/onepage/issues/114#issuecomment-5575748275) selected:

- New Runs, interrupted evaluations, and suspended Runs with any newly available unresolved dependency are eligible. A partial join may cause another evaluation. The host does not interpret Promise dependencies or require a global join.
- One complete evaluator lifecycle at a time; oldest eligible first, query again immediately after lifecycle cleanup and other Host service, and wait one second asynchronously only after an empty query.
- Each live evaluation has fixed available-result membership. There is no live result injection.
- Validate the complete evaluator output and known bindings before independently admitting new calls; retain committed prefixes after later failure and publish the final generation outcome/dependency set atomically.
- A crash abandons the interrupted evaluation. A fresh generation uses current original keyed results, not the abandoned snapshot.
- The returned value/Promise determines completion. A fulfilled root can complete with unawaited calls still pending; those calls still require validation/admission, and their later results do not restart a terminal Run.

The [branch-progress decision](https://github.com/DivyanshGolyan/onepage/issues/114#issuecomment-5569358326) explains why one branch may progress before another. The [pull-loop decision](https://github.com/DivyanshGolyan/onepage/issues/114#issuecomment-5571455370) deliberately avoids completion hooks, ready queues and per-Run timers. Its same-generation crash reconstruction statement was subsequently superseded by the [fresh-evaluation amendment](https://github.com/DivyanshGolyan/onepage/issues/114#issuecomment-5572610760).

[Closed #90](https://github.com/DivyanshGolyan/onepage/issues/90#issuecomment-5565740113) selected a disposable evaluator with one-second CPU and five-second elapsed lifecycle limits. External-work waits are outside that lifecycle. A live request/reply bridge would need an explicit fit check against containment, admission timing and elapsed waiting; it is not merely an API spelling change.

[Issue #101](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667) is still open, but its accepted Session interface amendments distinguish creation/configuration replies from a message's original final result. Creation starts no model work. A Promise return type does not itself mandate an evaluator restart; the staged evaluator design does. Later local decisions make the workflow an independent keyed client of the core, superseding older shared core/workflow admission transactions and unkeyed direct callers.

## Point 4: creation during the evaluation

Under #114, new creation follows:

```text
JavaScript asks for a Session -> evaluator exits with the request
-> coordinator saves/submits it -> core saves Session and returns ID
-> coordinator saves ID -> next evaluation returns that ID to JavaScript
```

The next evaluation need not wait for the idle timer: the just-recorded reply already makes the Run eligible. Parallel creation requests can be processed within one evaluator lifecycle's post-exit admission phase before the next evaluation. This is why reasoning from the number of reply arrivals alone gives the wrong evaluation count.

The benefit is a one-way input/output evaluator protocol, full output validation before new external submissions, a fixed input view and no waiting evaluator heap during core calls. The cost is extra evaluations even for quick database operations, especially sequential creation/configuration chains.

Changing this to return new IDs during the same evaluation is possible. The evaluator must exchange requests and replies with its coordinator while it is alive. The coordinator must still persist identities/inputs before core submission and record replies before returning them to JavaScript. Time spent waiting and an error later in the script need explicit treatment: some calls may already have committed before final output validation. This does not require putting workflow branch decisions in the coordinator.

Creation delivery and model-result delivery are separable choices. One can consider live creation/configuration replies while still freezing previously submitted message-result visibility for an evaluation. That hybrid needs a precise visibility rule; it should not be described as retaining the old all-results-fixed contract unchanged.

## Point 5: a Session finishes during evaluation

Under #114, suppose JavaScript started with A's result and B still pending. B finishes while the evaluator runs. B remains absent from that evaluator's fixed input. If the returned Promise is still pending, its complete unresolved set includes B. After publication, the next eligibility query sees B's saved result and schedules another evaluation. If the returned root finished, the Run becomes terminal and no later B result reopens it.

No completion event needs to be retained across that race: the unanswered dependency and saved result remain queryable. Under the independent-workflow boundary, the coordinator obtains and records results through the core API rather than joining core tables. The correctness argument remains a comparison of recorded facts, not a promise that every transient notification arrives.

A completion-hook design is also possible. If it only notices B while the evaluator is busy and then forgets the event, the workflow can remain asleep after exiting. It needs either a retained/coalesced reevaluation indication or a post-evaluation durable result check, plus restart discovery. The prior pull decision chose the latter family without a hook. Neither approach decides whether JS can advance; it merely decides when JS gets another chance.

A Run-to-Session map can route hints. Original keyed calls/results are still necessary: Sessions are reusable, creation/configuration do not finish model work, unrelated later work can finish in the same Session, and new/interrupted Runs need evaluation without any Session completion. New Session creation cannot rely solely on a Session-completed hook to return its ID.

## Corrections to the recent walkthrough

The recent claim that creation should finish inside the current evaluation was a new recommendation, not a restatement of #114. The claim that Promise.all lets the host suppress reevaluation until all inputs arrive also contradicted the accepted conservative eligibility rule. Finally, the newly written two-Session trace's same-fixed-input crash restart description conflicts with #114's later fresh-evaluation amendment; that text must be reconciled when the present reconsideration is settled. Historical prototype states are evidence, not instructions to restore superseded snapshot reconstruction.

The user's proposed central invariant is compatible with either delivery mechanism: JavaScript alone determines branch progress, joins and its returned result. Outside JavaScript, the coordinator can keep request/result records and perform conservative eligibility checks without becoming a second workflow interpreter. The open choices are when new replies enter JavaScript and how reevaluation is discovered reliably.
