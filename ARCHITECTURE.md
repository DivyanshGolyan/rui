# OnePage architecture

This document is normative. [`CONTEXT.md`](CONTEXT.md) defines the domain language; accepted ADRs explain hard-to-reverse decisions. Historical design, spike, and research documents are evidence, not authority.

## System shape

```text
Caller
  │
  ▼
local CLI ──► Run Service ──► Host Runtime ──► Host Store (SQLite)
                              │       │
                              │       └── Turns ──► Operations ──► Attempts
                              │
                              └── disposable Workflow Evaluator
```

One native Zig **Host Runtime** owns one **Host Store**, every live execution resource, and every disposable evaluator. The **Run Service** is the protocol-independent product boundary; the CLI only parses commands and renders committed snapshots. QuickJS evaluates Workflow Definitions but owns no Session, provider, tool, permission, recovery, or durable state.

A **Session** is one reusable linear Conversation in one Workspace and access scope. A **Turn** begins with one ordinary User input and advances that Session until Final Answer or a typed terminal outcome. At most one Turn is nonterminal in a Session. A **Workflow Run** maps each caller-defined Agent Call Key directly to one Turn; there is no intermediate Job domain.

## Simplicity rule

Each durable fact has one relational authority. Each resident byte has one current production consumer, one population multiplier, and one release boundary. Each interface owns one decision and hides its mechanics.

Use established mechanisms without transferring OnePage policy to them: SQLite owns transactions and journal recovery, Git owns patch parsing/application, libcurl owns bounded HTTP/TLS transport, and the OS credential store owns subscription credentials. OnePage retains model-visible context selection, operation admission, permissions, effect recovery, and Conversation meaning.

V1 has no generalized scheduler, provider registry, OAuth framework, runtime tool registry, plugin loader, durable JavaScript continuation, daemon, event bus, or wire-protocol adapter. A new abstraction requires a current second consumer or an invariant that cannot fit an existing deep module.

## Canonical relational authority

The Host Store is the sole recoverable OnePage-owned semantic and content store. OS-held credentials are non-semantic security material. Its canonical relationships are equivalent to:

```text
sessions
conversation_entries
session_context_revisions
session_context_changes
turns
turn_contracts
operations
model_request_manifests
attempts
attempt_completions
operation_resolutions
interaction_requests
interaction_resolutions
workflow_runs
run_turn_memberships
evaluation_generations
content
```

Names may change during implementation; the ownership boundaries may not.

SQLite constraints and transactions establish identity, parentage, uniqueness, occupancy, ordering, and settlement. OnePage does not persist a generic Session Ledger, reducer image, continuation blob, cached lifecycle phase, or shadow frontier beside these rows. A loaded Session, Turn, or Decision Snapshot is a bounded query result and never a second source of truth.

The Host Store atomically enforces:

- one linear Conversation per Session;
- at most one nonterminal Turn per Session;
- one terminal Turn Outcome;
- one Operation Resolution per Operation;
- exact Attempt identity and ordinal within an Operation;
- exact causal parentage between model Operations, Tool Calls, child Action Operations, and Tool Results;
- immutable Interaction Requests with at most one resolution;
- idempotent Run and Turn membership by exact canonical binding; and
- content publication together with its first durable reference.

Turn Condition, Session dormancy, Run `input_required`, runnable work, and observer summaries are derived from canonical rows. Persist a derived value only after measurement proves that an index is necessary; it remains rebuildable and non-authoritative.

V1 is a flag day. Unreleased databases and fixtures are recreated; no ledger-to-relational migration, compatibility reader, alias table, or dual-write path is permitted.

## Conversation and Turns

Conversation contains exactly four immutable V1 entry kinds: User text, assistant text, Tool Call, and Tool Result. Each entry records its Turn and exact causal source. Compaction never edits or deletes these entries.

Starting a Turn is one transaction, not an order of partially visible writes. It validates identity, exact expected Conversation Revision and Context Revision, Workspace, access scope, Principal authority, occupancy, and idempotent membership. For a new Session it creates the complete baseline Session Context Revision. For an existing idle Session, an optional closed Session Context Patch may atomically append one sparse revision. A command that supplies the same component as a persistent patch and Turn-local override conflicts. The transaction binds the Turn Contract to the resulting revision and creates the Turn and initiating User entry; all become visible together or none do. V1 has no independent context-mutation command or mid-Turn context change.

A correlated permission or input response resumes the exact nonterminal Turn. An unsolicited ordinary User message is accepted only when the Session has no nonterminal Turn and starts a new Turn. A Turn becomes terminal only when no open request, unresolved Operation, applicable Completion, or admitted effect can still change its outcome. Turn settlement and Session occupancy release commit atomically.

