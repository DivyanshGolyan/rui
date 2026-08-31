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

**User**:
The conversation role that supplies tasks or requested input to an Agent. A User may be a person or another Agent; the role does not identify the invoking process, security principal, Run owner, or permission authority.
_Avoid_: Human, operator, approver, Caller, Principal

**Caller**:
The entity invoking the Run Service for a Run. A Caller may present User-role content but is not thereby the permission authority.
_Avoid_: User, Principal, Agent

**Principal**:
The identity against which Run access and delegated authority are checked.
_Avoid_: User, Caller, permission decision

**Authority**:
A policy or delegated capability that permits a Principal to make one class of decisions, including a bound Permission Decision.
_Avoid_: User role, Caller identity, Authorization

**Session**:
The durable container for one agent's related tasks, conversation, and outcomes.
_Avoid_: Conversation, task, process

**Dormant Session**:
A durable, resumable Session with no live Harness owner, borrowed Activation Slot, admitted in-flight Attempt, or external executor resource.
_Avoid_: In-flight Session, sleeping agent, closed Session, inactive process

**In-flight Session**:
A Session whose committed admitted external Attempt owns one transferable Active Credit while its Harness and Activation Slot are absent.
_Avoid_: Dormant Session, open Harness, blocked workflow

**Awaiting User**:
A Session condition in which safe progress requires a supported input from its User. Approval Required is the V1 permission-specific form of this condition.
_Avoid_: Blocked Workflow Run, In-flight Session, generic waiting

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
The sole recoverable OnePage-owned durable store: one host-wide SQLite database containing every Session Ledger, immutable content value, and host-wide coordination record.
_Avoid_: Session Ledger, blob store, Workspace

**Transient Content Scratch**:
One bounded unlinked file owned by a live content producer while external work prevents a SQLite transaction. It has no durable identity or recovery meaning and disappears on close or process exit.
_Avoid_: Host Store, Captured Model Output, durable content, spool directory

**Host Runtime**:
The sole live owner that coordinates Workflow Runs, Agents, and shared capacities for one Host Store.
_Avoid_: Agent, Session, Storage Owner

**Workflow Definition**:
A bounded program that composes keyed Jobs and returns one Workflow Output. It expresses demand for agent work but does not own or execute the resulting Agents.
_Avoid_: Workflow Run, evaluator, scheduler, agent runtime

**Workflow Evaluator**:
A disposable, Host-managed mechanism that evaluates one Workflow Definition against one Evaluation Generation. It retains no durable workflow or Agent state.
_Avoid_: Caller, Host Runtime, agent runtime, scheduler, durable workflow

**Evaluation Generation**:
One immutable evaluation input binding a Workflow Definition, arguments, semantics, resource profile, and Visibility Snapshot. Repeating the generation observes the same input even when later Job outcomes exist.
_Avoid_: Workflow Run, replay history, live completion stream

**Workflow Run**:
The durable identity binding one caller Run Key, exact workflow source, arguments, canonical invocation Workspace, semantics, Workflow Resource Profile, keyed Jobs, interactions, and terminal outcome.
_Avoid_: JavaScript process, Session, continuation, durable heap

**Run Key**:
A Caller-supplied stable idempotency key unique within one Host Store that creates or reattaches one Workflow Run when all bound inputs match.
_Avoid_: Run identity, Job Key, display name

**Job Key**:
A Caller-defined identity for one Job within a Workflow Run. It contains 1–128 Unicode scalar values, is at most 512 UTF-8 bytes, and is not a shell-safe system identifier.
_Avoid_: Run Key, Job identity, opaque ID

**Run Service**:
The protocol-independent semantic interface for creating, inspecting, advancing, responding to, cancelling, and reading immutable content from Workflow Runs.
_Avoid_: CLI, Harness, wire protocol, daemon

**Run Snapshot**:
A committed, revisioned read model of one Workflow Run, including every open Interaction Request and bounded output, Job, failure, uncertainty, artifact, and pagination metadata. The durable Run and Session facts remain authoritative.
_Avoid_: Harness Projection, event stream, durable authority

**Blocked Workflow Run**:
A non-terminal Workflow Run waiting for its complete requested set of Jobs to become terminal before a later Evaluation Generation. Being blocked does not imply that a Workflow Evaluator is live.
_Avoid_: Awaiting User, In-flight Session, suspended JavaScript

**Input Required**:
A public Run condition in which at least one Interaction Request is open and no other work in the Run can currently progress without a response.
_Avoid_: Awaiting User, Blocked Workflow Run, generic waiting

**Suspended Workflow Run**:
A non-terminal Run condition in which foreground advancement returns without requiring User input. V1 exposes it only if a concrete supported wait cannot remain attached to its wake source.
_Avoid_: Input Required, Blocked Workflow Run, process detachment

