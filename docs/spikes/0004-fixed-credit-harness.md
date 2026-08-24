# Fixed-credit harness spike

## Question

Can completion producers hand work to one owner without allocating, waiting, growing resident state, or bypassing the durable-before-mutation ordering?

## External seam

The spike introduces two deep modules:

```zig
CoreContract.verify(wasm)

Harness.open(config)
Harness.offer(completion)
Harness.drive()
Harness.close()
```

`CoreContract` owns the current compiled-artifact structural policy. The host and build test pass Wasm bytes to one function instead of repeating individual section checks. Export-name and function-signature validation remain future ABI checks; the current verifier enforces export counts and kinds.

`Harness` owns fixed admission storage, completion classification, persistence-before-apply ordering, bounded owner turns, failure state, and scrubbing. Callers cannot separately drain a mailbox and mutate an execution slot in the wrong order.

## Resident bounds

The current completion record is an exact 40-byte fixed-layout value containing agent identity and generation, operation identity and generation, and a bounded result value. The harness contains storage for at most 32 records. Configuration may expose fewer credits but cannot grow the compiled maximum.

Every build mechanically enforces the two native byte bounds, and the test suite enforces the behavioral and Wasm bounds:

- `@sizeOf(Completion) == 40`;
- `@sizeOf(Harness) <= 1,536` bytes;
- exactly the configured number of completions can be resident;
- a 10,000-cycle offer/drive run uses the same fixed object;
- the compiled core still has exactly one initial and maximum Wasm page and no `memory.grow` instruction.

This control-plane storage is native host memory, separate from the core's 64 KiB linear-memory page. It is fixed per resident harness owner, not per logical agent.

## Admission

`offer` copies one structurally valid completion into the fixed ring and returns one normal disposition:

- `queued`: the volatile record now occupies one resident credit;
- `full`: every configured credit is occupied and ownership stays with the producer;
- `busy`: another producer or the owner currently holds the atomic admission lock;
- `unavailable`: the owner observed an uncertain transition failure and must be reconstructed;
- `closed`: teardown has started;
- `invalid`: an identity or generation is zero.

The call performs no allocation, system call, retry, or wait. Concurrent producers use a one-byte atomic try-lock. Contention returns `busy`; it never parks a callback thread. A four-producer test fills all 32 credits concurrently and proves that a thirty-third completion is refused.

The owner currently keeps the admission lock for a whole `drive` call, including durable and apply callbacks. This deliberately makes producers receive `busy` while a transition is in progress. A later implementation can shorten the critical section with a claim state, but must first preserve the current no-copy/no-loss failure behavior.

`drive` and `close` are owner-only operations. Transition callbacks must not reenter the harness, and `close` must run only after transition callbacks are quiescent.

## Owner transitions

`drive` is called by one owner and consumes at most the configured quantum. The transition adapter classifies the head completion:

- `applicable`: persist the completion, then apply it;
- `durable`: recovery already observes the persisted completion, so apply without appending it again;
- `stale`: consume without persistence or mutation;
- `duplicate`: consume idempotently without persistence or mutation.

The ring releases a credit only after the selected path completes. A persistence or application error leaves the record resident, marks the harness unavailable, and prevents further offers or drives. Recovery constructs a fresh harness rather than guessing whether the failed owner can continue safely.

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
8. proves fail-stop and close behavior;
9. runs 10,000 fixed-storage reuse cycles.

The existing memory-model and four-process lifecycle spikes continue to use the same compiled core and pass through the extracted contract verifier.

## Deliberate omissions

The deterministic transition adapter described by this spike has now been followed by the real journal/JSC integration in [`0005-owner-crash-recovery.md`](0005-owner-crash-recovery.md). Atomic checkpoint replacement and automatic recovery scanning beyond the offered operation remain absent.

Crash injection currently uses an explicit adapter failure, not process termination at every filesystem instruction. The test proves transition ordering and idempotent replay semantics, not parent-directory durability, power-loss behavior, or exactly-once external effects.

The ring protects concurrent producers with an atomic try-lock rather than a lock-free sequence-number queue. This is a deliberate small implementation: contention is visible and bounded. Replace it only after measurements show that `busy` materially harms completion delivery.

The next spike should connect `Harness.drive` to one real operation-journal and JavaScriptCore transition, then kill fresh processes at each record-write, sync, dispatch, checkpoint, and slot-release boundary.
