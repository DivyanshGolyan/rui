# OnePage verification contract

This document maps each public architectural claim to required evidence. A claim is not complete because a type or comment expresses it; the production composition and its failure boundaries must demonstrate it.

## Claim matrix

| Claim | Required evidence |
| --- | --- |
| One actual bounded Activation Slot | Compile-time size, alignment, named-component accounting, absence of filler, and `<= 32 KiB` assertions over the production slot type; startup pool accounting from `@sizeOf(ActivationSlot)`. |
| Core State is independent of slot layout | Canonical codec vectors, unknown-version rejection, and restore into differently poisoned slots with identical semantic outcomes. |
| No Core activation allocation | Compile-time rejection of allocator-bearing parameter and storage types across every lifecycle method, direct review of Core dependencies, plus complete activate, transition, suspend, restore, and reuse tests. |
| Native semantic invariants | Randomized accepted and rejected transition traces with typed outcomes, rejection-state preservation, semantic observations, deterministic canonical encoding, and poisoned-slot restoration. |
| Session Ledger is sole semantic authority | Recovery from complete ordered canonical transactions with rebuildable indexes absent, stale, corrupt, or behind. |
| Host Store transitions are atomic | Termination and injected SQLite failures around multi-table transactions expose either the previous complete Session sequence or the complete new sequence, never enclosed partial facts. |
| Immutable content is durable before reference | Crash injection before content sync, after content sync, before Host Store commit, and after commit; committed transitions never resolve to absent content. |
| Prepare, commit, publish ordering | Failure injection at every semantic publication point, including semantic-index capacity, proves that every rejection precedes commit and post-commit publication is infallible assignment; otherwise the owner becomes unavailable and fresh `open` reconstructs. |
| One Storage Owner is the durable gateway | A host-level lifetime-lock test excludes a second process; a process-level test excludes a second SQLite-owning `HostRuntime`; dependency plus runtime tests prove Core, Harness, adapters, workers, and CLI cannot open SQLite directly. A request-serialization test proves two Harnesses cannot interleave one connection transaction. |
| Adapter evidence is not a second authority | Result content and immutable Completion Inbox evidence survive lost notifications and process termination; every envelope requires the epoch admitted with its Attempt and the evidence kind selected by the Attempt's typed descriptor; terminal commitment atomically sets `consumed_by_sequence`; recovery scans only pending rows; truly irrelevant evidence is not persisted; valid late evidence for a superseded Attempt is associated with the first terminal Result sequence; the 4,096-row pending bound is enforced at insertion; and changed epoch, kind, or Result evidence for the same Attempt fails closed. |
| Session publication has one replayable value | Applying the same canonical transaction live and after decode produces equal `ResidentState`; post-commit publication is one assignment and Conversation has no second reconstruction reducer. |
| Harness lifetime is structural | `Harness.open` returns an opaque stable handle; duplicate close is non-destructive, runtime close remains busy while any lease is live, and data-only Projections can open content only through their originating live Harness generation. |
| Approval Required is not Authorization | Ledger inspection and restore tests prove pending `ask` state has one exact Approval Required transition and no Authorization until a matching allow or deny Permission Decision commits. |
| Control settlement cannot strand accepted work | Shutdown denies pending Approval Required state; cancellation and shutdown reconcile durable Completion Inbox evidence until every accepted Operation is terminal or indeterminate. |
| Known provider failure is terminal | A dispatch error after Attempt admission produces one durable provider-failure Result; repeated restore regenerates failure without admitting a replacement Attempt. |
| Ingress custody is not durable acknowledgement | Crash after `offer` acceptance but before Host Store commit loses no acknowledged fact: Completion is rediscovered, an `ask` decision is requested again, an uncommitted Task remains absent, and cancellation remains unapplied. |
| No silent Bash replay | Process termination after possible command execution always produces an indeterminate Result without redispatch. |
| Patch reconciliation is honest | Exact preimage, postimage, and divergent Workspace fixtures plus concurrent replacement, symlink, and stale-Authorization cases. |
| Authorization binds exact execution | Descriptor-digest tests cover tool kind, bytes, Workspace, working directory, environment authority, timeout, generation, and preimage. |
| Authoritative bindings are collision-resistant and typed | Domain-separated SHA-256 vectors and type-level mismatch tests cover descriptors, Patch Intent, preimage, postimage, Results, Completions, and ledger records; absence is represented separately from digest bytes. |
| Dormant population does not scale active memory | Increase Dormant Sessions while holding every resident pool fixed; report RSS tolerance and disk growth separately. |
| SQLite remains within its host allowance | Process-global current and high-water heap stay below the Host Runtime hard limit for the 32, 64, and 128 KiB cache profiles at increasing Session populations. Page-cache, lookaside, and statement counters are reported as overlapping diagnostics; request and result reservations are reported separately. |
| Storage work is bounded | Indexed-query plans and worst-case admitted inputs prove each Host Store statement and result remains bounded. |
| Active capacity is startup-fixed | Configure zero, one, exactly full, and one beyond full; prove Slot storage is reserved once, opening beyond capacity acquires no Session ownership, temporary exhaustion does not allocate or spin, and closure work outranks new admission. |
| Output remains bounded in RAM | Adversarial model and command outputs larger than memory tails, exact durable spool recovery, and steady resident-memory measurements. |
| Ownership and slot reuse are fenced | Late, duplicate, prior-epoch, future-epoch, stale-window, and generation-exhaustion tests across scrubbed slot reuse. |
| Terminal output is safe | Control, ANSI, OSC, hyperlink, clipboard, carriage-return, backspace, fragmented UTF-8, and oversized-line fixtures. |

