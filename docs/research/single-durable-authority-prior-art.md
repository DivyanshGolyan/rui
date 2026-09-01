# Single durable authority: industry prior art

Research date: 2026-09-01

This note asks whether OnePage needs an append-only application ledger at all. It is design research,
not a normative decision. It deliberately did not assume that the former Session Ledger, encoded
Core State, Semantic View, or recovery replay should survive a redesign. It predates ADR-0019's
vocabulary decision: its proposed `Job` responsibility is now the canonical **Turn**. `Job` below is
historical wording, not a second planned domain entity.

## Recommendation

Use **SQLite relations plus a narrow external-effect journal as OnePage's single durable semantic
authority**. Do not retain a universal Session event log.

In this model:

- SQLite rows are the state. A Session row identifies the current Conversation head. A Job row holds
  its immutable admission data and an initially absent, write-once Outcome. Conversation Entries,
  Operations, Attempts, and immutable content remain durable domain records.
- A row's shape or the existence of a related row answers lifecycle questions. There is no separately
  encoded Job phase, Core continuation, ledger head, or materialized semantic index that can disagree
  with those records.
- Before OnePage starts an external effect, it durably inserts its exact Attempt. After the effect, it
  records Completion evidence on that Attempt. Semantic admission then updates the Operation and
  Conversation or Job Outcome in one SQLite transaction.
- An Attempt with no Completion after a crash is the irreducible uncertain-effect boundary. Recovery
  is effect-specific. OnePage retries only when the operation is known safe or the remote system
  honors the same idempotency key; otherwise it records uncertainty or reconciles observable state.
- Current-state caches and observer views may exist only as disposable process-local accelerators.
  Opening a dormant Session performs targeted indexed reads; it does not replay its history.

This keeps append-only history only where history is itself part of the product: Conversation Entries,
Attempts and their evidence, explicit requests and decisions, and immutable content. "Append-only" is
not a universal persistence policy.

The recommendation is an inference from the sources below, not a claim that the cited systems use
this exact design.

## The fundamental tension

OnePage has three separate durability problems that the current ledger makes look like one:

1. **Atomic local state change.** A Job admission may need to create a Job, occupy its Session, append
   a User message, and advance the Conversation head together.
2. **Recovery around a non-transactional external effect.** SQLite cannot atomically commit with a
   model provider, shell process, or mutable Workspace.
3. **Historical reconstruction.** Some systems need to replay arbitrary user code or answer temporal
   queries from a complete event history.

SQLite already solves the first problem. An Attempt/Completion protocol is needed for the second.
Only the third requires a universal event log. OnePage needs durable Conversation history and effect
evidence, but V1 does not require point-in-time reconstruction of every internal state, replication from
semantic events, or deterministic replay of the Session implementation itself.

A second distinction matters just as much:

- A **database journal** is SQLite's physical mechanism for making transactions atomic across crashes.
- An **effect journal** is application data proving that OnePage admitted an external Attempt and what
  evidence later arrived.
- An **event-sourcing log** is an ordered application history from which all current semantic state is
  reconstructed.

These are not interchangeable. Keeping SQLite's physical journal and a small effect journal does not
imply retaining an event-sourced Session architecture.

## Prior 1: SQLite already supplies the local commit protocol

### Facts

