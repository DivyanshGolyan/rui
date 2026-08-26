# OnePage architecture

This document is normative. Historical spikes and research explain how the project reached this design; where they conflict, this document and accepted ADRs win.

## System shape

```text
durable world

immutable blobs and Conversation nodes
                    +
       host-wide SQLite Host Store
     per-Session ordered ledger rows
                    |
          Session sequence S
                    v
     canonical transaction payload
      including compact Core State
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

OnePage is single-host. One **Host Runtime** process owns one **Host Store** at a time and routes all durable access through its sole **Storage Owner**. The Workspace is external mutable truth. Local durable storage is authoritative for Session semantics but cannot reconstruct or overwrite arbitrary external Workspace changes.

## Durable authority

The Host Store is one host-wide SQLite database. Each Session owns one append-only **Session Ledger** within it. The complete ordered ledger is the sole order of semantic facts that create, advance, recover, cancel, or complete that Session. It includes task admission, accepted model and tool Operations, Attempts with typed recovery classes, Approval Required, Authorization, Results, Conversation advancement, reconciliation, cancellation, and Outcome. Recovery disposition is derived from the fact kind and typed evidence rather than stored as a redundant wire field.

One call to `Session.commitSemantic` prepares one typed transaction containing one to eight ordered facts and optional Core State. That transaction is the Storage Owner's only semantic commit input. The Storage Owner validates and canonically encodes it, derives its admission class and every normalized Conversation or Completion write, then occupies one Session sequence and one ledger row. One SQLite transaction atomically fences the ownership epoch and expected head, inserts the row, advances the head, and writes the derived indexes. No independently supplied projection sidecar exists, and no enclosed fact or side effect is visible unless the complete transaction commits.

Inside the process, a semantic fact is a typed variant with a kind-specific payload. Cross-kind combinations are not representable; Result evidence additionally couples recovery class, Attempt identity, and evidence kind as one typed choice. Scalar identity and range validity is checked before canonical publication and after decode. The compact flat tagged form exists only inside the canonical codec, where hostile wire input is validated completely before constructing a typed fact.

Large or variable content is immutable and stored outside SQLite. A publisher writes and synchronizes content before committing a Session Ledger transition that references it. Failure before that commit may leave an unreferenced blob, which is garbage; a committed transition may never reference absent or unverified content.

The following are non-authoritative and cannot establish Session semantics:

- runnable and waiting indexes;
- lookup accelerators;
- observer Projections;
- same-build activation caches, if later measurement justifies them;
- the durable Completion Inbox used to reconcile adapter evidence that has not yet entered the Session Ledger.

Derived views may lag the Session Ledger. Completion Inbox evidence may precede its terminal transaction and remain after association. Neither advances semantic authority. Recovery replays complete ordered transactions and reconstructs Core State from the newest committed payload that contains it. A sequence gap, duplicate, conflicting identity, invalid canonical payload, or missing referenced content fails the Session closed. SQLite owns physical transaction atomicity and journal recovery; OnePage owns semantic validation and does not claim protection from arbitrary faulty hardware or storage returning incorrect bytes.

Streaming deltas, terminal frames, diagnostics, scheduler polling, and raw provider payload bytes are not Session Ledger facts. They are volatile projections, debug evidence, or immutable content.

## Conversation and Workspace

Conversation is the immutable parent-linked model-visible tree. Every normalized Conversation row is committed-only, names its creating Session Ledger sequence, and is mechanically derivable from the typed `conversation_advanced` fact. Session creation atomically commits the Session identity, initial canonical transaction, and root Conversation row; it does not admit the task for execution. The later `task_admitted` fact acknowledges offered Task custody. Effect-recovery facts enter Model Context only through a committed typed Result Conversation Entry.

A Context Checkpoint is an immutable Conversation Entry used by future compaction. V1 has no separate State Checkpoint: canonical Core State is already carried by the authoritative transaction that produced it.

The Workspace remains external truth because the user, Git, an editor, or another process may change it while a Session sleeps. Consequential mutation descriptors bind the Workspace identity, target path, relevant base identity, preimage digest, exact mutation bytes, and Action generation. Divergence produces a typed conflict or indeterminate Result; OnePage never reconstructs or overwrites a user worktree from Session history.

## Core State and Activation Slot

**Core State** contains only compact semantic facts needed to continue one agent. It has an explicit schema version and canonical encoding with fixed widths, explicit enum values, defined byte order, length, and checksum. Unknown versions, states, enum values, identities, generations, or out-of-range fields fail closed. Native ABI fingerprints and struct layout are not durable compatibility rules.

**Activation Slot** is one exact 65,536-byte, caller-owned resident workspace. It contains decoded Core State plus bounded parser, response, and transition scratch. Core State never contains a native pointer or an offset into transient scratch. Large model responses, patches, command output, and Conversation content remain immutable blobs addressed by bounded handles and ranges.

The host reserves a fixed pool of Activation Slots before admitting work. Activation borrows a slot, decodes or reconstructs Core State into it, and performs no general-purpose allocation inside Core. Suspension encodes Core State, commits required semantic facts, scrubs the complete slot, and returns it to the pool. Slot identity and generation fence stale borrowed windows and late Completions.

Native Zig is the sole V1 Core executor. Native invariant traces cover accepted and rejected transition outcomes, rejection-state preservation, semantic observations, deterministic canonical encoding, and restoration through differently poisoned slots. Core State's fixed-width codec and the exact native Activation Slot are the portability and resident-memory contracts; V1 defines no secondary runtime or target ABI.

## Deep modules and interfaces

### Core

Core is a deterministic reducer. It owns task phases, legal semantic transitions, Action interpretation, stable identities and generations, bounded context-selection policy, and terminal decisions. It consumes typed semantic input and produces a prepared semantic transition or a closed rejection. It does not perform I/O, allocate, publish durable records, format provider requests, execute tools, or render output.

### Harness

`Harness.open / offer / drive` is the complete Session lifecycle interface. No alternate public run, resume, provider-assisted resume, or direct Core advancement path exists.

The application first opens one opaque `HostRuntime` from a state path and host-level configuration, then gives a reference to each `Harness.open`. Exactly one SQLite-owning Host Runtime may exist in a process. The runtime owns the process-wide SQLite budget, state directory, singleton Storage Owner, connection, and Activation Slot pool. Harness configuration exposes none of those mechanics or handles individually; callers can inspect narrow aggregate metrics, but cannot assemble a partially configured lifecycle owner. Runtime ownership is atomically retained by each Harness, and closing refuses while any retained owner remains. The application owner must serialize `Harness.open` against `HostRuntime.close`; the retained-owner count does not make an unretained raw pointer safe to acquire concurrently with destruction.

- `open` acquires exclusive Session ownership through the Storage Owner and initializes fixed ledger and Inbox recovery cursors. A new Session returns ready immediately. A restored Session returns in `restoring`; it exposes no committed Projection or adapter work until `drive` has incrementally validated both snapshotted watermarks.
- `offer` nonblockingly transfers bounded Task, Completion, Permission Decision, cancellation, or shutdown input into fixed live-process ingress. It performs no I/O, allocation, wait, or Core call. `full` or `busy` preserves producer ownership; `accepted` transfers custody only to the live Harness instance.
- `drive` performs one bounded owner quantum. It borrows an Activation Slot only for that quantum, then encodes Core State, invalidates borrowed windows, scrubs the slot, and releases it before returning. It alone advances Core, publishes Session facts, admits immutable Attempts to adapters, applies durable Completions, and returns committed Projections and progress.

While restoration is incomplete, each `drive` consumes at most the configured recovery-record quantum and returns `restoring` with `more = true` and no Projection. After the safe watermark is reached, Harness reconstructs the durable level state without dispatch, publishes Session identity first, and only a later `drive` may reconcile or admit external work. Recovery failure makes that live owner unavailable; a fresh `open` starts from durable bytes again.

Harness hides Session Ledger ordering, transaction replay, page activation and scrubbing, adapter admission, reconciliation, control settlement, and Projection regeneration. Cancellation and shutdown continue bounded Completion Inbox reconciliation while accepted Attempts settle; they publish a terminal Outcome only after no accepted Operation remains open. The CLI and tests use the same interface.

`offer` acceptance is not durable semantic acknowledgement. Only a committed Host Store transaction acknowledges durable acceptance. Until that commit, a process crash may discard volatile ingress: Completion is rediscovered from its durable Completion Inbox evidence, an `ask` decision is requested again, an uncommitted Task remains unadmitted, and uncommitted cancellation has not taken effect. The CLI acknowledges these inputs to the user only through a committed Projection returned after `drive`.

### Session storage

The Host Runtime acquires a lifetime operating-system lock before opening the Host Store. A second process targeting that store receives `busy`; SQLite transaction locks do not replace this singleton guarantee. Within the runtime, the Storage Owner is the only code allowed to open or access SQLite. Core, Harness instances, adapters, workers, and the CLI issue bounded requests and never open their own connections. The foreground CLI may host the runtime in V1; a future daemon may expose the same interface over bounded IPC.

The Storage Owner owns one pinned SQLite connection, schema installation and validation, Session sequences, ownership epochs, canonical transactions, normalized Conversation metadata, Completion Inbox evidence, and bounded reads. One request mutex serializes each complete public operation across every Harness, including its full `BEGIN` through `COMMIT` interval; SQLite calls from different requests cannot interleave on the connection. It executes only indexed and bounded statements and returns bounded results. Raw SQL, row identifiers, physical table shape, SQLite errors, and connection lifetime are not Session lifecycle interfaces. Issue #3 may later place bounded request credits in front of this unchanged seam.

V1 configures 4 KiB pages, rollback-journal `DELETE`, `synchronous=EXTRA`, foreign keys, `busy_timeout=0`, `mmap_size=0`, and `temp_store=FILE`. Tables are `STRICT`; defensive mode is enabled; trusted schema, double-quoted string literals, extension loading, `ATTACH`, and SQLite worker threads are disabled; conservative runtime limits constrain lengths, columns, SQL text, variables, expression depth, and database pages. The SQLite version and compile options are pinned. The 32, 64, and 128 KiB page-cache profiles are measured configuration points, not total-memory or production-performance promises. `sqlite3_hard_heap_limit64` covers every SQLite connection in the process, so Host Runtime—not an individual connection—owns and configures that allowance. Global heap is the authoritative enforced total. Page-cache, lookaside, and statement figures are non-additive diagnostics that may already be included in it.

The Host Store schema version and Session payload version are independent. Unsupported versions fail clearly. Pre-release V1 does not implement downgrade compatibility or a general migration framework. Opening reads schema identity from SQLite rather than inferring it from file existence. An empty database with zero application and schema versions may install or retry installation; an unowned non-empty schema fails closed. Schema objects and both identity fields commit in one transaction, with identity written last, so an interrupted installation remains safely retryable. Because V1 has no migration framework, open validates the exact stored DDL and object set. It does not duplicate that proof through weaker column probes, foreign-key counts, or eager preparation of every lifecycle statement.

### Adapters

Model, Bash, and `apply_patch` adapters receive only immutable admitted Attempts. They may perform external work and publish typed evidence through the Completion seam; they cannot choose policy, advance Core, append Session facts, retry themselves, or render terminal output. A known provider dispatch failure is encoded as a durable terminal Result for its admitted Attempt; it is not recovered as missing evidence or retried. A model Operation may admit only its fixed recovery-history capacity: if every admitted dispatch loses evidence, exhaustion publishes a durable provider-failure Result for the last Attempt instead of stranding the Session or admitting an unrecordable retry. Deterministic and live adapters justify these internal seams.

Adapter evidence uses a non-authoritative durable **Completion Inbox**. The adapter first publishes immutable Result content, then asks the Storage Owner to commit one evidence row binding Session, ownership epoch, Agent generation, Operation and generation, Attempt, evidence kind, Result reference, and digest. SQLite assigns a host-wide positive Inbox identity; the semantic fields remain unique and conflicting evidence fails closed. No Session-row counter or two-write publication protocol exists. Only after acknowledgement may the adapter offer the in-memory Completion notification. Lost notification is harmless: `open` and `drive` use the `(session_id, inbox_id)` index to scan the bounded snapshotted range through the normal owner path.

Harness validates the complete identity and atomically associates the immutable evidence with the terminal Session transition through `consumed_by_sequence`; it does not delete the evidence on consumption. The unique Completion identity excludes Result reference and digest: the same identity and Result is idempotent, while the same identity with different Result evidence is a closed conflict. Missing, corrupt, or mismatched evidence never becomes authority and falls back to the Attempt's uncertainty rule. V1 retains evidence until its closed Session is explicitly removed.

The CLI parses invocation, reserves host pools, chooses adapters and Permission Mode, supplies input, and renders sanitized committed Projections. Creation and provider-assisted resume construct the selected adapter before `Harness.open` and use the same owner loop. It owns no Session lifecycle policy.

## Transition protocol

Every authoritative state change follows:

```text
prepare -> commit -> publish
```

Preparation uses fixed scratch to validate identity, generation, descriptor, Authorization, capacity, referenced immutable content, legal Core transition, and the complete bounded canonical payload. It may reject without changing authoritative state.

Commit asks the Storage Owner to publish one complete SQLite transaction. It may fail while leaving the previous Session sequence authoritative. An external adapter cannot observe an Attempt until that Attempt's identity, descriptor digest, ownership epoch, and recovery class are committed.

Publish applies the already-prepared Core State and emits prepared Projections through infallible assignments. Semantic indexes, capacity checks, and every other operation that can reject the transition are prepared before commit. If a platform operation after commit cannot complete, the live owner becomes unavailable and a fresh `open` reconstructs the committed transaction. Committed facts are never rolled back to match an older live image.

## Operations, Attempts, and recovery

An Action becomes one stable Operation. Operation acceptance and Attempt admission are separate Session Ledger facts. Each Attempt has exactly one current disposition:

- `definitely_unsent` — the adapter did not observe the Attempt;
- `possibly_executed` — the external effect may have occurred without a durable terminal Result;
- `terminal(Result)` — immutable typed evidence completed the Attempt.

Attempt admission is the conservative dispatch boundary. Once its Host Store transaction commits, recovery treats an unterminated Attempt as `possibly_executed` unless durable adapter evidence proves a terminal Result. `definitely_unsent` applies only when no Attempt admission committed or when a committed terminal adapter Result proves that external dispatch did not occur. OnePage does not infer non-execution merely because the Completion Inbox is empty.

The first durable terminal Result completes an Operation. Duplicate or late evidence remains auditable but cannot advance Core, Conversation, Projection, or Outcome again.

Recovery is effect-specific:

| Effect | Recovery from uncertainty |
| --- | --- |
| Model inference | If the admitted Attempt lacks terminal evidence, admit a new Attempt under the same Operation and report possible duplicate work or billing. A known provider failure is already a terminal Result and is not retried. |
| Bash | Never replay automatically; commit an indeterminate Result because arbitrary effects may have occurred. |
| One-file patch | Compare current content with exact preimage and postimage; accept postimage, require new Authorization before retrying preimage, and stop on divergence. |

Cancellation and shutdown stop new admission but settle or classify every accepted Attempt before publishing a terminal Outcome.

## Tools and Authorization

V1 exposes only `bash` and `apply_patch`. Bash covers inspection and verification through one bounded Result path. OnePage makes no repository-confinement or sandbox claim for Bash and never classifies an apparently read-only command as automatically safe.

Validation creates an immutable descriptor before Approval Required or Authorization. The descriptor binds tool kind, exact bytes, Workspace and working directory, relevant environment and timeout, Action identity and generation, and preimage state where applicable.

`ask` is the default Permission Mode. It commits Approval Required for the exact descriptor before the CLI prompts, then the CLI offers a matching Permission Decision. Approval Required is a waiting state, never an undecided Authorization. An exact allow or deny decision commits Authorization; explicit bypass commits Authorization for the same descriptor without prompting. Both modes commit the exact Authorization before Attempt admission and follow identical validation and recovery paths. Shutdown and cancellation deny an outstanding Approval Required state before terminal control settlement. Resume selects `ask` unless bypass is explicitly supplied again; a prior exact Authorization remains evidence, but no Session retains blanket future authority.

## Capacity, scheduling, and topology

The host resolves one resident-memory budget into fixed reservations for Activation Slots, Core workers, the Storage Owner, storage-request envelopes, scheduler frontier, Completion records, model requests, tool processes, output tails, recovery work, native stacks, runtime overhead, and a safety margin. The sum must fit before admission and remains fixed until restart. Exhaustion returns explicit backpressure or preserves already-accepted durable work; allocator failure and the operating-system OOM killer are not flow control.

The process-wide SQLite hard heap limit is the authoritative SQLite allowance. Page-cache, lookaside, and statement counters describe overlapping parts of that allocation and must not be summed as independent reservations. Request and result buffers remain separate OnePage reservations. Supported workloads must remain within a measured current and high-water envelope below the process allowance. `SQLITE_NOMEM` or violation of the validated envelope is a Host Store fault, not ordinary backpressure. Page-cache size is selected from the host budget and may grow on larger hosts without changing Session semantics.

Logical Session population, runnable count, resident Activation count, Core worker count, in-flight external work, storage-request credits, and SQLite memory are independent capacities. Ten thousand resident Activation Slots require exactly 625 MiB for slots; the single Storage Owner remains one host-level reservation. Scheduler working memory is bounded independently of historical population through paginated Host Store scans and a bounded ready frontier. Configured drive and recovery quanta guarantee bounded work and eventual scheduling opportunities.

V1 has one SQLite writer and commits one whole Session request at a time. Fair request credits and optional bounded cross-Session group commit belong to the scheduler work in issue #3; they are not part of the Host Store cutover. Additional same-database writer connections and storage sharding are outside V1 and require new evidence and cross-Session atomicity rules.

Delegation creates durable child identity and parent Operation references, not resident caller frames. Activation, suspension, Completion routing, and recovery never traverse or hydrate ancestry. Total descendants, fan-out, durable bytes, spend, tool effects, and deadlines remain configurable resource policies even though topology is not a resident-memory dimension.

## Failure and compatibility

Disk exhaustion, SQLite full, busy, I/O, corrupt, and allocation failures, missing or corrupt referenced content, corrupt canonical payloads, unsupported versions, stale ownership, and capacity exhaustion are closed outcomes with deterministic recovery rules. Physical Host Store corruption, failed SQLite recovery, storage exhaustion, and blocking maintenance may make every Session on the host unavailable; the host-wide failure domain is accepted and never reported as an isolated Session failure.

The Host Store has an explicit maximum page count and protects a configured low-water closure reserve from durable admission. Free pages count toward available capacity. Admission performs its writes inside the transaction, then checks the actual remaining page budget before commit; an admission that would enter the reserve rolls back. Closure-class work may consume that reserve. This fixed page margin is not yet a proof that every simultaneously outstanding Attempt can settle and does not reserve filesystem space for journals. Issue #3 must introduce admission credits that reserve measured worst-case closure capacity before increasing concurrent in-flight work. Foreground work never runs `VACUUM`. A recoverable backup must snapshot SQLite and the exact immutable-blob closure; that host-snapshot facility, export, shrinking, and major maintenance belong to bounded maintenance work. Removing data requires an explicitly selected closed Session and never prunes individual authoritative transactions from a retained Session. Blob garbage collection is bounded maintenance over durable references.

A same-build raw slot image may be added later only as a measured invalidatable cache; it can never be the only durable representation.
