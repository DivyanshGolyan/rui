# OnePage verification contract

This document defines evidence required for V1 claims. Tests use production interfaces and fresh-process reopen. An interrupted suite is reported as interrupted, not green.

## Domain authority

| Claim | Required evidence |
| --- | --- |
| SQLite is sole authority | Recreate every Decision Snapshot and Run Snapshot from canonical relational rows with no Session Ledger, reducer image, continuation blob, or resident cache. |
| Session is linear and reusable | Complete two Turns in one Session, prove immutable ordered Conversation entries, and reject branching and a concurrent second Turn. Ordinary Session messages use current state without a caller historical revision guard; workflow replay recovers its original binding/result. |
| Turns settle; Sessions do not | Completion, failure, and cancellation fixtures commit one Turn Outcome and release Session occupancy atomically. Failure-code and Operation-uncertainty fixtures remain orthogonal to terminality. Releasing transient Host resources changes no Session or Turn meaning. |
| Conditions are derived | Rebuild the exact Turn partition—runnable, waiting for permission, in flight, completed, failed, and cancelled—plus Session dormancy and Run `permission_required` from relational rows after dropping every rebuildable index. Prove immutable future retry eligibility derives in flight without a live effect. |
| Causality is explicit | Every User Message, Conversation entry, Operation, Attempt, Completion, Resolution, Permission Request, Permission Decision, and output resolves to its exact Turn and causal parent without relying on insertion order alone. |
| Pre-V1 is a flag day | Schema tests reject obsolete ledger/reducer formats; no compatibility reader, alias, migration, or dual-write path exists. |

## Context and model requests

| Claim | Required evidence |
| --- | --- |
| Context revisions are sparse | Create a Session and its complete baseline atomically, reject a Session without one, change one component, and prove every unchanged component resolves to its earlier immutable reference. |
| Revisions are atomic | Independently configure a compatible sparse change; the settings and workflow replay result commit together. Lose acknowledgement, apply a later update, and replay the earlier operation without reverting that update. A later message failure leaves configuration committed. A newly constructed request within ongoing work selects the later committed revision. |
| Model settings freeze per request | Construct request A from revision r1, configure r2, then prove A and its retries retain r1 while newly constructed request B uses r2, including within the same Turn. No second Turn-wide model-setting authority exists. Preserve exact Action and Authorization targets; verify runtime information and retained limits on their actual scopes without a Turn Contract. |
| Model request is exact | Persist one Model Request Manifest for each model Operation and reconstruct the same frozen request semantics after fresh-process reopen. |
| Retry does not drift | Replacement Attempts reuse the same manifest while credentials and transport are refreshed independently. A changed component requires a new model Operation. |
| Historical requests remain explainable | After changing ambient model, instructions, tools, or defaults, explain each earlier Operation from its frozen manifest and content references. |
| Provider cache is optional | Disable or lose provider-side conversation/cache identity and produce the same request from the locally retained replay recipe. |
| Provider continuation is lossless | Preserve completed ordered Model Output Items, including exact opaque or encrypted reasoning, signatures, compaction items, and extension fields, outside generic Conversation content. After restart, derive the same replay-input meaning and exact preserved field bytes from the frozen manifest without a second replay copy or stored request body. |
| Continuity never degrades silently | Missing, corrupt, unsupported, or incompatible replay material prevents dispatch with `continuation_unavailable`; no path drops private reasoning or reconstructs from visible Conversation alone. |
| Unknown output fails closed | Preserve unknown open fields inside known records. Preserve an unknown consequential union variant as Completion evidence, resolve it as `unsupported_provider_output`, and publish no Conversation, continuation, or effect consequence. |

The accepted append-only context direction additionally requires successive-request fixtures: retain a response with opaque continuation, change Session instructions, and prove the next request appends the update without rewriting the earlier prefix. Preserve that position and rendering across restart and retries. Cover an update while tool results are pending, two updates before first inclusion, and supported compaction across an applied update. System Instruction is selected as a distinct Conversation Entry kind. Required history fixtures distinguish it from user messages and tool results, preserve exact ordering/content on replay, and ensure provider output cannot manufacture operator authority. First inclusion commits atomically with its assistant-response request; exact storage/wire encoding remains implementation work. These are required checks, not passing evidence.

