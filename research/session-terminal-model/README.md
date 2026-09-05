# Failure, stop, and continuation with pending messages

> **Historical experiment, published 6 September 2026.** Sources, fixtures, and recorded observations retain their original investigation scope. Historical decision/implementation status is not a current plan or production verification claim.

Checked with TLC on 5 September 2026. This extends the [successful-settlement and replay study](../session-replay-model/README.md) with a separate model. It evaluates the proposed pending-message rule without changing production code or closing the architectural decision.

**Result:** the corrected model passes safety and conditional progress across 29,144 reachable states. Three deliberately broken alternatives produce counterexamples. Four reachability checks confirm failure/stop continuation, crash recovery, and discarding a late result after new work has begun.

## Proposed rule

When a definitive failure or stop makes pending messages inapplicable, preserve their immutable admissions and content. Show that they were not applied, with the failure/stop cause. A new message can continue the Session after old work settles, but must not implicitly apply those excluded messages. Retrying their content requires a new explicit submission.

No per-message phase is required by this rule: applicability can be derived from the causal failure/stop fact, the message's original work, and the absence of its projection into Conversation. The existing projection relation continues to identify applied messages.

The terminology matters. **Projected/applied is not proof of provider consumption.** OnePage prepares context before launching transport. A message can therefore already be in Conversation when a request is interrupted, rejected, or never sent. Those existing facts remain; this rule concerns messages still unprojected at the terminal decision. Provider execution and billing uncertainty require separate Attempt/Resolution evidence.

## Scope and boundaries

One existing Session, two episodes of work, three immutable messages:

- A initiates work 1 and is already projected into Conversation at the initial state.
- B can be admitted while work 1 accepts messages. It may arrive before or after provider request preparation.
- C explicitly starts work 2 once work 1 has ended and released Session occupancy.

A request contains already-projected history plus the current work's applicable pending messages. A later C may intentionally contain the same text as B, but remains a new admission; the model reasons about identities, not content deduplication.

The model separates message admission, context projection/manifest preparation, transport launch, remote completion, local completion acceptance, failure/stop decision, transport cleanup, terminal outcome/occupancy release, and server crash/restart/resume. A provider can return after detachment and even after subsequent work starts.

A committed failure/stop cause immediately blocks new work under the old episode and makes its unprojected messages inapplicable. Cleanup then suppresses prepared transport or detaches launched transport. Only after modeled custody is gone does terminal settlement release the Session. Detachment does not assert the remote provider stopped or avoided charging.

Failure means an **irreversible terminal decision**, such as capacity failure before preparation or a provider error already classified as terminal. Retryable errors are outside this abstraction. The model's `fence` represents causal authority; it is not a choice of a new SQL table, copied intent, or lifecycle phase. With no outstanding work, a concrete implementation may commit failure cause, outcome, and occupancy release together.

Crashes preserve admissions, projections, and committed failure/stop facts. Restart alone does not enable provider requests. Explicit resume retires the old modeled attempt and permits a replacement, without clearing any failure/stop decision. An epoch abstracts rejection of retired attempt results; it does not select a new production epoch field or replace effect-specific recovery.

## Counterexamples

| Disabled rule | Trace | Violation |
| --- | --- | --- |
| Exclude old pending rows from future requests | Admit B → fail work 1 → release Session → admit C → build context from every admitted row | B is silently applied to work 2. |
| Preserve truthful projection facts | Admit B → fail work 1 → mark remaining messages applied while finalizing | B appears applied despite no request preparation having projected it. |
| Validate result authority at acceptance | Prepare A → launch → stop commits → provider returns success → accept it anyway | A result is accepted after its authority was revoked. |

Full traces: [carry-forward](results/broken-carry.log), [false disposition](results/broken-disposition.log), [late result](results/broken-late-result.log).

The correct late-result path can continue further: launch A, stop, detach, settle, admit C, launch C, receive A's old success, discard A's result. This is an actual [reachability witness](results/witness-late-after-continuation.log), not an assumed narrative. It does not mutate the old outcome or the newer work.

