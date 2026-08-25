# OnePage verification contract

This document maps each public architectural claim to required evidence. A claim is not complete because a type or comment expresses it; the production composition and its failure boundaries must demonstrate it.

## Claim matrix

| Claim | Required evidence |
| --- | --- |
| One exact 64 KiB Activation Slot | Compile-time size and alignment assertions over the production slot type; startup pool accounting. |
| Core State is independent of slot layout | Canonical codec vectors, unknown-version rejection, and restore into differently poisoned slots with identical semantic outcomes. |
| No Core activation allocation | Compile-time rejection of allocator-bearing parameter and storage types across every lifecycle method, direct review of Core dependencies, plus complete activate, transition, suspend, restore, and reuse tests. |
| Native semantic invariants | Randomized accepted and rejected transition traces with typed outcomes, rejection-state preservation, semantic observations, deterministic canonical encoding, and poisoned-slot restoration. |
| Session Ledger is sole semantic authority | Recovery from ordered canonical transitions with checkpoints and indexes absent, stale, corrupt, or behind. |
| Host Store transitions are atomic | Termination and injected SQLite failures around multi-table transactions expose either the previous complete Session sequence or the complete new sequence, never enclosed partial facts. |
| Checkpoints never lead authority | Ignoring a corrupt checkpoint, rejecting one ahead of the ledger head, and replaying from every checkpoint-behind-ledger boundary. |
| Immutable content is durable before reference | Crash injection before content sync, after content sync, before Host Store commit, and after commit; committed transitions never resolve to absent content. |
| Prepare, commit, publish ordering | Failure injection at every semantic publication point with exactly one result: owner remains usable, fresh `open` reconstructs, or Session fails closed. |
| One Storage Owner is the durable gateway | A host-level lifetime-lock test excludes a second process, and dependency plus runtime tests prove Core, Harness, adapters, workers, and CLI cannot open SQLite directly. |
| Adapter evidence is not a second authority | Result content and immutable Completion Inbox evidence survive lost notifications and process termination; terminal commitment atomically sets `consumed_by_sequence`, and conflicting evidence fails closed. |
| Approval Required is not Authorization | Ledger inspection and restore tests prove pending `ask` state has one exact Approval Required transition and no Authorization until a matching allow or deny Permission Decision commits. |
| Control settlement cannot strand accepted work | Shutdown denies pending Approval Required state; cancellation and shutdown reconcile durable Completion Inbox evidence until every accepted Operation is terminal or indeterminate. |
| Known provider failure is terminal | A dispatch error after Attempt admission produces one durable provider-failure Result; repeated restore regenerates failure without admitting a replacement Attempt. |
| Ingress custody is not durable acknowledgement | Crash after `offer` acceptance but before Host Store commit loses no acknowledged fact: Completion is rediscovered, an `ask` decision is requested again, an uncommitted Task remains absent, and cancellation remains unapplied. |
| No silent Bash replay | Process termination after possible command execution always produces an indeterminate Result without redispatch. |
| Patch reconciliation is honest | Exact preimage, postimage, and divergent Workspace fixtures plus concurrent replacement, symlink, and stale-Authorization cases. |
| Authorization binds exact execution | Descriptor-digest tests cover tool kind, bytes, Workspace, working directory, environment authority, timeout, generation, and preimage. |
| Sleeping population does not scale active memory | Increase durable Sessions while holding every resident pool fixed; report RSS tolerance and disk growth separately. |
| SQLite remains within its host allowance | Current and high-water heap, page-cache, lookaside, statement, request, and result measurements stay within the validated envelope for every supported cache and workload profile. |
| Storage work is bounded and fair | Indexed-query plans, bounded result tests, group-commit limits, and adversarial multi-Session scheduling prove no request, recovery scan, or Session monopolizes the Storage Owner. |
| Topology does not scale activation memory | Flat, deep, wide, and balanced synthetic delegation shapes with equal runnable work and fixed pool capacity. |
| Output remains bounded in RAM | Adversarial model and command outputs larger than memory tails, exact durable spool recovery, and steady resident-memory measurements. |
| Ownership and slot reuse are fenced | Late, duplicate, prior-epoch, future-epoch, stale-window, and generation-exhaustion tests across scrubbed slot reuse. |
| Terminal output is safe | Control, ANSI, OSC, hyperlink, clipboard, carriage-return, backspace, fragmented UTF-8, and oversized-line fixtures. |

## Required test seams

The highest product seam is the real CLI against a temporary Git repository and deterministic adapters. It proves that a user can create and resume a Session, supply a selected provider for model work required after resume, select either Permission Mode, inspect exact Actions, observe typed Results, complete a repair, and receive the same terminal Outcome that durable state records.

The highest deterministic lifecycle seam is `Harness.open / offer / drive` with the production Core reducer, real SQLite Host Store and immutable blob store, fixed caller-owned pools, deterministic adapters, and semantic fault injection. Lifecycle tests assert durable behaviour, adapter admission, Conversation advancement, Projections, and Outcomes rather than private table names, SQL text, row identifiers, numeric Core fields, or helper calls.

Ingress tests distinguish three outcomes: `full` or `busy` leaves ownership with the producer; `accepted` transfers volatile custody to the live Harness; a later committed Projection acknowledges durable acceptance. Tests fill ingress while every Activation Slot is occupied and prove bounded retry without an unbounded fallback queue.

