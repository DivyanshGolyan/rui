# OnePage engineering style

This document defines the implementation rules for OnePage. Product semantics remain authoritative in
`PRODUCT.md`, `ARCHITECTURE.md`, `VERIFICATION.md`, accepted ADRs, and `CONTEXT.md`.

The rules adapt TigerStyle to OnePage's bounded native architecture. They are scoped contracts, not
quotas for line length, assertion count, pointer use, or helper naming.

## Priorities

When rules compete, decide in this order:

1. correctness, durability, and security;
2. bounded resource use;
3. architectural simplicity;
4. measured performance;
5. developer experience.

Do not defer a known defect in the first two priorities. Product scope and non-critical cleanup may be
deferred explicitly.

## Scope

| Area | Required discipline |
| --- | --- |
| Core | No I/O, general-purpose allocation, recursion, or reentrant activation. Use one compile-time-bounded Activation Slot and bounded work. |
| Harness | After `open`, use Host-owned bounded storage for owner-loop state. Only `drive` advances Core; `offer` remains nonblocking and allocation-free. |
| Host Store | Route all access through the Storage Owner. Treat every durable value as hostile input; use bounded canonical payloads, indexed SQL, fixed-width identities, and prepare-commit-publish ordering. |
| Run Service | Keep queries pure, updates acknowledged and safely retriable under their operation-specific contracts, advancement fenced, content immutable, and Run Snapshots derived from committed facts. Implement both checked-in JSON schemas exactly, keep caller-defined Unicode Job Keys separate from shell-safe system IDs, and represent truncation only through a Content Reference preview. Never expose Harness generations or storage mechanics. |
| Adapters | Allocation is permitted only when bounded and fallible. External effects begin only after durable Attempt admission. Treat provider-owned envelopes as open and OnePage semantic conversions as closed. |
| CLI | Allocation is permitted only when bounded and fallible. Compose Run Service operations, derive Markdown only from normative JSON, sanitize hostile output, and own no Run or Session policy. |
| Tests and tooling | May allocate freely within host limits, but must exercise production bounds and failure behavior rather than replacing them. |

## Mandatory rules

### Keep the V1 architecture necessary

- Every production module, abstraction, pool, background owner, durable representation, and extension
  seam must support a current product guarantee, an external-effect boundary, or required release
  evidence. Hypothetical reuse is not a requirement.
- Prefer an established dependency or explicit supported-platform assumption for mechanisms that do not
  need OnePage policy. Do not wrap a dependency with a generalized framework for one implementation.
- Keep one owner and one representation for each responsibility. Delete or consolidate duplicated
  protocol state before adding another synchronization path.
- Add the narrowest complete vertical behavior through existing deep modules. Provider-neutral model
  data must not encode the current concrete tool inventory, but do not turn that data contract into a
  runtime registry, plugin surface, generic effect executor, scheduler, terminal framework, or
  maintenance subsystem.
- Keep the native Zig Host Runtime as the sole owner of Workflow Runs and the sole agent runtime. The
  protocol-independent Run Service is the public semantic boundary; the CLI only composes its
  operations and renders results. A Workflow Evaluator is a disposable Host-managed mechanism: it
  receives one immutable Evaluation Generation and returns one terminal evaluation outcome, but it
  must not own durable state, Sessions, providers, tools, permissions, recovery, or a durable DAG.
- A change that adds an architectural surface must name the current consumer, ownership boundary,
  resource bound, failure contract, and simpler alternative rejected. Cross-cutting additions require an
  accepted ADR. Missing justification is a standards violation.
- Prefer deleting superseded paths and issue requirements. Pre-release formats and internal APIs have no
  compatibility value unless the product contract explicitly grants it.

### Bound resources and work

- Give every queue, payload, read, record, retry count, output tail, recovery scan, and `drive` quantum
  an explicit bound.
- For every limit, name the distinct memory, storage, work, time, or semantic-cardinality resource it
  bounds. If another enforced limit strictly dominates it and it adds no independent guarantee, remove
  the redundant limit instead of choosing a larger threshold.
- Bound workflow source, arguments, Job count, blocked set, visible Results, JavaScript heap and stack,
  native bridge arena, protocol bytes, microtasks, diagnostics, evaluation time, and cumulative replay.
  Destroy the evaluator at every Job barrier; never retain a Promise resolver across durable waits.
