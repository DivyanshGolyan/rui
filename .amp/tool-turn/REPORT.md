# Coordinated Bash tool turns at ~100k-token history, Linux fixture, 22 Oct 2026

**Status: partial measured campaign; it does not satisfy the requested concurrency or peak coverage.** sleep N=100 reaches 96–99 calls in flight, read N=100 only 1–2, and 200 ms sampling misses almost every send and `cat` lifetime (see Open gaps). Linux only, fixture only, no live model, no Mac. Every number is **measured** unless labelled **estimated**. Source: origin/main = stable [`d4f87000`](https://github.com/DivyanshGolyan/rui/commit/d4f870002b1eeef370fb8f4c7aa3fd8b14343159), ReleaseFast (`zig build -Doptimize=ReleaseFast`, 42 steps, exit 0, [build log](build-releasefast.log); the log's "failed command" line is the transport step's progress echo, not a failure). Binary SHA-256 `993c3eb1a70d2c75d785ce91d032d7aee8f098358942777705ddfc22483954f2`. Harness: `tests/qualification/model-output --tool-sessions N --tool-workload sleep|read` on `perf/tool-turn-20261022` [`95da4883`](https://github.com/DivyanshGolyan/rui/commit/95da4883) (the campaign executable was built from this exact tree before it was committed, so Go stamped it `vcs.revision=d4f87000 vcs.modified=true`; each run JSON's recorded source hashes match `95da4883` for all five harness files; executable SHA-256 `d2065d2f…5a74` in [identities.txt](identities.txt)). 2-vCPU Linux 6.1 orb, 3 GB RAM, fd soft limit 1,024, Host active capacity 100 (product default).

## Scenario

```
TUI (rui session resume, real PTY) ──submit──▶ coordinator Session
coordinator response: N−1 Bash calls `rui session send --session worker-i` + 1 workload call
each worker turn:     1 workload call            workload = `sleep 5` | `cat` of a 100 KiB file
```

- **History:** before the measured turn every Session receives one ordinary `rui session send --text` Message of 409,600 bytes (deterministic prose), answered without tools. **Estimated** ≈102,400 tokens per Session by bytes/4; no tokenizer ran. Measured request bodies at the tool turn: 417,533 B (N=1) to 418,141 B (N=100) median.
- **Clients:** exactly one interactive TUI, attached to the coordinator, which submits the request. Every `rui session send` is a real process launched by a coordinator Bash call. N=1 has no sends; the coordinator runs the workload itself.
- **Counts (all 18 timing runs, from provider facts):** N=1: 0 dispatch + 1 workload; N=10: 9 + 10; N=100: 99 + 100. Every call returned `Bash succeeded. Exit code: 0.`; 0 failed. 2N model requests per turn over one H2 connection.
- **Columns:** Host = Host PID. Bash = Host-child shells + their non-`rui` children + Host forks seen before exec. Clients = TUI + `rui` processes under a shell (sends), counted once as clients, never as Bash. Each PID+start-time is in exactly one category per sample. Controller and fixture are excluded.

## Results (median of 3 fresh Hosts; Linux PSS from `smaps_rollup`, 200 ms samples)

| Workload, N | Workload calls in flight (max overlap) | Host PSS idle → active peak | Bash peak | Clients peak (TUI; sends seen) | Total, peak sample | Host CPU in turn | Host CPU / workload call | / model request |
| --- | ---: | --- | ---: | --- | ---: | ---: | ---: | ---: |
| sleep 1 | 1 | 10.55 → 10.80 MB | 0.90 MB | 6.79 MB (TUI; no sends) | 18.38 MB | 0.36 s / 8.25 s | 360 ms | 180 ms |
| sleep 10 | 10, 10, 10 | 11.02 → 11.24 MB | 5.26 MB | 7.01 MB (0 sends seen) | 23.15 MB | 1.68 s / 8.71 s | 168 ms | 84 ms |
| sleep 100 | 99, 96, 96 | 11.12 → 11.62 MB | 37.36 MB | 7.69 MB (4–5 of 99 sends seen) | 55.42 MB | 9.61 s / 14.92 s | 96 ms | 48 ms |
| read 1 | 1 | 10.53 → 10.79 MB | 0.85 MB | 6.71 MB | 18.31 MB | 0.09 s / 3.26 s | 90 ms | 45 ms |
| read 10 | 1, 1, 1 | 11.06 → 11.30 MB | 0.27 MB | 6.88 MB (0–1 sends seen) | 18.19 MB | 0.43 s / 3.61 s | 43 ms | 21.5 ms |
| read 100 | 2, 1, 2 | 11.08 → 11.60 MB | 0.86 MB | 7.45 MB (3–5 sends seen) | 19.18 MB | 5.53 s / 10.13 s | 55 ms | 27.7 ms |

- **Steady state after the turn:** total 17.50–18.22 MB = Host 10.8–11.5 MB + TUI 6.71–6.73 MB; no Bash or send process remains. Host PSS barely depends on history: the idle Host with 100 × 400 KiB history is 11.12 MB versus 10.55 MB with one, so history is not held in memory.
- **Per process (median of each process's max sample):** workload shell 0.33 MB at N=100 and 0.46–0.70 MB at N≤10 (PSS spreads shared pages over more processes); `sleep` 0.12–0.20 MB; `cat` 0.29–0.30 MB when seen; `rui session send` 0.82–1.04 MB; TUI 6.7–7.9 MB.
- **Concurrency.** Measured from bash `$EPOCHREALTIME` builtins around each command. `sleep 5`: 10 of 10 and 96–99 of 100 overlap; 100 is not reached because the coordinator's own sleep starts and ends before the last worker's starts (shell-start delay after the tool-call response: median 10 ms, max 0.95–0.98 s at N=100). Dispatch sends run **2–3 at a time**, 6–8 ms each, so the coordinator's 99 sends are close to serial. `cat` takes 2–4 ms in the shell: **no realistic overlap** (1–2), so read N is Sessions, not concurrent reads.
- **CPU of descendants (reaped children ticks):** 0.72 s (N=100 sleep), 0.69–0.74 s (N=100 read) for all shells, workload children and sends together; they cannot be separated. TUI 0.14–0.15 s. Observer (sampler) 0.39–0.42 s at N=100, not subtracted.
- **Aggregate observation, not an attributed cost:** same N, sleep minus read Host CPU is +0.27 s (N=1), +1.24 s (N=10), +4.1 s (N=100) Host CPU. Over the 5 s sleep that is ≈5% of one core for one waiting shell and ≈80% for 100. The runs also differ in window length and output size, so this difference is not a measured per-shell cost. Polling by the Host's Bash service loop is an unprofiled **hypothesis**, not a proven cause.
- **Disk.** Seeding adds 409,600 B per Session to `rui.sqlite3` (41,164,800 B for 100). The tool turn adds 70 B (N=1 sleep), 50 KB (N=10 sleep), 0.72 MB (N=100 sleep: 0.67 MB SQLite + 54 KB scratch), 12.07 MB (N=100 read: 1.77 MB SQLite + 10.29 MB scratch). Full stdout/stderr stay in `store/scratch` after the turn (398 files at N=100), as the README's temporary-output design says.
- **Page cache** (system-wide `Cached`, not attributable, never added to PSS): +83 MB across seeding N=100 (includes the controller's 41 MB of seed files, since deleted, plus the Store); +2.3–15.7 MB across the N=100 turn. `fincore` after the turn shows the whole `rui.sqlite3` resident (42,135,552 of 42,135,552 B at N=100 sleep).

## Fork safety finding (src/bash.zig:133, for review; no launch change made)

- **`src/bash.zig:133` is test code.** It is the `fork()` inside the test "native Bash observation agrees with reap for wide process exit values", whose child only calls `_exit`. Production Bash launch is `Prepared.launch` → `std.process.spawn` (`src/bash.zig:246`) → Zig 0.17 `Io.Threaded.spawnPosix`, which calls glibc `fork()` on Linux (`posix_spawn` only on Darwin).
- **Child path, Rui's options** (`cwd=.path`, `stdin=.ignore`, `stdout/stderr=.pipe`, `pgid=0`, absolute `argv[0]`, prebuilt env): thread-local `cancel_protection = .blocked`; `chdir` (path copied to a stack buffer); `dup2` × 3; `setpgid(0,0)`; `execve`; on failure `write` to the CLOEXEC error pipe and `_exit(1)`. `Syscall.start`/`checkCancel` return early when protection is blocked, so no atomics or locks run. All allocation (argv, envp) happens before `fork`. Every syscall used is on the POSIX async-signal-safe list. The binary imports no `__register_atfork`/`pthread_atfork`, and pinned OpenSSL's fork hooks are empty. **Owner reading: async-signal-safe on the exercised path. Pending independent review.**
- **Residual issues found:** (1) **descriptor leak**: Zig's cached `/dev/null` (`getDevNullFd`) opens without `O_CLOEXEC`, so every Bash shell and its children inherit an extra fd 19 → `/dev/null` (observed, [fd-probe.txt](fd-probe.txt)). SQLite (`O_CLOEXEC`) and curl (`SOCK_CLOEXEC`) sockets are atomic and did not leak. (2) The child inherits the forking thread's signal mask and ignored dispositions; Host threads were observed with SigBlk 0 and SigIgn 0, so nothing leaks today, but nothing resets them.
- **posix_spawn:** simpler to audit (no Rui/Zig code runs in the child) and resets signals via `POSIX_SPAWN_SETSIGMASK/SETSIGDEF`. glibc 2.36 uses `CLONE_VM|CLONE_VFORK`, avoiding page-table copies, and reports exec errors directly; `addchdir_np`, `adddup2` and `POSIX_SPAWN_SETPGROUP` cover every current option. `src/host_launch.c` already uses `posix_spawn` on macOS. Cost: Rui would own its pipes and the `Child` handle instead of `std.process.spawn`. Fork is cheap at this Host size (below), so the case for switching is auditability and signal hygiene, not speed. The fd-19 inheritance and the signal-mask observations are owner findings pending independent review. No launch or fd fix is in this lane's scope.
- **Fork-to-exec (instrumented, strace -f attached to the Host, not comparable to timing runs):** Host fork → bash `execve` median 0.77 ms (min 0.23, max 4.6 ms; 199 forks at N=100 read), 0.80 ms at N=1. bash → `rui` send median 0.79–0.85 ms. strace stops every syscall of traced processes, so these are inflated upper-bound-style figures; untraced fork-to-exec is unavailable.

## Open gaps and smallest existing-harness options (not run)

| Gap | Option | Cost / ETA (**estimated**) | Caveat |
| --- | --- | --- | --- |
| Concurrent reads (read N=100 overlaps 1–2) | Read workload waits on a fixture-created start file (`until [ -e go ]; do sleep 0.01; done; cat …`), released after all N workload calls are in flight | ~30 min code+test, ~10 min for 3×3 runs | Synchronized start is artificial concurrency; it measures N parked shells plus N simultaneous reads, not a natural agent pattern |
| Same, natural | `rg` over the disposable clone instead of `cat` (warm ≈30–40 ms, cold 3 s measured once here) | ~15 min, ~10 min runs | Still short against a ≈1 s worker-start spread; expect overlap ≈3–5, not N |
| Send/`cat` peaks missed by 200 ms samples | Per-process peak at exit: wrap each dispatch/workload in `/usr/bin/time -f %M` (max RSS) | ~20 min, rerun 18 runs ~15 min | Max RSS, not PSS; changes the tool command slightly |
| Unobserved true tree peak | Start the Host in its own cgroup scope (`systemd-run --scope`, available here) and read `memory.peak` | ~30 min, rerun ~15 min | Charged anon+page cache, not PSS; not comparable to PSS columns |
| Higher sampling resolution | 20 ms interval in the active phase only | ~5 min, rerun ~15 min | ~10× sampler CPU on 2 vCPUs perturbs Host CPU; still misses sub-20 ms processes |

## Limits

- Processes shorter than one 200 ms sample are missed: 0–5 of 99 sends and most `cat`s were seen. Peaks are **observed sample peaks**, not true peaks. The sampler cost 0.39–0.42 CPU-s at N=100 and is not subtracted.
- The workload-call CPU denominators include setup inside the turn: TUI submit, 2N history-sized model requests, Store commits and the 3 s tail. "Per workload call" is total Host CPU / N, not marginal cost. "Including dispatch" divides by 2N−1.
- strace runs (sleep N=1/10/100, read N=100) distort concurrency (sleep N=100 overlap fell to 11) and CPU (38 s); they are used only for fork-to-exec.
- The token estimate is bytes/4. The prompt layout is fixture text, not a real transcript.
- Seed records (40 MB of request captures) are excluded from the evidence; their sizes and SHA-256s are in each run's `seed-records-sha256.txt`.

## Records

- 22 campaign attempts, all exit 0 ([attempts.tsv](attempts.tsv)), in a one-shot service guarded against reruns ([campaign.sh](campaign.sh)). A one-line estimate was written before each run ([napkins.tsv](napkins.tsv)) and saved in each run's `run-notes.txt`.
- Pre-campaign smoke runs on the same binary, used to write the estimates, are in `smoke/`. The first smoke attempt failed because it ran from the wrong directory (`open …/tests/qualification/go.sum: no such file`), and it is kept. Two later fd-probe runs passed.
- `runs/<label>.json.gz` is each final JSON; `runs/<label>-artifacts.tar.gz` holds the raw samples (`tree-samples.jsonl`), provider facts, Host stderr, TUI transcript and the strace output. [summary.json](summary.json) is produced by [reduce.py](reduce.py).
- Owner-verified only; no independent review yet.