Execute the [System Instruction boundary traces](docs/design/system-instruction-first-inclusion.md) against production storage and advancement. Cover unchanged instruction content across a new revision; A -> B -> C and A -> B -> A both before and after B was included; atomic instruction/projection/Operation/manifest rollback; lost acknowledgement before dispatch; mode-only updates; pending tools; configuration during compaction; last-applied instructions covered by a base; and predicted versus already-admitted provider overflow. Retry must reuse the original entry without rereading current settings. No production run of these new fixtures is claimed.

Required sparse-context fixture:

```text
r1: model=A, instructions=I1, tools=T1
r2: tools=T2
r3: instructions=I2

Request 1 binds r1
Request 2 binds r2
Request 3 binds r3

Request 3 resolves model=A, instructions=I2, tools=T2
```

The fixture restarts between each revision and verifies exact content references and manifest digests. Include multiple requests within one Turn, two settings updates before preparation (only the latest value is selected), changes after manifest commit but before dispatch, and failed preparation followed by later settings changes. Configuration alone must create no model work. These are required scenarios, not completed runtime evidence.

## Model output and tools

One model response fixture emits assistant text plus three Tool Calls. Admission must:

1. validate the complete ordered candidate before mutation;
2. commit every Tool Call and child Action Operation atomically;
3. reject the complete candidate for a duplicate call identity, unknown Tool Key, malformed arguments, or invalid member;
4. execute children independently under Active Capacity with no Workspace fence or isolation claim;
5. survive independent permission, denial, failure, cancellation, and uncertain-effect outcomes; and
6. construct the next Model Request Manifest with every Tool Result in original call order regardless of completion order.

Permute physical completion order and prove that Conversation, the next model request, Turn Output, and Workflow topology remain identical.

Tool visibility and execution authority remain separate. Arbitrary provider-neutral Tool Keys round-trip as data, but only admitted `bash` and `apply_patch` bindings execute. Permission Decisions bind exact Principal, request, Operation, descriptor digest, and decision.

## Operations, Attempts, and recovery

| Boundary | Required fresh-process result |
| --- | --- |
| Before Attempt commit | No external dispatch authority exists. |
| After Attempt commit, before dispatch | Recovery treats dispatch according to the Operation's conservative uncertainty contract. |
| During provider/tool execution | No SQLite transaction, payload-sized resident buffer, reducer image, or notification is required to rediscover admitted work. |
| After scratch seal, before normal settlement | Scratch is non-authoritative; process death loses it and leaves the Attempt unresolved for effect-specific recovery. |
| Normal settlement | Immutable content, the single Attempt Completion, Operation Resolution, Conversation or permission facts, and the next semantic consequence commit together or not at all. |
| Retryable model settlement | Completion and immutable retry eligibility commit together while the Operation remains unresolved and owns no waiting memory or timer. |
| Interrupted model settlement | Direct Model Interruption or an applicable ordinary Session stop commits an `Interrupted` Operation Resolution without manufacturing a Completion. Its provenance cites either the direct command's Local Owner and exact target or the applicable Session stop, preserving causal Run Cancellation Intent where relevant. Recovery retries only missing-Completion Attempts whose Operations remain unresolved. If the physical launch boundary has not been crossed, the owner suppresses the unconsumed Dispatch Permit; otherwise it closes or detaches the local transport. Physical Custody persists through that cleanup without a second provider-cancellation request or acknowledgement wait, and partial or late provider output can enter neither Conversation nor a later request as continuation material. |
| After Resolution, before acknowledgement | Replay returns the committed result without another transition. |