- Apply structural-cardinality limits cumulatively to each complete strict value, canonicalize object
  keys at every depth, and apply visible-result byte limits to the complete Visibility Snapshot rather
  than independently to each member.
- Keep speculative reserve out of fixed resident structures. Every Activation Slot field and other
  per-capacity buffer must have a current production reader and writer; add future scratch when its
  consumer exists.
- Treat a new allocation topology as an architectural change, not a local implementation detail.
  Before introducing a new pool, cache, arena, spool, growable buffer, per-call or per-capacity
  allocation, file-backed scratch class, or allocation lifetime, discuss its owner, multiplier,
  maximum and ordinary occupancy, release boundary, failure behavior, and why an existing owner
  cannot serve it. Record that decision in the governing issue or design documentation before code
  makes the allocation part of the architecture.
- Assign every substantial resident resource to the narrowest stage that needs it. Name the capacity
  that multiplies it, whether it survives a wait, and why it cannot be shared or reconstructed. Active
  Capacity multiplies only resources that every concurrent semantic activation can actually retain.
- Optimize representations in multiplier order. Eliminate resident state proportional to Dormant
  Sessions before shrinking Active-Credit state, and shrink per-Active-Credit state before shared
  Host scratch. Report the incremental slope for each multiplier; a small isolated type is not evidence
  of a small system.
- Borrow reconstructible scratch only after its input is durable when the lifecycle permits it, release
  it before provider, subprocess, permission, or workflow waits, and give closure work priority over new
  admission. Do not preallocate one bundle of every possible parser, connection, stack, and subprocess
  resource for each Active Credit.
- Measure each stage's reservation, occupancy, queue depth, wait time, and high-water use separately.
  Keep fixed private stage permits out of the public configuration until a product consumer needs them.
- Stream or spool variable content directly into its durable or final bounded owner. Do not retain a
  complete value and then allocate another complete encoding solely to transfer it between modules.
- Once stored content is immutable, do not retain unused growth capacity. Prefer one bounded packed
  representation with validated offsets over repeated independently allocated lists when measurement
  shows that pointer, allocator-bin, padding, or locality costs are material. Inspect tagged-union size
  in every repeated resident collection, but do not add indirection to a singleton or rare path without
  measured whole-stage benefit.
- Destroy consumed resource-owning handles. Do not retain full closed objects until host shutdown to
  make duplicate use appear safe; stale use is a caller error unless a bounded handle table is itself a
  product requirement.
- Separate orchestration memory owned by OnePage from workload memory intentionally consumed by a
  model-requested process. Bound the former, report the latter, and do not introduce a workload memory
  sandbox merely to improve the harness headline.
- Reject or backpressure at capacity. Do not use allocator failure or the operating-system OOM killer as
  flow control.
- Before adding an architectural surface, sketch its maximum resident memory, durable bytes, CPU work,
  I/O, and recovery work.
- Keep a blocking external dependency behind a synchronous deep module when its population is already
  bounded and an asynchronous implementation would require a second lifecycle merely to save a small
  measured amount. Count its worker, stack, resolver, socket, descriptor, callback, and library-owned
  allocation state separately from the semantic capacity token that bounds the population.
- Distinguish graceful in-process shutdown from process-exit recovery. Never free Host state beneath a
  callback or worker that failed to join, and never claim a hard cancellation bound across an operating-
  system call the selected dependency cannot cancel. Durable recovery may make process termination safe;
  it does not make a partially completed in-process close correct.

### Preserve ownership and ordering

- Never reenter Core from a callback. One `drive` quantum completes before another Activation begins.
- Never deliver a provider, tool, or Job completion into a live workflow evaluation. Evaluations see
  one immutable run-local Visibility Snapshot and return a complete blocked set before exit.
- Keep Workflow Run and Session states distinct. Use `Blocked` for a Run awaiting Jobs, `Awaiting User`
  for a Session with an open supported Interaction Request, and `In-flight` for a Session with an admitted external
  Attempt. Do not expose an unqualified `waiting` state.
