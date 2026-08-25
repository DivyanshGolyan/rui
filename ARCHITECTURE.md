# OnePage architecture

This document is normative. Historical spikes and research explain how the project reached this design; where they conflict, this document and accepted ADRs win.

## System shape

```text
durable world

immutable blobs and Conversation nodes
                    +
            per-Session WAL
       sole semantic lifecycle order
                    |
             WAL sequence S
                    v
       compact Core State checkpoint
              rebuildable view
                    |
                 activate
                    v
       exact 64 KiB Activation Slot
     decoded Core State + transient scratch
                    |
          semantic transition intent
                    v
       Harness: prepare -> commit -> publish
                    |
      model / Bash / apply_patch adapters
```

OnePage is single-host. The Workspace is external mutable truth. Local durable storage is authoritative for Session semantics but cannot reconstruct or overwrite arbitrary external Workspace changes.

## Durable authority

Each Session owns one append-only **Session WAL**. Its valid prefix is the sole order of semantic facts that create, advance, recover, cancel, or complete that Session. It includes task admission, accepted model and tool Operations, Attempts and their dispositions, Authorization, Results, Conversation advancement, reconciliation, cancellation, and Outcome.

One prepared semantic transition commits as one bounded WAL transaction frame. A frame contains every typed fact in that transition under one length, schema, sequence, and checksum. No enclosed fact is visible unless the complete frame validates; an incomplete or corrupt tail frame is discarded. Every validated frame boundary is therefore a legal recoverable semantic state, and one WAL sequence identifies the whole transition.

Large or variable content is immutable and stored outside the WAL. A publisher writes and synchronizes content before appending a WAL fact that references it. Failure before the WAL append may leave an unreferenced blob, which is garbage; a committed WAL record may never reference absent or unverified content.

The following are non-authoritative and may lag the WAL:

- encoded Core State checkpoints;
- runnable and waiting indexes;
- manifests and lookup accelerators;
- observer Projections;
- same-build activation caches, if later measurement justifies them.
- the durable Completion Inbox used to reconcile adapter evidence that has not yet entered the WAL.

They never advance semantic authority. Recovery rejects a checkpoint or index ahead of the valid WAL tail and replays records after a valid checkpoint's sequence. The implementation promises recovery from process termination and torn or incomplete application writes at named publication boundaries. Stronger operating-system crash and sudden-power-loss guarantees require separate evidence and must not be implied by process-crash tests.

Streaming deltas, terminal frames, diagnostics, scheduler polling, and raw payload bytes are not Session WAL facts. They are volatile projections, debug evidence, or immutable content.

## Conversation and Workspace

Conversation is the immutable parent-linked model-visible tree. Creating its content does not by itself advance a Session; a Session WAL fact establishes when a Conversation Entry becomes part of an authoritative Branch. Effect-recovery facts enter Model Context only through a committed typed Result Conversation Entry.

A Context Checkpoint is an immutable Conversation Entry used by future compaction. It is distinct from a State Checkpoint, which accelerates Core State recovery.

The Workspace remains external truth because the user, Git, an editor, or another process may change it while a Session sleeps. Consequential mutation descriptors bind the Workspace identity, target path, relevant base identity, preimage digest, exact mutation bytes, and Action generation. Divergence produces a typed conflict or indeterminate Result; OnePage never reconstructs or overwrites a user worktree from Session history.

## Core State and Activation Slot

**Core State** contains only compact semantic facts needed to continue one agent. It has an explicit schema version and canonical encoding with fixed widths, explicit enum values, defined byte order, length, and checksum. Unknown versions, states, enum values, identities, generations, or out-of-range fields fail closed. Native ABI fingerprints and struct layout are not durable compatibility rules.

**Activation Slot** is one exact 65,536-byte, caller-owned resident workspace. It contains decoded Core State plus bounded parser, response, and transition scratch. Core State never contains a native pointer or an offset into transient scratch. Large model responses, patches, command output, and Conversation content remain immutable blobs addressed by bounded handles and ranges.