Model recovery records possible duplicate work or billing and reuses the exact manifest. Bash recovery never redispatches uncertain work. Patch recovery distinguishes preimage, expected postimage, divergence, and invalid target. Each Attempt admits at most one Completion: exact replay is idempotent and conflicting evidence is rejected without mutation. Cancellation intent and transport shutdown cannot race to create competing Completions; only the effect-specific terminal owner proposes evidence.

The relational settlement matrix covers all combinations used by recovery. `Completion present / Resolution absent` is legal only for a retryable model Completion committed with future eligibility. Interruption during that delay inserts the `Interrupted` Resolution beside the earlier Completion; every due-work query joins through an unresolved Operation and therefore ignores the historical eligibility. `Completion absent / Interrupted Resolution present` is the deliberate live-model-abandonment exception above.

Streaming fixtures prove that the I/O Reactor writes provider and Bash bytes directly to dynamically charged, immediately unlinked scratch through fixed borrowed windows. No per-Attempt candidate, parser, request, response, or output buffer scales with Active Capacity. Complete model output is parsed once after terminal seal in the shared serial validation/import workspace. Post-commit request-materialization failure becomes evidence for the admitted Attempt.

Storage failure injection covers full, I/O, allocation, corrupt content, foreign reference, wrong digest, and transaction rollback. SQLite faults expose neither half a semantic relation nor content without its first reference.

## User Messages and permission

Fixtures prove:

- Session creation and baseline commit without model work; message admission separately starts or joins current work, with workflow key/input/result binding committed atomically where applicable and no direct caller key;
- initiating admission atomically creates the User Message and its Conversation Entry;
- later User Message admission creates an immutable `user_messages` row without a Conversation Entry or change to an already-admitted Model Request Manifest;
- the next assistant-response model-Operation admission transaction projects every applicable unprojected message in admission order and freezes the manifest, while an intervening compaction model Operation uses only already-applied context and leaves them pending;
- both SQLite commit orders around assistant-only settlement produce the documented result: message-first retains ordinary assistant text and requires a later model Operation; settlement-first commits Final Answer and prevents attachment to that Turn;
- a sealed User Message source and its first semantic reference become authoritative together, with exact length and digest verification and no payload-sized resident allocation;
- one Permission Decision binds the exact Principal, request, Operation, descriptor digest, and decision;
- identical Permission Decision replay is idempotent, while a conflicting, stale, inapplicable, unknown, or unauthorized decision fails without mutation;
- Session creation defaults Permission Mode to `ask`; only explicit Local Owner configuration selects `bypass`, and configuration replay does not reapply an old mode;
- child Action admission atomically binds the current mode and sparse configuration provenance with the exact descriptor and either an immutable Permission Request or bypass Authorization;
- ask-to-bypass leaves an existing request pending, while newly admitted actions use bypass; bypass-to-ask leaves an already-authorized but not-yet-started action authorized, while newly admitted actions require decisions;
- mode changes during an in-flight model request affect later Action admissions without changing that model request or already-admitted actions; siblings admitted in one transaction select the same configuration view;
- both commit orders of configuration versus Action admission, rollback before admission, lost acknowledgement, crash/reopen, and configuration replay preserve the selected permission facts without retargeting or duplicate requests/Authorizations;
- running actions are not interrupted by configuration; ordinary stops and cancellation still prevent inapplicable permission decisions or Attempts;
- a generic response batch and conversational Input Request do not exist;
- a terminal Turn has no applicable User Message or actionable Permission Request;
- definitive failure may commit with still-unprojected User Messages only after all other semantic obligations are resolved; the failed Outcome itself makes them inapplicable and releases logical Session occupancy atomically;
- pre-request `ResourceExceeded` creates no fake Operation, manifest, Attempt, Completion, or message projection; Operation-derived terminal failure instead references the same Turn's accepted Resolution;
- ordinary Tool errors, retryable Completions, recoverable overflow, and direct interruption do not independently authorize Turn failure;
- both failure/admission commit orders preserve intent: message-first retains not-applied input on the old Turn; Session-current admission after failure begins new work, while an exact stale Turn target rejects;
- excluded input stays readable with its causal reason but never enters a later request without a new explicit admission; existing projections are not relabeled as proof of provider consumption;
- rollback/storage failure claims no committed outcome or occupancy release, while reopen after lost acknowledgment recovers the one immutable outcome without another provider call;
- unresolved Operations, effects, permissions, and required Tool Result publication block failure settlement; late evidence cannot overwrite accepted Resolution/Outcome facts;
- failure disposition derives from existing rows without a new failure-intent table, message phase, withdrawal record, or resident queue.

