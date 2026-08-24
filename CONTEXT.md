# OnePage agent

OnePage runs durable coding tasks through a small, explicit action vocabulary. This glossary distinguishes the agent's decisions from the external work and notifications that advance them.

## Language

**Task**:
A durable statement of the repository outcome requested by the user.
_Avoid_: Repair, job, prompt

**Agent**:
The identified decision-maker responsible for advancing one task through actions to a terminal outcome.
_Avoid_: Session, run, worker

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

**Projection**:
A committed, observer-facing view of agent state or history that is not itself authoritative state.
_Avoid_: Event, callback, log

**Outcome**:
The terminal resolution of a task: success, an explained stop, or failure when safe progress cannot continue.
_Avoid_: Completion, result, exit code
