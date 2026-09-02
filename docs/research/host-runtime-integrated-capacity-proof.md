# Integrated Host Runtime capacity proof

Date: 2026-09-02

Status: architecture recommendation from the disposable issue #67 prototype.
This is research evidence, not a normative contract or production
implementation. Production source remains paused.

## Recommendation

Keep one deep **Host Runtime** module with three internal ownership lanes:

1. The foreground Host/control context is the sole **Storage Owner**. It owns
   the SQLite connection, bounded Decision Snapshots, semantic commands,
   post-commit request preparation, sealed-artifact validation/import, and
   settlement.
2. One Host-wide **I/O Reactor** owns live provider transports and Bash
   processes, pipes, deadlines, and transient spools. It performs no semantic
   classification and cannot access SQLite.
3. One serial **Patch execution lane** owns blocking Patch filesystem work and
   returns sealed observations. It cannot access SQLite, select Reconciliation,
   or claim Workspace isolation.

These are implementation lanes, not domain entities or public interfaces. The
Host Runtime's callers continue to use semantic Run and Turn commands. Reactor
handles, wakes, scratch descriptors, and Physical Custody records remain hidden
inside the module.

At startup, `active_capacity` bounds one table of tiny content-free **Physical
Custody** records. Occupancy of one record is one **Active Credit**; the terms do
not name two objects or pools. A record may contain Attempt identity,
effect kind, descriptors and opaque handles, scalar counters, deadlines, and
publication state. It contains no prompt, response, Tool Result, Bash output,
Conversation content, parser arena, or candidate buffer.

Do not add per-effect workers, resident retry objects, generic ready or
Completion queues, a Workspace fence, a second SQLite owner, an online semantic
detector, or a resident Session/Turn graph.

## Complete physical path

### Admission and request preparation

1. The Storage Owner loads one bounded canonical Decision Snapshot.
2. It validates the command and reserves one Active Credit with one free
   Physical Custody record. Capacity failure inserts no Attempt.
3. One SQLite-specific mutation starts `BEGIN IMMEDIATE`, reloads and validates
   the canonical snapshot, inserts the Attempt and all same-boundary facts, and
   commits. Only that invocation receives the one-shot Dispatch Permit.
4. After commit, the Storage Owner materializes any content-sized provider,
   Bash, or Patch input from canonical SQLite content through bounded read/write
   windows into disposable, immediately unlinked scratch. Only small scalar
   metadata and content references remain in Physical Custody. Preparation
   failure is evidence for the committed Attempt.
5. The Storage Owner publishes the prepared descriptors in the reserved
   Physical Custody record. The owning execution lane may then launch the
   effect.

Post-commit input preparation is necessary because SQLite is the sole
recoverable content authority while the execution lanes deliberately have no
SQLite access. It is not a second semantic store: Host loss may discard the
unlinked input spool and leave the Attempt unresolved for effect-specific
recovery.

### Live execution

- libcurl supplies borrowed receive windows which the reactor writes directly
  to one unlinked model-output spool.
- The reactor continuously drains Bash stdout and stderr into separate
  unlinked spools, even while terminating or discarding output after a limit.
- Patch operates on the named Workspace target and records only directly owned
  observations. Concurrent Bash or external mutation remains possible.
- No SQLite write transaction or shared validation workspace is held during a
  seconds- or minutes-long effect.

### Seal, validate, settle, release

1. The effect-owning lane first terminalizes physical truth: provider transport
   ends, Bash pipes drain and the direct child is reaped, or Patch finishes its
   bounded write-and-observation path.
2. It seals the scratch evidence and publishes only the descriptor and scalar
   metadata through Physical Custody.
3. The Storage Owner borrows one shared bounded validation/import workspace,
   validates the sealed artifact outside a write transaction, and writes any
   accepted canonical representation only to transient scratch.
4. One SQLite command normally imports accepted canonical content and commits
   Attempt Completion, Operation Resolution, and their fixed semantic consequence
   atomically. The sole Completion-only exception is a retryable model Completion
   committed atomically with immutable retry eligibility while the Operation
   remains unresolved.
5. Only after successful commit does the Host release scratch and the Physical
   Custody record, thereby returning its Active Credit. The record is reusable
   only after its owning lane can no longer publish a callback for the old
   Attempt identity.

SQLite constraints enforce zero or one Completion per Attempt and zero or one
Resolution per Operation. Exact settlement replay is idempotent; conflicting
replay is rejected. The Physical Custody record never arbitrates semantic truth.

## Measured evidence

