# OnePage agent

OnePage runs durable coding tasks through a small, explicit action vocabulary. This glossary distinguishes the agent's decisions from the external work and notifications that advance them.

## Language

### Identity and history

**Task**:
A durable statement of one repository outcome requested within a session.
_Avoid_: Repair, job, prompt

**Agent**:
The identified decision-maker responsible for advancing tasks within a session through actions.
_Avoid_: Run, worker

**Session**:
The durable container for one agent's related tasks, conversation, and outcomes.
_Avoid_: Conversation, task, process

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

### Execution

**Activation**:
A temporary period in which an agent occupies an execution page and advances its durable state.
_Avoid_: Agent, session, process

**Action**:
One policy-valid next step selected by the agent. An action either requests external work or ends the task.
_Avoid_: Tool call, command, event

**Operation**:
A uniquely identified instance of external work initiated by an action. An operation progresses through submitted, accepted, and completed states.
_Avoid_: Action, job, request

**Result**:
The durable, typed outcome of a completed operation that the agent can use in a later decision.
_Avoid_: Completion, output, response

**Completion**:
A bounded notification that an operation's durable result is ready to apply to agent state.
_Avoid_: Result, event, callback

**Approval**:
A user's decision to authorize or reject one exact consequential operation.
_Avoid_: Confirmation, blanket permission

**Verification**:
An approved operation that gathers evidence about repository state. Verification does not itself decide whether the task succeeded.
_Avoid_: Test, success check

### Observation

**Projection**:
A committed, observer-facing view of agent state or history that is not itself authoritative state.
_Avoid_: Event, callback, log

**Outcome**:
The terminal resolution of a task: success, an explained stop, or failure when safe progress cannot continue.
_Avoid_: Completion, result, exit code