`permission_required` appears in a Run Snapshot only when at least one Permission Request is actionable and no other member Turn can progress.

## Runtime information and limit ownership

The [Turn Contract removal trace](docs/design/turn-contract-removal.md) requires:

- no separate contract row or generic runtime-facts snapshot at Turn admission;
- a changed clock or filesystem after request admission leaving that request's instruction content/rendering inputs and replacement Attempts unchanged;
- later supplied instruction changes using the existing append-only first-inclusion path, with no automatic refresh policy implied;
- Session Workspace identity, admitted Action descriptors, and earlier Tool Results retaining their original meaning after external Workspace changes;
- Host resource admission on restart respecting current capacities without rewriting admitted model/Action inputs;
- if #91 retains a Turn-wide dispatch allowance/deadline, ordinary requests, retries, and compaction sharing that scope across restart without resetting it at a new Operation;
- pre-request failure retaining selected configuration/input provenance in the existing outcome, without a fake request or Turn Contract; and
- compaction and workflow replay recovering their respective request and evaluator bindings without the removed grouping.

These are production verification obligations. Removing the grouping does not select limits or bypass #89's pre-implementation gate.

## Workflow replay

Required workflow fixtures must use the production QuickJS boundary and the proposed `export default async function workflow({ createSession, configureSession, sendMessage }, args)` signature (configuration naming and acknowledgement shape remain to be finalized). The revised API is not implemented yet; these are required checks, not passing evidence. They cover:

- idempotent Caller Run Key and stored invocation Workspace;
- distinct Run-local creation/configuration/message keys binding operation kind and complete inputs;
- empty Session creation with complete baseline and no model work;
- lost creation acknowledgement recovering the same Session ID;
- configuration effect and replay result committing atomically without model work;
- replay of an old configuration operation leaving a later change intact;
- configuration remaining committed after later message failure or a crash before sending;
- another client changing settings between configuration and message admission without an invented stale-view rejection;
- existing Session IDs used directly without wrapper or attachment;
- first and later messages sharing the same API, with exact schema output and frozen rejection;
- optional Session output schema persisting across messages, with ordinary text when absent and no schema mutation through message options;
- changing or clearing a schema after request A is constructed leaves A and its retries unchanged; the next applicable request uses the new configuration, and replay returns the original result without validating it against current settings;
- provider-boundary fixtures covering supported structured success, unsupported schemas, malformed or schema-invalid output, refusal, and incomplete generation without fabricated success, prose conversion, or automatic model repair calls;
- shared-work message callers receiving the same recorded result under the producing request's schema, without caller-specific schema expectations;
- creation alone excluded from the Run cancellation Session set;
- lost membership acknowledgement;
- evaluator death before and after Turn admission;
- whole-blocked-set replay;
- staged fan-out and synthesis;
- deterministic `Promise.all` and `Promise.allSettled`;
- absence of `Promise.race` and `Promise.any`;
- final Workflow Output idempotency;
- source, arguments, value, CPU, wall-time, and cumulative replay bounds; and
- no JavaScript continuation or evaluator process retained at a barrier.

Two workflow calls in one Workspace prove that independent Bash and Patch Operations may progress concurrently under Active Capacity, completions settle without sibling head-of-line blocking, and filesystem interference is reported as observed evidence rather than prevented by a Host fence. Fixtures prove Bash and Patch use the same Action lifecycle without a permanent Patch lane or global serialization.

## Run interface