Accepted Conversation entries remain canonical after a failed or cancelled Turn. A Session never succeeds, fails, or closes.

## Sparse context and exact model requests

“System prompt” is not one mutable value. OnePage separates:

- persistent Session defaults;
- Turn-local policy and runtime facts;
- bounded Conversation projection; and
- exact model-Operation input.

A **Session Context Revision** atomically records only changed persistent components from this closed V1 set:

- model binding;
- Instruction Set;
- Tool Catalog;
- context policy;
- reasoning defaults; and
- default output limits.

Session creation and its first complete revision commit atomically. No Turn may be admitted without that baseline. Later revisions are sparse. Resolution selects the latest value of each component at or before the Turn's bound revision. Unchanged components keep their immutable content reference and digest.

```text
r1: model=A, instructions=I1, tools=T1
r2: tools=T2
r3: instructions=I2

resolve(r3) = model=A, instructions=I2, tools=T2
```

Date, timezone, current Workspace facts, explicit caller overrides, authority, and requested output schema are Turn-local facts. They enter the immutable **Turn Contract** without mutating future Session defaults.

Each model **Operation** binds one immutable **Model Request Manifest** containing provider-neutral references and digests for:

- exact model identity;
- rendered Instruction Set;
- Tool Catalog;
- Model Context or Compaction Checkpoint plus suffix;
- Turn-local runtime facts needed by the model;
- reasoning and output limits; and
- output contract.

Replacement Attempts reuse that manifest. Authentication, access tokens, sockets, HTTP headers, and transport buffers remain late-bound and are not canonical model input. A changed manifest requires a new model Operation.

The provider is logically stateless from OnePage's authority boundary. Provider caches, previous-response identifiers, and server-side optimizations may be used only when failure falls back to the same locally reconstructible manifest.

## Model output and multiple Tool Calls

One model Operation may resolve to a Final Answer, an input request, or an optional bounded assistant-text prefix accompanied by an ordered bounded set of Tool Calls. Final Answer has no Tool Calls. All model-visible output and child-call descriptors validate before atomic admission; an invalid member rejects the complete candidate. Successful admission appends the optional assistant-text entry followed by Tool Call entries in call-ordinal order in one transaction.

Each Tool Call creates one child Action Operation with `caused_by_operation_id` and a stable call ordinal. No Step or Tool Call Group is durable authority: the child set is derived from that parent relation.

```text
model Operation M1
├── call 0 ──► Bash Operation B1
├── call 1 ──► Patch Operation P1
└── call 2 ──► Bash Operation B2
```

Child Operations settle independently. Physical execution may be concurrent when capacities and Workspace fences permit. After every child resolves, one transaction appends their Tool Result Conversation Entries in original call-ordinal order. Only then may the next model Operation start. Physical completion order never chooses Conversation order. Denial, failure, cancellation, and uncertainty each produce typed model-visible Tool Results.

V1 may serialize same-Workspace Bash and patch execution without restricting the canonical model to one Tool Call.

## Operations and recovery

An **Operation** is one model request or admitted Action. An **Attempt** is one physical try. An **Attempt Completion** records bounded observed evidence. An **Operation Resolution** records what OnePage may safely do next. These distinctions are durable because an external effect may outlive its process owner.

Every authoritative transition follows:

```text
prepare ──► SQLite commit ──► infallible publication or fresh reconstruction
```

Attempt admission commits before physical dispatch. The command that commits a new Attempt receives one volatile Dispatch Permit; reconstructing an admitted Attempt never recreates that permit.

Recovery is effect-specific:

| Operation | Uncertain Attempt |
| --- | --- |
| Model | A policy-authorized replacement Attempt may reuse the same Model Request Manifest while recording possible duplicate work or billing. |
| Bash | Never replay automatically. Resolve as indeterminate and show the evidence to the Agent. |
| Patch | Reconcile the durable Patch Intent against preimage, expected postimage, divergence, or invalid target. |

SQLite owns transaction atomicity and recovery. OnePage owns semantic validation, external-effect uncertainty, and causal admission. It does not reimplement the pager or distrust the configured local machine without evidence.

## Tools and permission

The provider-neutral Tool Catalog does not grant execution authority. V1 maps only `bash` and `apply_patch` Tool Keys to executable Actions. Each child Action Operation binds a typed descriptor before permission or dispatch.

