# Workflow data model and wake-ups: industry prior art

Research checked 7 September 2026. Decision evidence only: no policy is selected, no production behavior is certified, and no implementation is changed.

## Finding

Design the observable workflow behavior, durable identities and state transitions together, then derive eligibility and discovery from them. A database schema alone does not describe how progress survives a crash; a callback alone does not describe what progress means. Memory efficiency depends on the lifetime and population of resident objects as well as the durable model.

The most useful industry distinction is between **a saved result or pending obligation** and **the mechanism that gets a worker's attention**. Restate makes results retrievable after their producer finishes; Temporal persists scheduling obligations with current state; DBOS recovers from database checkpoints; Solid Queue discovers ready records through database polling. These are different mechanisms, with transferable lessons below. They do not establish a need for OnePage to acquire a distributed event system.

## Current OnePage starting point

The following is accepted design, not an implementation assessment:

- A Run-local key binds a Session operation and its canonical inputs. A keyed message keeps its original admission/result binding even as the Session moves on. Several messages may share one Turn outcome. See [Workflow Runs](../../ARCHITECTURE.md#workflow-runs) and the [keyed Session amendment](../adr/0014-use-ephemeral-quickjs-for-workflow-evaluation.md#accepted-amendment--keyed-session-operations).
- Evaluation starts again from source against an immutable Visibility Snapshot, reports its blocked set, and exits. No JavaScript heap or Promise continuation survives the barrier. Deterministic joins are supported; `Promise.race` and `Promise.any` are excluded. See [Workflow Runs](../../ARCHITECTURE.md#workflow-runs).
- One evaluation lifecycle runs at a time per Host, including publication and cleanup. The wording in [Choose workflow reevaluation eligibility and wake-ups](https://github.com/DivyanshGolyan/onepage/issues/114) calling serialization merely a recommendation is stale relative to [Disposable evaluator construction](../../ARCHITECTURE.md#disposable-evaluator-construction). Eligibility remains unresolved.
- Operations own current execution facts and an optional immutable Resolution value. Do not introduce new Attempt/Completion/Resolution entities through this research. See [ADR-0026](../adr/0026-let-operations-own-current-execution-and-final-results.md).

A workflow-facing Session operation and an internal effect Operation should not be assumed to have a one-to-one mapping. The accepted Session contract already permits multiple keyed messages to share work. Finalizing that relationship is part of modeling the behavior.

## What established runtimes teach

### Restate: identify the value independently of the waiting execution

Restate distinguishes repeated signals, one-shot awakeables and workflow promises. A workflow promise is addressed by workflow key and name; it resolves once and can be read repeatedly by multiple handlers during retention. Signals instead preserve successive resolutions until consumed. All survive retries/restarts, and a waiting invocation can suspend. [Signals and external events](https://docs.restate.dev/develop/ts/external-events).

Its notification example explicitly allows late subscribers to receive an already-resolved result. [Notify when ready](https://docs.restate.dev/ai/patterns/notify-when-ready).

Restate records durable actions before applying their consequences, records completion before returning results/signaling completion, and rejects stale attempt epochs. Its architecture includes a replicated log, partition routing and derivative RocksDB state. [Architecture](https://docs.restate.dev/references/architecture).

**Transfer to OnePage:** a result is a retrievable fact, not a one-time callback delivery. A waiting Run can refer to existing result ownership rather than owning another payload copy. Do not copy Restate's distributed log/partition machinery. Suspension documentation does not establish a whole-server memory bound or zero resident metadata per waiting invocation.

### DBOS: distinguish messages, current values and replayed observations

DBOS messages persist in database queues; receiving consumes the next message for the selected topic. Events are mutable workflow-scoped key/value pairs. Crucially, an event value read inside a workflow is checkpointed so recovery uses that observed value even if the event later changes. [Workflow communication](https://docs.dbos.dev/python/tutorials/workflow-communication).

DBOS records workflow inputs and step outputs. Single-node startup discovers interrupted `PENDING` workflows; recovery runs workflow code using completed step results. Durable queues are polled and can limit execution concurrency. [Architecture](https://docs.dbos.dev/architecture).

**Transfer to OnePage:** distinguish reusable Session identity from the particular answer observed by a request. Current Session state cannot substitute for that answer. Persisted recovery and queue concurrency limits alone do not prove memory independent of suspended workflow count; the reviewed DBOS pages establish no such bound. OnePage must retain its explicit disposable-evaluator contract.

### Temporal: make the scheduling consequence survive the state change

Temporal's History Service processes inputs into state transitions and internal scheduling tasks. Activity completion can create a Workflow Task through a Transfer Task. Current mutable state and History Tasks are updated transactionally; the processor later delivers work to Matching. History events use a separate persistence step, with validity tied to committed mutable state. Thus it is inaccurate to describe the whole history/state/dispatch path as one transaction. [History Service architecture](https://github.com/temporalio/temporal/blob/main/docs/architecture/history-service.md#state-transitions).

Its queue processors read persisted tasks, while recently accessed mutable state is cached. The documented design addresses multiple shards and services. [History Service architecture](https://github.com/temporalio/temporal/blob/main/docs/architecture/history-service.md).

**Transfer to OnePage:** a committed result must leave enough durable evidence to rediscover its next consequence. A separate persisted task is one solution, not a necessity when eligibility can be derived within one SQLite owner. Do not import event-sourced history, Matching or shard ownership to solve local wake-ups. These docs provide no OnePage-equivalent memory guarantee.

### Solid Queue: waiting and ready work can live in database relations

Solid Queue supports SQLite, PostgreSQL and MySQL. Workers read ready executions; dispatchers move due scheduled executions into readiness. Polling intervals and dispatcher batch sizes are explicit, and its polling queries select job IDs with a limit. The README cautions that SQLite is intended for smaller applications. [Solid Queue](https://github.com/rails/solid_queue#workers-dispatchers-and-scheduler), [polling queries](https://github.com/rails/solid_queue#queues-specification-and-performance).

**Transfer to OnePage:** bound each discovery turn and load payload only after choosing work. Separate ready/scheduled tables are a concrete option, not proof that OnePage needs duplicated readiness facts. Solid Queue is job-queue prior art, not evidence for OnePage's replay, shared-result or whole-Host latency guarantees. Its polling defaults and process model should not become OnePage policy by analogy.

## Concrete examples from our saved Claude Code workflows

Use the [local workflow audit](local-claude-workflow-usecases.md) as the workload source. That audit inspected saved scripts and execution records on 5 September 2026; this section reuses its findings rather than claiming a fresh scan or rerun. Its historical API sketches and numeric limits are not current OnePage requirements. The cases below are design inputs, not proof of equivalent OnePage scheduling or tool compatibility.

| Saved workflow | Observed shape | Design question it exercises |
| --- | --- | --- |
| `scan-removal-guard-tests` | Each scanner returns findings that determine its own verifier calls; the audit records two explicit resumes. | Can one scanner's dependent verifiers become eligible while other scanners remain unfinished? After restart, how do we recover the same finding-to-verifier identities? |
| `writing-for-agents-review-agent-dir` | Review each group, then conditionally verify that group's findings. | Distinguish a group's local dependency from the final join across all groups; an empty finding list must complete without manufacturing verifier work. |
| `unnecessary-complexity-audit` | Eight region finders, then deduplication/ranking, selected skeptics, and final synthesis. | Which stages genuinely need all preceding results before deciding what work to create? Preserve independent reviewer context and stable selection. |
| `clear-no-runtime-typeof` | Parallel workers receive disjoint file lists in one worktree. | Separate independent conversations from shared filesystem effects; model worker outcomes and cancellation without implying filesystem isolation. |
| Sheet-dossier workflows | Independent finding workers write assigned rows and report successes, missing results and failures. | Preserve successful branches and exact item identity; distinguish saved workflow results from uncertainty about a remote write. Source-tool availability remains a separate V1 compatibility question. |

### First trace: one scanner finishes before another

Start with `scan-removal-guard-tests`, using illustrative scanner labels rather than reconstructing a particular run:

1. Scanners A and B start in separate conversations.
2. A returns two findings while B is still running.
3. The workflow has enough input to describe two verifiers for A's findings.
4. Decide whether those verifiers may become eligible now, subject to shared execution capacity, or only after B finishes.
5. Crash after A's result commits but before any verifier request commits. Explain how evaluation rediscovers the same requests and their stable keys.
6. Crash after a verifier request commits but before the evaluator receives its acknowledgement. Recover its existing binding instead of admitting a duplicate request.
7. Let B return no findings, or fail. Specify how the final report records that branch according to the workflow's chosen error handling.

Follow-up accepted 7 September 2026: Step 4 now allows A's verifiers to become eligible while B remains unfinished. The [branch-progress trace](../design/workflow-branch-progress.md) records that decision, its owning amendments and outstanding discovery/replay questions. The complete blocked set no longer imposes a global join. Actual physical launch still waits for capacity.

For every step, record only: caller-visible behavior, durable facts/relationships, allowed next work, temporary memory and its release boundary. Increase scanner/finding counts only after the small trace is correct. Waiting scanners must not require retaining the workflow's JavaScript heap; completed finding data should not be copied into an unbounded resident verifier queue.

These observed scripts predominantly create fresh independent workers; the audit found no script-level continuation of a worker Session. Keep reusable/shared-Session scenarios as separately identified OnePage requirements, rather than presenting them as observed Claude workflow behavior.

## A systematic design method

State-machine modeling describes behavior above code as states and allowed transitions. AWS engineers report using precise properties and design specifications to expose subtle errors before implementation; checking a design does not verify its code. [Lamport's high-level view](https://lamport.azurewebsites.net/tla/high-level-view.html), [AWS authors' account](https://www.amazon.science/publications/how-amazon-web-services-uses-formal-methods), [Lamport-hosted excerpts](https://lamport.azurewebsites.net/tla/amazon-excerpt.html).

The following is a OnePage-specific method, inferred from those principles and the contracts above. Start with plain tables and executable traces. Add a model checker only if interleavings become difficult to enumerate or a concrete counterexample warrants it.

### 1. Write observable scenarios before choosing tables

| Scenario | Behavior to specify or preserve |
| --- | --- |
| New Run, one message, one result | Submission is admitted once under its key; the Run continues from its bound result. |
| Same key is replayed after a crash | Equal inputs recover the same binding; changed inputs conflict. |
| Session does later work | Earlier requests keep their original answers. |
| Two messages share one Turn | Both retain distinct request identity and observe the shared outcome. |
| Sequential awaits | The second submission occurs only after the first result is visible to evaluation. |
| Concurrent branches and joins | Establish when partial progress justifies reevaluation; do not assume every blocked set is one `Promise.all`. |
| One result serves many Runs | Every applicable Run can eventually continue without loading the whole dependent population. |
| A Run is cancelled while waiting | Accepted cancellation fencing prevents further evaluation/submission. |
| Permission is pending | Determine whether the saved change affects workflow visibility or only Session progress/inspection. |
| Result arrives during evaluation | The current immutable snapshot stays unchanged; the next discovery cannot overlook the new result. |

For the concurrent case, include two branches where one awaits A and then submits C while another awaits B. Determine the accepted barrier semantics before saying that either A alone or both A and B must finish. The same eventual final answer does not by itself establish identical permitted execution behavior.

### 2. Give each necessary fact one owner

Draw relationships in domain language, without SQL column names:

```text
Workflow Run + call key
    -> admitted Session operation + canonical inputs
    -> original work/result binding

Evaluation Generation
    -> immutable visible results
    -> recorded blocked dependencies
```

For each arrow ask: what creates it, can it change, when can it disappear, and can several callers share its target? For every proposed flag or counter ask whether it is authoritative, derived, or a rebuildable index. Justify a new stored fact with an otherwise ambiguous recovery case or unacceptable bounded-work cost.

### 3. Describe each transition and its commit boundary

For each scenario record: preconditions, saved changes, atomic group, permitted external action after commit, and how restart continues. Cover initial Run admission, keyed message admission, result settlement, blocked-set publication, next evaluation admission/publication and cancellation.

Separate three questions:

1. **Eligibility:** do saved facts justify evaluating this Run again?
2. **Discovery:** how does the Host notice that eligible work exists?
3. **Admission:** can the Host begin an evaluation lifecycle now?

A wake-up is not admission, and physical capacity is not workflow meaning. A notification can merely tell the existing driving path to reconsider durable facts. Whether that is sufficient depends on the complete lost-wake and bounded-discovery trace below.

### 4. Erase volatile state at every boundary

| Cut or race | What a complete design must demonstrate |
| --- | --- |
| Crash before result commit | No observer treats an uncommitted result as available; existing effect recovery applies. |
| Crash after commit, before notification | Startup finds the consequence from saved facts, without replaying callbacks. |
| Notification is lost while Host remains alive | The live check/sleep protocol or an explicitly selected fallback still discovers work. Startup recovery alone is insufficient. |
| Result commits before blocked-set publication | Publication/revalidation discovers that its snapshot is stale enough to need further consideration. |
| Result commits after blocked-set publication | Ordinary durable eligibility/discovery reaches the Run. |
| Result changes eligibility during candidate selection | Admission revalidates current generation, applicability and cancellation. |
| Several notifications arrive for the same visibility | Coalescing must not create repeated useless evaluation or erase a newer change. |
| Host stops partway through a large shared-result fan-out | Unprocessed dependents remain discoverable; a volatile cursor cannot be sole progress authority. |
| Evaluator exits before outcome publication | Recovery follows committed generation/admission facts; an exited process is not a published outcome. |

The check/sleep race matters even without a process crash: the Host can find no work, then receive a change before it actually sleeps. A proposed hook must explain the synchronization that prevents sleeping indefinitely after that change. Merely adding `onResult` does not answer this.

### 5. Apply the memory and simplicity tests before selecting a mechanism

Build a small ledger: object, owner, maximum simultaneous population, bytes per object, creation boundary and release boundary. Include waiting Runs, dependency edges, selected IDs, decoded inputs/results, the evaluator, captures, database workspace and completed outputs awaiting publication.

Desired design tests under the existing tenets:

- Increasing waiting Runs increases durable records, not retained JavaScript heaps, per-Run threads or payload queues.
- A shared result is not copied into every wake notification or every dependent Run's resident state.
- Burst handling reads a bounded portion, services other required work, and retains durable discoverability for the remainder.
- A blocked dependency graph can still grow on disk; fixed resident memory does not imply bounded storage or query time.
- An index or ready marker earns its maintenance/transaction/recovery complexity through a concrete scenario. Fewer tables alone does not establish simplicity.

### 6. Compare the smallest complete candidates, then choose queries

These are candidates for investigation, not accepted changes:

| Candidate | Potential simplicity/memory benefit | Obligation it must satisfy |
| --- | --- | --- |
| Derive eligible Runs when evaluator capacity is free | One durable authority; bounded candidate buffer | Avoid historical/all-Run scans and repeated unchanged evaluations; define live wake synchronization. |
| Locate affected Runs through persisted dependencies | Targeted discovery; dependency payload stays on disk | Bound shared-result fan-out; unfinished fan-out remains discoverable across crash. |
| Persist ready work with the relevant transition | Direct restart discovery and bounded draining | Prove marker/task ownership, deduplication, clearing and cancellation cannot diverge from canonical state. |

Notifications can accompany any of these. They need not be a fourth subsystem or a durable record per completion. Conversely, declaring them disposable is safe only after proving that dropping/coalescing them cannot strand progress.

Only after settling the behavior and ownership should the comparison specify actual indexes, SQL, temporary-memory accounting and measurements. Include historical growth, many waiting Runs, one highly shared result, completion bursts and controls competing with discovery. Fast queries on the wrong eligibility rule do not establish correctness.

## Decisions still requiring the human discussion

The open [workflow eligibility and wake-up decision](https://github.com/DivyanshGolyan/onepage/issues/114) owns the exact eligibility predicate, suppression of unchanged reevaluation, and the minimum discovery/recovery mechanism. Independent branch progress has since been accepted in the [branch-progress trace](../design/workflow-branch-progress.md); the mechanism remains open. Existing serial evaluation, original-result binding and disposable evaluators remain starting constraints.

The [inspection decision](https://github.com/DivyanshGolyan/onepage/issues/115) follows from those facts: decide which request/work relationships users need to see, then derive report access paths and measure responsiveness. It should not quietly select workflow execution semantics through a report layout.

No source above proves a preferred OnePage schema, polling frequency, fairness order or strict control latency. Those require the concrete traces and measured resource evidence of the selected local design.
