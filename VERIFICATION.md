# OnePage verification contract

This document defines evidence required for V1 claims. Tests use production interfaces and fresh-process reopen. An interrupted suite is reported as interrupted, not green.

## Domain authority

| Claim | Required evidence |
| --- | --- |
| SQLite is sole authority | Recreate every Decision Snapshot and Run Snapshot from canonical relational rows with no Session Ledger, reducer image, continuation blob, or resident cache. |
| Session is linear and reusable | Complete two Turns in one Session, prove immutable ordered Conversation entries, and reject branching, stale revision, and a concurrent second Turn. |
| Turns settle; Sessions do not | Completion, failure, and cancellation fixtures commit one Turn Outcome and release Session occupancy atomically. Failure-code and Operation-uncertainty fixtures remain orthogonal to terminality. Releasing transient Host resources changes no Session or Turn meaning. |
| Conditions are derived | Rebuild the exact Turn partition—runnable, waiting for permission, in flight, completed, failed, and cancelled—plus Session dormancy and Run `permission_required` from relational rows after dropping every rebuildable index. Prove immutable future retry eligibility derives in flight without a live effect. |
| Causality is explicit | Every User Message, Conversation entry, Operation, Attempt, Completion, Resolution, Permission Request, Permission Decision, and output resolves to its exact Turn and causal parent without relying on insertion order alone. |
| Pre-V1 is a flag day | Schema tests reject obsolete ledger/reducer formats; no compatibility reader, alias, migration, or dual-write path exists. |

## Context and model requests

| Claim | Required evidence |
| --- | --- |
| Context revisions are sparse | Create a Session and its complete baseline atomically, reject a Session without one, change one component, and prove every unchanged component resolves to its earlier immutable reference. |
| Revisions are atomic | Start a Turn with an authorized compatible Session Context Patch changing instructions and Tool Catalog; interruption exposes the revision, Turn, Contract, initiating User Message, and Conversation Entry together or none. Separately reject a model change under the initial same-concrete-model rule, plus independent, mid-Turn, and other known-incompatible mutation, before any of those facts commit. |
| Turn Contract is immutable | Resolve Session defaults, explicit overrides, Permission Mode, date, timezone, Workspace facts, authority, and output requirements once; later ambient changes do not alter the admitted Turn. |
| Model request is exact | Persist one Model Request Manifest for each model Operation and reconstruct the same frozen request semantics after fresh-process reopen. |
| Retry does not drift | Replacement Attempts reuse the same manifest while credentials and transport are refreshed independently. A changed component requires a new model Operation. |
| Historical requests remain explainable | After changing ambient model, instructions, tools, or defaults, explain each earlier Operation from its frozen manifest and content references. |
| Provider cache is optional | Disable or lose provider-side conversation/cache identity and produce the same request from the locally retained replay recipe. |
| Provider continuation is lossless | Preserve completed ordered Model Output Items, including exact opaque or encrypted reasoning, signatures, compaction items, and extension fields, outside four-kind Conversation. After restart, derive the same replay-input meaning and exact preserved field bytes from the frozen manifest without a second replay copy or stored request body. |
| Continuity never degrades silently | Missing, corrupt, unsupported, or incompatible replay material prevents dispatch with `continuation_unavailable`; no path drops private reasoning or reconstructs from visible Conversation alone. |
| Unknown output fails closed | Preserve unknown open fields inside known records. Preserve an unknown consequential union variant as Completion evidence, resolve it as `unsupported_provider_output`, and publish no Conversation, continuation, or effect consequence. |

Required sparse-context fixture:

```text
r1: model=A, instructions=I1, tools=T1
r2: tools=T2
r3: instructions=I2

Turn 1 binds r1
Turn 2 binds r2
Turn 3 binds r3

Turn 3 resolves model=A, instructions=I2, tools=T2
```

The fixture restarts between each revision and verifies exact content references and manifest digests.

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
| Interrupted model settlement | Direct Model Interruption or Run Cancellation commits an `Interrupted` Operation Resolution without manufacturing a Completion. Its one-of provenance cites either the direct command's Principal/key or the Run Cancellation Intent. Recovery retries only missing-Completion Attempts whose Operations remain unresolved. If the physical launch boundary has not been crossed, the owner suppresses the unconsumed Dispatch Permit; otherwise it closes or detaches the local transport. Physical Custody persists through that cleanup without a second provider-cancellation request or acknowledgement wait, and partial or late provider output can enter neither Conversation nor a later request as continuation material. |
| After Resolution, before acknowledgement | Replay returns the committed result without another transition. |

