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
An input or observation source invoking the Host Runtime. The Caller has no separate conversational position within a Session; its observation is current only as of the instant captured.
_Avoid_: User, Principal, Agent

**Local Owner**:
The single owner of a Host Runtime and its Store. All clients admitted to that server act for this owner and share access to its Sessions and Workflow Runs.
_Avoid_: per-agent Principal, role, delegated identity

**Principal**:
The implicit Local Owner wherever this term remains in the V1 contracts; it is not a separate identity for each Caller.
_Avoid_: User Message author, per-client account, permission decision

**Authority**:
The Local Owner's control over its Store, shared by admitted clients. V1 has no independently delegated or per-Session authority.
_Avoid_: role hierarchy, Caller identity, Action Authorization

**Authorization**:
The durable decision that permits one exact validated Action to be attempted.
_Avoid_: blanket permission, Approval, Authority

**Permission Mode**:
Persistent Session setting selected at Action admission: `ask` creates an exact Permission Request; explicit `bypass` creates Authorization. Existing admissions retain their meaning after configuration changes. See [Tools and permission](ARCHITECTURE.md#tools-and-permission).
_Avoid_: Session authority, tool capability

### Conversation

**Session**:
A reusable durable linear Conversation, its sparse persistent context history, one Workspace, and one access scope. Its first accepted complete configuration establishes its durable state. A Session has no terminal outcome or persisted lifecycle phase.
_Avoid_: Turn, tree, process, controller, terminal task

**Dormant Session**:
A Session with no nonterminal Turn and no active external work.
_Avoid_: sleeping process, closed Session, retained agent

**Session Key / Session Reference**:
An opaque caller-scoped identity accepted unchanged by the core within a Store. Constructing a reference performs no core operation, proves no durable Session exists and grants no access. Workflow `session(name)` scopes a short name by Run identity; an exact full key can directly address the same Session from another Run. First complete configuration establishes durable state. Session keys identify conversations, separately from Request Identities and internal Turn IDs.
_Avoid_: creation receipt, Run Key, request key, live Session object

**Conversation**:
The complete immutable linear sequence of canonical semantic entries accumulated within one Session.
_Avoid_: Session, operation log, provider transcript, tree

**Conversation Entry**:
One immutable User text, assistant text, Tool Call, Tool Result, or System Instruction in a Conversation, with exact Turn and causal provenance.
_Avoid_: event, mutable message, provider frame

**System Instruction**:
An immutable Conversation Entry carrying an appended operator instruction or host-supplied contextual update for the model. Session history distinguishes it from User text, assistant output, and tool content. Every explicit instruction update is preserved in order, including intermediate values, reversals and fresh updates repeating the same text; source-update identity prevents replay duplicates. Later changes append another instruction rather than rewriting it. Its provider representation must preserve instruction authority and legal placement; it cannot grant Action Authorization. First inclusion of all pending updates commits atomically with their assistant-response request; exact storage encoding remains implementation work.
_Avoid_: Context Update, User Message, Permission Decision, provider thinking

**Conversation Revision**:
The ordinal of a Conversation Entry within one Session.
_Avoid_: Session phase, ledger head, ownership generation

**User Message**:
Immutable User-authored content admitted to one Turn. It becomes a Conversation Entry when a model Operation requesting the next assistant response applies it; an initiating User Message is admitted and applied atomically with its Turn. An internal compaction model Operation does not apply a pending User Message. A failed Turn Outcome or applicable cancellation authority makes remaining unprojected admissions inapplicable without deleting them or adding a message phase; later work does not implicitly apply them. Projection proves application to Conversation/model context, not provider consumption.
_Avoid_: Interaction Response, steering event, mutable prompt

**Turn**:
One idempotently admitted episode that begins with an initiating User Message and advances one Session until Final Answer or a typed terminal outcome. Later User Messages may extend the same nonterminal Turn; at most one Turn is nonterminal in a Session.
_Avoid_: Job, Session, model request, worker

**Turn Outcome**:
The single terminal resolution of a Turn: completed, failed, or cancelled. A completed outcome references its Final Answer; failure carries a typed failure code and either pre-request validation provenance or a same-Turn reference to the accepted Operation Resolution establishing the failure. Once all other semantic obligations are resolved, the failed outcome may commit with unprojected User Messages remaining; it makes them inapplicable and releases logical Session occupancy atomically. Operation uncertainty remains a separate fact that may inform either a later model decision or the Turn's failure.
_Avoid_: Operation Resolution, process exit

**Turn Condition**:
The semantic classification derived from committed facts: runnable, waiting for permission, in flight, completed, failed or cancelled. [Run interface](docs/architecture/workflows.md#run-interface) owns precedence. `Permission Required` is the Run-wide condition where no member can progress.
_Avoid_: persisted phase, status cache, ready flag

**Session Context Revision**:
One atomic sparse update to persistent Session configuration, including model-visible settings and the Host-enforced Permission Mode. Omitted components continue from earlier revisions. An explicitly supplied Instruction Set records an update even if its bytes repeat; identical content references may be reused without coalescing the updates.
_Avoid_: rewritten system prompt, configuration snapshot

**Session Context Patch**:
A sparse change to persistent Session settings, independent of message submission. Omitted settings remain unchanged; later changes to the same setting replace its current value without rewriting history. New model requests use the committed Session state at their construction boundary; existing requests retain their selected inputs.
_Avoid_: message content, temporary override, generic configuration map

**Output Schema**:
An optional persistent Session setting selecting the shape of a model-generated Final Answer. The producing request freezes it; the provider adapter validates success, and workflow consumers receive that exact value. Absence selects ordinary text.
_Avoid_: Tool Catalog input schema, Workflow Output, result envelope

**Model Context**:
The exact replay recipe used by one model Operation: an optional selected Compaction Base followed by one total ordered suffix of canonical host inputs and accepted model Operation Resolutions. Core and the selected adapter validate that chosen base without searching backward for an alternative.
_Avoid_: Conversation, Session Context Revision, prompt cache

**Model Request Manifest**:
The immutable references and digests that identify the provider protocol operation, requested concrete model, Instruction Set, Tool Catalog, totally ordered Model Context, replay format, behavior-affecting protocol options, limits, and output contract consumed by one model Operation.
_Avoid_: raw HTTP request, credentials, mutable provider defaults

**Instruction Set**:
Immutable instruction content in Session configuration. Its model-visible use is bound through the fixed initial prefix or an appended System Instruction; later requests replay those historical bindings rather than rewriting earlier instructions from current settings.
_Avoid_: complete model request, Tool Catalog, provider system field

**Compaction Base**:
The derived role of an accepted compaction model Operation Resolution when a later Model Request Manifest selects its replacement Model Context. Its creating Operation's source manifest defines the complete covered frontier and lineage; that Operation owns the immutable replacement output. It is not a separate authoritative row or a rewrite of Conversation.
_Avoid_: Compaction Checkpoint, Conversation rewrite, retention, reducer checkpoint

**Workspace**:
The working-directory context of a Session, used as the starting point for relative tool paths. It is not a filesystem sandbox or a boundary on which accessible files tools may operate.
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
_Avoid_: Execution Evidence, Operation Resolution, raw evidence

**Spillover Tool Result**:
A Tool Result containing a bounded excerpt, an explicit notice that more output exists, and an ordinary temporary-file path for reading the full output through the existing Bash tool. The saved excerpt and command outcome remain part of Conversation; the full temporary output need not survive a crash.
_Avoid_: failed Tool Call, complete inline output, durable Content Reference

**Spillover Output**:
Complete temporary Tool Call output reachable through a Spillover Tool Result path. The [shared retention policy](docs/architecture/resources.md#shared-temporary-file-retention) may remove it after active use, including while an external reader holds it open. Loss changes no saved result and permits no automatic replay.
_Avoid_: Conversation Entry, diagnostic log, durable Content Reference

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
One ordered canonical provider-result item owned by the resolved model Operation. It retains supported semantic fields, provider-only continuation fields, and response-evidence fields exactly once; a provider adapter derives any later replay-input view from it.
_Avoid_: Conversation Entry, Provider Replay Receipt, raw HTTP or SSE frame

**Validation Profile**:
The versioned strict-data rules used to validate model tool arguments and provider-neutral output.
_Avoid_: provider validation, canonical JSON spelling

### Operations and effects

**Action**:
One policy-valid request by the Agent for external work. V1 admits Bash and one-file exact Edit Actions.
_Avoid_: Tool Call, command text, Final Answer

**Operation**:
A uniquely identified unit of model or Action work within a Turn, owning its exact request and causal source, current execution/retry facts and eventual immutable Operation Resolution. Its accepted content is owned by reference, and its identity identifies the final result.
_Avoid_: Turn, Attempt, Action

**Operation Ordinal**:
The durable order of Operations within one Turn.
_Avoid_: global sequence, generation, timestamp order

**Attempt**:
One uniquely identified physical try to execute an Operation. Its admission is recorded in that Operation's current execution facts before launch; historical Attempts are not separate durable entities.
_Avoid_: Operation, retry policy, request notification

**Execution Evidence**:
The terminal observation delivered by an Attempt's effect owner for validation and settlement. It is transient until the Operation commits the required retry facts or immutable final meaning and retained evidence.
_Avoid_: Operation Resolution, durable Completion, Turn Outcome

**Operation Resolution**:
The optional final semantic value owned directly by an Operation, absent while unresolved and immutable once committed. Its basis may be validated Execution Evidence, permission denial, validation failure, interruption, cancellation or recovery uncertainty; its identity is the Operation identity, not a separate result identity.
_Avoid_: Execution Evidence, separate Resolution entity, Turn Outcome

**Interrupted Resolution**:
An Operation Resolution ending one exact unresolved Model Operation without accepted output, caused by direct Model Interruption or an applicable Session stop. It records abandonment, not provider termination. Direct interruption may permit the Turn to continue; Session stop fences selected work. [Execution and settlement](docs/architecture/execution.md#host-runtime-execution-and-settlement) owns provenance and applicability.
_Avoid_: Turn Outcome, failed Attempt, process detachment

**Indeterminate Resolution**:
An Operation Resolution stating that external state may have changed but the terminal effect cannot be proved. It is evidence for the Agent's next decision unless the Turn cannot safely continue.
_Avoid_: automatic retry, User escalation, generic failure

**Reconciliation**:
Comparison of durable intent with observed external state. Historical Edit recovery required this comparison; current tool recovery records uncertainty without mandatory inspection. A later observation does not prove which action produced the current state.
_Avoid_: replay, generic retry, database recovery

**Edit Intent**:
The immutable mutation proposal for one existing file, binding Workspace, exact target path and a nonempty list of whole-line ranges with expected and replacement text before Authorization. Lines start at 1; ranges include the start and exclude the end, with equal endpoints inserting empty expected text. All ranges refer to the same pre-edit state and must pass applicability checks before mutation. Admission requires no target read, whole-file freshness or relocation.
_Avoid_: edit result, approval, workspace snapshot

**Dispatch Permit**:
A volatile one-shot capability returned only to the invocation that committed fresh Attempt admission. It permits physical launch subject to the Physical Custody boundary and intervening interruption. Recovery cannot recreate it.
_Avoid_: Attempt, Authorization, lease, ownership epoch

**Physical Custody**:
A bounded transient Host record owning resources for a prospective/admitted Attempt. Its atomic launch boundary distinguishes suppression from cleanup after an effect may have started. It carries neither payload nor semantic authority. Proposal-only Edit approval needs no target preparation custody.
_Avoid_: Operation state, database authority, Session ownership

### Permission and cancellation

**Permission Request**:
An immutable durable request for a Principal's decision on one exact proposed Action and descriptor. Absence of a Permission Decision means the request remains actionable while its Operation and applicable Session stop/terminal facts permit admission.
_Avoid_: input request, prompt, notification, User Message

**Permission Decision**:
The single allow-once or deny decision for one exact Permission Request. An allowed decision may establish Authorization; it is never Conversation content.
_Avoid_: User Message, generic response batch, permission text

**Permission Required**:
A public Run condition in which at least one Permission Request is actionable and no other member Turn can currently progress.
_Avoid_: blocked Turn, suspended, generic waiting

**Session Stop**:
A request to end the current work selected in a Session, regardless of who submitted it. Completion means that work has a terminal outcome and has released the Session for reuse; an idle stop completes immediately. Acknowledging the request does not mean it has completed, and completion does not prevent later Session work.
_Avoid_: Session closure, Host shutdown, provider cancellation acknowledgement

**Run Cancellation Intent**:
Durable intent fencing new evaluation/call creation for one Run. Workflow Runtime first recovers saved unanswered submissions, then stops current work in Sessions reached through accepted message calls. Configuration alone is not rolled back and adds no stop target. Until the terminal Run outcome records completion, recovery may repeat stops and affect newer shared-Session work.
_Avoid_: Turn Cancellation Intent, core Run fence, Permission Request, process detachment, terminal outcome

### Workflows and runs

**Workflow Definition**:
A program that names Sessions, configures them, composes keyed message results and returns one Workflow Output under evaluator resource limits.
_Avoid_: Workflow Run, scheduler, agent runtime

**Workflow Runtime**:
The public module owning Run lifecycle, saved calls/results, replay eligibility, cancellation and submission through the Session core API. It contains the private Workflow Evaluator. Earlier references to the workflow coordinator describe this module's coordination responsibility, not a separate public component.
_Avoid_: Session core, Host Runtime, evaluator, separate service

**Workflow Evaluator**:
A private disposable mechanism inside Workflow Runtime that evaluates one Workflow Definition against one immutable Evaluation Generation and returns requested calls plus an outcome. It has no durable state or independently supported public lifecycle. Its process containment remains explicit.
_Avoid_: Workflow Runtime, Host Runtime, retained workflow, agent runtime

**Evaluation Generation**:
One immutable evaluation input binding source, arguments, semantics, evaluator limits, and a Visibility Snapshot. An interrupted evaluation is abandoned after a Host crash; recovery admits a fresh generation rather than reconstructing the old view.
_Avoid_: JavaScript continuation, live completion stream

**Workflow Run**:
The durable identity binding one Caller Run Key, exact workflow inputs, Evaluation Generations, keyed Session operations and original results, and terminal outcome. Internal work references may be shared across Runs without ownership of Session history.
_Avoid_: evaluator process, Session, durable heap

**Run Key**:
A Caller-supplied idempotency key that creates or reattaches one Workflow Run when all bound inputs match.
_Avoid_: Run identity, Agent Call Key, display name

**Agent Call Key**:
A Caller-defined identity for one Session configuration or message submission and its recorded result within a Workflow Run. These operations share a Run-local namespace; Workflow Runtime scopes it by Run identity to construct the core Request Identity. Different messages may share a work outcome.
_Avoid_: Session Key, Turn identity, Run Key, system ID

**Visibility Snapshot**:
The immutable run-local set of recorded operation results and stable failures visible to one Evaluation Generation. The Workflow Runtime freezes it from its own recorded results; later arrivals belong to a later generation. It is not a simultaneous cross-Session status snapshot.
_Avoid_: live completion stream, Conversation

**Blocked Workflow Run**:
A nonterminal Workflow Run suspended on unresolved recorded dependencies. A branch may continue when its own dependencies become available; unrelated branches need not finish first.
_Avoid_: Permission Required, retained JavaScript

**Turn Output**:
The bounded workflow-visible value produced by one successful Turn Outcome.
_Avoid_: Workflow Output, Tool Result, provider response

**Workflow Output**:
The bounded strict-data value durably committed with a completed Workflow Run.
_Avoid_: Turn Output, Final Answer

**Run API**:
The caller-facing Run operations owned by Workflow Runtime and ordinary Session operations owned by Session core, exposed through the local adapter. These include admissions, observation, permission, stopping, cancellation, exact Model Interruption and content reads. Callers do not schedule internal progress.
_Avoid_: Run Service, CLI, generic command dispatcher, wire protocol

**Run Snapshot**:
A complete progress read model composed from workflow records and ordinary core observations. It exposes exact full keys of associated durable Sessions and enough existing label/context to select one for reuse. It may briefly lag across owners and need not represent one global committed moment. It grants no mutation authority and is distinct from fixed evaluator visibility.
_Avoid_: durable authority, event stream, Harness Projection, Workflow Output metadata

### Runtime and storage

**Host Runtime**:
The explicitly started local server and sole live owner coordinating Workflow Runs, reusable Sessions, Turns, external execution, and bounded capacities for one Host Store. Its lifetime and advancement are independent of clients.
_Avoid_: Agent, Session, Storage Owner

**Host Store**:
The sole recoverable OnePage-owned semantic and content store, containing canonical relational domain rows and immutable content. Credentials in the selected credential store are non-semantic security material.
_Avoid_: Session Ledger, blob store, Workspace

**Storage Owner**:
The exclusive gateway for Session core tables and content. Workflow Runtime persistence has separate logical ownership; deployment may share a Store without permitting cross-module table access.
_Avoid_: Session owner, database connection exposed to callers

**Decision Snapshot**:
A transient bounded query result containing facts needed for an operation. It is never persisted or treated as a second authority. This term does not require a common snapshot structure or a separate classifier layer.
_Avoid_: Core State, checkpoint, semantic view

**Active Capacity**:
The startup-fixed maximum population of prospective/admitted executions and outstanding physical cleanup. Permission and capacity waits retain no credit.
_Avoid_: Session population, total RSS, preallocated resource bundle

**Neutral Work**:
The empty representation of a startup-allocated Physical Custody record. Advancing it does nothing; it owns no execution resources, has no durable Operation or Attempt, and consumes no occupied Active Credit. Safe release returns an occupied record to this representation.
_Avoid_: queued Operation, synthetic Attempt, durable job

**Active Credit**:
One occupied Physical Custody record, charging shared concurrency from reservation through execution and safe physical cleanup. Permission waits consume none. Semantic completion alone cannot release resources still in use.
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
A typed domain-separated digest that binds exact bytes for one identity, content or authorization role.
_Avoid_: identifier, authentication tag, tamper proof

### Constraints

**Constraint**:
A rule preserving semantic correctness, memory efficiency or simplicity, or a concrete security, compatibility, effect-safety/spending or termination boundary. Expected workload size or generic robustness alone does not justify one.
_Avoid_: decorative limit, generic constraint engine

**Invariant**:
A semantic predicate enforced by its authoritative construction, such as identity, ordering or occupancy; it is not configurable resource policy.
_Avoid_: quota, Verification Target

**Fixed Boundary**:
A non-adjustable maximum derived from an exact representation, dependency, consumer or bounded algorithm, with a unit and explicit violation result. Workload observations alone cannot create one.
_Avoid_: measured percentile, configurable allowance

**Resource Budget**:
An adjustable allowance owned and accounted for at one resource or external-effect scope, with explicit exhaustion and release behavior. Defaults are selected policy whose evidence and qualification status must be stated; no separate hard maximum exists without a Fixed Boundary.
_Avoid_: Verification Target, reserved memory implied by a disk allowance

**Verification Target**:
A specified workload, metric and pass condition used to qualify an implementation. It never rejects production work.
_Avoid_: runtime admission counter, passing evidence inferred from acceptance

### Shared request protocol amendment

**Request Identity**:
An opaque Store-scoped identity supplied to core Session configuration or message submission. It binds exact request inputs and the first committed admission answer, including rejection. Matching repeats recover that binding; changed inputs conflict. It does not identify a tool execution attempt.

**Workflow Submission Intent**:
The workflow's durable record of a call's identity and exact inputs, saved before sending it to the core. The workflow derives identity from Run identity and its Run-local Agent Call Key and saves the core answer separately. Unanswered intents are resubmitted after interruption, including during cancellation. Core request records do not contain Run membership; workflow records own that relationship. This amends earlier integrated Host/Run descriptions without requiring separate processes.
