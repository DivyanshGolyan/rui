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
Persistent Session configuration, defaulting to `ask`, selected and bound at each child Action admission. `ask` creates an exact Permission Request; explicit `bypass` creates exact Authorization without a request. The Local Owner may change the mode during active work. Existing requests, Authorizations, and running actions keep their admitted meaning; recovery never reselects their mode. Server access alone does not select bypass.
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
One immutable User text, assistant text, Tool Call, Tool Result, or System Instruction in a Conversation, with exact Turn and causal provenance.
_Avoid_: event, mutable message, provider frame

**System Instruction**:
An immutable Conversation Entry carrying an appended operator instruction or host-supplied contextual update for the model. Session history distinguishes it from User text, assistant output, and tool content. Later changes append another instruction rather than rewriting it. Its provider representation must preserve instruction authority and legal placement; it cannot grant Action Authorization. First inclusion commits atomically with its assistant-response request; exact storage encoding remains implementation work.
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
The total semantic classification derived from committed facts. Run membership summaries use exactly runnable, waiting for permission, in flight, completed, failed, or cancelled. Derivation is ordered: terminal Outcome wins; otherwise an unresolved Operation with current admitted-execution facts or current future retry eligibility is in flight; otherwise an actionable Permission Request with no remaining progress is waiting for permission; otherwise the Turn is runnable. `Permission Required` is reserved for the Run-wide condition where no member can progress.
_Avoid_: persisted phase, status cache, ready flag

**Session Context Revision**:
One atomic sparse change to persistent Session configuration, including model-visible settings and the Host-enforced Permission Mode. Unchanged components continue from earlier revisions.
_Avoid_: rewritten system prompt, configuration snapshot

**Session Context Patch**:
A sparse change to persistent Session settings, independent of message submission. Omitted settings remain unchanged; later changes to the same setting replace its current value without rewriting history. New model requests use the committed Session state at their construction boundary; existing requests retain their selected inputs.
_Avoid_: message content, temporary override, generic configuration map

**Output Schema**:
An optional persistent Session setting describing the shape of a model-generated final answer. Each applicable model request freezes its selected schema in the Model Request Manifest. The provider adapter translates and validates it at the provider boundary; workflow consumers receive the exact validated value. Without a schema, the final answer is ordinary text. It is not a per-message override or a transformation of prose.
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
The complete output of a Tool Call kept temporarily outside Model Context and accessible through the file path in its Spillover Tool Result. Once saved result publication and execution no longer need it, the full output may be discarded under the shared oldest-first temporary-file policy, even if another program still has it open. Losing it does not change the saved result or authorize automatic execution of the old call.
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
The optional final semantic value owned directly by an Operation, absent while unresolved and immutable once committed. Its basis may be validated Execution Evidence, permission denial, validation failure, interruption, cancellation, reconciliation or recovery uncertainty; its identity is the Operation identity, not a separate result identity.
_Avoid_: Execution Evidence, separate Resolution entity, Turn Outcome

**Interrupted Resolution**:
An Operation Resolution stating that one exact unresolved Model Operation ended before any result was accepted. Its causal provenance is exactly one of: an authorized direct Model Interruption binding the Local Owner and exact command-target provenance, or an applicable ordinary Session stop with its causal command provenance, including the Run Cancellation Intent when propagation caused the stop. An interrupted Model Operation need not have terminal Execution Evidence; this records deliberate abandonment, not an assertion that the provider stopped processing. It ends only that Operation. The Turn may continue through independently admitted User Messages after direct interruption; an applicable Session stop fences that work and eventually yields a cancelled Turn Outcome. A Run intent alone fences the Run, not every Turn in a Session it once used. Actions cannot receive the direct interruption command.
_Avoid_: Turn Outcome, failed Attempt, process detachment

**Indeterminate Resolution**:
An Operation Resolution stating that external state may have changed but the terminal effect cannot be proved. It is evidence for the Agent's next decision unless the Turn cannot safely continue.
_Avoid_: automatic retry, User escalation, generic failure

