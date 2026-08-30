# Host Runtime asynchronous execution design

Research date: 2026-08-30

Governing work: [issue #34](https://github.com/DivyanshGolyan/onepage/issues/34)

Inspected OnePage revision: `bf6081e8a502435457ba6c23c78dbd9e908b9615`

Inspected toolchain: Zig 0.16.0 on aarch64 macOS

## Decision

Keep one fixed `ExecutionCell[active_capacity]` table and one coalescing Host
wake event. Use the injected `std.Io.Threaded` implementation for bounded model,
Bash, patch, and other blocking effects. V1 uses blocking libcurl easy for the
model transport. The measured capacity-100 multi control saves about 3.6 MiB
active and 5.1 MiB retained against easy, which does not justify a second
transfer lifecycle, callback owner, wake path, and local-I/O handoff. Whenever
`Io.Threaded` owns an
Attempt, submit it with one long-lived `std.Io.Group` and `Group.concurrent`, not
`Group.async` and not one retained `Future` per Attempt. An executor receives
only a cell index and generation plus a narrow detached `AttemptIo` lease; it
never receives a Harness or semantic `Session` pointer.

Reserve actual executor concurrency before committing an Attempt by starting a
task that waits on its cell's start gate. If `Group.concurrent` returns
`ConcurrencyUnavailable`, release the cell and return bounded `busy` before
Attempt admission. After the Attempt transaction commits, transfer the Active
Credit to the Attempt and open the gate. If the transaction fails, open the
gate in the aborted state and wait for that task to depart before reusing the
cell. This is the smallest shape that satisfies all three existing rules:

1. capacity failure occurs before Attempt admission;
2. Attempt admission commits before an executor can observe or perform the
   effect; and
3. `drive` cannot run the provider or tool synchronously.

The detached lease is the central new ownership seam. Current `ProviderIo`,
`BlobReader`, and `BlobWriter` point back to a live `Session`; that Session owns
the exclusive Session directory lock. `Session.openExisting` clears provisional
drafts only after acquiring that lock. Spawning current `ProviderIo` and then
destroying Harness would therefore either retain a semantic Session indirectly
or let a fresh opener race a live `.drafts` writer. Issue #34 must transfer the
directory handle, exclusive lock, exact ownership identity, permitted immutable
blob references, and one predetermined result reference into `AttemptIo` after
Attempt commit. The old semantic Session is then invalidated without unlocking
those transferred handles.

The executor durably publishes immutable evidence and a Completion Inbox row,
releases transport or process resources, closes `AttemptIo` and its Session
lock, release-stores a generation-tagged departure marker, and sets the Host
wake event. The owner alone transitions the cell to closure. The event and
marker are only wake hints. The Completion Inbox remains recovery truth. Only
after the detached lease releases the lock can a fresh Harness open the Session,
perform `offer / drive` and semantic admission, and either release the credit or
transfer it to a later Attempt.

Do not add a general scheduler, a per-Session actor, an allocator-backed ready
queue, or a resident registry of durable Sessions.
[Issue #35](https://github.com/DivyanshGolyan/onepage/issues/35) owns durable Job
identity and rebuildable readiness indexing. Issue #34 needs only bounded
Active-Credit ownership, executor dispatch, closure priority, and bounded
durable reconciliation. Do not add a second provider/effect task capacity in
V1: Active Credits already cap executor tasks. Add a distinct private permit
only if the real Codex Run work in
[issue #43](https://github.com/DivyanshGolyan/onepage/issues/43) measures a
separate physical bottleneck that Active Credits cannot express.

This decision was intentionally conditional on measurement. The follow-up
capacity-100 HTTPS spike below found that current-like Zig `std.http` ownership
uses about 30 MiB physical memory even with a one-certificate trust bundle, and
that one independently loaded macOS trust bundle per active request adds about
another 21 MiB over its idle baseline. Blocking libcurl easy measured about
8.4 MiB active and 10.0 MiB retained; the multi control measured about 4.8 MiB
active and 4.9 MiB retained. Easy therefore removes the material custom-client
cost while preserving the synchronous Provider settlement seam. Multi remains
a deferred response to a demonstrated shutdown, energy, connection, throughput,
or substantially larger memory failure rather than the V1 default.

## The fundamental tension

OnePage has four different populations that must not be conflated:

| Population | Bound and residence |
| --- | --- |
| Durable Sessions and Jobs | Potentially thousands; storage facts only while dormant or Awaiting User. |
| Live semantic owners | At most `active_capacity`; each may borrow one Activation Slot for one bounded quantum. |
| Admitted external Attempts | At most the remaining Active Credits; each retains one bounded adapter resource but no Harness or Activation Slot. |
| Physical executor workers | Backend-specific. With Zig 0.16 `Io.Threaded`, a blocked adapter normally occupies a native worker thread; this is not a logical-agent invariant. |

The invariant is:

```text
live Harness owners + admitted Attempts + closure handoffs <= active_capacity
occupied Activation Slots <= live Harness owners
executor tasks <= admitted Attempts
```

An Active Credit is therefore transferable semantic capacity, not a bundle of
one Slot, stack, TLS connection, parser, process, and validation workspace. An
admitted external Attempt does, however, need one bounded detached filesystem
and completion-publication lease because its provisional output must remain
under the Session's exclusive lock. The physical relationship between an
executor task and an operating-system thread is an implementation fact of the
selected Zig backend and must be reported separately.

## What Zig 0.16 actually permits on macOS

Zig 0.16 describes `Io.Threaded` as feature-complete and well tested and
`Io.Evented` as experimental. It also explicitly permits `async` work to run
eagerly on the caller, while `concurrent` either arranges true concurrency or
returns `ConcurrencyUnavailable` ([Zig 0.16 I/O overview and Future
semantics](https://ziglang.org/download/0.16.0/release-notes.html#I-O-as-an-Interface)).
That distinction is architectural here: `Group.async` can invoke a provider or
tool inside `drive`, so it cannot implement issue #34.

The installed Zig 0.16 source adds several relevant details:

- `std.process.Init.io` is a process-owned `Io.Threaded` constructed by
  [Zig's startup path](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/start.zig).
  Its `concurrent_limit` defaults to unlimited, while
  `async_limit` defaults to approximately the logical CPU count minus one.
- `Group.concurrent` copies a small task context into an implementation-owned
  closure. In `Io.Threaded`, it returns `ConcurrencyUnavailable` rather than
  falling back to caller execution when allocation, the configured concurrency
  limit, or worker creation prevents concurrency.
- A `Group` releases each task's closure when that task returns; a long-lived
  Group is therefore suitable for resultless executor tasks. A `Future` retains
  its result/context object until an explicit await or cancel and adds a
  per-Attempt join object that OnePage does not otherwise need. The public
  `Group` contract is in [`std.Io`](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/Io.zig#L1205-L1305),
  and the worker/limit behavior is in
  [`Io.Threaded`](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/Io/Threaded.zig).
- `Io.Threaded` grows a detached worker pool when all current workers are busy.
  Idle workers wait for more work and remain until `Io.Threaded.deinit`; peak
  simultaneous blocking work can therefore become the process's retained
  worker high-water.
- The native thread stack request defaults to 16 MiB, and Zig normally installs
  a 256 KiB alternate signal stack per worker
  ([`std.Thread`](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/Thread.zig),
  [`std.options`](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/std.zig)).
  These figures describe address-space reservation and thread-local storage,
  not physical resident memory.
- On macOS, `Io.Evented` aliases `Io.Dispatch`. The Zig 0.16 release notes state
  that Evented networking is not implemented
  ([networking status](https://ziglang.org/download/0.16.0/release-notes.html#Networking));
  the inspected `Dispatch` vtable maps network connect/read/write/send to
  unavailable operations. It also allocates a large userspace fiber reservation
  per task. It is not a viable V1 provider backend or a fair live-transport
  comparison.

`std.http` and DNS can create nested `Io` work. Consequently, the exact worker
count is not proven by `executor tasks == active_capacity`: real HTTPS handshake
bursts, DNS, TLS, streaming, Bash, and patch execution all need measurement.
OnePage should keep using the injected `Io` rather than create another Threaded
runtime with its own signal handlers and lifetime merely to tune stack size.
Zig's startup path does not pass an application-configurable stack size into
the process-owned runtime. V1 accepts and reports its 16 MiB-per-worker virtual
reservation unless physical measurements or supported tooling establish a hard
failure; virtual arithmetic alone does not justify a second executor.

## Measured macOS topology

A local Zig 0.16 spike submitted sleep-only `Group.concurrent` tasks, touched
64 KiB on each worker stack, and measured process physical footprint and thread
count. It is evidence for the current machine and build, not a universal
constant:

| Concurrent tasks | Physical footprint | Process threads |
| ---: | ---: | ---: |
| 1 | 1.169 MiB | 2 |
| 10 | 3.713 MiB | 11 |
| 50 | 19.0 MiB | 51 |
| 100 | 37.9 MiB | 101 |
| 100, after every task completed | 37.9 MiB | 101 |

The persistence result matches the Threaded worker lifecycle. It also shows why
the 16 MiB default stack request must not be multiplied and presented as RSS:
100 workers request roughly 1.6 GiB of stack address space, but this experiment
measured 37.9 MiB of physical footprint after touching 64 KiB per worker.

Most of that synthetic physical slope came from a release-build facility that
the production binary does not need. Zig attaches a 256 KiB alternate signal
stack to every thread whenever `std.options.signal_stack_size` is non-null,
even though the default segmentation-fault handler is disabled when runtime
safety is disabled. Repeating the 100-task ReleaseFast spike with only
`signal_stack_size = null` measured 11.3 MiB and the same 101 threads, versus
38.0 MiB with the default option. The Threaded cancellation signal handler does
not request the alternate stack.

V1 should therefore retain Zig's default alternate signal stacks in Debug and
ReleaseSafe, where stack-overflow diagnostics are valuable, but disable them in
the optimized production root when the segmentation-fault handler is disabled.
This is a build-mode memory policy, not a smaller worker stack and not evidence
that real DNS/TLS/HTTP calls peak at 11.3 MiB. The production transport matrix
must repeat both the memory and failure-diagnostic checks.

An Evented control reached about 15.3 MiB and 8 threads at 100 tasks, but it
could not run macOS networking and did not complete the same clean lifecycle in
the spike. It is useful only as evidence that event-driven execution can have a
different physical slope, not as an available OnePage implementation.

### Controlled HTTPS transport spike

A second throwaway spike compared three clients against the same local Python
TLS server. Every run opened the stated number of simultaneous verified HTTPS
connections, waited six seconds for a 1 KiB response, disabled the unused Zig
alternate signal stack in optimized builds, and measured the process with
macOS `footprint`, `vmmap`, `ps`, and `lsof`. The certificate and response were
deliberately small. The numbers isolate transport execution and do not include
OnePage's SSE projection, decoded candidate, Blob Writer, SQLite, Harness, or
Activation Slots.

| Capacity 100 client | Active physical footprint | Physical after requests | Threads active / after | Virtual regular stacks |
| --- | ---: | ---: | ---: | ---: |
| Current-like Zig `std.http`, one Client and one tiny CA per request | 30.0 MiB | 22.0 MiB | 101 / 101 | 1,638 MiB |
| Zig workers running blocking libcurl easy transfers | 8.4 MiB | 10.0 MiB | 103 / 102 | 1,638 MiB |
| One libcurl multi owner | 4.8 MiB | 4.9 MiB | 3 / 2 | 9 MiB |

The current-like Zig client touched about 20.4 MiB of regular stack pages at
capacity 100. The earlier 11.3 MiB sleep result was therefore not representative
of the real TLS call path. The virtual 1.6 GiB remains address-space reservation,
not RAM.

The production path has another multiplier not represented by the tiny local
CA. `NativeTransport.performRequest` constructs one `std.http.Client` per call,
and a fresh client scans and retains its own trust bundle until deinit. A
separate controlled run held independently scanned macOS trust bundles without
network activity:

| Concurrent fresh Zig clients | Active physical footprint | Physical after deinit |
| ---: | ---: | ---: |
| 1 | 1.13 MiB | 0.94 MiB |
| 10 | 3.11 MiB | 1.24 MiB |
| 50 | 12.0 MiB | 2.24 MiB |
| 100 | 22.0 MiB | 3.44 MiB |

Against the 0.81 MiB idle baseline, capacity 100 adds about 21.2 MiB while the
trust bundles are live. The test does not establish that this amount adds
perfectly to the HTTPS result, but it proves that independent clients make
certificate authority state another population-scaled owned resource. A
long-lived shared Zig client is therefore the minimum correction even if
libcurl is rejected.

The libcurl multi result has about a 2.8 MiB active increment over its own
2.0 MiB idle process, compared with about 29.2 MiB for current-like Zig HTTPS.
At capacity 100 the measured difference is about 25 MiB active and 17 MiB after
completion, before accounting for the production path's larger trust store or
nested timeout tasks. The six-second fixture made throughput effectively equal;
an attempted zero-delay local TLS timing run deadlocked in the fixture and is
not evidence. A production decision still requires the real SSE parser and
durable sink to prove that bounded callbacks do not stall unrelated libcurl
transfers.

The current OnePage `ActivationSlot` is 8,360 bytes, so 100 Slots occupy about
816 KiB before pool metadata. The measured Threaded executor topology already
dominates Slot memory by an order of magnitude. Optimizing the Slot cannot
solve a transport/thread multiplier.

A separate ReleaseSafe two-cell ownership prototype passed four focused tests:
credit transfer across Harness/Attempt/closure owners, recovery of durable
terminal evidence after dropping the wake hint, crash reconstruction of a
same-Workspace effect fence, and rejection of stale or duplicate completion
generations. This is local research evidence that the fixed-cell ownership
model is implementable; it is not production code and does not validate
Session-lock transfer, real transport memory, cancellation, or throughput.

## Prior art and the boundary to adopt

### Transferable capacity, not queue length

Tokio's owned semaphore permit can move into a spawned task and releases its
capacity when dropped. Its bounded channel can reserve capacity before a value
is produced, and dropping an unused reservation returns capacity
([owned semaphore permits](https://docs.rs/tokio/latest/tokio/sync/struct.Semaphore.html#method.acquire_owned),
[bounded sender capacity](https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Sender.html#method.reserve_owned)).
This supports OnePage's Active-Credit transfer and the need to reserve executor
capacity before committing an Attempt. It does not justify importing a channel:
the Session Ledger and Completion Inbox already hold durable work. A second
queue would introduce another lifetime, ordering rule, and overload state.

### Durable completion versus a wake packet

Windows I/O completion ports associate many asynchronous endpoints with one
completion queue and separately control how many worker threads may run. The
kernel queues completion packets after operations complete, and applications
may also post their own packets
([Microsoft IOCP documentation](https://learn.microsoft.com/en-us/windows/win32/fileio/i-o-completion-ports)).
The useful analogy is separation, not API imitation: logical in-flight I/O,
queued notification, and runnable worker concurrency are different resources.
For OnePage, a small wake event says only "inspect committed state". It cannot
carry Completion authority.

### Stage admission without a staged framework

SEDA makes queues and thread pools explicit between stages so each stage can
apply load conditioning and expose overload
([Welsh, Culler, and Brewer, SOSP 2001](https://people.eecs.berkeley.edu/~brewer/papers/SEDA-sosp.pdf)).
OnePage should adopt explicit ownership and per-stage limits, but not SEDA's
network of queues and controllers. V1 has a fixed semantic owner stage, an
external-effect stage, and a shared closure/validation stage. Active Credits,
the fixed cell table, Workspace fences, and the shared validator already expose
their bounds without a generic stage framework.

### Fixed handoff and release/rebuild

Ghostty's active terminal I/O uses a fixed set of buffers with explicit stage
ownership and backpressure rather than allowing the producer to grow a queue
([Ghostty `Exec.zig`](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/Exec.zig#L1293-L1408)).
Its mailbox separates publication from notification and allows one notification
to wake a consumer that drains available work
([Ghostty mailbox](https://github.com/ghostty-org/ghostty/blob/6a508fd5e34c7e222c052a6d00bb3891ff3feace/src/termio/mailbox.zig#L57-L108)).
Its later memory work preserves semantic terminal state while releasing
reconstructible hidden-surface and cold-history working sets
([history compression PR](https://github.com/ghostty-org/ghostty/pull/13264),
[hidden-surface GPU release PR](https://github.com/ghostty-org/ghostty/pull/14017)).

The OnePage translation is direct: retain the admitted Attempt and Completion
evidence; discard the Harness, Slot, transport, and parser state as soon as the
durable boundary allows; use generations so a recycled cell cannot accept a
late notification.

## The detached Attempt I/O lease

The current code has a deeper coupling than its provider-facing capability
suggests. [`model_operation.ProviderIo`](https://github.com/DivyanshGolyan/onepage/blob/bf6081e8a502435457ba6c23c78dbd9e908b9615/src/model_operation.zig#L595-L689)
contains `*Session`; its request reader and candidate writer contain the same
pointer; `Session` owns the exclusive `owner.lock` and directory; and
[`Session.openExisting`](https://github.com/DivyanshGolyan/onepage/blob/bf6081e8a502435457ba6c23c78dbd9e908b9615/src/session.zig#L767-L807)
resets `.drafts` on the proof that the newly acquired lock excludes all live
writers. [`blob_store.resetDrafts`](https://github.com/DivyanshGolyan/onepage/blob/bf6081e8a502435457ba6c23c78dbd9e908b9615/src/blob_store.zig#L147-L174)
states that lock requirement explicitly. That ownership is correct
synchronously and prevents draft corruption. It must be preserved, not
bypassed, when execution moves to another task.

`AttemptIo` should be a stripped, move-only leaf capability with these
properties:

- It owns the moved Session directory and exclusive lock, injected `Io`, exact
  Session/Agent/ownership-epoch/Operation/Attempt identity, permitted immutable
  request and descriptor references, and the predetermined result reference.
- It can open bounded read windows only over the references bound to the
  admitted Attempt, create/append/settle only that result, compute its digest,
  and publish only the corresponding typed Completion evidence.
- Its publication method accepts result settlement, not arbitrary Session or
  Attempt identities. The exact Completion binding is prepared by Attempt
  admission, so an adapter cannot manufacture another envelope.
- It cannot read or mutate resident Core, Conversation indexes, Session policy,
  authorization, ledger facts, or ownership state. It contains no reconstructed
  semantic graph and no Activation Slot.
- Normal close aborts an unfinished draft, closes readers/writers, releases the
  directory lock, and invalidates the lease. Process death lets the OS release
  the lock; the next legitimate Session owner may then perform the existing
  bounded draft reset.

Completion publication must move behind a narrow Storage Owner operation that
does not require resident `Session` semantic state. It should receive the
pre-bound Attempt completion authority plus the sealed result reference and
digest, commit the Completion Inbox row, and return its Inbox identity. Later
Harness recovery performs the full durable semantic validation already required
before those bytes can acquire Session authority. This retains the existing
evidence-versus-authority split.

Do not solve this by leaving the Session unlocked while an adapter writes, by
making `.drafts` globally concurrent, or by keeping the entire current Session
inside an executor closure. The first two break the cleanup proof; the third
makes an In-flight Session resident and violates issue #34. The detached lease
is bounded by Active Credits and is the minimum state external work genuinely
needs.

A local aarch64 ReleaseSafe type probe measured the current `Session` at 7,720
bytes, `BlobReader` at 72 bytes, `BlobWriter` at 160 bytes, and `ProviderIo` at
288 bytes. `ProviderIo`'s figure excludes the Session to which it points. The
same probe measured `std.Io.Event` at 4 bytes and `std.Io.Group` at 16 bytes.
These are current type-layout facts, not a proposed `AttemptIo` budget. They
show that retaining the complete Session is avoidable; the new lease's exact
size and handle topology must be asserted after its fields are justified.

## Smallest V1 state machine

Each Active Credit has one fixed cell. The cell is not a semantic Session object
and does not contain variable provider output, a parser, a TLS connection, a
subprocess buffer, Conversation state, Core State, or validation scratch. While
an Attempt is admitted, it contains the bounded `AttemptIo` lease that owns the
Session filesystem lock and exact content/publication authority.

```text
free
  -> harness_owned
  -> executor_reserved       Group.concurrent succeeded; task waits on gate
  -> attempt_in_flight       Attempt committed; gate opened
  -> task_departed           atomic marker; evidence/recovery is durable
  -> closure_ready           Host owner alone performs this transition
  -> harness_owned           fresh Harness applies offer/drive
  -> free | executor_reserved
```

Awaiting User moves from `harness_owned` to `free`; the immutable request remains
durable. Capacity or Workspace-fence contention also releases the credit and
leaves readiness durable. A terminal closure moves to `free`. Every reuse
increments the cell generation.

The dispatch sequence should be:

1. Borrow an existing Active Credit and Activation Slot through the current
   owner path.
2. Prepare the immutable typed executor input. Keep variable content in the
   existing immutable blob/content owners; the cell holds only identities,
   generations, references, and fixed control state.
3. Acquire the Workspace Effect Fence when required. Store fence ownership in
   the same fixed cell and detect conflicts by scanning at most
   `active_capacity` cells; do not add a second map.
4. Reset the cell's atomic start decision and generation-tagged departure
   marker and call `Group.concurrent` with only
   `{ host, cell_index, generation }`. The task waits for start or abort.
5. If reservation fails, release the fence and return `busy` before Attempt
   admission. If it succeeds, commit Attempt admission and credit transfer.
6. Infallibly move the Session directory/lock and exact bound content authority
   from the semantic owner into the cell's `AttemptIo`; invalidate the old
   Session without closing those moved handles.
7. Publish start by setting the gate, scrub and release the Activation Slot,
   destroy the Harness, and return to the foreground owner loop.
8. The task rechecks generation, reads only the admitted immutable input through
   `AttemptIo`, performs the adapter operation, and publishes exact Completion
   evidence through the Storage Owner.
9. The task releases transport/process state and closes `AttemptIo` and the
   Session lock. It copies the Host wake pointer locally, release-stores its
   generation into the atomic departure marker as its final cell access, sets
   the Host wake event, and returns. Its Group closure then self-releases.
10. The Host acquire-loads a matching departure generation and is the only code
   that transitions the non-atomic cell state to `closure_ready`. It can now
   acquire the Session lock in a fresh Harness, offer the
   durable evidence, drive one bounded quantum, and release or transfer the
   same credit.

If the Attempt transaction fails after task reservation, the Host marks the
cell aborted, opens the gate, and waits for task departure before incrementing
the generation or reusing the cell. The same release-store/acquire-load marker
proves departure on this pre-commit abort path. The task never writes a
non-atomic cell union while the owner may scan it. This is a narrow
prepare/commit/publish mechanism, not a general executor protocol.

### Wake without a completion queue

Use one process-local Host `Io.Event` plus generation-tagged atomic departure
markers in the fixed cells. A producer sets the event only after Completion
Inbox publication or a classified executor failure, adapter cleanup, lock
release, and its final release-store to the cell. The owner resets the event,
acquire-scans the bounded markers and durable readiness, and waits only if
neither contains work. Reset-before-scan avoids a lost-wakeup window: a set
before the reset is recovered by the scan, and a set after the reset remains
observable by either the scan or wait.

Dropped, duplicated, stale, or process-lost wakes are harmless. The cell
generation rejects late in-process hints. On fresh-process recovery no old
executor is presumed alive. The Host reconstructs at most `active_capacity`
recovery/closure owners and their effect fences from durable non-terminal
Attempts, queries bounded Completion Inbox evidence, and applies the existing
effect-specific interrupted-Attempt rules. It does not rebuild a heap object
for every Session. Later Run/Job readiness comes from the rebuildable durable
index owned by issue #35.

## Allocation topology

| Resource | Owner | Multiplier and maximum | Release boundary | Failure behavior |
| --- | --- | --- | --- | --- |
| Activation Slot | Host Runtime | Exactly `active_capacity`; current size 8,360 B each | End of every Harness owner quantum | Borrow failure is bounded `busy`; no overflow allocation. |
| Execution Cell and detached `AttemptIo` storage | Host Runtime | Exactly `active_capacity`; exact type size and live handle counts must be asserted and reported | Task release-stores its generation after closing `AttemptIo`; owner acquire-loads it before `closure_ready`; cell returns to `free` only after closure/control settlement | No overflow cell, unlocked draft writer, data race, or waiting-node allocation. |
| Group task closure | Injected `Io.Threaded` | At most admitted/reserved executor tasks, itself bounded by Active Credits | Automatically when that task returns | Reservation failure occurs before Attempt commit. |
| Native worker stack, alternate signal stack, and TLS | Injected `Io.Threaded`/OS | Worker high-water; ordinarily approaches simultaneous blocking work and may include nested `std.Io` tasks | Workers persist until process `Io.Threaded` deinit | Host must measure and report this retained high-water. |
| Blocking model transport | Owning adapter task and libcurl | At most model Attempts, bounded by Active Credits; one easy handle, socket/TLS state, possible resolver thread, fixed request-encoder state, and bounded Capture per live transfer | Provider return, before Host settlement and `closure_ready` wake | Local callback disposition distinguishes terminal, cancellation, deadline, parser/resource failure, and upload uncertainty; no hidden replay. |
| Bash/patch state | Owning adapter task | Only Attempts of that effect class; no preallocated bundle per credit | Before `closure_ready` wake | Existing typed failure or effect-specific uncertainty; no hidden retry. |
| Wake event | Host Runtime | One | Host shutdown | Notification may coalesce; durable evidence cannot. |
| Semantic validation workspace | Storage/Harness closure owner | V1 capacity one, independent of `active_capacity` | End of one bounded admission | Closure waits/retries from durable evidence and outranks new admission. |
| Workspace fence | Same fixed cell table | At most effect Attempts, bounded by `active_capacity` | Terminal evidence application/control settlement | Contention before Attempt admission releases credit; recovery rebuilds from durable Attempts. |

The task closure allocation is an implementation detail of `std.Io`, but it is
still part of OnePage's topology and must be counted. No claim should sum the
16 MiB stack request as physical memory or exclude the worker pool because Zig
owns it.

## Cancellation, shutdown, and joining

`Group.cancel` is cooperative and waits for every member to finish; cancellation
is observed at `Io` cancellation points. Libcurl easy additionally observes the
owning cell's cancellation state in read, write, and progress callbacks and uses
connect and whole-call deadlines. It is not abandonment and it is not a semantic
rollback. OnePage should therefore:

- commit User/Run cancellation intent and apply the existing effect-specific
  rules before treating an Attempt as settled;
- make every built-in adapter cancellation-aware and bound provider deadlines,
  process-group termination, and cleanup;
- stop new executor reservations during Host shutdown, settle or cancel
  admitted work, then `Group.cancel`/`Group.await` exactly once before destroying
  cells or Host resources;
- keep each detached Session lock held until that task has closed every draft,
  reader, writer, and external resource; fresh semantic ownership must never
  race leaf I/O cleanup;
- never recycle a cell while its task may still retain the cell index and
  generation; and
- preserve Bash/patch/model uncertainty when process death or cancellation
  crosses the external-effect boundary.

There is deliberately no per-task Future just to join it. Normal task departure
is reflected by the fixed cell transition; the Group supplies whole-Host join
at shutdown. A cancellation-insensitive adapter can delay shutdown, so the V1
adapters must have bounded cancellation paths and tests rather than assuming
the runtime can forcibly reclaim a stack safely. V1 claims two different
guarantees: ordinary graceful cancellation and process-exit recovery. It does
not claim that blocking easy can make a wedged system DNS lookup return within a
hard reusable-process deadline. A timed-out close leaves referenced Host state
intact; the foreground CLI may terminate the process after its grace period and
let durable Attempt recovery classify the missing Completion on restart.

## Rejected alternatives

- **`Group.async`:** may execute eagerly on the Harness owner and violates the
  required dispatch boundary.
- **Commit then call `Group.concurrent`:** a concurrency/allocation failure
  after Attempt admission turns temporary capacity exhaustion into recovery
  state. The gated pre-reservation avoids that hole.
- **One Future per Attempt:** adds retained result/join objects and explicit
  per-task cleanup without giving OnePage authority it needs.
- **An in-memory ready or completion queue:** duplicates durable readiness,
  needs its own overflow/order/recovery rules, and tends to create one node per
  logical Session. Fixed cells plus one coalescing wake are enough.
- **Passing current `ProviderIo` to the task:** it retains `*Session` through
  both Blob capabilities. Closing that Session invalidates live I/O; retaining
  it retains semantic owner state; unlocking it lets draft cleanup race. Move a
  stripped `AttemptIo` lease instead.
- **`Io.Evented` on macOS:** experimental, lacks networking in Zig 0.16, and has
  a materially different fiber reservation/lifecycle. It cannot run the V1
  vertical slice.
- **A custom kqueue/Network.framework HTTP engine:** replaces supported TLS,
  redirects, proxies, cancellation, and HTTP behavior merely to reduce a
  topology that has not yet failed the real workload budget.
- **libcurl multi now:** the official multi API can run multiple transfers on
  one thread and is designed to scale beyond thousands of connections
  ([libcurl multi overview](https://curl.se/libcurl/c/libcurl-multi.html)). It is
  the most credible deferred alternative if the blocking topology fails a hard
  shutdown, energy, descriptor, connection, throughput, or whole-process memory
  gate. The measured single-digit-MiB saving at capacity 100 does not by itself
  justify its transfer owner, callback lifecycle, wake path, and local-I/O handoff.
- **A SEDA scheduler:** stage accounting is useful; a public stage graph,
  dynamic controllers, and multiple queues are not required by one foreground
  Host owner.

## Measurement gate

The sleep spike establishes neither real provider footprint nor production
throughput. Before claiming capacity 100, measure `active_capacity` 1, 10, 50,
and 100 with dormant population fixed. Run at least these phases:

1. executor reservation before gate release;
2. DNS/connect/TLS handshake burst;
3. providers blocked waiting for first bytes;
4. maximum-rate streaming with a slow durable sink;
5. Bash and patch execution, including maximum bounded capture;
6. Completion publication plus shared semantic admission backlog;
7. all Attempts completed while the process remains alive; and
8. cancellation and Host shutdown under each external wait.

Record, rather than infer:

- macOS physical footprint, RSS, compressed memory, and virtual size;
- process thread count and per-thread stack reservations at peak and after all
  work completes;
- allocator live and high-water bytes by Execution Cell, Group closure,
  provider, TLS/HTTP, parser, blob writer, SQLite, and diagnostics;
- active sockets and kernel/user transport buffer observations where the OS
  exposes them;
- cell occupancy, Activation Slot occupancy, semantic-validation backlog, and
  durable Completion Inbox high water;
- thread-creation ramp, provider throughput, completion-to-closure latency, and
  cancellation/join latency; and
- Debug, ReleaseSafe, and ReleaseSmall behavior, because stack use and
  instrumentation differ by build.

The report must show an analytical bound and the measured slope separately.
`16 MiB * worker count` is virtual stack reservation, not RSS. The sleep spike's
37.9 MiB is physical evidence for one synthetic workload, not a maximum for
HTTPS/TLS. The current Slot size is a compile-time fact, not total active-agent
memory.

If production-shaped capacity-100 measurements keep blocking easy within the
declared Host budget, ship it. Reconsider multi only when easy fails a declared
hard gate or multi saves at least about 15 MiB or 15 percent of the active
whole-process budget. Do not tune Zig stack size or build a custom event loop
from virtual-address arithmetic alone.

## V1 implementation checklist

1. Add the fixed cell table, one Group, and one Host wake event; assert and
   report their exact sizes.
2. Introduce `AttemptIo` by moving the Session directory/lock and exact bound
   content/publication authority out of the semantic Session after commit;
   remove leaf readers/writers' dependency on `*Session`.
3. Implement gated `Group.concurrent` reservation and prove that provider/tool
   code cannot run before Attempt commit or inside `drive`.
4. Move executor context from Harness pointers to cell identity/generation and
   immutable Attempt inputs.
5. Publish Completion Inbox evidence, release the `AttemptIo` lock, and only
   then set the wake hint; remove all correctness dependence on notification
   delivery.
6. Give closure cells priority over admitting new Attempts and keep the shared
   semantic workspace at capacity one.
7. Represent effect-fence ownership in the fixed cells and rebuild it from
   durable non-terminal Attempts after restart.
8. Add lost/duplicate/stale/full wake, reservation failure, commit failure after
   reservation, draft-cleanup exclusion, cancellation, whole-Host join, and
   historical-cycle leak tests.
9. Replace the nested `std.http` request/timeout race with one blocking libcurl
   easy call on the owning task. Stream request bytes through fixed resumable
   encoder state, stream response bytes into the existing Capture, and classify
   callback aborts from the first local disposition rather than `CURLcode` alone.
10. Run the real 1/10/50/100 measurement gate, including cold resolver-thread,
    descriptor, wakeup, cancellation, graceful-close, and post-churn evidence.

This gives V1 one runtime, one durable authority, one transferable capacity
model, and one volatile wake mechanism. Logical durability scales in SQLite;
only current Attempts multiply executor resources.
