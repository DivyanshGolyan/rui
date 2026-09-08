# Dependency discovery and recovery: industry priors

Publication note, 8 September 2026: this dated research preserves the candidates and open questions at the time of investigation. Subsequent decisions selected asynchronous pull discovery and fresh evaluation after interruption; the current [workflow contract](../architecture/workflows.md#workflow-runs) owns eligibility, discovery and recovery. The [inspection contract](../architecture/workflows.md#run-interface) owns the accepted single-owner capture behavior. Open-decision wording below is historical.

Research checked 7 September 2026. This is decision evidence and a candidate design analysis, not an accepted contract amendment or an implementation claim.

Follow-up: the user subsequently selected the [asynchronous pull loop](../design/workflow-readiness-comparison.md#accepted-choice--asynchronous-pull-loop). The completion-notification protocol analyzed below remains historical candidate evidence; the selected loop discovers current facts without those notifications.

## Question and scope

Can OnePage keep discovery simple: defer a reverse dependency lookup after a Turn result commits, and discover waiting Runs with completed dependencies at Host startup, without persisting a queue of checks?

The user favors independent branch progress, accepts extra evaluations, and prefers memory efficiency and simplicity. No batching window or generic subscription framework is requested. This note builds on [the branch-progress trace](../design/workflow-branch-progress.md) and [workflow data-model research](workflow-data-model-and-wakeups.md).

## Finding

The direction has strong prior art: use durable state to establish work, and notifications to prompt discovery. Startup reconstruction from database facts is also established practice. Neither establishes that OnePage's proposed two trigger points alone are sufficient.

The missing case is publication: an evaluation can report a dependency unresolved in its older snapshot after that result has already committed. The completion lookup may have happened before the new dependency existed. Publishing dependencies must therefore also check present results before allowing the Run to remain asleep.

This is a deduction from OnePage's snapshot/publication model, supported by the notification ordering lesson below. It is not a claim that the referenced systems implement OnePage's exact schema.

## PostgreSQL: establish observation before relying on notifications

PostgreSQL's official `LISTEN` documentation explicitly describes the initial registration race. Its prescription is: commit registration first, inspect database state in a subsequent transaction, then use notifications for later changes. Some initial notifications can describe already-observed state; the documentation treats this duplication as generally harmless. Session termination removes registrations. [LISTEN](https://www.postgresql.org/docs/current/sql-listen.html).

`NOTIFY` documentation describes notifications as a prompt to inspect changed table data. Notifications inside a transaction are delivered only after commit. PostgreSQL offers statement triggers as one way to avoid forgetting notification, but does not require an application-wide event abstraction. Its delivery queue is a real mechanism with resource and transaction behavior. [NOTIFY](https://www.postgresql.org/docs/current/sql-notify.html).

**Transfer:** check the state after establishing the ability to receive subsequent changes. A current-state lookup closes the gap between observation setup and notification delivery. Duplicate prompts are tolerable when eligibility is revalidated.

**Does not transfer:** SQLite does not acquire PostgreSQL's transactional notification semantics by analogy. OnePage's local after-commit handoff must have an explicit owner and failure behavior. PostgreSQL's queue and trigger facilities do not establish that OnePage needs either.

## DBOS: startup recovers from saved workflow facts

DBOS documents single-node startup scanning incomplete `PENDING` workflows. Recovery invokes a workflow with saved inputs; completed steps return saved outputs, and execution resumes at a step without a checkpoint. Distributed recovery needs coordination. DBOS separately documents durable queues that processes poll. [DBOS architecture: workflow recovery and queues](https://docs.dbos.dev/architecture#how-workflow-recovery-works).

**Transfer:** an interrupted process can recover work from database facts instead of recovering its lost in-memory callbacks. This supports the proposed startup discovery direction.

**Does not transfer:** DBOS's documented scan finds interrupted workflows, not OnePage's exact join of current unresolved dependencies with completed results. It does not prove a cheap OnePage startup query, memory bounds, or that runtime notifications may safely be dropped. Its deterministic replay restrictions and deployment model also differ.

## Temporal: when an explicit scheduling record earns its place

Temporal's History Service responds to activity completion by producing work that will advance the workflow. It transactionally updates mutable state and adds History Tasks. History events are appended in a separate persistence step; it would be incorrect to describe all three as one transaction. Queue processors read persisted tasks and deliver work to the separate Matching Service. [History Service: state transitions and consistency](https://github.com/temporalio/temporal/blob/main/docs/architecture/history-service.md#state-transitions).

**Transfer:** committed state must leave the next required consequence recoverable. A durable dispatch task is one way to achieve that when delivery crosses a service boundary.

**Does not transfer:** OnePage's one Host and SQLite owner may derive eligibility directly from relationships and immutable results. Temporal does not establish a need for a separate check queue in this local design. Omitting the queue is justified only if derived discovery covers every transition and remains sufficiently bounded.

## Matklad: state, explicit ownership, and rechecking

In an IDE-protocol discussion, Matklad contrasts edge-triggered commands with level-triggered agreement about current state. The same post warns about notifications losing causal context and ordering. [LSP could have been better: remote procedural state synchronization](https://matklad.github.io/2023/10/12/lsp-could-have-been-better.html#remote-procedural-state-synchronization).

**Transfer:** “this waiting dependency now has a result” survives longer than the signal announcing completion. This is architectural guidance, not a proof of OnePage's database or crash protocol, and not a blanket endorsement of one-way notifications.

Matklad argues that central event-loop mutation makes global invariant checks easier to express, while links between causally related activities can become harder to follow. [The concurrent expression problem](https://matklad.github.io/2021/04/26/concurrent-expression-problem.html).

**Transfer:** named result-commit and dependency-publication handlers sharing readiness logic are a reasonable starting point. A generic hook registry is not needed to obtain explicit event handling.

His account of TigerBeetle describes a single actor with explicit callbacks that assert and recheck state. A single execution thread still permits logical races around asynchronous suspension. [On async mutexes](https://matklad.github.io/2025/11/04/on-async-mutexes.html).

**Transfer:** recheck saved facts when deferred work resumes and when an evaluation publishes. This does not imply adding a mutex, copying TigerBeetle's architecture, or assuming single-owner serialization eliminates stale observations.

## Smallest candidate protocol to validate

These are proposed responsibilities, not selected SQL, production code, or runtime guarantees.

1. **After result commit:** the Host schedules the relevant reverse dependency check without waiting for reevaluation. A direct Session can produce an empty lookup.
2. **At dependency publication:** the Host installs the evaluation's unresolved dependencies and checks them against present results before considering the Run asleep. Retain a dependency that was unresolved in the evaluation snapshot even if it has since completed; that completion is the reason another evaluation is needed.
3. **On Host startup:** inspect current waiting dependencies against saved results to rediscover eligibility. Separately follow the existing recovery rules for interrupted evaluations and newly created Runs; those cases need not already have a published waiting set.
4. **When evaluator capacity becomes available:** discover eligible work that could not run earlier. Finding a Run during completion handling must not be its only opportunity to receive capacity.
5. **Before admitting a new evaluation:** revalidate Run state and use a fresh fixed visibility snapshot. Recovery of an already-admitted generation retains its bound snapshot under its existing recovery rule. Duplicate discovery must not create concurrent evaluation of the same Run or revive a cancelled Run.

A single database owner can order publication and result writes. The intended proof is that either completion observes the dependency already published, or publication observes the result already saved. The exact transaction and scheduler handoff must be specified before claiming this property.

Deferred does not mean free or concurrent: SQL still occupies the owner while it runs. The protocol does not require intentionally collecting completions into a batch.

## Failure and race traces

| Interleaving | Required outcome |
|---|---|
| A completes after the Run publishes its wait for A | Completion discovery finds the dependency. |
| A completes before the wait is published; completion lookup finds nothing | Publication checks current results and discovers A. |
| A completes while an evaluation uses an older snapshot | Publication preserves the need for a later evaluation; the older snapshot does not swallow A's completion. |
| Result commits, then Host crashes before scheduling discovery | Startup joins saved waiting facts with saved results. |
| Dependency publication commits, then Host crashes before scheduling evaluation | Startup discovers the same eligible state. |
| Lookup finds an eligible Run while the evaluator is occupied | Capacity release provides another discovery opportunity; no work is silently discarded. |
| Several completion paths discover the same Run | Admission revalidates current state; no concurrent duplicate evaluation. |
| A was considered by the last successful evaluation | The current unresolved set no longer contains A solely as an already-consumed trigger. |
| Cancellation intervenes | Discovery/admission sees cancellation and does not restart the Run. |
| A deferred notification cannot be handed off while the Host remains alive | Retry or another guaranteed discovery path is required; startup recovery alone is insufficient. |

Startup repairs process loss. It does not repair a missed live notification until a restart actually occurs. A bounded queue that may drop work is therefore not made correct merely by having startup recovery.

## Memory and lookup costs still to establish

- Reverse access should follow dependencies to the original result binding, not the Session's newest answer. Multiple keyed messages may share a Turn result.
- A dependency lookup may find many Runs. Avoid loading all dependent IDs or result payloads into memory at once.
- Deferring one heap-allocated task or retaining one pending Turn ID per completion can accumulate memory if the database owner falls behind. Dropping an ID while live requires a guaranteed fallback. Compare a short synchronous lookup with using bounded existing owner work records or a resumable check; leave that mechanism open until its ownership and cost are established. Do not add a batching subsystem to hide this obligation.
- An index can make an empty targeted lookup cheap, but its existence alone does not bound high fan-out work or the startup join.
- Limiting returned rows does not prove bounded database work. Check the query plan and rows visited on realistic data.
- No new event registry, durable ready flag, check table, or callback retention is demonstrated necessary by these sources. No source demonstrates that existing OnePage relationships alone are already sufficient in production.

The next evidence should be a small model of the listed interleavings and query-plan measurements for zero dependents, one dependent, high fan-out, and many waiting Runs. Production behavior remains unverified.