SQLite defines atomic commit as all changes in one transaction occurring or none occurring, including
when a transaction is interrupted by an operating-system crash or power failure
([Atomic Commit in SQLite](https://www.sqlite.org/atomiccommit.html#introduction)). A transaction can
therefore update several related tables as one old-or-new state rather than asking the application to
recover a partially published semantic transition
([transaction documentation](https://www.sqlite.org/lang_transaction.html)).

SQLite can enforce application structure at the storage boundary with `PRIMARY KEY`, `UNIQUE`,
`NOT NULL`, `CHECK`, and foreign-key constraints
([CREATE TABLE](https://www.sqlite.org/lang_createtable.html),
[foreign keys](https://www.sqlite.org/foreignkeys.html)). A unique partial index can enforce uniqueness
only for rows satisfying a predicate, such as at most one Job whose Outcome is absent for a Session
([unique partial indexes](https://www.sqlite.org/partialindex.html#unique_partial_indexes)). `STRICT`
tables make declared column types mandatory instead of advisory
([STRICT tables](https://www.sqlite.org/stricttables.html)).

### OnePage implication

If one SQLite transaction validates the expected Conversation head, inserts or updates the canonical
domain rows, and exposes the next effect only after commit, an application-level transaction record does
not add crash atomicity. It adds value only if its ordered historical payload is itself required.

The schema should make invalid combinations hard to represent:

- a partial unique index can enforce one unfinished Job per Session;
- `UNIQUE(operation_id, ordinal)` can make Attempt order exact without a Session-global sequence;
- a write-once nullable Outcome on the Job row can define terminality without a second status enum;
- a write-once response on an Interaction Request or permission row can define open versus answered;
- a write-once Completion on an Attempt can define pending evidence without a separate Inbox status;
- foreign keys can bind every Operation, Attempt, result, and Conversation Entry to its actual owner.

This trusts the database primitive instead of replaying a second application record to prove the same
commit happened.

## Prior 2: Cloudflare Durable Objects use durable state without requiring an application event log

### Facts

SQLite-backed Durable Object storage is transactional and strongly consistent. Cloudflare's API treats
operations inside a storage transaction as one commit, and its synchronous transaction callback rolls
back if the callback throws
([SQLite-backed storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/#sql-transactions)).

Cloudflare's output gate delays outgoing messages until preceding storage writes are confirmed; if a
write fails, the messages are discarded. This makes "persist before publish" a runtime invariant rather
than an application-authored event protocol
([Durable Objects: Easy, Fast, Correct](https://blog.cloudflare.com/durable-objects-easy-fast-correct-choose-three/#part-2-output-gates)).

Durable Objects may be hibernated or evicted, at which point their in-memory state is discarded. The
official lifecycle guidance says important state must therefore be persisted, and a later invocation
recreates the object
([Durable Object lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/#durable-object-lifecycle-state-transitions)).

### OnePage implication

The transferable ideas are narrower than the Durable Object runtime:

1. serialize one logical owner;
2. commit necessary durable state before exposing an effect or acknowledgement;
3. treat in-memory state as an optional cache that can disappear completely.

None requires a second semantic log above SQLite. The Host Runtime can provide its own small output gate:
the transaction returns a typed next action only after commit, and only then may Harness dispatch it.
Dormant Sessions need no retained object because their canonical rows are sufficient to reconstruct the
next decision.

## Prior 3: logs earn their cost when the system replays user code

Temporal, Azure Durable Functions, Restate, and DBOS are strong evidence **for** journals in their own
problem domain. They are also evidence that the journal is not free.

### Temporal and Azure Durable Functions facts

Temporal keeps a complete durable Event History. On replay, a worker reruns Workflow code and checks the
Commands it generates against that history
([Temporal Workflow Execution](https://docs.temporal.io/workflow-execution#replays),
[Event History](https://docs.temporal.io/encyclopedia/event-history)). This requires deterministic
Workflow code: external calls and other non-deterministic operations must be Activities, and changing
command-producing Workflow code requires versioning discipline
([Temporal Workflow Definition](https://docs.temporal.io/workflow-definition#deterministic-constraints)).
Temporal recommends idempotent Activities because an Activity that has not recorded completion can be
executed again
([Temporal Activities](https://docs.temporal.io/activities)).

Azure Durable Functions similarly stores orchestration history and replays that history into the
orchestrator function. Its documentation explicitly notes that loading and replaying full histories can
create memory pressure, and that keeping executions resident is a cache optimization that avoids replay
at the cost of memory
([Azure Storage provider](https://learn.microsoft.com/en-us/azure/azure-functions/durable/durable-functions-azure-storage-provider#history-table-for-orchestration-events)).

### Restate and DBOS facts

Restate records each SDK-visible operation and its result in an execution journal. On failure it invokes
the handler again and uses recorded results instead of re-executing completed actions
([Restate key concepts](https://docs.restate.dev/foundations/key-concepts#durable-execution),
[request lifecycle](https://docs.restate.dev/guides/request-lifecycle#6-replay-journal)).

DBOS checkpoints Workflow inputs and step outputs in its system database. Recovery calls the Workflow
again and substitutes a stored output at each completed step until it reaches the first uncheckpointed
step. DBOS therefore also requires deterministic Workflow code and idempotent Steps
([DBOS architecture](https://docs.dbos.dev/architecture#how-workflow-recovery-works)). When application
data uses the same database engine, DBOS can atomically commit the application transaction and its
durability record; it does not create a separate transaction-completion table for that case
([DBOS transactions](https://docs.dbos.dev/golang/tutorials/transaction-tutorial#transactions)).

### OnePage implication

These systems use a history because their product is to replay a general-purpose function while hiding
the persisted state machine. That buys an ergonomic programming model but introduces deterministic-code,
history-size, replay, checkpoint, and code-versioning machinery.

OnePage's **Workflow Evaluator** may need a DBOS/Temporal-like checkpoint contract at the Run layer: it
reevaluates caller-supplied JavaScript from an immutable Visibility Snapshot. The **Session lifecycle**
is different. It is already an explicit state machine implemented by OnePage, not arbitrary customer
code whose local variables must be reconstructed. Persisting its current domain relations directly is
the simpler representation.

The broader event-sourcing guidance agrees with that selection rule. Microsoft's architecture guidance
calls event sourcing a complex, constraining pattern and recommends traditional data management for
most systems unless auditability or historical reconstruction justifies the cost
([Event Sourcing pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing)).

## Prior 4: a state machine does not imply event sourcing

### Facts

Erlang/OTP describes an event-driven state machine as:

```text
State(S) x Event(E) -> Actions(A), State(S')
```

`gen_statem` keeps the current State and Data and returns actions plus the next state from each callback.
It recommends the abstraction when state-specific event handling, postponement, inserted events, or
state-entry actions are useful; simpler machines can use `gen_server`
([Erlang `gen_statem`](https://www.erlang.org/doc/system/statem.html)). The state-machine abstraction
itself specifies no event store.

TigerBeetle makes the opposite, deliberate choice: as a replicated state machine, it calls its immutable,
hash-chained append-only prepare log the ground state, while its LSM trees contain derived indexes
([TigerBeetle architecture](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/ARCHITECTURE.md)).
Its synchronous `commit` performs deterministic accounting after I/O has been prefetched.

### OnePage implication

The contrast gives a useful decision test:

- A pure transition function can improve clarity and testing without being the durable representation.
- A total ordered log is justified when replication, consensus, full replay, temporal reconstruction, or
  audit is a first-class requirement.

OnePage is a single-host V1 whose database already owns crash recovery. Its pure reducer can remain a
small implementation technique if useful, but its result should be ordinary relational mutations rather
than an encoded second state machine. TigerBeetle's log is evidence for logs under replicated-state-machine
requirements, not evidence that every crash-safe state machine needs one.

## Prior 5: external effects require a journal, but not a universal ledger

### Facts

The transactional outbox pattern writes application state and an outbound intent in the same database
transaction, then relays that intent later. Delivery can still happen more than once, so the consumer
must be idempotent or deduplicate by identity
([AWS transactional outbox guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html)).

Server cooperation can make a retry safe. Stripe stores the first result associated with an idempotency
key and returns it for a matching retry; it rejects reuse with different parameters
([Stripe idempotent requests](https://docs.stripe.com/api/idempotent_requests)). This works because the
remote participant owns durable deduplication. A local caller cannot manufacture that guarantee for an
arbitrary shell command or API.

### OnePage implication

The minimal crash protocol is:

```text
SQLite transaction: insert exact Attempt
        |
        v
external provider / Bash / patch work
        |
        v
SQLite transaction: record exact Completion evidence
        |
        v
SQLite transaction: admit the semantic Result and next domain state
```

This admits the unavoidable window between the external effect and Completion persistence. The correct
response depends on the effect:

- reuse a provider idempotency key when the provider actually promises deduplication;
- allow a model retry only under the explicit possible-duplicate/billing policy;
- do not blindly replay Bash after an uncertain completion;
- reconcile a patch against observable preimage/postimage state;
- expose unresolved uncertainty as typed data rather than inventing exactly-once execution.

Only Attempt and Completion evidence must be journal-like. A total order of unrelated Session facts does
not narrow this external failure window.

## Authority models compared

| Model | Durable authority | Appropriate when | Complexity paid | What OnePage could delete |
|---|---|---|---|---|
| Full event sourcing | One ordered immutable event stream; current state is derived | Point-in-time reconstruction, audit, replication, or deterministic replay of user code is a product requirement | Event schemas, replay reducer, snapshots, projections, history bounds, versioning | If chosen cleanly, delete authoritative relational state and keep only rebuildable projections; the current mixed model must not survive |
| Relational current state | Normalized rows, constraints, and atomic transactions | The domain is an explicit state machine and current state is the product | Careful schema design and transactional command handling | Session Ledger, ledger codec, replay cursor, Core checkpoint, Semantic View reconstruction, fact-prefix and head-sequence plumbing |
| Checkpointed code replay | Inputs plus ordered step outputs, as in DBOS | Caller code should look like an ordinary durable function | Deterministic step order, checkpoint identity, code versioning, replay runtime | Hand-written lifecycle state, but only by replacing it with a workflow engine; this is not a simplification for Session |
| **Relational state plus effect journal** | Current domain rows; immutable history only for Conversation and external-effect evidence | Explicit local state machine with non-transactional external effects | Attempt/Completion protocol and effect-specific recovery | Everything in relational current state, plus Completion Inbox consumption state and duplicate lifecycle caches; retain only effect evidence |

The final row is the recommendation.

## Proposed OnePage shape

This is illustrative rather than a frozen schema.

### Durable rows

- `session`: identity, Workspace binding, and authoritative current Conversation head.
- `job`: immutable admission descriptor plus write-once Outcome fields. `Outcome IS NULL` means unfinished;
  a unique partial index on `session_id WHERE outcome IS NULL` enforces one active Job.
- `conversation_entry`: immutable parent-linked User, assistant, Tool Call, and Tool Result history.
- `operation`: immutable typed model or action descriptor, exact provenance, and write-once admitted Result.
- `attempt`: immutable dispatch identity and ordinal plus write-once Completion evidence. An Attempt with
  no Completion is precisely the crash-recovery question.
- `interaction_request` and permission request: immutable prompt/binding plus a write-once answer or
  decision. Absence means open; no parallel status field is necessary.
- `content`: immutable bytes and their exact typed digest, in SQLite.
- Run and Job membership rows required by the Workflow layer.

The schema can use nullable write-once columns or one-to-one child rows. Choose whichever makes SQL and
constraints clearer; do not persist both.

### One transaction boundary

A deep Session/Job module accepts a typed command, performs the bounded indexed reads needed to decide
it, and commits the exact relational changes. It returns one of a small set of consequences only after
commit:

```text
progressed
dispatch Model Attempt
dispatch Action Attempt
input required
permission required
terminal Job Outcome
```

The returned consequence is not authority. If the process dies before acting on it, a later drive query
derives the same next work from the rows.

### Recovery queries, not replay

On open or drive, query only the active Job and its unresolved relations:

- Job Outcome present -> terminal;
- unanswered Interaction Request -> input required;
- permission request without a decision -> permission required;
- completed Attempt whose Operation has no admitted Result -> semantic admission;
- Attempt without Completion -> effect-specific recovery;
- latest Conversation head without its next model Operation -> admit the next model Attempt.

These are indexed existence checks over bounded live state. Completed Conversation and Attempt history
remains available without becoming activation memory.

## What this lets OnePage remove

The redesign should aim to delete, not adapt, the following current concepts:

- the universal Session Ledger and generic semantic-fact union;
- ledger sequence, ledger head, fact prefix, and bounded ledger replay protocol;
- encoded Core continuation as durable authority;
- `ResidentState` and `SemanticView` as reconstructed copies of durable state;
- fresh-versus-restored advancement and `initial_job_advanced`;
- `last_core_sequence` and any `operation_sequence` whose only purpose is ledger correlation;
- Job state or final-result caches in Harness;
- a separate Completion Inbox identity, consumed flag, resident index, and historical ledger scan. An
  Attempt's Completion evidence is itself the durable inbox; an Operation Result records admission;
- duplicated cancellation state when cancellation and terminal Outcome are one transaction;
- separate normalized Job fields that are not mechanically the same canonical Job row.

Some current names may survive as APIs, but not as independent state owners. Harness should own only
bounded volatile custody and dispatch. Lifecycle should decide no durable fact outside the Session/Job
transaction module. Storage Owner should execute the SQL without requiring a second encoded transition.

## What must remain

Removing the ledger does not justify removing the real safety boundaries:

- durable Attempt admission before any external effect;
- exact descriptor, provenance, digest, and idempotency binding;
- effect-specific recovery and explicit uncertainty;
- provider Completion capture before semantic admission;
- atomic import of immutable content with its first durable reference;
- one-writer fencing and idempotent command identities;
- one nonterminal Job per Session;
- bounded parser, transport, validator, and activation memory;
- Conversation history and immutable Job Outcomes;
- crash failpoints before and after every SQLite commit and external effect boundary.

These are product requirements. The Session Ledger is only one implementation of them.

## Derived data without a second system of record

A duplicate representation is acceptable only when all four conditions hold:

1. it serves a measured query or memory need;
2. its source is unambiguous;
3. it is updated mechanically in the same transaction or can be discarded and rebuilt;
4. no correctness decision trusts it when it disagrees with its source.

Ordinary SQLite indexes meet these conditions. A process-local cache can meet them if eviction is always
safe. An observer snapshot can meet them if it names the committed source version. A second durable
state machine that callers can independently update does not.

If future measurement proves a direct query too expensive, add the smallest derived column or table for
that query and update it in the owning transaction. Do not pre-emptively restore a general projection
framework.

## Decision test for any future application log

Add a total application event log only if OnePage acquires a concrete requirement that cannot be met by
its relational state and effect evidence, such as:

- point-in-time reconstruction of all Session semantics;
- multiple independently evolving read models that must rebuild from one event source;
- deterministic replay of arbitrary Session code, not just Workflow JavaScript;
- replication or consensus over semantic commands;
- a regulatory audit requiring every internal transition rather than Conversation and effect evidence.

If that day comes, the log should become the sole authority and relational rows should become disposable
projections. OnePage should not return to two writable representations.

## Verification plan for the redesign

1. **Schema invariants:** property-test one active Job, immutable identity reuse, write-once Outcome,
   request decision, Completion, and Result fields, exact foreign-key provenance, and conflict behavior.
2. **Reference model:** compare each typed command against a small in-memory state-machine model, but
   persist only the relational result.
3. **Crash matrix:** kill before and after Attempt admission, external dispatch, Completion publication,
   semantic admission, Conversation advance, and Job Outcome. Reopen with direct queries and prove the
   expected consequence without ledger replay.
4. **Effect recovery:** count real tool executions and prove idempotent, uncertain Bash, patch
   reconciliation, and possible-duplicate model behavior independently.
5. **Dormant density:** create 10,000 and then 100,000 Sessions with no active Job; assert no
   per-Session process object, handle, cache entry, or replay allocation survives.
6. **Deletion gate:** compare source concepts and lines removed, not only tests added. A successful
   redesign should make `session_transition.zig` and ledger recovery disappear rather than wrap them.

## Final conclusion

Crash consistency does not require event sourcing. OnePage needs one transactional database, a small
explicit state machine, and durable evidence around effects that cannot join the database transaction.
SQLite should be trusted to make local semantic changes atomic; the application should persist the
domain rows that answer its actual questions. History should be stored once where history has product
meaning, not copied into a universal ledger for the purpose of reconstructing state that SQLite already
stores.

The simplest credible V1 is therefore:

> **SQLite is the semantic authority. Conversation and effect evidence are durable domain history.
> Everything else is derived on demand or volatile.**
