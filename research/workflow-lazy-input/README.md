# On-demand workflow results and admission service

Throwaway prototype, 7 September 2026, for OnePage #114. This extends the eager-input experiment at commit `bb7a6ea` without changing production code. The accepted direction is on-demand original-result decoding, fresh object values for separate invocations, independent keyed transactions and real Host service between them. The two-file layout tested here is a private implementation candidate, not a public protocol or newly required file-count policy.

## Run and source

`python3 research/workflow-lazy-input/run.py`

Requires macOS/Apple Silicon, Clang, Python with tarfile data-filter support, and the repository-pinned dependency archives already in `~/.cache/zig/p`. The runner extracts/caches compiled dependencies under the system temporary directory's `onepage-lazy-input-native-build`, recompiles the harness, and deletes every fixture database on exit. Delete that build directory for a clean rebuild. No provider, user workspace, credential or network access is used.

- Pinned QuickJS-ng `1ab8676f4b6d6d669baeb5f21790fb9734636a20`; pinned SQLite 3.53.4. Clang `-O2`; baseline feature macros, DELETE/EXTRA, mmap disabled, file-backed temp storage, 256 KiB suggested cache and immediate busy handling. This is a standalone C harness, not the production Zig build or complete production SQLite configuration.
- `common.h`: private native-endian entry layout and small I/O/SQLite helpers.
- `host.c`: membership capture, bounded body materialization, inherited descriptors, child pipe capture, fixture prevalidation, independent admissions and a small service driver.
- `child.c`: binary search over the disk directory, on-demand JSON conversion, allocator accounting, CPU checks and fixture bridge.
- `workflow.js`: full-text parallel/sequential/selective scanner-verifier consumers, identity and result-type cases, and deliberate deadline failures.
- `run.py`: reproducible measurements and assertions. `results.json` contains every observation and summary; binary hashes identify the exact measured executables.

## What changed

The Host captures exact key bytes, outcome tags and immutable result locators in a read transaction. The directory is a count, fixed-size entries and variable key bytes, ordered by SQLite BINARY comparison. Each entry has key range, body range, prototype row locator and tag. The directory itself stays on disk: there is no resident key Map. A count query plus an ordered enumeration establishes its layout; this is linear membership work, not a constant-time snapshot operation.

After ending that read transaction, the Host reads only the captured original results. Each 4 KiB body read opens/closes its SQLite blob access before writing scratch and returning to the service driver. Body materialization still copies **all captured bodies**, including ones the workflow never requests. The fixture keeps results immutable and has no deletion/GC path; production retention must be established through the existing Run/result owner.

Both files are unlinked immediately after the Host opens read-only handles. Writable handles close before spawn. The child inherits only explicitly selected stdin/stdout/stderr pipes and input descriptors 3/4, via close-on-exec-default spawn actions and an empty environment. It checks that both input handles are read-only. JavaScript receives no path, descriptor, SQLite or filesystem API. The eager comparison uses the same transport and materialization but predecodes every captured answer into the historical Map; it intentionally retains the old same-key aliasing as a baseline.

On a lazy lookup, native code compares exact UTF-8 key bytes in bounded windows, reads the selected body, parses it and hands its value to the Promise. It keeps no decoded value reference afterwards. Repeated calls repeat decoding; one Promise still returns the same value on repeated await. A missing key stays pending, a null value resolves null and a saved failure rejects with its decoded payload. Invalid ranges/short reads fail evaluation. The bridge does not delay answer delivery to shrink the graph.

Calls emit full finding text as their inputs, captured immediately. The Host captures the complete output before staging/validating it. It rejects known existing-key conflicts and inconsistent repeated keys before admitting new calls. Equal existing bindings are read-only comparisons. New bindings each use their own transaction with generation/cancellation/existence checks. Input copies and SQLite bindings/statements are released/reset before a service turn; no active cursor spans that turn. A final transaction replaces the complete pending set and publishes the outcome under the fence.

