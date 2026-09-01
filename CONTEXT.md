# OnePage agent

OnePage coordinates durable coding-agent conversations and workflows. This glossary separates conversation meaning, workflow orchestration, external effects, authority, and transient execution custody.

## Language

### People and authority

**Agent**:
The model-driven decision-maker that advances one Turn through Conversation entries and proposed Actions.
_Avoid_: worker, Workflow Run, provider

**User**:
The Conversation role that starts a Turn or answers a requested input. A User may be a person or another Agent.
_Avoid_: human, Caller, Principal, approver

**Caller**:
The entity invoking the Run Service.
_Avoid_: User, Principal, Agent

**Principal**:
The identity against which access and delegated authority are checked.
_Avoid_: User, Caller, permission decision

**Authority**:
A policy or delegated capability that permits a Principal to make one class of decisions.
_Avoid_: User role, Caller identity, Authorization

**Authorization**:
The durable decision that permits one exact validated Action to be attempted.
_Avoid_: blanket permission, Approval, Authority

**Permission Mode**:
The advancing-invocation rule that obtains Authorization either from an authorized response or explicit bypass.
_Avoid_: Session authority, tool capability

### Conversation

**Session**:
A reusable durable linear Conversation, its sparse persistent context history, one Workspace, and one access scope. A Session has no terminal outcome or persisted lifecycle phase.
_Avoid_: Turn, tree, process, controller, terminal task

**Dormant Session**:
A Session with no nonterminal Turn and no active external work.
_Avoid_: sleeping process, closed Session, retained agent

**Conversation**:
The complete immutable linear sequence of model-visible entries accumulated within one Session.
_Avoid_: Session, operation log, provider transcript, tree

**Conversation Entry**:
One immutable User text, assistant text, Tool Call, or Tool Result in a Conversation, with exact Turn and causal provenance.
_Avoid_: event, mutable message, provider frame

**Conversation Revision**:
The ordinal of a Conversation Entry within one Session.
_Avoid_: Session phase, ledger head, ownership generation

**Turn**:
One idempotently admitted episode that begins with an ordinary User input and advances one Session until Final Answer or a typed terminal outcome. A correlated permission or input response may resume the same nonterminal Turn; at most one Turn is nonterminal in a Session.
_Avoid_: Job, Session, model request, worker

**Turn Outcome**:
The single terminal resolution of a Turn: completed, failed, or cancelled. Completion references its Final Answer; failure carries a typed failure code such as resource exhaustion. Operation uncertainty remains a separate fact that may inform either a later model decision or the Turn's failure.
_Avoid_: Attempt Completion, Operation Resolution, process exit

**Turn Condition**:
The total semantic classification derived from committed facts. Run membership summaries use exactly runnable, waiting for input, in flight, completed, failed, or cancelled. Derivation is ordered: terminal Outcome wins; otherwise an unresolved admitted external Attempt is in flight; otherwise an open request with no remaining progress is waiting for input; otherwise the Turn is runnable. `Input Required` is reserved for the Run-wide condition where no member can progress.
_Avoid_: persisted phase, status cache, ready flag

**Session Context Revision**:
One atomic sparse change to persistent model-visible Session defaults. Unchanged components continue from earlier revisions.
_Avoid_: rewritten system prompt, Turn Contract, configuration snapshot

**Session Context Patch**:
An optional closed sparse command supplied when starting a Turn in an idle Session. It carries the exact expected Context Revision and may change model, instructions, enabled built-in Tool Keys, context policy, reasoning default, or output limit. Authorized Turn admission atomically appends the patch as a new Session Context Revision and binds the new Turn to it. A persistent field cannot also be supplied as a Turn-local override in the same command.
_Avoid_: mutable prompt, mid-Turn update, generic configuration map

**Turn Contract**:
The immutable resolved policy and runtime facts that apply to one Turn, including the bound Session Context Revision and any explicit Turn-local overrides.
_Avoid_: mutable Session defaults, provider configuration, Model Request Manifest

**Model Context**:
The bounded projection of Conversation used by one model Operation, including an optional Compaction Checkpoint and a later complete suffix.
_Avoid_: Conversation, Session Context Revision, prompt cache

**Model Request Manifest**:
The immutable provider-neutral references and digests that identify the exact model, Instruction Set, Tool Catalog, Model Context, limits, and output contract consumed by one model Operation.
_Avoid_: raw HTTP request, credentials, mutable provider defaults