## Checks and recorded results

The model bounds execution to one Session, two internal Turns, three messages, up to one crash, and up to four prepared requests. Safety and progress runs each explored the full graph: **69,625 generated states, 29,144 distinct states, zero states left queued**. Counts are per configuration and should not be added together.

Safety invariants check:

- Excluded messages never acquire a projection and never appear in a prepared request.
- Revoked or retired results are never semantically accepted.
- Terminal outcomes remain unchanged.
- Every terminal message is either already projected or explicitly excluded.
- Active occupancy only belongs to open work, and all modeled values have valid types.

The temporal checks establish eventual settlement of each opened episode and eventual accounting for every admitted message, conditional on finite messages/crashes, eventual explicit restart/resume, fair Host/cleanup scheduling, and eventual provider return. They guarantee neither success nor a response-time bound. Failure is a legitimate terminal outcome. The optional actions of stopping and starting C are not required by fairness.

| Configuration | Expected result | Distinct states examined |
| --- | --- | ---: |
| Correct safety | No violation; complete graph | 29,144 |
| Correct conditional progress | No violation; complete graph | 29,144 |
| Carry excluded rows forward | `ExcludedNeverApplied` violation | 105 |
| Pretend pending rows were applied | `ExcludedNeverApplied` violation | 23 |
| Accept late results | `NoLateAcceptance` violation | 138 |
| Execute new work after failure with B excluded | Reachability witness | 198 |
| Execute new work after stop with B excluded | Reachability witness | 207 |
| Resume after crash and launch a replacement | Reachability witness | 280 |
| Discard old success after subsequent work launches | Reachability witness | 1,720 |

Witness configurations deliberately assert that a desired situation never happens. Their expected invariant violations show the situations are reachable; they are not contract failures. Counterexample and witness runs stop early. The crash witness happens to crash after preparation and before launch; the full graph also permits crashes after launch.

[Machine-readable results and hashes](results/summary.json) · [Safety log](results/correct.log) · [Progress log](results/progress.log)

## What this does not prove

The model does not prove the production implementation or arbitrary message/crash counts correct. It assumes atomic Store transitions. Its checker-only `excluded`, `invalid`, and `frozen` histories express properties and do not propose persisted ledgers or resident sets. Physical custody is reduced to one current model request; Bash, Patch, Tool Results, permissions, compaction, and external-state reconciliation need their own rules.

This is not a full recovery algorithm. A new prepared request after explicit resume abstracts replacement of retired uncertain work; exact provider manifests, replay recipes, request budget enforcement, and billing are not modeled. The epoch may conservatively reject old results even where another provider-specific recovery policy could reconcile them.

The model also does not choose delayed HTTP cancellation targeting, cross-consumer authorization, whether external writers may steer workflow-owned Sessions, exact continuation freshness, or workflow operation identity. It assumes durable failure and outcome records remain inspectable after restart; response delivery and acknowledgment loss are covered only by persistence of those facts, not a wire protocol here.

See the [draft contract](../../docs/design/session-terminal-failure.md) for the proposed admission-race and caller-visible rules. A subsequent [relational mapping and SQL fixture](../session-failure-mapping/README.md) supplies the local proposal for existing failure provenance and classifier relations. The [decision and owner handoffs](https://github.com/DivyanshGolyan/onepage/issues/102#issuecomment-5550577434) are now published, and the normative documents are updated locally. The generic failure fence in this model is not a selected production entity; implementation remains outstanding.

## Reproduce

Use the same pinned TLA+ v1.7.4 jar as the earlier study:

```sh
python3 research/session-terminal-model/check.py \
  --jar /tmp/onepage-tla-tools/tla2tools.jar
```

If needed, obtain the jar using the [previous study's instructions](../session-replay-model/README.md#reproduce). The runner verifies its SHA-256, uses one worker and a 512 MiB maximum Java heap, saves all nine results, and fails on unexpected outcomes. Use `--output /tmp/session-terminal-results` to preserve the recorded logs. No provider calls or production Store mutations occur.
