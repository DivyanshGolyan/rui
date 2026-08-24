# Operation-lifecycle spike

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

Completions preserve dependency order and use free-running sequence numbers. The scheduler admits
and drains fixed-size batches so that a backlog cannot monopolize an execution slot. Full mailboxes
apply backpressure and pause new work instead of growing resident memory.

Transport implementations may process many network chunks through shared bounded buffers. V1 does
not expose general multishot operations to the core: the agent receives only requested bounded
progress events or one durable terminal completion.

## Representation decision

The contract does not require shared circular rings. Because only one logical agent runs in an
execution slot at a time, fixed command and event batches may use less page space and be easier to
inspect. The implementation spike must compare both layouts after the descriptor fields and
alignment are known.

The operating-system backend is also separate from the protocol. A later macOS host can use
readiness notification for sockets and pipes and a fixed worker pool for unavoidable blocking work
without exposing either mechanism to the core.

## Required experiments

1. Crash immediately before and after operation acceptance, then prove that acknowledged work is
   present and unacknowledged work is never reported as accepted.
2. Complete an operation while its agent has no resident page, restart the host, and deliver the
   completion to the correct restored generation.
3. Send immediate and deferred completions through the same queue and prove that neither re-enters
   the core.
4. Fill the submission and completion bounds and prove deterministic backpressure without memory
   growth or record loss.
5. Reuse operation and buffer slots across generations and reject stale or duplicate completions.
6. Measure resident host memory while durable accepted operations increase with execution-slot
   count fixed.

## Deliberate omissions

This note does not choose an on-page queue representation, journal record encoding, mailbox storage
layout, or macOS I/O backend. It does not promise exactly-once execution for arbitrary external
effects. Those decisions require measurements from the next implementation spike.
