# Bash `-c` launch A/B, 22 Oct 2026

**Status: measured Linux A/B, 36 of 36 attempts accepted** ([attempts.tsv](attempts.tsv); a one-line estimate preceded each run, [napkins.tsv](napkins.tsv)). Research and limits are in [FINDINGS.md](FINDINGS.md). Every number is measured unless labelled estimated.

## Identities

| Role | Identity |
| --- | --- |
| Baseline Rui | origin/main `671c3c7d` (`src` tree `b3af9ef9`, unchanged at main `4f478c32`), ReleaseFast, binary SHA-256 `d1a4b966…0f39` ([build-base.log](build-base.log)) |
| Candidate Rui | `bash -c` change, `src` tree `f558b33f`, ReleaseFast, binary SHA-256 `34b6e066…3e15` ([build-cand.log](build-cand.log)) |
| Harness | `tests/qualification/model-output` at `44319070` (tree `c6ab109b`): the existing tool-turn harness, adapted only as described below; executable SHA-256 `193ca229…a3a7` |
| Machine | one 2-vCPU Linux 6.1 orb, GNU bash **5.2.15** (CI's ubuntu-24.04 ships 5.2.21; macOS ships 3.2.57, which optimizes only a lone simple command) |

Both arms ran the same harness binary and the same command strings; only the Rui binary differed. Arms alternated per configuration (base first in repeats 1 and 3, candidate first in repeat 2). Each run: fresh Host, active capacity 100, 409,600 B seeded history per Session (≈102,400 tokens **estimated** by bytes/4), one real coordinator `rui session resume` TUI, N−1 `rui session send` calls launched by coordinator Bash calls, N workload calls, start barrier, 25 ms active sampling.

## Harness adaptation (`44319070`)

- **The pitfall:** `timed()` printed an end marker and `exit $status` after the workload. Bash had to stay resident to run them, so neither arm could exec the workload in place. The marker is gone; each command is now `printf start …; <workload>` (after the barrier `read`), so the workload is Bash's final simple command. No EXIT trap, no explicit `exec`. Test `TestWorkloadIsExecutedInPlaceByBash` runs the real command with `cat /proc/self/stat` and requires the test process as `cat`'s parent, with and without the barrier; restoring the old suffix fails it.
- **Acceptance:** a call succeeds only with `Bash succeeded. Exit code: 0.`, exactly one start marker, no end marker and, for barrier workloads, one park marker not after start. Barrier runs still need all N parked at release and N overlapping intervals.
- **Overlap without end markers:** each call is known alive over [park, start + minimum], minimum 5 s for `sleep 5` (it cannot finish sooner) and 0 for `cat`. For `cat` the guaranteed overlap is the release instant, when all N shells are parked. Post-release `cat` overlap is observed only by sampling. The barrier is artificial synchronization.
- **Classification:** a Host child whose shell execed its command is `bash_exec` (Bash column); a Host child `rui session send` is `send` (clients); an exited, unreaped process is `unreaped`, counted but never PSS-read. Each identity (PID + start time) records its comm/category transitions.

## Results (median of 3)

Bash column = shells, their children and Host children that replaced their shell. "Post-release" is the Bash column's highest sample beginning at or after the barrier release; "active" includes the parked phase, when both arms hold N identical parked shells. Peaks are highest observed sequential-scan sums, not true peaks.

| Workload, N | Bash post-release, base → cand | Bash active, base → cand | Total peak sample | Host CPU in turn | Reaped descendants CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| sleep 5, 1 | 0.97 → **0.20 MB** | 0.97 → 0.20 MB | 18.5 → 17.9 MB | 0.39 → 0.38 s | 0 → 0 s |
| sleep 5, 10 | 5.37 → **1.45 MB** | 5.37 → 3.75 MB | 23.5 → 21.7 MB | 1.83 → 1.73 s | 0.06 → 0.05 s |
| sleep 5, 100 | 39.63 → **11.09 MB** | 39.63 → 29.34 MB | 57.9 → 47.4 MB | 10.10 → 10.06 s | 0.80 → 0.71 s |
| cat 100 KiB, 1 | 1.03 → 0.30 MB | 1.03 → 0.30 MB | 18.5 → 17.8 MB | 0.09 → 0.09 s | 0 → 0 s |
| cat 100 KiB, 10 | 0 → 0 MB (missed) | 4.03 → 3.70 MB | 22.0 → 21.7 MB | 0.65 → 0.61 s | 0.06 → 0.06 s |
| cat 100 KiB, 100 | 28.81 → 20.70 MB | 29.31 → 29.34 MB | 47.4 → 47.4 MB | 9.77 → 9.70 s | 0.81 → 0.71 s |

Per-repeat values are in [summary.json](summary.json) (`medians[].values`). sleep N=100 post-release: base 39.66/39.58/39.63, candidate 12.41/11.09/11.08 MB. Host CPU sleep N=100: base 9.74/10.10/10.15, candidate 10.13/10.01/10.06 s.

- **Process transitions (sleep N=100, r1):** baseline: 100 identities `bash/bash_shell` with 100 separate `sleep/bash_child`, post-release max 100 shells + 100 children. Candidate: 100 identities `bash/bash_shell > sleep/bash_exec > sleep/unreaped` (same PID and start time), post-release max 0 children, 100 `bash_exec`, at most 7 shells not yet execed. Dispatch shells become `rui session send` in place (`bash/bash_shell > rui/send`).
- **Napkins:** base sleep N=100 estimated ~40 MB, measured 39.63; candidate post-release estimated 12–17 MB, measured 11.09. Host CPU estimated unchanged; measured within ±6% at every N, inside run-to-run spread.
- **Reference only:** the user's experiment (bash 5.2.21, 100 × `sleep 3`, summed PSS) saw 50.5 → 13.0 MB; this harness sees 39.6 → 11.1 MB for 100 × `sleep 5` in the same direction and ratio.
- `cat` lives milliseconds, so 25 ms sampling mostly misses it after release (workload-process PSS reads at N=100: 16–19 of 100). Its post-release numbers are coverage-limited; the parked phase dominates its active peak in both arms.
- Clients peak rose 7.75 → 8.41 MB (sleep N=100): more `rui session send` processes were observed alive per sample (send identities read 30 → 57 of 99, r1). Each is ~0.9 MB; the cause is not attributed.

## Limits

- One orb, three repeats, Bash 5.2.15. Peaks are sequential-scan sums over ~6–11 ms per peak sample, 0 failed PSS reads in the median peak samples; short-lived processes are under-sampled.
- Concurrency is barrier-synchronized; overlap is a lower bound from start markers and `sleep`'s minimum.
- Host CPU uses 10 ms ticks and includes TUI submit, 2N history-sized model requests, Store commits, barrier wait and a 3 s tail.
- Raw per-run artifacts exclude each Store and the seed request records (their SHA-256s are in `runs/*-records-sha256.txt`).

## Records

`runs/<label>.json.gz` (final JSON), `runs/<label>-artifacts.tar.gz` (tree samples, provider facts, Host stderr, TUI transcript, barrier and dispatch files), `runs/<label>.stdout.gz`. [reduce.py](reduce.py) (adapted from `.amp/tool-turn-v2/reduce.py`) produced [summary.json](summary.json). [campaign.sh](campaign.sh) ran once under a supervised service with a rerun guard. `smoke/` holds three pre-campaign smoke runs; the first used a harness build before the `unreaped` classification.