The host reserves a fixed pool of Activation Slots before admitting work. Activation borrows a slot, decodes or reconstructs Core State into it, and performs no general-purpose allocation inside Core. Suspension encodes Core State, commits required semantic facts, scrubs the complete slot, and returns it to the pool. Slot identity and generation fence stale borrowed windows and late Completions.

Native Zig executes Core in production. The same reducer compiles to `wasm32-freestanding` as an independent conformance target. Native and Wasm tests compare accepted and rejected transition outcomes, produced intents, and canonical Core State encodings. Complete slot-byte equality is not a semantic requirement.

## Deep modules and interfaces

### Core

Core is a deterministic reducer. It owns task phases, legal semantic transitions, Action interpretation, stable identities and generations, bounded context-selection policy, and terminal decisions. It consumes typed semantic input and produces a prepared semantic transition or a closed rejection. It does not perform I/O, allocate, publish durable records, format provider requests, execute tools, or render output.

### Harness

`Harness.open / offer / drive` is the complete Session lifecycle interface. No alternate public run, resume, provider-assisted resume, or direct Core advancement path exists.

- `open` acquires exclusive Session ownership, validates durable inputs, and reconstructs through the safe WAL watermark using caller-owned fixed storage. It may borrow a slot while reconstructing but releases and scrubs it before returning.
- `offer` nonblockingly transfers bounded task, Completion, Authorization, cancellation, or shutdown input. It performs no I/O, allocation, wait, or Core call; full or busy results preserve producer ownership.
- `drive` performs one bounded owner quantum. It borrows an Activation Slot only for that quantum, then encodes Core State, invalidates borrowed windows, scrubs the slot, and releases it before returning. It alone advances Core, publishes Session facts, admits immutable Attempts to adapters, applies durable Completions, and returns committed Projections and progress.

Harness hides WAL ordering, checkpoint replay, page activation and scrubbing, adapter admission, reconciliation, cancellation settlement, and Projection regeneration. The CLI and tests use the same interface.

### Session storage

Session storage is an internal concrete module behind Harness. It owns WAL framing and valid-prefix recovery, immutable content publication, State Checkpoint encoding, exclusive ownership and epochs, and bounded reads. Raw sequence allocation, file paths, checksums, and cross-record correlation are not lifecycle interfaces.

### Adapters

Model, Bash, and `apply_patch` adapters receive only immutable admitted Attempts. They may perform external work and publish typed evidence through the Completion seam; they cannot choose policy, advance Core, append Session facts, retry themselves, or render terminal output. Deterministic and live adapters justify these internal seams.

Adapter evidence uses a non-authoritative durable **Completion Inbox**. The adapter first publishes immutable Result content, then a bounded inbox envelope binding Session, ownership epoch, Agent generation, Operation, Attempt, result digest, and evidence kind, and only then offers the in-memory Completion notification. Lost notification is harmless: `open` and `drive` scan the bounded inbox cursor and offer matching evidence through the normal owner path. Harness validates the binding and commits the terminal Result in one WAL transaction; only that commit advances the Session. Inbox cleanup may lag and duplicates are idempotent. Missing, corrupt, or mismatched evidence never becomes authority and falls back to the Attempt's uncertainty rule.

The CLI parses invocation, reserves host pools, chooses adapters and Permission Mode, supplies input, and renders sanitized committed Projections. It owns no Session lifecycle policy.

## Transition protocol

Every authoritative state change follows:

```text
prepare -> commit -> publish
```

Preparation uses fixed scratch to validate identity, generation, descriptor, Authorization, capacity, referenced immutable content, legal Core transition, and the complete bounded WAL transaction frame. It may reject without changing authoritative state.

Commit appends and synchronizes one complete WAL transaction frame. It may fail while leaving the previous valid prefix authoritative. An external adapter cannot observe an Attempt until that Attempt's identity, descriptor digest, ownership epoch, and recovery class are committed.

