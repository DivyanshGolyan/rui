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

## Design and implementation planning

During the design phase, normative documents own accepted requirements and open decision/research issues own unanswered questions. Amend the owning document when a decision is accepted; retain historical discussions and experiments as evidence. Do not maintain speculative implementation tickets as another copy of the design. Once the V1 contract is aligned, create bounded implementation slices with links to the contract and concrete verification. Exact schema/encoding mechanics may be chosen during implementation where behavior is already determined. A superseded planning ticket is not completed implementation.

## Enforce contracts at their owner

An adapter owns delivery and cleanup for one physical execution; the Host owns retry policy, semantic acceptance and durable recovery. Make local lifecycle guarantees enforceable and test them through that interface instead of retaining historical records to compensate for ambiguous delivery. Preserve explicit uncertainty where an owner cannot guarantee external truth, including remote billing and subprocess effects.

Every durable execution fact must name a recovery consumer or concrete product promise. Diagnostic usefulness alone does not require permanent failed-try history. Preserve consumed allowances, exact admitted inputs and authorization, accepted results and provider continuation; preserve the accepted recovery traces when implementing Operation-owned current facts and immutable final results. See [required execution guarantees](../ARCHITECTURE.md#required-execution-and-recovery-guarantees).

Keep diagnostic history independent of execution authority. Default local summaries and explicit detailed capture follow the [local diagnostic contract](../ARCHITECTURE.md#local-diagnostics-and-application-state); expiry or logging failure must not change recovery or accepted meaning. This is separate from the deferred retention of canonical application state.

## Freeze at the boundary

- Record persistent model-visible defaults as sparse Session Context Revisions.
- Keep supplied runtime information in its instruction/tool records, exact permission provenance on Action admission, and any retained execution limit on the scope it constrains. Do not resolve a separate Turn Contract or generic runtime-facts bag at message admission.
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
- Reserve one content-free in-memory Physical Custody record before opening the dispatching write transaction; its occupancy is the Active Credit, not a second allocation. Use the startup-sized table and ordinary bounded scans, without a duplicate SQLite slot table, free list, or active-record index. Return rolled-back reservations and retain occupied records through physical cleanup; exact identity checks reject stale events after reuse.
- Commit Attempt admission before physical launch.
- Return a one-shot Dispatch Permit only to the invocation that observed the Attempt commit; never reconstruct or store it.
- Keep SQLite transactions closed during request materialization, network or subprocess I/O, filesystem mutation, and response streaming. The read-only capture exceptions are inspection writes to private report scratch under [ADR-0024](adr/0024-capture-run-inspection-before-delivery.md) and workflow writes to private visibility metadata under [Workflow Runs](../ARCHITECTURE.md#workflow-runs). Result-body materialization and network delivery remain outside those transactions.
- Stream variable content through fixed borrowed windows to dynamically charged, immediately unlinked scratch.
- Parse complete output only after terminal seal in the one shared serial validation/import workspace.
- Treat Execution Evidence as transient observed evidence and the Operation-owned Resolution value as immutable selected meaning.
- Normally commit content, the Operation's previously absent Resolution value and required final evidence, and semantic consequences atomically. Retryable model evidence instead atomically updates current retry facts and eligibility without a Resolution. Never reset consumed allowance or reuse an Attempt identity.
- Reconcile according to effect: model retry with explicit duplicate risk, no automatic Bash replay, exact edit preimage/postimage observation.
- Keep User role, Caller identity, Principal, Authority, Authorization, and Permission Mode separate.
- Do not add a Workspace fence, quiescence promise, global Action serialization, or isolation claim. Bash and Edit share the closed Action lifecycle and may execute concurrently under Active Capacity.

Every semantic mutation follows:

```text
bounded syntax ──► BEGIN IMMEDIATE ──► bounded Decision Snapshot
               ──► pure total classification ──► fixed mutation
               ──► exact row counts ──► COMMIT ──► release consequence
```

The same bounded loader and classifier serve inspection and advancement. A post-commit preparation failure records evidence for the admitted Attempt; it cannot erase durable authority. Retry eligibility uses only the bounded SQLite poll. Other intra-Host wakes may request a rescan of live Physical Custody, but never carry semantic facts or trigger delayed retries. Sleep when no work or required deadline/poll is due; do not add an empty-custody-table scan timer. Workflow discovery uses the accepted asynchronous pull loop: check again after evaluation cleanup, or after one shared one-second idle timer when no workflow is eligible. It introduces no per-Run timer or completion hook; query work still needs bounded ownership and measured service time. Before starting another queued inspection, give ready controls and ordinary settlement/advancement work bounded turns through the existing driving path, without draining either class indefinitely. Encode and escape report fields through fixed-size windows and block writes; permitted strings may span windows. Keep a capture already in progress atomic as a read view; no extra scheduler or reader is implied.

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

The [combined matrix](../ARCHITECTURE.md#v1-limit-matrix) supplies subsequently accepted policy defaults and distinguishes their required qualification from existing measurements. An unmeasured accepted default is not a demonstrated production result. Delete, consolidate or demote unsupported numbers; when an old guard still protects a fixed representation, replace and verify that representation before removing the guard. Preserve recursion, allocation, representability and atomic-publication safety. Do not silently truncate semantic input or partially commit an atomic admission.

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

`zig build check` is the canonical local and CI gate. It formats and validates source, runs the native ReleaseSafe test graph, and compiles native deliverables in ReleaseSmall.

Changes to the Workflow Evaluator, private evaluator protocol, QuickJS dependency, or evaluator build graph additionally run `zig build workflow-check`. Dependency, build, persisted-format, and CI-bootstrap changes also run the canonical gate from a clean empty cache.

The Zig compiler is the primary linter and typechecker. Add another analyzer only when a reviewed issue identifies unique defects, pins the tool, and defines its blocking diagnostics.

## Exceptions

An exception names the rule, the current consumer, why compliance would reduce correctness or clarity, the retained bound or safety argument, and its verification. Put local exceptions beside the code; use an ADR for architectural exceptions.