The integrated prototype is under
`research/host-runtime/integrated-capacity-proof/`. It is disposable C and a
scratch measurement schema; neither is linked into OnePage.

Four ten-second Latin-square rotations produced these medians on the current
busy 16 GiB M1 Pro development Host:

| Active Capacity | Parent active physical | Active minus lanes-idle | One-core CPU fraction | Parent FD high-water |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 3.20 MiB | 0.57 MiB | 0.016 | 10 |
| 10 | 3.86 MiB | 1.42 MiB | 0.042 | 30 |
| 50 | 7.31 MiB | 4.79 MiB | 0.130 | 130 |
| 100 | 11.59 MiB | 9.12 MiB | 0.220 | 256 |

The incremental parent-process slope from capacity 1 to 100 was about 89 KiB
per additional active credit. The candidate Physical Custody record itself was
128 bytes, or 12.5 KiB for all 100 records. The remainder is predominantly
live libcurl, TLS, socket, pipe, descriptor, and allocator state required by
concurrent effects. These are prototype measurements, not #68 release limits.

The duration control changed 74 model streams from ten seconds to sixty seconds
while retaining 25 concurrent Bash Attempts and one Patch Attempt. Live spool
allocation increased by 19.47 MiB and logical scratch high-water by 16.97 MiB;
parent active physical footprint changed by 128 bytes. Response duration and
size therefore scaled disk custody without a measurable resident-memory slope.

`F_NOCACHE` changed the equal-duration active physical sample by only 47.9 KiB
and worsened the sampled callback tail. Ordinary unlinked cached files remain
the simpler default unless repeated whole-machine trials show a material gain.

After one capacity-100 wave, `vmmap` reported 10.5 MiB total private dirty and
112 KiB dirty stack pages. A paired zero-credit allocator pressure-relief run
reported 4.61 MiB private dirty and 144 KiB dirty stack pages. Ten consecutive
capacity-100 waves settled 1,000 Attempts correctly; the no-relief run retained
5.36 MiB more physical memory after the tenth wave than after the first. One
pressure-relief call at zero Active Credit reduced the paired final sample from
17.84 MiB to 5.06 MiB. This proves allocator retention is reclaimable; it does
not yet select when production should request relief.

The asserted physical fixtures also cover post-commit scratch-open failure,
real mounted-image `ENOSPC`, output overflow without RAM fallback, descriptor
exhaustion, reactor fail-stop, Bash TERM/KILL/drain/reap and escaped pipe grace,
terminal-protocol omission, and three fence-free Bash/Patch interference
orders. Relational retry, cancellation-winner, sibling-projection, idempotency,
and recovery semantics were deliberately removed from the disposable artifact.
Issue #52 owns relational constraints and sibling projection; issue #34 owns
physical admission, retry, cancellation, custody release, and effect recovery.

## What the proof decides

- Active Capacity 100 does not require 100 workers, parser arenas, candidate
  buffers, response buffers, or resident Turn drivers.
- Seconds- or minutes-long model custody needs live transport control but not
  response-sized process memory.
- One model/Bash reactor plus one serial validation/import workspace is enough
  for the tested load shape.
- A serial Patch lane is small fixed Host machinery and keeps blocking mutation
  off both SQLite ownership and continuous I/O drainage.
- Ordinary unlinked scratch is the default. It is disposable Physical Custody,
  not a second recoverable store.
- Allocator high-water must be measured and bounded independently from live
  content; it must not be mistaken for a per-Turn buffer requirement.

## Remaining gates

Issue #67 is not complete until:

1. one real-provider run validates authentication, DNS, handshake, provider
   fragmentation, request upload, cancellation, and library retention;
2. the post-commit input-preparation path is exercised with production-shaped
   provider and Patch inputs;
3. whole-machine socket/kernel and file-cache/writeback pressure is measured
   separately from parent-process physical footprint; and
4. a fresh evidence-validity and unnecessary-complexity review checks the
   frozen artifact and claims, not production-code style.

Issue #68 must choose numeric release budgets for parent-process baseline and
slope, kernel/socket pressure, SQLite cache, descriptors, threads, scratch
logical and physical bytes, raw-plus-canonical overlap, per-effect output,
allocator retention/relief, and the retry-eligibility poll cadence. It must also
define the atomic overload result for each budget.

Issue #69 must publish the accepted ownership and settlement contract and remove
the current normative references to Workspace fencing, pre-commit physical
preparation, Activation Slots, universal Completion-before-Resolution crash
boundaries, retained contradictory evidence, and the narrower public
`in_flight` derivation.
