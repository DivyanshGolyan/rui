# OnePage engineering style

This document defines the implementation rules for OnePage. Product semantics remain authoritative in
`PRODUCT.md`, `ARCHITECTURE.md`, `VERIFICATION.md`, accepted ADRs, and `CONTEXT.md`.

The rules adapt TigerStyle to OnePage's bounded native architecture. They are scoped contracts, not
quotas for line length, assertion count, pointer use, or helper naming.

## Priorities

When rules compete, decide in this order:

1. correctness, durability, and security;
2. bounded resource use;
3. measured performance;
4. developer experience.

Do not defer a known defect in the first two priorities. Product scope and non-critical cleanup may be
deferred explicitly.

## Scope

| Area | Required discipline |
| --- | --- |
| Core | No I/O, general-purpose allocation, recursion, or reentrant activation. Use one exact Activation Slot and bounded work. |
| Harness | After `open`, use caller-owned bounded storage for owner-loop state. Only `drive` advances Core; `offer` remains nonblocking and allocation-free. |
| Session storage | Treat every durable byte as hostile input. Use bounded records, fixed-width fields, prepare-commit-publish ordering, and valid-prefix recovery. |
| Adapters | Allocation is permitted only when bounded and fallible. External effects begin only after durable Attempt admission. |
| CLI | Allocation is permitted only when bounded and fallible. Sanitize hostile output and keep Session policy inside Harness. |
| Tests and tooling | May allocate freely within host limits, but must exercise production bounds and failure behavior rather than replacing them. |

## Mandatory rules

### Bound resources and work

- Give every queue, payload, read, record, retry count, output tail, recovery scan, and `drive` quantum
  an explicit bound.
- Reject or backpressure at capacity. Do not use allocator failure or the operating-system OOM killer as
  flow control.
- Before adding an architectural surface, sketch its maximum resident memory, durable bytes, CPU work,
  I/O, and recovery work.
- Keep logical delegation depth independent of resident call-stack or ancestry traversal. Execution,
  recovery, parsing, and topology traversal are iterative and bounded.

### Preserve ownership and ordering

- Never reenter Core from a callback. One `drive` quantum completes before another Activation begins.
- Route external input through `offer` and apply it through `drive`.
- Treat `offer` acceptance as volatile custody. Only a committed Session WAL transaction acknowledges a
  semantic fact.
- Prepare and validate complete transitions before commit. After commit, publish without new semantic
  validation or general-purpose allocation.
- Make ownership, generation, identity, and capacity transitions explicit. Stale references fail closed.

### Treat boundaries as hostile

- Use fixed-width integers, explicit byte order, versioning, lengths, and checksums in durable,
  cross-process, and network formats. Do not persist `usize`, native enums, pointers, or struct
  layout.
- Validate important records before writing and after reading. Validate consequential operations before
  admission and again before application.
- Initialize buffers deliberately before observation and scrub reusable storage before transfer to a new
  owner.
- Bind Authorization to the exact immutable Action and Workspace evidence that the user or bypass mode
  authorized.

### Make failures explicit

- Assert programmer errors and impossible states. Return typed errors or Results for expected I/O,
  capacity, permission, corruption, timeout, and external-process failures.
- Handle every error. An intentionally ignored cleanup error needs a local explanation and the narrowest
  possible suppression.
- Test both positive and negative space: malformed records, stale generations, truncated input, capacity
  exhaustion, duplicates, replay, and every correctness-sensitive crash boundary.
- Never infer that an uncertain external effect did not happen because evidence is absent.

### Keep code legible

- Use the canonical domain terms in `CONTEXT.md`, including units and qualifiers where ambiguity is
  possible.
- Keep values and validation near their use. Prefer small scopes and deep modules that hide mechanics
  behind semantic interfaces.
- Use named option or descriptor structures when multiple arguments share a type or represent identities,
  lengths, offsets, generations, or optional values.
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
