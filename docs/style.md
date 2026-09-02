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

- Persist canonical domain relationships directly in SQLite.
- Derive Turn Condition, Session dormancy, Run state, and observer views from canonical rows.
- Treat a derived index as rebuildable acceleration, never authority.
- Keep loaded Session, Turn, and Decision Snapshot values bounded and disposable.
- Delete superseded formats and paths. V1 has no compatibility obligation to unreleased databases or internal APIs.
- Trust SQLite for transactions, locking, journaling, and pager recovery. Test OnePage's semantic transactions rather than recreating SQLite's machinery.

A change violates this rule when it adds a Session Ledger, reducer image, continuation blob, cached phase, shadow frontier, second durable store, or resident graph that can disagree with canonical rows.

## Freeze at the boundary

- Record persistent model-visible defaults as sparse Session Context Revisions.
- Resolve one immutable Turn Contract when ordinary User input starts a Turn.
- Bind one immutable Model Request Manifest to each model Operation.
- Reuse that manifest for replacement Attempts.
- Late-bind only credentials, transport handles, sockets, and other non-semantic mechanisms.
- Create a new Operation when model-visible semantics change.

Keep context components typed and closed for current consumers. Do not store a monolithic mutable system prompt or introduce a generic component registry.

## Preserve causality

- Use explicit Session, Turn, Operation, Attempt, and cause identities.
- Never infer kind, parentage, or order from numeric identity bits or timestamp order.
- Admit a complete model response and its ordered Tool Calls atomically.
- Give each Tool Call one child Action Operation and stable ordinal.
- Order Tool Results for the next model request by call ordinal, not completion time.
- Start the next model Operation only after every child Tool Call has a Resolution and model-visible Tool Result.
- Keep Workflow Run state separate from Session and Turn state.

## External effects

- Prepare and validate exact immutable dispatch descriptors before permission or Attempt admission; validate streamed evidence after its terminal seal.
- Reserve one content-free Physical Custody record before opening the dispatching write transaction; its occupancy is the Active Credit, not a second allocation.
- Commit Attempt admission before physical launch.
- Return a one-shot Dispatch Permit only to the invocation that observed the Attempt commit; never reconstruct or store it.
- Keep SQLite transactions closed during request materialization, network or subprocess I/O, filesystem mutation, and response streaming.
- Stream variable content through fixed borrowed windows to dynamically charged, immediately unlinked scratch.
- Parse complete output only after terminal seal in the one shared serial validation/import workspace.
- Treat Completion as observed evidence and Resolution as selected meaning.
- Normally commit content, the single Completion, Resolution, and semantic consequence atomically. Permit Completion without Resolution only for a retryable model result committed with immutable retry eligibility.
- Reconcile according to effect: model retry with explicit duplicate risk, no automatic Bash replay, exact patch preimage/postimage observation.
- Keep User role, Caller identity, Principal, Authority, Authorization, and Permission Mode separate.
- Do not add a Workspace fence, quiescence promise, or isolation claim. Treat the serial Patch lane as a private V1 implementation choice.

Every SQLite command follows:

```text
bounded syntax ──► BEGIN IMMEDIATE ──► bounded Decision Snapshot
               ──► pure total classification ──► fixed mutation
               ──► exact row counts ──► COMMIT ──► release consequence
```

The same bounded loader and classifier serve inspection and advancement. A post-commit preparation failure records evidence for the admitted Attempt; it cannot erase durable authority. Retry eligibility uses only the bounded SQLite poll. Other intra-Host wakes may request a rescan of live Physical Custody, but never carry semantic facts or trigger delayed retries.

## Deep modules

| Owner | Responsibility |
| --- | --- |
| Storage Owner | SQLite, canonical transactions, bounded content reads/writes, and no domain-policy delegation to callers. |
| Host Runtime | Derive Turn Condition and advance legal quanta through the Storage Owner, one multiplexed model/Bash I/O Reactor, one private serial Patch lane, and content-free custody. |
| Provider adapter | Authentication, request lowering, transport grammar, and direct streaming between scratch descriptors and the provider; no SQLite access or semantic admission. |
| Action adapter | Execute one immutable admitted Bash or patch Attempt and return sealed evidence; select no permission, retry, or recovery policy. |
| Run Service | Pure inspection, acknowledged updates, bounded advancement, cancellation, and immutable content reads. |
| Workflow Evaluator | Evaluate one immutable Generation and return one terminal outcome; retain nothing across a durable barrier. |

An interface is deep when callers provide semantic intent and cannot construct the owner's internal facts, storage rows, lifecycle phases, or capabilities.

## Bounds and memory

- Give every payload, queue, scan, retry, output, context, evaluator run, and execution population an explicit dominating bound.
- Name the resource each limit protects. Remove a limit that adds no guarantee beyond a stricter byte, work, depth, or time bound.
- Treat a new pool, cache, arena, spool, growable buffer, per-call allocation, or allocation lifetime as an architectural change.
- Before implementation, record its owner, multiplier, maximum, ordinary occupancy, release boundary, failure behaviour, and why an existing owner cannot serve it.
- Assign substantial resident memory to the narrowest stage that needs it and release it before durable waits when reconstruction is possible.
- Keep payload and speculative reserve out of Active Credit and per-capacity structures.
- Stream or window variable content rather than retaining two complete representations.
- Backpressure before allocation failure. Capacity exhaustion is not a semantic Session state.
- Separate OnePage orchestration memory from model-requested workload memory.
- Report whole-process RSS and the slope of every population independently.

## Validation and trust

- State the trust assumption at each external seam.
- Validate strict syntax, owned resources, consumed semantic fields, durable authority, and consequential effects.
- Treat provider object records as open: ignore bounded unknown metadata.
- Treat consumed fields and must-understand semantic unions as closed: reject missing, duplicate, contradictory, wrongly typed, unsupported, or oversized meaning.
- Keep OnePage-owned durable, interaction, tool-input, cross-process, and authority-bearing formats closed and exact.
- Validate important records before write and after read.
- Trust the configured local machine and SQLite once their documented boundary has accepted canonical data; do not add redundant revalidation solely to distrust them.

## Ownership and lifetime

- Return resource-owning modules through opaque pointer-stable handles.
- Destroy consumed handles rather than retaining tombstones for invalid reuse.
- Never expose SQLite connections, prepared statements, evaluator frames, provider handles, or internal advancement generations through product interfaces.
- Let one owner access each libcurl easy handle, file descriptor, subprocess, SQLite connection, and mutable writer.
- Distinguish graceful in-process shutdown from process-exit recovery. Never free state beneath an execution lane or callback that has not joined.
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

`zig build check` is the canonical local and CI gate. It formats and validates source, runs the native ReleaseSafe test graph, and compiles native deliverables in ReleaseSmall.

Changes to the Workflow Evaluator, private evaluator protocol, QuickJS dependency, or evaluator build graph additionally run `zig build workflow-check`. Dependency, build, persisted-format, and CI-bootstrap changes also run the canonical gate from a clean empty cache.

The Zig compiler is the primary linter and typechecker. Add another analyzer only when a reviewed issue identifies unique defects, pins the tool, and defines its blocking diagnostics.

## Exceptions

An exception names the rule, the current consumer, why compliance would reduce correctness or clarity, the retained bound or safety argument, and its verification. Put local exceptions beside the code; use an ADR for architectural exceptions.