**Instruction Set**:
The immutable model-visible instructions selected through Session context and resolved for one Turn.
_Avoid_: complete model request, Tool Catalog, provider system field

**Compaction Checkpoint**:
An immutable replacement Model Context binding its exact source range, prior checkpoint, replacement content and digest, and creating model Operation. Turn, context, manifest, and model provenance derive through that Operation.
_Avoid_: Conversation rewrite, retention, reducer checkpoint

**Workspace**:
The repository checkout that a Session observes and may be authorized to change.
_Avoid_: Session, Conversation, repository history

### Model and tools

**Final Answer**:
A non-empty assistant response with no Tool Call that successfully completes the current Turn.
_Avoid_: finish tool, process exit, Workflow Output

**Tool Call**:
A provider-neutral Conversation Entry selecting one Tool Key with exact bounded arguments under the model Operation's Tool Catalog.
_Avoid_: Action, executable authority, provider wire call

**Tool Result**:
A provider-neutral Conversation Entry containing the model-visible consequence of one Tool Call.
_Avoid_: Attempt Completion, Operation Resolution, raw evidence

**Tool Key**:
A stable bounded identity for one Tool Definition within an exact Tool Catalog.
_Avoid_: provider tool name, Action kind

**Tool Definition**:
The model-visible description, input schema, and result-content contract for one tool.
_Avoid_: Adapter, permission, executable capability

**Tool Catalog**:
The bounded immutable set of Tool Definitions offered by one Model Request Manifest.
_Avoid_: runtime registry, provider catalog, plugin graph

**Captured Model Output**:
The immutable content carried by a model Attempt Completion before its provider-neutral meaning is selected by the Operation Resolution.
_Avoid_: admitted assistant entry, provider stream, Tool Result

**Validation Profile**:
The versioned strict-data rules used to validate model tool arguments and provider-neutral output.
_Avoid_: provider validation, canonical JSON spelling

### Operations and effects

**Action**:
One policy-valid request by the Agent for external work. V1 admits Bash and one-file patch Actions.
_Avoid_: Tool Call, command text, Final Answer

**Operation**:
A uniquely identified unit of model or Action work within a Turn. It binds its exact descriptor and causal source and has at most one Operation Resolution.
_Avoid_: Turn, Attempt, Action

**Operation Ordinal**:
The durable order of Operations within one Turn.
_Avoid_: global sequence, generation, timestamp order

**Attempt**:
One uniquely identified physical try to execute an Operation. Its durable insertion is the external-dispatch fence and binds the exact request, provenance, and retry identity.
_Avoid_: Operation, retry policy, request notification

**Attempt Completion**:
The immutable bounded evidence captured from one Attempt. It records what was observed, not what OnePage may safely do next.
_Avoid_: Operation Resolution, notification, Turn Outcome

**Operation Resolution**:
The single durable semantic result selected for an Operation. Its basis may be an Attempt Completion, permission denial, validation failure, cancellation, reconciliation, or recovery uncertainty.
_Avoid_: Attempt Completion, generic Result, Turn Outcome

**Indeterminate Resolution**:
An Operation Resolution stating that external state may have changed but the terminal effect cannot be proved. It is evidence for the Agent's next decision unless the Turn cannot safely continue.
_Avoid_: automatic retry, User escalation, generic failure

**Reconciliation**:
Resolution of an uncertain Operation by comparing durable intent with observed external state.
_Avoid_: replay, generic retry, database recovery

**Patch Intent**:
The immutable one-file mutation description binding Workspace, target, patch, preimage, and expected postimage before Authorization.
_Avoid_: patch result, approval, workspace snapshot

**Dispatch Permit**:
A volatile one-shot capability issued only to the command that committed a new Attempt. It authorizes physical launch after commit but is not durable semantic authority.
_Avoid_: Attempt, Authorization, lease, ownership epoch

**Physical Custody**:
The transient fact that a live Host execution cell currently owns an Attempt. Loss of custody never rewrites durable meaning.
_Avoid_: Operation state, database authority, Session ownership

### Interaction

**Interaction Request**:
An immutable durable request for one typed response, issued for permission or bounded conversational input within one Turn.
_Avoid_: prompt, notification, User Request

**Interaction Resolution**:
The single terminal answer, decision, or withdrawal of an Interaction Request. Absence of this relation means the request is open.
_Avoid_: generic response queue, permission text

