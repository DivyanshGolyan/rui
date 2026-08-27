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
      bounded native Activation Slot
     decoded Core State + transient scratch
                    |
          semantic transition intent
                    v
       Harness: prepare -> commit -> publish
                    |
      model / Bash / apply_patch adapters
```

OnePage is single-host. One **Host Runtime** process owns one **Host Store** at a time and routes all durable access through its sole **Storage Owner**. The Workspace is external mutable truth. Local durable storage is authoritative for Session semantics but cannot reconstruct or overwrite arbitrary external Workspace changes.

## Simplicity boundary

Simplicity is a V1 correctness requirement. Each architectural role must own one necessary responsibility and hide enough mechanics to justify its existence. A new module, abstraction, durable representation, resident pool, background owner, or extension point is permitted only when it directly supports a current product guarantee, an external-effect boundary, or release evidence and cannot fit an existing owner without weakening that owner's contract.

OnePage prefers established dependencies for mechanisms and keeps policy in its existing domain seams. SQLite owns physical database transactions; Git owns patch parsing and application; a safe transport dependency may own Codex authentication. A transport dependency is accepted only when it cannot inspect the Workspace, select context, run tools, retry consequential work invisibly, or advance Session state.

V1 deliberately has no generalized scheduler, provider registry, OAuth framework, tool framework, terminal framework, custom SQLite VFS test system, or Host Store maintenance subsystem. Hypothetical reuse is not evidence. Adding one of these surfaces requires a concrete second consumer and an accepted ADR that explains why the existing deep modules are insufficient.

## Durable authority

The Host Store is one host-wide SQLite database. Each Session owns one append-only **Session Ledger** within it. The complete ordered ledger is the sole order of semantic facts that create, advance, recover, cancel, or complete that Session. It includes task admission, accepted model and tool Operations, Attempts with typed recovery classes, Approval Required, Authorization, Results, Conversation advancement, reconciliation, cancellation, and Outcome. Recovery disposition is derived from the fact kind and typed evidence rather than stored as a redundant wire field.

One call to `Session.commitSemantic` prepares one typed transaction containing one to eight ordered facts and optional Core State. That transaction is the Storage Owner's only semantic commit input. The Storage Owner validates and canonically encodes it, derives its admission class and every normalized Conversation or Completion write, then occupies one Session sequence and one ledger row. One SQLite transaction atomically fences the ownership epoch and expected head, inserts the row, advances the head, and writes the derived indexes. No independently supplied projection sidecar exists, and no enclosed fact or side effect is visible unless the complete transaction commits.

Each live Session has one copyable `ResidentState`: the sole Session sequence and semantic index, the linear V1 Conversation head, and relevant pending Completion evidence. Live commit and recovery apply the same pure ledger reducer to produce the next complete value. Ledger advancement also prunes Completion evidence made terminal or irrelevant by that transaction. After durable commit, publication is one `ResidentState` assignment plus clearing explicitly volatile preparation; Conversation and Completion state have no separate publication or reconstruction protocols.

The Session retains its claimed ownership fence and validates it internally on every operation. Callers do not retrieve a token from a Session merely to pass it back; persisted facts carry ownership epochs only where the epoch is domain evidence, while the Host Store's conditional head update remains the authoritative stale-owner fence.

Inside the process, a semantic fact is a typed variant with a kind-specific payload. Cross-kind combinations are not representable; Result evidence additionally couples recovery class, Attempt identity, and evidence kind as one typed choice. Scalar identity and range validity is checked before canonical publication and after decode. The compact flat tagged form exists only inside the canonical codec, where hostile wire input is validated completely before constructing a typed fact.

Large or variable content is immutable and stored outside SQLite. A publisher writes and synchronizes content before committing a Session Ledger transition that references it. Failure before that commit may leave an unreferenced blob, which is garbage; a committed transition may never reference absent or unverified content.

The following are non-authoritative and cannot establish Session semantics:

- runnable and waiting indexes;
- lookup accelerators;
- observer Projections;
- same-build activation caches, if later measurement justifies them;
- the durable Completion Inbox used to reconcile adapter evidence that has not yet entered the Session Ledger.

Derived views may lag the Session Ledger. Completion Inbox evidence may precede its terminal transaction and remain after association for audit, but only unconsumed pending evidence belongs to the recovery scan or resident value. Neither advances semantic authority. Recovery replays complete ordered transactions through the same reducer used for live publication and reconstructs Core State from the newest committed payload that contains it. A sequence gap, duplicate, conflicting identity, invalid canonical payload, or missing referenced content fails the Session closed. SQLite owns physical transaction atomicity and journal recovery; OnePage owns semantic validation and does not claim protection from arbitrary faulty hardware or storage returning incorrect bytes.

Streaming deltas, terminal frames, diagnostics, scheduler polling, and raw provider payload bytes are not Session Ledger facts. They are volatile projections, debug evidence, or immutable content.

## Conversation and Workspace

Conversation is the immutable parent-linked model-visible history. V1 is linear: each committed entry is the child of the current `conversation_head_id`, and branching is not implied by the reserved Session `branch_id`. Every normalized Conversation row is committed-only, names its creating Session Ledger sequence, and is mechanically derivable from the typed `conversation_advanced` fact. Session creation atomically commits the Session identity, initial canonical transaction, and root Conversation row; it does not admit the task for execution. The later `task_admitted` fact acknowledges offered Task custody. Effect-recovery facts enter Model Context only through a committed typed Result Conversation Entry.

A Context Checkpoint is an immutable Conversation Entry used by future compaction. V1 has no separate State Checkpoint: canonical Core State is already carried by the authoritative transaction that produced it.

The Workspace remains external truth because the user, Git, an editor, or another process may change it while a Session sleeps. One immutable **Patch Intent** binds the Workspace identity, canonical target path, permitted file properties, patch reference and digest, exact preimage digest, expected postimage digest, and Action generation before Authorization. Approval Required, Authorization, Attempt, and Result reference that same intent instead of reproducing its fields. Divergence produces a typed conflict or indeterminate Result; OnePage never reconstructs or overwrites a user worktree from Session history.

Git owns patch parsing and application semantics. The patch adapter prepares the expected postimage without mutating the bound Workspace, observes the target as preimage, postimage, divergent, or invalid, and applies only an authorized intent whose preimage still matches immediately before mutation. V1 assumes the target is quiescent from Authorization until Result commit; it does not claim atomic compare-and-swap protection against an uncooperative concurrent writer.

## Core State and Activation Slot

**Core State** contains only compact semantic facts needed to continue one agent. It has an explicit schema version and canonical encoding with fixed widths, explicit enum values, defined byte order, length, and checksum. Unknown versions, states, enum values, identities, generations, or out-of-range fields fail closed. Native ABI fingerprints and struct layout are not durable compatibility rules.

**Activation Slot** is one caller-owned resident workspace whose actual size is derived at compile time from decoded Core State and named bounded parser, response, and transition scratch. It contains no filler for a page-size headline and must remain at or below the 32 KiB V1 ceiling. Core State never contains a native pointer or an offset into transient scratch. Large model responses, patches, command output, and Conversation content remain immutable blobs addressed by bounded handles and ranges.

At startup the Host Runtime resolves one explicit `active_capacity` and allocates that many Activation Slots plus fixed occupancy and generation metadata. Activation borrows a slot, decodes or reconstructs Core State into it, and performs no general-purpose allocation inside Core. Suspension encodes Core State, commits required semantic facts, scrubs the complete slot, and returns it to the pool. Slot identity and generation fence stale borrowed windows and late Completions. V1 adds no scheduler object around this pool.

Native Zig is the sole V1 Core executor. Native invariant traces cover accepted and rejected transition outcomes, rejection-state preservation, semantic observations, deterministic canonical encoding, and restoration through differently poisoned slots. Core State's fixed-width codec and the compile-time-bounded native Activation Slot are the portability and resident-memory contracts; V1 defines no secondary runtime or target ABI.

## Deep modules and interfaces

### Core

Core is a deterministic reducer. It owns task phases, legal semantic transitions, Action interpretation, stable identities and generations, bounded context-selection policy, and terminal decisions. It consumes typed semantic input and produces a prepared semantic transition or a closed rejection. It does not perform I/O, allocate, publish durable records, format provider requests, execute tools, or render output.

### Harness

`Harness.open / offer / drive` is the complete Session lifecycle interface. No alternate public run, resume, provider-assisted resume, or direct Core advancement path exists.

The application first opens one opaque `HostRuntime` from a state path and host-level configuration, then gives a reference to each `Harness.open`. Exactly one SQLite-owning Host Runtime may exist in a process. The runtime owns the process-wide SQLite budget, state directory, singleton Storage Owner, connection, Activation Slot pool, and retired Harness allocations. `Harness.open` acquires one private retained runtime lease, captures stable I/O, allocator, and execution capabilities once, and returns an opaque pointer-stable handle rather than a copyable resource-owning value. Closing is idempotent, releases exactly one lease, and leaves the closed allocation owned by the runtime until runtime destruction. Harness configuration exposes no storage mechanics or create-time slices after open. Runtime close refuses while any lease remains. The application owner must serialize acquisition of an unretained runtime pointer against destruction.

- `open` acquires exclusive Session ownership through the Storage Owner and initializes fixed ledger and Inbox recovery cursors. A new Session returns ready immediately. A restored Session returns in `restoring`; it exposes no committed Projection or adapter work until `drive` has incrementally validated both snapshotted watermarks.
- `offer` nonblockingly transfers bounded Task, Completion, Permission Decision, cancellation, or shutdown input into fixed live-process ingress. It performs no I/O, allocation, wait, or Core call. `full` or `busy` preserves producer ownership; `accepted` transfers custody only to the live Harness instance.
- `drive` performs one bounded owner quantum. It borrows an Activation Slot only for that quantum, then encodes Core State, invalidates borrowed windows, scrubs the slot, and releases it before returning. It alone advances Core, publishes Session facts, admits immutable Attempts to adapters, applies durable Completions, and returns committed Projections and progress.

Projections are data-only values. They contain no Session pointer, generation pointer, file handle, or close authority. Content is reopened only through `Harness.openProjectionContent`, which checks the live Harness generation and Session identity before returning a bounded reader.

While restoration is incomplete, each `drive` consumes at most the configured recovery-record quantum and returns `restoring` with `more = true` and no Projection. The recovery cursor is a tagged protocol, so ledger, Inbox, pending, and ready fields cannot form invalid combinations. Completion offered during recovery remains in the single bounded Harness ingress slot and is not applied until the snapshotted pending-evidence watermark is safe. After the safe watermark is reached, Harness reconstructs the durable level state without dispatch, publishes Session identity first, and only a later `drive` may reconcile or admit external work. Recovery failure makes that live owner unavailable; a fresh `open` starts from durable bytes again.

Harness hides Session Ledger ordering, transaction replay, page activation and scrubbing, adapter admission, reconciliation, control settlement, and Projection regeneration. Cancellation and shutdown continue bounded Completion Inbox reconciliation while accepted Attempts settle; they publish a terminal Outcome only after no accepted Operation remains open. The CLI and tests use the same interface.

`offer` acceptance is not durable semantic acknowledgement. Only a committed Host Store transaction acknowledges durable acceptance. Until that commit, a process crash may discard volatile ingress: Completion is rediscovered from its durable Completion Inbox evidence, an `ask` decision is requested again, an uncommitted Task remains unadmitted, and uncommitted cancellation has not taken effect. The CLI acknowledges these inputs to the user only through a committed Projection returned after `drive`.

### Session storage

The Host Runtime acquires a lifetime operating-system lock before opening the Host Store. A second process targeting that store receives `busy`; SQLite transaction locks do not replace this singleton guarantee. Within the runtime, the Storage Owner is the only code allowed to open or access SQLite. Core, Harness instances, adapters, workers, and the CLI issue bounded requests and never open their own connections. The foreground CLI may host the runtime in V1; a future daemon may expose the same interface over bounded IPC.

The Storage Owner owns one pinned SQLite connection, schema installation and validation, Session sequences, ownership epochs, canonical transactions, normalized Conversation metadata, Completion Inbox evidence, and bounded reads. One request mutex serializes each complete public operation across every Harness, including its full `BEGIN` through `COMMIT` interval; SQLite calls from different requests cannot interleave on the connection. It executes only indexed and bounded statements and returns bounded results. Raw SQL, row identifiers, physical table shape, SQLite errors, and connection lifetime are not Session lifecycle interfaces.

V1 configures 4 KiB pages, rollback-journal `DELETE`, `synchronous=EXTRA`, foreign keys, `busy_timeout=0`, `mmap_size=0`, and `temp_store=FILE`. Tables are `STRICT`; defensive mode is enabled; trusted schema, double-quoted string literals, extension loading, `ATTACH`, and SQLite worker threads are disabled; conservative runtime limits constrain lengths, columns, SQL text, variables, expression depth, and database pages. The SQLite version and compile options are pinned. The 32, 64, and 128 KiB page-cache profiles are measured configuration points, not total-memory or production-performance promises. `sqlite3_hard_heap_limit64` covers every SQLite connection in the process, so Host Runtime—not an individual connection—owns and configures that allowance. Global heap is the authoritative enforced total. Page-cache, lookaside, and statement figures are non-additive diagnostics that may already be included in it.

The Host Store schema version and Session payload version are independent. Unsupported versions fail clearly. Pre-release V1 does not implement downgrade compatibility or a general migration framework. Opening reads schema identity from SQLite rather than inferring it from file existence. An empty database with zero application and schema versions may install or retry installation; an unowned non-empty schema fails closed. Schema objects and both identity fields commit in one transaction, with identity written last, so an interrupted installation remains safely retryable. Because V1 has no migration framework, open validates the exact stored DDL and object set. It does not duplicate that proof through weaker column probes, foreign-key counts, or eager preparation of every lifecycle statement.

### Adapters

Model, Bash, and `apply_patch` adapters receive only immutable admitted Attempts. They may perform external work and publish typed evidence through the Completion seam; they cannot choose policy, advance Core, append Session facts, retry themselves, or render terminal output. A known provider dispatch failure is encoded as a durable terminal Result for its admitted Attempt; it is not recovered as missing evidence or retried. Each model Attempt commits a bounded count of earlier Attempts under that Operation that may already have reached the provider, making possible duplicate work or billing visible before redispatch. A model Operation may admit only its fixed recovery-history capacity: if every admitted dispatch loses evidence, exhaustion publishes a durable provider-failure Result for the last Attempt instead of stranding the Session or admitting an unrecordable retry. The deterministic external-model capability justifies the narrow Provider seam. An optional Codex adapter, if feasible, reuses that seam; V1 does not add a provider registry.

The preferred Codex adapter delegates browser authorization, credential storage, refresh, TLS, and account selection to an established official client only if it exposes a transport-only mode with tools and Workspace access disabled. OnePage still owns the exact model name, bounded request and response, timeout, canonical decoding, dispatch uncertainty, and publication through the existing Provider contract. If no safe transport-only dependency exists, V1 may use one provider-specific credential flow or defer live subscription support; it does not build a generalized authentication product.

Adapter evidence uses a non-authoritative durable **Completion Inbox**. The adapter first publishes immutable Result content, then asks the Storage Owner to commit one evidence row binding Session, ownership epoch, Agent generation, Operation and generation, Attempt, evidence kind, Result reference, and digest. SQLite assigns a host-wide positive Inbox identity; the semantic fields remain unique and conflicting evidence for that same identity fails closed. Publication transactionally enforces at most 4,096 unconsumed rows per Session. Truly irrelevant evidence is not persisted. Valid evidence for an admitted Attempt that arrives after another Attempt completed the Operation is inserted already associated with the terminal Session sequence: it remains auditable but never enters the pending recovery bound or resident Inbox. Exact duplicate evidence is idempotent and consumes no additional capacity. No Session-row counter or two-write publication protocol exists. Only after acknowledgement may the adapter offer the in-memory Completion notification. Lost notification is harmless: `open` and `drive` use the `(session_id, inbox_id)` index to scan only the bounded unconsumed range through the normal owner path.

Harness validates the complete identity and atomically associates the immutable evidence with the terminal Session transition through `consumed_by_sequence`; it does not delete the evidence on consumption. The unique Completion identity excludes Result reference and digest: the same identity and Result is idempotent, while the same identity with different Result evidence is a closed conflict. Missing, corrupt, or mismatched evidence never becomes authority and falls back to the Attempt's uncertainty rule. V1 retains evidence indefinitely. Post-V1 maintenance may collect it only after the Session is durably closed.

The CLI parses invocation, reserves host pools, chooses adapters and Permission Mode, supplies input, and renders sanitized committed Projections. Creation and provider-assisted resume construct the selected adapter before `Harness.open` and use the same owner loop. It owns no Session lifecycle policy.

## Transition protocol

Every authoritative state change follows:

```text
prepare -> commit -> publish
```

Preparation uses fixed scratch to validate identity, generation, descriptor, Authorization, capacity, referenced immutable content, legal Core transition, and the complete bounded canonical payload. It may reject without changing authoritative state.

Every authoritative byte binding uses a domain-separated SHA-256 value with a semantic wrapper appropriate to its role. Descriptor, Patch Intent, preimage, postimage, Result, Completion, and ledger-record bindings share one cryptographic width but are not interchangeable identities. An all-zero digest is data, not an absence sentinel. These unkeyed digests provide collision-resistant byte binding and accidental-corruption detection; they do not make a locally rewritable database tamper-proof.

Commit asks the Storage Owner to publish one complete SQLite transaction. It may fail while leaving the previous Session sequence authoritative. An external adapter cannot observe an Attempt until that Attempt's identity, descriptor digest, ownership epoch, and recovery class are committed.

Publish assigns the already-prepared `ResidentState`, clears explicitly volatile preparation, and emits prepared Projections through infallible assignments. Semantic indexes, Conversation advancement, Completion pruning, capacity checks, and every other operation that can reject the transition are prepared before commit. If a platform operation after commit cannot complete, the live owner becomes unavailable and a fresh `open` reconstructs the committed transaction. Committed facts are never rolled back to match an older live image.

## Operations, Attempts, and recovery

An Action becomes one stable Operation. Operation acceptance and Attempt admission are separate Session Ledger facts. Each Attempt has exactly one current disposition:

- `definitely_unsent` — the adapter did not observe the Attempt;
- `possibly_executed` — the external effect may have occurred without a durable terminal Result;
- `terminal(Result)` — immutable typed evidence completed the Attempt.

Attempt admission is the conservative dispatch boundary. Once its Host Store transaction commits, recovery treats an unterminated Attempt as `possibly_executed` unless durable adapter evidence proves a terminal Result. `definitely_unsent` applies only when no Attempt admission committed or when a committed terminal adapter Result proves that external dispatch did not occur. OnePage does not infer non-execution merely because the Completion Inbox is empty.

The first durable terminal Result completes an Operation. Later evidence from a different admitted Attempt is associated with that terminal sequence for audit and cannot advance Core, Conversation, Projection, or Outcome again. Different evidence for the winning Attempt is a conflict.

Recovery is effect-specific:

| Effect | Recovery from uncertainty |
| --- | --- |
| Model inference | If the admitted Attempt lacks terminal evidence, admit a new Attempt under the same Operation whose durable duplicate count exposes how many prior dispatches may also bill or complete. A known provider failure is already a terminal Result and is not retried. |
| Bash | Never replay automatically; commit an indeterminate Result because arbitrary effects may have occurred. |
| One-file patch | Observe the target through its durable Patch Intent. Accept the expected postimage without reapplying; apply a matching preimage only under the stated quiescence contract and current Authorization; stop on divergence or invalid target. |

Cancellation and shutdown stop new admission but settle or classify every accepted Attempt before publishing a terminal Outcome.

## Tools and Authorization

V1 exposes only the closed typed `bash` and `apply_patch` Actions. They are capabilities behind the existing adapter boundary, not runtime plugins: Core selects an Action, Harness owns validation, Authorization, Attempt admission, durable ordering, and recovery, and a leaf adapter executes only an immutable admitted Attempt. Tool visibility never grants authority. Bash covers inspection and verification through one bounded Result path. OnePage makes no repository-confinement or sandbox claim for Bash and never classifies an apparently read-only command as automatically safe.

A future out-of-tree tool requirement may justify a host-resolved definition table with stable input, output, and capability contracts. It must leave approval and durable recovery outside executors. V1 adds no dynamic registry, discovery format, unload lifecycle, dependency graph, event waterfall, or per-Session tool shadowing for two built-in Actions.

Validation creates an immutable descriptor before Approval Required or Authorization. The descriptor binds tool kind, exact bytes, Workspace and working directory, relevant environment and timeout, Action identity and generation, and preimage state where applicable.

`ask` is the default Permission Mode. It commits Approval Required for the exact descriptor before the CLI prompts, then the CLI offers a matching Permission Decision. Approval Required is a waiting state, never an undecided Authorization. An exact allow or deny decision commits Authorization; explicit bypass commits Authorization for the same descriptor without prompting. Both modes commit the exact Authorization before Attempt admission and follow identical validation and recovery paths. Shutdown and cancellation deny an outstanding Approval Required state before terminal control settlement. Resume selects `ask` unless bypass is explicitly supplied again; a prior exact Authorization remains evidence, but no Session retains blanket future authority.

## Capacity and density

V1 exposes one startup-fixed `active_capacity`. The Host Runtime allocates exactly that many Activation Slots, caps open Harness owners at that value, and permits at most one in-flight external Attempt per Harness. This one number bounds the active execution working set without introducing separate model, tool, Completion, recovery, or scheduler pools. A future workload that requires parallel Attempts inside one Harness must justify a separate capacity in a new issue.

Opening beyond `active_capacity` fails before Session ownership or external work is acquired. Temporary slot exhaustion returns bounded `busy` or `waiting`; it does not allocate, spin, or create an unbounded queue. Effect-capacity failure occurs before Attempt admission. Once an Attempt is admitted, closure work takes priority over new admission.

The process-wide SQLite hard heap limit is the authoritative SQLite allowance. Page-cache, lookaside, and statement counters describe overlapping parts of that allocation and must not be summed as independent reservations. Request and result buffers remain separate OnePage reservations. Supported workloads must remain within a measured current and high-water envelope below the process allowance. `SQLITE_NOMEM` or violation of the validated envelope is a Host Store fault, not ordinary backpressure. Page-cache size is selected from the host budget and may grow on larger hosts without changing Session semantics.

SQLite's low-water page reserve protects only SQLite closure writes. Before admitting an external effect, OnePage durably prepares the immutable descriptor and any closure evidence that can be known in advance, then ensures the remaining bounded terminal representation can use the configured SQLite reserve and bounded blob policy. V1 does not claim that byte credits can guarantee writes on an arbitrarily failing or full filesystem. Failure to prepare evidence prevents dispatch; exhaustion after a possible effect fails closed and is reported as an unsupported storage failure rather than concealed by a scheduler.

The density proof has two axes. It increases Dormant Sessions while holding `active_capacity` fixed, then increases `active_capacity` while holding dormant population fixed. It reports actual slot size and named components, reserved and occupied high-water slot bytes, open Harness count, compact state, fixed host metadata, SQLite memory, virtual size, physical resident memory, blob and database bytes, and subprocess memory separately. Tests dirty and release slots before measurement. V1 claims only that Activation Slot reservation is `@sizeOf(ActivationSlot) * active_capacity` and does not scale with dormant Session count.

V1 has one SQLite writer and commits one whole Session request at a time. It has no fair queue, group commit, dynamic RSS feedback, pressure-triggered cancellation, topology experiment, or production scheduler. Additional writers, storage sharding, and scheduling policy require measured demand after V1.

## Failure and compatibility

Disk exhaustion, SQLite full, I/O, corrupt, and allocation failures, missing or corrupt referenced content, corrupt canonical payloads, unsupported versions, stale ownership, and capacity exhaustion are closed outcomes with explicit recovery rules. Physical Host Store corruption, failed SQLite recovery, and storage exhaustion may make every Session on the host unavailable; the host-wide failure domain is accepted and never reported as an isolated Session failure. OnePage tests its semantic use of SQLite and relies on the pinned engine and supported platform for pager atomicity and journal recovery.

The Host Store has an explicit maximum page count and protects a configured low-water closure reserve from durable admission. Free pages count toward available capacity. Admission performs its writes inside the transaction, then checks the actual remaining page budget before commit; an admission that would enter the reserve rolls back. Closure-class work may consume that reserve. Foreground work never runs `VACUUM`.

V1 makes no backup or long-term retention promise. The state directory is experimental, may be copied only while OnePage is closed, and may be deleted as a whole to reset. Recoverable snapshots, export, Session removal, blob garbage collection, integrity tooling, shrinking, and migration are post-V1 responsibilities. A future backup must bind one SQLite snapshot to its exact immutable-blob closure before it may claim recoverability.

A same-build raw slot image may be added later only as a measured invalidatable cache; it can never be the only durable representation.

## Future deployment and recursive workloads

V1 ships one native Host Runtime. Its semantic boundaries deliberately avoid native layout, SQLite handles, file paths, and process mechanics outside their owners, but portability is not a second implementation requirement. A Cloudflare deployment is post-V1: a Workerd profile would need a Wasm Core, a Storage Owner over Durable Object transactions, and non-process tool capabilities, while a Durable Object-managed Container could retain the native executable but would still need an explicit Workspace and storage topology. Neither path justifies restoring Wasm conformance or a platform framework to V1.

The architecture may later host Recursive Language Model workloads without retaining recursive call stacks. External context remains immutable range-addressed content; each child model call becomes a durable Operation or child Session; and depth, fan-out, token, cost, time, and active-work budgets belong to the Host Runtime. A REPL, delegation, child-result aggregation, persistent environment, and scheduling policy remain post-V1 capabilities and must not enter Session authority implicitly.
