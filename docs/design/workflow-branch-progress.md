# Independent workflow branch progress

Accepted behavior and design trace, 7 September 2026. No production implementation or passing recovery guarantee is claimed. [Choose workflow reevaluation eligibility and wake-ups](https://github.com/DivyanshGolyan/onepage/issues/114) records the accepted discovery and replay decisions; the [closeout review](workflow-114-resolution.md) lists the remaining implementation and qualification.

## Behavior selected

A branch may continue when its own dependencies are ready. Unrelated branches do not impose a global barrier. A's verifiers become eligible when A's findings are available, even while B is still running. Actual evaluation and model/tool launch still require their existing capacities. Explicit joins preserve their own success/failure semantics and required inputs.

The example comes from the scanner-to-verifier shape in the [saved Claude Code workflow audit](../research/local-claude-workflow-usecases.md#per-item-pipelines-and-nested-dynamic-fan-out). Labels and findings below are illustrative, not a replay of a specific saved Run. The current [Workflow Runs contract](../../ARCHITECTURE.md#workflow-runs), [domain language](../../CONTEXT.md) and [ADR-0014 amendment](../adr/0014-use-ephemeral-quickjs-for-workflow-evaluation.md#accepted-amendment--independent-branch-progress) own the accepted semantics.

## Minimum information to account for

These are existing semantic fact families, not a proposal for four new tables.

| Saved information | Why it is needed |
| --- | --- |
| Run identity, source and arguments | Recover the same workflow program and input. |
| Run-local keyed Session operations and exact input/result bindings | Reuse each scanner or verifier request after replay; a key with different inputs conflicts. |
| Original work outcomes and immutable result content | Recover A's findings without requesting another answer or following later Session work. |
| Evaluation Generation, visible results and complete unresolved dependencies | Identify what that evaluation could see and what could subsequently permit progress. |

The accepted generation/publication mapping distinguishes new and interrupted Runs from suspended Runs with a newly available unresolved result. Atomic dependency publication preserves results arriving after capture; considered results do not alone retrigger evaluation. Exact records and indexes remain implementation work; no separate ready flag, callback registry or durable queue is selected.

## One execution, in small steps

Scanner Sessions have already been created through stable keyed creation calls. Each verifier likewise creates its own distinct Session through a stable creation key before its keyed message; sharing a Session could share a Turn/result and would not establish independent verification. The table abbreviates these separate calls; it does not combine creation and messaging into one atomic API operation.

| Moment | Saved facts / view | What may happen next | Resident workflow state |
| --- | --- | --- | --- |
| Scanners admitted | Requests `scan:A` and `scan:B` bind to their original work. Both results are unavailable. Generation G0 records unresolved dependencies. | Scanners run subject to capacity. The workflow has no result-dependent verifier input yet. | G0 exits and releases its heap. |
| A finishes | A's original outcome and findings F1/F2 are committed. B remains unfinished. | The Host must be able to discover that this Run merits further consideration without waiting for B. | No per-waiting-Run evaluator or result-payload queue. |
| Fresh evaluation G1 | G1 sees A's recorded result and B's pending binding in one immutable view. Source replay recovers existing calls. | A's branch creates the two verifier requests using stable keys derived from A and its recorded findings. | One bounded live evaluator; inputs/results consume its existing budgets. |
| Verifier requests saved | `verify:A:0` and `verify:A:1` bind their complete inputs and original work. B remains pending. | Those verifiers can run when capacity permits. The next unresolved set includes their message results and B. | G1 exits after outcome handling and cleanup; waiting dependencies remain durable. |
| B or a verifier finishes | Its result is saved against the original binding. | A later generation can advance the newly enabled branch. Several results may be considered together; no evaluator launch per notification is promised. | Only the admitted evaluation lifecycle is resident. |
| Final aggregation | The workflow's required branches have produced their handled outcomes. | Aggregate the recorded results and publish the final Workflow Output. | Release evaluation/output resources after their existing publication/cleanup boundary. |

Finding indices are stable only because they refer to A's immutable recorded finding list. They are not global invocation ordinals or physical completion positions. A deliberate new verifier attempt requires a distinct workflow call key; recovery reuses the original one.

A final `Promise.allSettled` can collect successful and failed branches; an empty finding list creates no verifiers. A `Promise.all` rejection follows ordinary failure semantics and does not itself cancel siblings. The workflow chooses that error handling; the runtime adds no partial-success subsystem.

## Crash and wake-up checks

| Boundary | Required result |
| --- | --- |
| A's result did not commit | Do not expose it as available. Existing model/effect recovery governs unfinished work. |
| A's result committed, wake-up did not happen | Restart must discover eligible progress from saved facts. No callback replay is needed. |
| Wake-up missed while the Host stays alive | A correct check/sleep handshake or explicitly selected fallback must prevent permanent sleep. Restart-only discovery is insufficient. |
| G1 read its view, then B committed | G1's view stays immutable. Publication/discovery must not lose the later change. |
| G1 discovered a verifier but its request did not commit | Later evaluation may rediscover that same request from A's saved findings. Discovery alone is not durable admission. |
| Verifier request committed, acknowledgement was lost | Replaying its same key and inputs recovers the existing binding rather than another admission. |
| A's result is noticed repeatedly | Repeated discovery must not create duplicate keyed requests; avoiding repeated useless evaluations remains part of the eligibility design. |
| Cancellation commits before another admission | Existing Run cancellation fencing prevents further workflow submissions. Previously admitted effects follow their existing stop/recovery rules. |

These are obligations to establish in the selected mechanism, not executed tests. Transaction grouping for evaluation publication and new requests remains to be specified where existing command contracts do not already determine it.

## Memory and simplicity consequences

Waiting retains saved dependencies, not a JavaScript heap, Promise resolver, per-branch thread or payload-bearing callback. A single live evaluation may materialize part of its input/results within the accepted evaluator limits; disposable does not mean memory-free. Large recorded finding lists may still exceed those actual limits. This decision does not promise arbitrary fan-out fits one evaluation.

Use the existing serial evaluator and keyed request/result owners. A result shared by multiple request bindings need not become a separate resident payload per waiter. Candidate discovery and shared-result fan-out must be bounded and remain recoverable when interrupted. A proposed ready marker or index must earn its maintenance cost through a concrete discovery or resource requirement.

## Accepted discovery follow-up

The asynchronous pull loop is accepted as of 7 September 2026. The Host derives eligibility from saved dependencies and results, selects again after evaluation cleanup, and uses one shared one-second asynchronous timer only after no work is found. Extra evaluations on partial results are acceptable. Completion hooks, deferred notification delivery and a durable ready set are not required for workflow discovery. The prior wake-up scenarios above are handled by subsequent pulls; there is no notification handoff to recover. See [the accepted comparison](workflow-readiness-comparison.md#accepted-choice--asynchronous-pull-loop) and [Workflow Runs](../../ARCHITECTURE.md#workflow-runs).

## Decision closeout

The [closeout review](workflow-114-resolution.md) traces the accepted mapping, oldest-eligible pull loop, fresh recovery, source-derived authoring and returned-root completion. Remaining query, native conversion, crash and resource evidence belongs to implementation/qualification; configuration acknowledgement values remain with #101. The discussion below is historical candidate exploration and does not reopen those choices.

## Earlier candidate discovery discussion — historical

For a nonterminal, uncancelled Run with no evaluation lifecycle in progress, a saved result for any dependency unresolved in its latest published evaluation permits another evaluation. New Runs and recovery of interrupted generations are separate entry cases. The accepted recovery rule abandons the interrupted evaluation and admits a fresh generation with currently available original results.

When capacity is available, create one immutable view containing the then-visible recorded results. Results that accumulated while the evaluator was busy can be considered together; there is no evaluator launch, retained callback or payload queue per completion. No intentional batching delay is selected. A result arriving after snapshot capture belongs to later consideration.

After evaluation, publish its complete unresolved dependencies as the current eligibility basis, with generation identity checked and publication atomic at its owning boundary. Dependencies whose results were visible to that evaluation do not keep triggering it. A dependency unresolved in the snapshot may already have a result by publication time; compare against current saved facts rather than assuming the old view is still current. Revalidate cancellation and evaluation identity before admission/publication. These are candidate representation/transaction requirements, not implemented guarantees.

### Trade-off to discuss

This rule can spend an evaluation on a partial explicit join even when that evaluation produces no new request. For example, a final join waiting for 100 scanners can be reconsidered after only one completes. Once its result has been considered, that unchanged result does not justify another evaluation. Additional completions can still cause further evaluations; coalescing reduces but does not eliminate that cost.

The benefit is that the Host needs no second model of JavaScript branches, join predicates or continuations to predict which result will produce a new request. The existing evaluator determines progress from source and saved values. The existing one-at-a-time lifecycle and memory/time limits apply, but acceptable aggregate reevaluation cost still requires evidence.

### Mechanism comparison

| Candidate | Added responsibility | Check before selection |
| --- | --- | --- |
| Derive eligibility from unresolved dependencies and saved outcomes | Query/discovery through existing durable facts | Bound examined work and service time, including no-ready-work cases; a small SQL result limit alone does not do this. |
| Find affected Runs when a result commits | Reverse dependency access and incremental fan-out | Recover interrupted fan-out and reconcile results that committed before dependency publication. An index alone is not a complete wake-up protocol. |
| Save a ready marker/task | Additional state maintained with result/publication/cancellation transitions | Prevent clearing a newer readiness change and justify duplicate state through measured discovery needs. |

The first is the recommended starting candidate for investigation, not a selected SQL plan or a promise of constant-time discovery. Notifications may request reconsideration, but saved facts determine eligibility.

### Failures the candidate must cover

- A result saved before its dependency is published must still be found by the current-fact check.
- A result saved while an evaluation runs must not be erased by publication of that evaluation's older snapshot.
- A committed result remains discoverable after a crash before notification or halfway through shared-result fan-out.
- The live Host must coordinate checking and sleeping with its owner-observed changes. If its chosen notification channel can drop the last wake, select a reliable latch/handshake or explicit fallback; startup recovery alone is insufficient. Exact synchronization remains open.
- Very many waiting Runs or dependents must not become a resident Run list or one unbounded owner turn. Assess indexed access and bounded/resumable discovery before selecting this candidate.

The next human decision is whether this conservative result-driven reevaluation rule is the right simplicity/cost trade-off. Acceptance would still leave its bounded discovery, publication and wake synchronization to establish.
