# Fixed-credit harness spike

## Question

Can task, completion, permission, cancellation, and shutdown producers hand work to one owner without allocating, waiting, growing resident state, or bypassing durable-before-mutation ordering?

## External seam

The spike introduces two deep modules:

```zig
CoreContract.verify(wasm)

Harness.open(config)
Harness.offer(input)
Harness.drive()
```

`CoreContract` owns the current compiled-artifact structural policy. The host and build test pass Wasm bytes to one function instead of repeating individual section checks. Export-name and function-signature validation remain future ABI checks; the current verifier enforces export counts and kinds.

`Harness` owns fixed admission storage, input classification, persistence-before-apply ordering, bounded owner turns, committed projections, failure state, and shutdown scrubbing. Callers cannot separately drain a mailbox, close the owner, or mutate an execution slot in the wrong order.

## Resident bounds

Every public input is encoded into an exact 40-byte fixed-layout ingress record. Completion fields retain their previous widths; task, permission, cancellation, and shutdown use the same storage, with the input tag encoded in bits unused by that record kind. The harness contains storage for at most 32 records. Configuration may expose fewer credits but cannot grow the compiled maximum.

Every build mechanically enforces the two native byte bounds, and the test suite enforces the behavioral and Wasm bounds:

- `@sizeOf(Completion) == 40`;
- `@sizeOf(Entry) == 40`;
- `@sizeOf(Harness) <= 1,536` bytes;
- the real harness, durable adapter, and restored-slot metadata total exactly 1,536 bytes;
- exactly the configured number of inputs can be resident;
- a 10,000-cycle offer/drive run uses the same fixed object;
- the compiled core still has exactly one initial and maximum Wasm page and no `memory.grow` instruction.

This control-plane storage is native host memory, separate from the core's 64 KiB linear-memory page. It is fixed per resident harness owner, not per logical agent.

## Admission

`offer` copies one structurally valid input into the fixed ring and returns one normal disposition:

- `queued`: the volatile record now occupies one resident credit;
- `full`: every configured credit is occupied and ownership stays with the producer;
- `busy`: another producer or the owner currently holds the atomic admission lock;
- `unavailable`: the owner observed an uncertain transition failure and must be reconstructed;
- `closed`: teardown has started;
- `invalid`: a required identity, generation, reference, or digest is zero, or the input is incompatible with cancellation already in progress.

The call performs no allocation, system call, retry, or wait. Concurrent producers use a one-byte atomic try-lock. Contention returns `busy`; it never parks a callback thread. A four-producer test fills all 32 credits concurrently and proves that a thirty-third input is refused.

The owner currently keeps the admission lock for a whole `drive` call, including durable and apply callbacks. This deliberately makes producers receive `busy` while a transition is in progress. A later implementation can shorten the critical section with a claim state, but must first preserve the current no-copy/no-loss failure behavior.

`drive` is the only owner transition. Shutdown is offered through the ring and becomes `closed` only after earlier accepted inputs settle; there is no public `close` bypass. Transition callbacks must not reenter the harness.

## Owner transitions

`drive` is called by one owner and consumes at most the configured quantum. The transition adapter classifies the head input:

- `applicable`: persist the completion, then apply it;
- `durable`: recovery already observes the persisted completion, so apply without appending it again;
- `stale`: consume without persistence or mutation;
- `duplicate`: consume idempotently without persistence or mutation.

The ring releases a credit only after the selected path completes. A persistence or application error leaves the record resident, marks the harness unavailable, and prevents further offers or drives. Recovery constructs a fresh harness rather than guessing whether the failed owner can continue safely. Progress reports bounded counters, state, and projections created only after the authoritative transition commits.

Tests observe persistence before application through the same `drive` seam. Another test injects a failure after persistence but before application, discards that owner, reconstructs one over the same deterministic durable state, and proves that replay skips the second persistence and applies the logical transition exactly once. A third replay is classified as a duplicate.

## Current result

`zig build test -Doptimize=ReleaseSafe` now:

1. compiles the real `onepage-core.wasm` artifact;
2. runs `CoreContract.verify` over that artifact;
3. exercises exact admission capacity and concurrent producers;
4. proves durable-before-apply ordering;
5. rejects invalid and stale completions before mutation;
6. proves bounded owner quanta;
7. simulates crash/reconstruction after durable completion publication;
8. proves task, completion, permission, cancellation, and shutdown share the same durable path;
9. proves cancellation settles an already accepted completion before finishing;
10. proves fail-stop and offered-shutdown behavior;
11. runs 10,000 fixed-storage reuse cycles.

The existing memory-model and four-process lifecycle spikes continue to use the same compiled core and pass through the extracted contract verifier.

## Deliberate omissions

The deterministic transition adapter described by this spike has now been followed by the real journal/JSC integration in [`0005-owner-crash-recovery.md`](0005-owner-crash-recovery.md). Atomic checkpoint replacement and automatic recovery scanning beyond the offered operation remain absent.

Crash injection currently uses an explicit adapter failure, not process termination at every filesystem instruction. The test proves transition ordering and idempotent replay semantics, not parent-directory durability, power-loss behavior, or exactly-once external effects.

The ring protects concurrent producers with an atomic try-lock rather than a lock-free sequence-number queue. This is a deliberate small implementation: contention is visible and bounded. Replace it only after measurements show that `busy` materially harms completion delivery.

The owner-crash and atomic-checkpoint spikes now connect `Harness.drive` to the real operation journal, JavaScriptCore transition, and process-level crash boundaries. Session ownership and restoration are the next layer, tracked separately from this owner-loop contract.
