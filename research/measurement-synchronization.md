# Measurement synchronization at wall-time and Store boundaries

Research date: 2026-09-22. This note answers two measurement defects encountered in readiness work for [issue #168](https://github.com/DivyanshGolyan/rui/issues/168). It recommends test design; it does not change Rui's runtime, qualification contract or evidence status. The reported approximately 9 ms settlement duration was not independently measured here.

## Conclusions

1. **Recheck the serialized wall-time postcondition after every wait.** A Unix timestamp reconstructed with `time.Unix` has no Go monotonic reading. `time.Until(target)` therefore computes a wall-clock duration, while `time.Sleep` only promises to wait at least that duration. A backward wall adjustment during the sleep can leave `time.Now().Before(target)` true. Keep the existing cross-process wall boundary, but loop until the wall predicate is satisfied or the independent monotonic run deadline expires. Unit-test the loop through injected `now`, `sleep` and remaining-budget functions that script the wall clock moving backward after the first sleep.
2. **Split transaction exclusion from representative latency.** Add a test-only gate at the Store owner boundary immediately after `BEGIN IMMEDIATE` has established a real SQLite write transaction. Direct synchronization should hold that transaction, place real control calls at the Store mutex, then release it and verify commit-before-control-acquisition plus canonical outcomes. That proves mutual exclusion and queue ordering. Because the gate artificially extends the mutex, transaction and resource lifetimes, exclude that run from latency and representative-resource claims. Keep a separate ungated assembled workload for control latency and natural transaction duration; natural overlap may be reported when observed but must not be a pass condition.

## 1. Waiting for a timestamp from another process

### Current ownership path

The provider records `startAt = time.Now().Add(500 * time.Millisecond)` and returns `StartUnixNS = startAt.UnixNano()` from `StartOffer` ([provider/main.go](../tests/qualification/model-output/provider/main.go)). The runner reconstructs it with `time.Unix(0, started.StartUnixNS)`, then `Deadline.SleepUntil` performs one `time.Until`/`time.Sleep` before the 10-second and 50-second CPU observations ([model-output/main.go](../tests/qualification/model-output/main.go), [measurement.go](../tests/qualification/measurement/measurement.go)). Serialization is necessary because provider and runner are separate processes, but it changes the clock semantics.

### Source-backed findings

- Go's [`time` package monotonic-clock contract](https://pkg.go.dev/time#hdr-Monotonic_Clocks) says `time.Now` contains wall and monotonic readings; comparisons and subtraction use monotonic time only when **both** operands have it. If either lacks it, they use wall time. It also says monotonic readings have no meaning outside the current process, are omitted by serialization and Unix values, and `time.Unix` constructs a value without one. The [`Time.Sub` source](https://cs.opensource.google/go/go/+/go1.27.1:src/time/time.go;l=1194-1203) implements that exact fallback. Therefore `time.Until(time.Unix(...))`, shorthand for `target.Sub(time.Now())`, is a wall-clock calculation despite `time.Now()` carrying a monotonic component.
- [`time.Sleep`](https://pkg.go.dev/time#Sleep) promises only that the goroutine pauses for at least duration `d`; it does not promise that a separately computed wall timestamp has been reached when it returns. The [`sleep.go` declaration](https://cs.opensource.google/go/go/+/go1.27.1:src/time/sleep.go;l=12-14) states the same guarantee.
- POSIX makes the distinction explicit. [`clock_gettime`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/clock_gettime.html) says a changed `CLOCK_REALTIME` value governs realtime absolute timers while a relative interval elapses independently of the old or new realtime value; it also describes a monotonic clock's absolute origin as arbitrary. [`clock_nanosleep`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/clock_nanosleep.html) guarantees a relative sleep is not shorter than its interval as measured by the selected clock, whereas an absolute sleep remains blocked until that clock reaches its target. Go's one-shot wall subtraction followed by a relative sleep does not acquire the latter postcondition.
- Go's first-party [Testing Time](https://go.dev/blog/testing-time) guidance says real-time tests are slow or flaky and identifies fake time plus explicit synchronization/quiescence as the two foundations of reliable asynchronous tests. `testing/synctest` advances one fake clock monotonically; it does not by itself create the discontinuous wall/monotonic pair this regression needs.

### Recommended correction and regression seam

`Deadline.SleepUntil` should treat the target as a wall predicate and the run deadline as a separate elapsed-time bound:

```text
repeat:
    now = wallNow()
    if now >= target: return success
    delay = target - now
    remaining = runDeadline.remaining()  // monotonic in this process
    if delay > remaining: return scheduled-observation-exceeds-deadline
    sleep(delay)
```

Recomputing after every wake handles backward wall changes; a forward jump makes the next check finish immediately. The existing `Deadline` originates at `time.Now().Add(duration)` in the runner process, so its `Remaining` calculation retains monotonic semantics and bounds repeated backward adjustments. Preserve the current error distinction between an expired run and a target beyond the remaining budget.

Use a narrow unexported seam around this loop: production supplies `time.Now`, `time.Sleep` and `Deadline.Remaining`; a unit test supplies scripted functions. The decisive regression script is asymmetric:

1. wall `now` is 90 and target is 100, so the first requested sleep is 10;
2. after that sleep, wall `now` is 85, modeling a backward adjustment;
3. the function must request another 15 rather than return;
4. wall `now` reaches 100 and the function returns, with enough scripted monotonic budget throughout.

Also cover a forward jump past 100, target already reached, and repeated backward movement exhausting the run deadline. Assert requested durations and the final wall predicate, not real elapsed time. `testing/synctest` can test ordinary timer behavior, but injected readings are the smaller seam that can express this specific clock discontinuity.

### Rejected alternatives and claim boundary

- **One monotonic duration sent by the provider:** reject. Go states that its monotonic reading is process-local and not serializable. A serialized `Duration` has no origin; starting “10 seconds” when the runner receives it shifts the provider boundary by transport and handler delay.
- **A protocol-relative start timestamp:** reject unless the protocol also adds an explicit synchronization handshake or boundary notification. An offset from provider start still cannot reconstruct that start on the runner's monotonic clock. Provider-emitted boundary events could avoid wall correlation, but they add protocol machinery and delivery-delay semantics without being needed for the current 10-second/50-second wall observations.
- **An OS monotonic timestamp:** not a portable Go contract. POSIX allows system-wide clocks but calls the monotonic origin arbitrary; Go deliberately says its embedded monotonic reading is meaningless outside the process. Rui targets both Linux and macOS, so an undocumented shared epoch would weaken the evidence.
- **Adding a fixed sleep margin:** reject. No finite margin establishes the wall postcondition after an arbitrary permitted adjustment; it only makes the test slower.

The loop establishes the serialized provider wall boundary at the check immediately preceding each CPU query, subject to the run deadline. No user-space check can prevent another wall adjustment between that check and the query. The design does not prove clock synchronization accuracy, prevent forward jumps from shortening provider-relative elapsed time, or turn Unix timestamps into a monotonic cross-process interval. If qualification eventually needs adjustment-proof elapsed intervals rather than wall-boundary observations, it needs a synchronized protocol event or measurement owner, not a richer timestamp encoding.

## 2. Proving controls wait behind settlement

### Current ownership path

`Store.settleModelSuccess` acquires the single Store mutex, emits `settlement_lock_acquired`, and then `settleModelSuccessLocked` starts `BEGIN IMMEDIATE`, imports the provider output and commits ([store.zig](../src/store.zig)). The model-control runner discovers the trace by rereading stderr every 25 ms, then launches two controls and later requires `storeQueued < settlementComplete < lockAcquired` ([model-control/main.go](../tests/qualification/model-control/main.go)). A transaction shorter than one polling interval can commit before the runner sees the acquisition record, so failure to overlap says nothing about Store exclusion.

The present trace also marks mutex acquisition **before** `BEGIN IMMEDIATE`; that milestone alone proves neither an active SQLite transaction nor imported work.

### Source-backed findings

- SQLite's [transaction documentation](https://www.sqlite.org/lang_transaction.html) says all database access occurs in transactions, `BEGIN IMMEDIATE` starts a write transaction immediately, and only one write transaction may exist at a time. Rui additionally serializes its one connection through the Store mutex.
- [`sqlite3_txn_state`](https://sqlite.org/c3ref/txn_state.html) reports `SQLITE_TXN_WRITE` for a connection in a write transaction. [`sqlite3_get_autocommit`](https://sqlite.org/c3ref/get_autocommit.html) reports that autocommit is disabled by `BEGIN` and re-enabled by `COMMIT` or `ROLLBACK`. Either can validate gate placement; `sqlite3_txn_state(database, "main") == SQLITE_TXN_WRITE` is the more specific assertion.
- SQLite's own [testing strategy](https://www.sqlite.org/testing.html) separates `speedtest1` performance work from `mptester`/`threadtest3` concurrency stress and uses test harness instrumentation for OOM, I/O, crash and mutex assertions. It reruns delivery builds separately from instrumented coverage builds. The relevant principle is to instrument the ownership boundary for a correctness proof without treating the instrumented run as delivered performance.
- Go's [`testing` benchmark contract](https://pkg.go.dev/testing#hdr-Benchmarks) similarly excludes setup and cleanup from measured work. This does not prescribe Rui's runner, but supports separating synchronization setup from the latency interval whose product meaning is being claimed.
- Go's [Testing Time](https://go.dev/blog/testing-time) also states that passage of time is not synchronization. A trace file becoming visible on a polling schedule is therefore the wrong authority for entering a short critical interval; an explicit event/barrier is the appropriate seam.

### Recommended deterministic exclusion test

Put a test-only callback/barrier in the Store settlement owner immediately after successful `BEGIN IMMEDIATE`, before output import. At that point, assert `sqlite3_txn_state(database, "main") == SQLITE_TXN_WRITE`, signal `settlement_transaction_active`, and wait for release while retaining the production Store mutex and SQLite transaction.

Prefer a direct Store integration test in one process:

1. Build valid model output through the real preparation/validation fixture and call production `settleModelSuccess` asynchronously.
2. Wait on the direct `settlement_transaction_active` event, not stderr polling.
3. Start real `interruptModel` and `stopSession` calls against the same `Store`. Their existing `ControlTrace.lock_requested` callbacks signal direct events immediately before the production mutex acquisition. Wait until both requests have entered that owner path and assert neither call has completed.
4. Release the settlement gate. Assert the settlement commits and returns before either control emits `lock_acquired`; then let the controls run through real SQLite transactions.
5. Verify canonical output bytes/digest and the controls' resolved/current-work answers through Store interfaces. Verify the connection returns to `SQLITE_TXN_NONE`/autocommit and no transaction or mutex remains held after every success/failure cleanup path.

The order among the two waiting controls is unspecified and should not be asserted. If Host/socket wiring itself needs a witness, expose the same entered/release handshake through two one-shot pipes or FIFOs; do not rediscover entry by polling a trace file. The direct Store test is the primary proof because Store owns the mutex, transaction and state transition.

This gate is narrowly justified at the owner boundary. A delay before mutex acquisition only prepositions a race and cannot prove an active transaction. A delay after mutex acquisition but before `BEGIN` proves only mutex exclusion. A second SQLite connection or synthetic lock would test a topology Rui does not use. A generic scheduler hook would duplicate Store authority.

### Separate representative measurement

Keep the assembled model-control qualification ungated. Under the production 100,000-byte result import, captured-report population and protected control places, record:

- natural settlement mutex wait, real transaction/service duration and commit outcome;
- control queue, Store-lock, Store-service, reply and total durable-acknowledgment intervals;
- canonical answer integrity, control semantics, cleanup and resource high-water.

Apply the existing latency limit only to this ungated run. Submit controls promptly, but do not require the approximately 9 ms transaction to overlap a separately scheduled process by chance. If the timestamps happen to show natural overlap, retain it as diagnostic evidence with its observed frequency; absence is not incomplete qualification once the deterministic owner test proves exclusion.

### Rejected alternatives and claim boundary

- **Poll faster or retry until overlap:** reject. This changes probability, not authority, and selective reruns bias the evidence.
- **Relax the latency limit or enlarge production work:** reject. Neither fixes synchronization, and both change the product question to make a fixture pass.
- **Hold the Store mutex/transaction and include that wait in latency:** reject. The barrier deliberately creates queue time and extends SQLite, scratch and custody lifetimes. It can prove exclusion and bounded cleanup under the artificial state, but cannot establish representative acknowledgment latency, natural transaction duration, throughput or ordinary resource occupancy.
- **Pre-position controls before settlement without an active-transaction gate:** insufficient for the requested direction. It deterministically proves the control-first race, not that controls wait behind settlement. Pre-position controls only after the transaction-active signal and before releasing the gate.
- **Infer transaction overlap from `settlement_lock_acquired`:** reject. In current code that event precedes `BEGIN IMMEDIATE`.

The gated test can claim that production Store calls cannot acquire the Store mutex or begin their SQLite work until a real settlement write transaction commits/releases, and that the resulting canonical outcomes are correct. It cannot claim the ungated transaction naturally lasts long enough for another process to observe, or that latency/resource targets pass while the barrier is held. The ungated qualification can claim representative latency and resources for its stated workload; without the gate, it cannot guarantee a particular short-lived interleaving. Together the tests answer both questions without conflating them.

## Sources

- Go `time`: [monotonic clocks](https://pkg.go.dev/time#hdr-Monotonic_Clocks), [`Sleep`](https://pkg.go.dev/time#Sleep), [`Time.Sub` source](https://cs.opensource.google/go/go/+/go1.27.1:src/time/time.go;l=1194-1203), [`Until` source](https://cs.opensource.google/go/go/+/go1.27.1:src/time/time.go;l=1235-1242), [`Sleep` source](https://cs.opensource.google/go/go/+/go1.27.1:src/time/sleep.go;l=12-14).
- Go testing: [Testing Time (and other asynchronicities)](https://go.dev/blog/testing-time), [`testing` benchmarks](https://pkg.go.dev/testing#hdr-Benchmarks).
- POSIX.1-2024: [`clock_gettime`/`clock_settime`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/clock_gettime.html), [`clock_nanosleep`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/clock_nanosleep.html).
- SQLite: [transactions](https://www.sqlite.org/lang_transaction.html), [`sqlite3_txn_state`](https://sqlite.org/c3ref/txn_state.html), [`sqlite3_get_autocommit`](https://sqlite.org/c3ref/get_autocommit.html), [How SQLite Is Tested](https://www.sqlite.org/testing.html).
