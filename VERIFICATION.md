# OnePage verification contract

This document defines evidence required for V1 claims. Tests use production interfaces and fresh-process reopen. An interrupted suite is reported as interrupted, not green.

## Domain authority

| Claim | Required evidence |
| --- | --- |
| SQLite is sole authority | Recreate every Decision Snapshot and Run Snapshot from canonical relational rows with no Session Ledger, reducer image, continuation blob, or resident cache. |
| Session is linear and reusable | Complete two Turns in one Session, prove immutable ordered Conversation entries, and reject branching, stale revision, and a concurrent second Turn. |
| Turns settle; Sessions do not | Completion, failure, and cancellation fixtures commit one Turn Outcome and release Session occupancy atomically. Failure-code and Operation-uncertainty fixtures remain orthogonal to terminality. Releasing transient Host resources changes no Session or Turn meaning. |
| Conditions are derived | Rebuild the exact Turn partition—runnable, waiting for input, in flight, completed, failed, and cancelled—plus Session dormancy and Run `input_required` from relational rows after dropping every rebuildable index. Prove immutable future retry eligibility derives in flight without a live effect. |
| Causality is explicit | Every Conversation entry, Operation, Attempt, Completion, Resolution, Interaction Request, and output resolves to its exact Turn and causal parent without relying on insertion order alone. |
| Pre-V1 is a flag day | Schema tests reject obsolete ledger/reducer formats; no compatibility reader, alias, migration, or dual-write path exists. |

## Context and model requests

| Claim | Required evidence |
| --- | --- |
| Context revisions are sparse | Create a Session and its complete baseline atomically, reject a Session without one, change one component, and prove every unchanged component resolves to its earlier immutable reference. |
| Revisions are atomic | Start a Turn with an authorized Session Context Patch changing model and Tool Catalog; interruption exposes the revision, Turn, Contract, and initiating entry together or none. Reject independent and mid-Turn mutation. |
| Turn Contract is immutable | Resolve Session defaults, explicit overrides, date, timezone, Workspace facts, authority, and output requirements once; later ambient changes do not alter the admitted Turn. |
| Model request is exact | Persist one Model Request Manifest for each model Operation and reconstruct the same provider-neutral request after fresh-process reopen. |
| Retry does not drift | Replacement Attempts reuse the same manifest while credentials and transport are refreshed independently. A changed component requires a new model Operation. |
| Historical requests remain explainable | After changing model, instructions, tools, or renderer code, reconstruct each earlier Operation from its manifest and content references. |
| Provider cache is optional | Disable or lose provider-side conversation/cache identity and produce the same semantic request from local authority. |

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

Tool visibility and execution authority remain separate. Arbitrary provider-neutral Tool Keys round-trip as data, but only admitted `bash` and `apply_patch` bindings execute. Permission responses bind exact Principal, request, Operation, descriptor digest, and option.

## Operations, Attempts, and recovery

| Boundary | Required fresh-process result |
| --- | --- |
| Before Attempt commit | No external dispatch authority exists. |
| After Attempt commit, before dispatch | Recovery treats dispatch according to the Operation's conservative uncertainty contract. |
| During provider/tool execution | No SQLite transaction, payload-sized resident buffer, reducer image, or notification is required to rediscover admitted work. |
| After scratch seal, before normal settlement | Scratch is non-authoritative; process death loses it and leaves the Attempt unresolved for effect-specific recovery. |
| Normal settlement | Immutable content, the single Attempt Completion, Operation Resolution, Conversation or interaction facts, and the next semantic consequence commit together or not at all. |
| Retryable model settlement | Completion and immutable retry eligibility commit together while the Operation remains unresolved and owns no waiting memory or timer. |
| After Resolution, before acknowledgement | Replay returns the committed result without another transition. |

Model recovery records possible duplicate work or billing and reuses the exact manifest. Bash recovery never redispatches uncertain work. Patch recovery distinguishes preimage, expected postimage, divergence, and invalid target. Each Attempt admits at most one Completion: exact replay is idempotent and conflicting evidence is rejected without mutation. Cancellation intent and transport shutdown cannot race to create competing Completions; only the effect-specific terminal owner proposes evidence.

Streaming fixtures prove that the I/O Reactor writes provider and Bash bytes directly to dynamically charged, immediately unlinked scratch through fixed borrowed windows. No per-Attempt candidate, parser, request, response, or output buffer scales with Active Capacity. Complete model output is parsed once after terminal seal in the shared serial validation/import workspace. Post-commit request-materialization failure becomes evidence for the admitted Attempt.

Storage failure injection covers full, I/O, allocation, corrupt content, foreign reference, wrong digest, and transaction rollback. SQLite faults expose neither half a semantic relation nor content without its first reference.

