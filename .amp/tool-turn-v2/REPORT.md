# Coordinated Bash tool turns with a start barrier, campaign v2, 22 Oct 2026

**Status: measured Linux fixture campaign, owner-verified, no independent review.** This supersedes nothing: the v1 campaign without a barrier ([../tool-turn/REPORT.md](../tool-turn/REPORT.md)) is kept unchanged. All 38 v2 attempts exited 0 ([attempts.tsv](attempts.tsv)); a one-line estimate was written before each run ([napkins.tsv](napkins.tsv)). Every number is **measured** unless labelled **estimated**.

**Identity.** Product: origin/main = stable [`d4f87000`](https://github.com/DivyanshGolyan/rui/commit/d4f870002b1eeef370fb8f4c7aa3fd8b14343159), ReleaseFast, binary SHA-256 `993c3eb1…54f2` (same binary as v1). Harness executable SHA-256 `ec190670…2311` ([identities.txt](identities.txt)), built from the tree committed as [`aeef8596`](https://github.com/DivyanshGolyan/rui/commit/aeef8596) on `perf/tool-turn-20261022`; each run JSON records per-file source hashes. Landing candidate with the same harness code: [`98c960b6`](https://github.com/DivyanshGolyan/rui/commit/98c960b6) on `perf/tool-turn-code`. 2-vCPU Linux 6.1 orb, 4,025,412 kB RAM, Host active capacity 100. The campaign directory is named `campaign-v2-v2` because a path substitution in the script ran twice; nothing else differs.

## What changed from v1

- **Start barrier (bounded).** Each workload shell prints a park timestamp, creates `parked-<i>`, and blocks in `read -t 120` on a FIFO, all bash builtins, so parking adds no process. The controller polls the barrier directory every 5 ms and writes N release lines once all N shells have parked, or after 60 s. **Achieved, every non-strace run: all N parked before release (no timeout), and N of N workload calls overlapped** (from in-shell `$EPOCHREALTIME` start/end markers). This is synchronized, therefore artificial, concurrency: real agents would not start N reads in the same millisecond.
- **Active-phase sampling at 200 ms or 25 ms**, 3 repeats each, plus **coverage**: processes seen in at least one sample versus processes the turn must create.
- Unchanged: ~400 KiB history per Session (409,600 B seed; ≈102,400 tokens **estimated** by bytes/4, no tokenizer), exactly one real `rui session resume` TUI on the coordinator, and every `rui session send` is launched by a coordinator Bash call. Per N=100 run: 99 dispatch + 100 workload calls, 199 succeeded, 0 failed, over 1 H2 connection. **Request counts by phase**, derived by [reduce.py](reduce.py) from each run's raw provider facts (`provider.session_facts` received timestamps) against the CPU window (the `before_submit` to `active_end` points): the provider saw 3N requests per run (300 at N=100). N are history seeds, all received **before** the window; N measured-turn requests and N continuations, 2N in total (200 at N=100), all received **inside** it. The reducer asserts this for all 38 v2 and all 22 v1 runs; the harness now also derives and checks it (test `TestToolRequestPhasesUseReceivedTimes`).

## Results (median of 3 fresh Hosts; Linux PSS from `smaps_rollup`)

Peaks are the **highest observed sample**, not true peaks. Columns are deduplicated: each PID+start time is counted once per sample; sends run under Bash but are counted only as clients. **The Host, Bash and Clients peak columns are each that column's own maximum, which can come from different samples, so they need not sum to the total.** Only "Total, peak sample" is one simultaneous sample.

| Workload, N, interval | In flight | Host PSS idle → peak | Bash peak | Clients peak | Total, peak sample | Host CPU in turn | Observer CPU |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| sleep 1, 200 ms | 1 | 10.53 → 10.79 MB | 0.78 MB | 6.70 MB | 18.26 MB | 0.33 s / 8.26 s | 0.11 s |
| sleep 10, 200 ms | 10 | 11.05 → 11.28 MB | 5.43 MB | 6.72 MB | 23.37 MB | 1.64 s / 8.87 s | 0.15 s |
| sleep 100, 200 ms | 100 | 11.05 → 11.62 MB | 40.10 MB | 7.66 MB | 58.09 MB | 9.06 s / 18.92 s | 0.68 s |
| sleep 100, 25 ms | 100 | 11.02 → 11.58 MB | 40.10 MB | 7.72 MB | 58.31 MB | 8.56 s / 18.14 s | 2.48 s |
| read 1, 200 ms | 1 | 10.54 → 10.80 MB | 0.89 MB | 6.71 MB | 18.36 MB | 0.09 s / 3.26 s | 0.04 s |
| read 10, 200 ms | 10 | 11.12 → 11.34 MB | 3.51 MB | 6.95 MB | 21.51 MB | 0.57 s / 3.85 s | 0.07 s |
| **read 100, 200 ms** | **100** | 11.08 → 11.61 MB | 29.40 MB | 7.44 MB | 47.38 MB | 8.63 s / 13.77 s | 0.41 s |
| **read 100, 25 ms** | **100** | 11.07 → 11.66 MB | 45.78 MB | 7.72 MB | **63.93 MB** | 8.69 s / 13.92 s | 1.48 s |

The combined realistic case from the brief is the read N=100 row: 100 Sessions with 400 KiB history each, 1 TUI, 99 Bash-spawned sends and 100 simultaneous reads of a 100 KiB file. Its observed total peak is 63.93 MB at 25 ms and 47.38 MB at 200 ms; the bursts last ~80 ms, so the 200 ms samples miss most of them.

- **Steady state after the turn (all intervals):** total 17.48–18.20 MB = Host 10.8–11.5 MB + TUI 6.7 MB. Bash 0, sends 0.
- **Per process (median of each process's max sample, N=100):** workload shell 0.32–0.33 MB; `sleep` 0.10–0.17 MB; `cat` 0.21 MB; `rui session send` 0.74–1.03 MB; TUI 6.7–7.7 MB. At N≤10, shells are 0.41–0.62 MB because PSS divides shared pages among fewer processes.
- **Host CPU per call (read N=100, 200 ms):** 8.63 s / 100 workload calls = 86 ms; / 199 tool calls including dispatch = 43 ms; / 200 in-window model requests (measured-turn requests plus continuations; the 100 seed requests fall before the window and are excluded) = 43 ms. Sleep N=100: 91 / 46 / 45 ms. Per-run values are in `summary-v2.json` (`host_cpu_seconds_per_model_request_in_window`). These are whole-turn totals divided by counts, not marginal costs.
- **Read now costs about the same Host CPU as sleep** (8.6 vs 9.1 s at N=100), whereas v1 measured 5.5 vs 9.6 s. With the barrier, read shells stay parked for up to 4.8 s (park-to-start max) before running. This is consistent with Host CPU scaling with how long tool shells stay alive. It is still an aggregate observation; the polling cause is an unprofiled hypothesis.
- **Reaped descendant CPU** (shells, workload children and sends, inseparable): 0.67–0.71 s at N=100. TUI 0.13–0.16 s.
- **Dispatch sends still run 2–3 at a time**, 6–8 ms each: the barrier gates only workload calls, and the coordinator's 99 sends are close to serial in this Host.

## Short-lived process coverage and observer effect

| N=100, coverage over whole run | 200 ms | 25 ms |
| --- | --- | --- |
| Sends seen / 99 | 3, 4, 4 (read); 4, 5, 3 (sleep) | 27, 21, 37 (read); 25, 28, 26 (sleep) |
| `cat` seen / 100 | 0, 100, 0 | 100, 102, 101 |
| `sleep` seen / 100 | 100 | 100 |
| Shells seen / 199 | 147–157 | 199 |
| Observer CPU in turn | 0.41 s (read), 0.68 s (sleep) | 1.48 s (read), 2.48 s (sleep) |
| Host CPU in turn | 8.63 s (read), 9.06 s (sleep) | 8.69 s (read), 8.56 s (sleep) |

- At 25 ms, every shell and every parked or running workload child is seen. Sends, which live ≈7–8 ms, remain only 21–37% covered. Observed counts above 100 are subshells that `bash` forks briefly.
- 25 ms sampling costs 3.6× the observer CPU, but Host CPU moved within run-to-run spread (read 8.69 vs 8.63 s; sleep 8.56 vs 9.06 s). On 2 vCPUs the observer competes for the second core, so a small Host effect cannot be excluded.
- **Exact peak PSS is not obtained.** Send PSS (0.74–1.03 MB each) is measured only for the sends that were sampled. A napkin **estimate**, not a bound: with 2–3 sends overlapping and the largest *sampled* send at 1.03 MB, unsampled sends might add about 3 × 1.03 ≈ 3.1 MB at an instant. Unsampled sends were never measured, so they could be larger, and this does not cap the missing peak memory.

## Disk and page cache

- Seeding adds 409,600 B per Session to `rui.sqlite3` (41,164,800 B at N=100), as in v1.
- The tool turn adds 105 B (sleep 1), 54 KB (sleep 10), 0.75 MB (sleep 100), 0.12 MB (read 1), 1.20 MB (read 10) and 12.2 MB (read 100: 100 × ~100 KiB stdout kept in `store/scratch`, plus SQLite growth).
- System `Cached` was ≈3.1 GB of 4.0 GB during N=100 runs and **fell** by 17.8–22.9 MB across those turns: eviction under cache pressure dominates, so turn page-cache growth is **unavailable** (unattributable) at N=100. Smaller N grew 0.03–1.4 MB. Page cache is never added to PSS columns.

## Fork-to-exec (instrumented, pending independent review)

**Corrected method.** The first reduction started each interval at the parent's `clone` *return*, which is not a valid start; one pair came out negative. The retained raw logs support an entry-based pairing: `strace -f -ttt` stamps a complete line, or an `<unfinished ...>` line, with the syscall's entry time, and stamps a `<... resumed>` line with its return. The reducer now pairs the parent's `clone` **entry** (from the same thread's unfinished line when the call was split; 59 of 398 clones in the v2 read run) with the child's first `execve` **entry**, and asserts every interval is non-negative. All 1,632 pairs across the 6 strace runs (v1 and v2) are non-negative.

| Run | Host clone → bash execve, median (min–max) | bash clone → `rui` send execve, median (min–max) |
| --- | --- | --- |
| v2 read N=100 | 0.781 ms (0.268–1.684), 199 | 0.849 ms (0.323–1.989), 99 |
| v2 sleep N=100 | 0.807 ms (0.292–4.735), 199 | 0.928 ms (0.286–3.343), 99 |
| v1 sleep N=1 / 10 / 100, read N=100 | 0.800 / 0.770 / 0.782 / 0.771 ms | — / 0.855 / 0.823 / 0.792 ms |

**v1 erratum:** the v1 report's fork-to-exec figures used the clone-return start. Re-reduced with entry pairing, its medians are those in the last row ([summary-v1-rereduced.json](summary-v1-rereduced.json)); the v1 file itself is unchanged. These are durations **under strace**, which stops the tracee at every syscall and timestamps when strace handles each stop. They are instrumented upper-bound-style figures, not untraced fork-to-exec, which remains unavailable. strace also cut achieved overlap to 53–54 and inflated CPU; strace runs are used for nothing else. The fork-safety, fd-19 and signal-mask findings in the v1 report remain owner findings pending independent review. No launch or fd change was made.

## Limits

- The concurrency is synchronized by the barrier, not natural; v1 records natural overlap (sleep 96–99, read 1–2).
- PSS columns are observed sample peaks, with quantified coverage above; true peaks are unobserved.
- CPU uses 10 ms ticks; per-call figures include TUI submit, the 2N in-window history-sized model requests, Store commits, barrier wait and a 3 s tail.
- Controller and fixture CPU and memory are excluded; the observer's CPU is reported, not subtracted.
- Pre-campaign smoke attempts: two failed from the wrong working directory (kept in `smoke/` on this branch as `v2-read-n*.json.gz`); two passed (`v2b-*`).

## Records

`runs/<label>.json.gz` holds each final JSON; `runs/<label>-artifacts.tar.gz` holds the raw `tree-samples.jsonl`, provider facts, Host stderr, TUI transcript, barrier files and strace output (seed request captures excluded; their sizes and SHA-256s are in `seed-records-sha256.txt`). [summary-v2.json](summary-v2.json) is produced by [reduce.py](reduce.py) from those JSONs. The campaign ran once from [campaign-v2.sh](campaign-v2.sh) under a supervisor, with a guard against reruns.
