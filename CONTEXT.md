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

**Session WAL**:
The single ordered authority for semantic facts that create, advance, recover, or complete a session.
_Avoid_: Operation journal, event bus, transcript, debug log

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

**Core State**:
The compact semantic state needed to continue one agent, independent of native layout and temporary execution storage.
_Avoid_: Core image, Activation Slot, checkpoint bytes

**State Checkpoint**:
A rebuildable encoding of Core State after one Session WAL sequence, used to shorten recovery replay.
_Avoid_: Authority, raw image, Context Checkpoint

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

**Action**:
One policy-valid request by the agent for external work. A V1 tool call selects an action; a Final Answer does not.
_Avoid_: Tool call, command, Final Answer, event

**Operation**:
A uniquely identified instance of external work initiated by an action. An operation progresses through submitted, accepted, and completed states and may require more than one attempt.
_Avoid_: Action, job, request

**Attempt**:
One uniquely identified try to execute an accepted operation. Its disposition states whether execution definitely did not occur, may have occurred, or produced a durable terminal result.
_Avoid_: Operation, retry, request

**Result**:
The durable, typed outcome of a completed operation that the agent can use in a later decision.
_Avoid_: Completion, output, response

**Completion**:
A bounded notification that an operation's durable result is ready to apply to agent state.
_Avoid_: Result, event, callback

**Completion Inbox**:
A durable, non-authoritative collection of adapter evidence awaiting validation and commitment by Harness.
_Avoid_: Session WAL, Result, queue authority

**Reconciliation**:
The resolution of an uncertain operation by comparing durable intent with observed external state.
_Avoid_: Retry, replay, recovery

**Authorization**:
A durable admission decision bound to one exact validated Action. It comes from a user's decision in `ask` mode or automatic admission in bypass mode.
_Avoid_: Confirmation, blanket permission, Permission Mode

**Approval**:
A user's allow decision for one exact Action in `ask` mode.
_Avoid_: Authorization, bypass, blanket permission

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