- Route external input through `offer` and apply it through `drive`.
- Keep `User`, Caller, Principal, Authority, and Authorization separate. Conversation role never grants
  execution authority. Bind permission freshness to one immutable request identity and exact descriptor,
  not an unrelated whole-Run revision.
- Make every mutating Run operation safe to retry after a lost acknowledgement. Require a Caller Run
  Key for creation, accept identical response replay, reject conflicting replay, and keep cancellation
  idempotent.
- Permit exactly one fenced Run driver. Inspection is a pure committed read and notification or rendering
  is never an authority-bearing update path.
- Treat `offer` acceptance as volatile custody. Only a committed Host Store transaction acknowledges a
  semantic fact.
- Prepare and validate complete transitions before commit. After commit, publish without new semantic
  validation, fallible capacity checks, or general-purpose allocation. Anything that can reject the
  prepared transition is resolved before commit; publication is an infallible assignment of prepared
  live state. If a platform operation still fails after commit, make the live owner unavailable and
  reconstruct from durable state.
- Make ownership, generation, identity, and capacity transitions explicit. Stale references fail closed.
- Treat Active Credit transfer as ownership transfer: one credit has exactly one Harness, admitted
  Attempt, or closure-handoff owner. Adapters and wake hints never retain a destroyed Harness.
- Acquire the bounded Workspace Effect Fence before admitting Bash or patch, retain it through
  terminal-evidence application, and reconstruct it from durable non-terminal effect Attempts before
  new admission. Never infer that arbitrary Bash is read-only.
- Never automatically redispatch an indeterminate Bash Attempt or force it into User escalation. Commit
  the Result, append its Tool Result to Conversation, and let the Agent choose its next action. Use a
  terminal `JobIndeterminate` only when the Session cannot safely reach a more reliable Outcome.
- Let a resource owner retain and validate its own fence. Do not make callers retrieve an ownership token
  from an object merely to pass it back to that object's methods.
- Serialize acquisition against destruction for top-level owning handles. A retained-child count protects
  existing children; it does not turn an unretained raw pointer into a concurrent weak reference.
- Return resource-owning modules through opaque pointer-stable handles. Do not expose copyable values
  containing mutexes, file handles, leases, or close authority. Harness Projections are data-only and
  reopen content only through the live owning Harness.
- Reserve `Projection` for generation-scoped Harness output. Public observation uses a committed
  `RunSnapshot`; it materializes Run-owned immutable content before Harness or evaluator teardown.
- Represent multi-phase recovery with a tagged state. Do not keep booleans beside cursor fields whose
  validity depends on those booleans.
- Keep every production query indexed and bounded in input bytes, rows, result bytes, temporary work,
  transaction work, and recovery work. Do not rely on an unbounded sort, aggregation, join, or temporary
  result spilling to disk.
- Serialize every complete Storage Owner request across the one SQLite connection; a transaction is the
  concurrency unit, not an individual SQLite call.
- No module except the Storage Owner may open SQLite, issue SQL, or retain a prepared statement. Host
  Runtime owns SQLite's process-global hard heap allowance. Treat page cache, lookaside, and statement
  memory as overlapping diagnostics within that total, and request envelopes and results as separate
  host reservations.

### Validate according to ownership and consequence

- Do not equate external with adversarial. State the trust assumption at each seam and validate only
  what is needed for framing, an owned resource, unambiguous semantic conversion, durable authority, or
  a consequential effect.
- Treat provider wire records as open envelopes. Within framing, byte, depth, and deadline bounds,
  ignore unknown object members and explicitly classified non-authoritative events or variants. Keep
  discriminated semantic unions closed by default: an unknown output item, content part, provider-side
  action, or terminal state is `unsupported_provider_output` unless the adapter has established that
  exact variant as safely ignorable. Do not assign a schema-cardinality limit to provider metadata
  unless it bounds an independently named resource.
- Make conversion into OnePage semantic state closed. Reject missing, duplicated, wrongly typed,
  inconsistent, or oversized fields that OnePage consumes to create a canonical fact. Never guess,
  coerce, or default ambiguous provider meaning.
- Keep OnePage-owned canonical, durable, authority-bearing, tool-input, interaction, and cross-process
  formats closed and exact. Trusting a provider does not grant provider metadata authority inside those
  formats.