`ask` creates an immutable permission Interaction Request for the exact validated descriptor. A response is accepted only from a Principal whose Authority covers the request, Operation identity, descriptor digest, and option. Explicit bypass creates Authorization for the same descriptor without a request. Both modes preserve validation, binding, Attempt admission, and recovery.

## Workflow Runs

A Workflow Run durably binds its Caller Run Key, Workflow Definition bytes, arguments, Workspace, semantics identity, evaluator limits, Evaluation Generations, Turn memberships, and terminal outcome.

Each `agent({ key, task, input, schema, model, reasoning_effort, session, session_context })` call produces one canonical Turn-membership specification. Required `task` is the initiating User instruction; optional `input` is bounded strict data rendered canonically into that same initiating User entry. Optional `session_context` carries the closed persistent patch described above. Equal `(run_id, key, digest)` reattaches to the same Turn. Reusing a key with different bindings conflicts. V1 permits at most one Run membership per Turn, so Run cancellation cannot affect another Run; the Turn's committed Conversation and outcome remain valid independently if the Run is later removed.

Each evaluator starts from source against one immutable Visibility Snapshot of terminal Turn Outputs and stable failures. It returns the complete blocked Turn set and exits. No JavaScript heap, Promise graph, continuation, bytecode, or completion callback survives a durable barrier. Workflow code cannot observe physical Turn completion order; V1 supports deterministic joins and excludes `Promise.race` and `Promise.any`.

Admitting Run Cancellation Intent atomically stops new evaluator generations and new Turn memberships and records Turn cancellation intent for every nonterminal member Turn. Later Turn evidence still reconciles under its own Operation rules. Cancelling a Run never makes a Session terminal.

## Run interface

The Run Service owns six semantic operations:

- idempotent creation or attachment;
- committed snapshot read;
- atomic typed response submission;
- durable cancellation request;
- fenced advancement; and
- immutable content read.

JSON is the complete versioned external contract. Markdown is a deterministic bounded rendering of the same Run Snapshot and introduces no facts. Process interruption detaches without cancellation; only the explicit cancellation command carries cancellation authority.

Every Run–Turn membership summary appears in exactly one category derived from committed Turn rows: `runnable`, `waiting_for_input`, `in_flight`, `completed`, `failed`, or `cancelled`. Derivation has an exact precedence: terminal Outcome wins; otherwise an unresolved admitted external Attempt is `in_flight`; otherwise an open request with no remaining progress is `waiting_for_input`; otherwise the nonterminal Turn is `runnable`. `input_required` is reserved for Run state. Membership and Turn creation are atomic, so no public `pending` state exists.

## Capacity and memory

One startup-fixed `active_capacity` bounds transferable Active Credits. A credit is owned by one admitted external Attempt or its immediate settlement handoff. An Activation Slot contains only bounded current decision data and no historical Conversation or speculative scratch.

A Dormant Session, terminal Turn, and Blocked Workflow Run retain no Harness, Slot, Active Credit, thread, socket, subprocess, evaluator, materialized Conversation, or context graph. In-flight work may retain the bounded transport or effect resource charged to its Active Credit.

Memory claims report whole-process RSS and the slope of each population separately: durable Sessions, terminal Turns, Active Capacity, provider transports, effect workers, SQLite, semantic-validation workspace, evaluator, and model-requested subprocesses. Workload memory is observed separately from OnePage-owned orchestration memory.

Every large value moves through explicit stages—wire/source, provisional decoded data, admitted semantic data, immutable content, and presentation window—with one owner and release boundary. A bound does not authorize a resident allocation of the same size.

## Compaction

Conversation remains complete. When the next exact request plus reserved output cannot fit the bound model context, OnePage may create a compaction model Operation under the active Turn. A committed Compaction Checkpoint binds only its source Conversation range, prior checkpoint lineage, replacement projection and digest, and creating model Operation ID. Turn Contract, Session Context Revision, Model Request Manifest, and model provenance derive through that Operation; provider transport identity remains Attempt evidence.

Later model requests use the newest compatible checkpoint plus the largest complete later suffix that fits. A missing, invalid, stale, or incomplete checkpoint falls back to an older valid checkpoint or uncompacted history. Compaction never creates a second Conversation or durable-history limit.

## Failure and future scope

Closed failures include stale identity, conflicting replay, invalid canonical data, capacity exhaustion, unsupported provider output, storage failure, and corrupt referenced content. Observer state and diagnostics cannot carry authority.

V1 excludes branching Conversations, edit/delete, queued steering, multi-host coordination, provider registries, dynamic tools, MCP execution, generalized scheduling, retained workflow VMs, and storage migration compatibility. A future conversation fork should create a new Session with explicit ancestry rather than turning every Session into a tree.
