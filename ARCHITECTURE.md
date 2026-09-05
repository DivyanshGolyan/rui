# OnePage architecture

This document is normative. [`CONTEXT.md`](CONTEXT.md) defines the domain language; accepted ADRs explain hard-to-reverse decisions. Historical design, spike, and research documents are evidence, not authority.

## System shape

```text
CLI / script clients
  │ HTTP over the Store-derived Unix socket
  ▼
one Host Runtime server
  ├── local HTTP adapter ──► typed Run API ──► Storage Owner ──► SQLite
  ├── bounded Session / Turn / Operation advancement
  ├── disposable Workflow Evaluators
  └── I/O Reactor and temporary external-effect custody
```

One native Zig **Host Runtime** owns one **Host Store**, every live execution resource, every disposable evaluator, and one narrow typed **Run API**. The Run API is a module boundary, not another component or lifecycle. The local HTTP adapter exposes typed operations over a Store-derived Unix socket. CLI and script clients submit commands and read committed facts; JSON belongs to the external adapter and Markdown rendering to the CLI. QuickJS evaluates Workflow Definitions but owns no Session, provider, tool, permission, recovery, or durable state.

A **Session** is one reusable linear Conversation in one Workspace and access scope. A **Turn** begins with one initiating User Message and advances that Session until Final Answer or a typed terminal outcome. At most one Turn is nonterminal in a Session. A **Workflow Run** binds each Run-local operation key to its creation, configuration, or message admission and original result. Multiple messages and Runs may share one internal Turn outcome; there is no intermediate Job domain or exclusive Run ownership of Sessions.

## Simplicity rule

Each durable fact has one relational authority. Each resident byte has one current production consumer, one population multiplier, and one release boundary. Each interface owns one decision and hides its mechanics.

Use established mechanisms without transferring OnePage policy to them: SQLite owns transactions and journal recovery, Git owns patch parsing/application, libcurl owns bounded HTTP/TLS transport, and the OS credential store owns subscription credentials. OnePage retains model-visible context selection, operation admission, permissions, effect recovery, and Conversation meaning.

V1 has no generalized scheduler, provider registry, OAuth framework, runtime tool registry, plugin loader, durable JavaScript continuation, separate daemon manager, event bus, or generalized protocol-adapter framework. The accepted local HTTP adapter is part of the single Host server. A new abstraction requires a current second consumer or an invariant that cannot fit an existing deep module.

## Server ownership and local clients

`onepage serve` acquires exclusive OS-held Store ownership before recovery, endpoint reclamation, or dispatch, and holds it until this process can no longer dispatch or write semantic facts. A second server for the same Store is rejected. One bounded canonical Store selector must be shared by locking and socket discovery: equivalent supported path spellings cannot create two owners, unsupported aliases must reject, and Unix socket path limits must fail explicitly. PID metadata, socket existence, client timeout, and an absent Completion never prove ownership or effect termination.

Protect the socket and containing directory with filesystem access controls. Validate intended Store identity and wire version before mutation. Every admitted client acts for the same Local Owner; there is no per-client ACL or implicit tool bypass. Clients never open SQLite or auto-start a server. Unavailable, mismatched, or inaccessible owners fail without fallback. Only after acquiring Store ownership may startup reclaim the expected owned stale socket; it must not unlink an unexpected file or another live owner's endpoint.

Server lifetime is independent of clients. It drives bounded quanta while work is eligible. Infrastructure stop fences new dispatch promptly, interrupts supported effects, preserves available terminal evidence, and performs bounded cleanup without waiting deliberately for LLM completion. Stop and crash do not insert Run cancellation, ordinary Session stop, or user-command Interrupted facts merely because execution becomes unavailable. Explicit restart recovers committed unfinished work using effect-specific rules and remaining budgets, with possible replacement model cost. Loss of ownership is not proof an external effect stopped.

Mutation acknowledgement follows semantic commit. The CLI does not automatically repeat mutations: proven pre-submission failure differs from uncertain acknowledgement loss. Direct Session creation and messages are keyless; explicit resubmission can create another Session/message. Run creation and workflow operations preserve their original keys and canonical bindings for caller-controlled replay. Permission and other controls retain their exact domain uniqueness and applicability rules. HTTP adds no generic command journal, WebSocket, subscription, TCP listener, or per-Run pause/resume system.

Streamed ingress is bounded, charged, validated, and sealed before the referencing semantic admission. Incomplete uploads publish no content or semantic reference. Inbound client connections, slow transfers, completed inspection scratch, and external Active Capacity are separate resource populations; selected budgets must preserve execution and control under connection pressure.

## Canonical relational authority

The Host Store is the sole recoverable OnePage-owned semantic and content store. OS-held credentials are non-semantic security material. Its canonical relationships are equivalent to:

```text
sessions
user_messages
conversation_entries
session_context_revisions
session_context_changes
turns
operations
model_request_manifests
model_context_items
attempts
attempt_completions
model_output_items
operation_resolutions
permission_requests
permission_decisions
run_cancellation_intents
workflow_runs
run_turn_memberships
evaluation_generations
content
```

These are the accepted baseline relationships, not frozen SQL names. Changes to ownership or durable guarantees require an explicit decision and document amendment; the open execution-model comparison does not silently replace this baseline. Exact mapping of keyed Session operations and ordinary stop/Run settlement remains implementation work.

SQLite constraints and transactions establish identity, parentage, uniqueness, occupancy, ordering, and settlement. OnePage does not persist a generic Session Ledger, reducer image, continuation blob, cached lifecycle phase, or shadow frontier beside these rows. A loaded Session, Turn, or Decision Snapshot is a bounded query result and never a second source of truth.

The Host Store atomically enforces:

- one linear Conversation per Session;
- immutable User Message admission order with at most one Conversation Entry projection per message;
- at most one nonterminal Turn per Session;
- one terminal Turn Outcome;
- at most one Attempt Completion per Attempt;
- one Operation Resolution per Operation;
- exact Attempt identity and ordinal within an Operation;
- exact causal parentage between model Operations, Tool Calls, child Action Operations, and Tool Results;
- immutable Permission Requests with at most one Permission Decision;
- idempotent Run creation and keyed Session operations by exact canonical binding;
- distinct keyed message admissions may share one Turn and its outcome across Runs;
- at most one Run Cancellation Intent per Run; and
- content publication together with its first durable reference.

Turn Condition, Session dormancy, Run `permission_required`, runnable work, and observer summaries are derived from canonical rows. Persist a derived value only after measurement proves that an index is necessary; it remains rebuildable and non-authoritative.

V1 is a flag day. Unreleased databases and fixtures are recreated; no ledger-to-relational migration, compatibility reader, alias table, or dual-write path is permitted.

## Conversation and Turns

Conversation contains five immutable V1 entry kinds: User text, assistant text, Tool Call, Tool Result, and System Instruction. Each entry records its Turn and exact causal source. Compaction never edits or deletes these entries.

Starting a Turn is one transaction against an already-created Session with a complete baseline. Admission validates current identity, Workspace, occupancy, canonical keyed inputs where applicable, and every locally decidable continuation-compatibility precondition without provider I/O. It creates the Turn, initiating User Message, and Conversation Entry together. Persistent configuration changes are independent admissions, not a patch bundled with the first message. Model settings are selected when constructing each model request, not frozen at Turn admission; ordinary Session messages require no caller historical revision guard.

The same Session message primitive serves direct clients and workflows. When idle it creates the Turn, initiating User Message, and its Conversation Entry atomically; when active and admissible it joins that work. A workflow additionally commits its key/input/admission/result binding atomically; a direct submission has no caller idempotency key. A later User Message inserts one immutable `user_messages` row with exact Session, internal Turn, admission ordinal, content, and Local Owner provenance; it does not create a Conversation Entry or change an admitted Model Request Manifest. Immediately before admitting the next model Operation that requests an assistant response, one transaction projects every applicable unprojected User Message into Conversation in admission order and freezes the resulting manifest. An internal compaction model Operation reads only already-applied Model Context and leaves pending User Messages unprojected. The unique projection relation derives whether a message remains pending; there is no message phase, batch entity, or resident queue. A Permission Decision authorizes or denies one exact proposed Action and is not Conversation content. Successful Turn settlement requires no applicable unprojected User Message, actionable Permission Request, unresolved Operation, applicable Completion, or admitted effect that can still change its outcome. Terminal failure uses the precise pending-message exception below. Turn settlement and logical Session occupancy release commit atomically.

Accepted Conversation entries remain canonical after a failed or cancelled Turn. A Session never succeeds, fails, or closes.

## Sparse context and exact model requests

“System prompt” is not one mutable value. OnePage separates:

- persistent Session defaults;
- exact Action permissions and limits on their actual execution scope;
- bounded Conversation projection; and
- exact model-Operation input.

A **Session Context Revision** atomically records only changed persistent components from this closed V1 set:

- model binding;
- Instruction Set;
- Tool Catalog;
- context policy;
- reasoning defaults;
- optional output schema;
- Host-enforced Permission Mode; and
- default output limits.

Session creation and its first complete revision commit atomically. No Turn may be admitted without that baseline. Later revisions are sparse. Each new model request selects the current committed Session Context Revision and resolves the model settings at or before that revision. Action admission independently selects the current Permission Mode; it is not tool authority frozen by a model request. Unchanged components keep their immutable content reference and digest.

```text
r1: model=A, instructions=I1, tools=T1
r2: tools=T2
r3: instructions=I2

resolve(r3) = model=A, instructions=I2, tools=T2
```

A new model request is constructed from one committed view of current Session configuration and its applicable canonical inputs. Its Model Request Manifest freezes the selected revision, resolved settings, input references, and request semantics. Later changes affect only requests not yet constructed; replacement Attempts reuse their existing manifest. There is no Turn-wide copy of model settings, per-setting activation queue, or requirement that every intermediate configuration value be used. Configuration alone creates no model work. Validity and continuation compatibility remain separate from this common construction boundary.

Append-only model-visible updates are the accepted direction. Keep the initial instruction prefix stable and preserve previously supplied messages and provider continuation. Later instruction/context changes enter at a fixed position in the model-visible history, using a provider-supported representation; new requests must preserve continuation compatibility as well as their own immutable retry inputs. Session configuration remains current state and changes independently of message submission. This does not make every Host setting a conversational message, require exposure of every unused intermediate value, authorize Workspace rebinding, or adopt a particular provider's tool/effort update protocol. Appended system instructions are a distinct Conversation Entry kind, visible in Session history alongside messages and tool results. The name is System Instruction, not a generic Context Update. First inclusion commits with the next assistant-response request as described below; exact storage/wire encoding remains implementation work. Existing permission admission and supported compaction contracts remain in force.

System Instruction first inclusion belongs to assistant-response request admission. Derive the last applied instruction from canonical Conversation and initial baseline references, even when a Compaction Base covers the entry. Compare effective instruction content, not revision numbers. After all preceding Tool Results and applicable User Message projections are ordered, validate the prospective replay recipe and atomically commit any net instruction change, those new projections, model Operation, and manifest referencing the entry. A rollback commits none of these new facts; prior inputs and independent configuration remain intact. Preserve immutable content/rendering references and causal request provenance without a separate pending row, applied flag, or application receipt. Recover an admitted request through its existing manifest rather than preparing it again. A -> B -> A emits nothing if B was never included; if B was included, restoring A requires another entry. An admitted failed request still establishes historical application, not proof of provider consumption. See the [boundary traces](docs/design/system-instruction-first-inclusion.md).