## Results

There are **69 driver invocations**, including terminal reopens and one intentional Host kill. Nine assertion groups passed. The controlled memory comparison comprises **48 invocations**: four shapes × three consumers × two input modes × two repetitions. Thirty-two published the expected pending set; sixteen failed evaluation without admitting requests. Fourteen of those failures reported out-of-memory; the two largest lazy parallel cases instead rejected with `null` near the limit. They remain classified as generic evaluation failures, not a proven specific resource cause.

Medians of two warm repetitions. “Engine backing” is peak actual allocator backing requested through QuickJS's malloc hooks, including arena backing/allocator rounding. It is not the engine's internal object-accounting counter used by JS_SetMemoryLimit, and not total child physical memory. The 16 MiB engine policy stayed unchanged. No pending-job scheduling or forced GC was added to obtain these results.

| Saved scanner input | Consumer | Eager | On demand | On-demand peak engine backing |
| --- | --- | --- | --- | ---: |
| 128 scanners, 8.00 MiB | parallel | fails | fails | 16.14 MiB |
| 128 scanners, 8.00 MiB | sequential | fails | passes | 0.50 MiB |
| 128 scanners, 8.00 MiB | selective | fails | passes | 0.45 MiB |
| 1024 scanners, 8.02 MiB | sequential | passes | passes | 2.39 MiB |
| 2048 scanners, 16.05 MiB | sequential | fails | passes | 4.56 MiB |
| 2048 scanners, 16.05 MiB | selective | fails | passes | 0.22 MiB |

The 128-scanner large-record sequential consumer submitted all 256 full-text verifier messages while using **0.50 MiB** peak engine backing. The matching eager run failed during preload. The parallel lazy run also failed, after emitting some descriptors; the Host admitted none because evaluation did not succeed. That is not a repaired parallel workflow or evidence that all its simultaneous values can fit.

With 2,048 scanner answers (~16 MiB), sequential lazy consumption decoded all 2,048 and submitted 4,096 verifiers, using **4.56 MiB** peak engine backing. The selective consumer decoded only two and used **0.22 MiB**, although preparation still copied the entire ~16 MiB. Sequential growth includes retained verifier Promises; on-demand input does not make arbitrary workflow memory constant.

There is an actual lookup cost. At 1,024 scanners × two 4 KiB findings, sequential engine backing fell from **11.94 to 2.39 MiB**, while child process CPU rose from **76.2 to 130.4 ms**. Binary search bounds directory probes, not total key-comparison or decoding work. Repeated lookups can decode more than the captured byte total. The selective case avoids most decoding, but does not avoid materialization.

For the 128-scanner large-record sequential case, membership capture took **1.93 ms** and materialization **29.69 ms**. Moving bodies outside the read transaction reduces that transaction's work; it does not remove the copy or make capture of arbitrary cardinality meet the control target. Materialization includes measurement/service checks. These results are not a controlled speed comparison against the earlier all-body capture prototype.

### Admission service

The same 512-scanner/1,024-new-verifier fixture compared service only after the loop with service after each admission. A control and an unrelated settlement become ready after four new commits. Both are real, separately committed fixture records processed by the driver, not a sleep or function named yield.

| Policy | Control acknowledgement | Settlement | New calls committed when control runs | Total admission phase |
| --- | ---: | ---: | ---: | ---: |
| Deferred | 360.767 ms | 361.117 ms | 1024 | 370.9 ms |
| Service between calls | 0.304 ms | 0.761 ms | 4 | 406.1 ms |

This is one observation per service variant, with synthetic readiness injection and tiny fixture commands. It demonstrates the service boundary and its consequence; it does not certify production p95 acknowledgement, sustained fairness or real effect cleanup. It does not start another workflow evaluation during the current lifecycle and does not select grouped commits.

### Correctness and failure checks