**Job**:
One keyed request within a Workflow Run that creates or reattaches one ordinary agent Session. Its canonical immutable specification determines whether replay reattaches or conflicts.
_Avoid_: Attempt, Operation, worker process, JavaScript Promise

**Job Output**:
The bounded workflow-visible projection of one Job Session's successful terminal Outcome. It is text when no output schema is supplied. With a schema it is one exact JSON document locally validated and canonically encoded under OnePage's closed JSON Schema subset, without extraction, repair, or coercion. Invalid structured output rejects `agent()` as `JobOutputInvalid`; a failed, cancelled, or indeterminate Job rejects it with its other stable code instead of producing a Job Output. Every rejection is a frozen bounded `JobError` containing only `code`, `job_key`, and `message`.
_Avoid_: Result, Conversation, provider response, Completion

**Workflow Output**:
The explicit bounded strict-data value fulfilled by a workflow's default export and canonically committed with its completed Workflow Run. An invalid or implicit `undefined` return fails as `WorkflowOutputInvalid`.
_Avoid_: Job Output, Result, Final Answer, terminal Outcome

**Interaction Request**:
An immutable durable request for one typed response, issued by the runtime for permission or by an Agent for bounded conversational input. Its identity is never reused, and replacement requires withdrawal plus a new identity.
_Avoid_: User Request, prompt, notification, Approval Required

**Interaction Response**:
A durable answer to one open Interaction Request. Every response is checked for kind, shape, freshness, and routing; a permission response additionally requires a Principal and matching Authority.
_Avoid_: User message, signal, Permission Decision

**Content Reference**:
An opaque Run-scoped identity for complete immutable bounded content retained for at least as long as its containing Run remains inspectable. Its optional preview is not the authoritative content.
_Avoid_: Harness content reference, Workspace path, blob path

**Artifact**:
A named immutable Run output composed from inline content or Content References. A mutable Workspace path alone is not an Artifact.
_Avoid_: message, tool Result, Workspace file

**Workflow Data Value**:
A bounded null, Boolean, string, array, string-keyed plain object, or finite IEEE-754 number shared by workflow arguments, inputs, schema-backed Job Outputs, and Workflow Output. Strings contain only Unicode scalar text: valid surrogate pairs encode as standard UTF-8 scalars, and lone UTF-16 surrogates are rejected without replacement. Integral numbers must be safe integers; negative zero canonicalizes to zero. `undefined`, non-finite numbers, unsafe integers, bigint, symbols, functions, accessors, proxies, cycles, host objects, lone surrogates, and unsupported prototypes are excluded.
_Avoid_: Conversation, arbitrary JavaScript object, provider wire value

**Agent Profile**:
A named immutable Job configuration selecting instructions, exact Model Contract, and Tool Catalog. It does not grant execution permission or change workflow resource limits. V1 exposes only the built-in `default` Agent Profile; omission selects it and an unknown name fails before Job creation.
_Avoid_: Workflow Resource Profile, Permission Mode, provider catalog

**Workflow Resource Profile**:
A named immutable set of evaluator and Run limits, including source, argument, Job, result-visibility, memory, CPU, time, diagnostic, and replay bounds. V1 exposes only the built-in `default` Workflow Resource Profile; omission selects it and an unknown name fails before Run creation.
_Avoid_: Agent Profile, Model Contract, Active Capacity

**Visibility Snapshot**:
The immutable run-local set of terminal Job Outputs and stable terminal Job failure codes visible to one workflow evaluation. It contains no physical completion order: outcomes that become terminal during an evaluation are visible only after its complete blocked set settles and a later evaluation begins.
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
A provider-neutral Conversation Entry selecting one Tool Key with exact bounded strict JSON arguments admitted under a named Validation Profile and the model Operation's Tool Catalog. Its entry identity pairs it with the immediate child Tool Result.
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
A non-empty assistant response with no tool call that completes the current task turn and is shown to the User.
_Avoid_: Finish action, stop action, terminal tool

### Execution

**Activation**:
A temporary period in which an agent occupies an Activation Slot and advances its Core State.
_Avoid_: Agent, session, process, checkpoint

**Activation Slot**:
One reusable, fixed-capacity resident workspace containing decoded Core State and transient scratch for an Activation.
_Avoid_: Agent, Core State, execution page, checkpoint

**Active Capacity**:
The startup-fixed number of transferable Active Credits supported by the V1 Host Runtime. It bounds active semantic work, not every stage-specific transport, effect, or validation resource; an Activation Slot is borrowed only while a Harness drives Core.
_Avoid_: Session population, total process memory, resource bundle, dynamic concurrency

