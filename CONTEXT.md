# OnePage agent

OnePage runs durable coding tasks through a small, explicit domain language. This glossary distinguishes the agent's decisions from the external work and notifications that advance them.

## Language

### Identity and history

**Task**:
A durable statement of one repository outcome requested within a session.
_Avoid_: Repair, job, prompt

**Agent**:
The identified decision-maker responsible for advancing tasks within a session through model responses.
_Avoid_: Run, worker

**Session**:
The durable container for one agent's related tasks, conversation, and outcomes.
_Avoid_: Conversation, task, process

**Dormant Session**:
A durable, resumable Session with no live Harness owner, borrowed Activation Slot, admitted in-flight Attempt, or external executor resource.
_Avoid_: In-flight Session, sleeping agent, closed Session, inactive process

**In-flight Session**:
A Session whose committed admitted external Attempt owns one transferable Active Credit while its Harness and Activation Slot are absent.
_Avoid_: Dormant Session, open Harness, blocked workflow

**Orchestration Memory**:
Resident memory owned by OnePage to coordinate work, including Activation Slots, live Harness state, Host Runtime metadata, SQLite, provider transport, and bounded adapter capture. It scales with explicit host capacities and current in-flight work.
_Avoid_: Workload Memory, total RSS, Activation Slot bytes

**Workload Memory**:
Memory intentionally consumed by a model-requested external process and its descendants. OnePage observes and reports it separately but does not cap it as part of the orchestration-memory guarantee.
_Avoid_: Orchestration Memory, subprocess output capture, transport memory

**Session Ledger**:
The single ordered authority for semantic facts that create, advance, recover, or complete one session.
_Avoid_: Session WAL, SQLite WAL, operation journal, event bus, transcript, debug log

**Host Store**:
The durable container for every Session Ledger and host-wide durable coordination state.
_Avoid_: Session Ledger, blob store, Workspace

**Host Runtime**:
The sole live owner that coordinates agents and shared capacities for one Host Store.
_Avoid_: Agent, Session, Storage Owner

**Workflow Evaluator**:
A disposable caller-side QuickJS subprocess that reconstructs one workflow evaluation from exact source, arguments, and a Visibility Snapshot, then submits or observes keyed Jobs. It is not an agent runtime.
_Avoid_: Host Runtime, agent runtime, scheduler, durable VM

**Workflow Run**:
The durable identity binding one workflow's exact source, arguments, canonical invocation Workspace, semantics, Workflow Resource Profile, keyed Jobs, and terminal outcome.
_Avoid_: JavaScript process, Session, continuation, durable heap

**Job**:
One keyed request within a Workflow Run that creates or reattaches one ordinary agent Session. Its canonical immutable specification determines whether replay reattaches or conflicts.
_Avoid_: Attempt, Operation, worker process, JavaScript Promise

**Job Output**:
The bounded workflow-visible projection of one Job Session's successful terminal Outcome. It is text when no output schema is supplied. With a schema it is one exact JSON document locally validated and canonically encoded under OnePage's closed JSON Schema subset, without extraction, repair, or coercion. Invalid structured output rejects `agent()` as `JobOutputInvalid`; a failed, cancelled, or indeterminate Job rejects it with its other stable code instead of producing a Job Output. Every rejection is a frozen bounded `JobError` containing only `code`, `job_key`, and `message`.
_Avoid_: Result, Conversation, provider response, Completion

**Workflow Output**:
The explicit bounded strict-data value fulfilled by a workflow's default export, canonically committed with its completed Workflow Run before being rendered as one terminal-safe JSON line. An invalid or implicit `undefined` return fails as `WorkflowOutputInvalid`.
_Avoid_: Job Output, Result, Final Answer, terminal Outcome

**Workflow Data Value**:
A bounded null, Boolean, string, array, string-keyed plain object, or finite IEEE-754 number shared by workflow arguments, inputs, schema-backed Job Outputs, and Workflow Output. Integral numbers must be safe integers; negative zero canonicalizes to zero. `undefined`, non-finite numbers, unsafe integers, bigint, symbols, functions, accessors, proxies, cycles, host objects, and unsupported prototypes are excluded.
_Avoid_: Conversation, arbitrary JavaScript object, provider wire value

