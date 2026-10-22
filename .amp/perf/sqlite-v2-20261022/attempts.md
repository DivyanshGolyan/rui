# Attempts (UTC)

- 2026-10-22 baseline ReleaseFast build of d4f87000 export: EXIT=0 (log raw/build-baseline.log retains a transient "failed command" line for the pinned transport step; the step was then reused and the build completed).
- baseline SQL-instrumented build (P2 postfix patch): EXIT=0 (raw/build-baseline-sql.log)
- 2026-10-22T04:32:26Z baseline stream100-strace start
- 2026-10-22T04:35:24Z baseline stream100-strace exit=1
- 2026-10-22T04:35:24Z baseline hold100-sql start
- 2026-10-22T04:36:30Z note: baseline stream100-strace JSON status=failed with error 'open .amp/sqlv2/tests/qualification/go.sum' (harness resolves its source from the binary path); counts complete (200 Messages, 1.2M events). Added symlink .amp/sqlv2/tests -> baseline-source/tests for later runs.
- 2026-10-22T04:36:37Z baseline hold100-sql exit=0
- 2026-10-22T04:36:37Z baseline stream100-sql start
- 2026-10-22T04:38:53Z baseline stream100-sql exit=1
- 2026-10-22T05:17:20Z candidate-1 (a8994b74, no statement cache) SQL-instrumented build start
- 2026-10-22T05:27:52Z candidate-1 SQL build EXIT=0 (raw/build-cand1-sql.log)
- 2026-10-22T05:27:52Z cand1 hold100-sql start
- 2026-10-22T05:29:04Z cand1 hold100-sql exit=0
- 2026-10-22T05:29:04Z cand1 stream100-sql start
- 2026-10-22T05:31:14Z cand1 stream100-sql exit=1
- 2026-10-22T06:27:40Z candidate-2 (26857f7c) cand2-source ReleaseFast build start
- 2026-10-22T06:41:45Z candidate-2 cand2-source build EXIT=0 (raw/build-cand2-source.log)
- 2026-10-22T06:41:45Z candidate-2 (26857f7c) cand2-sql-source ReleaseFast build start
- 2026-10-22T06:51:08Z candidate-2 cand2-sql-source build EXIT=0 (raw/build-cand2-sql-source.log)
- 2026-10-22T06:52:28Z cand2 stream100-strace start
- 2026-10-22T06:55:41Z cand2 stream100-strace exit=1
- 2026-10-22T06:55:41Z cand2 hold100-sql start
- 2026-10-22T06:56:57Z cand2 hold100-sql exit=0
- 2026-10-22T06:56:57Z cand2 stream100-sql start
- 2026-10-22T06:59:11Z cand2 stream100-sql exit=1
- 2026-10-22T06:59:39Z note: gzip -kn copy of raw/cand2/hold100/host-stderr.log for hold_sql_counts.py (same step as cand1)
- 2026-10-22T07:02:38Z note: copied cand2 STREAM100 host-stderr (gzip -n) from /tmp/rui-output-measure-138125833/capacity-100
- 2026-10-22T07:03:00Z CPU A/B estimate before runs: candidate Host CPU/event ~1-5% below baseline (napkin in NOTES.md; not a result)
- 2026-10-22T07:03:02Z cpu-ab run 1 baseline stream100 start
- 2026-10-22T07:05:25Z cpu-ab run 1 baseline stream100 exit=1
- 2026-10-22T07:05:25Z cpu-ab run 2 cand2 stream100 start
- 2026-10-22T07:07:38Z cpu-ab run 2 cand2 stream100 exit=1
- 2026-10-22T07:07:38Z cpu-ab run 3 cand2 stream100 start
- 2026-10-22T07:09:52Z cpu-ab run 3 cand2 stream100 exit=1
- 2026-10-22T07:09:52Z cpu-ab run 4 baseline stream100 start
- 2026-10-22T07:12:14Z cpu-ab run 4 baseline stream100 exit=1
- 2026-10-22T07:12:14Z cpu-ab run 5 baseline stream100 start
- 2026-10-22T07:14:34Z cpu-ab run 5 baseline stream100 exit=1
- 2026-10-22T07:14:34Z cpu-ab run 6 cand2 stream100 start
- 2026-10-22T07:16:47Z cpu-ab run 6 cand2 stream100 exit=1
- 2026-10-22T07:18:42Z cpu-ab reduced with the P2 jq-equivalent fields (complete_work_cpu_seconds / completed_events)
- 2026-10-22T07:33:36Z fresh run 1 on tree 965fe8a5: check EXIT=1 (bash failed: 'timed out waiting for same-group child identity'; 22/23 other check legs passed); evidence raw/fresh-run-1-failed. Retained as failed history.
- 2026-10-22T07:35Z bash failure attribution (fresh run 1): the retained Store shows the same-group Action
  resolved timed_out at attempt 1 (product timeout fired). Neither same-group-pid nor same-group-pid.tmp
  exists, so the 100 ms deadline killed the script before its first publish_pid printf. The Bash timer
  starts at spawn (src/bash.zig:245–267), before any script line runs. This lane changes 0 lines in
  src/bash.zig, BashLifecycle.zig or bash_platform.c. The same assertion passed in both earlier full
  check runs on the same Bash source (26857f7c). Change: fixture timeout_ms 100→1000 (child sleeps 30 s
  and ignores TERM). The timed_out, KILL-escalation and continuation assertions are unchanged; no
  assertion reads the 100 ms value. A repeat of the failed run was not used as a pass. The full repaired
  Linux set reruns on tree f75f592a.
