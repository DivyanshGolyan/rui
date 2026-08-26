# Operation-lifecycle spike

> Historical evidence. ADR-0009 replaces this spike's operation journal and checkpoint authority
> with one Host Store and per-Session Ledger. Retain the measured lifecycle evidence; do not use the
> obsolete persistence or runtime mechanics as current scope.

## Question

How can a logical agent submit an external operation, release its 64 KiB execution slot, and later
receive the result without losing work or retaining per-agent resident host state?

## Contract

An operation crosses three durable boundaries:

1. **Submitted:** The core has published an immutable operation descriptor inside the loaded page.
2. **Accepted:** The host has validated the descriptor and recorded enough durable state to recover
   it without the page.
3. **Completed:** The host has durably published the outcome to the logical agent's mailbox.

The scheduler may reuse a slot only after every submitted descriptor is accepted. If acceptance
fails, the core retains the descriptor or records a bounded failure event; the operation cannot
silently disappear. Completion does not require the agent's page to be resident.

Immediate and deferred operations follow the same path. An inline result becomes a completion
record for a later bounded core tick and never calls reentrantly into the core.

## Descriptor ownership

Each submitted descriptor is immutable and contains:

- the logical agent identity and checkpoint generation;
- a stable operation identifier and sequence number;
- the capability and exact authority granted to it;
- resource bounds and cancellation policy;
- generation-tagged handles for referenced durable byte ranges.

The host performs capability admission before acceptance. A worker receives only the accepted
descriptor and its explicit handles. It does not adopt credentials, environment, or mutable context
from the agent that submitted it.

## Completion ownership

The host retains accepted operations and completions in bounded durable storage. A completion
identifies the operation, agent generation, status, result handle, byte length, and checksum.
Generation checks reject stale results after handles or slots are reused.

The current core uses a 32-bit operation generation and refuses a new submission when that counter
is exhausted. It never wraps to a previously valid generation. A later format can rotate logical
agent identity under a durable barrier if operation counts make this boundary reachable.

Completions preserve dependency order and use free-running sequence numbers. The scheduler admits
and drains fixed-size batches so that a backlog cannot monopolize an execution slot. Full mailboxes
apply backpressure and pause new work instead of growing resident memory.

Transport implementations may process many network chunks through shared bounded buffers. V1 does
not expose general multishot operations to the core: the agent receives only requested bounded
progress events or one durable terminal completion.

## Representation decision

The host journal now uses canonical, checksummed 80-byte version-3 records. Each record identifies its
kind, logical agent, agent generation, operation, operation generation, Attempt, ownership epoch,
recovery class, immutable descriptor digest, global sequence, and result. Version 3 also assigns
canonical kinds to descriptor validation, permission, Attempt start, typed result, and indeterminate
effect recovery without creating another history. Patch preflight adds approval-required,
permission-binding, and preflight-result facts to the same record union. The writer synchronizes the
file after every record. Replay rejects corrupt,
noncanonical, truncated, and nonmonotonic records.

The page still uses one fixed operation slot rather than a shared circular ring. Because only one
logical agent runs in an execution slot at a time, fixed command and event batches may use less page
space and be easier to inspect. A later spike can compare both layouts after real descriptor fields
and alignment are known.

The operating-system backend is also separate from the protocol. A later macOS host can use
readiness notification for sockets and pipes and a fixed worker pool for unavoidable blocking work
without exposing either mechanism to the core.

## Current result

`zig build lifecycle -Doptimize=ReleaseSmall` launches four host processes: preparation, completion,
recovery, and repeated recovery. The preparation process drives 1,000 agents through one resident
JavaScriptCore instance and one 64 KiB page. Each agent writes its submitted checkpoint before the
host appends and synchronizes acceptance, then the page becomes eligible for reuse.

One completion is available immediately after acceptance but still enters the journal instead of
re-entering the core. The completion process reopens and validates the journal, resumes after global
sequence 1,001, and appends the other 999 completions while no logical-agent page is loaded. Agent
500 deliberately keeps a submitted page image after its acceptance is durable. Agent 1,001 keeps a
submitted page image without an accepted journal record.

The recovery process starts with a fresh JavaScriptCore context, compiled module, and execution
page. It scans the journal without a resident per-agent index, restores pages only as their
completions are encountered, reconciles agent 500's accepted transition, and leaves agent 1,001
submitted. All 1,000 accepted operations reach their expected completed state. The second recovery
process replays the same journal over already-completed pages and reaches the same result.

One measured run on 2026-08-24 reported:

| Boundary | Result |
| --- | ---: |
| Resident execution slots | 1 |
| Accepted operations | 1,000 |
| Queued completions | 1,000 |
| Journal size | 128,000 B |
| Checkpoint storage, including unaccepted probe | 65,665,600 B |
| Preparation RSS after agents 1, 100, and 1,000 | 8,650,752 B each |
| Preparation time | 743 ms |
| Completion publication time | 50 ms |
| First recovery time | 1,962 ms |
| Lost accepted operations | 0 |
| Resident per-agent index | 0 B |

The recovery scan deliberately trades disk reads and compute for resident memory. For each
completion it scans the prior journal prefix to prove that a matching acceptance exists and that no
earlier completion exists. This makes the current verifier quadratic in record count but bounded in
memory; it is evidence for the memory tradeoff, not a proposed production scheduler.

## Deliberate omissions

This spike proves recovery across a clean process boundary. It does not yet prove recovery from
power loss or a kill at every write boundary. Checkpoint replacement is not atomic, and the journal
sync does not yet include a parent-directory durability barrier.

The spike also does not choose an on-page queue representation, mailbox compaction strategy, bounded
runnable index, or macOS I/O backend. It does not promise exactly-once execution for arbitrary
external effects. Those decisions require named failure injection around atomic publication.
