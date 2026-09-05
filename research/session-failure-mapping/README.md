# Mapping terminal failure to relational authority

> **Historical experiment, published 6 September 2026.** Sources, fixtures, and recorded observations retain their original investigation scope. Historical decision/implementation status is not a current plan or production verification claim.

Prepared and checked 5 September 2026. This is a prospective transaction fixture and a contract mapping. The source still implements the historical Session Ledger (`src/host_store.zig`, `src/session_transition.zig`); the relational redesign is specified by [Replace terminal Sessions and Jobs with relational Sessions, Turns, and Operations](https://github.com/DivyanshGolyan/onepage/issues/52). No production schema or command changed.

## Smallest representation

Use the existing **failed Turn Outcome** as the durable cause making that Turn's remaining unprojected messages inapplicable. Commit the outcome and release of logical Session occupancy together. Preserve all admissions and projections. No `failure_intents`, message phase, withdrawal row, deferred queue, or copied failure reason per message is needed for the covered failure boundaries.

The outcome's existing typed failure payload has two causal forms:

| Where the terminal failure is established | What the existing Turn Outcome records |
| --- | --- |
| A pre-request check establishes that no fitting, compatible request is possible under the bound policy | Typed failure code such as `ResourceExceeded`, identified as a pre-request validation failure. Existing Turn/Context/Conversation/admission facts supply its input frontier; retain only bounded additional evidence that cannot be reconstructed from those facts. |
| An accepted Operation Resolution establishes that the Turn cannot legally continue | Typed failure code and a same-Turn reference to the source Operation/its unique Resolution. The source owns provider evidence; do not copy it into the outcome. |

Do not create a Model Operation, Attempt, Completion, or manifest for a request that was never admitted. Conversely, a failed request that was admitted retains all those real facts and its original projections.

The exact SQL column spelling and closed native union belong to the relational implementation. An Operation reference must be constrained to the same Turn and an existing accepted Resolution. A non-null arbitrary error code is not sufficient authority to fail a Turn.

## Restrict failure to a settlement boundary

A failed Operation does not automatically terminate its Turn. Tool errors/denials can become ordinary Tool Results. Provider-confirmed context overflow can lead to compaction. Direct model interruption can allow independently admitted input to continue. Retryable Completions leave their Operation unresolved with retry eligibility. Each retains its existing classifier rule.

The new failure branch is legal only when:

1. The same bounded canonical snapshot establishes a definitive reason that this Turn cannot continue under its existing contract and allowed recovery/compaction policy.
2. No unresolved Operation, unresolved admitted effect, actionable permission, unpublished required Tool Result, or applicable Completion can still alter semantic meaning.
3. The only otherwise-blocking input is the set of still-unprojected User Messages, if any.

The failure transaction inserts the unique failed outcome. That insertion itself makes the remaining messages inapplicable. The classifier must not first require them to be inapplicable before it may insert the outcome; that would preserve the circular dependency identified in [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102).

The successful-outcome branch still requires no applicable pending message. Cancellation still uses the existing Run Cancellation Intent while effects drain. Standalone cancellation targeting is a separate interface decision. A request to abort work before a safe failure-settlement boundary uses the cancellation contract; this mapping does not introduce an early generic failure intent.

A known failure on one child cannot erase obligations owned by another child. Already-admitted effects settle or reconcile under their existing rules. Physical resource cleanup remains owned by Physical Custody; a volatile cleanup flag is not an additional SQLite authority. Outcome settlement requires semantic closure, not a claim that every remote process has physically stopped.

## Transaction shape

```text
BEGIN IMMEDIATE
  Load the bounded canonical Decision Snapshot.
  If the Turn already has an Outcome, return its immutable fact.
  Respect committed cancellation authority and existing effect obligations.
  Classify whether the Turn can legally continue.
  If a definitive failure is established and other semantic obligations are clear:
    insert its one failed Turn Outcome with typed causal provenance;
    release logical Session occupancy in the same transaction.
COMMIT
Deliver acknowledgment/inspection only after commit.
```

The classifier does not update messages, create Conversation Entries for them, or emit another model request. Preparatory scratch or out-of-transaction estimates are not authority: the transaction must validate their exact canonical inputs before using the decision. No transaction spans provider I/O.

Failure before commit leaves pending messages pending and the old work nonterminal. Failure after commit but before response delivery leaves a complete inspectable outcome and stable not-applied facts. Reconstructing that result after reopen does not rerun the model or recompute whether the old decision would still be chosen under today's ambient settings. This is server reconstruction, not an idempotency key added to direct CLI messages.

Storage failure is distinct: if the transaction cannot commit because SQLite is full, unavailable, or corrupt, report the infrastructure failure. Do not claim a durable failed outcome, occupancy release, or not-applied disposition that was never committed.

## Derived message meaning

For a message under Turn T:

```text
if its unique Conversation projection exists:
    applied (provider consumption is not implied)
else if T has a failed Outcome:
    not applied, caused by that Outcome
else if T is covered by committed cancellation authority:
    not applied, caused by that cancellation
else if T is eligible to accept/process input:
    pending
```

The failed outcome is immutable, so a later Turn cannot change this answer. Current-Turn context preparation selects that Turn's applicable unprojected rows; later context derives from canonical Conversation and accepted provider replay authority. It never sweeps up old unprojected admissions from every Turn in the Session.

Both serialized message/failure orders are valid: a message committed first remains under the old Turn and becomes not applied; a Session-current message committed after outcome/occupancy release initiates new work and is applied as its initiating input. An internal request bound to the old Turn is rejected. Cancellation can additionally have a fenced-but-not-yet-terminal interval; ordinary failure in this mapping does not need that interval.

## SQL fixture evidence

[probe.py](probe.py) creates a small temporary SQLite schema using the prospective ownership boundaries. It is deliberately not a migration or a replacement production schema. Trigger checks demonstrate one active Turn, immutable admission targeting, projection/admission fencing after outcome, resolved Operations/permissions before terminality, and a stricter pending-input gate for success than for failure. Production immutability, complete effect-frontier checks, indexing, content storage, authority, and resource bounds are not implemented by this fixture.

Eight scenarios pass:

1. Admission precedes failure: message content survives, no projection is invented, and new Session work excludes the old pending row. Late projection/admission/Operation creation on the failed Turn is rejected. A pre-request failure creates no fake Operation or Resolution.
2. Failure precedes a Session-current message: the message initiates new work.
3. An unresolved Operation blocks failure; an accepted terminal model Resolution can then source it. Contradictory late Resolution insertion is rejected by uniqueness.
4. Tool error and recoverable context overflow do not independently authorize terminal failure.
5. An actionable permission blocks terminal failure.
6. Transaction rollback leaves both the original connection and a reopened connection seeing pending input and no outcome.
7. Lost acknowledgment after commit: a reopened connection recovers the same single outcome and not-applied facts; a conflicting outcome is rejected.
8. Successful settlement remains prohibited with pending input.

The two race orders are tested as explicitly serialized schedules. Rollback/reopen is tested; process termination, power loss, SQLite I/O fault injection, actual network races, provider semantics, and workload performance are not. The checks are not a formal refinement proof from the TLA+ model to production SQL.

Run from the repository root:

```sh
python3 research/session-failure-mapping/probe.py
```

[Recorded results](results.json) use SQLite 3.53.4. All fixture databases live in temporary directories and are deleted afterward. No model calls occur.

## Relation to the TLA+ studies

The [terminal model](../session-terminal-model/README.md) deliberately separated a generic failure decision, cleanup, and finalization. This mapping narrows ordinary failure to a boundary where the semantic obligations are already resolved, so failure and finalization can commit together. The prototype `fence = failed` was an abstraction, not evidence that a distinct production failure-fence relation was necessary. The cancellation branch retains the earlier intent where it is needed.

The model's safety obligations remain relevant: preserve unprojected input, prevent silent application in later work, keep outcomes immutable, and reject unauthorized late results. The SQLite fixture checks the proposed atomic failure mapping directly. It does not broaden the model-checker's 29,144-state claim to this different schema or to arbitrary workloads.

## Contract changes prepared for owning issues

| Owner | Required amendment |
| --- | --- |
| [Relational Sessions, Turns, and Operations](https://github.com/DivyanshGolyan/onepage/issues/52) | Give failed outcomes typed pre-request or same-Turn Resolution provenance. Add the terminal-failure classifier branch that permits unprojected messages once other obligations are clear; derive their inapplicability from that outcome. Keep success strict. Cover both commit orders, rollback, and acknowledgment loss. |
| [Session context and exact requests](https://github.com/DivyanshGolyan/onepage/issues/59) | Project only applicable messages of the current Turn. An aborted pre-request transaction creates no projection, manifest, or Operation. Preserve real projections after an admitted request fails. Exclude old failed/cancelled pending rows from later requests. |
| [Model Context compaction](https://github.com/DivyanshGolyan/onepage/issues/57) | If bounded preparation establishes that compaction cannot yield a legal request, settle `ResourceExceeded` directly with pending input intact. A rejected admitted request remains distinct: its Resolution and already-applied input survive. Do not classify every overflow or compaction error as an immediate Turn failure. |
| [Host Runtime API and inspection](https://github.com/DivyanshGolyan/onepage/issues/39) | Expose applied/pending/not-applied admission facts and causal outcome without equating projection with consumption. Keep exact unapplied content inspectable through bounded reads; define selection so every poll need not replay all history. Preserve Session-current admission ordering and direct CLI's no-key contract. |
| [SQLite command-work limits](https://github.com/DivyanshGolyan/onepage/issues/95) and [provider retry/effect budgets](https://github.com/DivyanshGolyan/onepage/issues/91) | Bound canonical loading, preparation evidence, and failure transactions; establish when retry/compaction is exhausted. Numerical policies remain with these owners. |

Local normative amendments cover the User Message/terminality and compaction failure sections of `ARCHITECTURE.md`, causal failure in the `CONTEXT.md` Turn Outcome definition, not-applied input and explicit resubmission in `PRODUCT.md`, and required transaction fixtures in `VERIFICATION.md`. Existing cancellation authority remains unchanged. The [accepted decision](https://github.com/DivyanshGolyan/onepage/issues/102#issuecomment-5550577434) and owner issue amendments are now published on GitHub. The owning normative documents and linked design record have been updated locally but remain uncommitted. Production implementation is outstanding; the study evidence retains the limits stated above.