- 2026-10-22T07:39:20Z fresh run 2 on tree f75f592a (1000 ms fixture variant): bash, check 23/23, admission-debug, dispatch-debug, codex-credential, codex-h2, current-facts EXIT=0; stopped at server-delivery per the user's causal condition. Diagnostic only. Landable fixture restored to 100 ms.
- 2026-10-22T07:42:55Z causal control smoke (cand2, 3 trials, no load): spawn->start ~2 ms, spawn->PID published ~4 ms, deadline serviced ~101-103 ms; raw/control/smoke-cand2.json
- 2026-10-22T07:42:56Z control none block 1 baseline start
- 2026-10-22T07:43:16Z control none block 1 baseline exit=0
- 2026-10-22T07:43:17Z control none block 2 cand2 start
- 2026-10-22T07:43:35Z control none block 2 cand2 exit=0
- 2026-10-22T07:43:36Z control none block 3 cand2 start
- 2026-10-22T07:43:54Z control none block 3 cand2 exit=0
- 2026-10-22T07:43:55Z control none block 4 baseline start
- 2026-10-22T07:44:13Z control none block 4 baseline exit=0
- 2026-10-22T07:44:14Z control cpu block 1 baseline start
- 2026-10-22T07:44:39Z control cpu block 1 baseline exit=1
- 2026-10-22T07:46:17Z control cpu block 1 baseline FAILED in reduction: KeyError for action 29's bash_deadline_established trace record (phase trace is lossy under load); no output written. Runner stopped; script now records missing trace as null; cpu and fsync loads rerun. 'none' blocks 1-4 kept.
- 2026-10-22T07:47:31Z control cpu block 1 baseline start
- 2026-10-22T07:47:58Z control cpu block 1 baseline exit=0
- 2026-10-22T07:52:57Z control cpu block 2 cand2 start
- 2026-10-22T07:53:23Z control cpu block 2 cand2 exit=0
- 2026-10-22T07:54:50Z runner bug: 'jobs -p | xargs kill' in sh pipeline killed nothing, so 'wait' hung after cpu block 1 (load stayed on through block 1, so its data is valid; 5-min gap until manual kill). cpu block 2 aborted at start (raw/control/cpu-2-cand2-ABORTED.log). Runner fixed to track load PIDs; cpu+fsync rerun from block 1.
- 2026-10-22T07:55:00Z control cpu block 1 baseline start
- 2026-10-22T07:55:24Z control cpu block 1 baseline exit=0
- 2026-10-22T07:55:25Z control cpu block 2 cand2 start
- 2026-10-22T07:55:56Z control cpu block 2 cand2 exit=0
- 2026-10-22T07:55:57Z control cpu block 3 cand2 start
- 2026-10-22T07:56:28Z control cpu block 3 cand2 exit=1
- 2026-10-22T07:56:29Z control cpu block 4 baseline start
- 2026-10-22T07:56:57Z control cpu block 4 baseline exit=0
- 2026-10-22T07:56:58Z control fsync block 1 baseline start
- 2026-10-22T07:57:20Z control fsync block 1 baseline exit=0
- 2026-10-22T07:57:21Z control fsync block 2 cand2 start
- 2026-10-22T07:57:44Z control fsync block 2 cand2 exit=0
- 2026-10-22T07:57:45Z control fsync block 3 cand2 start
- 2026-10-22T07:58:08Z control fsync block 3 cand2 exit=0
- 2026-10-22T07:58:09Z control fsync block 4 baseline start
- 2026-10-22T07:58:32Z control fsync block 4 baseline exit=0
- 2026-10-22T07:59:20Z control cpu block 3 cand2 FAILED in reduction: empty marker file (shell killed mid-printf), ValueError; reducer now treats empty marker as unpublished; rerunning one cpu cand2 block as cpu-5-cand2
- 2026-10-22T07:59:21Z control cpu block 5 cand2 start
- 2026-10-22T07:59:50Z control cpu block 5 cand2 exit=0
