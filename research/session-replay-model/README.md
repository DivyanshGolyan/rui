# Session admission, settlement, and replay

> **Historical experiment, published 6 September 2026.** Sources, fixtures, and recorded observations retain their original investigation scope. Historical decision/implementation status is not a current plan or production verification claim.

Checked with TLC on 5 September 2026. This is a small executable design model, not a verification of the OnePage implementation or an acceptance of unresolved interface choices.

The model supports keeping the public interface Session-based. It finds three failures when internal rules are removed: duplicate workflow admission after a crash, an answer taken from later Session activity, and an admitted message stranded at successful settlement. Corrected configurations satisfy the checked properties across their complete bounded state spaces.

## What we modeled

One existing Session, two callers, and two intended messages:

- **W:** one workflow operation with a fixed replay key and fixed content. After a crash, explicit workflow resumption can execute the same operation again.
- **X:** one external caller's keyless submission, after W has been admitted. It can arrive during W's work or after that work settles. X is submitted once; the model gives it no deduplication or automatic retry guarantee.

The provider request captures which messages it includes. Messages arriving afterward cannot retroactively enter that request. Provider return and durable completion application are separate actions. All responses are successful candidate final answers; tools, permissions, failure, and cancellation are excluded.

The principal steps are:

```text
admit message → deliver acknowledgment → observe answer
       ↓
capture provider input → provider returns → commit completion
```

Admission, acknowledgment, provider execution, completion application, and observation can interleave with crash/restart. Model steps are scheduling boundaries, not a proposed new runtime event system.

The Store's admission transaction atomically selects the active/new internal Turn and binds the message and workflow key. Completion application atomically checks remaining messages before declaring success. Those atomic boundaries are explicit assumptions that implementation must preserve. Splitting either transaction would require additional model steps and another check.

Server restart and explicit workflow resume are separate actions. Provider processing in this model remains disabled while the workflow is paused. The model does not choose automatic crash resumption.

## Counterexamples TLC found

### A crash between admission and acknowledgment

With `RecoverAdmission = FALSE`:

1. W commits its message; the acknowledgment has not been delivered.
2. The server/evaluator crashes.
3. The server restarts and the caller explicitly resumes the workflow.
4. Re-executing W appends a second copy of the same workflow operation.

`UniqueWorkflowAdmission` fails. Recovering the original durable binding prevents that second admission. This concerns workflow replay only; it does not add a key or retry contract to direct CLI submissions. It also does not prove exactly-once external execution or billing.

[Full counterexample](results/broken-recovery.log)

### Looking up the latest Session answer

With `PinWait = FALSE`:

1. W is admitted and its work finishes with answer 1.
2. X starts later work in the same Session, which finishes with answer 2.
3. W reads its answer using the Session's latest completed work.
4. W receives answer 2 despite having been admitted to work 1.

`AnswerMatchesAdmission` fails. This can happen without a crash; a delayed first read is enough. Replay makes the same historical-observation requirement relevant after restart.

Recovering W's admission also recovers its private observation target, so W continues to observe answer 1. This needs no public Turn ID or caller-supplied observation cursor. The model assumes each settled Turn has an immutable answer, abstracted as its Turn number.

[Full counterexample](results/broken-wait.log)

### Settling while a newly admitted message remains unprocessed

With `CheckPending = FALSE`:

1. W is admitted and a provider request captures W.
2. X is admitted into the still-active work, after request capture.
3. The provider returns a candidate final answer based on W.
4. Completion application declares the work successfully settled.
5. X remains admitted to settled work without having been processed.

`NoStrandedMessages` fails. The corrected completion transaction notices X and leaves the work active so the next provider request includes it. If completion commits before X's admission instead, X starts new work. The model checks both orders.

This is conditional on allowing messages to join active work. Rejecting active submissions would be a different contract; it is not necessary to expose Turns to avoid the failure.

[Full counterexample](results/broken-settlement.log)

## Checked properties and results

| Configuration | Result | Distinct states |
| --- | --- | ---: |
| Correct rules, up to one crash | All safety invariants pass; full graph explored | 141 |
| Correct rules, up to two crashes | All safety invariants pass; full graph explored | 241 |
| Correct rules, conditional progress, up to one crash | Both temporal properties pass; full graph explored | 141 |
| Re-admit instead of recover | Expected `UniqueWorkflowAdmission` violation | 34 before stopping |
| Observe latest answer | Expected `AnswerMatchesAdmission` violation | 106 before stopping |
| Settle without checking pending messages | Expected `NoStrandedMessages` violation | 31 before stopping |
| Reach a replay after an answer was already observed | Expected reachability witness found | 122 before stopping |