## Required test seams

The highest product seam is the real CLI against a temporary Git repository and deterministic adapters. It proves that a user can create and resume a Session, supply a selected provider for model work required after resume, select either Permission Mode, inspect exact Actions, observe typed Results, complete a repair, and receive the same terminal Outcome that durable state records.

`zig build fixture-repair -Doptimize=ReleaseSmall` is the reproducible repair command. It begins with a committed executable failure, drives red Bash Result -> authorized Patch Intent -> applied Patch Result -> green Bash Result -> Final Answer through the production CLI and Harness, and runs both Permission Modes. The Provider validates the complete durable Conversation at each turn and has no call-count or time-based response selector.

The highest deterministic lifecycle seam is `Harness.open / offer / drive` with the production Core reducer, real SQLite Host Store and immutable blob store, fixed caller-owned pools, deterministic adapters, and semantic fault injection. Lifecycle tests assert durable behaviour, adapter admission, Conversation advancement, Projections, and Outcomes rather than private table names, SQL text, row identifiers, numeric Core fields, or helper calls.

Ingress tests distinguish three outcomes: `full` or `busy` leaves ownership with the producer; `accepted` transfers volatile custody to the live Harness; a later committed Projection acknowledges durable acceptance. Tests fill ingress while every Activation Slot is occupied and prove bounded retry without an unbounded fallback queue.

Core tests exercise the reducer and canonical codec without filesystem or provider behaviour. Native invariant traces exercise valid and rejected paths through canonical suspend and restore after every step. Codec tests prove that only kind-specific typed facts cross the semantic interface, that immediate and durable Result evidence cannot be mixed or assigned an inconsistent recovery class, and that malformed flat wire records fail before construction. Narrow storage tests cover schema and payload versions, interrupted empty-schema initialization, rejection of foreign schema, exact V1 DDL, self-projecting typed transactions, committed-only Conversation attachment, SQLite-assigned Inbox identity, Completion association, insertion-side pending capacity, consumed-row exclusion, SQLite failure mapping, Inbox conflicts, low-water reserve preservation, and bounded critical range reads.

Incremental recovery tests restore histories larger than one configured quantum and prove that each `drive` consumes no more than that quantum, returns `restoring` with `more = true`, and exposes no Projection before the snapshotted Session Ledger and pending Completion Inbox watermarks. They compare the recovered and live `ResidentState`, prove that consumed or irrelevant evidence cannot re-enter it, and prove that a failed Host Store transaction leaves the prior resident value published and the live Harness unavailable.

Storage topology tests start two fresh processes against one Host Store and prove that exactly one holds the lifetime lock. In-process tests prove that exactly one Host Runtime controls SQLite's process-global heap allowance and that the Storage Owner request mutex covers each complete operation. Every adapter publication passes through the Storage Owner; a Completion becomes durable only after its single-row Inbox acknowledgement. The production dependency graph contains exactly one SQLite opener and one connection owner.

Point lookups are bounded structurally by primary or unique-key equality. Populated critical range tests execute the exact production statement and reject nonzero `SQLITE_STMTSTATUS_FULLSCAN_STEP`, `SORT`, or `AUTOINDEX`; they do not depend on unstable planner prose. Limits cover request count and bytes, statement parameters, returned rows and bytes, transaction work, recovery work, database pages, and immutable blob references. The 32, 64, and 128 KiB page-cache profiles are test points; larger host-derived profiles use the same semantics.

## Targeted crash evidence

Crash tests belong to the vertical slice whose effect contract they prove. V1 does not multiply every semantic state by every tool and storage failure. Fresh-process tests cover these distinct decisions:

1. termination before Attempt admission is safe to dispatch later, while a committed admitted Attempt is already at the conservative uncertainty boundary;
2. a model or Bash Attempt terminated after dispatch may have begun is never automatically repeated as the same Attempt;
3. a patch terminated after mutation recognizes its bound expected postimage and does not reapply;
4. a patch target matching neither preimage nor postimage stops without writing;
5. process exit after SQLite commit but before `ResidentState` publication reconstructs exactly the committed transaction;
6. storage or active-capacity exhaustion admits no new external effect unless its bounded terminal evidence can still use the supported closure path.

Ordinary transaction, reducer, Inbox, Projection, and volatile-ingress tests cover the intermediate ledger states without requiring a separate process-crash fixture for each one. Every acknowledged fact must still reappear after recovery. A failed transaction exposes no subset of its semantic facts, lost Completion notifications recover through the Inbox, and admitted uncertain work never disappears, completes twice, or becomes model-visible without a committed Conversation Entry.

## Durable-store failures

OnePage tests its classification and publication behavior, not SQLite's pager implementation. The residual release matrix covers `SQLITE_FULL`, an injected ambiguous `IOERR` at the Storage Owner boundary, corrupt or invalid schema on open, and process exit after a successful commit. `BUSY` is required only if it is reachable through the supported singleton topology; `NOMEM` remains covered by ordinary failed-transaction and unavailable-owner tests. A custom VFS, short-write campaign, and exhaustive allocation failure sweep are outside V1.

Tests also cover invalid canonical payloads, sequence gaps and conflicts, missing immutable content, unsupported Host Store and payload versions, and recovery with rebuildable views removed. Physical Host Store corruption may make every Session unavailable, and tests must not misreport it as an isolated Session failure.

Model-retry recovery repeatedly terminates the process after dispatch but before Completion publication. Every replacement Attempt must commit the exact count of earlier dispatches that may duplicate provider work or billing before redispatch. A two-Attempt fresh-process case lets the replacement win, then publishes and offers valid late evidence for the original; the evidence remains audited against the winning Result transaction without a second Session Ledger transition or failure Projection. Focused model, Bash, and Patch cases reject evidence whose epoch differs from the matched Attempt, including a same-identity cross-epoch storage conflict. At the fixed Attempt-history limit, the next restore must publish and apply one durable provider-failure Result without dispatching a ninth Attempt or making the Session unavailable.

Operational tests enforce maximum page count by filling a transaction until admission rolls back, then prove the configured low-water page margin remains available. Before dispatch, each effect slice proves that its immutable descriptor and known closure evidence are durable and that the remaining terminal representation is bounded. This does not claim guaranteed recovery from arbitrary filesystem exhaustion after a possible effect. Tests also reuse free pages without foreground `VACUUM`. Schema tests open a valid, non-empty but schema-empty SQLite file to prove bootstrap is based on transactional identity rather than file existence. Snapshot, export, collection, shrinking, and migration evidence is post-V1.

## Resource ledger

Every density and product run reports these categories separately:

- actual Activation Slot size and named components, exact configured reservation, and occupied high-water bytes;
- native executor stack and thread count;
- Harness ingress, Completion, adapter-record, and recovery buffers;
- process-wide SQLite hard heap allowance and current/high-water total; overlapping page-cache, lookaside, and prepared-statement diagnostics; separate Storage Owner request/result bytes;
- model transport and bounded output tails;
- whole-process virtual size, physical RSS or platform physical-footprint measure, compressed memory where available, and measurement conditions after slots have been dirtied and released;
- subprocess RSS where available;
- Host Store, immutable content, free-page, index, and spool disk bytes;
- logical, runnable, resident, waiting, and in-flight counts;
- model Attempts, possible duplicate billing, tool Attempts, and indeterminate effects.

No headline may present the Activation Slot ceiling or reservation as total per-agent process memory.

## Release gates

Before the V1 demonstration is considered credible:

- the deterministic repair passes through the real CLI and Harness interfaces;
- the targeted effect-specific crash cases and residual storage classifications pass;
- the Session reconstructs from canonical transactions with rebuildable indexes deleted;
- the Host Runtime exclusively owns the Host Store and every durable path traverses the Storage Owner;
- SQLite allocation remains within the validated host allowance across supported cache profiles and increasing Session population;
- arbitrary Bash uncertainty is visibly indeterminate and never silently replayed;
- one-file patch reconciliation passes all three Workspace states;
- both Permission Modes exercise the same validation, Session Ledger, Attempt, and recovery paths;
- large model and tool outputs remain bounded in resident memory and complete on disk;
- density results include raw reproducible measurements for fixed resident capacity and increasing Dormant Session population.
- `zig build check` discovers every stable first-party Zig source through a production, test, or self-maintaining declaration-coverage root without adding a parallel manual inventory.