**Reconciliation**:
Resolution of an uncertain Operation by comparing durable intent with observed external state.
_Avoid_: replay, generic retry, database recovery

**Edit Intent**:
The immutable one-file replacement description binding Workspace, target, exact search and replacement content, preimage, and expected postimage before Authorization.
_Avoid_: edit result, approval, workspace snapshot

**Dispatch Permit**:
A volatile one-shot capability issued only to the command that committed a fresh Attempt admission on its Operation. It authorizes but does not oblige physical launch after commit; a later committed interruption may suppress it before the owner crosses the Physical Custody launch boundary. It is not durable semantic authority and reconstruction never recreates it.
_Avoid_: Attempt, Authorization, lease, ownership epoch

**Physical Custody**:
A bounded Host record representing transient resource ownership for active Edit preparation or a prospective/admitted Attempt. Preparation occupancy grants no authority to mutate a target. One atomic launch-boundary transition distinguishes suppression before an external effect from cleanup after it may have started. The record contains no payload or semantic state, and loss of custody never rewrites durable meaning.
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
Durable intent to end one Workflow Run and stop the current work in every Session to which that Run has submitted a message. Other workflows using those Sessions observe the same stops. While cancellation is unfinished, recovery may repeat its Session stops, including earlier successful or idle stops; callers coordinate Session reuse. Completion follows ordinary Session-stop completion regardless of who submitted the stopped work. The existing terminal Run outcome records completion and prevents further propagation on recovery. Sessions remain reusable. No per-Session propagation receipt is required.
_Avoid_: Turn Cancellation Intent, Permission Request, process detachment, terminal outcome

### Workflows and runs

**Workflow Definition**:
A bounded program that creates Sessions, composes keyed message results, and returns one Workflow Output.
_Avoid_: Workflow Run, scheduler, agent runtime

**Workflow Evaluator**:
A disposable Host-managed mechanism that evaluates one Workflow Definition against one immutable Evaluation Generation.
_Avoid_: Host Runtime, retained workflow, agent runtime

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
A Caller-defined identity for one Session creation, configuration change, or message submission and its recorded result within a Workflow Run. These operations share the key namespace; different messages may share a work outcome.
_Avoid_: Turn identity, Run Key, system ID

**Visibility Snapshot**:
The immutable run-local set of recorded operation results and stable failures visible to one Evaluation Generation. It stays fixed during that evaluation; crash recovery captures a new view of currently available original results. Fixed visibility does not require eagerly decoded values: the bridge looks up and decodes original outcomes on demand without a decoded-answer cache.
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
The narrow typed boundary of the Host Runtime for Run and Session admissions, observation, permission, stopping, cancellation, exact Model Interruption, and content reads. Bounded driving is internal to the Host; callers do not schedule progress.
_Avoid_: Run Service, CLI, daemon, wire protocol

**Run Snapshot**:
A complete read model captured from one committed view of canonical Run, Session, internal work, permission, and effect facts. Later progress does not invalidate that captured report; its revision grants no historical snapshot service or mutation authority.
_Avoid_: durable authority, event stream, Harness Projection

### Runtime and storage

**Host Runtime**:
The explicitly started local server and sole live owner coordinating Workflow Runs, reusable Sessions, Turns, external execution, and bounded capacities for one Host Store. Its lifetime and advancement are independent of clients.
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
The startup-fixed maximum population of shared active Edit preparation, prospective/admitted execution, and outstanding physical cleanup. Permission and capacity waits retain no credit.
_Avoid_: Session population, total RSS, preallocated resource bundle

**Active Credit**:
The accounting term for one occupied in-memory Physical Custody record. Occupancy reserves one unit of shared Host concurrency for active Edit preparation or a prospective Attempt, retaining it until physical resource cleanup is safe. Waiting for permission holds no credit; approved execution reacquires one. Logical completion alone does not release resources still in use.
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
