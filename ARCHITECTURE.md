# OnePage architecture

This document is normative. [`CONTEXT.md`](CONTEXT.md) defines the domain language; accepted ADRs explain hard-to-reverse decisions. Historical design, spike, and research documents are evidence, not authority.


## Topic contracts

Read the relevant branch before changing its behavior; these files are part of this normative contract.

| Branch | Read for |
| --- | --- |
| [Execution](docs/architecture/execution.md) | Attempt admission, settlement, retries, tool output, Bash and Edit recovery. |
| [Workflows](docs/architecture/workflows.md) | Workflow replay, evaluator lifetime, Run controls and inspection. |
| [Resources](docs/architecture/resources.md) | Memory, temporary retention, limit defaults and qualification. |

## Consumer-driven interface design

OnePage's own Session, workflow, CLI/script, and deterministic integration consumers drive the redesign. Use an independent native caller and a Cloudflare Durable Object as concrete design probes for responsibility, lifetime, and failure contracts; neither requires an initial adapter or supported deployment. Existing documented mechanisms remain the baseline until their owning decisions explicitly amend them.

Evaluate separately the logic deciding admissible work and recovery, the mechanism storing durable facts, the mechanism driving execution and wakeups, and the environment performing workspace effects. Interfaces must preserve atomic admission/settlement, exact authorization, immutable results, effect-specific uncertainty, and bounded resource ownership. This is a test of the resulting design, not a requirement for a generic storage interface, scheduler framework, or fixed number of modules.

For each candidate interface, identify what the caller supplies, who owns and releases resources, how results and failures are observed, and what survives interruption. Storage substitution must preserve transaction semantics and bounded content access. Temporary storage must actually keep large content outside working memory to support the disk-first guarantee; a memory-backed filesystem does not establish that property. Compilation to WebAssembly alone proves neither host compatibility nor recovery and resource guarantees.

