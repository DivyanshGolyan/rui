# Rui overnight performance report (WIP, partial)

Status: **partial**. No Mac runner is connected, so the coordinator moved tonight's headlines to Linux. Headlines 1 and 2 are Linux fixture runs by P1; their rows are **pending** until P1 publishes them. macOS footprint remains pending and is not substituted. Headline 3 (live) is **skipped** tonight. Baseline source: main/stable [`240aef2e`](https://github.com/DivyanshGolyan/rui/commit/240aef2e46d7240ce31a02ce4cefceb695551a56). Labels: **measured** or **estimated**, and **fixture** or **live**. A number without a label is an error in this report.

## Headline 1: Linux PSS (macOS footprint pending), Host and clients, N = 0/10/100

| N sessions | Host PSS (`smaps_rollup`) | Clients PSS | Source SHA |
| ---: | --- | --- | --- |
| 0 | **measured** median 7,362,560 B (IQR 5,120 B) | 0 B steady state (clients reaped); transient peaks unavailable | `240aef2e` |
| 10 | **measured** median 11,345,920 B (IQR 13,312 B) | 0 B steady state; transient peaks unavailable | `240aef2e` |
| 100 | **measured** median 13,596,672 B (IQR 8,704 B) | 0 B steady state; transient peaks unavailable | `240aef2e` |
| Intercept (base) / slope (per session), linear fit | 9,024,073 B / 47,572 B per session. Residuals reach 1.85 MB, so this is **not** a constant per-session cost: the step from 0 to 10 sessions (≈398 KB/session) is far steeper than from 10 to 100 (≈25 KB/session) | — | — |