Model recovery records possible duplicate work or billing and reuses the exact manifest. Bash recovery never redispatches uncertain work. Patch recovery distinguishes preimage, expected postimage, divergence, and invalid target. Each Attempt admits at most one Completion: exact replay is idempotent and conflicting evidence is rejected without mutation. Cancellation intent and transport shutdown cannot race to create competing Completions; only the effect-specific terminal owner proposes evidence.

The relational settlement matrix covers all combinations used by recovery. `Completion present / Resolution absent` is legal only for a retryable model Completion committed with future eligibility. Interruption during that delay inserts the `Interrupted` Resolution beside the earlier Completion; every due-work query joins through an unresolved Operation and therefore ignores the historical eligibility. `Completion absent / Interrupted Resolution present` is the deliberate live-model-abandonment exception above.

Streaming fixtures prove that the I/O Reactor writes provider and Bash bytes directly to dynamically charged, immediately unlinked scratch through fixed borrowed windows. No per-Attempt candidate, parser, request, response, or output buffer scales with Active Capacity. Complete model output is parsed once after terminal seal in the shared serial validation/import workspace. Post-commit request-materialization failure becomes evidence for the admitted Attempt.

Storage failure injection covers full, I/O, allocation, corrupt content, foreign reference, wrong digest, and transaction rollback. SQLite faults expose neither half a semantic relation nor content without its first reference.

## User Messages and permission

Fixtures prove:

- agent-call admission atomically creates or reattaches its Turn, membership, and initiating User Message;
- initiating admission atomically creates the User Message and its Conversation Entry;
- later User Message admission creates an immutable `user_messages` row without a Conversation Entry or change to an already-admitted Model Request Manifest;
- the next assistant-response model-Operation admission transaction projects every applicable unprojected message in admission order and freezes the manifest, while an intervening compaction model Operation uses only already-applied context and leaves them pending;
- both SQLite commit orders around assistant-only settlement produce the documented result: message-first retains ordinary assistant text and requires a later model Operation; settlement-first commits Final Answer and prevents attachment to that Turn;
- a sealed User Message source and its first semantic reference become authoritative together, with exact length and digest verification and no payload-sized resident allocation;
- one Permission Decision binds the exact Principal, request, Operation, descriptor digest, and decision;
- identical Permission Decision replay is idempotent, while a conflicting, stale, inapplicable, unknown, or unauthorized decision fails without mutation;
- Turn admission defaults Permission Mode to `ask`, rejects unauthorized `bypass`, and binds an authorized explicit mode immutably to the Turn Contract and Agent Call Key;
- in authorized bypass mode, child Action admission creates exact descriptor-bound Authorization with Turn Contract provenance and no Permission Request;
- a generic response batch and conversational Input Request do not exist; and
- a terminal Turn has no applicable User Message or actionable Permission Request.

`permission_required` appears in a Run Snapshot only when at least one Permission Request is actionable and no other member Turn can progress.

## Workflow replay

Workflow fixtures use the production QuickJS boundary and the exact `export default async function workflow({ agent }, args)` signature. They cover:

- idempotent Caller Run Key and stored invocation Workspace;
- canonical Agent Call Key and Turn specification;
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

Golden and hostile-input tests exercise the CLI's strict JSON adapter and the Host Runtime's typed Run API independently. Issue #39 must freeze the complete closed JSON contract in compiled public types and golden fixtures before any replacement format is accepted. Those fixtures pin every field, union tag, omission rule, and integer encoding; IDs, revisions, offsets, and other `u64`-class values are strings. Markdown consumes the same logical scan and introduces no facts. Neither encoding exists inside the native semantic boundary, and no handwritten schema duplicates the compiled contract.

Tests cover:

- create/attach conflict by exact binding;
- distinct typed agent-call and later-User-Message admissions creating the same canonical User Message kind;
- one Permission Decision per mutation and absence of a generic response batch;
- authorized and idempotent Run cancellation, including exact replay, changed-binding conflict, wrong Principal, and no whole-Run optimistic revision precondition;
- authorized and idempotent interruption of one exact unresolved Model Operation, including exact replay and rejection of changed binding, wrong Principal, Action target, resolved target, and terminal Turn without a whole-Run revision precondition;
- one Run Cancellation Intent relationally fencing new evaluation, membership, Operation, and Attempt admission through every SQL path without copied Turn intents or unbounded fan-out;
- first-commit-wins settlement when provider evidence and Run cancellation race, with late evidence unable to bypass the committed fence;
- at most one Run membership per Turn and no Session finality from Run cancellation;
- cancelled-Run membership deriving pending User Messages and Permission Requests as inapplicable without per-item withdrawal state;
- immediate Interrupted Resolution for an active model request while its bounded Physical Custody drains independently;
- both SQLite orderings of Attempt admission and cancellation, plus both physical launch-boundary orderings after Attempt commit: pre-launch suppression or post-launch cleanup without changing the SQLite winner;
- Run cancellation of a Model Operation with no Attempt, retry-delayed eligibility, an unconsumed Dispatch Permit, a live stream, and sealed but unsettled output;
- cancellation of an Action with no Attempt, Bash process-group interruption, Patch cancellation before mutation as not applied, and a started Patch finishing bounded execution and reconciliation;
- one typed Tool Result for every accepted cancelled Tool Call, preserved in call-ordinal Conversation order before the cancelled Turn Outcome;
- concurrent advancement attempts classified from the same bounded committed facts without a resident driver lease;
- retry-delayed unresolved model Operations remain `in_flight`, own no Active Credit, and become eligible through the bounded SQLite poll;
- one bounded drive quantum composing multiple separately atomic transitions, stopping at the documented conditions, and reporting whether immediate work remains;
- a resource-free snapshot continuation retaining no SQLite cursor, statement, transaction, lock, physical page, payload collection, or cleanup obligation;
- current-revision scan invalidation rather than historical snapshot reconstruction;
- abandoning a scan without cleanup and reaching EOF without a separate finish operation;
- immutable content range reads and sealed-source ingress through fixed windows;
- complete visibility of every actionable Permission Request and every other current logical collection member without logical caps, caller page sizes, or serialized continuation tokens;
- Run–Turn membership summaries that keep Agent Call Key separate from Turn identity and partition members into the exact derived conditions/outcomes;
- recursive workflow-visible values crossing the Run API as immutable typed content rather than native object trees;
- untrusted model/tool text isolated from control framing; and
- SIGINT, timeout, terminal closure, and output failure detaching without cancellation.

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
- Session Context Revision, Turn Contract, Model Request Manifest, complete covered frontier, lineage, and model provenance derived through the Compaction Base's creating model Operation;
- newest accepted base selection before compatibility validation, with failed or unresolved compaction unable to displace it and missing, corrupt, unsupported, or incompatible selected material unable to trigger an older-base search; and
- `ResourceExceeded` after the allowed valid Attempts cannot produce a fitting request.

Model-result settlement tests prove that one transaction publishes immutable Completion-owned Model Output Items, the selected Resolution, and every applicable Conversation projection without a duplicate replay object. Adapter tests derive replay inputs by removing response-only fields while retaining exact provider-only continuation bytes. Raw scratch is deleted after canonical import. Partial, interrupted, failed, cancelled, and late streams publish no continuation input. Oversized Tool output produces one small typed Tool Result that tells the Agent to retry more narrowly; any partial capture remains Completion evidence only.

## Memory and density

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

## Canonical gates

Before V1 release:

- deterministic model, Bash, patch, User Message, permission, multi-tool, context-revision, compaction, workflow, and Run fixtures pass;
- hard-termination fixtures pass from fresh processes at every distinct acknowledgement and external-effect boundary;
- ReleaseSafe tests and ReleaseSmall build pass;
- evaluator protocol, JavaScript conversion, sanitizer, mutation/property, and leak gates pass on their supported platforms;
- compiler-backed declaration discovery reaches the completed source graph;
- `git diff --check` passes; and
- the opt-in Codex repair completes through the same Model Request Manifest, Operation, tool, permission, and Turn paths used by deterministic fixtures.