Golden and hostile-input tests exercise the local HTTP adapter, thin CLI, and typed Host Runtime API independently. Compiled public types and golden fixtures must freeze the complete closed JSON contract before any replacement format is accepted. Those fixtures pin every field, union tag, omission rule, and integer encoding; IDs, revisions, offsets, and other `u64`-class values are strings. Markdown consumes the same logical scan and introduces no facts. Neither encoding exists inside the native semantic boundary, and no handwritten schema duplicates the compiled contract.

Tests cover:

- create/attach conflict by exact binding;
- direct and workflow Session messages sharing one primitive and canonical User Message kind, while only workflow operations carry Run-local replay keys;
- one Permission Decision per mutation and absence of a generic response batch;
- Local Owner Run cancellation and exact domain repeat/conflict behavior without a direct CLI key or whole-Run optimistic revision precondition; rejected access cannot mutate, while all admitted clients share authority;
- authorized and idempotent interruption of one exact unresolved Model Operation, including exact domain replay and rejection of conflicting input, inaccessible Store, Action target, resolved target, and terminal work without a whole-Run revision precondition;
- one Run Cancellation Intent fencing further evaluator generations and Run creation/configuration/message admissions, with the affected Session set derived from earlier committed message admissions; ordinary Session stops separately fence their selected work;
- first-commit-wins settlement when provider evidence and an applicable Session stop race, with late evidence unable to bypass the committed stop;
- multiple keyed admissions/Runs sharing one Turn, no automatic cancellation of other Runs, and no Session finality from Run cancellation;
- Session stop acknowledgement before completion, idle immediate completion, and selected-work terminal outcome plus atomic occupancy release determining completion independently of later Session activity;
- model stop completion while transport cleanup still retains its charged Physical Custody, without retry or acceptance of late output; started tools retain their existing evidence/reconciliation and ordered Tool Result obligations before work settles;
- a slow tool in one Session not delaying stop requests to later Sessions during bounded workflow cancellation traversal;
- identical ordinary Session-stop completion semantics for work submitted by the cancelling Run or another client, with Run cancellation completion waiting on the required stops rather than a separate submitted-by-this-Run predicate;
- ordinary stop/terminal facts deriving pending User Messages and Permission Requests in stopped work as inapplicable without per-item withdrawal state;
- bounded stop-pass traversal over distinct submitted-to Sessions, excluding creation/configuration/read-only use and retaining no resident Session population;
- crashes before the first stop, between stops, and after the last stop but before Run completion commit; recovery may repeat the full pass and must finish all required stops before recording cancellation completion;
- earlier successful or idle stops being repeated against newer work while Run cancellation is unfinished; this is permitted caller-coordination behavior, not a lost isolation guarantee;
- lost acknowledgement or server restart after durable Run cancellation completion returning the existing outcome without further Session stops, including after later Session continuation;
- stop/storage failure leaving Run cancellation unfinished; normal effect-specific cleanup remains recoverable independently, with no per-Session propagation receipt, idle-check record, durable cursor, or cancellation queue;
- immediate Interrupted Resolution for an active model request while its bounded Physical Custody drains independently;
- both SQLite orderings of Attempt admission and cancellation, plus both physical launch-boundary orderings after Attempt commit: pre-launch suppression or post-launch cleanup without changing the SQLite winner;
- Run cancellation of a Model Operation with no Attempt, retry-delayed eligibility, an unconsumed Dispatch Permit, a live stream, and sealed but unsettled output;
- cancellation of an Action with no Attempt, Bash process-group interruption, Patch cancellation before mutation as not applied, and a started Patch finishing bounded execution and reconciliation;
- one typed Tool Result for every accepted cancelled Tool Call, preserved in call-ordinal Conversation order before the cancelled Turn Outcome;
- concurrent client commands serialized by the sole server Storage Owner, using the same bounded classifier as internal advancement without a resident driver lease or client-owned recovery;
- retry-delayed unresolved model Operations remain `in_flight`, own no Active Credit, and become eligible through the bounded SQLite poll;
- one bounded drive quantum composing multiple separately atomic transitions, stopping at the documented conditions, and reporting whether immediate work remains;
- complete inspection captured from one committed view on the existing connection through bounded private batches, with revision and all facts read inside that view;
- database admissions and settlements waiting during capture, then proceeding before delivery completes; later revisions do not invalidate a captured report and exact-target controls still reject stale actions;
- ready controls receiving a bounded driving turn before another queued inspection capture, while the current capture remains complete and consistent; measure request arrival, durable acknowledgement, interruption dispatch, and the remaining single-capture delay separately;
- release of active SQLite statements and the read transaction before delivery, bounded memory during large capture, and private-scratch cleanup after success, failure, abandonment, or process death;
- explicit failure for incomplete capture or delivery, including missing terminal framing, plus measured whole-Host command delay, aggregate scratch, and retained memory under repeated polling and slow clients;
- immutable content range reads and sealed-source ingress through fixed windows;
- complete visibility of every actionable Permission Request and every other current logical collection member without logical caps, caller page sizes, or serialized continuation tokens;
- Run–Turn membership summaries that keep Agent Call Key separate from Turn identity and partition members into the exact derived conditions/outcomes;
- recursive workflow-visible values crossing the Run API as immutable typed content rather than native object trees;
- untrusted model/tool text isolated from control framing; and
- SIGINT, timeout, terminal closure, and output failure detaching without cancellation.

