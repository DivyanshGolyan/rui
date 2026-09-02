# Host Runtime asynchronous execution design

Research date: 2026-08-30
Revised for the single-store architecture: 2026-08-31
Governing work: [issue #34](https://github.com/DivyanshGolyan/onepage/issues/34)

> **Superseded architecture guidance.** ADR-0019, ADR-0021, and the current
> issue #34 contract replace the detached-I/O design below. Its measurements
> remain evidence; its `ExecutionCell`, Activation Slot, blocking-worker,
> generation, pre-reservation, Workspace-fence, and lifecycle recommendations
> must not be implemented.

The original research inspected revision `bf6081e8a502435457ba6c23c78dbd9e908b9615`.
That revision used per-Session directories, lock files, and a custom durable blob
tree. [ADR-0018](../adr/0018-use-sqlite-as-the-sole-durable-content-store.md)
supersedes every ownership recommendation based on those objects. The measured
executor and transport results remain useful only as historical evidence.

## Decision

Keep one fixed `ExecutionCell[active_capacity]` table, one long-lived
`std.Io.Group`, and one coalescing Host wake event. V1 uses blocking libcurl easy
on the injected bounded Zig worker executor. An executor receives only a cell
index and generation plus a narrow detached `AttemptIo`; it never receives a
Harness, semantic Session, Activation Slot, SQLite connection, or filesystem
authority.

Reserve executor concurrency before committing an Attempt by starting a task
that waits on its cell's start gate. If `Group.concurrent` returns
`ConcurrencyUnavailable`, release the cell and return bounded `busy` before
Attempt admission. After the Attempt transaction commits, transfer the Active
Credit to the Attempt and open the gate. If admission fails, open the gate in
the aborted state and wait for task departure before recycling the generation.

This preserves three rules:

1. capacity failure occurs before Attempt admission;
2. Attempt admission commits before the executor may begin the effect; and
3. `drive` never runs provider or tool work synchronously.

Do not add a general scheduler, a per-Session actor, an allocator-backed ready
queue, a second SQLite connection, or a resident registry of durable Sessions.
Durable readiness remains reconstructible from the Host Store. Fixed cells and
generation-tagged wake hints exist only for live work.

## The fundamental tension

OnePage has four distinct populations:

| Population | Bound and residence |
| --- | --- |
| Durable Sessions and Jobs | Potentially thousands; SQLite facts and content only while dormant or Awaiting User. |
| Live semantic owners | At most `active_capacity`; each may borrow one Activation Slot for one bounded quantum. |
| Admitted external Attempts | At most the remaining Active Credits; each owns one bounded detached effect lease, not a Harness or Slot. |
| Physical executor workers | Backend-specific; with Zig 0.16 a blocking effect normally occupies one native worker. |

The invariant is:

```text
live Harness owners + admitted Attempts + closure handoffs <= active_capacity
occupied Activation Slots <= live Harness owners
executor tasks <= admitted Attempts
```

An Active Credit is transferable semantic capacity, not a preallocated bundle
of stack, socket, parser, process, and validation memory. Physical resources
must nevertheless be included in the capacity measurement.

## Detached `AttemptIo`

`AttemptIo` is a move-only leaf capability prepared by the Storage Owner after
Attempt admission. It contains only:

- Session identity and ownership epoch;
- exact Agent, Operation, Attempt, descriptor, and result identities;
- the bounded set of immutable SQLite content references permitted as input;
- one predetermined result reference;
- ownership of one bounded, unlinked transient scratch capture while the
  external effect is live; and
- a narrow Storage Owner publication capability pre-bound to the exact typed
  Completion relationship.

It may read fixed windows from only its permitted content references, append to
only its provisional result capture, and request one typed publication. It
cannot read or mutate resident Core, Conversation indexes, Session policy,
authorization, ledger facts, or ownership state. It contains no SQLite handle,
semantic graph, Harness, or Activation Slot.

The transient capture has no durable identity. It is never restored, scanned,
or reset after a crash. Normal completion imports its complete bytes and inserts
the bound Completion Inbox row in one short Storage Owner transaction. A crash
before that transaction leaves an admitted Attempt without Completion; recovery
uses the existing effect-specific rule. A crash after commit rediscovers the
exact Completion and content in SQLite. No lock transfer, directory transfer,
draft cleanup, orphan discovery, or cross-store publication protocol exists.

The executor closes transport/process state and transient scratch, then
release-stores a generation-tagged departure marker and sets the Host wake.
Only the Host owner transitions the fixed cell to closure. Wake state is never
authority; the Completion Inbox and Session Ledger are recovery truth.

## Smallest V1 cell lifecycle

```text
free
  -> harness_owned
  -> executor_reserved       Group.concurrent succeeded; task waits on gate
  -> attempt_in_flight       Attempt committed; gate opened
  -> task_departed           effect resources closed; atomic marker published
  -> closure_ready           Host owner alone performs this transition
  -> harness_owned           fresh semantic owner reconciles durable evidence
  -> free | executor_reserved
```

The dispatch sequence is:

1. Borrow an Active Credit and Activation Slot through the current owner path.
2. Prepare immutable executor input as identities and bounded content refs.
3. Acquire the Workspace Effect Fence when required, represented in the same
   fixed cell table.
4. Reserve `Group.concurrent` with `{ host, cell_index, generation }`; the task
   waits at the start gate.
5. If reservation fails, release the fence and return `busy` before admission.
6. Commit Attempt admission and bind `AttemptIo` to the admitted identity and
   predetermined result reference.
7. Open the start gate, scrub/release the Slot, destroy the Harness, and return.
8. The task performs the effect through `AttemptIo` and asks the Storage Owner
   to publish its exact typed Completion.
9. The task releases all external and transient resources, publishes its final
   generation marker, sets the coalescing wake, and returns.
10. The Host scans fixed cells and durable evidence, creates a fresh semantic
    owner for reconciliation, and releases or transfers the same credit.

If Attempt admission fails after task reservation, the task observes the
aborted gate state and departs without an effect. The cell generation is not
reused until the Host has observed that departure.

## Wake without a completion queue

Use one process-local `Io.Event` plus generation-tagged atomic departure markers
in the fixed cells. The producer sets the event only after its durable
publication decision and resource cleanup. The owner resets the event,
acquire-scans the fixed markers and durable readiness, and waits only if neither
contains work. Reset-before-scan closes the lost-wakeup window.

Dropped, duplicate, stale, and process-lost wakes are harmless. A fresh process
reconstructs non-terminal Attempts and Completion evidence from SQLite rather
than rebuilding an object per durable Session.

## Executor and transport evidence

On the inspected aarch64 macOS machine, a Zig 0.16 sleep-only
`Group.concurrent` spike touched 64 KiB of each worker stack:

| Concurrent tasks | Physical footprint | Process threads |
| ---: | ---: | ---: |
| 1 | 1.169 MiB | 2 |
| 10 | 3.713 MiB | 11 |
| 50 | 19.0 MiB | 51 |
| 100 | 37.9 MiB | 101 |
| 100, after completion | 37.9 MiB | 101 |

The retained worker high-water is an implementation fact of `Io.Threaded`.
The roughly 1.6 GiB obtained by multiplying Zig's default 16 MiB stack request
by 100 is virtual address reservation, not measured RSS. A ReleaseFast control
with the unnecessary alternate signal stack disabled measured 11.3 MiB at 101
threads, versus 38.0 MiB with the default signal-stack option. Production and
diagnostic build policies must remain explicit.

The production-shaped HTTPS comparison measured approximately:

| Capacity 100 topology | Active physical memory | Retained after churn |
| --- | ---: | ---: |
| current-like Zig `std.http` | about 30 MiB | not the chosen V1 path |
| blocking libcurl easy | about 8.4 MiB | about 10.0 MiB |
| libcurl multi control | about 4.8 MiB | about 4.9 MiB |

The roughly 3.6 MiB active and 5.1 MiB retained advantage of multi does not
justify a second transfer lifecycle, callback owner, wake path, and storage
handoff in V1. Reconsider multi only for a demonstrated shutdown, energy,
descriptor, connection, throughput, or materially larger whole-process memory
failure.

## Allocation topology

| Resource | Owner | Bound | Release boundary |
| --- | --- | --- | --- |
| Activation Slot | Host Runtime | exactly `active_capacity` | end of each semantic quantum |
| Execution Cell | Host Runtime | exactly `active_capacity` | after departure and closure reconciliation |
| `AttemptIo` identities and refs | one fixed cell | at most admitted Attempts | executor departure |
| Transient result scratch | active `AttemptIo` | one bounded capture per live effect | publication, abort, or process exit |
| Group closure and native worker | injected `Io.Threaded` | admitted/reserved tasks | closure returns; workers may remain pooled |
| Transport/TLS/parser | owning adapter task | active model Attempts | provider settlement |
| Bash/patch state | owning adapter task | active effect Attempts | typed settlement/uncertainty classification |
| Wake event | Host Runtime | one | Host shutdown |
| Semantic validation workspace | live closure owner | independent bounded workspace | end of admission quantum |

No row or content payload is copied into the fixed cell. No durable Session
directory, file handle, or lock is retained while dormant.

## Cancellation and shutdown

`Group.cancel` is cooperative and waits for members. Libcurl easy observes one
per-cell cancellation/deadline state in read, write, and progress callbacks and
uses bounded connect and whole-call deadlines. OnePage therefore:

- stops new reservations first;
- durably records cancellation intent and preserves effect-specific uncertainty;
- marks active cells cancelled and lets their owning tasks settle or abort;
- waits for the Group exactly once before destroying cells, scratch owners,
  Storage Owner state, or the Host Runtime;
- never recycles a generation while its task may still access that cell; and
- treats process exit as the final recovery boundary if a system DNS call does
  not honor the graceful-close interval.

V1 does not claim a hard DNS-inclusive reusable-process close deadline. A
foreground CLI may terminate after its documented grace interval. The admitted
Attempt remains sufficient for deterministic recovery on restart.

## Rejected alternatives

- `Group.async`: may execute eagerly inside `drive`.
- Commit then reserve: turns capacity failure into an interrupted Attempt.
- One Future per Attempt: adds a retained join object without new authority.
- In-memory ready/completion queues: duplicate durable readiness and need their
  own overflow and recovery contracts.
- Passing `Session` or `ProviderIo` to the task: retains semantic owner state and
  gives the executor broader content authority than the Attempt requires.
- Per-Session filesystem ownership: superseded by the single SQLite durable
  store and bounded transient capture.
- `Io.Evented` on macOS Zig 0.16: networking is unavailable.
- A custom HTTP engine or libcurl multi now: additional lifecycle machinery
  without a measured V1 requirement.

## V1 implementation and measurement gate

1. Add the fixed cell table, one Group, and one Host wake; assert exact sizes.
2. Introduce `AttemptIo` with Session identity/epoch, permitted SQLite refs,
   transient scratch, and pre-bound publication authority.
3. Prove executor code cannot run before Attempt commit or inside `drive`.
4. Move executor context to cell identity/generation and immutable Attempt refs.
5. Publish content plus Completion atomically, close transient resources, then
   set the wake hint.
6. Prioritize closure cells over new admission and retain capacity-one semantic
   validation.
7. Rebuild effect fences and interrupted Attempts from SQLite after restart.
8. Test lost/duplicate/stale wakes, reservation/commit failure, cancellation,
   whole-Host join, transient-capture cleanup, and historical-cycle leaks.
9. Use one blocking libcurl easy call per model Attempt; classify callback aborts
   from the first local disposition, never `CURLcode` alone.
10. Run 1/10/50/100 production measurements for memory, threads, descriptors,
    energy/wakeups, throughput, cancellation, shutdown, and post-churn state.

This leaves V1 with one runtime, one durable authority, one transferable
capacity model, one bounded transient effect lease, and one volatile wake hint.
