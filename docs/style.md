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
| Harness | After `open`, use caller-owned bounded storage for owner-loop state. Only `drive` advances Core; `offer` remains nonblocking and allocation-free. |
| Host Store | Route all access through the Storage Owner. Treat every durable value as hostile input; use bounded canonical payloads, indexed SQL, fixed-width identities, and prepare-commit-publish ordering. |
| Adapters | Allocation is permitted only when bounded and fallible. External effects begin only after durable Attempt admission. |
| CLI | Allocation is permitted only when bounded and fallible. Sanitize hostile output and keep Session policy inside Harness. |
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
- Add the narrowest complete vertical behavior through existing deep modules. Do not introduce a
  scheduler, registry, plugin surface, generic tool layer, terminal framework, or maintenance subsystem
  for a single consumer.
- A change that adds an architectural surface must name the current consumer, ownership boundary,
  resource bound, failure contract, and simpler alternative rejected. Cross-cutting additions require an
  accepted ADR. Missing justification is a standards violation.
- Prefer deleting superseded paths and issue requirements. Pre-release formats and internal APIs have no
  compatibility value unless the product contract explicitly grants it.

### Bound resources and work

- Give every queue, payload, read, record, retry count, output tail, recovery scan, and `drive` quantum
  an explicit bound.
- Reject or backpressure at capacity. Do not use allocator failure or the operating-system OOM killer as
  flow control.
- Before adding an architectural surface, sketch its maximum resident memory, durable bytes, CPU work,
  I/O, and recovery work.

### Preserve ownership and ordering

- Never reenter Core from a callback. One `drive` quantum completes before another Activation begins.
- Route external input through `offer` and apply it through `drive`.
- Treat `offer` acceptance as volatile custody. Only a committed Host Store transaction acknowledges a
  semantic fact.
- Prepare and validate complete transitions before commit. After commit, publish without new semantic
  validation, fallible capacity checks, or general-purpose allocation. Anything that can reject the
  prepared transition is resolved before commit; publication is an infallible assignment of prepared
  live state. If a platform operation still fails after commit, make the live owner unavailable and
  reconstruct from durable state.
- Make ownership, generation, identity, and capacity transitions explicit. Stale references fail closed.
- Let a resource owner retain and validate its own fence. Do not make callers retrieve an ownership token
  from an object merely to pass it back to that object's methods.
- Serialize acquisition against destruction for top-level owning handles. A retained-child count protects
  existing children; it does not turn an unretained raw pointer into a concurrent weak reference.
- Return resource-owning modules through opaque pointer-stable handles. Do not expose copyable values
  containing mutexes, file handles, leases, or close authority. Public Projections are data-only and
  reopen content through the live owning Harness.
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

### Treat boundaries as hostile

- Use fixed-width integers, explicit byte order, versioning, lengths, and checksums in durable,
  cross-process, and network formats. Do not persist `usize`, native enums, pointers, or struct
  layout.
- Represent semantic facts as typed variants whose payload exposes only fields valid for that kind.
  Keep flat tagged records private to the canonical wire codec, and validate them before constructing
  a typed fact.
- Validate important records before writing and after reading. Validate consequential operations before
  admission and again before application.
- Initialize buffers deliberately before observation and scrub reusable storage before transfer to a new
  owner.
- Bind Authorization to the exact immutable Action and Workspace evidence that the user or bypass mode
  authorized.

### Make failures explicit

- Assert programmer errors and impossible states. Return typed errors or Results for expected I/O,
  capacity, permission, corruption, timeout, and external-process failures.
- Handle every error. An intentionally ignored cleanup error needs an explanation at the narrowest
  shared wrapper that establishes why suppression is safe; callers of that wrapper need not repeat it.
- Test both positive and negative space: malformed records, stale generations, truncated input, capacity
  exhaustion, duplicates, replay, and every correctness-sensitive crash boundary.
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

The Zig compiler is the primary linter and typechecker. A third-party analyzer is not a required V1
dependency. Add one only through a reviewed issue that identifies unique defects it catches, classifies
the existing diagnostics, pins the tool, and defines narrow blocking rules.

## Exceptions

An exception states the rule, why obeying it would reduce correctness or clarity, the retained resource
bound or safety argument, and the test or measurement that verifies the decision. Put the explanation
beside the code when it is local; use an ADR when it changes an architectural contract.

See `docs/research/linting-typechecking-setup.md` for the compiler-first tooling research behind the
mechanical gate.
