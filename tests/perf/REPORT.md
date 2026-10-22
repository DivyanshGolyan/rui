# Rui overnight performance report, 21–22 Oct 2026

**Status: final for tonight, Linux only.** No Mac runner was connected, so there is no macOS footprint, Mac wakeup or live result; nothing Linux is presented as Mac. Every number is labelled **measured** or **estimated**; all measurements are **Linux fixture** runs, none **live**. Baseline: main/stable [`240aef2e`](https://github.com/DivyanshGolyan/rui/commit/240aef2e46d7240ce31a02ce4cefceb695551a56). Two fixes **landed** at 00:05:30 UTC on 22 Oct as main = stable = [`d4f87000`](https://github.com/DivyanshGolyan/rui/commit/d4f870002b1eeef370fb8f4c7aa3fd8b14343159). Their before/after numbers were measured on the original source commits [`4950c22e`](https://github.com/DivyanshGolyan/rui/commit/4950c22effd8120a4b8f689c81c652ef13e50d8b) and [`12f84075`](https://github.com/DivyanshGolyan/rui/commit/12f84075a2f5e73dcd5e4c8b38ed0ea890f1beef), each on `240aef2e`; no workload ran on the landed combined head, so this report makes no combined performance claim.

**Setup.** 2-vCPU Linux 6.1 orbs (KVM, Xeon 2.6 GHz); ReleaseFast builds with identical options; the existing Go qualification harness and samplers (frozen harness [`a204296c`](https://github.com/DivyanshGolyan/rui/commit/a204296c7289cf0a90f95df155c4f27832c924fe)); fixed Host capacity 100, TLS/H2. A/B runs alternate in one orb. CPU is Linux user+system time at 10 ms granularity.

**Memory versus sessions** (**measured**, Host PSS, 3 fresh Hosts per N): N=0 7,362,560 B; N=10 11,345,920 B; N=100 13,596,672 B. Linear fit 9,024,073 B base + 47,572 B/session, but the curve is **not linear**: ≈398 KB/session from 0 to 10, ≈25 KB/session from 10 to 100. Clients are reaped at steady state; transient client peaks are unavailable.

**CPU** (**measured**, Host only). Idle wait, 100 held streams with no events: 1.64 CPU-s/min ≈ 2.7% of one core (P1 median of 3). Streaming, 100 streams × 100 events/s: 96.535 CPU-s per 1.2M events ≈ 80 µs/event (P1 median of 2, same orb). Another orb measured 42.40 CPU-s for the same fixture, so only same-orb pairs are comparable.

**Hotspots** (**measured** counts, not CPU attribution). At N=100 streaming, `preadv` was 67.3% of all syscalls (7.08/event, SSE rereads). SELECT is ~98% of SQL statements; uncertain-Action recovery and control reconciliation callers account for ~94% of all statements. Sampled stacks are dominated by curl/OpenSSL.

**Fixed** (all values **measured**, Linux fixture, on the original source commits):

| Waste item | Before (`240aef2e`) | After | Status |
| --- | ---: | ---: | --- |
| Intake loop's fixed 20 ms `poll` while idle (HOLD100) | 87.90 voluntary switches/s; 1.64 CPU-s/min | 39.70/s (−54.8%); 1.54 CPU-s/min (near noise) | **Fixed: landed `d4f87000`** (source `4950c22e`) |
| SSE framing rereads (5 of 7 per event), STREAM100 | all syscalls 10.52147/event; `preadv` 7.07634/event; Host CPU 80.4458 µs/event (96.535 CPU-s / 1.2M) | all syscalls 8.24657/event; `preadv` 2.07284/event; Host CPU 77.0917 µs/event (92.510 CPU-s / 1.2M) | **Fixed: landed `d4f87000`** (source `12f84075`) |

The switch counts are a Linux voluntary-context-switch proxy; **distinct wakeups are unavailable** (no honest counter on these orbs). The SSE CPU per event is a descriptive median of two completed pairs (−4.17%), a partial result and not a general claim. Syscall counts are traced; CPU is untraced.

**Found, not fixed** (proposals not built tonight):

| Item | Measured | Napkin cost (**estimated**) | Proposal |
| --- | --- | --- | --- |
| Idle SQL polling (HOLD100) | 1,004.39 SELECT/s vs 62.44 with 0 held (16.1×); control reads 964.84/s | 0.1–1.0% of one core, assuming 1–10 µs per query | Execution Store-commit wake with a post-`COMMIT` generation; keep the existing control hints and the 100 ms lost-hint fallback, and skip SQL only after a generation and lost-hint proof |
| Execution loop 25 ms / 100 ms polls | ≈38.7 switches/s remain on the other busy thread (attribution is a hypothesis) | not separately estimated | Same Store-commit wake |
| `fsync` per Message | 29.5 (N=1), 24.06 (N=100) | I/O wait, not CPU: assuming 1–10 ms per `fsync`, ≈24–300 ms of sync wait per Message | **User decides** durability; no change proposed without that decision |
| PSS step from 0 to 10 sessions | +3,983,360 B (≈398,336 B/session) vs ≈25 KB/session from 10 to 100 | — | Cause unknown; investigate first-activation allocations (pools, TLS/H2, SQLite caches) |
| SSE JSON second pass | 2 rereads/event, 274 B | small; curl/OpenSSL dominate stacks | Parse JSON from the scanned buffer |

**Combined-head confirmation on `d4f87000`:** pending. These are independent methods; traced switches are not natural wakeups.
- P1 started at 00:59:21 UTC: one STREAM100 then one HOLD100 window, a fresh Host and Store each, the frozen harness `7f4fe110`/`a204296c`, the existing 10 s + 60 s method and no instrumentation. Pre-run estimate (**estimated**): STREAM 13.6 MB PSS and 0.45 cores; HOLD 13.45 MB, 40 voluntary switches/s and 1.54 CPU-s. Target branch `perf/linux-postfix-confirm-20261022`. The ReleaseFast build of `d4f87000` finished at 01:03:51 UTC (42/42 steps, exit 0, binary SHA-256 `98bfb3f1…ef719`); STREAM100 started at 01:03:52 UTC. STREAM and HOLD each completed once with exit 0, at 01:05:04 and 01:06:16 UTC, and both final JSONs are kept. A later service restart left record gaps; see "Post-fix restart incident" in the appendix limits. Results (**measured**, Linux fixture, **owner-reported, artifact not yet published**; observation method only, not complete-work or Mac qualification):
  - STREAM100: Host PSS 13,520,896 → 13,594,624 B across the window; 21.98 CPU-s / 60.057 s = 0.366 cores (estimate 0.45). Headline 1's pre-fix N=100 median was 13,596,672 B.
  - HOLD100: Host PSS 13,415,424 B at both ends; 1.42 CPU-s / 60.000 s (pre-fix median 1.64, B median 1.54). Five threads: 2,375 voluntary and 81 nonvoluntary switches, a proxy of 39.583/s, matching the B median of 39.70/s. Distinct wakeups **unavailable**.
  - Clients: steady-state count and PSS 0; transient peaks unavailable. One run each, so no spread; the aborted extra STREAM is not used as a replicate.
- P2 is preparing one instrumented HOLD100 window (10 s warmup + 60 s). Pre-run estimate (**estimated**): about 1,000 SELECT/s, since the fixes did not touch SQL polling.

**Open items.**
- No Mac measurement (footprint, wakeups) and no live 100 × gpt-6-luna wave: the only approved runner, 1993-X2, is offline.
- SQL polling and the execution-loop polls need an execution Store-commit wake (proposal below, not built); adding a wake alone does not remove the queries.
- With the SSE fix, other syscalls rose by 3.27M per run, mostly `recvfrom` (+2.48M); cause unknown.
- Artifact reviews are pending. P2's SSE-count (131 hashes) and matched-SQL (141 hashes) artifacts are owner-verified and queue-reproduced (hashes and reducers), without an independent artifact review. P1's SSE CPU artifact is owner-verified only, with its audit pending. Source correctness review of both fixes is complete.
- A3 of the SSE CPU A/B was killed by an executor restart and B3 never ran, so that A/B has two pairs, not three.

Details, method, limits and every artifact link follow. Raw data stays on the perf branches listed in each section.

---

## Details

## Headline 1: Linux PSS (macOS footprint pending), Host and clients, N = 0/10/100

| N sessions | Host PSS (`smaps_rollup`) | Clients PSS | Source SHA |
| ---: | --- | --- | --- |
| 0 | **measured** median 7,362,560 B (IQR 5,120 B) | 0 B steady state (clients reaped); transient peaks unavailable | `240aef2e` |
| 10 | **measured** median 11,345,920 B (IQR 13,312 B) | 0 B steady state; transient peaks unavailable | `240aef2e` |
| 100 | **measured** median 13,596,672 B (IQR 8,704 B) | 0 B steady state; transient peaks unavailable | `240aef2e` |
| Intercept (base) / slope (per session), linear fit | 9,024,073 B / 47,572 B per session. Residuals reach 1.85 MB, so this is **not** a constant per-session cost: the step from 0 to 10 sessions (≈398 KB/session) is far steeper than from 10 to 100 (≈25 KB/session) | — | — |

Each N has 3 fresh Hosts; the IQR is (max − min)/2 over those three. Headline 1 data, measured Linux fixture: P1 raw evidence at `perf/linux-pss-20261021` [`ab9f3e41`](https://github.com/DivyanshGolyan/rui/commit/ab9f3e410e4d06ad77c8a2fea6b8db6ccd5513e0) (`.amp/p1/summary.json` and `.amp/p1/raw/`). All nine runs and HOLD A1 passed, and all ten Host/provider pairs were reaped. Review: the same Sol reviewer gave a bounded no-findings audit of `ab9f3e41`, covering the nine PSS runs and HOLD A1 only, not the later A/B runs. It verified:
- 102 hashes with full file coverage, and the summary byte for byte;
- all 20 PSS endpoints and all 13 counter fields;
- the CPU arithmetic, identities, medians, IQRs and the exact OLS fit;
- the HOLD five-thread switch counts (5,278 voluntary, 91 nonvoluntary).

Audit limits:
- The fit is descriptive and nonlinear; it does not attribute marginal cost to TLS or anything else.
- The HOLD switch capture spans 60.05914–60.05957 s, while the 1.70 CPU-s comes from a separate 60.05890 s interval.
- Counters are sequential and coarse.
- STREAM rate and CPU/event stay null.
- Nobody independently rebuilt the binary or rechecked provider liveness.

The harness source is [`a204296c`](https://github.com/DivyanshGolyan/rui/commit/a204296c7289cf0a90f95df155c4f27832c924fe), and the baseline ReleaseFast binary SHA-256 is `e2835cb2…3a50`. The queue verified 102/102 hashes and all ten row identities and statuses at `ab9f3e41`; that is a hash and identity check, not a qualification verdict. STREAM in-window event rates and CPU/event are unavailable: provider totals publish only after the 120 s offer. They are null, not zero.

## Headline 2: HOLD100 waiting cost, before and after one deadline-wait fix (Linux fixture)

| Build | Host voluntary switches/s (Linux, not distinct wakeups) | Host CPU while waiting | Source SHA |
| --- | --- | --- | --- |
| Before, earlier P2 single run (**measured**) | ≈88/s (5,300 in 60 s; two threads at ≈49.7/s and ≈38.7/s) | 3.07% of one core (1.84 CPU-s / 60.01 s) | `240aef2e` |
| Before, P1 A1 (**measured**) | 87.88/s proxy (5,278 voluntary in 60.059 s: two threads at 2,955 and 2,323; 91 nonvoluntary) | 1.70 CPU-s / 60.059 s ≈ 2.83% of one core | `240aef2e` (binary `e2835cb2…3a50`) |
| Before, P1 A2, A3 (**measured**) | 87.90/s, 87.96/s (5,279 each) | 1.64, 1.61 CPU-s | `240aef2e` |
| **Before, median of A1–A3 (measured)** | **87.90/s** | **1.64 CPU-s / ≈60 s ≈ 2.7% of one core** | `240aef2e` |
| After, P1 B1, B2, B3 (**measured**) | 39.70/s, 39.63/s, 39.78/s (2,384 / 2,378 / 2,388) | 1.56, 1.54, 1.47 CPU-s | `4950c22e` (binary `ec840083…b439`) |
| **After, median of B1–B3 (measured)** | **39.70/s (≈54.8% fewer)** | **1.54 CPU-s / ≈60 s ≈ 2.6% of one core (≈0.10 CPU-s/min less)** | `4950c22e` |
| Failed candidate, not measured | — | — | [`f6a2df85`](https://github.com/DivyanshGolyan/rui/commit/f6a2df856fba8a68cb875f8b7432702910c734de): failed `admission-debug-integration`; review found the same defect (closed exchanges waited up to 1 s for removal) |
| Pre-run napkin (**estimated**) | ≈90/s before; ≈40/s after (only the intake 20 ms timer is removed) | not estimated | — |

What the A/B shows (measured, Linux fixture, P1 [`4463e505`](https://github.com/DivyanshGolyan/rui/commit/4463e5051a79f46e88b3f3636985b2f0867b958f), runs alternated A1/B1/A2/B2/A3/B3, all exit 0):
- One Host thread fell from ≈2,955 to exactly 60 voluntary switches per 60 s, which is the 1 s cap. That supports attributing it to the intake loop (source reasoning, not verified by the review); the counter still counts voluntary context switches, not distinct wakeups. The other thread stayed at ≈2,320 per 60 s (≈38.7/s), consistent with the unchanged 25 ms execution/curl wait.
- Voluntary context-switch proxy events fell 54.8%, matching the pre-run estimate of ≈40/s. This is not a measured count of distinct wakeups, which remain unavailable.
- **CPU barely moved:** 1.64 → 1.54 CPU-s per minute, about 0.17% of one core, within the spread of single runs and at Linux's 10 ms CPU granularity. Removing the intake timer is not a material CPU saving; most waiting CPU is elsewhere (likely the execution loop's 25 ms wait, unmeasured per thread).
- HOLD Host PSS medians 13,499,392 → 13,450,240 B: no meaningful change, as expected.
- Review: the same Sol reviewer gave a separate, bounded no-findings verdict on the A/B delta `ab9f3e41` → `4463e505`, distinct from the baseline verdict on `ab9f3e41` and from qualification of the fix. It verified:
  - 162 hashes with full coverage, the summary and the non-live verifier;
  - all 15 rows, all 30 memory endpoints and the dedicated CPU pairs;
  - the HOLD per-thread sums and the build and run-order identities;
  - that all three paired proxy differences have the same sign (median 87.900 → 39.696/s, 54.839% fewer).

  Review scope excludes distinct or timer wakeups, thread-role attribution, confidence intervals, any general CPU speedup and production qualification. An earlier audit endpoint error by P1 (general 28.23 versus dedicated 28.22) is kept, and no workload was rerun. Post-teardown process absence is P1's own orb evidence, and nobody rebuilt the binaries independently.

**Database polling while waiting** (**measured** SQL counts, Linux fixture, matched run, P2 [`351ed4aa`](https://github.com/DivyanshGolyan/rui/commit/351ed4aa94f13890c7ca65122c7884ea79ee2330), owner-verified, independent audit pending). With the same Host and the same 100 configured Sessions, 0 held streams ran 62.44 SELECT/s and 100 held streams receiving no events ran 1,004.39 SELECT/s: 16.1× as many, +941.9/s. That is substantial polling with no useful work, mostly per-operation control reads (964.8/s). These are statement counts, not CPU cost. **Found, not fixed.** Details are in the appendix under "Where the SELECTs come from".

- **Exact call sites** (source at `240aef2e`, checked by P4):
  - Control reads, 964.8420/s: `serviceLifecycle` (`src/execution_turn.zig:37–45`) reconciles on a control hint **or** when the 100 ms `control_reconciliation_interval_ms` fallback is due. `reconcileControls` (`src/server.zig:1477`) → `cancelSupersededTransfers` (`src/server.zig:1769`) → `Store.operationSupersededByControl` (`src/store.zig:5600–5612`), one `SELECT … FROM model_operation WHERE operation_id=?1` per active slot. Each call takes the Store lock and prepares and finalizes the statement anew (`prepare`, `src/store.zig:7416`).
  - Uncertain-Action scans, 38.5437/s: `src/execution_turn.zig:61` → `recoverOneUncertainActionLocked` (`src/store.zig:4568`) on every execution turn, before free capacity is checked, although neither fixture Store has any Action rows.
- **Constraint:** the hint wake (`Host.controls_changed`) already exists. The 100 ms fallback is deliberate and covered by tests: `execution_turn.zig` "absent control hint still reconciles when the fallback deadline is due", plus the `suppress_first_control_hint` fault. A fix must keep recovery from a lost hint.
- **CPU cost (estimated, not measured;** P2 [`812fdd69`](https://github.com/DivyanshGolyan/rui/commit/812fdd694632ee02805223cf3f3aaf0736880e38), [ATTRIBUTION.md](../../.amp/p2/ATTRIBUTION.md)**):** if each control query costs 1 µs inclusive, 964.8420 queries/s is 0.0965% of one core; at 10 µs it is 0.965%. Applying the same per-query assumptions to all 1,004.3855 SELECT/s gives 0.100% or 1.004%. No part of the measured 1.84 CPU-s whole-Host HOLD figure is allocated to SQL, and no speedup is claimed. The scaling "about 10 control queries per held operation per second" (100 ms × N) is a hypothesis, not a measured cadence.
- **Proposed fix (P2, not built tonight):** a process-local execution wake plus a generation number bumped after each successful `COMMIT`. The loop drains the wake before rechecking canonical state, and detects commits that race with that recheck. The existing `controls_changed`/replay hints and the deliberate 100 ms lost-hint fallback stay. **Adding a wake alone does not remove the ~965 queries/s**: skipping SQL when the generation is unchanged is safe only after proof that every relevant commit publishes and that lost hints are still recovered. Transport, retry, inactivity, Bash, cleanup, startup, capacity and deadline obligations stay unchanged, and so does durability.

## Headline 3: one illustrative live Mac 100 × gpt-6-luna wave

| Quantity | Value |
| --- | --- |
| All quantities | **SKIPPED tonight**: the credentials exist only on the offline 1993-X2 Mac runner. No credential probe was made. |

**Method.** Headlines 1 and 2 use the existing Go qualification harness and measurement samplers, executed from P1's frozen harness source [`a204296c`](https://github.com/DivyanshGolyan/rui/commit/a204296c7289cf0a90f95df155c4f27832c924fe) (executable SHA-256 `7f4fe110…5ade6`): `tests/qualification/model-output --sessions 0|10|100 --expectation '<estimate>'` (fixed Host capacity 100), plus `--hold` with `--sessions 100` for Headline 2. P1 runs on Linux in its own 2-vCPU orb, with Host and client PSS from the existing `smaps_rollup` sampler. All builds are ReleaseFast with the same options and caches: the nine PSS runs and A runs use `240aef2e` (binary `e2835cb2…3a50`); B runs use `4950c22e` (binary `ec840083…b439`). Each run uses capacity 100, TLS, 30 events/s/stream, a 10 s warmup and a 60 s window, 3 fresh Hosts per N, with the commit SHA on every row. Headline 2 alternates A1/B1/A2/B2/A3/B3 in the same orb with the same harness and observer, both binaries built identically, and no builds during measured windows. Before each run, a one-line estimate goes into that run's artifact; any gap is reported as a finding. The appendix below is a separate **measured Linux fixture** attribution study.

**Fix (candidate [`4950c22e`](https://github.com/DivyanshGolyan/rui/commit/4950c22effd8120a4b8f689c81c652ef13e50d8b), one file `src/server.zig` +36/−8; landed in `d4f87000`, see "Combined landing" below).** Gates so far: Sol review, no findings. Selected review targets (`check`, `admission-debug-integration`, `codex-h2-integration`, `transport-h2-integration`) passed on the exact head on Linux, after one rerun that installed CI's pinned `pyte`/`wcwidth`/`h2`; the first run failed only on `ModuleNotFoundError: pyte` and its log is kept. Mac Selected and the previous-release upgrade check, which landing requires because `src/server*` is a strict path, did not run on this source commit; both later passed on the combined landing commit. The intake loop's fixed 20 ms `poll` becomes a wait until its earliest owned deadline, capped at 1 s. Those deadlines are header/body inactivity, reply deadline, delivery `not_before`, `accept_retry_at` and `cleanup_retry_at`. Worker completion, `fenceDispatch` and `host_stop` already write the intake wake pipe. A test FIFO delivery gate keeps the 20 ms check. The execution loop's 25 ms (curl/Bash) and 100 ms (idle) waits are **found, not fixed**: newly admitted Messages are discovered only by polling. A 1 s cap would add up to 1 s of admission latency unless a Store-commit wake were added, and that is out of scope tonight.

**Second fix (candidate [`12f84075`](https://github.com/DivyanshGolyan/rui/commit/12f84075a2f5e73dcd5e4c8b38ed0ea890f1beef), one file `src/provider_output.zig`; landed in `d4f87000`): SSE framing rereads removed.** `validate` already scans every SSE line through a buffered window, then issued one to six extra positional reads per line for the line ending, field prefix, the space after `data:` and `[DONE]`. The candidate keeps the line's first 16 and last 2 bytes from that scan instead. Estimate (**estimated**): about 4–5 of the 7.076 `preadv` calls per event at N=100; CPU effect small, because curl/OpenSSL dominate sampled stacks. It is **not** read-each-byte-once: event JSON is still parsed a second time from its range, which stays **found, not fixed**. A new framing test passes on both the baseline and the candidate, and the provider unit tests pass 56/56. Selected on the exact head passed on Linux: `dispatch-integration` and `test` (320 s) and `transport-h2-integration` (45 s), all exit 0. `src/provider_output.zig` is not a strict path; the coordinator held landing until the combined stack below. **Review:** a fresh Sol reviewer ([thread](https://ampcode.com/threads/T-01a1608d-e9b0-72b4-afdb-78b1fa508c76), started by Puck) found **no actionable correctness or standards findings** on exact `12f84075` versus `240aef2e`. It checked head/tail framing, `[DONE]` forms, field and space rules, and the sealed production handoff. Its own provider suite passed 55/55, and scratch public-`validate` probes passed on both heads: 219 refill alignments, every truncated prefix, short extents, CRLF and bare CR, prefix and `[DONE]` variants, empty and multiline events, and invalid UTF-8. It noted the committed test lacks refill, extent and duplicate-`[DONE]` cases, but found no consequential gap. Its own Selected run is **not green**: the first attempt failed on generator cache-path resolution in the exported tree, and one recovery ended without a conclusive result. That is not a gate pass; the Linux Selected pass above is this lane's separate evidence. No Mac, live or performance qualification.

**Combined landing (code only, LANDED 00:05:30 UTC).** [Auto-land run 39697523381](https://github.com/DivyanshGolyan/rui/actions/runs/39697523381) advanced main and stable `c62d7215` → `d4f87000` as one atomic non-force fast-forward. Only `src/server.zig` and `src/provider_output.zig` changed; no raw data or REPORT landed. The upgrade check passed: normal install, the default soft fd limit of 256, same-format restart and explicit rejection of the prior format, with no migration. History: the coordinator ordered both fixes stacked together as land-19. `perf/p4-land19-code` @ `dc0c5447` puts three separate commits on main `c62d7215`: `4d525c9a` (`f6a2df85`), `09c3024b` (`4950c22e`) and `dc0c5447` (`12f84075`). Its `src/server.zig` and `src/provider_output.zig` blobs are identical to the reviewed heads; the queue verified this independently. The new base changed only the qualification harness, so the earlier build and Selected receipts do not cover this head. Required gates: Linux and Mac Selected (`admission-debug-integration` on both systems is the recovery requirement), then the upgrade check. The queue alone writes `wip/land-19` and adds a tree-identical `[skip ci]` metadata child, so the **landed SHA `d4f87000` differs from the source SHA `dc0c5447` while its tree is identical**. Final `wip/land-19` = [`d4f87000`](https://github.com/DivyanshGolyan/rui/commit/d4f870002b1eeef370fb8f4c7aa3fd8b14343159), an empty `[skip ci]` child of `dc0c5447`. Hosted Selected [run 39693676192](https://github.com/DivyanshGolyan/rui/actions/runs/39693676192) **passed on attempt 1** on Linux x86_64 and Darwin arm64. The queue inspected the logs: full Debug admission, composed Bash and settlement recovery and both H2 suites pass on each platform (recovery recorded 23:50:58 UTC). The same-head upgrade check [run 39696038434](https://github.com/DivyanshGolyan/rui/actions/runs/39696038434) then passed on attempt 1. The queue dispatched Selected from base `c62d7215` and inspected both systems' recovery results before dispatching the upgrade check. P4's local Linux Selected on `dc0c5447` (23:23:48–23:34 UTC) **passed, EXIT=0**: `admission-debug-integration` 10.4 s, `check` 557.2 s, `codex-h2-integration` 4.4 s, `transport-h2-integration` 41.3 s, all exit 0 (log `.amp/p4/selected-land19-dc0c5447.log` in P4's orb). It is supporting evidence for the source SHA only, not acceptance of the final SHA.

**SSE fix result (measured, Linux fixture; artifacts owner-verified, independent artifact audit pending):**

| `240aef2e` → `12f84075` | Before | After | Source |
| --- | ---: | ---: | --- |
| `preadv` per event (traced, P2) | 7.07634 (8,491,607) | 2.07284 (2,487,410) | P2 [`1a0a06ca`](https://github.com/DivyanshGolyan/rui/commit/1a0a06caf105d3c486548d5c4f0a9a4f2c7a514f) |
| All syscalls per event (traced, P2) | 10.52147 (12,625,760) | 8.24657 (9,895,882) | same |
| `fsync` per Message (traced, P2) | 24.06 (4,812) | 24.075 (4,815) | same |
| Host CPU-s per run, untraced (P1) | A1 96.71, A2 96.36 | B1 90.85, B2 94.17 | P1 [`5c9e3f23`](https://github.com/DivyanshGolyan/rui/commit/5c9e3f232a08b1e3535a5be3f700b92a5a165d3c) |
| Median of 2 completed pairs (P1) | 96.535 CPU-s | 92.510 CPU-s (−4.17%, descriptive) | same |

Each run, in both studies, is 1,200,000 actual 260-byte events and 200 audited Messages. Notes:
- The measured `preadv` reduction (−6,004,197) matches the estimated reduction (−6,000,000). From the baseline total of 12,625,760 calls, that estimate implied a post-fix total of about 6,625,760 (**estimated**). The measured post-fix total was 9,895,882, a measured total reduction of only 2,729,878, because other calls **rose** by 3,274,319, mainly `recvfrom` (+2,482,223). The cause is unknown and is retained as a finding.
- P1's paired CPU savings are 5.86 and 2.19 CPU-s. Two pairs give no confidence interval; this is a bounded partial result, not a general CPU speedup.
- **A3 was interrupted**: P1's journal shows `systemctl` sending SIGTERM to the run's executor scope at 20:36:53 UTC, the same second the Amp process restarted. OOM counters are 0. The restart cause is unknown. A3 has no result, B3 never started and nothing was retried.
- P1 did not serialize the complete-work initial CPU endpoint, so independent delta subtraction is unavailable. All canonical results are exit 1 (`incomplete`, missing Mac footprint only), and pacing diagnostics mark every stream timing-invalid in both studies.
- P2's counts come from a traced binary (`8c3add2e…c123c6`) and P1's CPU from an untraced one (`c7f0becc…db32`), so the two are kept separate. P2's 131-hash count export is owner-verified and queue-reproduced (hashes and reducers); an independent artifact review is still pending. P1's 149-entry CPU manifest is owner-verified, with its artifact audit pending. These are artifact checks; the source correctness review of `12f84075` is complete (above).

Run history:
- P1 uses the existing `--capacity 100` complete-work path, with two 60 s rounds and an expected 1.2M events and 200 Messages per run. Only the audited final counts are used. This offers 100 events/s/stream, not the 30/s of the `--sessions` headline runs, so it is not comparable with Headline 1. Order is A/B/A/B/A/B. A is the baseline binary `e2835cb2…3a50`. B is a ReleaseFast build of `12f84075`, built with the same options and caches (42/42 build steps, exit 0), SHA-256 `c7f0becc…db32`. A1 started at 20:23:30 UTC. P1's pre-run estimate (**estimated**, rough extrapolation): A ≈180, B ≈171 CPU-s per run. P2's earlier 42.40 CPU-s from another orb is a separate measurement.
  - A1 (**measured**, P1 [`dfb1542b`](https://github.com/DivyanshGolyan/rui/commit/dfb1542b45e3a462a61a656bcae1bd713f16011b) on `perf/linux-sse-cpu-20261021`): 2 × 600,000 audited offer events and 2 × 100 Messages. Host complete-work CPU was 49.06 + 47.65 = 96.71 CPU-s, or 80.59 µs per completed offer event, against the pre-run estimate of 180. The run exits 1 (`incomplete`) only because Mac footprint is unavailable; every functional and audit dimension passes. Caveat: pacing diagnostics mark all 100 streams timing-invalid in each round, so the offered rate was not exactly paced. Under the complete-work contract that stays a diagnostic, but CPU per event is the comparable figure, not CPU per second. Also, 96.71 CPU-s is about 2.3× P2's 42.40 CPU-s for the same fixture on a different orb, so cross-orb CPU numbers are not comparable; only same-orb A/B pairs are.
  - B1 started at 20:29:48 UTC; A3 started at 20:36:15 UTC and was killed with its scope (above). P1's [NOTES.md](../../.amp/p1-sse/NOTES.md), [summary.json](../../.amp/p1-sse/summary.json) and [analyze.py](../../.amp/p1-sse/analyze.py) keep all four completed runs, the A3 partials with explicit nulls, and the sanitized termination receipt.
- P2 counted syscalls separately with its original strace method: [sse-candidate-comparison.json](../../.amp/p2/raw/sse-candidate-comparison.json), [stream100-sse-candidate.json](../../.amp/p2/raw/stream100-sse-candidate.json), [identity](../../.amp/p2/raw/sse-candidate-identity.txt).

**Limits.** No Mac runner is connected; the only approved route, 1993-X2, needs the user to reconnect it. So there is no macOS footprint or Mac wakeup result, and Linux PSS and switch counts are labelled as Linux, not as Mac results. Linux voluntary context switches are not distinct timer wakeups, and scheduler wakeup tracepoints appear unavailable. P1 reports that transient client footprint is unavailable and that steady-state clients are reaped. Both fixes met the landing bar (Sol review, Linux and Mac Selected including recovery, upgrade check) on the landed commit; their performance numbers come from the original source commits only. SQLite synchronous/journal settings are measured and reported only; any change is the user's decision.

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

Notable measured findings (the `preadv` item led to the landed SSE framing fix; the rest were not acted on):

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

Finding (measured, Linux fixture): with nothing to do, 100 held streams cost the Host about 3% of one core, roughly 34× the estimate built from the 20 ms and 25 ms timers. This is relevant waiting-cost evidence for the deadline-wait fix, but it is Linux, a single run, and has no before/after. The paired before/after for the deadline-wait fix is P1's Headline 2 A/B, not this single run.

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

### Where the SELECTs come from (measured counts, Linux fixture)

Source: P2 [`352ea142`](https://github.com/DivyanshGolyan/rui/commit/352ea142df47ca1c6c006b3bf165a23200ac3e07), merged here: [sql-owner-summary.json](../../.amp/p2/raw/sql-owner-summary.json), [sql-phase-summary.json](../../.amp/p2/raw/sql-phase-summary.json), call sites in [ATTRIBUTION.md](../../.amp/p2/ATTRIBUTION.md). P2 verified the 116-entry manifest and both reducers. The queue then re-verified the 116 hashes and reproduced both SQL reducers byte for byte. That is a reproduction check, not an independent review, which is still pending. Exact rates: HOLD100 60,067 / 60.008008962 s = 1,000.983/s; cancelled-settled idle 1,248 / 20.018411884 s = 62.343/s. These are statement counts and rates from instrumented runs, not CPU cost and not proof of successful completion.

- **Existing logs, by caller:** uncertain-Action recovery accounts for 7,249 SELECTs at N=1 and 285,818 at N=100. Control reconciliation accounts for 1,140 and 124,156. Together that is 8,389 of 8,909 and 409,974 of 433,586 statements, about 94%. Neither fixture Store has any Action rows. These old logs have no phase clocks, so they do not show how much of that is polling.
- **New HOLD100 phase run** (60.008 s window, 0 events, 0 bytes, no admissions, mutations or transactions; every one of 2,307 execution turns had all slots full): 60,067 SELECTs, **1,000.98 per second**. That is 57,700 control reads, 2,307 uncertain-Action scans and 60 retry scans. Pre-run estimate: 62,460. So while 100 streams wait with nothing arriving, the Host still runs about 1,000 SELECTs a second, none of them part of an admission, mutation or transaction.
- **Cancelled-and-settled idle** (20.018 s, all 100 outcomes cancelled, none unresolved): 1,248 SELECTs, 62.34 per second, plus 218 `BEGIN` and 218 `ROLLBACK` with no `COMMIT`.
- **Empty Host, no Messages** (same run, 10.009 s): 629 SELECTs, 62.84 per second, plus 110 `BEGIN` and 110 `ROLLBACK`. This window ran **before** any Session was configured, had no warmup and lasted 10 s. The HOLD100 window followed 100 configured and admitted Sessions plus a 10 s warmup and lasted 60 s.

In plain terms (**measured** counts, **preliminary comparison**): holding 100 streams that receive nothing runs about 1,000.98 SELECTs/s, while the empty Host ran 62.84/s. Both numbers are measured, but the two windows differ in setup, so the ratio (about 15.9×, about 938 extra SELECTs/s) is **setup-confounded**, not a matched HOLD0-versus-HOLD100 result. It still shows substantial database polling while no events arrive. SQL counts alone do not establish CPU cost.

**Matched HOLD0 versus HOLD100** (**measured** counts, Linux fixture). Source: P2 [`351ed4aa`](https://github.com/DivyanshGolyan/rui/commit/351ed4aa94f13890c7ca65122c7884ea79ee2330), merged here: [hold-population-summary.json](../../.amp/p2/raw/hold-population-summary.json), raw [host-stderr.log.gz](../../.amp/p2/raw/hold-population/host-stderr.log.gz) and [evidence.json](../../.amp/p2/raw/hold-population/evidence.json), [identity](../../.amp/p2/raw/hold-population-identity.txt), [Store facts](../../.amp/p2/raw/hold-population-store-facts.json) and the retained [first reduction failure](../../.amp/p2/raw/hold-population-reduction-attempt1.txt). P2's clean export verifies 141/141 hashes and all six reductions byte for byte; that is owner verification, and an independent audit is pending. P2 ran it from 21:52:49 to 21:55:16 UTC and it passed. One Host at capacity 100, the same 100 configured `tools-none` Sessions, the same SQL-count binary and provider, and a 10 s warmup plus 60 s observation for each window. Admission happened outside both windows. P2's pre-run estimate (**estimated**): about 3,770 SELECTs at 0 and 60,060 at 100.

| Window | SELECTs | Interval, s | SELECT/s | Other statements |
| --- | ---: | ---: | ---: | --- |
| 0 held streams | 3,750 | 60.055861641 | 62.4419 | 655 `BEGIN` + 655 `ROLLBACK` (84.2549 statements/s total) |
| 100 held streams, 0 events/bytes | 60,273 | 60.009824453 | 1,004.3855 | none |

- SELECT ratio 16.0851×, +941.9437 SELECT/s. All-statement ratio 11.9208×, +920.1307 statements/s.
- Callers at 100: 57,900 control reads (964.8420/s, or 9.6484 per operation per second), 2,313 uncertain-Action scans (38.5437/s), 60 retry scans (0.9998/s).
- At 0 held streams, empty admission and continuation probes account for the remaining 51.5354 SELECT/s. Neither window has response bytes, events, `COMMIT` or data-changing SQL. Afterwards the read-only Store shows 100 cancelled Messages, 0 Actions and 0 unresolved model operations.
- Plainly: holding 100 streams makes the Host poll the database about 16 times as often while doing no useful work. This shows repeated SQL over unchanged state. It does not quantify CPU waste or set a speedup threshold, and control reads must stay responsive, so some polling cost is required.
- P2's reducer first rejected a `held_streams` field omitted at zero (the provider's `omitempty` rule). P2 corrected the reducer and kept the failure; the workload was not rerun.

This polling is **found, not fixed**: removing it needs a Store-commit wake or a SELECT redesign, both out of scope tonight.

### SSE byte-range rereads (measured counts, Linux fixture, small replay)

Source: P2 [`af391fc7`](https://github.com/DivyanshGolyan/rui/commit/af391fc7526d1eef55428053c939f054688df7eb), merged here: [sse-range-summary.json](../../.amp/p2/raw/sse-range-summary.json), [sse-replay-preadv.txt.gz](../../.amp/p2/raw/sse-replay-preadv.txt.gz), [sse-replay.log.gz](../../.amp/p2/raw/sse-replay.log.gz). It is published and owner-verified; P2's reducer reproduces all 56 matches between instrumented reads and actual `preadv` calls. An independent audit is pending. On the baseline, each 260-byte event rereads 7 ranges (283 bytes) that the scanner has already consumed:
- 5 framing reads: last byte of the line (1 B), CR check (1 B), `data:` prefix (5 B), leading space (1 B), and the last byte of the blank terminator line (1 B);
- 2 JSON reads: the event's fields (252 B) and its `type` string (22 B).

Candidate `12f84075` targets the 5 framing reads; the 2 JSON reads stay **found, not fixed**. This proof describes the baseline only. The candidate's measured N=100 counts are in the SSE fix table above (P2 [`1a0a06ca`](https://github.com/DivyanshGolyan/rui/commit/1a0a06caf105d3c486548d5c4f0a9a4f2c7a514f)): `preadv` fell by 5.00 per event, consistent with removing the 5 framing reads.

### Appendix limits and retained failures

- **Post-fix restart incident (P1, `d4f87000`):** P1 reports that both original windows finished before it, with no build overlapping them; that stays **owner-reported** until the published evidence is checked, and this report does not yet treat the post-fix metrics as an unqualified clean confirmation. At 01:06:19 UTC the managed service automatically restarted P1's finite wrapper, which did a cached rebuild and began an unintended second STREAM. P1 stopped the service at 01:06:42 UTC and reports it inactive. The aborted attempt produced no final JSON and did not replace the first; it is kept separately, and the campaign log keeps both starts. The restart overwrote the first STREAM run's controller-log and build-log paths, so those records are incomplete, and the campaign is **not** a strict single launch. No replacement capture was made. This is a measurement-harness incident, not a product failure.
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
