# OnePage verification contract

This document maps each public architectural claim to required evidence. A claim is not complete because a type or comment expresses it; the production composition and its failure boundaries must demonstrate it.

## Claim matrix

| Claim | Required evidence |
| --- | --- |
| One exact 64 KiB Activation Slot | Compile-time size and alignment assertions over the production slot type; startup pool accounting. |
| Core State is independent of slot layout | Canonical codec vectors, unknown-version rejection, and restore into differently poisoned slots with identical semantic outcomes. |
| No Core activation allocation | Failing-allocator instrumentation across activate, transition, suspend, restore, and slot reuse. |
| Native/Wasm semantic parity | Shared accepted and rejected transition corpus plus randomized state-machine traces comparing outcomes, intents, and canonical Core State. |
| Session WAL is sole semantic authority | Recovery from the valid WAL prefix with checkpoints and indexes absent, stale, corrupt, or behind. |
| WAL transitions are atomic | Mid-frame termination, truncation, checksum failure, and multi-fact transaction cases expose either the previous complete sequence or the complete new sequence, never enclosed partial facts. |
| Checkpoints never lead authority | Rejection of checkpoint sequence beyond the WAL tail and replay from every checkpoint-behind-WAL boundary. |
| Immutable content is durable before reference | Crash injection before content sync, after content sync, before WAL sync, and after WAL sync; committed records never resolve to absent content. |
| Prepare, commit, publish ordering | Failure injection at every semantic publication point with exactly one result: owner remains usable, fresh `open` reconstructs, or Session fails closed. |
| Adapter evidence is not a second authority | Result content and Completion Inbox evidence survive lost notifications and process termination, but Session state advances only after Harness commits the matching terminal Result transaction. |
| No silent Bash replay | Process termination after possible command execution always produces an indeterminate Result without redispatch. |
| Patch reconciliation is honest | Exact preimage, postimage, and divergent Workspace fixtures plus concurrent replacement, symlink, and stale-Authorization cases. |
| Authorization binds exact execution | Descriptor-digest tests cover tool kind, bytes, Workspace, working directory, environment authority, timeout, generation, and preimage. |
| Sleeping population does not scale active memory | Increase durable Sessions while holding every resident pool fixed; report RSS tolerance and disk growth separately. |
| Topology does not scale activation memory | Flat, deep, wide, and balanced synthetic delegation shapes with equal runnable work and fixed pool capacity. |
| Output remains bounded in RAM | Adversarial model and command outputs larger than memory tails, exact durable spool recovery, and steady resident-memory measurements. |
| Ownership and slot reuse are fenced | Late, duplicate, prior-epoch, future-epoch, stale-window, and generation-exhaustion tests across scrubbed slot reuse. |
| Terminal output is safe | Control, ANSI, OSC, hyperlink, clipboard, carriage-return, backspace, fragmented UTF-8, and oversized-line fixtures. |

## Required test seams

The highest product seam is the real CLI against a temporary Git repository and deterministic adapters. It proves that a user can create and resume a Session, select either Permission Mode, inspect exact Actions, observe typed Results, complete a repair, and receive the same terminal Outcome that durable state records.

The highest deterministic lifecycle seam is `Harness.open / offer / drive` with the production Core reducer, real Session WAL and content store, fixed caller-owned pools, deterministic adapters, and semantic fault injection. Lifecycle tests assert durable behaviour, adapter admission, Conversation advancement, Projections, and Outcomes rather than private file paths, numeric Core fields, or helper calls.

Core tests exercise the reducer and canonical codec without filesystem or provider behaviour. Native/Wasm differential tests consume the same semantic vector corpus. Narrow storage tests remain for WAL framing, checksums, torn-tail recovery, content addressing, sync and rename failures, ownership fencing, and codec corruption.

## Crash matrix

At minimum, fresh-process tests terminate before and after:

1. immutable content publication;
2. task or Operation submission commit;
3. Operation acceptance transaction, including every byte boundary inside its WAL frame;
4. Attempt admission transaction, including every byte boundary inside its WAL frame;
5. adapter observation, where an admitted unterminated Attempt becomes conservatively `possibly_executed`;
6. external execution without terminal evidence;
7. immutable Result content publication;
8. Completion Inbox envelope publication;
9. in-memory Completion offer;
10. terminal Result WAL transaction;
11. Conversation Entry content publication and WAL attachment;
12. prepared Core State publication;
13. State Checkpoint publication;
14. durable Projection regeneration;
15. slot scrub and release.

Every acknowledged fact must reappear after recovery. Mid-frame bytes never expose partial semantic facts. An admitted Attempt without a terminal WAL transaction is `possibly_executed` unless durable evidence completes it; absence of an inbox record never proves `definitely_unsent`. Lost Completion notifications are recovered from the inbox, and no accepted external effect may disappear, replay under the wrong policy, complete twice, or become model-visible without a committed Conversation Entry.

## Durable-store failures

Tests cover disk exhaustion during immutable content and WAL writes, short writes, failed sync, torn and corrupt WAL tails, corrupt older records, missing content, failed atomic rename, stale temporary files, unsupported schemas, and recovery with all rebuildable views removed. The documented durability level distinguishes process termination from operating-system crash and sudden power loss.

## Resource ledger

Every density and product run reports these categories separately:

- exact configured and occupied Activation Slot bytes;
- native executor stack and thread count;
- Harness ingress, Completion, adapter-record, and recovery buffers;
- model transport and bounded output tails;
- whole-process RSS and measurement conditions;
- subprocess RSS where available;
- Session WAL, immutable content, State Checkpoint, index, and spool disk bytes;
- logical, runnable, resident, waiting, and in-flight counts;
- model Attempts, possible duplicate billing, tool Attempts, and indeterminate effects.

No headline may fold these values into the 64 KiB Activation Slot claim.

## Release gates

Before the live repair demonstration is considered credible:

- the deterministic repair passes through the real CLI and Harness interfaces;
- the complete crash matrix passes in fresh processes;
- the Session reconstructs with checkpoints and indexes deleted;
- arbitrary Bash uncertainty is visibly indeterminate and never silently replayed;
- one-file patch reconciliation passes all three Workspace states;
- both Permission Modes exercise the same validation, WAL, Attempt, and recovery paths;
- large model and tool outputs remain bounded in resident memory and complete on disk;
- density results include raw reproducible measurements for fixed resident capacity and increasing sleeping population.