## Server lifecycle and local command boundary

Use production Unix-socket HTTP and fresh server/client processes to verify:

- simultaneous server starts, supported equivalent Store paths, and distinct Stores yield one live owner per Store; unsupported aliases reject rather than split authority;
- missing server, wrong Store/version, inaccessible peer, long socket path, stale socket, unexpected file at the endpoint, and restart races never cause client auto-start, client SQLite access, or blind unlink;
- disconnecting every client leaves eligible work advancing; a later client observes it without treating live Attempts as abandoned;
- server stop/crash before and after admission, dispatch, scratch seal, and commit preserves exact request bindings and remaining retry allowances on explicit restart; uncertain Bash is not replayed and Patch reconciles;
- stop with an active model stream, Bash, Patch, and delayed retry fences dispatch promptly, retains safe cleanup, and fabricates no semantic cancellation/interruption merely because transport closes;
- direct keyless submission reports uncertainty after lost acknowledgement and sends no automatic repeat; Run/workflow replay with original key and inputs recovers the committed fact after terminality/restart, and changed inputs conflict;
- Session waits select work once; later Session reuse cannot extend the wait indefinitely or substitute a newer result for a workflow's recorded answer;
- recent/kind/after history reads and separate unapplied-input reads preserve exact content and reasons without loading all history on every inspection;
- truncated/slow uploads publish no content or semantic reference; malformed headers, version failures, incomplete report framing, slow readers, saturation, and connection churn produce typed failure or bounded pressure without hidden resident populations;
- public operations use exact domain targets, with no per-client ACL, generic command journal, public scheduling requirement, or independent content upload lifecycle; and
- stdout contains only the selected data format, stderr carries diagnostics, and delivered workflow failure is a valid zero-exit protocol result while invocation/access/infrastructure/rendering failure is nonzero.

## Provider and evaluator integration

Provider fixtures cover post-commit request-materialization failure, provably-not-started and may-have-started dispatch, auth refresh/account continuity, DNS/TLS, arbitrary SSE fragmentation, terminal provider records, disconnect, cancellation, delayed retry, long-lived concurrency, deterministic incompatibility, and storage failure. Resume uses the persisted provider binding rather than silently attaching a fixture. Only opt-in live checks contact the provider; deterministic equivalents traverse the same production owners.

OAuth syntax fixtures round-trip every JSON-required control byte and exact legal boundaries through device polling and stored credentials. Prove worst-case escaping capacity, reject missing/extra/empty compact-token segments, reject unsafe token/account header bytes at construction and libcurl reuse, and preserve exact account binding on refresh. Keep numeric account syntax decisions with the shared-boundary issue. The historical source findings in the [cleanup record](docs/design/planning-cleanup-2026-09-05.md) are not passing evidence.

