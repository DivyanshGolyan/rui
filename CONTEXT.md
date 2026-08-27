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
A durable, resumable Session with no live Harness owner and no borrowed Activation Slot.
_Avoid_: Sleeping agent, closed Session, inactive process

**Session Ledger**:
The single ordered authority for semantic facts that create, advance, recover, or complete one session.
_Avoid_: Session WAL, SQLite WAL, operation journal, event bus, transcript, debug log

**Host Store**:
The durable container for every Session Ledger and host-wide durable coordination state.
_Avoid_: Session Ledger, blob store, Workspace

**Host Runtime**:
The sole live owner that coordinates agents and shared capacities for one Host Store.
_Avoid_: Agent, Session, Storage Owner

**Storage Owner**:
The exclusive gateway through which a Host Runtime reads or changes its Host Store.
_Avoid_: Host Runtime, Session owner, database connection

**Conversation**:
The immutable tree of context-relevant entries accumulated within a session.
_Avoid_: Session, transcript, operation log

**Conversation Entry**:
One immutable node in a conversation, linked to its parent entry or to the root.
_Avoid_: Message, record, event

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
The startup-fixed number of open Harness owners, Activation Slots, and per-Harness in-flight external Attempts supported by the V1 Host Runtime.
_Avoid_: Session population, scheduler, dynamic concurrency

**Action**:
One policy-valid request by the agent for external work. A V1 tool call selects an action; a Final Answer does not.
_Avoid_: Tool call, command, Final Answer, event

**Operation**:
A uniquely identified instance of external work initiated by an action. An operation progresses through submitted, accepted, and completed states and may require more than one attempt.
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
