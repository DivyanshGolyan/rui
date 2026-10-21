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

**Method.** Headlines 1 and 2 use the existing Go qualification harness (`tests/qualification/model-output --capacity N` and the measurement samplers), with P1's HOLD provider at [`b13caa4b`](https://github.com/DivyanshGolyan/rui/commit/b13caa4b603e44de482694e241f18b4d752a5456). The plan is a ReleaseFast build, warmup, a 60 s steady state, at most three fresh-process repeats, and the commit SHA on every row. Headline 2 alternates A/B/A/B on the same Mac with the same build mode. Headline 3 is one live wave in a throwaway clone with a fresh Store and a 60-minute cap. Sol does all Mac execution. Before each run, a one-line estimate goes into that run's artifact; any gap is reported as a finding. The appendix below is a separate **measured Linux fixture** study and does not supply any headline.

**Limits.** No Mac runner has been connected tonight. The only approved route, the 1993-X2 runner, must be reconnected by the user. Until then, no Mac footprint, Mac wakeup, before/after or live result exists, and Linux numbers do not substitute for any of them. The single production fix (wait until the next deadline, capped at 1 s) is **found, not fixed**. It waits for a measured Mac baseline, the full suite and recovery/qualification passing, and one Sol correctness review. Linux context switches are not accepted as that baseline. P1 reports that transient client footprint is unavailable and that steady-state clients are reaped, so the clients column may stay empty even on a Mac. SQLite synchronous/journal settings are out of scope: they are measured and reported only, and any change is the user's decision.

---

## Appendix: Linux fixture attribution (measured, fixture, not Mac, not live)

Source of every number here: P2 evidence at `perf/linux-attribution` [`48c0db21`](https://github.com/DivyanshGolyan/rui/commit/48c0db21f4ceff701bd7ed426d53156a9a868e8d). One Sol review produced a no-findings count/reduction verdict on [`e8a8cc9f`](https://github.com/DivyanshGolyan/rui/commit/e8a8cc9f0516da8371cc55f11b1a3542521fbc2a). Between that commit and `48c0db21`, only `NOTES.md` and its manifest digest changed. Full write-up: [ATTRIBUTION.md](../../.amp/p2/ATTRIBUTION.md). Commands: [COMMANDS.md](../../.amp/p2/COMMANDS.md). Notes, with the pre-run estimates: [NOTES.md](../../.amp/p2/NOTES.md). Raw data: [raw/](../../.amp/p2/raw/), manifest [evidence.sha256](../../.amp/p2/raw/evidence.sha256), reducer [analyze.py](../../.amp/p2/analyze.py).

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

### N100 on-CPU sampled user stacks (measured, Linux fixture, one profile)

The profile has 4,466 `cpu-clock:u` samples. The families below overlap, so they are not exclusive CPU shares. In 567 samples the leaf symbol is unresolved (540 in the vDSO), 4,294 samples contain an unknown frame, and kernel stacks are unavailable. Flamegraph: [stream100-flamegraph.svg](../../.amp/p2/raw/stream100-flamegraph.svg).

| Stack family | Samples | Share of user samples |
| --- | ---: | ---: |
| curl/OpenSSL prefixes | 3,481 | 77.9445% |
| SQLite | 613 | 13.7259% |
| `provider_output` | 222 | 4.9709% |
| Positional I/O | 52 | 1.1644% |

### HOLD100 natural context switches (measured, Linux fixture, not Mac wakeups)

In the untraced HOLD100 run, Host threads made 5,300 voluntary context switches in a 60 s interior window, about 88/s. All of them come from two threads: 2,980 (≈49.7/s) and 2,320 (≈38.7/s). The other three threads made 0 ([thread-deltas.json](../../.amp/p2/raw/hold100-untraced/thread-deltas.json)). The pre-run estimate was 6,200. These per-thread rates are close to the estimated intake 20 ms `poll` (50/s) and execution `curl_multi_poll` 25 ms (40/s) timers. This match is a **hypothesis**: thread identities were not recorded, and a Linux switch count is not Mac `IDLEW` or a count of distinct timer wakeups. The traced HOLD run made 7,200 `poll` calls and 1,212,768 voluntary switches. Those switches are ptrace distortion and are not reported as natural.

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
- **Not independently verified:** the review reproduced 93/93 manifest hashes and all nine reductions. It did not rebuild the unpublished measurement binaries.