Publish applies the already-prepared Core State and emits prepared Projections. It performs no new semantic validation or general-purpose allocation. If a platform operation after commit cannot complete, the live owner becomes unavailable and a fresh `open` reconstructs the committed transition. Committed facts are never rolled back to match an older checkpoint or live image.

## Operations, Attempts, and recovery

An Action becomes one stable Operation. Operation acceptance and Attempt admission are separate WAL facts. Each Attempt has exactly one current disposition:

- `definitely_unsent` — the adapter did not observe the Attempt;
- `possibly_executed` — the external effect may have occurred without a durable terminal Result;
- `terminal(Result)` — immutable typed evidence completed the Attempt.

Attempt admission is the conservative dispatch boundary. Once its WAL transaction commits, recovery treats an unterminated Attempt as `possibly_executed` unless durable adapter evidence proves a terminal Result. `definitely_unsent` applies only when no Attempt admission committed or when a committed terminal adapter Result proves that external dispatch did not occur. OnePage does not infer non-execution merely because the Completion Inbox is empty.

The first durable terminal Result completes an Operation. Duplicate or late evidence remains auditable but cannot advance Core, Conversation, Projection, or Outcome again.

Recovery is effect-specific:

| Effect | Recovery from uncertainty |
| --- | --- |
| Model inference | Admit a new Attempt under the same Operation; report possible duplicate work or billing. |
| Bash | Never replay automatically; commit an indeterminate Result because arbitrary effects may have occurred. |
| One-file patch | Compare current content with exact preimage and postimage; accept postimage, require new Authorization before retrying preimage, and stop on divergence. |

Cancellation and shutdown stop new admission but settle or classify every accepted Attempt before publishing a terminal Outcome.

## Tools and Authorization

V1 exposes only `bash` and `apply_patch`. Bash covers inspection and verification through one bounded Result path. OnePage makes no repository-confinement or sandbox claim for Bash and never classifies an apparently read-only command as automatically safe.

Validation creates an immutable descriptor before Authorization. The descriptor binds tool kind, exact bytes, Workspace and working directory, relevant environment and timeout, Action identity and generation, and preimage state where applicable.

`ask` is the default Permission Mode. The CLI renders the exact descriptor and offers the user's allow or deny decision. Explicit bypass creates Authorization for the same validated descriptor without prompting. Both modes commit the exact Authorization before Attempt admission and follow identical validation and recovery paths. Resume selects `ask` unless bypass is explicitly supplied again; a prior exact Authorization remains evidence, but no Session retains blanket future authority.

## Capacity, scheduling, and topology

The host resolves and reserves Activation Slot, Completion, model-request, tool-process, output-tail, and recovery-working storage at startup. Capacity is fixed until restart. Exhaustion returns explicit backpressure or preserves already-accepted durable work; allocator failure and the operating-system OOM killer are not flow control.

Logical Session population, runnable count, resident Activation count, and in-flight external work are separate quantities. Scheduler working memory is bounded independently of total historical population through bounded scans or rebuildable on-disk indexes plus a bounded ready frontier. A configured drive quantum guarantees bounded work and eventual scheduling opportunities under the selected fairness policy.

Delegation creates durable child identity and parent Operation references, not resident caller frames. Activation, suspension, Completion routing, and recovery never traverse or hydrate ancestry. Total descendants, fan-out, durable bytes, spend, tool effects, and deadlines remain configurable resource policies even though topology is not a resident-memory dimension.

## Failure and compatibility

Disk exhaustion, short writes, sync failure, torn WAL tail, missing or corrupt referenced content, corrupt checkpoint, unsupported schema, stale ownership, and capacity exhaustion are normal closed outcomes with deterministic recovery rules. A pre-release schema or WAL version may fail clearly as unsupported; silent reinterpretation is forbidden.

State Checkpoints are replay accelerators. A same-build raw slot image may be added only as a measured cache, must be marked invalidatable, and can never be the only durable representation.