**Active Credit**:
One volatile Host Runtime capacity credit that transfers between a live Harness, its committed admitted external Attempt, and the closure handoff that applies terminal evidence. It never establishes Session authority.
_Avoid_: Authorization, Runtime lease, ownership epoch, durable semaphore, preallocated memory bundle

**Semantic Admission**:
The bounded Host-owned step that validates one Captured Model Output and atomically commits either its typed Result meaning or a typed terminal failure into the Session Ledger.
_Avoid_: provider parsing, blob publication, Completion notification, Conversation replay

**Semantic View**:
The immutable bounded Session value derived from committed transactions for direct lifecycle observation: current Operations, relevant Attempts, control state, indeterminate Result, ledger head, and committed Core State.
_Avoid_: ledger replay callback, Run Snapshot, secondary index, durable authority

**Semantic Validation Capacity**:
The fixed number of Captured Model Outputs the Host may semantically admit at once.
_Avoid_: Active Capacity, provider concurrency, per-Agent scratch

**Validation Profile**:
The versioned strict-data rules under which exact model tool arguments are admitted, including syntax, duplicate-field, depth, structural, type, and size bounds.
_Avoid_: canonical JSON, Tool Catalog, input schema

**Strict Tool JSON V1**:
The V1 Validation Profile for exact model tool-argument bytes. It rejects invalid UTF-8, malformed JSON, duplicate fields, excessive depth or structure, schema mismatch, and size overflow without requiring a canonical spelling of an otherwise valid value.
_Avoid_: canonical JSON, semantic-equivalence identity, provider validation

**Workflow Evaluation Capacity**:
The maximum number of live workflow evaluator subprocesses. V1 fixes it at one independently of Active Capacity.
_Avoid_: Active Capacity, Job count, retained runner pool

**Action**:
One policy-valid request by the agent for external work. Harness may map an allowed Tool Call through the closed V1 bindings to an Action; model visibility alone does not create one. A Final Answer does not select an Action.
_Avoid_: Tool call, command, Final Answer, event

**Operation**:
A uniquely identified instance of model or external work. One durable admission binds its opaque identity and exact typed descriptor; an Action Operation also names the model Operation that proposed it. It may require more than one Attempt, and a model Operation fixes its complete semantic request contract for every Attempt.
_Avoid_: Action, job, request

**Attempt**:
One uniquely identified try to execute an admitted Operation. Its disposition states whether execution definitely did not occur, may have occurred, or produced a durable terminal Result. A model Attempt also records how many earlier Attempts under that Operation may already have reached the provider.
_Avoid_: Operation, retry, request

**Result**:
The durable, typed outcome of a completed operation that the agent can use in a later decision.
_Avoid_: Completion, output, response

**Captured Model Output**:
The immutable bounded bytes published by a model adapter for one Attempt before their provider-neutral meaning is admitted. They are durable evidence but not a Result or Conversation authority.
_Avoid_: Result, admitted response, provider wire stream, Conversation Entry

**Indeterminate Result**:
A Result stating that an Attempt may have affected external state but its terminal effect cannot be proved. It is evidence for the Agent's next decision, not an automatic retry, User escalation, or terminal Job outcome.
_Avoid_: Failure, retry request, Approval Required, Job Outcome

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
A durable admission decision bound to one exact validated Action. It comes from an authorized Principal's Permission Decision in `ask` mode or automatic admission in bypass mode.
_Avoid_: Confirmation, blanket permission, Permission Mode

**Approval**:
A permitted Principal's allow decision for one exact Action in `ask` mode.
_Avoid_: Authorization, bypass, blanket permission

**Approval Required**:
The durable Awaiting User state that identifies the exact validated Action for which `ask` mode still
needs a Permission Decision. It is not an Authorization.
_Avoid_: Authorization, Approval, prompt

**Permission Decision**:
A permitted Principal's exact allow or deny Interaction Response for an Approval Required state. Harness validates its Authority and exact operation binding before committing the corresponding Authorization.
_Avoid_: Authorization, Permission Mode, User role, blanket permission

**Permission Mode**:
The advancing-invocation rule that obtains Authorization either from an authorized Principal's response or by explicit bypass.
_Avoid_: Session authority, tool, Approval

**Verification**:
An authorized operation that gathers evidence about repository state. Verification does not itself decide whether the task succeeded.
_Avoid_: Test, success check

### Observation

**Projection**:
A small generation-scoped output emitted by a live Harness. Its content references require the originating Harness generation and are not public durable Run observations.
_Avoid_: Run Snapshot, event, durable read model

**Outcome**:
The terminal resolution of a task: a Final Answer, cancellation, or failure when safe progress cannot continue.
_Avoid_: Completion, result, exit code