Each N has 3 fresh Hosts; the IQR is (max − min)/2 over those three. Headline 1 data, measured Linux fixture: P1 raw evidence at `perf/linux-pss-20261021` [`ab9f3e41`](https://github.com/DivyanshGolyan/rui/commit/ab9f3e410e4d06ad77c8a2fea6b8db6ccd5513e0) (`.amp/p1/summary.json` and `.amp/p1/raw/`). All nine runs and HOLD A1 passed, and all ten Host/provider pairs were reaped. The final baseline audit by the same Sol reviewer is pending. The harness source is [`a204296c`](https://github.com/DivyanshGolyan/rui/commit/a204296c7289cf0a90f95df155c4f27832c924fe), and the baseline ReleaseFast binary SHA-256 is `e2835cb2…3a50`. The queue verified 102/102 hashes and all ten row identities and statuses at `ab9f3e41`; that is a hash and identity check, not a qualification verdict. STREAM in-window event rates and CPU/event are unavailable: provider totals publish only after the 120 s offer. They are null, not zero.

## Headline 2: HOLD100 waiting cost, before and after one deadline-wait fix (Linux fixture)

| Build | Host voluntary switches/s (Linux, not distinct wakeups) | Host CPU while waiting | Source SHA |
| --- | --- | --- | --- |
| Before, earlier P2 single run (**measured**) | ≈88/s (5,300 in 60 s; two threads at ≈49.7/s and ≈38.7/s) | 3.07% of one core (1.84 CPU-s / 60.01 s) | `240aef2e` |
| Before, P1 A1 (**measured**) | 87.88/s proxy (5,278 voluntary in 60.059 s: two threads at 2,955 and 2,323; 91 nonvoluntary) | 1.70 CPU-s / 60.059 s ≈ 2.83% of one core | `240aef2e` (binary `e2835cb2…3a50`) |
| Before, P1 A2–A3 | pending (alternating with B) | pending | `240aef2e` |
| After, P1 B1–B3 (intake deadline wait) | pending (B ReleaseFast build from `4950c22e`, same options and caches as A, 42/42 steps, SHA-256 `ec840083…b439`; B1 started 19:57:22 UTC, then A2/B2/A3/B3 serially, no compiles or tests during windows) | pending | [`4950c22e`](https://github.com/DivyanshGolyan/rui/commit/4950c22effd8120a4b8f689c81c652ef13e50d8b) (Sol review: no findings; selected suite pending; **not** a fixed claim) |
| Failed candidate, not measured | — | — | [`f6a2df85`](https://github.com/DivyanshGolyan/rui/commit/f6a2df856fba8a68cb875f8b7432702910c734de): failed `admission-debug-integration`; review found the same defect (closed exchanges waited up to 1 s for removal) |
| Pre-run napkin (**estimated**) | ≈90/s before; ≈40/s after (only the intake 20 ms timer is removed) | not estimated | — |

## Headline 3: one illustrative live Mac 100 × gpt-6-luna wave

| Quantity | Value |
| --- | --- |
| All quantities | **SKIPPED tonight**: the credentials exist only on the offline 1993-X2 Mac runner. No credential probe was made. |

**Method.** Headlines 1 and 2 use the existing Go qualification harness and measurement samplers at P1's [`b13caa4b`](https://github.com/DivyanshGolyan/rui/commit/b13caa4b603e44de482694e241f18b4d752a5456): `tests/qualification/model-output --sessions 0|10|100 --expectation '<estimate>'` (fixed Host capacity 100), plus `--hold` with `--sessions 100` for Headline 2 (`main.go:2049–2051`). P1 runs on Linux in its own 2-vCPU orb, with Host and client PSS from the existing `smaps_rollup` sampler. Each run is a ReleaseFast build from `240aef2e` sources: capacity 100, TLS, 30 events/s/stream, a 10 s warmup and a 60 s window, 3 fresh Hosts per N, with the commit SHA on every row. Headline 2 alternates A1/B1/A2/B2/A3/B3 in the same orb with the same harness and observer, both binaries built identically, and no builds during measured windows. Before each run, a one-line estimate goes into that run's artifact; any gap is reported as a finding. The appendix below is a separate **measured Linux fixture** attribution study.

**Fix (candidate, not yet validated).** The intake loop's fixed 20 ms `poll` becomes a wait until its earliest owned deadline, capped at 1 s. Those deadlines are header/body inactivity, reply deadline, delivery `not_before`, `accept_retry_at` and `cleanup_retry_at`. Worker completion, `fenceDispatch` and `host_stop` already write the intake wake pipe. A test FIFO delivery gate keeps the 20 ms check. The execution loop's 25 ms (curl/Bash) and 100 ms (idle) waits are **found, not fixed**: newly admitted Messages are discovered only by polling. A 1 s cap would add up to 1 s of admission latency unless a Store-commit wake were added, and that is out of scope tonight.

**Limits.** No Mac runner is connected; the only approved route, 1993-X2, needs the user to reconnect it. So there is no macOS footprint or Mac wakeup result, and Linux PSS and switch counts are labelled as Linux, not as Mac results. Linux voluntary context switches are not distinct timer wakeups, and scheduler wakeup tracepoints appear unavailable. P1 reports that transient client footprint is unavailable and that steady-state clients are reaped. The fix counts as fixed only if the full suite, recovery/qualification and one Sol review all pass; otherwise it is reported as found, not fixed. SQLite synchronous/journal settings are measured and reported only; any change is the user's decision.

---

## Appendix: Linux fixture attribution (measured, fixture, not Mac, not live)

Source of every count number here (syscalls, fsync, SQL, allocations, profile, context switches): P2 evidence at `perf/linux-attribution` [`48c0db21`](https://github.com/DivyanshGolyan/rui/commit/48c0db21f4ceff701bd7ed426d53156a9a868e8d). One Sol review produced a no-findings count/reduction verdict on [`e8a8cc9f`](https://github.com/DivyanshGolyan/rui/commit/e8a8cc9f0516da8371cc55f11b1a3542521fbc2a). Between that commit and `48c0db21`, only `NOTES.md` and its manifest digest changed. Full write-up: [ATTRIBUTION.md](../../.amp/p2/ATTRIBUTION.md). Commands: [COMMANDS.md](../../.amp/p2/COMMANDS.md). Notes, with the pre-run estimates: [NOTES.md](../../.amp/p2/NOTES.md). Raw data: [raw/](../../.amp/p2/raw/), manifest [evidence.sha256](../../.amp/p2/raw/evidence.sha256), reducer [analyze.py](../../.amp/p2/analyze.py). The uninstrumented CPU subsection below comes from later P2 commits `3c522068` and `19fedb86` and has its own separate review verdict, described there.

Environment (measured): KVM VM, 2 logical Intel Xeon @ 2.60 GHz CPUs, Linux 6.1.158+, Zig 0.17.0, Go 1.27.1, fd soft limit 1,024. The binary is an explicit ReleaseFast build of `240aef2e`, SHA-256 `b843b47a…cdbb2` ([identity](../../.amp/p2/raw/identity.txt)). All counts are Host-only. They come from instrumented runs, so they are counts only, never times. Per-Message values are whole-run amortized: they include startup, configuration, two rounds and teardown. N1 used H1 at 30 events/s/stream and N100 used TLS/H2 at 100 events/s/stream, so N1 and N100 are not a controlled scaling curve.

### Work per event and per Message (measured, Linux fixture)

| Count | STREAM N=1 (quiet) | STREAM N=100 (quiet) | HOLD N=100 (traced) |
| --- | ---: | ---: | ---: |
| Messages / events | 2 / 3,600 | 200 / 1,200,000 | 100 / 0 |
| All syscalls | 170,960 | 12,625,760 | 792,106 |
| Syscalls/event | 47.48889 | 10.52147 | undefined (0 events) |
| `fsync`/Message | 29.5 | 24.06 | 17.05 (admission and hold only) |
| `fdatasync` | 0 | 0 | 0 |
| SQLite statement first-executions/Message | 4,454.5 | 2,167.93 | not measured |
| Explicit `COMMIT` executions/Message (starts, not confirmed completions) | 4.5 | 4.005 | not measured |
| libc allocation calls (heaptrack, N1 only) | 21,021 (10,510.5/Message) | not measured | not measured |

Notable measured findings, not acted on:

- At N100, `preadv` makes 8,491,607 calls: 7.076 per event and 67.3% of all syscalls. Source attribution points to `src/provider_output.zig:1650–1745`, which rereads SSE ranges. That source link is inferred; the exclusive CPU cost of these calls is not measured.
- SELECT makes up 8,773 of 8,909 statements at N1 and 425,912 of 433,586 at N100.
- At N1 heaptrack, SQLite malloc and realloc account for 83.43% of allocation calls and OpenSSL `CRYPTO_malloc` for 14.59%. This is allocation traffic, not retained bytes.
- With phase-trace diagnostics on, N1 makes 284,834 syscalls versus 170,960 quiet. That difference of 113,874 is within 276 of the estimated 114,150, which supports diagnostic amplification as the cause.

### Uninstrumented Host CPU (measured, Linux fixture)

Source: P2 [`3c522068`](https://github.com/DivyanshGolyan/rui/commit/3c522068a2b7c11922c0925c3fe4256501341d77) and [`19fedb86`](https://github.com/DivyanshGolyan/rui/commit/19fedb861b2ba6b44292ca34edb4586ad85f83e8), merged into this branch. These runs use the same frozen ReleaseFast binary (`b843b47a…`) and the existing Go capacity runner. No strace, perf, heaptrack, SQL callback or phase diagnostics ran. Review: the same Sol reviewer gave a separate, bounded no-findings verdict on the CPU delta `48c0db21` → `19fedb86`. That verdict is distinct from the `e8a8cc9f` count verdict. It verified 102 manifest hashes, both jq reductions, and the reported CPU sums, denominators and HOLD subtraction. Review limits:
- The STREAM complete-work start and end readings were not saved separately. Only the boundary placement (from source) and the sums were verified.
- The interior-window and HOLD endpoints are saved and can be replayed.
- The pre-run estimates were written in the working tree before each run, not published beforehand as immutable snapshots.
- jq rounds epoch timestamps by up to 196 ns in the summaries; the raw files keep exact values. This does not affect these coarse CPU values.
- Only the STREAM1 run explicitly records that `LD_PRELOAD` was unset. The later runs invoke the baseline binary directly.

The CPU figure is Host user+system time over the complete work: Message admission, paced offer, result delivery and drain. It excludes Configure, Host startup, and the provider, controller and CLI processes. Linux `CLK_TCK` is 100, so values are coarse at 10 ms and the per-event ratios are amortized, not microsecond timings. N=1 and N=100 are not a controlled scaling curve. Each case has one fresh Host (two rounds for streaming, one HOLD window), which gives no repeat statistics. Raw files: [stream1-uninstrumented.json](../../.amp/p2/raw/stream1-uninstrumented.json) and [cpu-stream1-summary.json](../../.amp/p2/raw/cpu-stream1-summary.json).

| Fixture | Pre-run estimate (**estimated**) | Host CPU (**measured**) | Events | CPU/event |
| --- | ---: | ---: | ---: | ---: |
| STREAM N=1 | ≈0.158 CPU-s (≈44 µs/event) | 1.53 CPU-s (0.77 + 0.76) | 3,600 | 425 µs (≈9.7× the estimate) |
| STREAM N=100 | ≈14.12 CPU-s (≈11.77 µs/event) | 42.40 CPU-s (20.62 + 21.78) | 1,200,000 | 35.3 µs (≈3.0× the estimate) |
| HOLD N=100, 60.01 s interior window | ≈0.054 CPU-s | 1.84 CPU-s (0.90 → 2.74), ≈0.0307 cores = 3.07% of one core (≈34× the estimate) | 0 | undefined |

In the 40 s interior windows, the Host used about 0.0127 and 0.0120 average cores at N=1, and about 0.310 and 0.300 at N=100. All four streaming rounds pass capture, request integrity, result delivery, cleanup and post-reap durable audits. Both streaming verdicts are `incomplete` only because Mac footprint is unavailable. HOLD passes (exit 0) with 100 held streams on one H2 connection, 0 events and 0 offer bytes. Its figure is waiting CPU only: not admission or settlement CPU, and not a count of distinct wakeups or Mac `IDLEW`. Runs were serial and compiles happened between measured intervals, not during them. Run times (UTC): N=1 18:58:49–19:00:51, N=100 19:01:24–19:03:42, HOLD 19:04:20–19:05:33.

Finding (measured, Linux fixture): with nothing to do, 100 held streams cost the Host about 3% of one core, roughly 34× the estimate built from the 20 ms and 25 ms timers. This is relevant waiting-cost evidence for the deadline-wait fix, but it is Linux, a single run, and has no before/after. The fix stays **found, not fixed** unless the coordinator accepts this as the baseline.

Additional raw files from P2 [`19fedb86`](https://github.com/DivyanshGolyan/rui/commit/19fedb861b2ba6b44292ca34edb4586ad85f83e8): [stream100-uninstrumented.json](../../.amp/p2/raw/stream100-uninstrumented.json), [cpu-stream100-summary.json](../../.amp/p2/raw/cpu-stream100-summary.json), [hold100-cpu/evidence.json](../../.amp/p2/raw/hold100-cpu/evidence.json), [cpu-binary-source-identity.sha256](../../.amp/p2/raw/cpu-binary-source-identity.sha256).

### N100 on-CPU sampled user stacks (measured, Linux fixture, one profile)

The profile has 4,466 `cpu-clock:u` samples. The families below overlap, so they are not exclusive CPU shares. In 567 samples the leaf symbol is unresolved (540 in the vDSO), 4,294 samples contain an unknown frame, and kernel stacks are unavailable. Flamegraph: [stream100-flamegraph.svg](../../.amp/p2/raw/stream100-flamegraph.svg).

| Stack family | Samples | Share of user samples |
| --- | ---: | ---: |
| curl/OpenSSL prefixes | 3,481 | 77.9445% |
| SQLite | 613 | 13.7259% |
| `provider_output` | 222 | 4.9709% |
| Positional I/O | 52 | 1.1644% |

### HOLD100 natural context switches (measured, Linux fixture, not Mac wakeups)

In the untraced HOLD100 run, Host threads made 5,300 voluntary context switches in a 60 s interior window, about 88/s. All of them come from two threads: 2,980 (≈49.7/s) and 2,320 (≈38.7/s). The other three threads made 0 ([thread-deltas.json](../../.amp/p2/raw/hold100-untraced/thread-deltas.json)). The pre-run estimate was 6,200. These per-thread rates are close to the estimated intake 20 ms `poll` (50/s) and execution `curl_multi_poll` 25 ms (40/s) timers. This match is a **hypothesis**: the raw file retains all five TIDs and their switch deltas, but which TID is the intake loop and which is the execution loop is unverified, and a Linux switch count is not Mac `IDLEW` or a count of distinct timer wakeups. The traced HOLD run made 7,200 `poll` calls and 1,212,768 voluntary switches. Those switches are ptrace distortion and are not reported as natural.

### Appendix limits and retained failures

- **Incomplete reports:** all seven canonical streaming, SQL, heap and perf reports remain `incomplete` with exit 1, because Mac physical footprint is unavailable. Their functional and post-reap audit dimensions pass.
- **Heap run Host exit:** the heap run's graceful Host stop logs `EffectAwareShutdown` and exits 1 ([log](../../.amp/p2/raw/heap1-host.log.gz)). This is retained and not fixed.
- **Hardware and perf counters:** hardware counters are unsupported. The perf context-switch and migration counters read 0 even though task switches demonstrably occurred, so they are treated as unavailable, not zero.
- **Retained failures:**
  - the first SQL research build failed (dependency symlink);
  - the first perf post-processing attempt failed;
  - a preliminary profile summary was wrong (3,479 samples and 0 unresolved leaves).

  All three are kept. None of them led to a workload rerun.
- **Whitespace check:** `git diff --check` from the baseline to this evidence exits 2. The cause is blank EOF lines in three raw build logs (`build-releasefast.log:81`, `build-sql-research-attempt1.log:98`, `build-sql-research-attempt2.log:72`). The raw evidence was not normalized, so this check is **not green**.
- **Landing preflight metadata:** P2's landing preflight first failed because P2's checkout had shallow history. After unshallowing, the existing preflight exits 0 with all identities unchanged. The original failure is preserved only in the transcript and NOTES; [preflight-history-diagnosis.txt](../../.amp/p2/raw/preflight-history-diagnosis.txt) holds the before/after diagnosis. This correction is P2 [`4fbd77d6`](https://github.com/DivyanshGolyan/rui/commit/4fbd77d688671d57b6902c1bc9d6cabacf53b631), merged here. It changes only `NOTES.md`, the manifest and that new file, with no measurement changes. It was not reviewed; the CPU verdict stays attributed to `19fedb86`.
- **Not independently verified:** the review reproduced 93/93 manifest hashes and all nine reductions. It did not rebuild the unpublished measurement binaries.