**Agent Profile**:
A named immutable Job configuration selecting instructions, exact Model Contract, and Tool Catalog. It does not grant execution permission or change workflow resource limits. V1 exposes only the built-in `default` Agent Profile; omission selects it and an unknown name fails before Job creation.
_Avoid_: Workflow Resource Profile, Permission Mode, provider catalog

**Workflow Resource Profile**:
A named immutable set of evaluator and Run limits, including source, argument, Job, result-visibility, memory, CPU, time, diagnostic, and replay bounds. V1 exposes only the built-in `default` Workflow Resource Profile; omission selects it and an unknown name fails before Run creation.
_Avoid_: Agent Profile, Model Contract, Active Capacity

**Visibility Snapshot**:
The immutable run-local set of terminal Job Outputs and stable terminal Job failure codes visible to one workflow evaluation. Outcomes that become terminal during an evaluation are visible only after its complete blocked set settles and a later evaluation begins.
_Avoid_: live completion stream, Conversation, scheduler state

**Storage Owner**:
The exclusive gateway through which a Host Runtime reads or changes its Host Store.
_Avoid_: Host Runtime, Session owner, database connection

**Conversation**:
The immutable tree of context-relevant entries accumulated within a session.
_Avoid_: Session, transcript, operation log

**Conversation Entry**:
One immutable node in a conversation, linked to its parent entry or to the root.
_Avoid_: Message, record, event

**Tool Call**:
A provider-neutral Conversation Entry selecting one Tool Key with bounded canonical JSON arguments. Its entry identity pairs it with the immediate child Tool Result.
_Avoid_: Action, provider wire call, executable authority

**Tool Result**:
A provider-neutral Conversation Entry containing the bounded model-visible outcome of one Tool Call and naming that call through its parent identity.
_Avoid_: Completion, raw adapter evidence, provider response

**Tool Key**:
A stable bounded identity for one Tool Definition within the exact Tool Catalog bound to a model Operation.
_Avoid_: Provider tool name, Action kind, Tool Catalog Digest

**Tool Definition**:
The model-visible description of one tool: its Tool Key, provider-facing name and description, bounded input JSON Schema, and result-content contract.
_Avoid_: Adapter, permission, executable capability

**Tool Catalog**:
The bounded immutable set of Tool Definitions offered to every Attempt of one model Operation.
_Avoid_: Runtime registry, plugin graph, provider catalog

**Tool Catalog Digest**:
The typed digest binding the exact Tool Catalog for one model Operation.
_Avoid_: Tool Key, provider name, permission binding

**Branch**:
One root-to-leaf path through a conversation that represents a possible continuation.
_Avoid_: Session, fork, lane

**Model Context**:
The bounded projection of one branch prepared for a single model operation.
_Avoid_: Conversation, transcript, prompt

**Compaction**:
An operation that derives a bounded replacement model context from an older part of a branch without deleting the source conversation entries.
_Avoid_: Deletion, truncation, transcript rewrite

**Context Checkpoint**:
An immutable conversation entry that defines the replacement projection produced by compaction and the branch range from which it was derived.
_Avoid_: Snapshot, rewritten transcript, operation checkpoint

**Delegation**:
An action that creates a child agent with a task and returns that child's outcome to the parent as a result.
_Avoid_: Agent call, recursive call, subroutine

**Workspace**:
The repository checkout whose state a session observes and may be authorized to change.
_Avoid_: Session, conversation, repository history

**Workspace Effect Fence**:
The bounded Host Runtime ownership record that permits at most one admitted Bash or patch Attempt against one Workspace until its terminal evidence is applied. It is reconstructed from durable non-terminal Attempts and is not model-visible authority.
_Avoid_: Active Credit, Git lock, read-only classification, permission

**Patch Intent**:
The immutable one-file mutation description that binds the Workspace, canonical target, permitted file properties, exact patch, exact preimage, and expected postimage before Authorization.
_Avoid_: Patch result, approval, workspace snapshot

**Core State**:
The compact semantic state needed to continue one agent, independent of native layout and temporary execution storage.
_Avoid_: Core image, Activation Slot, checkpoint bytes