Evaluator lifecycle checks prove descriptor isolation through construction and close-on-exec with three stdio pipes and an empty environment, absent native descriptor capabilities, and disabled core dumps. Verify no numeric `RLIMIT_NOFILE` scan and no whole-capacity exit-time overwrite/free of process-lifetime input/output/bridge mappings. Compare at least five real evaluator invocations at the default descriptor limit and at `ulimit -n 256`, reporting median wall time and maximum RSS; there must be no latency proportional to the numeric descriptor ceiling. Run the existing workflow and canonical gates. The containment decision still owns the limits; archived timings do not certify the eventual implementation.

## Compaction

Compaction tests preserve every source Conversation byte while selecting one exact derived Compaction Base plus a complete compatible suffix. They cover:

- a soft approximate Compaction Trigger that never rejects, splits, or truncates a User Message;
- provider-reported usage plus estimation of only newly appended model-visible content;
- every User Message admitted between consecutive model-Operation admissions remaining distinct in SQLite and entering the next manifest together;
- deterministic approximate Compaction Trigger crossing, exact configured output reservation, and authoritative provider-overflow handling;
- intact Tool Call/Tool Result boundaries;
- source change during summarization;
- invalid, empty, oversized, stale, corrupt, and incomplete compaction results;
- complete source-manifest coverage and current-lineage selection;
- acknowledgement loss after compaction settlement;
- repeated compaction;
- exactly one canonical replacement output owned by the selected Completion, with no Compaction Checkpoint relation or semantic-handoff alternative;
- Core structural replay validation and adapter-owned provider compatibility composed from immutable source and target facts rather than a persisted validity flag;
- complete total ordered suffix replay through accepted model Resolutions and canonical host inputs, including opaque reasoning and known extension fields;
- unknown consequential union variants retained as evidence but rejected as `unsupported_provider_output` before continuation publication;
- explicit `continuation_unavailable` for missing or incompatible replay material, including unsupported model or replay-format changes demonstrated by adapter fixtures;
- rejection or deferral of incompatible context change without provider dispatch;
- provider overflow resolving the old model Operation, followed by compaction and a new model Operation rather than a changed-manifest Attempt;
- Session Context Revision, exact instruction/rendering inputs, Model Request Manifest, complete covered frontier, lineage, and model provenance derived through the Compaction Base's creating model Operation, without a Turn Contract;
- newest accepted base selection before compatibility validation, with failed or unresolved compaction unable to displace it and missing, corrupt, unsupported, or incompatible selected material unable to trigger an older-base search; and
- `ResourceExceeded` after the allowed valid Attempts cannot produce a fitting request.

Model-result settlement tests prove that one transaction publishes immutable Completion-owned Model Output Items, the selected Resolution, and every applicable Conversation projection without a duplicate replay object. Adapter tests derive replay inputs by removing response-only fields while retaining exact provider-only continuation bytes. Raw scratch is deleted after canonical import. Partial, interrupted, failed, cancelled, and late streams publish no continuation input. Oversized Tool output produces one small typed Tool Result that tells the Agent to retry more narrowly; any partial capture remains Completion evidence only.

## Memory and density

The [accepted execution-control simplification](docs/design/execution-control-simplicity.md) also requires fixed-table saturation and reuse checks: free plus occupied equals configured capacity, reservation rollback restores capacity, commit-before-launch crash does not recreate a Dispatch Permit, and cancellation retains live resource custody until safe release. Delayed/duplicate events cannot affect a reused record's newer Attempt. Benchmark plain scans and completion bursts at the selected capacities before considering another index; exploratory capacity 1,000 is not an accepted product ceiling. Measure actual idle CPU and wake counts separately from per-scan arithmetic, preserving the required retry poll and deadlines.

Measurements report whole-process RSS and each independent axis:

- Dormant Session count;
- terminal and nonterminal Turn count;
- Active Capacity and occupied Active Credits;
- Storage Owner, I/O Reactor, and temporary Action-executor incremental and retained-idle cost;
- the one content-free Physical Custody table's record size and occupancy, where each occupied record is one Active Credit;
- transport-library threads, stacks, fixed windows, sockets, and resolver resources;
- subprocess trees and model-requested workload memory;
- shared serial validation/import workspace high-water;
- SQLite heap, database bytes, journal bytes, and writes;
- Workflow Evaluator heap, bridge memory, process RSS, and replay count;
- immutable content, unlinked-scratch logical and physical bytes, filesystem-cache pressure, and raw-plus-canonical overlap.

Required population points are 0, 100, 1,000, and 10,000 Dormant Sessions at fixed capacity, then Active Capacity 1, 10, 50, and 100 at fixed durable population. Repeated 0→capacity→0 churn must return resident orchestration memory to the same bounded envelope. Terminal Turn population adds durable bytes rather than resident execution objects. At each active point, report end-to-end Turn latency, provider and tool overhead, evaluator replay, SQLite transaction cost, and throughput alongside memory and OS-resource measurements.

Every new allocation topology records its owner, multiplier, maximum, ordinary occupancy, release boundary, failure behaviour, and reason an existing owner cannot serve it before implementation.

Certification additionally measures unopened, Store-open, and Host-started idle baselines, with Active Capacity zero where supported, and separate idle CLI cost. Connected-client population varies independently from external Active Capacity and durable Run count, including slow inbound/outbound transfers, saturation, and connection churn. Distinguish analytical worst case, reserved virtual memory, physical resident/private dirty memory, observed high-water, kernel/socket resources, file descriptors, filesystem cache/writeback, and temporary disk. Use representative Conversation/content in the 10,000-Session fixture and check in raw inputs and calculations. Numeric pass/fail targets come from the approved limit matrix; any unexplained slope or budget miss triggers architecture review before another pool or cache is added.

## Release evidence and residual audit

Package the demonstrations specified in PRODUCT.md through production interfaces, with exact expected observations and checked-in measurements/calculations. Finalize the project name before packaging so examples and later audits use the same identity. Demonstrate explicit server start, no-client progress, server interruption and restart, keyed fan-out/fan-in, direct Session use, separate creation/configuration/messages, multiple ordered tool calls, uncertain Bash, Patch divergence, and shared-Session cancellation. Do not retain historical exact-Turn public examples or fixture-only state machines as the V1 experience.

After integration, audit only residual gaps in domain authority, context/request/compaction integrity, workflow replay, permission/cancellation, SQLite schema identity and closure reserve, corruption/I/O behavior, endpoint ownership, and external-effect uncertainty. Each invariant names its owning table/constraint/transaction and a relevant recovery fixture. Canonical content and its first reference commit together, leaving no V1 orphan-cleanup requirement. Rely on SQLite's guarantees directly; do not recreate a generic ledger audit or duplicate an already-proven fault campaign. Unsupported platform behavior is a release blocker, not a reason for hidden fallback.

Compiler-backed declaration discovery covers the final ReleaseSafe and ReleaseSmall production graphs. Classify test-only, fixture-only, conditional, and intentionally unused declarations; prove obsolete Job, Step, ledger/reducer, terminal-Session, duplicate schema, and compatibility APIs are removed rather than merely unreachable. Public types must agree across the native API, Unix-socket HTTP adapter, and CLI rendering. No declaration exists solely for an unselected future provider, protocol, workflow engine, or migration.

## Canonical gates

Before V1 release:

- deterministic model, Bash, patch, User Message, permission, multi-tool, context-revision, compaction, workflow, and Run fixtures pass;
- hard-termination fixtures pass from fresh processes at every distinct acknowledgement and external-effect boundary;
- ReleaseSafe tests and ReleaseSmall build pass;
- evaluator protocol, JavaScript conversion, sanitizer, mutation/property, and leak gates pass on their supported platforms;
- compiler-backed declaration discovery reaches the completed source graph;
- `git diff --check` passes; and
- the opt-in Codex repair completes through the same Model Request Manifest, Operation, tool, permission, and Turn paths used by deterministic fixtures.