- Add GREASE-like compatibility fixtures only at declared open provider seams: inject bounded unknown
  fields and explicitly ignorable variants with valid arbitrary values in different orders and chunk
  partitions, and prove the recognized canonical result is unchanged. Pair them with strict negative
  fixtures for every consumed field and must-understand semantic variant.

- Use fixed-width integers, explicit byte order, versioning, lengths, and checksums in OnePage-owned
  binary durable, cross-process, and network formats. Do not persist `usize`, native enums, pointers,
  or struct layout.
- Represent semantic facts as typed variants whose payload exposes only fields valid for that kind.
  Keep flat tagged records private to the canonical wire codec, and validate them before constructing
  a typed fact.
- Validate important records before writing and after reading. Validate consequential operations before
  admission and again before application.
- Initialize buffers deliberately before observation and scrub reusable storage before transfer to a new
  owner.
- Bind Authorization to the exact immutable Action and Workspace evidence that the User or bypass mode
  authorized.
- Treat workflow source and JavaScript-to-native conversion as hostile boundaries. Use source only,
  reject imports and ambient capabilities, reject accessors and proxies without invoking them, and
  make bridge mutation reentrancy-safe.

### Make failures explicit

- Assert programmer errors and impossible states. Return typed errors or Results for expected I/O,
  capacity, permission, corruption, timeout, and external-process failures.
- Handle every error. An intentionally ignored cleanup error needs an explanation at the narrowest
  shared wrapper that establishes why suppression is safe; callers of that wrapper need not repeat it.
- Test both positive and negative space: malformed records, stale generations, truncated input, capacity
  exhaustion, duplicates, replay, and every correctness-sensitive crash boundary. A crash claim requires
  immediate test-subprocess termination that bypasses ordinary error handling and deferred cleanup;
  returning an injected error is useful fault evidence but is not crash evidence.
- Never infer that an uncertain external effect did not happen because evidence is absent.

### Keep code legible

- Use the canonical domain terms in `CONTEXT.md`, including units and qualifiers where ambiguity is
  possible.
- Keep values and validation near their use. Prefer small scopes and deep modules that hide mechanics
  behind semantic interfaces.
- Use a named descriptor when a call carries independently optional fields or coupled choices. A typed
  context followed by a short canonical sequence of required fields is acceptable when their roles are
  unambiguous at the call site.
- Explain invariants and non-obvious safety arguments. Do not narrate syntax or restate the implementation.

## Review triggers, not gates

Review a function over roughly 70 lines, a line over roughly 100 columns, recursion, a large by-value
copy, or a dense compound condition. Keep it when the alternative has a weaker contract or worse
locality; otherwise simplify it.

OnePage does not require assertion quotas, equal-length names, an `else` for every `if`, pointer passing
above an arbitrary size, out-pointer construction, caller-prefixed helper names, or Zig implementations
for every development tool.

## Mechanical enforcement

`zig build check` is the canonical local and CI gate. It performs formatting and AST validation, runs
the complete native test graph in `ReleaseSafe`, and compiles the native deliverables in
`ReleaseSmall`.

Changes to the Workflow Evaluator, its private protocol, QuickJS dependency, or evaluator build graph
must additionally pass `zig build workflow-check`. That separate heavyweight gate owns the focused C
undefined-behaviour sanitizer, supported-platform leak detector, and deterministic mutation/property
targets; routine checks do not acquire those platform and runtime costs.

Changes to dependencies, build logic, persisted formats, or CI bootstrap must also pass the canonical
gate from a clean checkout with an empty cache. CI creates the cache layout explicitly and fetches the
pinned dependency graph in a named step before it compiles source, so bootstrap and product failures
remain distinguishable.

The Zig compiler is the primary linter and typechecker. A third-party analyzer is not a required V1
dependency. Add one only through a reviewed issue that identifies unique defects it catches, classifies
the existing diagnostics, pins the tool, and defines narrow blocking rules.

## Exceptions

An exception states the rule, why obeying it would reduce correctness or clarity, the retained resource
bound or safety argument, and the test or measurement that verifies the decision. Put the explanation
beside the code when it is local; use an ADR when it changes an architectural contract.

See `docs/research/linting-typechecking-setup.md` for the compiler-first tooling research behind the
mechanical gate.
