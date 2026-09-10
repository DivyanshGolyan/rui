# OnePage verification contract

This document defines evidence required for V1 claims. Tests use production interfaces and fresh-process reopen. An interrupted suite is reported as interrupted, not green.


## Topic contracts

Read the relevant branch before changing its behavior; these files are part of this normative contract.

| Branch | Read for |
| --- | --- |
| [Execution](docs/verification/execution.md) | Attempt admission, settlement, retries, tool output, Bash and Edit recovery. |
| [Workflows](docs/verification/workflows.md) | Workflow replay, evaluator lifetime, Run controls and inspection. |
| [Resources](docs/verification/resources.md) | Memory, temporary retention, limit defaults and qualification. |

## Consumer and interface design evidence

Trace direct Session use with a permissioned effect, workflow fan-out/fan-in and sequential Session reuse, client disconnection and restart from durable facts. Identify caller knowledge and ownership of scheduling, lifetime, resources, credentials, recovery and observation at each interface. Integration evidence uses production interfaces rather than a second implementation of Session behavior.

An independent native caller and Cloudflare Durable Object hosting are design probes for hidden coupling, not requirements to ship embedding/cloud support or a runnable external adapter. A walkthrough or focused experiment may expose missing storage, driving or workspace-effect contracts. Compilation, mocked storage and source inspection do not establish deployed transaction, recovery, scratch or memory guarantees. Keep unresolved mechanism choices with their existing owners. See the [consumer decision](https://github.com/DivyanshGolyan/onepage/issues/118).

## Platform qualification

Linux and macOS remain design targets under the [platform contract](ARCHITECTURE.md#platform-contract). The accepted evidence policy runs applicable production behavior, recovery and resource checks on the available Mac, plus portable-API/dependency evidence and cross-compilation for other targets. A Linux distribution/CPU runtime fleet is not a release gate. Record the actual machine, dependency builds and executed checks; label cross-compilation and compatibility assumptions separately. Missing target execution is neither a passed test nor evidence of equivalent memory, cancellation or filesystem behavior.

Retain locally applicable Session/workflow, storage/recovery, permission, provider-fixture, Bash/Edit, cancellation, cleanup, endpoint and temporary-retention checks. Define the counters used for resource/control-response qualification; unavailable counters are not zero. Live provider checks remain opt-in. A known unsupported dependency or behavior requires an explicit design response, not a hidden fallback.

Credential checks cover explicit backend selection, locked/unavailable stores, account-preserving refresh, failed atomic save, access checks and no silent plaintext fallback or inherited credentials. The selected Linux plaintext option does not protect secrets from same-user Bash. Deployment checks establish local Store support and accessible scratch, identify known memory-backed backing, and state unknown backing as an assumption. Pin reproducible bundled dependencies; ordinary builds do not fetch the latest version automatically.

The [platform decision](https://github.com/DivyanshGolyan/onepage/issues/126) and [decision record](docs/design/platform-contract-review.md) own this amendment. Their acceptance is design readiness, not passing implementation evidence.

## Domain authority

| Claim | Required evidence |
| --- | --- |
| SQLite is sole authority | Recreate core observations from canonical core rows and composed Run inspection through workflow records plus core APIs, without cross-owner table access, a Session Ledger, reducer image, continuation blob or resident cache. |
| Session is linear and reusable | Complete two Turns in one Session, prove immutable ordered Conversation entries, and reject branching and a concurrent second Turn. Ordinary Session messages use current state without a caller historical revision guard; workflow replay recovers its original binding/result. |
| Turns settle; Sessions do not | Completion, failure, and cancellation fixtures commit one Turn Outcome and release Session occupancy atomically. Failure-code and Operation-uncertainty fixtures remain orthogonal to terminality. Releasing transient Host resources changes no Session or Turn meaning. |
| Conditions are derived | Rebuild the exact Turn partition—runnable, waiting for permission, in flight, completed, failed, and cancelled—plus Session dormancy and Run `permission_required` from relational rows after dropping every rebuildable index. Prove current future retry eligibility derives in flight without a live effect. |
| Causality is explicit | Every User Message, Conversation entry, Operation, current Attempt identity, Operation-owned Resolution, Permission Request, Permission Decision, and output resolves to its exact Turn and causal parent without relying on insertion order alone. |
| Pre-V1 is a flag day | Schema tests reject obsolete ledger/reducer formats; no compatibility reader, alias, migration, or dual-write path exists. |

## Context and model requests

| Claim | Required evidence |
| --- | --- |
| Context revisions are sparse | First complete configuration saves the Session, baseline and original core request answer atomically; incomplete initialization leaves no partial Session. Change one component and prove omitted components resolve to earlier immutable references. |
| Revisions are atomic | Independently configure a compatible sparse change; the settings and core request answer commit together; Workflow Runtime records the answer separately through recoverable submission. Lose acknowledgement, apply a later update, and replay the earlier operation without reverting that update. A later message failure leaves configuration committed. A newly constructed request within ongoing work selects the later committed revision. |
| Model settings freeze per request | Construct request A from revision r1, configure r2, then prove A and its retries retain r1 while newly constructed request B uses r2, including within the same Turn. No second Turn-wide model-setting authority exists. Preserve exact Action and Authorization targets; verify runtime information and retained limits on their actual scopes without a Turn Contract. |
| Model request is exact | Persist one Model Request Manifest for each model Operation and reconstruct the same frozen request semantics after fresh-process reopen. |
| Retry does not drift | Replacement Attempts reuse the same manifest while credentials and transport are refreshed independently. A changed component requires a new model Operation. |
| Historical requests remain explainable | After changing ambient model, instructions, tools, or defaults, explain each earlier Operation from its frozen manifest and content references. |
| Provider cache is optional | Disable or lose provider-side conversation/cache identity and produce the same request from the locally retained replay recipe. |
| Provider continuation is lossless | Preserve completed ordered Model Output Items, including exact opaque or encrypted reasoning, signatures, compaction items, and extension fields, outside generic Conversation content. After restart, derive the same replay-input meaning and exact preserved field bytes from the frozen manifest without a second replay copy or stored request body. |
| Continuity never degrades silently | Missing, corrupt, unsupported, or incompatible replay material prevents dispatch with `continuation_unavailable`; no path drops private reasoning or reconstructs from visible Conversation alone. |
| Unknown output fails closed | Preserve unknown open fields inside known records. Preserve a bounded typed rejection and producing-request/causal provenance for an unknown consequential union variant, resolve it as `unsupported_provider_output`, and publish no Conversation, continuation, or effect consequence. |

The accepted append-only context direction additionally requires successive-request fixtures: retain a response with opaque continuation, change Session instructions, and prove the next request appends the update without rewriting the earlier prefix. Preserve that position and rendering across restart and retries. Cover an update while tool results are pending, two updates before first inclusion, and supported compaction across an applied update. System Instruction is selected as a distinct Conversation Entry kind. Required history fixtures distinguish it from user messages and tool results, preserve exact ordering/content on replay, and ensure provider output cannot manufacture operator authority. First inclusion commits atomically with its assistant-response request; exact storage/wire encoding remains implementation work. These are required checks, not passing evidence.

Execute the [instruction-update examples](docs/design/instruction-update-history.md#required-examples) against production storage and advancement. A → B → C includes B then C, and A → B → A includes B then the second A even when no request used B alone. A fresh explicit A → A creates an update; matching request-key replay and patches omitting instructions create none. Reusing identical content bytes cannot collapse distinct update identities. Cover atomic entries/projections/Operation/manifest rollback, lost acknowledgement before dispatch, mode-only updates, pending tools, updates arriving during compaction, previously included updates covered by a base, and predicted versus admitted overflow. Retries reuse their frozen manifest; pending updates remain for the next fresh assistant-response request, without duplicate inclusion or claims of provider consumption. These new scenarios are required evidence, not completed checks.

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

The fixture restarts between each revision and verifies exact content references and manifest digests. Include multiple requests within one Turn, multiple settings updates before request construction (the latest configuration is selected while every explicit instruction update is preserved in history), changes after manifest commit but before dispatch, and failed preparation followed by later settings changes. Configuration alone must create no model work. These are required scenarios, not completed runtime evidence.

## Model output and tools

One model response fixture emits assistant text plus three Tool Calls. Admission must:

1. validate the complete ordered candidate before mutation;
2. commit every Tool Call and child Action Operation atomically;
3. reject the complete candidate for a duplicate call identity, unknown Tool Key, malformed arguments, or invalid member;
4. execute children independently under Active Capacity with no Workspace fence or isolation claim;
5. survive independent permission, denial, failure, cancellation, and uncertain-effect outcomes; and
6. construct the next Model Request Manifest with every Tool Result in original call order regardless of completion order.

Permute physical completion order and prove that Conversation, the next model request, Turn Output, and Workflow topology remain identical.

Tool visibility and execution authority remain separate. Arbitrary provider-neutral Tool Keys round-trip as data, but only admitted `bash` and `edit` bindings execute. Permission Decisions bind exact Principal, request, Operation, descriptor digest, and decision.

## Operations, Attempts, and recovery

Read [Operations, Attempts, and recovery](docs/verification/execution.md#operations-attempts-and-recovery) for this contract and its required evidence.

## Local diagnostics

Verify that default diagnostic summaries persist across ordinary restart, correlate failures with the affected execution, and remain within the configurable 128 MiB default history cap as the oldest records are replaced. Exercise a smaller test cap through the same path; verify ordinary restart preserves retained history and the allowance, and low traffic causes no separate age-based expiry. Delete or expire diagnostics, lose an unwritten crash tail and inject diagnostic-write failure: effect-specific recovery, accepted results, permission decisions, consumed allowance and retry eligibility must remain unchanged. Canonical storage failures retain their existing failure behavior; this is not authority to ignore a failed semantic write.

Verify explicit bounded detailed capture and user-controlled export of recent diagnostics without automatic upload. Default summaries and exports exclude credentials; generic content reads continue to exclude private provider continuation. Capture and export use bounded memory and storage. Unsupported rejected provider output preserves a typed rejection and necessary producing-request/causal provenance without requiring permanent raw payloads; removing its diagnostic bytes cannot introduce Conversation, continuation or effect consequences. Accepted replayable output still preserves its required bytes, ordering, unknown fields and provenance independently of diagnostic capture. Missing raw diagnostic bytes are an investigation limitation, not a promise of reproducibility or complete crash history.

At fixed active concurrency, vary failed-try count and retained diagnostic bytes through quota and rotation; exercise explicit large-payload capture and export. Verify no resident-memory slope with historical tries or total diagnostic payload size. Report whole-process RSS, diagnostic workspace high-water, SQLite heap/cache/spill, filesystem-cache/writeback pressure, disk usage and command/settlement latency alongside the existing density and churn checks. A fixed disk quota is not a resident-memory budget; measure actual integration before claiming an improvement.

Verify at most 16 size-rotated files, including the active file, with per-file maximum floor(cap / 16), encoded-byte accounting and deletion before growth. Test exact boundaries, a 4 KiB record, worst-case escaping, optional-text omission, rejected too-small configuration, partial writes, incomplete crash tails and deletion failure without quota overrun or a memory queue. Verify detail shares the cap and missing chunks mark incomplete captures. During slow export, rotate source files and verify bounded copy turns release source handles, gaps are reported, copies count in scratch and scratch-full exports fail explicitly. Restart with a smaller cap must prune before growth or disable growth on failure. These are selected requirements, not passing production evidence.

## User Messages and permission

Fixtures prove:

- caller-provided Session keys and first complete configuration committing baseline plus core request answer without model work; incomplete initialization and messages to unknown keys save definite rejection without partial Session state;
- direct and workflow configuration/messages using the same request identity contract, with separate workflow answer recording; lost replies recover the original acceptance or rejection before checking current state again;
- initiating admission atomically creates the User Message and its Conversation Entry;
- later User Message admission creates an immutable `user_messages` row without a Conversation Entry or change to an already-admitted Model Request Manifest;
- the next assistant-response model-Operation admission transaction projects every applicable unprojected message in admission order and freezes the manifest, while an intervening compaction model Operation uses only already-applied context and leaves them pending;
- both SQLite commit orders around assistant-only settlement produce the documented result: message-first retains ordinary assistant text and requires a later model Operation; settlement-first commits Final Answer and prevents attachment to that Turn;
- a sealed User Message source and its first semantic reference become authoritative together, with exact length and digest verification and no payload-sized resident allocation;
- one Permission Decision binds the exact Principal, request, Operation, descriptor digest, and decision;
- identical Permission Decision replay is idempotent, while a conflicting, stale, inapplicable, unknown, or unauthorized decision fails without mutation;
- First Session configuration defaults Permission Mode to `ask`; only explicit Local Owner configuration selects `bypass`, and configuration replay does not reapply an old mode;
- child Action admission atomically binds the current mode and sparse configuration provenance with the exact descriptor and either an immutable Permission Request or bypass Authorization;
- ask-to-bypass leaves an existing request pending, while newly admitted actions use bypass; bypass-to-ask leaves an already-authorized but not-yet-started action authorized, while newly admitted actions require decisions;
- mode changes during an in-flight model request affect later Action admissions without changing that model request or already-admitted actions; siblings admitted in one transaction select the same configuration view;
- both commit orders of configuration versus Action admission, rollback before admission, lost acknowledgement, crash/reopen, and configuration replay preserve the selected permission facts without retargeting or duplicate requests/Authorizations;
- running actions are not interrupted by configuration; ordinary stops and cancellation still prevent inapplicable permission decisions or Attempts;
- a generic response batch and conversational Input Request do not exist;
- a terminal Turn has no applicable User Message or actionable Permission Request;
- definitive failure may commit with still-unprojected User Messages only after all other semantic obligations are resolved; the failed Outcome itself makes them inapplicable and releases logical Session occupancy atomically;
- pre-request `ResourceExceeded` creates no fake Operation, manifest, Attempt, or message projection; Operation-derived terminal failure instead references the same Turn's accepted Resolution;
- ordinary Tool errors, retryable model failures, recoverable overflow, and direct interruption do not independently authorize Turn failure;
- both failure/admission commit orders preserve intent: message-first retains not-applied input on the old Turn; Session-current admission after failure begins new work, while an exact stale Turn target rejects;
- excluded input stays readable with its causal reason but never enters a later request without a new explicit admission; existing projections are not relabeled as proof of provider consumption;
- rollback/storage failure claims no committed outcome or occupancy release, while reopen after lost acknowledgment recovers the one immutable outcome without another provider call;
- unresolved Operations, effects, permissions, and required Tool Result publication block failure settlement; late evidence cannot overwrite accepted Resolution/Outcome facts;
- failure disposition derives from existing rows without a new failure-intent table, message phase, withdrawal record, or resident queue.

`permission_required` appears in a Run Snapshot only when at least one Permission Request is actionable and no other member Turn can progress.

## Bash timeout policy

Read [Bash timeout policy](docs/verification/execution.md#bash-timeout-policy) for this contract and its required evidence.

## Model retry and inactivity policy

Read [Model retry and inactivity policy](docs/verification/execution.md#model-retry-and-inactivity-policy) for this contract and its required evidence.

## Runtime information and limit ownership

The [Turn Contract removal trace](docs/design/turn-contract-removal.md) requires:

- no separate contract row or generic runtime-facts snapshot at Turn admission;
- a changed clock or filesystem after request admission leaving that request's instruction content/rendering inputs and replacement Attempts unchanged;
- later supplied instruction changes using the existing append-only first-inclusion path, with no automatic refresh policy implied;
- Session Workspace identity, admitted Action descriptors, and earlier Tool Results retaining their original meaning after external Workspace changes;
- Host resource admission on restart respecting current capacities without rewriting admitted model/Action inputs;
- no aggregate Turn model-request count limit or whole-Turn deadline; permission/capacity waiting and Host downtime cannot expire work through such a limit;
- pre-request failure retaining selected configuration/input provenance in the existing outcome, without a fake request or Turn Contract; and
- compaction and workflow replay recovering their respective request and evaluator bindings without the removed grouping.

These are production verification obligations. Removing the grouping does not select limits or bypass #89's pre-implementation gate.

## Workflow replay

Read [Workflow replay](docs/verification/workflows.md#workflow-replay) for this contract and its required evidence.

## Run interface

Read [Run interface](docs/verification/workflows.md#run-interface) for this contract and its required evidence.

## Server lifecycle and local command boundary

Use production Unix-socket HTTP and fresh server/client processes to verify:

- simultaneous server starts, supported equivalent Store paths, and distinct Stores yield one live owner per Store; unsupported aliases reject rather than split authority;
- missing server, wrong Store/version, inaccessible peer, long socket path, stale socket, unexpected file at the endpoint, and restart races never cause client auto-start, client SQLite access, or blind unlink;
- disconnecting every client leaves eligible work advancing; a later client observes it without treating live Attempts as abandoned;
- server stop/crash before and after admission, dispatch, scratch seal, and commit preserves exact request bindings and remaining retry allowances on explicit restart; uncertain Bash and Edit are not replayed, require no target inspection, and preserve an indeterminate Tool Result;
- stop with an active model stream, Bash, Edit, and delayed retry fences dispatch promptly, retains safe cleanup, and fabricates no semantic cancellation/interruption merely because transport closes;
- direct and workflow same-key retries recover the original committed acceptance/rejection after lost acknowledgement, terminality and restart; changed inputs conflict and an originally rejected request cannot become accepted merely because conditions changed;
- Session waits select work once; later Session reuse cannot extend the wait indefinitely or substitute a newer result for a workflow's recorded answer;
- recent/kind/after history reads and separate unapplied-input reads preserve exact content and reasons without loading all history on every inspection;
- truncated/slow uploads publish no content or semantic reference; malformed headers, version failures, incomplete report framing, slow readers, saturation, and connection churn produce typed failure or bounded pressure without hidden resident populations;
- one request/response per connection bounds retained uploads/reports, rejects pipelined work, and leaves no idle keep-alive population; ordinary-transfer saturation preserves classification and short-control headroom within the total connection bound;
- Session stop, Run cancellation, exact Model Interruption and Permission Decision admission each retain bounded protected access under ordinary-transfer saturation; completion waits and large reports cannot consume that headroom, and successful control acknowledgement still follows semantic commit rather than implying physical cleanup;
- header byte and total-time bounds reject oversized or trickled incomplete headers; upload/download inactivity releases stalled connections and scratch, while healthy slow transfers and Host processing/backpressure are not misclassified as client inactivity; include stalled control-response readers, concurrent controls, connection churn, and commit followed by timeout with matching configuration/message retry recovering the saved answer rather than repeating the mutation;
- public operations use exact domain targets, with no per-client ACL, generic command journal, public scheduling requirement, or independent content upload lifecycle; and
- stdout contains only the selected data format, stderr carries diagnostics, and delivered workflow failure is a valid zero-exit protocol result while invocation/access/infrastructure/rendering failure is nonzero.

Qualify the accepted initial defaults: 128 total connections, at most 120 ordinary with 8 places for classification/short controls; 16 KiB combined request line/headers; 8 KiB short-control bodies and acknowledgement/error responses; 10 seconds total header completion and 60 seconds client transfer inactivity. Compiled wire fixtures must fit every supported short control, including valid maximum identifiers/decisions and bounded errors; amend an incompatible bound explicitly rather than truncate semantic data. Verify oversized rejection before mutation, timeout attribution under Host contention, concurrent controls, stalled acknowledgement readers, and independent connection/scratch saturation. These are policy choices, not measured traffic needs or passing release evidence. Validate configuration at startup; configuration changes take effect on restart.

## Shared syntax and representation

Verify each field at its actual consumer: SQLite INTEGER boundaries and checked overflow without imposing that range on differently represented opaque IDs; exact 32-byte SHA-256 values and rejection of invalid textual decoding; OS path and derived Unix socket boundaries including terminators/suffixes; embedded-NUL rejection and ordinary permitted Edit paths. Keep authorized target and Store-ownership checks independent of path length. Golden wire fixtures own public identifier spellings.

For names, media/schema types and diagnostics, distinguish unsupported semantic values from invalid encoding and resource exhaustion. Qualify replacements for historical fixed arrays using values beyond the old capacities where the supported provider/consumer and owning resources permit. Do not fabricate provider support to satisfy a size fixture. Cover safe JSON/header/rendering reuse, complete rejection before semantic mutation, and no truncation. Existing buffer checks may be removed only with verified bounded replacement handling; document remaining aggregate workspace requirements under their Host/SQLite owners.

## Provider and evaluator integration

Provider fixtures cover post-commit request-materialization failure, provably-not-started and may-have-started dispatch, auth refresh/account continuity, DNS/TLS, arbitrary SSE fragmentation, terminal provider records, disconnect, cancellation, delayed retry, long-lived concurrency, deterministic incompatibility, and storage failure. Resume uses the persisted provider binding rather than silently attaching a fixture. Only opt-in live checks contact the provider; deterministic equivalents traverse the same production owners.

OAuth syntax fixtures round-trip every JSON-required control byte and exact legal boundaries through device polling and stored credentials. Prove worst-case escaping capacity, reject missing/extra/empty compact-token segments, reject unsafe token/account header bytes at construction and libcurl reuse, and preserve exact account binding on refresh. Exercise account values beyond the historical 128-byte buffer and tokens beyond the historical 16 KiB buffer when actual authentication resources permit; preserve exact account binding without UUID grammar or normalization. Test resource exhaustion separately from invalid syntax, with no truncation or credential leakage. The historical source findings in the [cleanup record](docs/design/planning-cleanup-2026-09-05.md) are not passing evidence.

### Evaluator lifecycle

Evaluator lifecycle checks prove descriptor isolation through construction and close-on-exec with three stdio pipes, only the selected read-only completed-input descriptors and an empty environment, no JavaScript-visible descriptor capabilities, and disabled core dumps. Verify writable input handles are closed before spawn, the child cannot open paths or access SQLite, and native positional reads stay confined to the inherited snapshot handles. Verify no numeric `RLIMIT_NOFILE` scan and no whole-capacity exit-time overwrite/free of process-lifetime input/output/bridge mappings. Compare at least five real evaluator invocations at the default descriptor limit and at `ulimit -n 256`, reporting median wall time and maximum RSS; there must be no latency proportional to the numeric descriptor ceiling. Run the existing workflow and canonical gates. The containment decision still owns the limits; archived timings do not certify the eventual implementation.

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
- exactly one canonical replacement output owned by the accepted compaction Operation, with no Compaction Checkpoint relation or semantic-handoff alternative;
- Core structural replay validation and adapter-owned provider compatibility composed from immutable source and target facts rather than a persisted validity flag;
- complete total ordered suffix replay through accepted model Resolutions and canonical host inputs, including opaque reasoning and known extension fields;
- unknown consequential union variants retained as evidence but rejected as `unsupported_provider_output` before continuation publication;
- explicit `continuation_unavailable` for missing or incompatible replay material, including unsupported model or replay-format changes demonstrated by adapter fixtures;
- rejection or deferral of incompatible context change without provider dispatch;
- provider overflow resolving the old model Operation, followed by compaction and a new model Operation rather than a changed-manifest Attempt;
- Session Context Revision, exact instruction/rendering inputs, Model Request Manifest, complete covered frontier, lineage, and model provenance derived through the Compaction Base's creating model Operation, without a Turn Contract;
- newest accepted base selection before compatibility validation, with failed or unresolved compaction unable to displace it and missing, corrupt, unsupported, or incompatible selected material unable to trigger an older-base search; and
- `ResourceExceeded` after the allowed valid Attempts cannot produce a fitting request.

### Model-result settlement and spillover

Model-result settlement tests prove that one transaction publishes immutable Operation-owned Model Output Items, that Operation's final Resolution value with producing-request/execution provenance, and every applicable Conversation projection without a duplicate replay object. Adapter tests derive replay inputs by removing response-only fields while retaining exact provider-only continuation bytes. Raw scratch is deleted after canonical import. Partial, interrupted, failed, cancelled, and late streams publish no continuation input. Large tool output produces a Spillover Tool Result with the original command outcome, bounded excerpt, omission notice and temporary-output reference; it does not fail solely for exceeding the inline excerpt size or ask the Agent to rerun merely to reduce output. Verify the default tail excerpt includes no more than 10,000 UTF-8 bytes of rendered output text across the entire Tool Result, without an independent line-count quota. Cover output below, at and above the bound, a single long line, multibyte characters at the cut, and combined stdout/stderr allowance. Short output remains complete; command status and bounded omission/reference metadata remain present. Full tool output has no per-call capture-size ceiling; OnePage-produced bytes count through active capture and retained-name ownership. External mutation or post-removal external retention is outside the published-spillover allowance. Verify selected-output retrieval through an ordinary absolute path and the existing Bash tool using grep, tail and sed, without a new read tool or inserting the entire file into Model Context. Apply ordinary Bash permissions, timeout and excerpt rules. Cover removal before open, a reader overlapping FIFO cleanup, attempted mutation/growth through the exposed path, and Host-exit/restart cleanup. Prove the [scoped temporary accounting](docs/verification/resources.md#memory-and-density), bounded Host metadata/handles and that the Host never reuses a saved path for other output. External path changes are ordinary filesystem behavior, not authenticated spillover reads. Explicit unavailability after lost spillover must leave the saved result unchanged and never automatically replay the old command. A fresh model-requested call uses ordinary authorization. Storage exhaustion remains explicit failure; required recovery evidence is never discarded as spillover.

## Memory and density

Read [Memory and density](docs/verification/resources.md#memory-and-density) for this contract and its required evidence.

## Native Edit verification

Read [Native Edit verification](docs/verification/execution.md#native-edit-verification) for this contract and its required evidence.

## Accepted Host qualification targets

Read [Accepted Host qualification targets](docs/verification/resources.md#accepted-host-qualification-targets) for this contract and its required evidence.

## Limit replacement verification

Read [Limit replacement verification](docs/verification/resources.md#limit-replacement-verification) for this contract and its required evidence.

## Release evidence and residual audit

Package the demonstrations specified in PRODUCT.md through production interfaces, with exact expected observations and checked-in measurements/calculations. Finalize the project name before packaging so examples and later audits use the same identity. Demonstrate explicit server start, no-client progress, server interruption and restart, keyed fan-out/fan-in, direct Session use, caller-owned references with first-configuration initialization, Run inspection exposing full Session keys for direct cross-Run reuse, multiple ordered tool calls, uncertain Bash/Edit without automatic inspection, and shared-Session cancellation. Do not retain historical exact-Turn public examples or fixture-only state machines as the V1 experience.

After integration, audit only residual gaps in domain authority, context/request/compaction integrity, workflow replay, permission/cancellation, SQLite schema identity and atomic content/reference publication, corruption/I/O behavior, endpoint ownership, and external-effect uncertainty. Each invariant names its owning table/constraint/transaction and a relevant recovery fixture. Canonical content and its first reference commit together, leaving no V1 orphan-cleanup requirement. Rely on SQLite's guarantees directly; do not recreate a generic ledger audit or duplicate an already-proven fault campaign. Unsupported platform behavior is a release blocker, not a reason for hidden fallback.

Compiler-backed declaration discovery covers the final ReleaseSafe and ReleaseSmall production graphs. Classify test-only, fixture-only, conditional, and intentionally unused declarations; prove obsolete Job, Step, ledger/reducer, terminal-Session, duplicate schema, and compatibility APIs are removed rather than merely unreachable. Public types must agree across the native API, Unix-socket HTTP adapter, and CLI rendering. No declaration exists solely for an unselected future provider, protocol, workflow engine, or migration.

## Canonical gates

`zig build check` is the local and CI gate: source formatting/validation, native ReleaseSafe tests and ReleaseSmall deliverables. Evaluator, private evaluator protocol, QuickJS dependency or evaluator build-graph changes also run `zig build workflow-check`. Dependency, build, persisted-format and CI-bootstrap changes additionally run the canonical gate from a clean empty cache. Confirm definitions in `build.zig`.

Before V1 release:

- deterministic model, Bash, Edit, User Message, permission, multi-tool, context-revision, compaction, workflow, and Run fixtures pass;
- hard-termination fixtures pass from fresh processes at every distinct acknowledgement and external-effect boundary;
- ReleaseSafe tests and ReleaseSmall build pass;
- evaluator protocol, JavaScript conversion, sanitizer, mutation/property, and leak gates pass on their supported platforms;
- compiler-backed declaration discovery reaches the completed source graph;
- `git diff --check` passes; and
- the opt-in Codex repair completes through the same Model Request Manifest, Operation, tool, permission, and Turn paths used by deterministic fixtures.

## Transactional operation boundaries

Read [Transactional operation boundaries](docs/verification/execution.md#transactional-operation-boundaries) for semantic admission, dispatch and recovery evidence without a required classifier/interpreter layer.

## Fixed execution tracking

Read [Fixed execution tracking](docs/verification/resources.md#fixed-execution-tracking) for startup-sized neutral records and safe reuse.

## Oldest-eligible admission

Read [Oldest-eligible admission](docs/verification/resources.md#oldest-eligible-admission) for selection evidence and recovery constraints.

## Control-loop waiting

Read [Control-loop waiting](docs/verification/resources.md#control-loop-waiting) for event/deadline coverage and idle measurements.

## Shared identity and workflow submission

Read [Shared identity and workflow submission](docs/verification/workflows.md#shared-identity-and-workflow-submission) for independent core/workflow transactions, lost replies and cancellation.

## Workflow Runtime and private evaluation

Read [Workflow Runtime and private evaluation](docs/verification/workflows.md#workflow-runtime-and-private-evaluation) for the public lifecycle, private compute boundary and inspection-based Session reuse.
