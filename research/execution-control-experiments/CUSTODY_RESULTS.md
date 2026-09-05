# Memory custody and SQLite admission probe

This is an executable, throwaway protocol fixture. It uses real SQLite transactions,
process exit and reopen, and controlled child-process pipes. It does not exercise
OnePage's production runtime or establish a complete recovery proof.

## Question and representation

Can durable Attempt admission and volatile physical execution ownership remain
separate without storing a second slot allocation table in SQLite?

The fixture has one in-memory slot containing occupancy, exact Attempt identity,
a reuse generation, one-shot dispatch permission, and live-resource status. A child
and its pipe descriptors stand in for local execution resources. Its only database
tables are minimal Attempt, Resolution, and Completion facts; these are fixture
tables, not a proposed production migration. Slot indices and generations are
volatile and never persisted.

The model follows the existing architecture's rules: reserve capacity before
admission; dispatch only after the invocation observes commit; do not reconstruct a
lost permit; retain local resource custody after a logical interruption; reject
late evidence for another Attempt; never automatically repeat uncertain Bash work.
The generation is an explicit fixture identity guard, not a recommendation to add
another durable identity or select a production representation.

## Executed cases

| Boundary | Mechanism and assertion | Deliberately broken control |
| --- | --- | --- |
| Rollback after slot reservation | Insert an Attempt inside a real transaction and roll it back. Close/reopen SQLite. No Attempt survives, no dispatch authority exists, and capacity can be reserved again. | None; rollback is a baseline. |
| Crash after commit, before launch | A separate owner process commits an Attempt and immediately calls `_exit` with its database connection open. The parent reopens the database. The Attempt survives; a pipe witness shows no external launch. Reconstructed memory has no permit. | Fabricate a permit from the unresolved row. |
| Uncertain external Attempt | The owner commits an Attempt, writes a launch witness through a pipe, and exits without Completion. Reopening preserves the unresolved Attempt; no replacement Attempt is admitted. | Blindly admit a second Bash Attempt. |
| Cancellation before local cleanup | A model-transport stand-in child emits a callback and waits at a cleanup gate. Commit an Interrupted Resolution, accept no Completion from late output, and attempt another reservation while its child/pipes remain live. Reservation must fail; it succeeds after cleanup. | Mark the slot free as soon as logical interruption is durable. |
| Delayed callback after reuse | Receive old callback bytes but defer handling them. Reap the old child, close its pipes, reuse the slot for another Attempt, then deliver the old event. No newer Completion may be written. A correct current event completes once; its duplicate adds no row. | Ignore exact Attempt identity/generation and settle whatever now occupies the slot. |

The stale-callback case intentionally represents a callback already queued before
cleanup but delivered afterward. It does not claim that an old process writes into
a newly reused operating-system file descriptor. The launch witness is a local
pipe byte, not a real provider request or filesystem mutation.

## Running and evidence

Run from any directory:

```sh
python3 /Users/divyanshgolyan/code/personal/onepage-execution-control-experiments/research/execution-control-experiments/run_custody.py
```

The runner builds with the repository's cached, pinned SQLite amalgamation and
compile flags via `build_native.py`. It repeats each safe scenario and applicable
negative control ten times, both normally and with AddressSanitizer and
UndefinedBehaviorSanitizer. Each scenario receives its own temporary database.
Every database open, including reopen after process exit, selects and reads back
`journal_mode=DELETE` and `synchronous=EXTRA` (numeric value 3), asserting both
observed values. Each invocation records the read-back configuration in its result.
Children are reaped and pipes closed before expected negative-control failures.
Temporary binaries, databases, and any rollback-journal files are removed by the
runner. Leak detection is disabled; ASan/UBSan exercise invalid memory access and
undefined behavior, not leak certification. No network or paid model calls occur.

See [machine-readable results](custody-results.json) for the exact environment,
SQLite package/flags, each exit status, and the assertion caught by each negative
control.

The completed run passed all 180 invocations: 100 safe-case passes and 80 expected
negative-control failures. Half ran under ASan+UBSan; no sanitizer diagnostics were
reported. Every negative control failed at its intended assertion, rather than
being counted as detected because of an unrelated process or sanitizer error.

## What this can decide

These cases support keeping physical custody in memory while SQLite owns durable
semantic facts. Durable interruption and local resource release can occur at
different times; therefore a count of unresolved database records is insufficient
to decide whether a live execution slot is reusable. A durable slot table is not
needed for any handoff tested here. It also would not replace the in-memory handles
and callback-identity checks exercised by the fixture.

The fixture retains a minimal implementation distinction: a database transaction
governs durable admission, and the caller that observes that commit holds the only
volatile launch permission. Recovery classifies unresolved durable work rather than
trying to resurrect a process's physical slot.

Keep these handoff scenarios as requirements for the eventual integrated Host
implementation. Do not promote this fixture's data layout into another runtime
abstraction.

## Limits

The recovery choices are implemented fixture policies, checked against assertions;
the experiment establishes that the stated finite traces can be implemented and
that the negative controls are detected. It does not discover or prove the recovery
policy from SQLite behavior alone. Ten repetitions of deterministic handshakes do
not explore arbitrary schedules.

No production classifier, real reactor, Session occupancy, Workflow cancellation
traversal, Patch reconciliation, provider billing, power-loss simulation, process
group cleanup, full asynchronous launch/interruption race, or adversarial event
ordering is covered. The abrupt process exits verify SQLite reopen after an owner
dies, not machine power loss. No memory/latency result is claimed by this probe.
