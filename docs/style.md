# OnePage engineering style

This document defines implementation discipline. [`CONTEXT.md`](../CONTEXT.md) owns language; [`ARCHITECTURE.md`](../ARCHITECTURE.md) owns system shape; [`VERIFICATION.md`](../VERIFICATION.md) owns evidence.

## Priorities

When rules compete, decide in this order:

1. correctness, durability, and authority;
2. bounded resource use;
3. architectural simplicity;
4. measured performance;
5. developer experience.

## One authority

Use [canonical relational authority](../ARCHITECTURE.md#canonical-relational-authority). Keep loaded views bounded and disposable; treat measured derived indexes as rebuildable acceleration. Test OnePage's semantic transactions through SQLite rather than recreating its locking, journaling or pager recovery. Delete superseded formats and paths; unreleased V1 databases and internal APIs have no compatibility obligation.

## Design and implementation planning

Follow [AGENTS.md](../AGENTS.md#establish-the-current-contract) for design readiness, normative ownership and implementation slices. Exact schema and encoding mechanics may be selected during implementation when behavior is settled.

## Enforce contracts at their owner

Every durable execution fact must serve recovery or a concrete product promise. Diagnostic usefulness alone does not justify permanent failed-try history. Make an adapter's physical delivery/cleanup guarantees enforceable at its interface; the Host owns retry, semantic acceptance and recovery. Preserve uncertainty about external truth, including billing and subprocess effects. Use the [execution guarantees](architecture/execution.md#required-execution-and-recovery-guarantees) and [diagnostic contract](../ARCHITECTURE.md#local-diagnostics-and-application-state) for the specific obligations.

## Freeze at the boundary

Bind semantics at their consumer: [model requests](../ARCHITECTURE.md#sparse-context-and-exact-model-requests) freeze exact model-visible inputs; [Action admissions](../ARCHITECTURE.md#tools-and-permission) freeze permission provenance. Replacement Attempts reuse admitted semantics. Late-bind credentials and transport mechanisms. Keep context components typed and closed; use a new Operation when model-visible semantics change.

## Preserve causality

Use explicit Session, Turn, Operation, Attempt and cause identities; numeric identity bits and timestamps do not establish parentage or order. Follow [model-output admission](../ARCHITECTURE.md#model-output-and-multiple-tool-calls) for atomic child creation and call-ordered results. Keep Workflow Run state separate from Session and Turn state.

## External effects

Implement [execution and settlement](architecture/execution.md#host-runtime-execution-and-settlement) through the existing owners. Prepare exact immutable descriptors, reserve custody, commit Attempt admission, then release its one-shot Dispatch Permit. Retain custody through physical cleanup and reject stale identities after reuse. Reconcile uncertainty according to the effect.

Keep transactions closed during external effects and delivery. The only private scratch-write read-transaction exceptions are [inspection capture](architecture/workflows.md#run-interface) and [workflow visibility metadata](architecture/workflows.md#workflow-runs); result-body materialization follows the latter transaction.

Every semantic mutation follows:

```text
bounded syntax ──► BEGIN IMMEDIATE ──► bounded Decision Snapshot
               ──► pure total classification ──► fixed mutation
               ──► exact row counts ──► COMMIT ──► release consequence
```

Use the same bounded loader and classifier for inspection and advancement. A post-commit preparation failure records evidence for the admitted Attempt rather than erasing authority. Keep notifications as rescan hints; use committed facts for semantic acknowledgement. [Run service](architecture/workflows.md#run-interface) owns fairness between controls, settlement and inspection; [workflow discovery](architecture/workflows.md#workflow-runs) and [model retry](architecture/execution.md#model-retries-and-inactivity) own their distinct polls.

## Deep modules

| Owner | Responsibility |
| --- | --- |
| Storage Owner | SQLite, canonical transactions, bounded content reads/writes, and no domain-policy delegation to callers. |
| Host Runtime | Expose the narrow typed Run API; derive Turn Condition; drive legal quanta through the Storage Owner, one multiplexed I/O Reactor, temporary Action executors, and content-free custody. |
| Provider adapter | Authentication, derived replay-input projection, request lowering, transport grammar, and direct streaming between scratch descriptors and the provider; no SQLite access or semantic admission. |
| Action adapter | Execute one immutable admitted Bash or Edit Attempt under temporary custody and return sealed evidence; select no permission, retry, or recovery policy. |
| Edit module | Own literal matching, streamed preparation, file mutation and reconciliation observations behind the Action adapter. Use no SQLite or provider credentials; leave admission and canonical outcomes to the Host. Run in-process with bounded service turns and owned reusable buffers. |
| Workflow Evaluator | Evaluate one immutable Generation and return one terminal outcome; retain nothing across a durable barrier. |

An interface is deep when callers provide semantic intent and cannot construct the owner's internal facts, storage rows, lifecycle phases, or capabilities.

## Bounds and memory

- Give every resident allocation, per-event computational workload, external effect, evaluator run, and concurrent execution population an explicit dominating bound. Stream durable collections and variable content rather than imposing cardinality caps solely to protect memory.
- Name the resource each limit protects. Remove a limit that adds no guarantee beyond a stricter byte, work, depth, or time bound.
- Treat a new pool, cache, arena, spool, growable buffer, per-call allocation, or allocation lifetime as an architectural change.
- Before implementation, record its owner, multiplier, maximum, ordinary occupancy, release boundary, failure behaviour, and why an existing owner cannot serve it.
- Assign substantial resident memory to the narrowest stage that needs it and release it before durable waits when reconstruction is possible.
- Keep payload and speculative reserve out of Active Credit and per-capacity structures.
- Stream or window variable content rather than retaining two complete representations.
- Backpressure before allocation failure. Capacity exhaustion is not a semantic Session state.
- Separate OnePage orchestration memory from model-requested workload memory.
- Report whole-process RSS and the slope of every population independently.

## Constraint evidence

Use the [accepted vocabulary](../CONTEXT.md#constraints) from [#88](https://github.com/DivyanshGolyan/onepage/issues/88#issuecomment-5523637847). Each constraint belongs to the deepest owner of its protected resource or exact consumer; add no central registry, generic enforcement engine or universal exhaustion result. “Bounded” names a derivation or Resource Budget and its failure behavior.

| Kind | Required justification |
| --- | --- |
| Invariant | Authoritative owner, construction, violation result and invariant test. |
| Fixed Boundary | Protected operation, unit/scope, exact derivation or source, enforcement point, typed failure and boundary test. |
| Resource Budget | Owner, unit/scope, accounting/release, configuration/default, exhaustion, population multiplier and measurement. |
| Verification Target | Workload, metric, pass condition and measurement method; no runtime enforcement. |

The [combined matrix](architecture/resources.md#v1-limit-matrix) supplies subsequently accepted policy defaults and distinguishes their required qualification from existing measurements. An unmeasured accepted default is not a demonstrated production result. Delete, consolidate or demote unsupported numbers; when an old guard still protects a fixed representation, replace and verify that representation before removing the guard. Preserve recursion, allocation, representability and atomic-publication safety. Do not silently truncate semantic input or partially commit an atomic admission.

## Validation and trust

- State the trust assumption at each external seam.
- Validate strict syntax, owned resources, consumed semantic fields, durable authority, and consequential effects.
- Treat provider object records as open: preserve unknown fields inside known records while ignoring them semantically.
- Treat consumed fields and must-understand semantic unions as closed: reject missing, duplicate, contradictory, wrongly typed, unsupported, or oversized meaning.
- Keep OnePage-owned durable, User Message, permission, tool-input, cross-process, and authority-bearing formats closed and exact.
- Validate important records before write and after read.
- Trust the configured local machine and SQLite once their documented boundary has accepted canonical data; do not add redundant revalidation solely to distrust them.

## Ownership and lifetime

- Return resource-owning modules through opaque pointer-stable handles.
- Destroy consumed handles rather than retaining tombstones for invalid reuse.
- Never expose SQLite connections, prepared statements, evaluator frames, provider handles, or internal advancement generations through product interfaces.
- Let one owner access each libcurl easy handle, file descriptor, subprocess, SQLite connection, and mutable writer.
- Distinguish graceful in-process shutdown from process-exit recovery. Never free state beneath a live effect owner or callback that has not joined.
- Treat notifications and wakeups as hints. Only committed rows acknowledge semantic input.

## Failure discipline

- Assert programmer errors and impossible states.
- Return typed failures for expected capacity, permission, I/O, timeout, corruption, provider, and process outcomes.
- Handle every error. Explain intentionally ignored cleanup failures once at the narrowest shared wrapper.
- Test malformed input, exact boundaries, replay, stale identity, conflicts, exhaustion, and every semantically distinct crash point.
- Crash evidence terminates a fixture process immediately and verifies a fresh reopen; returning an injected error is fault evidence, not crash evidence.
- Report interrupted validation precisely.

## Legibility

- Use the canonical terms in `CONTEXT.md`.
- Co-locate a concept's state, invariants, validation, and transition code.
- Prefer deep modules and typed descriptors over generic command buses, nullable field combinations, or public wire-shaped structs.
- Explain non-obvious invariants and safety arguments; do not narrate syntax.
- Review unusually long functions, lines, large copies, recursion, and dense conditions. Keep them only when the alternative weakens the contract or locality.

## Mechanical gates

Use [Canonical gates](../VERIFICATION.md#canonical-gates), with command definitions in `build.zig`. The Zig compiler is the primary linter and typechecker. Add another analyzer only when a reviewed issue identifies unique defects, pins the tool and defines blocking diagnostics.

## Exceptions

An exception names the rule, the current consumer, why compliance would reduce correctness or clarity, the retained bound or safety argument, and its verification. Put local exceptions beside the code; use an ADR for architectural exceptions.