- Separate same-key calls produce fresh object values; mutation does not affect the second call. Reawaiting one Promise retains identity. The eager baseline reproduces the previous aliasing.
- Empty/prefix keys, distinct composed/decomposed Unicode, a non-Latin key and an 8 KiB key round-trip exactly. Null, a saved failure and absence are distinct.
- A alone starts verifiers. B finishes after membership capture but stays absent even during materialization; the next capture sees it. Final sums and terminal reopens are correct.
- An existing wrong verifier binding rejects the whole output before any new request admission. A truncated body fails rather than appearing missing.
- A JS CPU loop and native CPU loop stop under the one-second process CPU policy; a deliberately blocked native call is killed by the parent's five-second elapsed deadline. Native lookup/chunk reads/encoding have checks, QuickJS has an interrupt handler and the child has a coarse kernel CPU backstop. Long individual library calls can overshoot cooperative checkpoints.
- After four new admissions, the driver services a control and settlement, then kills the Host with SIGKILL before dependency publication. A fresh process reopens the database, replaces the generation, reuses all four calls and admits the remaining 28, then publishes all 32 pending verifier keys. This is process-kill evidence for the toy model, not power-loss or production Session recovery.
- Cancellation and generation replacement at the same prefix stop additional admissions and final publication. Cancellation stays fenced on reopen; a fresh generation can recover the replaced-generation prefix.
- Successful memory cases compare canonical verifier inputs with the complete generated text, not only its length, and check every expected pending key count. No failed evaluation admits output merely because some descriptor bytes were captured.

## Measurement meaning and remaining limits

QuickJS custom allocation hooks count live backing allocations and record their peak; all return to zero on normal teardown. QuickJS's internal arena accounting differs from backing allocation, so a backing peak slightly above 16 MiB is not itself proof that the configured engine-accounting ceiling was bypassed. Native body-buffer peak records requested allocation bytes separately (largest fixture body roughly 64 KiB), not allocator-rounded backing size. It is **not complete native allocation accounting**: source/stack, library internals, keys, parent record copies and SQLite remain outside that one buffer metric.

The Host samples parent and child macOS physical footprint in paired observations during child pipe capture and samples itself between materialization/validation/admission turns. `sampled_combined_peak` includes those observations across the lifecycle; it may miss short peaks, particularly during setup, a library call or process exit. It is not an enforced physical-memory ceiling or whole-OnePage qualification. Engine hooks and sampling add instrumentation overhead.

The child still materializes one complete encoded body for JS_ParseJSON; output Stringify/ToCString materialize one record, and parent validation holds one line. Source uses a small fixed fixture buffer. No arbitrary-large-record streaming conversion or complete native budget is implemented. The directory format is native-endian and fixture-private, with no canonical schema commitment or complete hostile-input validator.

Temporary input/output files are unlinked, writable input handles close before spawn, and normal lifecycle cleanup closes all handles. The tested Host kill happens **after the child exits**; abrupt parent death during evaluation, orphan descriptors, scratch exhaustion and I/O-fault cleanup remain unqualified. Aggregate scratch accounting is not implemented; directory/data/output byte metrics exclude SQLite temporary validation storage and journal overhead.

Result locators are immutable result columns on fixture call rows. The model does not implement actual Session creation/configuration, shared original-result ownership, retention/GC or cancellation propagation to effects. In particular, configuration replay and binding semantics for arbitrary strict-data descriptors require production evidence. Fixture validation does not establish prototype/accessor/cycle checks for arbitrary JS objects; inputs here are strings. Awaited versus unawaited call semantics remain unresolved; the fixture makes every encountered unresolved call pending.

Retain the selected direction: on-demand original-result decoding, no decoded-answer cache, independent atomic new-call admission with actual Host service, and one atomic complete publication. Keep disk layout and native large-value conversion as implementation work. Fair selection across waiting workflows and sustained control/settlement service still require their own evidence; #114 is not closed by this prototype.
