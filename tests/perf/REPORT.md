# Rui overnight performance report (WIP, partial)

Status: **partial**. All three headline results need Mac execution, and no Mac runner is connected. They are **UNAVAILABLE**, not zero. No production fix has been made. Baseline source: main/stable [`240aef2e`](https://github.com/DivyanshGolyan/rui/commit/240aef2e46d7240ce31a02ce4cefceb695551a56). Labels: **measured** or **estimated**, and **fixture** or **live**. A number without a label is an error in this report.

## Headline 1: Mac fixture footprint, Host and clients (N = 0/10/100)

| N streams | Host current phys_footprint | Host peak phys_footprint | Clients footprint | Source SHA |
| ---: | --- | --- | --- | --- |
| 0 | UNAVAILABLE | UNAVAILABLE | UNAVAILABLE | — |
| 10 | UNAVAILABLE | UNAVAILABLE | UNAVAILABLE | — |
| 100 | UNAVAILABLE | UNAVAILABLE | UNAVAILABLE | — |
| Intercept (base) / slope (per session) | UNAVAILABLE | UNAVAILABLE | UNAVAILABLE | — |

## Headline 2: HOLD100 waiting wakeups/s, before and after one deadline-wait fix

| Build | Host wakeups/s (Mac) | Host CPU while waiting (Mac) | Source SHA |
| --- | --- | --- | --- |
| Before (baseline) | UNAVAILABLE | UNAVAILABLE | `240aef2e` |
| After (deadline wait, capped at 1 s) | NOT BUILT: no measured Mac baseline | NOT BUILT | — |
| Pre-run napkin, **estimated** from source timeouts | ≈90/s at HOLD100 (intake `poll` 20 ms ≈50/s + execution `curl_multi_poll` 25 ms ≈40/s); ≈60/s at N0; ≈1–2/s after the fix | not estimated | `240aef2e` |

## Headline 3: one illustrative live Mac 100 × gpt-6-luna wave

| Quantity | Value |
| --- | --- |
| Total Host + Bash + clients footprint (current, peak) | UNAVAILABLE: not run |
| Total CPU | UNAVAILABLE: not run |
| 429 / retry / error counts | UNAVAILABLE: not run |
| Luna auth | Untested |

**Method.** Headlines 1 and 2 use the existing Go qualification harness and measurement samplers at P1's [`b13caa4b`](https://github.com/DivyanshGolyan/rui/commit/b13caa4b603e44de482694e241f18b4d752a5456): `tests/qualification/model-output --sessions 0|10|100 --expectation '<estimate>'` (fixed Host capacity 100), plus `--hold` with `--sessions 100` for Headline 2 (`main.go:2049–2051`). The plan is a ReleaseFast build, warmup, a 60 s steady state, at most three fresh-process repeats, and the commit SHA on every row. Headline 2 alternates A/B/A/B on the same Mac with the same build mode. Headline 3 is one live wave in a throwaway clone with a fresh Store and a 60-minute cap. Sol does all Mac execution. Before each run, a one-line estimate goes into that run's artifact; any gap is reported as a finding. The appendix below is a separate **measured Linux fixture** study and does not supply any headline.

**Limits.** No Mac runner has been connected tonight. The only approved route, the 1993-X2 runner, must be reconnected by the user. Until then, no Mac footprint, Mac wakeup, before/after or live result exists, and Linux numbers do not substitute for any of them. The single production fix (wait until the next deadline, capped at 1 s) is **found, not fixed**. It waits for a measured Mac baseline, the full suite and recovery/qualification passing, and one Sol correctness review. Linux context switches are not accepted as that baseline. P1 reports that transient client footprint is unavailable and that steady-state clients are reaped, so the clients column may stay empty even on a Mac. SQLite synchronous/journal settings are out of scope: they are measured and reported only, and any change is the user's decision.

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
