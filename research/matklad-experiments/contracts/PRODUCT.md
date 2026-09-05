# OnePage product

OnePage is a crash-resumable, resource-bounded local runtime for programmable coding-agent workflows. JavaScript expresses orchestration; native Zig owns Sessions, Turns, model requests, tools, permissions, recovery, and storage.

## V1 experience

The Local Owner explicitly starts `onepage serve` for the selected Host Store. CLI and script clients use HTTP over its Store-derived Unix socket. They require a running server, never open SQLite, and never auto-start or drive the server. All admitted clients share the Local Owner's Sessions and Runs; tool Permission Mode and exact Action Authorization remain separate.

Direct use is non-interactive and Session-addressed: `onepage session <verb> [session-id]`. Creation and configuration are separate from sending messages. Message text is positional; `-` reads the complete message from stdin, including shell redirection. Creation, messaging, inspection, history reads, waiting, and stopping require no public Turn ID or Workflow Run/evaluator. Exact remaining command spellings, acknowledgement fields, and configuration applicability are tracked in the [Session and client decision](https://github.com/DivyanshGolyan/onepage/issues/101); this is the accepted interaction contract, not an implemented CLI reference.

A message uses current committed Session state. It starts work if idle or joins admissible active work. Ordinary reads capture fresh facts; a Session wait selects current work once and does not follow future work indefinitely. History reads provide recent entries, kind filters, and an after-position without requiring a Turn ID. Unapplied message content and its reason remain separately inspectable. Polling does not replay all Session history or create a remembered caller view.

Direct Session creation and message submission have no optional or mandatory caller idempotency key. If their acknowledgement is lost, the outcome is uncertain; explicit resubmission can create new work and cost. The CLI never automatically repeats mutations. Run creation and workflow operations retain their own stable-key replay contracts; exact permission and other controls use their domain repeat/conflict rules rather than a generic command ledger. Acknowledgement follows semantic commit and is separate from completion.

The server advances eligible work even after every client disconnects. A server stop ceases new dispatch promptly, interrupts supported active work, preserves available terminal evidence, and performs bounded effect-aware cleanup without deliberately waiting for an LLM answer. A crash may lose volatile evidence. The next explicit server start recovers unfinished work with the remaining retry allowances and possible replacement-call cost. Neither infrastructure stop nor crash fabricates semantic Session stop, Run cancellation, or direct Model Interruption. There is no separate Run pause/resume state.

The Workflow Definition has one form:

```js
export default async function workflow({ createSession, configureSession, sendMessage }, args) {}
```

`createSession({ key, ... })` returns a Promise of a plain Store-relative Session ID after the Session, complete baseline context, and Run-local creation binding commit atomically. It starts no model work. An empty Session is valid and retains disk facts without a resident worker. Replaying the creation key returns the same ID.

Session configuration changes separately from messages. Illustrative spelling: `configureSession(sessionId, changes, { key })`. It records a sparse persistent change and its workflow replay result atomically, without submitting input or starting model work. Omitted settings remain unchanged. Successful configuration is not rolled back if a later message fails. Replay returns the original operation result without applying its old changes again.

Configuration and message submission are separate admissions. Another trusted client may change settings between them; no lock, historical revision guard, or cross-call transaction is promised. New model requests use the committed Session state when constructed, including within ongoing work; already-constructed requests and their retries remain unchanged. The exact configuration acknowledgement shape is not selected here.

`sendMessage(sessionId, message, { key, ... })` submits to an existing Session and returns a normal Promise of the recorded final text or exact validated schema value. The same call handles the first and later messages; existing IDs from workflow arguments need no `get`, `ref`, or attachment operation. A fresh message uses current committed Session state. Internal Turns remain absent from the caller interface, and several messages may share a work outcome.

Creation, configuration, and messages use distinct keys in one Run-local namespace. Keys bind operation kind and complete inputs; equal replay recovers the original operation/result, while changed bindings conflict. Failed or cancelled messages reject with their frozen failure. Ordinary catch/join logic controls the workflow response; deliberate retry uses a new message key. Cancellation of the Run itself fences further evaluation and operations.

Cancelling a Workflow Run first fences further evaluation and submissions from that Run, then applies ordinary stops to current work in every distinct Session found through its committed message admissions. If a crash interrupts cancellation before its completion is durably recorded, recovery may repeat the entire stop pass, including stops that previously succeeded or found an idle Session. Callers coordinate Session sharing and reuse while cancellation is unfinished; newer work may be stopped by a repeated pass. Once the existing terminal Run outcome records cancellation completion, recovery does not propagate that cancellation again. Creation, configuration, and reads alone do not add a Session to the stop set. Other Runs observe stopped work without themselves being cancelled. Workflow cancellation completes when the required ordinary Session stops complete, regardless of who submitted their selected work; it does not separately wait only for this Run's submitted work. A Session stop completes when its selected work has a recorded terminal outcome and releases the Session for reuse; idle stops complete immediately. Cancellation-intent acknowledgement remains distinct from completion. This does not promise that remote provider processing or billing has stopped. Effect-specific cleanup and external-effect uncertainty remain unchanged.

Settings are persistent Session state, established at creation and changed explicitly. Message sending does not also change that configuration. An optional output schema belongs to Session configuration; without it, the final answer is ordinary text. The model produces the structured answer using the provider's supported mechanism. The provider adapter translates the schema, parses the response, and validates structured success against the producing request's frozen schema. OnePage does not convert prose into a schema value or automatically spend another model call to repair it. Later configuration cannot reinterpret a recorded result. Other supported settings remain decisions. Tool permission defaults and exact Action Authorization remain in force.

Ordinary JavaScript functions, loops, arrays, `Promise.all`, and `Promise.allSettled` compose Session operations and their recorded results. `Promise.race` and `Promise.any` are absent because physical completion order is not durable workflow input. Each Evaluation Generation runs from source against one immutable Visibility Snapshot and exits at its complete blocked set. No evaluator remains while a Run waits.

## Conversation

A Session contains one immutable linear Conversation. Conversation entries are User text, assistant text, Tool Calls, Tool Results, and System Instructions. Sessions are reusable and never terminal; Turns settle.

One initiating User Message begins a Turn and enters Conversation atomically. Later User Messages use the same admission primitive while that Turn is nonterminal but enter Conversation only when the next model Operation requesting an assistant response applies all pending messages in arrival order. An internal compaction model Operation uses already-applied context and leaves them pending. A Permission Decision authorizes or denies one exact proposed Action and is not Conversation content. V1 has no model-created conversational Input Request.

If work definitively fails or is stopped before an admitted message enters model context, its content remains inspectable as not applied, with the reason. Continuing the Session does not silently retry that message; the caller explicitly submits its content again if desired. Messages already applied remain in Conversation, even if the provider request failed; application does not prove provider consumption. A crash alone does not mark pending input failed or cancelled.

Conversation history is never rewritten. Context pressure may create an accepted compaction model Operation whose Resolution can serve as a derived Compaction Base for later model requests; no separate checkpoint record duplicates it.

Completed provider output needed for faithful continuation—including opaque or encrypted reasoning and provider compaction items—is retained exactly once as canonical Attempt Completion output. Conversation references its supported semantic content, while the adapter derives the provider replay view from the same items. Private continuation material is never exposed through a generic content read. OnePage never silently drops that material or substitutes visible Conversation for it. If the exact continuation is unavailable or incompatible, the model request fails explicitly.

## Model-visible context

Persistent Session settings change through an independent sparse Session Context Patch. The change and its workflow operation result commit together. Later messages are independent admissions; there is no automatic rollback if they fail. This replaces the earlier patch-with-Turn-admission proposal and temporary override layer. A new model request is constructed from one committed view of current Session configuration and its applicable canonical inputs. Its Model Request Manifest freezes the selected revision, resolved settings, input references, and request semantics. Later changes affect only requests not yet constructed; replacement Attempts reuse their existing manifest. There is no Turn-wide copy of model settings, per-setting activation queue, or requirement that every intermediate configuration value be used. Configuration alone creates no model work. Validity and continuation compatibility remain separate from this common construction boundary.

Append-only model-visible updates are the accepted direction. Keep the initial instruction prefix stable and preserve previously supplied messages and provider continuation. Later instruction/context changes enter at a fixed position in the model-visible history, using a provider-supported representation; new requests must preserve continuation compatibility as well as their own immutable retry inputs. Session configuration remains current state and changes independently of message submission. This does not make every Host setting a conversational message, require exposure of every unused intermediate value, authorize Workspace rebinding, or adopt a particular provider's tool/effort update protocol. Appended system instructions are a distinct Conversation Entry kind, visible in Session history alongside messages and tool results. The name is System Instruction, not a generic Context Update. First inclusion commits with the next assistant-response request as described below; exact storage/wire encoding remains implementation work. Existing permission admission and supported compaction contracts remain in force.

A new System Instruction enters Conversation in the same transaction as the assistant-response request that first includes it, after preceding tool results and applicable user input. Compare instruction content with the last applied value; unchanged values and unused intermediate changes create no entry. Retry reuses the entry and manifest. Configuration alone starts no work. Compaction before admission uses already-applied context; compaction after an admitted overflow includes the instruction already recorded.

Every model Operation freezes one exact Model Request Manifest. Replacement Attempts reuse its request semantics exactly; the provider request body is reconstructed on demand rather than stored. Credentials, non-behavioral HTTP headers, endpoints, sockets, and provider caching remain late-bound transport details.

This preserves historical context without copying a complete system prompt on every Turn and prevents retry from drifting with ambient configuration.

## Tools and multiple calls

V1 executes `bash` and one-file `apply_patch`. The Tool Catalog is model-visible data; a separate closed Host mapping and exact Authorization decide what may execute.

One model response may contain multiple ordered Tool Calls. Each becomes an independently recoverable child Operation and may settle into SQLite as soon as it finishes. Bash, Patch, and model Operations may run concurrently even within one Workspace under Active Capacity; no permanent Patch lane or Workspace isolation is implied. The next model Operation waits for every child result and receives Tool Results together in original call order, not physical completion order.

Permission Mode is persistent Session configuration, defaulting to `ask`; the Local Owner may explicitly change it, including during active work. Each child Action admission selects the current committed mode and records its configuration provenance together with the exact descriptor and either an immutable Permission Request (`ask`) or Authorization (`bypass`). Later mode changes do not answer pending requests, revoke existing Authorizations, or stop running actions. Recovery reuses the admitted facts rather than current settings. Both modes preserve validation, Attempt admission, cancellation, and effect-specific recovery; server access never selects bypass implicitly.

## Workflow and Run interface

The Host Runtime exposes one narrow typed Run API rather than a separate Run Service component. Explicit operations create or attach a Run, create and configure Sessions, submit Session messages, decide one Permission Request, interrupt one exact unresolved Model Operation when explicitly targeted, stop current Session work, and cancel one Run. Bounded driving is internal to the server and composes multiple short semantic transactions; no public `advance` operation is required. Inspection captures a complete report as of one committed moment before delivery. Database updates wait during capture, then resume while the caller receives the report. Before another queued inspection begins, ready control commands get a bounded opportunity to run; a stop need not wait behind the whole report backlog. One capture can still delay controls, and its accepted latency budget remains open. Later progress does not invalidate it; commands still check their exact targets. Immutable content is read through fixed windows.

The local HTTP adapter owns the closed versioned JSON wire contract; the CLI consumes it and renders JSON or Markdown. Compiled public types and golden fixtures freeze the automation contract covering every field, union tag, omission rule, and integer encoding; IDs, revisions, offsets, and other `u64`-class values are JSON strings. Until that contract exists, no replacement JSON format is accepted. Markdown is the default deterministic model-facing view of the same facts. Every actionable Permission Request and every other current logical collection member appears without a collection cap or external pagination token. Variable fields and workflow-visible structured values use immutable Content References rather than resident recursive object trees. Client process death, terminal closure, and shell timeout detach without cancelling durable work. A successfully delivered workflow failure is a valid zero-exit protocol result; nonzero means invocation, access, infrastructure, or rendering failure. Stdout contains only the selected data format and diagnostics go to stderr.

## Product guarantees

- SQLite is the sole recoverable OnePage-owned semantic and content store and the canonical relational authority; OS-held credentials are non-semantic security material.
- No Session Ledger, reducer image, continuation blob, or resident object graph duplicates canonical rows.
- At most one Turn is nonterminal in one Session.
- Each Attempt has at most one Completion; one Operation Resolution selects meaning across zero or more Attempts.
- Attempt admission precedes physical dispatch.
- Long-lived request and response content streams through bounded windows to dynamically charged, immediately unlinked scratch; no prompt-, response-, or output-sized resident allocation is multiplied by Active Capacity.
- Complete output is parsed only after its effect-specific terminal boundary in one shared Host validation/import workspace. Normal content, Completion, Resolution, and semantic consequence settle atomically.
- A retryable model Completion is the sole Completion-only exception: it commits with immutable future eligibility while the Operation remains unresolved and consumes no waiting memory or timer object.
- Model retry reuses one exact Model Request Manifest and records possible duplicate work or billing.
- Uncertain Bash is never replayed automatically; the Agent receives an indeterminate Tool Result.
- Patch recovery reconciles exact preimage, expected postimage, and observed state.
- Dormant Sessions, terminal Turns, and Blocked Workflow Runs retain durable bytes rather than live execution resources.
- One startup-fixed Active Capacity bounds concurrent external work.
- Workflow evaluation is disposable, deterministic at durable barriers, and independently bounded.
- Model-requested subprocess memory is workload memory and is measured separately from orchestration memory.
- Codex subscription transport is the first live provider but never owns Conversation, context selection, tools, permissions, or recovery.

## V1 exclusions

- Conversation branches, edit/delete, alternate answers, merge, or fork UI. A later fork creates a new Session with explicit ancestry.
- Model-created conversational Input Requests, generic signals, arbitrary forms, credentials, or file uploads.
- Dynamic tools, MCP execution, plugins, skills, hooks, provider registries, automatic model fallback, or generalized OAuth.
- A model-visible Agent tool, recursive model-directed delegation, or durable RLM stack.
- Retained QuickJS, bytecode, Node, timers, imports, filesystem, process, network, environment, credential, clock, or random access inside workflow evaluation.
- MCP Tasks, ACP, A2A, a separate daemon manager, public event stream, watch mode, webhook, push delivery, TUI, editor, or Web UI. The explicit local Host server is part of V1.
- Multi-host scheduling, distributed coordination, external-effect exactly-once claims, or arbitrary Bash sandbox claims.
- Backup, export, retention, deletion, garbage collection, shrinking, or compatibility migration for unreleased V1 databases.

## Demonstration standard

The release demonstration runs a deterministic multi-Turn fan-out/fan-in workflow, kills OnePage at named semantic and physical handoff boundaries, resumes from SQLite, proves uncertain Bash is not replayed, changes a Patch target during downtime and fails reconciliation safely, continues one Session across multiple Turns, applies a later User Message at the next assistant-response model-Operation boundary, changes model-visible context between Turns, executes independent same-Workspace Bash and Patch work concurrently under Active Capacity, and emits one committed Workflow Output.

It reports whole-process RSS and separate slopes for Dormant Sessions, terminal Turns, Active Capacity, provider transport, SQLite, semantic validation, evaluator memory, immutable content, and workload subprocesses. The density run includes 0, 100, 1,000, and 10,000 Dormant Sessions and Active Capacity 1, 10, 50, and 100, with latency and throughput reported at each active point.

Packaging uses the final project identity selected before demonstrations and audits. The package requires no Node, Codex CLI, separate daemon manager, or additional workflow runtime. Exact example inputs, expected outputs, recovery observations, raw resource measurements, and calculation scripts accompany the demonstrations. Live Codex login and repair remain opt-in; a deterministic equivalent uses the same production paths without credentials. Examples demonstrate client detachment separately from server stop/crash, direct Session use, and shared-Session workflow cancellation including repetition only while cancellation is unfinished.

## Post-V1 maintenance

Retention and maintenance remain deferred. Any later design must preserve referential integrity across retained Runs, Sessions, outcomes, permission/context/replay evidence, and Content References. Reclaim content only when no retained canonical reference needs it; export from committed facts. Checkpoint, vacuum, backup, integrity, and archival tools require a concrete need. This creates no V1 retention policy, background daemon, or second store.
