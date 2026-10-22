# SQLite v2 lane measurement notes (Linux fixture)

Orb: independent 2-vCPU Linux orb, thread T-01a161ce-8357-7340-a91c-c92bc0ff2267.
Baseline product: d4f870002b1eeef370fb8f4c7aa3fd8b14343159 (origin/main at start, 2026-10-22).
Harness: the same exported baseline tree's `tests/qualification` (`model-output`, plus the retained
P2 temporary `p2_postfix_hold_test.go.txt` from perf/linux-attribution c95185dc) for both baseline
and candidate. Launchers mirror P2's `rui-strace` (Host-only `strace -D -f -c`, P2_DIAGNOSTICS=0)
and SQL counting uses P2's retained `postfix-sql-instrumentation.patch` applied to each export.

## Estimates recorded before any run (napkin, from the coordinator brief and source)

- fsyncs per Message, STREAM100 (`model-output --capacity 100`, 200 Messages):
  baseline ≈ 24 (P2 measured 24.06 on 240aef2e; journal_mode=DELETE + synchronous=EXTRA).
  Candidate ≈ 4–5 (WAL + synchronous=FULL: one WAL sync per commit, ≈3–4 commits per Message,
  plus occasional checkpoint syncs and non-SQLite capture/directory syncs).
- HOLD100 idle SELECT/s: baseline ≈ 1,006/s (P2 measured 1,006.1999/s on d4f87000).
  Candidate ≈ 60/s or less (control reconciliation and per-turn uncertain-Action scans skip on an
  unchanged commit generation; ≈1/s retry scan remains).
- Host CPU per event, STREAM100 complete work, uninstrumented: baseline ≈ 77 µs/event
  (P1 measured 77.09 on 12f84075 in another orb; only same-orb pairs compare). Candidate: a small
  reduction, ≈1–5%, because curl/OpenSSL dominate and fsync wait is not CPU.

## Attempts

All attempts, including failures, are listed in attempts.md in order.

## Measured results (same orb, same harness binaries; counts and CPU kept separate)

Identities: baseline Rui 83529d64256ee173… (d4f87000), candidate Rui 04c8bc908c79aade… (26857f7c,
branch wip/sqlite-v2-measured-26857f7c), SQL-instrumented baseline d9de069af29f280f…, candidate
995a3f3b05feb121…, model-output harness a04c1e4f39109a6f…, hold-test 2f4502f296a3e9e1…, strace
launcher 4f22801398f7cb7e…. Full hashes are in raw/*/identity.sha256.

Instrumented counts (strace -c or SQL trace; never used as CPU or time):
- STREAM100 fsync (200 Messages): baseline 4,814 = 24.07/Message; candidate 1,643 = 8.22/Message.
  The napkin estimate was 4–5/Message; the measured count is higher. strace -c counts every Host
  fsync (scratch capture seals, directory syncs and WAL), and this run does not attribute them.
- HOLD100 held window (60.008 s): baseline 60,067 SELECT = 1,000.98/s; candidate 59 = 0.98/s
  (the retry scan only). The napkin estimate was ≤60/s.
- STREAM100 SQL statements (first executions): baseline 259,207 (SELECT 251,735, BEGIN 1,410,
  ROLLBACK 609); candidate 26,638 (SELECT 20,381, BEGIN 801, ROLLBACK 0). cand1 (a8994b74, no
  statement cache) had 25,325; the cache does not change execution counts.

Uninstrumented Host CPU, STREAM100, order A B B A A B, actual binaries passed directly,
LD_PRELOAD unset (all six: 200 Messages, 1,200,000 events, all results audited, harness verdict
"incomplete" only for the missing macOS footprint):
- baseline: 36.12, 34.63, 36.47 µs/event (mean 35.74)
- candidate: 27.62, 27.84, 29.07 µs/event (mean 28.18)
- candidate − baseline: −7.56 µs/event (−21.2%); the ranges do not overlap. The napkin estimate
  was a 1–5% reduction. Linux fixture diagnostic only; not a macOS or qualification verdict.

## Bash same-group timeout failure: causal control (2026-10-22)

The fresh Linux run on tree 965fe8a5 (100 ms fixture) failed in bash-integration with "timed out
waiting for same-group child identity". Evidence: raw/fresh-run-1-failed. The run with the fixture
timeout at 1000 ms (tree f75f592a) is diagnostic history only: raw/fresh-run-2-1s-diagnostic.

Control: control/same_group_control.py runs the exact fixture command with timeout_ms=100, plus
$EPOCHREALTIME markers, on one Host per block. Timing comes from the Host's bash_deadline_* trace
(spawn = deadline − 100 ms). Blocks are 30 trials each, ordered B C C B under each load. Loads:
none, CPU (4 busy loops on 2 vCPU), and fsync (2 writers doing fsync in a loop). Binaries are the
same measured baseline (d4f87000) and candidate (26857f7c), which have identical Bash owners.
Failed and aborted blocks are kept in raw/control and listed in attempts.md.

PID unpublished when the 100 ms kill landed:
- no load: baseline 0/60, candidate 0/60
- CPU load: baseline 8/60 (13%), candidate 11/60 (18%)
- fsync load: baseline 0/60, candidate 1/60
Spawn→publish median, baseline vs candidate: 5.2 vs 9.2 ms (no load), 48.2 vs 63.6 ms (CPU),
31.7 vs 27.9 ms (fsync).

Conclusion: under matched CPU load the pre-WAL baseline fails the same way, so the 100 ms fixture
race exists independently of WAL/FULL. The control does not rule out a small candidate contribution:
under CPU load the candidate's failure rate and publish median are somewhat higher. That difference
is within block-to-block variation (no-load baseline block medians were 9.4 and 4.1 ms), and it is
not resolved.