A selected configuration revision identifies desired current state; it does not authorize re-rendering earlier instruction positions from that state. The manifest freezes the actual initial-prefix and appended-instruction bindings.

Before admission, compaction reads already-applied Model Context and leaves unapplied instruction changes and pending User Messages for the next assistant-response request. Compaction selects and freezes its own controls without applying new conversation instructions. After an admitted overflow, compaction includes the already-recorded instruction. A later request does not duplicate unchanged instructions, including entries covered by the selected base; exact base/suffix compatibility must preserve their effective instruction meaning. Provider-specific re-establishment controls require demonstrated, frozen adapter rules rather than replaying a configuration mutation.

There is no separate Turn Contract or `turn_contracts` relation. Each fact belongs to its existing consumer. Model-visible date, time, timezone, and Workspace information live in the fixed initial instruction binding or an appended System Instruction, with immutable content/rendering inputs referenced by the request manifest. Tool-observed Workspace facts remain Completion evidence and Tool Results. The Session owns Workspace identity; Actions retain their exact descriptors and Permission Request/Authorization provenance. Do not recapture a Turn-wide environment snapshot or reread ambient values when retrying admitted work. This mapping adds no automatic clock refresh, Workspace polling, rebinding, or generic runtime-facts bag.

Resource controls retain their actual scopes. Host admission owns physical capacities, memory/workspace/scratch budgets, and current resource availability. Workflow Run bindings and Evaluation Generations own evaluator limits. Existing request/Operation bindings and retry eligibility own the selected per-Operation retry facts. If [issue #91](https://github.com/DivyanshGolyan/onepage/issues/91) retains a Turn-wide dispatch allowance or absolute deadline, store its typed values directly on the Turn and derive consumption from admitted Attempts across its Operations, including compaction; a fresh Operation or restart cannot reset that allowance. This does not choose numeric limits or introduce a new quota. The limit-matrix gate remains in force. See the [field audit and recovery traces](docs/design/turn-contract-removal.md).

Exact admitted Action descriptors and Authorizations remain valid historical targets; a configuration update does not rewrite them. This decision does not enable implicit bypass or revoke running tools.

Output schema is optional persistent Session configuration, selected by the same request-construction rule. Absence means ordinary final text. The adapter translates the selected schema into a supported provider mechanism and owns response parsing and schema validation at the provider boundary, using the producing manifest rather than current Session settings. Adapter validation runs within the existing bounded validation/import path, without another full response copy or per-Session validator worker. The Host still owns candidate admission, settlement, and exact result identity; the workflow consumes the validated value without a second schema interpretation. No prose-to-object conversion, automatic model repair call, per-caller output schema, or separate schema activation queue is added. Unsupported schemas, refusals, incomplete generation, and invalid output must not become fabricated structured success. Provider schema subsets and concrete error mappings belong to implementation. Codex subscription-endpoint support is an accepted planning assumption, not a live-tested compatibility claim.

Each model **Operation** binds one immutable **Model Request Manifest** containing references and digests for:

- the provider protocol operation, requested concrete model identity, and behavior-affecting protocol options;
- rendered Instruction Set;
- Tool Catalog;
- one exact Model Context replay recipe: an optional derived Compaction Base plus one total ordered suffix of canonical host inputs and accepted model Operation Resolutions;
- the replay format;
- exact content/rendering references for any supplied runtime information, without duplicating values already owned by instruction history;
- reasoning and output limits; and
- output contract.

The recipe freezes the selected Compaction Base and each ordered source identity needed to preserve complete provider-native rounds. Replacement Attempts reuse that manifest and reconstruct the same request semantics; they need not preserve JSON key order or other wire spelling with no provider meaning. Authentication secrets, access tokens, endpoints, sockets, HTTP headers that do not affect behavior, and transport buffers remain late-bound. A changed manifest requires a new model Operation.

The provider owns no OnePage semantic authority. Every value required to reconstruct a continuation is retained in the Host Store and frozen by the manifest. Provider-hosted caches and previous-response identifiers are optional accelerators only when their loss still permits the same request to be constructed from that frozen local recipe.

## Model output and multiple Tool Calls

One model Operation may resolve to assistant-only output or an optional bounded assistant-text prefix accompanied by an ordered bounded set of Tool Calls. All model-visible output and child-call descriptors validate before atomic admission; an invalid member rejects the complete candidate. Successful admission appends the optional assistant-text entry followed by Tool Call entries in call-ordinal order in one transaction. Assistant-only output is a Final Answer only when that settlement transaction proves that no earlier applicable unprojected User Message exists. If a User Message committed first, the output remains ordinary assistant text, no Turn Outcome is inserted, and ordinary advancement later projects the message and admits the next model Operation. If settlement commits first, the terminal Turn Outcome prevents that message command from attaching to the completed Turn. SQLite commit order therefore decides the race without a lifecycle branch outside the canonical transaction classifier. V1 has no model-created conversational Input Request; later input is a User Message admitted independently of model output.

A terminal model response is first retained losslessly and in provider order as immutable Model Output Items owned by its Attempt Completion. Each item stores its semantic fields, provider-only continuation fields, and response-evidence fields once. Its Operation Resolution selects the accepted Completion; the same transaction publishes every applicable provider-output Conversation projection by reference to those semantic fields. The provider adapter derives a later replay-input view by stripping response-only or non-replayable fields; OnePage does not persist a second replay copy or a complete serialized request body.

Unknown open fields inside a known item are preserved. An unknown consequential discriminator—such as a top-level item, content block, Action subtype, compaction variant, or terminal status—is preserved as Completion evidence but resolves as `unsupported_provider_output`; it publishes no Conversation, continuation, or effect consequence. Core neither exposes private reasoning through generic content reads nor fabricates meaning for opaque or encrypted reasoning, signatures, and compaction items. Raw HTTP and SSE framing, token deltas, partial streams, interrupted output, and late output are scratch evidence, not replay authority, and are deleted after successful canonical import.

Each Tool Call creates one child Action Operation with `caused_by_operation_id` and a stable call ordinal. No Step or Tool Call Group is durable authority: the child set is derived from that parent relation.

```text
model Operation M1
├── call 0 ──► Bash Operation B1
├── call 1 ──► Patch Operation P1
└── call 2 ──► Bash Operation B2
```

Child Operations execute and settle independently under Active Capacity, including within one Workspace. Each Completion and Resolution is committed when that child settles; no sibling holds it outside SQLite. After every child resolves, one transaction appends their Tool Result Conversation Entries in original call-ordinal order. Only then may the next model Operation start. Physical completion order never chooses Conversation order. Denial, failure, cancellation, and uncertainty each produce typed model-visible Tool Results.

OnePage provides no Workspace-wide fence, quiescence assumption, global Action serialization, or isolation claim against other agents and processes. Bash, Patch, and provider work may proceed concurrently under Active Capacity. A closed typed Action adapter gives Bash and Patch the same lifecycle while temporary execution custody exists only for an active Attempt. Patch correctness comes from exact preimage, expected postimage, and observed-state reconciliation.

## Host Runtime execution and settlement

An **Operation** is one model request or admitted Action. An **Attempt** is one physical try. An **Attempt Completion** records bounded observed evidence. An **Operation Resolution** records what OnePage may safely do next. These distinctions are durable because an external effect may outlive its process owner.

The explicitly started server control context is the sole Storage Owner and the only code permitted to use SQLite. Every mutation goes through one SQLite-specific command module. A command validates bounded syntax, reserves an Active Credit before a dispatching transaction, starts `BEGIN IMMEDIATE`, loads one bounded canonical Decision Snapshot, invokes one pure total classifier, writes one fixed relational mutation, checks exact affected-row counts, derives any consequence, commits, and releases that consequence only after successful `COMMIT`. Inspection and advancement use the same bounded loader and classifier.

One I/O Reactor multiplexes long-lived provider streams and subprocess pipes and observes temporary Action executors, including Patch. Execution machinery owns only volatile OS and library handles plus fixed borrowed windows while work is active; it cannot access SQLite or decide semantic meaning. One bounded content-free Physical Custody table implements Active Capacity: occupancy of one record is one Active Credit, not a second object or pool. There is no per-Turn driver, permanent Patch lane, retained worker, Session graph, candidate buffer, response buffer, parser workspace, or lifecycle object.

After Attempt commit, the Storage Owner asks the selected adapter to materialize an outbound request from the frozen manifest and canonical source items into an immediately unlinked scratch file through fixed windows. Neither the generated request body nor a second replay representation becomes authority. Execution consumes that descriptor and streams inbound bytes directly to another immediately unlinked scratch file. No SQLite transaction spans request construction, network or subprocess execution, filesystem mutation, or response streaming, except that the inspection read transaction may span its private report-scratch writes under ADR-0024. Scratch is dynamically charged, non-authoritative, and nonrecoverable; a process crash discards it and leaves the durable Attempt unresolved for effect-specific recovery.

Only after transport or execution reaches an effect-specific terminal boundary does its effect owner seal the scratch descriptor and hand it to the Storage Owner. The Storage Owner uses one shared serial validation/import workspace to parse complete model output or tool evidence, then normally commits immutable content, the Attempt Completion, the Operation Resolution, Conversation or permission facts, and the next semantic consequence in one transaction. The sole intentional Completion-only state is a retryable model Completion committed atomically with immutable retry eligibility while its Operation remains unresolved. SQLite eligibility rows are the retry queue; one periodic bounded query while the Host is running is the only V1 retry-eligibility trigger.

Variable caller content enters through a sealed source supplied to the semantic mutation that first references it. The Run API exposes no independent content-publication operation or caller-visible staged Content Reference. The Storage Owner verifies exact length, digest, media or schema type, and stable positional bytes while importing under its owning content and command-work contract; no semantic row may reference incomplete or unvalidated bytes.

Each Attempt can have at most one Completion. An exact replay returns the existing record; contradictory evidence is rejected rather than stored beside it. Cancellation records intent and may signal the live owner, but only the effect-specific terminal owner may propose Completion evidence. This removes the generic Completion Inbox, consumption watermark, two-transaction admission protocol, online stream detector, and scratch replay path.

The explicit model-interruption operation targets one exact unresolved Model Operation in nonterminal work. It validates the Local Owner, exact target and its canonical parentage, and current applicability in one transaction. The Interrupted Resolution retains the exact command target and causal provenance; domain repeat/conflict rules recover the prior result or reject conflicting/inapplicable input without a generic command ledger or mandatory direct caller key. No whole-Run revision gates the operation, and ordinary Session controls do not require callers to name a Turn. Its semantic mutation is insertion of the Resolution. It neither stops the whole Session nor decides whether another Operation follows. Ordinary advancement derives continuation only when independently admitted User Messages are applicable; otherwise ordinary terminality derives the cancelled Turn Outcome. Remaining observable repeat/error details belong to the Session/client decision, not an implementation-ticket copy.

An intentional model interruption may therefore commit an `Interrupted` Resolution without inventing an Attempt Completion. The pair of facts is authoritative: an Attempt without Completion under an unresolved Operation requires effect-specific recovery, while one under an Interrupted Resolution was deliberately abandoned and is never recovered or retried. The Resolution fences semantic acceptance but does not claim that the provider stopped processing or avoided billing. After commit, one atomic launch-boundary transition in the content-free Physical Custody record decides physical truth: if interruption wins before launch, the I/O Reactor suppresses the unconsumed Dispatch Permit; if launch wins, it closes or detaches the transport. This volatile race selects cleanup only and cannot alter the committed Resolution. Physical Custody and its Active Credit remain occupied until suppression or transport detachment completes; late provider output is discarded. V1 issues no separate provider-cancellation request and waits for no provider acknowledgement. Partial, interrupted, or late provider reasoning, signatures, compaction items, and other continuation material never become durable request input. Actions have no independent interruption command; Turn cancellation follows their effect-specific settlement rules because external state may have changed.

The V1 cancellation command targets one exact Workflow Run. It validates the Local Owner's command and request binding, then inserts the Run's unique Cancellation Intent. Exact replay returns the existing fact and a changed binding conflicts; no whole-Run expected revision is required. The intent immediately fences further evaluator generations and new creation, configuration, and message admissions from that Run. Message admission and this fence serialize, making the affected Session set stable. The intent alone does not fence every Operation through old Run–Turn membership.

An ordinary Session stop selects the current work once and fences its further advancement. Stop completion is the selected work's durable terminal outcome and atomic logical Session occupancy release; an idle stop completes immediately. Acknowledgement of the saved request is distinct from completion. Completion follows the selected work rather than future Session activity, and a stop does not rewrite an outcome committed before its admission. Existing tool Resolution and ordered Tool Result obligations must settle first. Model transport suppression/detachment may finish afterward under its existing Physical Custody owner, with Active Credit retained until release; logical completion does not free resources still in use or prove that a remote provider stopped processing or billing.

Bounded Host driving applies ordinary Session stops to current work in each distinct Session found through the Run's committed message admissions. Creation, configuration, or reads alone do not add Sessions. Each stop serializes with advancement and affects the selected current work regardless of which Run submitted it. A Session may be idle; stopping it is then a no-op. Other Runs observe the stopped outcome without themselves being cancelled. This control path remains permitted after the Run evaluator is fenced.

An unfinished cancellation pass may restart from the beginning after a crash. Use bounded disk queries and a disposable traversal position; do not persist per-Session propagation receipts, idle-check results, or a progress cursor. A stop that previously succeeded or found an idle Session may select newer work during the repeated pass. Callers coordinate Session reuse while cancellation is unfinished. Workflow cancellation completion composes ordinary Session-stop completion for every Session in the pass, regardless of which client submitted the work selected by a stop. There is no separate predicate that waits only for work submitted by the cancelling Run. Use the Session-level completion rule above; workflow cancellation adds no different effect-settlement policy. Request the required stops promptly through bounded traversal before awaiting completion, so one slow tool cannot delay stopping later Sessions. Every stop in a full pass must complete under that common contract before the existing terminal Run outcome can record cancellation completion; once that outcome commits, replay/recovery never runs the pass again. A crash after the final stop but before completion commit may repeat the pass. Failure to commit is not successful cancellation completion. Exact ordinary stop storage and Run settlement integration remain implementation work; no separate cancellation subsystem is introduced.

Ordinary Session stop authority governs admission and settlement of the selected work. If model-result settlement commits first, its Resolution remains valid and the stop governs remaining work. If the stop commits first, late provider bytes cannot bypass it; bounded driving records Interrupted Resolutions for unresolved Model Operations with causal stop provenance. A directly requested model interruption instead cites its Local Owner and exact command-target provenance. An unresolved Action with no Attempt resolves without execution. An Action with a committed Attempt must settle from terminal evidence or reconciliation. Active Bash receives best-effort process-group interruption. Patch may stop as not applied before mutation starts; after mutation starts it finishes bounded execution and reconciliation. Every accepted Tool Call still receives one typed Tool Result in call-ordinal Conversation order.

Pending User Messages and Permission Requests in stopped work become inapplicable through that work's ordinary stop/terminal facts. Their immutable admissions remain; no per-item withdrawal state or resident queue is added. The Session runtime retains effect-specific recovery, cleanup, and safe Turn settlement independently of the propagation loop. Run cancellation completion is not proof that a remote provider stopped processing or billing. No permanent Session fence or protection against overlapping callers is promised.

Attempt admission commits before physical dispatch. Only the invocation that observes that commit receives a volatile one-shot Dispatch Permit; reconstruction never recreates it. The commit durably admits the Attempt but does not oblige the owner to launch after a later committed interruption. Permit consumption and post-commit suppression compete through the Physical Custody record's one atomic launch boundary. The winner truthfully determines whether the external effect may have started; it never chooses semantic meaning. Failure while preparing post-commit request scratch is evidence for that Attempt, not authority to erase it.

## Effect-specific recovery

Recovery is effect-specific:

| Operation | Uncertain Attempt |
| --- | --- |
| Model | A policy-authorized replacement Attempt may reuse the same Model Request Manifest while recording possible duplicate work or billing. |
| Bash | Never replay automatically. Resolve as indeterminate and show the evidence to the Agent. |
| Patch | Reconcile the durable Patch Intent against preimage, expected postimage, divergence, or invalid target. |

SQLite owns transaction atomicity and recovery. OnePage owns semantic validation, external-effect uncertainty, and causal admission. It does not reimplement the pager or distrust the configured local machine without evidence.

## Tools and permission

The provider-neutral Tool Catalog does not grant execution authority. V1 maps only `bash` and `apply_patch` Tool Keys to executable Actions. Each child Action Operation binds a typed descriptor before permission or dispatch.

Permission Mode is persistent Session configuration, defaulting to `ask`. An admitted client acting for the Local Owner may explicitly change it through independent configuration, including during active work. The child Action admission transaction selects one committed current mode and binds its sparse configuration provenance with the exact validated descriptor. In `ask`, it creates one immutable Permission Request; in explicit `bypass`, it creates Authorization for that same descriptor without a request. Sibling Actions admitted in one transaction share its committed configuration view. A model request's earlier settings do not authorize subsequently admitted Actions.

A later mode change neither answers an existing Permission Request nor revokes an existing Authorization, including one whose Attempt has not started; it does not interrupt a running action. One Permission Decision still targets the exact request, Operation, and descriptor under the Local Owner's Authority. Ordinary cancellation and applicability checks remain in force. Recovery of a committed admission reuses its request or Authorization and bound provenance without rereading the current mode. If admission rolls back, no permission fact exists; a later fresh admission uses current configuration. Replay of a configuration operation returns its recorded result without reapplying its old mode. No Turn-wide policy snapshot, retroactive revocation mechanism, activation queue, resident permission worker, or separate permission history is introduced. Exact relational columns remain implementation work.

## Workflow Runs

A Workflow Run durably binds its Caller Run Key, Workflow Definition bytes, arguments, Workspace, semantics identity, evaluator limits, Evaluation Generations, keyed Session operations and original results, and terminal outcome.

The workflow receives creation, configuration, and messaging functions: `createSession`, `configureSession` (illustrative name), and `sendMessage`. Creation atomically records a Session, its complete baseline context, and its Run-local creation binding before returning the plain Session ID. It creates no Turn or model work; the Session may remain empty. The first message admits work against that existing baseline using the same primitive as later messages.

`sendMessage(sessionId, message, { key, ... })` binds a message admission to its original work outcome and returns that outcome through an ordinary Promise. All operation keys share one Run-local namespace and bind kind and canonical inputs. Equal replay recovers committed identity/admission/result; changed binding conflicts. Existing IDs require no wrapper or attachment. Messages from the same or different Runs may share an internal Turn and its outcome, including the output schema frozen by the request producing that outcome. Exact tables and transaction grouping remain to be finalized; no resident JavaScript object is durable authority.

Configuration is an independent sparse persistent Session update. Its effect and keyed result commit atomically. Replay recovers that result without reapplying an old update. Configuration and later messages are separate admissions; trusted clients may interleave updates and messages. No combined mutation, cross-call lock, historical revision guard, or rollback on later message failure is promised. Configuration alone starts no model work and adds no Session to the message-derived cancellation set.

The request-construction boundary and optional Session output schema are accepted. Other supported settings and the exact configuration acknowledgement shape stay open. The Turn Contract grouping is removed; resource-limit decisions remain with their assigned budget issues. Earlier combined creation, patch-with-message admission, temporary override, and Turn-wide model-setting freeze proposals are superseded.

Each evaluator starts from source against one immutable Visibility Snapshot of recorded Session operation results and stable failures. It returns the complete blocked set and exits. No JavaScript heap, Promise graph, continuation, bytecode, or completion callback survives a durable barrier. Workflow code cannot observe physical Turn completion order; V1 supports deterministic joins and excludes `Promise.race` and `Promise.any`.

Cancelling a Workflow Run first fences further evaluation and submissions from that Run, then applies ordinary stops to current work in every distinct Session found through its committed message admissions. If a crash interrupts cancellation before its completion is durably recorded, recovery may repeat the entire stop pass, including stops that previously succeeded or found an idle Session. Callers coordinate Session sharing and reuse while cancellation is unfinished; newer work may be stopped by a repeated pass. Once the existing terminal Run outcome records cancellation completion, recovery does not propagate that cancellation again. Use the existing Run Cancellation Intent, Run outcome, and ordinary Session stop/settlement facts; add no per-Session propagation receipts, idle-check records, durable progress cursor, or cancellation-specific queue. Effect-specific cleanup still applies; Sessions remain reusable. See the [accepted recovery trace](docs/design/workflow-cancellation-stop-mapping.md#accepted-simplification).

## Run interface

The Host Runtime exposes one narrow typed Run API and no separately instantiated Run Service. Its explicit semantic operations create or attach a Run, create and independently configure a Session, admit first or later messages to its current work, decide one Permission Request, interrupt one exact unresolved Model Operation when explicitly targeted, stop current Session work, and cancel one Run. Ordinary Session operations keep Turn identity internal. Each verb owns its distinct authority, concurrency, idempotency, and transaction contract; there is no generic native command or result union.

`drive` is a separate Host scheduler operation. One bounded quantum may settle evidence, admit consequences, release committed external work, and compose several individually atomic transactions before stopping at quiescence, an observable block, terminality, interruption, or quantum exhaustion. It is not one atomic mutation and returns only a small drive report. The server repeats it while immediate runnable work remains. Client mutations admit intent; they do not own scheduling, and no public `advance` call is exposed or required.

Current inspection captures a complete report of one Run under one read transaction on the Storage Owner's existing connection. Bounded private batches stream facts incrementally into immediately unlinked scratch; the revision and facts come from the same committed view. Other database admissions and settlements wait during capture. The owner finishes active statements and ends the transaction before delivery, so subsequent execution cannot invalidate the report and a slow client retains no database resources. Commands still validate current exact targets. One shared capture workspace and separately charged completed-report scratch have explicit cleanup on completion, failure, and abandonment. There is no public cursor or snapshot service. Capture time and aggregate scratch require resource budgets and measured whole-Host command latency; batching alone does not bound total work. See [ADR-0024](docs/adr/0024-capture-run-inspection-before-delivery.md).

Before starting another queued inspection capture, give already-ready control commands a bounded turn through the existing Host driving path. Do not drain an inspection backlog ahead of a ready stop/cancel or other control command. A capture already in progress retains its complete committed view and is not preempted between private batches. This adds no separate scheduler, priority-queue subsystem, second reader, WAL requirement, or public snapshot mechanism. The maximum acceptable delay from one capture and sustained-load fairness remain with the existing work/resource decisions.

Every actionable Permission Request and every other current logical collection member appears in the complete scan. Physical keyset batching is private and no logical collection cap, caller page size, or serialized continuation token exists. Variable fields are immutable Content References read through fixed windows. JSON is the complete versioned external contract and Markdown is its deterministic model-facing rendering, with wire encoding at the HTTP boundary and rendering in the CLI, outside the native Run API. Client interruption only detaches; server termination stops live execution until explicit restart. Truncated delivery is an explicit failure, not a complete report.

Every Run–Turn membership summary appears in exactly one category derived from committed Turn rows: `runnable`, `waiting_for_permission`, `in_flight`, `completed`, `failed`, or `cancelled`. Derivation has an exact precedence: terminal Outcome wins; otherwise an unresolved Operation with an admitted Attempt or immutable future retry eligibility is `in_flight`; otherwise an actionable Permission Request with no remaining progress is `waiting_for_permission`; otherwise the nonterminal Turn is `runnable`. A retry-delayed Turn therefore remains `in_flight` even when it owns no Active Credit and no physical effect is live. `permission_required` is reserved for Run state. A keyed message admission binds atomically to its selected work, which may already exist; its result never retargets to later Session activity. Public wire variants are compiled from this contract, not inferred from historical membership names.

Direct Session observation reads fresh committed facts. Waiting selects current work once at observation start and does not follow subsequent work indefinitely. History reads support recent entries, kind filters, and after-position queries; unapplied message content and reasons remain separately reachable without replaying history in every poll. These reads grant no remembered caller view, Session ownership, or historical revision precondition on later messages. Exact remaining public boundary choices stay in the Session/client decision; compiled public types and exhaustive golden fixtures own field names, tags, omissions, and string encoding of `u64`-class values. No handwritten duplicate wire schema is accepted.

## Provider authentication boundary

Codex remains one private authentication/transport adapter, without SQLite access, a Codex CLI dependency, or its own Conversation/retry authority. Resume derives the provider from the persisted model binding; it cannot substitute a fixture or different provider. Credentials remain in macOS Keychain and late-bound transport, never semantic manifests, logs, child environments, or workflow-visible content. Refresh preserves the validated account binding; account data decoded from the configured TLS peer's bearer token is routing metadata, not independently verified identity.

Encode all provider strings before JSON reuse with one bounded encoder covering quotes, backslashes, and every required control escape. Derive buffer capacity from worst-case expansion. Validate token/account values at construction and before HTTP-header reuse, rejecting NUL, CR, LF, other ASCII controls, and non-ASCII bytes. The compact access-token form consumed by account extraction has exactly three nonempty dot-separated segments. The shared syntax decision owns remaining account-ID grammar and length bounds. This requires no JWT signature verification, JWKS, discovery, generalized OAuth layer, or change to the trusted-peer model.

## Disposable evaluator construction

The evaluator receives an empty environment and three explicit stdio pipes; Host descriptor construction and close-on-exec own descriptor inheritance. It has no filesystem, process, imports, FFI, raw-descriptor, network, clock, randomness, credential, or storage capability. Core dumps remain disabled. Do not scan every descriptor number up to `RLIMIT_NOFILE` at each invocation, retain a process pool, or overwrite/free complete input/output/bridge mappings immediately before this disposable process exits. Those mappings have process lifetime and no subsequent in-process owner. This is not a sandbox guarantee after arbitrary native-code execution. The evaluator decision still owns independent containment limits; these lifecycle requirements do not select numeric caps.

## Capacity and memory

Physical Custody is one startup-sized in-memory table of content-free records. Use plain bounded table scans in V1, without a separate free list, active-record index, resident Session collection, or durable SQLite slot table. Reserve a record before Attempt admission; rollback returns the unused reservation, while successful admission permits dispatch only after its commit is observed. SQLite owns Session occupancy, Attempt/Resolution facts, cancellation and retry eligibility; it does not duplicate live handle ownership. Logical settlement does not free a record whose physical cleanup is still outstanding. Reuse requires safe resource release and rejection of stale or duplicate events by exact admitted identity. The accounting invariant is free records plus occupied records equals startup Active Capacity; it does not introduce a second credit pool.

When no runnable work or required deadline/poll is due, sleep until an existing I/O/control notification or required wake. Do not add periodic scans merely to revisit an empty custody table. The existing single bounded SQLite retry-eligibility poll remains; its cadence is a separate budget decision. This is not a whole-process prohibition on allocation after startup: library, evaluator, transport, and scratch resources retain their existing bounded ownership and accounting.

One startup-fixed `active_capacity` bounds the Physical Custody table. Reserving a free record before admitting an external Attempt occupies one Active Credit; releasing that same record after its physical resource obligations finish returns it. A cancelled model outcome may precede that release. Bounded Decision Snapshots and the shared validation/import workspace are borrowed serially; neither is preallocated per credit.

Durable Dormant Session, terminal Turn, and Blocked Workflow Run populations reserve no resident driver, Slot, Active Credit, thread, socket, subprocess, evaluator, materialized Conversation, or context graph merely by existing. Temporary cleanup after logical model cancellation remains owned and charged by the Host's Physical Custody until release, not by a resident Session object. Long-lived in-flight work may retain only its credit, content-free custody record, transport handles, and dynamically charged unlinked scratch.

Memory claims report whole-process RSS and the slope of each population separately: durable Sessions, terminal Turns, Active Capacity, provider transports, temporary Action executors and transport resources, SQLite, semantic-validation workspace, evaluator, and model-requested subprocesses. Workload memory is observed separately from OnePage-owned orchestration memory.

Every large value moves through explicit stages—SQLite or wire, unlinked scratch, one shared validation/import workspace, canonical SQLite content, and presentation window—with one owner and release boundary. Variable content goes to disk unless a measured CPU-critical operation requires a fixed borrowed memory window. A byte limit never authorizes a resident allocation of the same size.

## Compaction

Conversation remains complete. User Messages have no token-admission quota and are never silently split or truncated. The configured token value is an approximate **Compaction Trigger**, not a strict content ceiling: OnePage anchors on provider-reported usage where available and estimates only newly appended model-visible content. Every User Message admitted between consecutive assistant-response model Operations remains a distinct durable fact, and all are applied together when the next such Operation freezes its manifest.

When that estimate predicts pressure before pending User Messages are applied, OnePage may first create a compaction model Operation over only the already-applied Model Context; the pending rows remain unprojected until the following assistant-response model Operation selects the new base, projects every applicable message, and freezes its manifest. If the provider instead authoritatively rejects an already-admitted request for context overflow before output or effects are accepted, the rejected Operation resolves with its User Messages already applied, and compaction covers that committed context. Because compaction changes Model Context, continuation afterwards is a new model Operation with a new manifest rather than a replacement Attempt of the old Operation. An accepted compaction Resolution becomes a **Compaction Base** only when a later manifest selects it. Its creating Operation's complete source manifest defines coverage and lineage; its selected Completion owns the one canonical replacement output. No separate checkpoint row duplicates those facts.

Later model requests first select the newest accepted Compaction Base in the current lineage, then validate that exact base and append one complete total ordered suffix of canonical host inputs and accepted model Resolutions. Core proves structural replay-recipe validity: lineage, suffix completeness, content presence and digest, and supported stored format. The provider adapter separately applies only compatibility restrictions demonstrated by its wire contract. The total classifier requires both and persists no validity flag. A failed or unresolved compaction never displaces the selected base; missing, corrupt, unsupported, or incompatible material in the selected base fails explicitly as `continuation_unavailable` rather than selecting an older base or rebuilding from visible Conversation. A configuration change known to invalidate continuity is rejected atomically at configuration admission; request preparation separately validates its selected replay recipe. Codex V1 starts with the proven same-concrete-model rule and records both requested model and served-model evidence; broader compatibility requires adapter fixtures rather than a permanent Core equality rule. If compaction cannot produce a fitting compatible request under the allowed policy, the terminal-failure transaction records `ResourceExceeded` with any still-unprojected messages intact and inapplicable. A pre-request failure creates no fake model request; failure after an admitted request preserves its Resolution and already-applied context. Compaction never creates another Conversation or durable-history limit.

## Terminal failure with pending input

Accepted in [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102#issuecomment-5550577434).

A definitive inability to continue may settle a Turn as failed once every other semantic obligation is resolved: no unresolved Operation or admitted effect, actionable permission, applicable Completion, or required Tool Result publication may still change its meaning. Still-unprojected User Messages alone do not prevent this failed outcome. The same transaction inserts the unique failed Turn Outcome and releases logical Session occupancy; the outcome itself makes those messages inapplicable. Requiring their prior inapplicability would create a circular settlement condition. There is no separate early failure intent or per-message phase.

The failed outcome carries typed causal provenance. A pre-request validation failure such as `ResourceExceeded` belongs directly to the outcome, without inventing a Model Operation, manifest, Attempt, or Completion. Its failure provenance must identify the configuration revision and canonical input frontier selected for the failed preparation; it must not reconstruct those from later current settings or rely on a removed Turn-wide configuration binding. The minimal durable reference mapping remains to be specified; only evidence not recoverable from canonical facts should be retained additionally. Failure established by an accepted Operation Resolution references that same Turn's Operation and its unique Resolution rather than copying provider evidence. Tool errors, retryable Completions, recoverable provider overflow, and direct model interruption do not automatically fail the Turn. Cancellation retains its earlier Run intent while effects settle; failure cannot erase another Operation's obligations.

All User Message admissions and existing projections remain immutable. Inspection derives `applied` from the projection relation, `not applied` from a missing projection plus the failed outcome or applicable cancellation authority, and otherwise `pending` for eligible work. Applied means entered Conversation/model context, not proof that the provider consumed it. Unapplied content and its cause remain inspectable even without a Conversation Entry. Later requests project only the current Turn's applicable messages and use canonical context; they never revive excluded admissions from earlier Turns. Reusing their content requires a new explicit submission.

SQLite commit order decides admission versus failure. A message committed first remains attached to the old Turn and becomes not applied if still unprojected. A Session-current submission after failed-outcome/occupancy-release commit begins new work; a command bound to the old Turn rejects. Rollback leaves the original pending facts. Lost acknowledgment after commit is recovered from the existing outcome, without redispatch or reinterpretation under current ambient settings. A storage fault that prevents commit cannot be reported as a durable failed outcome or occupancy release. A crash alone is neither failure nor cancellation. Physical cleanup and credit release retain their effect-specific owners, and late evidence cannot replace a committed Resolution or Outcome.

## Failure and future scope

Closed failures include stale identity, conflicting replay, invalid canonical data, capacity exhaustion, unsupported provider output, storage failure, and corrupt referenced content. Observer state and diagnostics cannot carry authority.

V1 excludes branching Conversations, edit/delete, attachments, automatic provider/model fallback, incompatible provider/model switching, lossy handoff, multi-host coordination, provider registries, dynamic tools, MCP execution, generalized scheduling, retained workflow VMs, and storage migration compatibility. A model change between Turns is allowed only when the selected adapter demonstrates continuation compatibility. A future conversation fork should create a new Session with explicit ancestry rather than turning every Session into a tree.