Core tests exercise the reducer and canonical codec without filesystem or provider behaviour. Native invariant traces exercise valid and rejected paths through canonical suspend and restore after every step. Narrow storage tests cover schema and payload versions, canonical payloads, transaction rollback, sequence conflicts, hardened configuration, SQLite failure mapping, content addressing, sync failures, ownership fencing, Inbox conflicts, bounded query plans, and checkpoint corruption.

Incremental recovery tests restore histories larger than one configured quantum and prove that each `drive` consumes no more than that quantum, returns `restoring` with `more = true`, and exposes no Projection before the snapshotted Session Ledger and Completion Inbox watermarks. They also prove that irrelevant Inbox evidence cannot displace evidence for a currently admitted Attempt, and that a failed Host Store transaction leaves the semantic index unpublished and the live Harness unavailable.

Storage topology tests start two fresh processes against one Host Store and prove that exactly one holds the lifetime lock. Every adapter publication passes through bounded Storage Owner requests; a Completion becomes durable only after the Inbox transaction acknowledgement. The production dependency graph contains exactly one SQLite opener and one connection owner.

SQL tests use `EXPLAIN QUERY PLAN`, worst-case admitted inputs, and populated fixtures to reject full scans or temporary materialization on lifecycle paths. Limits cover request count and bytes, statement parameters, returned rows and bytes, transaction work, group size, recovery work, database pages, and immutable blob references. The 32, 64, and 128 KiB page-cache profiles are test points; larger host-derived profiles use the same semantics.

## Crash matrix

At minimum, fresh-process tests terminate before and after:

1. immutable content publication;
2. task or Operation submission commit;
3. Operation acceptance transaction, immediately before and after SQLite commit;
4. Attempt admission transaction, immediately before and after SQLite commit;
5. adapter observation, where an admitted unterminated Attempt becomes conservatively `possibly_executed`;
6. external execution without terminal evidence;
7. immutable Result content publication;
8. Completion Inbox envelope publication;
9. in-memory Completion offer;
10. terminal Result Host Store transaction and Inbox evidence association;
11. Conversation Entry content publication and Session Ledger attachment;
12. prepared Core State publication;
13. State Checkpoint publication;
14. durable Projection regeneration;
15. slot scrub and release.

The matrix separately crashes after volatile `offer` acceptance and before the corresponding Host Store transaction for Task, Completion, `ask` decision, and cancellation. Completion recovers through the Completion Inbox; the Task is not partially admitted; the user is asked again; cancellation is not silently applied; and no CLI acknowledgement exists before the committed Projection.

Every acknowledged fact must reappear after recovery. A failed transaction never exposes a subset of its semantic facts. An admitted Attempt without a terminal Session Ledger transition is `possibly_executed` unless durable evidence completes it; absence of Inbox evidence never proves `definitely_unsent`. Lost Completion notifications are recovered from the Inbox, and no accepted external effect may disappear, replay under the wrong policy, complete twice, or become model-visible without a committed Conversation Entry.

## Durable-store failures

Tests cover disk exhaustion during immutable content and SQLite writes; `SQLITE_FULL`, `BUSY`, `IOERR`, `CORRUPT`, `NOTADB`, and `NOMEM`; failed sync; invalid canonical payloads; sequence gaps and conflicts; missing content; corrupt checkpoints; unsupported Host Store and payload versions; and recovery with every rebuildable view removed. A corrupt checkpoint loses only acceleration. Physical Host Store corruption may make every Session unavailable, and tests must not misreport it as an isolated Session failure.

Operational tests enforce maximum page count and admission reserve, reuse free pages without foreground `VACUUM`, take a bounded consistent backup, export one Session with its referenced blobs, delete only an explicitly selected closed Session, and perform bounded blob garbage collection. Major shrinking or recovery maintenance requires the Host Store to be offline under its lifetime lock.

## Resource ledger

Every density and product run reports these categories separately:

- exact configured and occupied Activation Slot bytes;
- native executor stack and thread count;
- Harness ingress, Completion, adapter-record, and recovery buffers;
- SQLite accounting allowance, hard heap limit, page-cache setting and high-water, lookaside use, prepared-statement use, and Storage Owner request/result bytes;
- model transport and bounded output tails;
- whole-process RSS and measurement conditions;
- subprocess RSS where available;
- Host Store, immutable content, State Checkpoint, free-page, index, and spool disk bytes;
- logical, runnable, resident, waiting, and in-flight counts;
- model Attempts, possible duplicate billing, tool Attempts, and indeterminate effects.

No headline may fold these values into the 64 KiB Activation Slot claim.

## Release gates

Before the live repair demonstration is considered credible:

- the deterministic repair passes through the real CLI and Harness interfaces;
- the complete crash matrix passes in fresh processes;
- the Session reconstructs with checkpoints and indexes deleted;
- the Host Runtime exclusively owns the Host Store and every durable path traverses the Storage Owner;
- SQLite allocation remains within the validated host allowance across supported cache profiles and increasing Session population;
- bounded group commits remain fair and create no cross-Session semantic dependency;
- arbitrary Bash uncertainty is visibly indeterminate and never silently replayed;
- one-file patch reconciliation passes all three Workspace states;
- both Permission Modes exercise the same validation, Session Ledger, Attempt, and recovery paths;
- large model and tool outputs remain bounded in resident memory and complete on disk;
- density results include raw reproducible measurements for fixed resident capacity and increasing sleeping population.