## Interaction and conversational continuation

Fixtures prove:

- ordinary User input admitted to an idle Session starts a new Turn;
- ordinary uncorrelated input conflicts while a Turn is nonterminal;
- a model input request atomically appends its assistant prompt and creates one immutable Interaction Request;
- an identical response replay is idempotent;
- a conflicting, stale, withdrawn, unknown, or unauthorized response fails without mutation;
- an accepted correlated response appends User text and resumes the same Turn;
- permission text cannot substitute for a typed permission response; and
- a terminal Turn has no open Interaction Request or applicable response.

`input_required` appears in a Run Snapshot only when at least one request is open and no other member Turn can progress.

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

Two workflow calls in one Workspace prove that independent Bash Operations may progress concurrently, completions settle without sibling head-of-line blocking, and filesystem interference is reported as observed evidence rather than prevented by a Host fence. Separate fixtures prove the private Patch lane is serial without turning that implementation choice into a Workspace invariant.

## Run interface

Golden and hostile-input tests implement both checked-in JSON schemas exactly. JSON contains the complete versioned Run Snapshot; Markdown consumes the same semantic value and introduces no facts.

Tests cover:

- create/attach conflict by exact binding;
- pure inspection;
- atomic response batches;
- explicit cancellation;
- atomic Run cancellation propagation to every nonterminal member Turn and no Session finality;
- concurrent advancement attempts classified from the same bounded committed facts without a resident driver lease;
- retry-delayed unresolved model Operations remain `in_flight`, own no Active Credit, and become eligible through the bounded SQLite poll;
- immutable content range reads;
- JavaScript-safe string encoding of opaque integer-class values;
- complete visibility of every actionable open request;
- Run–Turn membership summaries that keep Agent Call Key separate from Turn identity and partition members into the exact derived conditions/outcomes;
- stable pagination over immutable or revision-bound records;
- untrusted model/tool text isolated from control framing; and
- SIGINT, timeout, terminal closure, and output failure detaching without cancellation.

## Compaction

Compaction tests preserve every source Conversation byte while selecting one replacement checkpoint plus the largest complete compatible suffix. They cover:

- exact next-request-plus-reserved-output pressure;
- intact Tool Call/Tool Result boundaries;
- source change during summarization;
- invalid, empty, oversized, stale, corrupt, and incomplete checkpoints;
- prior-checkpoint lineage;
- acknowledgement loss after checkpoint commit;
- repeated compaction;
- Session Context Revision, Turn Contract, Model Request Manifest, and model provenance derived through the checkpoint's creating model Operation;
- fallback to older valid checkpoint or uncompacted history; and
- `ResourceExceeded` after the allowed valid Attempts cannot produce a fitting request.

## Memory and density

Measurements report whole-process RSS and each independent axis:

- Dormant Session count;
- terminal and nonterminal Turn count;
- Active Capacity and occupied Active Credits;
- Storage Owner, I/O Reactor, and Patch-lane incremental and retained-idle cost;
- the one content-free Physical Custody table's record size and occupancy, where each occupied record is one Active Credit;
- transport-library threads, stacks, fixed windows, sockets, and resolver resources;
- subprocess trees and model-requested workload memory;
- shared serial validation/import workspace high-water;
- SQLite heap, database bytes, journal bytes, and writes;
- Workflow Evaluator heap, bridge memory, process RSS, and replay count;
- immutable content, unlinked-scratch logical and physical bytes, filesystem-cache pressure, and raw-plus-canonical overlap.

Required population points are 0, 100, 1,000, and 10,000 Dormant Sessions at fixed capacity, then Active Capacity 1, 10, and 100 at fixed durable population. Repeated 0→capacity→0 churn must return resident orchestration memory to the same bounded envelope. Terminal Turn population adds durable bytes rather than resident execution objects.

Every new allocation topology records its owner, multiplier, maximum, ordinary occupancy, release boundary, failure behaviour, and reason an existing owner cannot serve it before implementation.

## Canonical gates

Before V1 release:

- deterministic model, Bash, patch, interaction, multi-tool, context-revision, compaction, workflow, and Run fixtures pass;
- hard-termination fixtures pass from fresh processes at every distinct acknowledgement and external-effect boundary;
- ReleaseSafe tests and ReleaseSmall build pass;
- evaluator protocol, JavaScript conversion, sanitizer, mutation/property, and leak gates pass on their supported platforms;
- compiler-backed declaration discovery reaches the completed source graph;
- `git diff --check` passes; and
- the opt-in Codex repair completes through the same Model Request Manifest, Operation, tool, permission, and Turn paths used by deterministic fixtures.
