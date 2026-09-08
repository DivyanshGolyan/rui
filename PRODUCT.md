# OnePage product

OnePage is a crash-resumable, resource-bounded local runtime for programmable coding-agent workflows. JavaScript expresses orchestration; native Zig owns Sessions, Turns, model requests, tools, permissions, recovery, and storage.

## Supported platforms

V1 requires Linux and macOS with the same selected behavior and guarantees. The [platform decision](https://github.com/DivyanshGolyan/onepage/issues/126) selects supported versions, environments, CPU architectures and mechanisms. [README.md](README.md#current-status) distinguishes the current macOS implementation from this target.

## V1 experience

The Local Owner explicitly starts `onepage serve` for one Host Store. CLI and script clients use HTTP over its Store-derived Unix socket. They require a running server and share its Sessions and Runs; server access does not grant tool Authorization. Clients never open SQLite, auto-start the server, or drive its progress.

### Direct Sessions

Direct use is non-interactive and Session-addressed: `onepage session <verb> [session-id]`. Creation, configuration and messaging are separate. Message text is positional; `-` reads the complete message from stdin. Creation, messaging, inspection, history, waiting and stopping require no public Turn ID or workflow evaluator. Remaining spellings, acknowledgement fields and configuration applicability belong to the [Session/client decision](https://github.com/DivyanshGolyan/onepage/issues/101).

A message starts idle work or joins admissible active work using committed Session state. Reads capture fresh facts. A wait selects current work once. History supports recent entries, kind filters and an after-position; unapplied messages and their reasons remain inspectable. Polling requires neither replaying all history nor a remembered caller view.

Direct creation and messaging have no caller idempotency key. A lost acknowledgement leaves the outcome uncertain; explicit resubmission may create new work and cost. The CLI never automatically repeats mutations. Acknowledgement follows commit and is distinct from completion. Workflow operations use stable keys; other controls use their domain-specific repeat/conflict rules.

The server continues after clients disconnect. Server stop ceases dispatch promptly, interrupts supported work and performs bounded cleanup without waiting for an LLM answer. Crash may lose volatile evidence. The next explicit start recovers unfinished work with remaining retry allowances and possible replacement-call cost. Neither event means Session stop, Run cancellation or direct Model Interruption; Runs have no pause/resume state.

### Workflow operations

```js
export default async function workflow({ createSession, configureSession, sendMessage }, args) {}
```

| Operation | Result and effect |
| --- | --- |
| `createSession({ key, ... })` | Promise of a plain Store-relative Session ID. Commits the Session, complete baseline and creation binding together; starts no model work. Empty Sessions retain no worker. |
| `configureSession(sessionId, changes, { key })` (illustrative spelling) | Commits a sparse persistent change and replay result together. Omitted settings stay unchanged; no message or model work starts. |
| `sendMessage(sessionId, message, { key, ... })` | Promise of recorded final text or the exact validated schema value. Accepts existing IDs directly and handles first and later messages; several messages may share one work outcome. |

All three operations share one Run-local key namespace. Give each intended operation a distinct stable key, even for identical inputs. Equal replay returns the original result; changed kind or inputs conflict. Configuration replay never reapplies old changes. Failed or cancelled messages reject with their frozen failure; deliberate retry needs a new message key. Ordinary calculations, helpers and awaits need no keys or wrappers.

Configuration and messaging are independent admissions: another client may change settings between them, and message failure does not roll back configuration. New model requests select committed settings when constructed; existing requests and retries retain their inputs. An optional persistent output schema selects a model-generated structured answer, validated by the provider adapter. Without it, the answer is text. OnePage neither converts prose nor spends a repair call to manufacture schema success. Later settings cannot reinterpret a saved result.

### Replay and completion

Functions, loops, arrays, `Promise.all` and `Promise.allSettled` compose operations. `Promise.race` and `Promise.any` are absent because physical completion order is not durable input. Evaluation runs from source against a fixed view of original results, then exits. Ready branches may continue independently; explicit joins wait for their inputs. Restart abandons unfinished calculations and reevaluates against current results while reusing keyed operations. Separate calls decode fresh result objects; repeated awaits of the same Promise keep normal JavaScript identity.

The returned value or Promise determines workflow completion. Returning `"done"` after an unawaited `sendMessage` still validates and admits the encountered call before committing success. Submitted Session work continues; its later completion does not restart the workflow. Await or join all results and continuations required for your output: unawaited continuations end with the evaluator.

Keep keys, inputs and combined-result ordering stable across reevaluation. Use saved scanner/finding identities or stable result positions rather than branch completion order. Reusing a key with different inputs fails; accidentally assigning a new key to the same intended work cannot always be detected.

One workflow evaluates at a time while models and tools run concurrently. Ready workflows are checked after evaluation cleanup; when none is ready, a shared one-second asynchronous timer triggers another check. Contention adds delay. Waiting Runs retain no evaluator. Evaluation budgets and streamed result publication are specified in the [workflow contract](docs/architecture/workflows.md#workflow-runs) and [limit matrix](docs/architecture/resources.md#v1-limit-matrix): exhaustion fails explicitly, never with partial or truncated success.

### Cancellation

Run cancellation first fences its evaluation and submissions, then stops current work in every distinct Session reached through its committed message admissions. Creation, configuration and reads alone add no stop target. Shared Sessions are affected regardless of who submitted current work; other Runs observe those stops without becoming cancelled.

Until cancellation completion is saved, crash recovery may repeat the entire stop pass, including earlier successful or idle stops. Coordinate Session reuse during this interval: a repeated pass may stop newer work. The terminal Run outcome ends propagation.

A Session stop completes when selected work has a terminal outcome and releases the Session for reuse; an idle stop completes immediately. Run cancellation completes after all required stops. Intent acknowledgement is separate from completion, and neither promises that remote processing or billing has stopped. See [Run interface](docs/architecture/workflows.md#run-interface) for authority and cleanup boundaries.

## Conversation

A Session contains one immutable linear Conversation. Conversation entries are User text, assistant text, Tool Calls, Tool Results, and System Instructions. Sessions are reusable and never terminal; Turns settle.

One initiating User Message begins a Turn and enters Conversation atomically. Later User Messages use the same admission primitive while that Turn is nonterminal but enter Conversation only when the next model Operation requesting an assistant response applies all pending messages in arrival order. An internal compaction model Operation uses already-applied context and leaves them pending. A Permission Decision authorizes or denies one exact proposed Action and is not Conversation content. V1 has no model-created conversational Input Request.

If work definitively fails or is stopped before an admitted message enters model context, its content remains inspectable as not applied, with the reason. Continuing the Session does not silently retry that message; the caller explicitly submits its content again if desired. Messages already applied remain in Conversation, even if the provider request failed; application does not prove provider consumption. A crash alone does not mark pending input failed or cancelled.

Conversation history is never rewritten. Context pressure may create an accepted compaction model Operation whose Resolution can serve as a derived Compaction Base for later model requests; no separate checkpoint record duplicates it.

Completed provider output needed for faithful continuation—including opaque or encrypted reasoning and provider compaction items—is retained exactly once as canonical output owned by the resolved Operation. Conversation references its supported semantic content, while the adapter derives the provider replay view from the same items. Private continuation material is never exposed through a generic content read. OnePage never silently drops that material or substitutes visible Conversation for it. If the exact continuation is unavailable or incompatible, the model request fails explicitly.

## Model-visible context

New model requests freeze current committed settings and exact canonical inputs in a Model Request Manifest; retries reuse it. Credentials and transport remain late-bound. Configuration alone starts no work.

Instruction changes append System Instructions to model-visible history while preserving the initial prefix and provider continuation. The next assistant-response request commits first inclusion after preceding tool results and applicable user input. Compare content with the last applied instruction: unchanged values and unused intermediate changes produce no entry. Compaction before admission uses applied context; compaction after an admitted overflow includes the recorded instruction.

This selects neither Workspace rebinding nor a provider-specific tool/effort update protocol. Request construction, sparse revisions and continuation compatibility are owned by [Sparse context and exact model requests](ARCHITECTURE.md#sparse-context-and-exact-model-requests).

## Tools and multiple calls

V1 executes `bash` and one-file `edit`. The Tool Catalog is model-visible data; a separate closed Host mapping and exact Authorization decide what may execute.

One model response may contain multiple ordered Tool Calls. Each becomes an independently recoverable child Operation and may settle into SQLite as soon as it finishes. Bash, Edit, and model Operations may run concurrently even within one Workspace under Active Capacity; no permanent Edit lane or Workspace isolation is implied. The next model Operation waits for every child result and receives Tool Results together in original call order, not physical completion order.

Permission Mode is persistent Session configuration, defaulting to `ask`; the Local Owner may explicitly change it, including during active work. Each child Action admission selects the current committed mode and records its configuration provenance together with the exact descriptor and either an immutable Permission Request (`ask`) or Authorization (`bypass`). Later mode changes do not answer pending requests, revoke existing Authorizations, or stop running actions. Recovery reuses the admitted facts rather than current settings. Both modes preserve validation, Attempt admission, cancellation, and effect-specific recovery; server access never selects bypass implicitly.

## Workflow and Run interface

The Host Runtime exposes one narrow typed Run API rather than a separate Run Service component. Explicit operations create or attach a Run, create and configure Sessions, submit Session messages, decide one Permission Request, interrupt one exact unresolved Model Operation when explicitly targeted, stop current Session work, and cancel one Run. Bounded driving is internal to the server and composes multiple short semantic transactions; no public `advance` operation is required. Inspection captures a complete report as of one committed moment before delivery. Database updates wait during capture, then resume while the caller receives the report. Before another queued inspection begins, ready control commands get a bounded opportunity to run; a stop need not wait behind the whole report backlog. One capture can still delay controls; the one-second p95 acknowledgement target under defined saturation tests is a qualification requirement, not a hard deadline or a physical termination guarantee. Later progress does not invalidate it; commands still check their exact targets. Immutable content is read through fixed windows.

The local HTTP adapter owns the closed versioned JSON wire contract; the CLI consumes it and renders JSON or Markdown. Compiled public types and golden fixtures freeze the automation contract covering every field, union tag, omission rule, and integer encoding; IDs, revisions, offsets, and other `u64`-class values are JSON strings. Until that contract exists, no replacement JSON format is accepted. Markdown is the default deterministic model-facing view of the same facts. Every actionable Permission Request and every other current logical collection member appears without a collection cap or external pagination token. Variable fields and workflow-visible structured values use immutable Content References rather than resident recursive object trees. Client process death, terminal closure, and shell timeout detach without cancelling durable work. A successfully delivered workflow failure is a valid zero-exit protocol result; nonzero means invocation, access, infrastructure, or rendering failure. Stdout contains only the selected data format and diagnostics go to stderr.

## Product guarantees

V1 preserves recovery facts, accepted results and exact provider continuation in one SQLite Host Store. Sessions remain reusable with at most one active Turn. Dormant Sessions, settled Turns and waiting workflows retain durable facts rather than resident workers. The [execution guarantees](docs/architecture/execution.md#required-execution-and-recovery-guarantees) define admission, settlement and recovery; the [limit matrix](docs/architecture/resources.md#v1-limit-matrix) owns numeric defaults.

- Accepted work waits, remains cancellable and survives restart when execution capacity or known temporary storage is unavailable. Waiting starts no Attempt and consumes no retry allowance. Capacity returns only after safe physical cleanup.
- Temporary storage is shared and configurable, with an 8 GiB default. Files needed by current work are protected; retained files share oldest-first reclamation. Published spillover is charged while OnePage retains it. External additions or storage kept alive by other programs after removal are outside this logical allowance. It reserves no disk space.
- Storage exhaustion after admission stops affected execution safely and reports failure. It neither truncates success nor automatically reruns work. Failure to save application state stops the Host; explicit restart after repair uses ordinary recovery. Tool termination cannot undo external effects.
- Model requests allow three retries by default after waits of 2, 4 and 8 seconds, extended for provider-requested delay. Retry inputs, consumed allowance and eligibility survive restart. Five minutes without incoming body data, including heartbeats, triggers the retry policy; progressing responses have no total deadline. Turns have no model-request count limit or whole-Turn deadline. Replacement calls may duplicate work or billing.
- Bash defaults to a five-minute execution timeout. A call may choose any positive finite representable duration through `timeout`. Output does not extend it; permission/capacity waits do not consume it. Timeout returns a Tool Result. Uncertain Bash is never automatically replayed.
- Tool output streams within shared temporary storage. Large output succeeds with the last 10,000 bytes of output text, omission metadata and a path readable through Bash; shorter output is included in full. Full spillover may outlive a Turn but disappear through reclamation or Host exit. Saved results survive independently; missing spillover never authorizes automatic replay.
- Edit recovery compares exact intent, preimage, expected postimage and observed state. Unproved external effects remain explicitly indeterminate.

OnePage bounds its orchestration resources separately from model-requested subprocess memory. Codex subscription is the first live provider; adapters do not own conversation, permission or recovery policy.

## Exact file edits

`edit` performs one exact `oldText` → `newText` replacement in an existing accessible file. Search text must be nonempty, unique and at most 16,384 decoded bytes. This bound applies neither to the file nor replacement text. Missing or ambiguous matches fail without mutation; empty replacement deletes matched text. Surrounding bytes are preserved. Fuzzy matching, replace-all, batching and file creation are outside this tool.

Bash and Edit may access files outside Git and outside the Workspace: relative paths start at the Workspace, absolute paths may point elsewhere. Filesystem permissions and exact Action Authorization still apply. Edit runs in-process with bounded streamed I/O; it has no independent crash isolation. [Native Edit](docs/architecture/execution.md#native-edit-module) owns matching, authorization, reconciliation and resource details.

## Local diagnostics

V1 records small structured diagnostics locally by default and keeps them across ordinary restarts. Retained history has a configurable 128 MiB default cap per Host; the oldest records are replaced as needed, with no additional age-based expiry rule or fixed-days retention promise. This disk allowance does not allocate an equally sized RAM buffer. They help explain failures through execution identifiers, timings, error classifications and application/provider version information where available. Users can export recent diagnostics for inspection and choose whether to share them; no central collection backend is required.

Diagnostics are separate from application state. Their loss or expiry may make a bug harder to explain but cannot change recovery, accepted results, permissions or retry allowance. Detailed capture of provider payloads and tool output is explicit and bounded; credentials remain excluded. If rejected raw bytes were not captured, investigating some failures may require reproducing them with detailed capture enabled. Complete permanent failed-try investigation is not promised. Detailed capture shares the diagnostic allowance and may shorten retained summary history. Export is best-effort recent history: it identifies gaps if rotation overtakes copying and fails explicitly when temporary storage is unavailable. Slow downloads cannot keep old logs alive indefinitely. Limits take effect at Host startup; exact command spellings remain implementation details.

## V1 exclusions

- Conversation branches, edit/delete, alternate answers, merge, or fork UI. A later fork creates a new Session with explicit ancestry.
- Model-created conversational Input Requests, generic signals, arbitrary forms, credentials, or file uploads.
- Dynamic tools, MCP execution, plugins, skills, hooks, provider registries, automatic model fallback, or generalized OAuth.
- A model-visible Agent tool, recursive model-directed delegation, or durable RLM stack.
- Retained QuickJS, bytecode, Node, timers, imports, filesystem, process, network, environment, credential, clock, or random access inside workflow evaluation.
- MCP Tasks, ACP, A2A, a separate daemon manager, public event stream, watch mode, webhook, push delivery, TUI, editor, or Web UI. The explicit local Host server is part of V1.
- Multi-host scheduling, distributed coordination, external-effect exactly-once claims, or arbitrary Bash sandbox claims.
- Backup, export, retention, deletion, garbage collection, shrinking, or compatibility migration for unreleased V1 databases. Bounded diagnostic retention and diagnostic export are separately included above.

## Demonstration standard

Release evidence must exercise the production paths for deterministic fan-out/fan-in, multi-Turn Session reuse, message/context updates, same-Workspace concurrent tools, client detachment, server stop/crash and shared-Session cancellation. Named crash boundaries must prove safe recovery, no uncertain Bash replay, changed-target Edit reconciliation and one committed Workflow Output.

[Release verification](VERIFICATION.md#release-evidence-and-residual-audit) owns fixture details, density populations, measurements and required artifacts. Report whole-process memory separately from workload subprocesses and qualify each supported platform. Package under the selected final identity without Node, Codex CLI, a separate daemon manager or an additional workflow runtime. Live login/repair stays opt-in; deterministic evidence uses the same production paths without credentials.

## Post-V1 maintenance

Application-state retention and maintenance remain deferred; the local diagnostic contract above has a separate lifetime. Any later design must preserve referential integrity across retained Runs, Sessions, outcomes, permission/context/replay evidence, and Content References. Reclaim content only when no retained canonical reference needs it; export from committed facts. Checkpoint, vacuum, backup, integrity, and archival tools require a concrete need. This creates no V1 application-state retention policy, background daemon, or second semantic store.