State counts are per configuration, not additive evidence for a larger system. The three broken configurations stop at their first counterexample. The reachability configuration deliberately checks the negation of a desired scenario: its expected violation confirms that completed work can actually be revisited in the model, rather than replay checks passing because replay is unreachable. It is not a failure of the corrected contract.

Additional invariants check valid types, definite assignment of every admitted message to active or settled work, acknowledgments bound to W's admission, separation of active and settled work, and provider snapshots belonging to active work.

The progress configuration checks that every admitted message eventually gets processed, and every active workflow submission/wait eventually reaches an answer. It assumes finitely many crashes and messages, eventual explicit restart/resume, fair scheduling of enabled Host actions, and a provider that eventually returns. It makes no unconditional latency or completion promise for real providers. Deadlock checking is disabled because completed, idle Sessions may correctly have no next action; the separate temporal checks cover the stated progress obligations.

[Machine-readable results and source hashes](results/summary.json) · [Progress log](results/progress.log) · [Replay witness](results/witness-replay.log)

## What the variables mean

`entries`, `processed`, `settled`, `active`, and `turnCount` abstract durable admission and outcome facts. They are not proposed tables. `snapshot`, `phase`, `target`, and `wpc` abstract temporary provider/evaluator state and disappear on crash. Recovery reconstructs the observation target from the original entry.

`observations` is checker-only history retained across crashes so the model can examine previous observations. It is not a proposed durable observation ledger. `externalSent` belongs to the external environment and simply limits X to one submission; it does not implement server-side idempotency.

`processed` means included in a provider request whose successful result was committed. It cannot prove that an LLM understood or obeyed the message. `snapshot` tracks message inclusion, not the complete provider context or transcript.

## Design implications and limits

The smallest supported rules are:

1. Replaying a workflow operation recovers its committed admission.
2. Workflow waiting observes the outcome associated with that admission, even if the Session later advances.
3. Successful settlement and checking for newly admitted messages happen in the same transaction.

These rules fit the proposed Session interface and use internal identities. They add no production memory footprint by themselves. The checker is development tooling; its heap usage is unrelated to OnePage's runtime budget.

This model permits X to join active work so that the concurrency boundary can be tested. It does **not** select a policy permitting external writers into workflow-owned Sessions. If X joins W's active work, both messages can share its eventual answer. Pinning an outcome prevents a later settled answer from replacing it; it does not isolate an active conversation from steering.

The model does not resolve freshness checks on a new workflow continuation, changed replay bindings, concurrent sends through aliased handles, failure with pending messages, cancellation fences, stale provider callbacks, effect-specific crash recovery, storage corruption, or admission of the Session itself. In particular, it discards uncommitted provider state on crash; it is not proof that real late responses are correctly fenced. Provider retries can still cost money.

The earlier JavaScript invocation-order problem is also outside this model. The [existing replay-order probes](../workflow-call-order/README.md) remain its evidence. No claim is made that this model justifies automatic workflow keys.

This is bounded model checking, not a mathematical proof for arbitrary Sessions/messages/crashes or a proof that production code implements these transitions. The implementation needs tests at the exact transaction boundaries above. The next useful separate model is terminal failure/cancellation with accepted but unprocessed messages; that should compare explicit policies rather than inventing a successful outcome for them.

## Reproduce

Requires Python 3, Java, and the pinned standalone TLA+ tool jar. No project dependency or global installation is required. From the repository root:

```sh
mkdir -p /tmp/onepage-tla-tools
curl -fL https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar \
  -o /tmp/onepage-tla-tools/tla2tools.jar
python3 research/session-replay-model/check.py \
  --jar /tmp/onepage-tla-tools/tla2tools.jar
```

`check.py` verifies jar SHA-256 `936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`, uses one worker and a 512 MiB maximum JVM heap, saves logs, and fails if any expected success or counterexample is missing. TLC Version 2.19 from the v1.7.4 release was used. Model-checker temporary state stays outside the repository. The jar remains in `/tmp`, outside project dependencies.

Use `--output /tmp/session-model-results` to keep a new run's logs separate from the recorded results. The `.tla` and `.cfg` files can also be opened in TLA+ tooling directly.

The approach follows [Murat Demirbas's AWS DNS race model](https://github.com/muratdem/TLA-seminar/blob/main/AwsDNSrace/AwsDNSRace.tla): small actions, explicit state, and invariants whose violations produce readable traces. [Lamport's overview](https://lamport.azurewebsites.net/tla/high-level-view.html) explains the distinction between safety invariants, conditional progress, and implementation correctness.