**Input Required**:
A public Run condition in which at least one Interaction Request is open and no other Turn in the Run can currently progress.
_Avoid_: blocked Turn, suspended, generic waiting

**Cancellation Intent**:
Durable intent targeting one Turn or Workflow Run. Turn intent stops ordinary admission and reconciles admitted Operations. Run intent atomically stops evaluator generations and new membership and records Turn cancellation intent for every nonterminal member. It is not an Interaction Request and never makes a Session terminal.
_Avoid_: permission request, process detachment, terminal outcome

### Workflows and runs

**Workflow Definition**:
A bounded program that composes keyed Turns and returns one Workflow Output.
_Avoid_: Workflow Run, scheduler, agent runtime

**Workflow Evaluator**:
A disposable Host-managed mechanism that evaluates one Workflow Definition against one immutable Evaluation Generation.
_Avoid_: Host Runtime, retained workflow, agent runtime

**Evaluation Generation**:
One immutable evaluation input binding source, arguments, semantics, evaluator limits, and a Visibility Snapshot.
_Avoid_: JavaScript continuation, live completion stream

**Workflow Run**:
The durable identity binding one Caller Run Key, exact workflow inputs, Evaluation Generations, Turn memberships, and terminal outcome.
_Avoid_: evaluator process, Session, durable heap

**Run Key**:
A Caller-supplied idempotency key that creates or reattaches one Workflow Run when all bound inputs match.
_Avoid_: Run identity, Agent Call Key, display name

**Agent Call Key**:
A Caller-defined identity for one Turn membership within a Workflow Run.
_Avoid_: Turn identity, Run Key, system ID

**Visibility Snapshot**:
The immutable run-local set of terminal Turn Outputs and stable failures visible to one Evaluation Generation.
_Avoid_: live completion stream, Conversation

**Blocked Workflow Run**:
A nonterminal Workflow Run waiting for its complete requested Turn set before another Evaluation Generation.
_Avoid_: Input Required, retained JavaScript

**Turn Output**:
The bounded workflow-visible value produced by one successful Turn Outcome.
_Avoid_: Workflow Output, Tool Result, provider response

**Workflow Output**:
The bounded strict-data value durably committed with a completed Workflow Run.
_Avoid_: Turn Output, Final Answer

**Run Service**:
The protocol-independent interface for creating, inspecting, advancing, responding to, cancelling, and reading content from Workflow Runs.
_Avoid_: CLI, Harness, daemon, wire protocol

**Run Snapshot**:
A committed revisioned read model derived from canonical Run, Turn, Session, interaction, and effect facts.
_Avoid_: durable authority, event stream, Harness Projection

### Runtime and storage

**Host Runtime**:
The sole live owner that coordinates Workflow Runs, Turns, external execution, and bounded capacities for one Host Store.
_Avoid_: Agent, Session, Storage Owner

**Host Store**:
The sole recoverable OnePage-owned semantic and content store, containing canonical relational domain rows and immutable content. OS-held credentials are non-semantic security material.
_Avoid_: Session Ledger, blob store, Workspace

**Storage Owner**:
The exclusive gateway through which the Host Runtime reads or changes the Host Store.
_Avoid_: Session owner, database connection exposed to callers

**Decision Snapshot**:
A transient bounded set of canonical rows loaded to classify one Turn. It is never persisted or treated as a second authority.
_Avoid_: Core State, checkpoint, semantic view

**Active Capacity**:
The startup-fixed maximum population of concurrent active external work admitted by the Host Runtime.
_Avoid_: Session population, total RSS, preallocated resource bundle

**Active Credit**:
One volatile Host capacity credit owned by an admitted active Attempt or its immediate settlement handoff.
_Avoid_: Authorization, durable semaphore, Activation Slot

**Orchestration Memory**:
Resident memory owned by OnePage to coordinate current work. It scales with explicit capacities and active Operations, not durable Session or Turn population.
_Avoid_: Workload Memory, total RSS, database bytes

**Workload Memory**:
Memory intentionally consumed by a model-requested process and its descendants.
_Avoid_: Orchestration Memory, subprocess output capture

**Content Reference**:
An opaque identity for complete immutable bounded content stored in the Host Store.
_Avoid_: Workspace path, preview, transient file

**Binding Digest**:
A typed domain-separated digest that binds exact bytes for one identity, authorization, dispatch, or reconciliation role.
_Avoid_: identifier, authentication tag, tamper proof
