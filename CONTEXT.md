# OnePage agent

OnePage coordinates durable coding-agent conversations and workflows. This glossary separates conversation meaning, workflow orchestration, external effects, authority, and transient execution custody.

## Language

### People and authority

**Agent**:
The model-driven decision-maker that advances one Turn through Conversation entries and proposed Actions.
_Avoid_: worker, Workflow Run, provider

**User**:
The Conversation role that authors a User Message. A User may be a person or another Agent.
_Avoid_: human, Caller, Principal, approver

**Caller**:
The entity invoking the Host Runtime's Run API.
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
The immutable Turn Contract policy selected when the Turn is admitted. `ask`, the default, requires an authorized Permission Decision for each exact validated Action; explicit `bypass` creates Authorization from that bound policy without a request. Turn admission rejects bypass unless the Principal's Authority permits it. The mode cannot change while the Turn is active.
_Avoid_: Session authority, tool capability

### Conversation

**Session**:
A reusable durable linear Conversation, its sparse persistent context history, one Workspace, and one access scope. A Session has no terminal outcome or persisted lifecycle phase.
_Avoid_: Turn, tree, process, controller, terminal task

**Dormant Session**:
A Session with no nonterminal Turn and no active external work.
_Avoid_: sleeping process, closed Session, retained agent

**Conversation**:
The complete immutable linear sequence of canonical semantic entries accumulated within one Session.
_Avoid_: Session, operation log, provider transcript, tree

**Conversation Entry**:
One immutable User text, assistant text, Tool Call, or Tool Result in a Conversation, with exact Turn and causal provenance.
_Avoid_: event, mutable message, provider frame

**Conversation Revision**:
The ordinal of a Conversation Entry within one Session.
_Avoid_: Session phase, ledger head, ownership generation

**User Message**:
Immutable User-authored content admitted to one Turn. It becomes a Conversation Entry when a model Operation requesting the next assistant response applies it; an initiating User Message is admitted and applied atomically with its Turn. An internal compaction model Operation does not apply a pending User Message.
_Avoid_: Interaction Response, steering event, mutable prompt

**Turn**:
One idempotently admitted episode that begins with an initiating User Message and advances one Session until Final Answer or a typed terminal outcome. Later User Messages may extend the same nonterminal Turn; at most one Turn is nonterminal in a Session.
_Avoid_: Job, Session, model request, worker

**Turn Outcome**:
The single terminal resolution of a Turn: completed, failed, or cancelled. Completion references its Final Answer; failure carries a typed failure code such as resource exhaustion. Operation uncertainty remains a separate fact that may inform either a later model decision or the Turn's failure.
_Avoid_: Attempt Completion, Operation Resolution, process exit

**Turn Condition**:
The total semantic classification derived from committed facts. Run membership summaries use exactly runnable, waiting for permission, in flight, completed, failed, or cancelled. Derivation is ordered: terminal Outcome wins; otherwise an unresolved Operation with an admitted Attempt or immutable future retry eligibility is in flight; otherwise an actionable Permission Request with no remaining progress is waiting for permission; otherwise the Turn is runnable. `Permission Required` is reserved for the Run-wide condition where no member can progress.
_Avoid_: persisted phase, status cache, ready flag

**Session Context Revision**:
One atomic sparse change to persistent model-visible Session defaults. Unchanged components continue from earlier revisions.
_Avoid_: rewritten system prompt, Turn Contract, configuration snapshot

**Session Context Patch**:
An optional closed sparse command supplied when starting a Turn in an idle Session. It carries the exact expected Context Revision and may change model, instructions, enabled built-in Tool Keys, context policy, reasoning default, or output limit. Authorized Turn admission atomically appends the patch as a new Session Context Revision and binds the new Turn to it. A persistent field cannot also be supplied as a Turn-local override in the same command.
_Avoid_: mutable prompt, mid-Turn update, generic configuration map

**Turn Contract**:
The immutable resolved policy and runtime facts that apply to one Turn, including the bound Session Context Revision, Permission Mode, and any explicit Turn-local overrides.
_Avoid_: mutable Session defaults, provider configuration, Model Request Manifest

**Model Context**:
The exact replay recipe used by one model Operation: an optional selected Compaction Base followed by one total ordered suffix of canonical host inputs and accepted model Operation Resolutions. Core and the selected adapter validate that chosen base without searching backward for an alternative.
_Avoid_: Conversation, Session Context Revision, prompt cache

**Model Request Manifest**:
The immutable references and digests that identify the provider protocol operation, requested concrete model, Instruction Set, Tool Catalog, totally ordered Model Context, replay format, behavior-affecting protocol options, limits, and output contract consumed by one model Operation.
_Avoid_: raw HTTP request, credentials, mutable provider defaults

**Instruction Set**:
The immutable model-visible instructions selected through Session context and resolved for one Turn.
_Avoid_: complete model request, Tool Catalog, provider system field

**Compaction Base**:
The derived role of an accepted compaction model Operation Resolution when a later Model Request Manifest selects its replacement Model Context. Its creating Operation's source manifest defines the complete covered frontier and lineage; its selected Completion owns the replacement output. It is not a separate authoritative row or a rewrite of Conversation.
_Avoid_: Compaction Checkpoint, Conversation rewrite, retention, reducer checkpoint