**Final Answer**:
A non-empty assistant response with no tool call that completes the current task turn and is shown to the user.
_Avoid_: Finish action, stop action, terminal tool

### Execution

**Activation**:
A temporary period in which an agent occupies an Activation Slot and advances its Core State.
_Avoid_: Agent, session, process, checkpoint

**Activation Slot**:
One reusable, fixed-capacity resident workspace containing decoded Core State and transient scratch for an Activation.
_Avoid_: Agent, Core State, execution page, checkpoint

**Active Capacity**:
The startup-fixed number of transferable Active Credits supported by the V1 Host Runtime. Each credit is owned by exactly one live Harness, admitted external Attempt, or closure handoff; an Activation Slot is borrowed only while its Harness drives Core.
_Avoid_: Session population, scheduler, dynamic concurrency

**Active Credit**:
One volatile Host Runtime capacity credit that transfers between a live Harness, its committed admitted external Attempt, and the closure handoff that applies terminal evidence. It never establishes Session authority.
_Avoid_: Authorization, Runtime lease, ownership epoch, durable semaphore

**Workflow Evaluation Capacity**:
The maximum number of live workflow evaluator subprocesses. V1 fixes it at one independently of Active Capacity.
_Avoid_: Active Capacity, Job count, retained runner pool

**Action**:
One policy-valid request by the agent for external work. Harness may map an allowed Tool Call through the closed V1 bindings to an Action; model visibility alone does not create one. A Final Answer does not select an Action.
_Avoid_: Tool call, command, Final Answer, event

**Operation**:
A uniquely identified instance of external work initiated by an action. An operation progresses through submitted, accepted, and completed states and may require more than one attempt. A model Operation fixes its complete semantic request contract for every Attempt.
_Avoid_: Action, job, request

**Attempt**:
One uniquely identified try to execute an accepted operation. Its disposition states whether execution definitely did not occur, may have occurred, or produced a durable terminal result. A model Attempt also records how many earlier Attempts under that Operation may already have reached the provider.
_Avoid_: Operation, retry, request

**Result**:
The durable, typed outcome of a completed operation that the agent can use in a later decision.
_Avoid_: Completion, output, response

**Binding Digest**:
A typed, domain-separated SHA-256 value that binds exact authoritative bytes for one semantic role. Different roles share a width but are not interchangeable.
_Avoid_: Identifier, authentication tag, tamper proof, optional sentinel

**Completion**:
A bounded notification that an operation's durable result is ready to apply to agent state.
_Avoid_: Result, event, callback

**Completion Inbox**:
A durable, non-authoritative collection of adapter evidence awaiting validation and commitment by Harness.
_Avoid_: Session Ledger, Result, queue authority

**Reconciliation**:
The resolution of an uncertain operation by comparing durable intent with observed external state.
_Avoid_: Retry, replay, recovery

**Authorization**:
A durable admission decision bound to one exact validated Action. It comes from a user's decision in `ask` mode or automatic admission in bypass mode.
_Avoid_: Confirmation, blanket permission, Permission Mode

**Approval**:
A user's allow decision for one exact Action in `ask` mode.
_Avoid_: Authorization, bypass, blanket permission

**Approval Required**:
The durable waiting state that identifies the exact validated Action for which `ask` mode still
needs a Permission Decision. It is not an Authorization.
_Avoid_: Authorization, Approval, prompt

**Permission Decision**:
The user's exact allow or deny input for an Approval Required state. Harness validates it before
committing the corresponding Authorization.
_Avoid_: Authorization, Permission Mode, blanket permission

**Permission Mode**:
The invocation-scoped rule that obtains Authorization either by asking the user or by explicit bypass.
_Avoid_: Session authority, tool, Approval

**Verification**:
An authorized operation that gathers evidence about repository state. Verification does not itself decide whether the task succeeded.
_Avoid_: Test, success check

### Observation

**Projection**:
A committed, observer-facing view of agent state or history that is not itself authoritative state.
_Avoid_: Event, callback, log

**Outcome**:
The terminal resolution of a task: a Final Answer, cancellation, or failure when safe progress cannot continue.
_Avoid_: Completion, result, exit code