External scenarios should reveal where future adaptation belongs without transferring OnePage policy to callers or adding speculative implementations. The [consumer decision](https://github.com/DivyanshGolyan/onepage/issues/118) selects this design discipline; platform contracts and architecture alternatives select concrete mechanisms and module composition.

## Platform contract

The [platform decision](https://github.com/DivyanshGolyan/onepage/issues/126) targets Linux and macOS through capability requirements, with local Host Store filesystems, configurable disk-backed scratch, host-provided Bash and bundled pinned libcurl alongside SQLite and QuickJS. Do not add detached-descendant containment or a new sandbox to satisfy portability. The selected mechanisms below complete the portability inventory; their implementation is still pending.

Credential persistence belongs to its selected store: macOS Keychain, explicitly configured Linux Secret Service, or an explicitly selected owner-only plaintext file on Linux. The file exception permits same-user reads, including through authorized Bash, but not automatic copying into tool environments, logs, workflow data or SQLite semantic storage. Validate ownership/access and use atomic refresh replacement; load/save/delete failures remain explicit and never silently select another backend. This amends references below to OS-held credentials without changing account binding or late-bound transport semantics.

## Selected platform mechanisms

The platform decision selects these mechanisms while preserving the existing semantic owners. Qualification follows the [platform evidence policy](VERIFICATION.md#platform-qualification); unexecuted Linux behavior remains explicitly unverified. These rows do not prescribe the module graph for architecture comparison.

| Area | Mechanism and owner | Failure and evidence |
| --- | --- | --- |
| TLS and trust | Bundle a pinned OpenSSL release with libcurl; use curl's Apple SecTrust integration on macOS and host CA certificates on Linux, with an explicit CA-file setting for installations needing it. Enable a supported asynchronous resolver. Keep initialization, handles, resolver lifetime and cleanup within the transport owner. | Missing trust configuration, invalid peer certificates or required capabilities fail explicitly. Never disable verification as fallback. Check the actual linked build and deterministic TLS/DNS/cancellation cases on the available Mac; retain Linux build/source assumptions as unverified runtime evidence. OpenSSL is an accepted bundled dependency. |
| SQLite | Keep one Storage Owner and vendored SQLite. Preserve DELETE/EXTRA; explicitly enable macOS fullfsync through SQLite. Use the platform SQLite VFS rather than a new pager. Select a thread-safe SQLite build while retaining OnePage's single-owner access discipline. | Atomic publication, rollback and reopen remain required. No concurrent callers gain direct database access. Verify effective settings on the Mac. Process-crash tests do not certify power-loss behavior or arbitrary storage hardware. A future embedder need not inherit SQLITE_THREADSAFE=0's library-wide restriction. |
| Store locking and socket | OS-held exclusive file lock and pathname Unix socket, owned by the server for its Store lifetime. Reject unsupported aliases, competing ownership and unrepresentable endpoint paths. Derive socket capacities from the target ABI; do not use Linux abstract sockets. Close-on-exec prevents tools/evaluators retaining server ownership. | Never use PID/socket existence as ownership proof; reclaim stale endpoints only after exclusive ownership. Preserve existing canonical Store selector and one-local-owner permissions. Lock inheritance, crash/reopen and stale-path behavior need relevant local checks; Linux semantics are evidence-backed assumptions until exercised. |
| Exact Edit | Preserve the accepted in-process exact Edit design, ordinary OS access, opened-target identity, exact intent binding and target checks before mutation. Use target-specific stat/handle facts together with content evidence. | No inode-only universal identity, guessed rollback, Git patch revival, sandbox expansion or silent target retargeting. Preserve partial-I/O, rename/link, authorization and recovery cases; unchanged historical records remain history. |
| Scratch and spillover | Create protected private scratch under a configured directory; use immediate unlink where no pathname consumer remains. Keep published spillover paths under the existing bounded FIFO retention owner, never reused by OnePage for other output. | Report known memory-backed backing as incompatible with the disk-first guarantee; unknown backing remains an explicit deployment assumption rather than falsely certified. Preserve open-reader exceptions, partial-I/O/storage failure, and non-authoritative disposable spillover semantics. |
| Evaluator | Keep disposable QuickJS, one evaluation at a time, the accepted 16 MiB JS heap, 1-second process CPU budget and 5-second parent lifetime deadline. Use cooperative checks plus RLIMIT_CPU, platform stack protection and parent-owned termination/reaping. Native allocations retain their derived bounded owners. Use the same ownership model on Linux without adding an independent fixed address-space limit or RSS polling killer. | Do not restore the obsolete 64 MiB address-space quota, numeric descriptor scans or exit-time wiping. Scope limits to the evaluator child, preserve explicit inherited read-only input descriptors and empty environment, and keep parent controls responsive. Unexplained signals do not establish a specific resource cause. Linux resource behavior remains unexecuted, not waived. |
| Core dumps | Set evaluator RLIMIT_CORE=0 on both systems. On Linux additionally set PR_SET_DUMPABLE=0 in the child after exec and before loading sensitive inputs, because piped core collection ignores RLIMIT_CORE. | A failure to establish the required protection prevents evaluation. Do not modify an embedding application's whole process. This is not arbitrary-native-code sandboxing. |
| Measurements and builds | Preserve named Mac footprint/RSS measurements and existing available-Mac gates. Keep Linux RSS/PSS/private-page/peak metrics distinct when later available. Cross-compile supported CPU targets with pinned dependencies; record unsupported toolchain/SDK prerequisites honestly. | Missing counters are unavailable, never zero. Do not convert Linux RSS into Mac physical footprint or label a compilation as a runtime test. No new mandatory Linux CI fleet or full distribution matrix. |


## System shape

```text
Direct clients ───────────────► Session core API
Workflow Runtime ────────────► Session core API
  ├── durable Run/call records    ├── transactional admission/results
  └── private QuickJS evaluator  ├── SQLite core facts/content
                                 └── control loop + fixed execution slots
                                       └── provider / Bash / Edit modules
```

The initial local server remains explicitly started and owns its Store and live resources. Within it, the Session core owns Session decisions and execution; the Workflow Runtime owns Runs, submission intents and evaluator replay. They communicate through the Session core API, without Run-aware admission or shared admission transactions. Module and lifecycle separation does not select separate OS processes or database files. Core tables are accessed only through their Storage Owner; workflow records belong to the Workflow Runtime's persistence boundary. Physical deployment and remaining implementation integration are tracked in the [consolidated candidate](docs/design/consolidated-architecture.md).

The local HTTP adapter exposes caller-facing operations over the Store-derived Unix socket. JSON belongs to this adapter and Markdown rendering to the CLI. QuickJS executes workflow source against supplied recorded results; it owns no Session, provider, tool, permission or durable state. The native Workflow Runtime provides its durable lifecycle.

A **Session** is one reusable linear Conversation in one Workspace and access scope. A **Turn** begins with one initiating User Message and advances that Session until Final Answer or a typed terminal outcome. At most one Turn is nonterminal in a Session. A **Workflow Run** binds each Run-local operation key to its configuration or message admission and original result. Multiple messages and Runs may share one internal Turn outcome; there is no intermediate Job domain or exclusive Run ownership of Sessions.

## Simplicity rule

Each durable fact has one relational authority. Each resident byte has one current production consumer, one population multiplier, and one release boundary. Each interface owns one decision and hides its mechanics.

Use established mechanisms without transferring OnePage policy to them: SQLite owns transactions and journal recovery, libcurl owns bounded HTTP/TLS transport, and the selected credential store owns subscription credentials. OnePage retains model-visible context selection, operation admission, permissions, effect recovery, and Conversation meaning.

V1 has no generalized scheduler, provider registry, OAuth framework, runtime tool registry, plugin loader, durable JavaScript continuation, separate daemon manager, event bus, or generalized protocol-adapter framework. The accepted local HTTP adapter is part of the single Host server. A new abstraction requires a current second consumer or an invariant that cannot fit an existing deep module.

## Server ownership and local clients

`onepage serve` acquires exclusive OS-held Store ownership before recovery, endpoint reclamation, or dispatch, and holds it until this process can no longer dispatch or write semantic facts. A second server for the same Store is rejected. One bounded canonical Store selector must be shared by locking and socket discovery: equivalent supported path spellings cannot create two owners, unsupported aliases must reject, and Unix socket path limits must fail explicitly. PID metadata, socket existence, client timeout, and an absent final result never prove ownership or effect termination.

Protect the socket and containing directory with filesystem access controls. Validate intended Store identity and wire version before mutation. Every admitted client acts for the same Local Owner; there is no per-client ACL or implicit tool bypass. Clients never open SQLite or auto-start a server. Unavailable, mismatched, or inaccessible owners fail without fallback. Only after acquiring Store ownership may startup reclaim the expected owned stale socket; it must not unlink an unexpected file or another live owner's endpoint.

Server lifetime is independent of clients. It drives bounded quanta while work is eligible. Infrastructure stop fences new dispatch promptly, interrupts supported effects, preserves available terminal evidence, and performs bounded cleanup without waiting deliberately for LLM completion. Stop and crash do not insert Run cancellation, ordinary Session stop, or user-command Interrupted facts merely because execution becomes unavailable. Explicit restart recovers committed unfinished work using effect-specific rules and remaining budgets, with possible replacement model cost. Loss of ownership is not proof an external effect stopped.

Mutation acknowledgement follows semantic commit. Session configuration and messages use caller-provided request keys, distinct from caller-provided Session keys: same-key retries recover the original answer rather than resubmit effects. The CLI must retain identity and inputs for reliable retry; its exact persistence/user interface remains implementation work. Run creation and workflow calls preserve their own identities through the workflow adapter. Permission and other controls keep their domain repeat/conflict rules. No WebSocket, TCP listener or per-Run pause/resume system is selected by this change.

Streamed ingress is bounded, charged, validated, and sealed before the referencing semantic admission. Incomplete uploads publish no content or semantic reference. Inbound client connections, slow transfers, completed inspection scratch, and external Active Capacity are separate resource populations; selected budgets must preserve execution and control under connection pressure.

Bound the total local-client connection population and admit ordinary requests and long transfers below that bound, preserving headroom for request classification and short controls within the same server. Each connection handles one request and response, then closes; do not queue pipelined requests or retain idle keep-alive connections. Request headers have both a byte bound and a total completion deadline. Upload and response delivery have client-inactivity deadlines; time spent on Host processing or Host-imposed backpressure does not count as client inactivity. V1 introduces no minimum transfer rate or total-duration limit for a transfer making progress. Connection and scratch bounds remain necessary even when a client trickles bytes. Classification and control headroom do not promise immediate access under arbitrary connection floods or OS resource exhaustion.

Protected short controls are Session stop, Run cancellation, exact Model Interruption, and Permission Decision admission. Protection covers bounded request admission and acknowledgement, not completion waits or large inspection/report delivery. Completion waits and report delivery use ordinary client capacity and must not occupy protected headroom while waiting for execution to finish. This admission distinction changes neither command authority nor effect-specific completion semantics; exact acknowledgement encoding remains with the client contract.

A client timeout closes the connection and releases incomplete transfer resources through their existing owners. It cannot publish an incomplete upload or successful truncated report, cancel saved work, undo a committed command, or authorize automatic mutation replay. The startup-configurable default is 128 total connections, at most 120 ordinary, preserving 8 places for classification/short controls. Bound the combined request line and headers to 16 KiB, short-control bodies to 8 KiB, and acknowledgement/error responses to 8 KiB; reject oversized requests before semantic mutation. Normal message/configuration/content bodies retain their streaming and scratch rules. Initial deadlines are 10 seconds total for headers and 60 seconds of client transfer inactivity. These are accepted policy defaults, not measured requirements or passing production evidence. Configuration is loaded at Host startup; no live resizing protocol is required.

## Canonical relational authority

The Host Store is the sole recoverable OnePage-owned semantic and content store. Credentials in the selected credential store are non-semantic security material. Its canonical relationships are equivalent to:

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
model_output_items
permission_requests
permission_decisions
run_cancellation_intents
workflow_runs
workflow_call_records
core_request_bindings
evaluation_generations
content
```

These are the accepted relationships, not frozen SQL names. [ADR-0026](docs/adr/0026-let-operations-own-current-execution-and-final-results.md) makes the Operation the owner of current execution facts and its optional immutable Resolution value; Attempts, Completions and Resolutions are not separate durable entities. Session/content/request records belong to the core; Run/call/evaluation records belong to the Workflow Runtime. Run relationships derive from saved API answers. These are separate logical transaction owners, without selecting a database-file count. Exact schema mapping remains implementation work.

SQLite constraints and transactions establish identity, parentage, uniqueness, occupancy, ordering, and settlement. OnePage does not persist a generic Session Ledger, reducer image, continuation blob, cached lifecycle phase, or shadow frontier beside these rows. A loaded Session, Turn, or Decision Snapshot is a bounded query result and never a second source of truth.

Within each owning transaction boundary, the Host Store enforces:

- one linear Conversation per Session;
- immutable User Message admission order with at most one Conversation Entry projection per message;
- at most one nonterminal Turn per Session;
- one terminal Turn Outcome;
- at most one immutable Resolution value on each Operation, referenced through Operation identity;
- exact current Attempt identity and non-reused ordinal within its Operation;
- atomic admission accounting and replacement of retry eligibility without losing consumed allowance;
- exact causal parentage between model Operations, Tool Calls, child Action Operations, and Tool Results;
- immutable Permission Requests with at most one Permission Decision;
- core configuration/message request identity and its original acceptance or rejection atomically with the relevant core changes;
- idempotent Run creation and workflow call records within workflow-owned transactions;
- distinct keyed message admissions may share one Turn and its outcome across Runs;
- at most one Run Cancellation Intent per Run; and
- content publication together with its first durable reference.

Turn Condition, Session dormancy, Run `permission_required`, runnable work, and observer summaries are derived from canonical rows. Persist a derived value only after measurement proves that an index is necessary; it remains rebuildable and non-authoritative.

V1 is a flag day. Unreleased databases and fixtures are recreated; no ledger-to-relational migration, compatibility reader, alias table, or dual-write path is permitted.

## Shared syntax and representation

Field validation follows the exact consumer rather than a common identifier validator or copied buffer size. Keep semantic invariants, fixed representation boundaries and resource budgets distinct. Each retained boundary names its unit, enforcement owner and explicit failure; it never silently truncates semantic input. Existing source buffers remain protected until their replacement storage and traversal are bounded and verified. Removing a product quota does not authorize unsafe buffer growth.

| Field | Retained contract |
| --- | --- |
| Internal identities and ordinals | Check arithmetic and the selected storage representation before mutation. SQLite INTEGER consumers require signed 64-bit representability; this does not limit opaque identities stored in another representation. Preserve each domain's positivity/nonnegativity and non-reuse rules. Final public ID spelling remains interface work; public integer strings retain their existing wire contract. |
| Binding Digests | SHA-256 values contain exactly 32 binary bytes. Any exposed text must decode to that exact representation; no public hex/base64 choice is introduced here. |
| Store, Workspace and Edit paths | Validate the actual OS/API path representation, embedded NUL and the complete derived path, including suffixes and terminators. Store canonicalization preserves single ownership. Edit retains ordinary absolute/relative path resolution and authorized target checks; historical repository-relative grammar and a universal 1,024-byte product cap are not retained. |
| Unix socket path | Derive capacity from the platform socket address field independently of filesystem path handling, reserving any required terminator. An unrepresentable derived endpoint fails explicitly without truncation. |
| Provider, model and tool names | Supported provider/tool selectors use their finite mappings. Preserve exact supported model identifiers. The provider adapter owns demonstrated wire grammar and compatibility; historical name-buffer sizes do not define universal name quotas. |
| Media/schema types | Validate supported semantic types through the existing content/schema consumer and wire types through their protocol parser. Add no generic metadata registry or independent media-type byte quota without a consumer. |
| Diagnostic codes and text | Keep internal typed failure classifications distinct from external diagnostic text. Escape external text through its renderer and enforce diagnostic memory/retention through that owner. An old short provider-code whitelist is not a universal provider grammar. Credentials remain excluded. |
| OAuth values | Preserve exact nonempty account binding and the adapter's token shape and JSON/header safety rules below. No undocumented UUID grammar, independent 128-byte account limit or 16 KiB token limit is retained. Aggregate authentication parsing, credential materialization and transport allocations still require bounded ownership and explicit resource failure. |

The path boundary is platform/API-specific: the supported macOS SDK exposes a 104-byte Unix socket path field, while filesystem APIs have their own path limits. Derive capacities from the installed target definitions and actual API convention, not duplicated numeric constants. SQLite representation follows [SQLite's datatype contract](https://www.sqlite.org/datatype3.html); OAuth does not prescribe token/value lengths in [its successful-response contract](https://www.rfc-editor.org/rfc/rfc6749#section-5.1). These facts justify representation checks, not new workload quotas. The [Host and SQLite resource contract](docs/architecture/resources.md#capacity-and-memory) owns aggregate workspace and command-work policy; this section selects no new numeric budget.

## Conversation and Turns

Conversation contains five immutable V1 entry kinds: User text, assistant text, Tool Call, Tool Result, and System Instruction. Each entry records its Turn and exact causal source. Compaction never edits or deletes these entries.

Starting a Turn is one transaction against an already-created Session with a complete baseline. Admission validates current identity, Workspace, occupancy, canonical keyed inputs where applicable, and every locally decidable continuation-compatibility precondition without provider I/O. It creates the Turn, initiating User Message, and Conversation Entry together. Persistent configuration changes are independent admissions, not a patch bundled with the first message. Model settings are selected when constructing each model request, not frozen at Turn admission; ordinary Session messages require no caller historical revision guard.

The same Session message primitive serves direct clients and workflows. When idle it creates the Turn, initiating User Message, and its Conversation Entry atomically; when active and admissible it joins that work. Both direct and workflow submissions atomically bind their core request key, exact inputs and original admission answer. Workflow Runtime records its own call answer separately and recovers unanswered submissions through that same core key. A later User Message inserts one immutable `user_messages` row with exact Session, internal Turn, admission ordinal, content, and Local Owner provenance; it does not create a Conversation Entry or change an admitted Model Request Manifest. Immediately before admitting the next model Operation that requests an assistant response, one transaction projects every applicable unprojected User Message into Conversation in admission order and freezes the resulting manifest. An internal compaction model Operation reads only already-applied Model Context and leaves pending User Messages unprojected. The unique projection relation derives whether a message remains pending; there is no message phase, batch entity, or resident queue. A Permission Decision authorizes or denies one exact proposed Action and is not Conversation content. Successful Turn settlement requires no applicable unprojected User Message, actionable Permission Request, unresolved Operation or admitted effect that can still change its outcome. Terminal failure uses the precise pending-message exception below. Turn settlement and logical Session occupancy release commit atomically.

Accepted Conversation entries remain canonical after a failed or cancelled Turn. A Session never succeeds, fails, or closes.

## Sparse context and exact model requests

“System prompt” is not one mutable value. OnePage separates:

- persistent Session defaults;
- exact Action permissions and limits on their actual execution scope;
- bounded Conversation projection; and
- exact model-Operation input.

A **Session Context Revision** atomically records sparse persistent component updates from these context component kinds. The supported mutable fields and their applicability remain with [the Session configuration decision](https://github.com/DivyanshGolyan/onepage/issues/101); this list does not settle those remaining choices:

- model binding;
- Instruction Set;
- Tool Catalog;
- context policy;
- reasoning defaults;
- optional output schema;
- Host-enforced Permission Mode; and
- default output limits.

The first accepted configuration for an unknown caller-provided Session key atomically establishes the Session, complete baseline revision, Workspace, access scope and original request answer. There is no separate creation operation. An incomplete first configuration or a message to an unknown Session rejects without leaving partial Session state. Configuration starts no Turn or model work. Later configuration applies supplied mutable fields in admission order, without an original-baseline comparison; immutable Workspace/access constraints and ordinary compatibility validation remain enforced. No Turn may be admitted without that baseline. Later revisions are sparse. An explicitly supplied Instruction Set records an update even if its content equals the current value; identical bytes may reuse their immutable content reference. Omitted instructions create no update, and same-key configuration replay creates no duplicate. Each new model request selects the current committed Session Context Revision and resolves the model settings at or before that revision. Action admission independently selects the current Permission Mode; it is not tool authority frozen by a model request. Unchanged components keep their immutable content reference and digest.

```text
r1: model=A, instructions=I1, tools=T1
r2: tools=T2
r3: instructions=I2

resolve(r3) = model=A, instructions=I2, tools=T2
```

A new model request is constructed from one committed view of current Session configuration and its applicable canonical inputs. Its Model Request Manifest freezes the selected revision, resolved settings, input references, and request semantics. Later changes affect only requests not yet constructed; replacement Attempts reuse their existing manifest. There is no Turn-wide copy of model settings or per-setting activation queue. Explicit instruction updates are preserved in model-visible history; other request settings use their latest selected values. Configuration alone creates no model work. Validity and continuation compatibility remain separate from this common construction boundary.

Append-only model-visible updates are the accepted direction. Keep the initial instruction prefix stable and preserve previously supplied messages and provider continuation. Later instruction/context changes enter at a fixed position in the model-visible history, using a provider-supported representation; new requests must preserve continuation compatibility as well as their own immutable retry inputs. Session configuration remains current state and changes independently of message submission. This does not make every Host setting a conversational message, authorize Workspace rebinding, or adopt a particular provider's tool/effort update protocol. Preserve every explicit instruction update in order, including intermediate values and reversals. Appended system instructions are a distinct Conversation Entry kind, visible in Session history alongside messages and tool results. The name is System Instruction, not a generic Context Update. First inclusion commits with the next assistant-response request as described below; exact storage/wire encoding remains implementation work. Existing permission admission and supported compaction contracts remain in force.

System Instruction first inclusion belongs to assistant-response request admission. Select every explicit instruction update not yet included through the transaction's committed configuration view, deriving inclusion from canonical source-update references and the initial baseline, including entries covered by compaction. After preceding Tool Results and applicable User Message projections, append the updates in configuration admission order, validate the prospective replay recipe and atomically commit all new entries, projections, model Operation and exact manifest. A rollback commits none of these new facts; independent configuration updates remain eligible. Preserve immutable content/rendering references and causal request provenance without a separate pending row, applied flag or application receipt. Recover an admitted request through its manifest rather than preparing it again. A -> B -> A includes B then the second A; A -> B -> C includes B then C. No content-equality comparison or automatic coalescing removes explicit updates. An admitted failed request still establishes historical inclusion, not proof of provider consumption. See the [accepted update-history amendment](docs/design/instruction-update-history.md).

A selected configuration revision identifies desired current state; it does not authorize re-rendering earlier instruction positions from that state. The manifest freezes the actual initial-prefix and appended-instruction bindings.

Before admission, compaction reads already-applied Model Context and leaves every pending instruction update and User Message for the next assistant-response request. Compaction selects and freezes its own controls without applying new conversation instructions. After an admitted overflow, compaction includes the instruction entries already recorded. A later request does not include the same source update twice, including entries covered by the selected base; distinct updates with equal content remain distinct. Exact base/suffix compatibility must preserve instruction meaning. Provider-specific re-establishment controls require demonstrated, frozen adapter rules rather than replaying a configuration mutation.

There is no separate Turn Contract or `turn_contracts` relation. Each fact belongs to its existing consumer. Model-visible date, time, timezone, and Workspace information live in the fixed initial instruction binding or an appended System Instruction, with immutable content/rendering inputs referenced by the request manifest. Tool-observed Workspace facts remain required Operation-owned final evidence and Tool Results. The Session owns Workspace identity; Actions retain their exact descriptors and Permission Request/Authorization provenance. Do not recapture a Turn-wide environment snapshot or reread ambient values when retrying admitted work. This mapping adds no automatic clock refresh, Workspace polling, rebinding, or generic runtime-facts bag.

Resource controls retain their actual scopes. Host admission owns physical capacities, memory/workspace/scratch budgets, and current resource availability. Workflow Run bindings and Evaluation Generations own evaluator limits. Each model Operation owns its retry accounting and eligibility. V1 has no Turn-wide model-request count limit or absolute Turn deadline; successful work, permission waiting, capacity waiting and Host downtime do not consume such a budget. Count admitted tries on their Operation without historical Attempt rows or redundant Turn counters. The limit-matrix gate remains in force. See the [field audit and recovery traces](docs/design/turn-contract-removal.md).

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

One model Operation may resolve to assistant-only output or an optional bounded assistant-text prefix accompanied by an ordered bounded set of Tool Calls. All model-visible output and child-call descriptors validate before atomic admission; an invalid member rejects the complete candidate. Successful admission appends the optional assistant-text entry followed by Tool Call entries in call-ordinal order in one transaction. Assistant-only output is a Final Answer only when that settlement transaction proves that no earlier applicable unprojected User Message exists. If a User Message committed first, the output remains ordinary assistant text, no Turn Outcome is inserted, and ordinary advancement later projects the message and admits the next model Operation. If settlement commits first, the terminal Turn Outcome prevents that message command from attaching to the completed Turn. SQLite commit order therefore decides the race within the owning settlement transaction. V1 has no model-created conversational Input Request; later input is a User Message admitted independently of model output.

An accepted terminal model response is retained losslessly and in provider order as immutable Model Output Items owned by its Operation. Each item stores its semantic fields, provider-only continuation fields, and required response-evidence fields once, with exact producing-request and Attempt provenance. The Operation commits its immutable Resolution value and these items together; the same transaction publishes every applicable provider-output Conversation projection by reference to those semantic fields. The provider adapter derives a later replay-input view by stripping response-only or non-replayable fields; OnePage does not persist a second replay copy or a complete serialized request body.

Unknown open fields inside a known item are preserved. An unknown consequential discriminator—such as a top-level item, content block, Action subtype, compaction variant, or terminal status—resolves as `unsupported_provider_output` with a bounded typed rejection and its producing-request and necessary causal provenance; it publishes no Conversation, continuation, or effect consequence. Permanent full rejected payload retention is not required. Additional raw detail follows the local diagnostic contract below; unknown fields inside accepted replayable output remain canonical. Core neither exposes private reasoning through generic content reads nor fabricates meaning for opaque or encrypted reasoning, signatures, and compaction items. Raw HTTP and SSE framing, token deltas, partial streams, interrupted output, and late output are scratch evidence, not replay authority, and their execution scratch is deleted after successful canonical import. Explicit bounded diagnostic capture may retain raw detail separately, without granting publication or replay authority.

Each Tool Call creates one child Action Operation with `caused_by_operation_id` and a stable call ordinal. No Step or Tool Call Group is durable authority: the child set is derived from that parent relation.

```text
model Operation M1
├── call 0 ──► Bash Operation B1
├── call 1 ──► Edit Operation P1
└── call 2 ──► Bash Operation B2
```

Child Operations execute and settle independently under Active Capacity, including within one Workspace. Each child commits its own Resolution value and required final evidence when it settles; no sibling holds it outside SQLite. After every child resolves, one transaction appends their Tool Result Conversation Entries in original call-ordinal order. Only then may the next model Operation start. Physical completion order never chooses Conversation order. Denial, failure, cancellation, and uncertainty each produce typed model-visible Tool Results.

OnePage provides no Workspace-wide fence, quiescence assumption, global Action serialization, or isolation claim against other agents and processes. Bash, Edit, and provider work may proceed concurrently under Active Capacity. A closed typed Action adapter gives Bash and Edit the same lifecycle while temporary execution custody exists only for an active Attempt. Exact Edit binds the submitted intent and checks all target ranges after authorization before any mutation. Uncertain admitted tools resolve without automatic replay or mandatory target reconciliation.

## Required execution and recovery guarantees

Read [Required execution and recovery guarantees](docs/architecture/execution.md#required-execution-and-recovery-guarantees) for this contract.

## Local diagnostics and application state

Application state retains facts needed for recovery and promised user-visible behavior. Diagnostics retain recent evidence for investigation. Both may persist locally, but execution never consults diagnostic history to choose recovery, authorize an effect, reset allowance or replace an accepted result. Expiry, deletion, a missing crash tail or diagnostic-write failure cannot alter semantic meaning or grant dispatch authority. A canonical storage failure still follows the ordinary storage-failure contract.

Record small structured diagnostics by default, correlate them with the relevant execution identities, preserve recorded history across ordinary restart and bound total storage by replacing older diagnostic records. Include timings, error classifications and available application/provider version information. Detailed provider/tool payload capture is explicit and bounded. It does not change the lifetime of accepted content, private continuation, exact authorization or other canonical evidence. Credentials stay excluded; generic content reads still exclude private provider continuation. Users can export recent diagnostics to inspect and choose whether to share; this requires no central collection service or automatic upload.

Retained local diagnostic history has a configurable **128 MiB default cap per Host**. Replace the oldest diagnostic records as needed to stay within that allowance, preserving recorded history across ordinary restart. Do not add a separate age-based expiry rule or promise a fixed number of days of history; retained time depends on traffic. The cap is a disk-retention policy, not a RAM allocation or reserved disk space. Canonical application state and the temporary scratch allowance remain separate. Detailed payload capture stays explicit and shares this same allowance; enabling it can evict older summaries sooner.

A typed rejection and producing-request/causal provenance preserve the failure meaning of unsupported provider output. Full rejected payloads may be diagnostic detail rather than permanent canonical evidence. The tradeoff is that a parser/provider fault may require reproduction with detailed capture when the original bytes are absent. Never discard bytes still required by a canonical consumer under this rule.

Diagnostic encoding, retention/rotation, detailed capture and export obey the existing bounded-memory contract. Stream variable content through fixed windows; a diagnostic disk quota does not authorize an equally sized resident buffer. Do not accumulate an unbounded event queue, materialize full log history for export or retain diagnostic buffers per dormant Operation. Any fixed diagnostic workspace must have an explicit owner and resource accounting.

Use one Host-owned append writer and at most 16 size-rotated files of newline-delimited structured records. Each file is bounded by floor(configured history cap / 16), or 8 MiB at the default; the active file and encoded framing count. Delete oldest closed files before growth would exceed the cap. Records are at most 4 KiB encoded through a fixed window: preserve mandatory identity/classification, shorten optional text with an omission marker before overflow, and omit a record if a valid bounded encoding cannot be produced. Reject configuration that cannot fit one record per file. No compression or separate diagnostic database is required.

Opt-in detail uses bounded chunks with capture identity, ordering and completeness markers in the same files. Rotation or missing chunks must never present a partial capture as complete. Discard an incomplete final record before appending after restart; a missing crash tail is allowed and per-record fsync is not required. Write or deletion failure stops/drops diagnostic writes with a bounded notice, without a RAM backlog or semantic failure. After a reduced cap at restart, prune before further growth; failed pruning cannot release fictitious bytes.

Export copies available recent complete records in bounded turns into charged scratch, then uses ordinary report delivery. Record the cutoff and any gaps if rotation overtakes copying; this is best-effort history, not an atomic historical snapshot. Close source handles between copy turns so slow delivery cannot pin deleted logs. Retained originals count against diagnostics and temporary copies against scratch. Unavailable scratch fails the export explicitly.

Application-state retention remains post-V1; bounded diagnostic retention is part of V1. The [comparison discussion](https://github.com/DivyanshGolyan/onepage/issues/105) owns this accepted amendment; the [research note](docs/research/local-diagnostics-conventions.md) supplies supporting examples, not normative defaults.

## Host Runtime execution and settlement

Read [Host Runtime execution and settlement](docs/architecture/execution.md#host-runtime-execution-and-settlement) for this contract.

## Model retries and inactivity

Read [Model retries and inactivity](docs/architecture/execution.md#model-retries-and-inactivity) for this contract.

## Effect-specific recovery

Read [Effect-specific recovery](docs/architecture/execution.md#effect-specific-recovery) for this contract.

## Tool output and spillover

Read [Tool output and spillover](docs/architecture/execution.md#tool-output-and-spillover) for this contract.

## Bash execution timeout

Read [Bash execution timeout](docs/architecture/execution.md#bash-execution-timeout) for this contract.

## Tools and permission

Bash and Edit use ordinary operating-system filesystem access rather than a OnePage Workspace sandbox or Git-based access policy. Session Workspace supplies the working-directory context; it is not an allowed-path boundary. This does not remove the existing per-Action permission flow or change the exact work an approved Action may perform.

The provider-neutral Tool Catalog does not grant execution authority. V1 maps only `bash` and `edit` Tool Keys to executable Actions. Each child Action Operation binds a typed descriptor before permission or dispatch.

Permission Mode is persistent Session configuration, defaulting to `ask`. An admitted client acting for the Local Owner may explicitly change it through independent configuration, including during active work. The child Action admission transaction selects one committed current mode and binds its sparse configuration provenance with the exact validated descriptor. In `ask`, it creates one immutable Permission Request; in explicit `bypass`, it creates Authorization for that same descriptor without a request. Sibling Actions admitted in one transaction share its committed configuration view. A model request's earlier settings do not authorize subsequently admitted Actions.

A later mode change neither answers an existing Permission Request nor revokes an existing Authorization, including one whose Attempt has not started; it does not interrupt a running action. One Permission Decision still targets the exact request, Operation, and descriptor under the Local Owner's Authority. Ordinary cancellation and applicability checks remain in force. Recovery of a committed admission reuses its request or Authorization and bound provenance without rereading the current mode. If admission rolls back, no permission fact exists; a later fresh admission uses current configuration. Replay of a configuration operation returns its recorded result without reapplying its old mode. No Turn-wide policy snapshot, retroactive revocation mechanism, activation queue, resident permission worker, or separate permission history is introduced. Exact relational columns remain implementation work.

## Shared request identity and independent workflows

Session identity is an opaque caller-provided key within the Store. Constructing a reference is local work and establishes neither durable Session state nor access authority. Workflow callers scope short Session names by Run identity; a full reference can be reused across Runs. Run inspection exposes associated durable Sessions' exact full keys and identifying context. An agent can inspect W1 and type a selected key unchanged into W2; this uses current Session state, requires no W1 output envelope or previous-Run argument, and does not clone historical context. Session keys, request keys and internal Turn IDs have different roles. A request key binds one submission, while multiple message submissions may join one internal Turn. Core need not expose a generated Session ID, and it does not interpret Run namespaces.

Session configuration and message submission use one core request-identity mechanism for direct and workflow callers. A request identity binds operation kind, complete canonical inputs and its first committed admission answer, including a definite rejection. The owning transaction saves that binding atomically with accepted core changes or the rejection. Repeats with matching inputs return the original binding; changed inputs conflict without replacing it. Accepted work may remain pending, and later observations return its original work result. A fresh intended submission uses a fresh identity. Storage failure cannot promise a recorded answer; retry with the same identity first discovers whether a commit occurred. Malformed envelopes without a usable identity are outside this recorded-request contract.

The core treats request identities as opaque within its Store; callers generate them. Workflow authors choose call keys unique within a Run. The workflow adapter deterministically scopes the key by Run identity, not workflow name or content. Encoding must distinguish namespaces and components unambiguously; a particular hash or wire representation is not selected. Restart reuses identities; a fresh Run produces different identities. This mechanism covers configuration and message submission, not a new generic replay policy for every control or tool.

The workflow owns its durable Run state and call records and communicates through the core API. Before submitting, it saves the request identity and exact inputs as a submission intent. It then submits and records the returned acceptance or rejection in its own transaction. A crash between submission and recording the reply is recovered by resubmitting the same identity and inputs. Core admission and workflow bookkeeping need not share a transaction. Core admission has no Run membership or Run cancellation policy; workflow call records establish those relationships. Independent lifecycle does not require a separate OS process or a particular storage deployment.

Workflow cancellation durably stops new evaluation/call creation, then resolves saved unanswered submissions using their original identities and inputs. This may newly admit previously undelivered requests, including configuration changes or external work before a subsequent stop; that cost/effect window is accepted and is not rollback. Record the answers, then apply ordinary Session stops to Sessions identified by accepted message submissions. Reference construction or configuration alone does not add Sessions to that stop set. Resolve every pending submission and complete required stops before recording cancellation completion. Storage or communication failures leave cancellation unfinished. Restart repeats from saved records; uncertain tool attempts are never replayed by this protocol. Existing caller coordination during repeated Session stops remains required.

This amendment supersedes older requirements for Run-local bindings inside core admission transactions, core-side Run admission fences and unkeyed direct Session submissions. The core's saved request answer is atomic; the workflow's own answer record is recoverable through retry. Historical diagrams and decision records showing integrated Run relationships are superseded for this boundary. See [decision record](docs/design/shared-request-identity.md).

## Workflow Runs

Read [Workflow Runs](docs/architecture/workflows.md#workflow-runs) for this contract.

## Run interface

Read [Run interface](docs/architecture/workflows.md#run-interface) for this contract.

## Provider authentication boundary

Codex remains one private authentication/transport adapter, without SQLite access, a Codex CLI dependency, or its own Conversation/retry authority. Resume derives the provider from the persisted model binding; it cannot substitute a fixture or different provider. Credentials remain in the selected platform credential store and late-bound transport, never semantic manifests, logs, child environments, or workflow-visible content. macOS uses Keychain; Linux uses explicitly configured Secret Service or the explicitly selected owner-only plaintext file described in the platform contract, with no silent backend fallback. Refresh preserves the validated account binding; account data decoded from the configured TLS peer's bearer token is routing metadata, not independently verified identity.

Encode all provider strings before JSON reuse with one bounded encoder covering quotes, backslashes, and every required control escape. Derive buffer capacity from worst-case expansion. Validate token/account values at construction and before HTTP-header reuse, rejecting NUL, CR, LF, other ASCII controls, and non-ASCII bytes. The compact access-token form consumed by account extraction has exactly three nonempty dot-separated segments. Account IDs are nonempty opaque values preserved exactly, without UUID grammar or normalization. Apply the header-safety profile above; do not impose an independent account/token length quota. Validate the consumed claims encoding and shape explicitly. Authentication response parsing, credential materialization and complete outbound encoding remain subject to their actual resource owners, with capacity derived from complete encoded data and explicit exhaustion. This requires no JWT signature verification, JWKS, discovery, generalized OAuth layer, or change to the trusted-peer model.

## Disposable evaluator construction

Read [Disposable evaluator construction](docs/architecture/workflows.md#disposable-evaluator-construction) for this contract.

## Capacity and memory

Read [Capacity and memory](docs/architecture/resources.md#capacity-and-memory) for this contract.

### Shared temporary-file retention

Read [Shared temporary-file retention](docs/architecture/resources.md#shared-temporary-file-retention) for retention accounting and release rules.

## V1 limit matrix

Read [V1 limit matrix](docs/architecture/resources.md#v1-limit-matrix) for this contract.

## Native Edit module

Read [Native Edit module](docs/architecture/execution.md#native-edit-module) for this contract.

## Compaction

Conversation remains complete. User Messages have no token-admission quota and are never silently split or truncated. The configured token value is an approximate **Compaction Trigger**, not a strict content ceiling: OnePage anchors on provider-reported usage where available and estimates only newly appended model-visible content. Every User Message admitted between consecutive assistant-response model Operations remains a distinct durable fact, and all are applied together when the next such Operation freezes its manifest.

When that estimate predicts pressure before pending User Messages are applied, OnePage may first create a compaction model Operation over only the already-applied Model Context; the pending rows remain unprojected until the following assistant-response model Operation selects the new base, projects every applicable message, and freezes its manifest. If the provider instead authoritatively rejects an already-admitted request for context overflow before output or effects are accepted, the rejected Operation resolves with its User Messages already applied, and compaction covers that committed context. Because compaction changes Model Context, continuation afterwards is a new model Operation with a new manifest rather than a replacement Attempt of the old Operation. An accepted compaction Resolution becomes a **Compaction Base** only when a later manifest selects it. Its creating Operation's complete source manifest defines coverage and lineage; that Operation owns the one canonical replacement output. No separate checkpoint row duplicates those facts.

Later model requests first select the newest accepted Compaction Base in the current lineage, then validate that exact base and append one complete total ordered suffix of canonical host inputs and accepted model Resolutions. Core proves structural replay-recipe validity: lineage, suffix completeness, content presence and digest, and supported stored format. The provider adapter separately applies only compatibility restrictions demonstrated by its wire contract. Request admission requires both and persists no validity flag. A failed or unresolved compaction never displaces the selected base; missing, corrupt, unsupported, or incompatible material in the selected base fails explicitly as `continuation_unavailable` rather than selecting an older base or rebuilding from visible Conversation. A configuration change known to invalidate continuity is rejected atomically at configuration admission; request preparation separately validates its selected replay recipe. Codex V1 starts with the proven same-concrete-model rule and records both requested model and served-model evidence; broader compatibility requires adapter fixtures rather than a permanent Core equality rule. If compaction cannot produce a fitting compatible request under the allowed policy, the terminal-failure transaction records `ResourceExceeded` with any still-unprojected messages intact and inapplicable. A pre-request failure creates no fake model request; failure after an admitted request preserves its Resolution and already-applied context. Compaction never creates another Conversation or durable-history limit.

## Terminal failure with pending input

Accepted in [Choose terminal failure semantics for pending User Messages](https://github.com/DivyanshGolyan/onepage/issues/102#issuecomment-5550577434).

A definitive inability to continue may settle a Turn as failed once every other semantic obligation is resolved: no unresolved Operation or admitted effect, actionable permission or required Tool Result publication may still change its meaning. Still-unprojected User Messages alone do not prevent this failed outcome. The same transaction inserts the unique failed Turn Outcome and releases logical Session occupancy; the outcome itself makes those messages inapplicable. Requiring their prior inapplicability would create a circular settlement condition. There is no separate early failure intent or per-message phase.

The failed outcome carries typed causal provenance. A pre-request validation failure such as `ResourceExceeded` belongs directly to the outcome, without inventing a Model Operation, manifest or Attempt. Its failure provenance must identify the configuration revision and canonical input frontier selected for the failed preparation; it must not reconstruct those from later current settings or rely on a removed Turn-wide configuration binding. The minimal durable reference mapping remains to be specified; only evidence not recoverable from canonical facts should be retained additionally. Failure established by an accepted Operation Resolution references that same Turn's resolved Operation ID and reads its immutable Resolution value rather than copying provider evidence or retaining a second result identity. Tool errors, retryable model failures, recoverable provider overflow, and direct model interruption do not automatically fail the Turn. Cancellation retains its earlier Run intent while effects settle; failure cannot erase another Operation's obligations.

All User Message admissions and existing projections remain immutable. Inspection derives `applied` from the projection relation, `not applied` from a missing projection plus the failed outcome or applicable cancellation authority, and otherwise `pending` for eligible work. Applied means entered Conversation/model context, not proof that the provider consumed it. Unapplied content and its cause remain inspectable even without a Conversation Entry. Later requests project only the current Turn's applicable messages and use canonical context; they never revive excluded admissions from earlier Turns. Reusing their content requires a new explicit submission.

SQLite commit order decides admission versus failure. A message committed first remains attached to the old Turn and becomes not applied if still unprojected. A Session-current submission after failed-outcome/occupancy-release commit begins new work; a command bound to the old Turn rejects. Rollback leaves the original pending facts. Lost acknowledgment after commit is recovered from the existing outcome, without redispatch or reinterpretation under current ambient settings. A storage fault that prevents commit cannot be reported as a durable failed outcome or occupancy release. A crash alone is neither failure nor cancellation. Physical cleanup and credit release retain their effect-specific owners, and late evidence cannot replace a committed Resolution or Outcome.

## Failure and future scope

Closed failures include stale identity, conflicting replay, invalid canonical data, rejection under independently enforced resource limits, unsupported provider output, storage failure, and corrupt referenced content. Observer state and diagnostics cannot carry authority.

V1 excludes branching Conversations, edit/delete, attachments, automatic provider/model fallback, incompatible provider/model switching, lossy handoff, multi-host coordination, provider registries, dynamic tools, MCP execution, generalized scheduling, retained workflow VMs, and storage migration compatibility. A model change between Turns is allowed only when the selected adapter demonstrates continuation compatibility. A future conversation fork should create a new Session with explicit ancestry rather than turning every Session into a tree.