**Workspace**:
The repository checkout that a Session observes and may be authorized to change.
_Avoid_: Session, Conversation, repository history

### Model and tools

**Final Answer**:
A non-empty assistant response with no Tool Call that successfully completes the current Turn because no earlier applicable User Message requires another model Operation.
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

**Model Output Item**:
One ordered canonical provider-result item owned by a model Attempt Completion. It retains supported semantic fields, provider-only continuation fields, and response-evidence fields exactly once; a provider adapter derives any later replay-input view from it.
_Avoid_: Conversation Entry, Provider Replay Receipt, raw HTTP or SSE frame

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
One uniquely identified physical try to execute an Operation. Its durable insertion is the external-dispatch fence and binds the Operation's immutable manifest or Action descriptor, provenance, and retry identity without storing a request body.
_Avoid_: Operation, retry policy, request notification

**Attempt Completion**:
The single immutable bounded evidence record captured from one Attempt. It records what was observed, not what OnePage may safely do next.
_Avoid_: Operation Resolution, notification, Turn Outcome

**Operation Resolution**:
The single durable semantic result selected for an Operation. Its basis may be an Attempt Completion, permission denial, validation failure, interruption, cancellation, reconciliation, or recovery uncertainty.
_Avoid_: Attempt Completion, generic Result, Turn Outcome

**Interrupted Resolution**:
An Operation Resolution stating that one exact unresolved Model Operation ended before any result was accepted. Its causal provenance is exactly one of: an authorized direct Model Interruption binding its Principal and idempotency key, or the canonical Run Cancellation Intent joined through immutable Run–Turn membership. An interrupted Model Operation may have no Attempt Completion; this records deliberate abandonment, not an assertion that the provider stopped processing. It ends only that Operation. The Turn may continue through independently admitted User Messages after direct interruption; Run cancellation fences that continuation and eventually yields a cancelled Turn Outcome. Actions cannot receive the direct interruption command.
_Avoid_: Turn Outcome, failed Attempt, process detachment

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
A volatile one-shot capability issued only to the command that committed a new Attempt. It authorizes but does not oblige physical launch after commit; a later committed interruption may suppress it before the owner crosses the Physical Custody launch boundary. It is not durable semantic authority and reconstruction never recreates it.
_Avoid_: Attempt, Authorization, lease, ownership epoch

**Physical Custody**:
A bounded Host record representing the transient fact that one effect owner currently holds the physical handles for an Attempt. One atomic launch-boundary transition distinguishes suppression before an external effect from cleanup after it may have started. The record contains no payload or semantic state, and loss of custody never rewrites durable meaning.
_Avoid_: Operation state, database authority, Session ownership

### Permission and cancellation

**Permission Request**:
An immutable durable request for a Principal's decision on one exact proposed Action and descriptor. Absence of a Permission Decision means the request remains actionable while its Operation and Run permit admission.
_Avoid_: input request, prompt, notification, User Message

**Permission Decision**:
The single allow-once or deny decision for one exact Permission Request. An allowed decision may establish Authorization; it is never Conversation content.
_Avoid_: User Message, generic response batch, permission text

**Permission Required**:
A public Run condition in which at least one Permission Request is actionable and no other member Turn can currently progress.
_Avoid_: blocked Turn, suspended, generic waiting

**Run Cancellation Intent**:
Durable intent to stop one Workflow Run. Through immutable Run–Turn membership it fences new evaluation, membership, Operation, and Attempt admission immediately while already-admitted work resolves or reconciles before terminal cancellation.
_Avoid_: Turn Cancellation Intent, Permission Request, process detachment, terminal outcome

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
_Avoid_: Permission Required, retained JavaScript

**Turn Output**:
The bounded workflow-visible value produced by one successful Turn Outcome.
_Avoid_: Workflow Output, Tool Result, provider response

**Workflow Output**:
The bounded strict-data value durably committed with a completed Workflow Run.
_Avoid_: Turn Output, Final Answer

**Run API**:
The narrow typed caller-facing boundary of the Host Runtime for admitting Run work, inspecting current Run state, driving progress, deciding permission, interrupting one exact Model Operation, cancelling a Run, and reading content.
_Avoid_: Run Service, CLI, daemon, wire protocol

**Run Snapshot**:
A current committed read model derived from canonical Run, Turn, Session, permission, and effect facts. Its revision can guard inspection but does not promise historical reconstruction.
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
The accounting term for one occupied Physical Custody record. Occupancy reserves one unit of Host concurrency for a prospective Attempt before admission and retains it only through live execution and immediate settlement.
_Avoid_: Authorization, durable semaphore, Activation Slot

**Orchestration Memory**:
Resident memory owned by OnePage to coordinate current work. It scales with explicit capacities and active Operations, not durable Session or Turn population.
_Avoid_: Workload Memory, total RSS, database bytes

**Workload Memory**:
Memory intentionally consumed by a model-requested process and its descendants.
_Avoid_: Orchestration Memory, subprocess output capture

**Content Reference**:
An opaque identity for complete immutable content stored in the Host Store with its exact length and digest.
_Avoid_: Workspace path, preview, transient file

**Binding Digest**:
A typed domain-separated digest that binds exact bytes for one identity, content, authorization, or reconciliation role.
_Avoid_: identifier, authentication tag, tamper proof
