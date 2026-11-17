# Linux producer latency, issue #1599

Collected via `gh api` REST at 2026-11-17T03:26:37.210776+00:00. Last 10 Promote runs and **20 successful completed PR linux_build jobs**, extending through 39 completed pull_request Selected checks workflows. Skipped and cancelled jobs are inventoried separately below. Medians use successful linux_build jobs only. Newest Promote workflow was still in progress at collection but its linux_build had completed successfully.

Step and job seconds come from REST timestamps; cache bytes, nested restore duration and slowest compiles come from raw job logs. Build summary compile durations are rounded by Zig, so use the REST compile step for wall time. Download means cache-hit message through completed receipt; extraction means tar invocation through restored-successfully. Cache restore includes both plus action overhead. Slowest compiles are individual nodes and can overlap; do not add their durations.

See `analysis.md` for the measured causes, snapshot accumulation mechanism, compiler-miss correlation and evidence limits.

## Group medians

| Group | Successful / sampled | Compiler hit / miss | Setup s | Build snapshot B | Restore s | Download s | Extract s | Compile s | Total job s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Promote | 10 / 10 | 9 / 1 | 106.0 | 2207118261.5 | 51.843 | 10.475 | 42.507 | 576.5 | 743.0 |
| PR | 20 / 39 | 13 / 7 | 237.5 | 5990708323.0 | 190.522 | 33.251 | 158.115 | 237.5 | 506.5 |

## Per-run evidence

| Group / run | UTC created | Build status | Setup s | Compiler | Build snapshot B | Restore s | Download / extract s | Compile s | Total job s | Slowest successful compiles (rounded) |
|---|---|---|---:|---|---:|---:|---:|---:|---:|---|
| Promote [44003556067](https://github.com/DivyanshGolyan/rui/actions/runs/44003556067) | 2026-11-17T02:30:59Z | success | 297.0 | miss | 6612528053 | 251.287 | 39.138 / 211.8 | 867.0 | 1179.0 | rui-upgrade-release-fixture 6m (4G); rui-release-safe-check 4m (4G); rui-release-small-check 3m (2G); rui-debug-check 1m (2G); translate-c 1m (1G) |
| Promote [43885198710](https://github.com/DivyanshGolyan/rui/actions/runs/43885198710) | 2026-11-16T14:23:24Z | success | 170.0 | hit | 4565375417 | 133.86 | 17.801 / 115.867 | 509.0 | 692.0 | rui-upgrade-release-fixture 5m (4G); rui-release-safe-check 4m (4G); rui-release-small-check 3m (2G); rui-debug-check 2m (1G); codex-credential-actor 16s (456M) |
| Promote [43819213128](https://github.com/DivyanshGolyan/rui/actions/runs/43819213128) | 2026-11-16T06:47:35Z | success | 143.0 | hit | 3277709897 | 109.281 | 13.242 / 95.717 | 556.0 | 713.0 | rui-upgrade-release-fixture 5m (4G); rui-release-safe-check 4m (4G); rui-debug-check 2m (1G); rui-release-small-check 2m (2G); codex-credential-actor 18s (393M) |
| Promote [43815243585](https://github.com/DivyanshGolyan/rui/actions/runs/43815243585) | 2026-11-16T06:13:02Z | success | 144.0 | hit | 3166137375 | 107.939 | 33.291 / 74.247 | 542.0 | 738.0 | rui-upgrade-release-fixture 4m (4G); rui-release-safe-check 3m (4G); rui-release-small-check 2m (2G); rui-debug-check 1m (1G); rui-qualification-sqlite3 16s (244M) |
| Promote [43732653500](https://github.com/DivyanshGolyan/rui/actions/runs/43732653500) | 2026-11-15T15:56:32Z | success | 86.0 | hit | 2481608808 | 54.774 | 21.901 / 31.106 | 851.0 | 952.0 | rui-upgrade-release-fixture 7m (4G); rui-release-safe-check 6m (4G); rui-release-small-check 3m (2G); rui-debug-check 2m (1G); rui-qualification-sqlite3 24s (256M) |
| Promote [43701103697](https://github.com/DivyanshGolyan/rui/actions/runs/43701103697) | 2026-11-15T09:49:41Z | success | 72.0 | hit | 1932627715 | 48.609 | 5.761 / 42.616 | 420.0 | 521.0 | rui-upgrade-release-fixture 5m (4G); rui-release-safe-check 4m (4G); rui-release-small-check 3m (2G); rui-debug-check 1m (1G) |
| Promote [43694861963](https://github.com/DivyanshGolyan/rui/actions/runs/43694861963) | 2026-11-15T08:30:56Z | success | 69.0 | hit | 1687520075 | 41.846 | 5.312 / 36.288 | 767.0 | 864.0 | rui-upgrade-release-fixture 4m (4G); rui-release-safe-check 3m (4G); rui-release-small-check 2m (2G); rui-debug-check 1m (1G); rui-qualification-sqlite3 13s (258M) |
| Promote [43550488963](https://github.com/DivyanshGolyan/rui/actions/runs/43550488963) | 2026-11-14T03:13:24Z | success | 126.0 | hit | 878292070 | 26.078 | 7.708 / 17.86 | 597.0 | 748.0 | rui-upgrade-release-fixture 5m (4G); rui-release-safe-check 4m (4G); rui-release-small-check 3m (2G); rui-debug-check 2m (1G); translate-c 1m (1G) |
| Promote [43515431209](https://github.com/DivyanshGolyan/rui/actions/runs/43515431209) | 2026-11-13T21:59:10Z | success | 31.0 | hit | 527390023 | 11.104 | 2.346 / 8.23 | 722.0 | 764.0 | rui-upgrade-release-fixture 5m (3G); rui-release-safe-check 4m (4G); rui-release-small-check 3m (2G); rui-debug-check 2m (1G); translate-c 1m (1G) |
| Promote [43476158826](https://github.com/DivyanshGolyan/rui/actions/runs/43476158826) | 2026-11-13T17:46:47Z | success | 74.0 | hit | 1631733774 | 48.913 | 6.185 / 42.397 | 388.0 | 475.0 | rui-upgrade-release-fixture 4m (4G); rui-qualification-sqlite3 14s (249M); codex-credential-actor 12s (400M) |
| PR [44006777354](https://github.com/DivyanshGolyan/rui/actions/runs/44006777354) | 2026-11-17T02:58:05Z | success | 300.0 | hit | 6612528053 | 254.89 | 77.247 / 177.216 | 217.0 | 537.0 | rui-pr-check 3m (2G); rui-debug-check 2m (2G); rui-upgrade-release-fixture 2m (1G); codex-credential-actor 28s (389M); rui-qualification-sqlite3 21s (267M) |
| PR [44005169760](https://github.com/DivyanshGolyan/rui/actions/runs/44005169760) | 2026-11-17T02:44:23Z | success | 195.0 | hit | 6612528053 | 155.427 | 35.923 / 119.108 | 408.0 | 617.0 | rui-pr-check 4m (1G); rui-upgrade-release-fixture 4m (1G); rui-debug-check 3m (2G); rui-qualification-sqlite3 45s (235M); codex-credential-actor 22s (394M) |
| PR [44004931789](https://github.com/DivyanshGolyan/rui/actions/runs/44004931789) | 2026-11-17T02:42:21Z | success | 328.0 | hit | 6612528053 | 299.945 | 79.637 / 219.845 | 226.0 | 570.0 | rui-pr-check 3m (2G); rui-upgrade-release-fixture 3m (1G); rui-debug-check 2m (2G); rui-terminal-notice-test 2s (197M) |
| PR [44003414993](https://github.com/DivyanshGolyan/rui/actions/runs/44003414993) | 2026-11-17T02:29:56Z | success | 206.0 | miss | 6612528053 | 171.891 | 54.534 / 116.889 | 325.0 | 546.0 | rui-pr-check 5m (2G); rui-debug-check 4m (2G); rui-upgrade-release-fixture 4m (1G); rui-terminal-notice-test 2s (197M) |
| PR [44001992140](https://github.com/DivyanshGolyan/rui/actions/runs/44001992140) | 2026-11-17T02:18:24Z | success | 219.0 | miss | 6612528053 | 174.231 | 57.507 / 116.247 | 367.0 | 602.0 | rui-pr-check 5m (2G); rui-upgrade-release-fixture 5m (1G); rui-debug-check 4m (2G); codex-credential-actor 1m (412M); rui-qualification-sqlite3 1m (242M) |
| PR [43996737793](https://github.com/DivyanshGolyan/rui/actions/runs/43996737793) | 2026-11-17T01:35:30Z | success | 312.0 | hit | 6228731156 | 270.985 | 36.042 / 234.633 | 386.0 | 712.0 | rui-upgrade-release-fixture 4m (1G); rui-debug-check 3m (2G); rui-pr-check 3m (2G); rui-qualification-sqlite3 38s (253M); codex-credential-actor 32s (401M) |
| PR [43996662477](https://github.com/DivyanshGolyan/rui/actions/runs/43996662477) | 2026-11-17T01:34:56Z | success | 278.0 | hit | 6228731156 | 233.882 | 70.224 / 163.229 | 208.0 | 508.0 | rui-pr-check 3m (2G); rui-upgrade-release-fixture 3m (1G); rui-debug-check 2m (2G); rui-qualification-sqlite3 35s (247M); rui-activity-client-test 2s (183M) |
| PR [43994376205](https://github.com/DivyanshGolyan/rui/actions/runs/43994376205) | 2026-11-17T01:17:01Z | success | 233.0 | hit | 6228731156 | 197.456 | 33.669 / 163.583 | 205.0 | 452.0 | rui-debug-check 2m (2G); rui-pr-check 2m (2G); rui-upgrade-release-fixture 2m (1G); codex-credential-actor 23s (398M); rui-host-status-test 2s (170M) |
| PR [43991786572](https://github.com/DivyanshGolyan/rui/actions/runs/43991786572) | 2026-11-17T00:57:27Z | success | 259.0 | hit | 6228731156 | 229.71 | 32.832 / 196.534 | 168.0 | 437.0 | rui-pr-check 2m (2G); rui-debug-check 1m (2G); codex-credential-actor 29s (384M); rui-terminal-notice-test 3s (194M); rui-mysql-launch-admin 2s (259M) |
| PR [43987716698](https://github.com/DivyanshGolyan/rui/actions/runs/43987716698) | 2026-11-17T00:27:05Z | success | 261.0 | hit | 5990708323 | 221.584 | 64.697 / 156.447 | 224.0 | 505.0 | rui-pr-check 2m (2G); rui-upgrade-release-fixture 2m (1G); rui-debug-check 1m (2G); codex-credential-actor 28s (392M); rui-activity-client-test 2s (179M) |
| PR [43986685642](https://github.com/DivyanshGolyan/rui/actions/runs/43986685642) | 2026-11-17T00:19:26Z | success | 261.0 | hit | 5990708323 | 214.57 | 57.964 / 156.189 | 210.0 | 493.0 | rui-pr-check 2m (1G); rui-debug-check 2m (2G); rui-upgrade-release-fixture 2m (1G); rui-qualification-sqlite3 22s (242M); rui-terminal-notice-test 2s (199M) |
| PR [43986545897](https://github.com/DivyanshGolyan/rui/actions/runs/43986545897) | 2026-11-17T00:18:25Z | success | 221.0 | miss | 5990708323 | 183.589 | 23.584 / 159.784 | 195.0 | 431.0 | rui-debug-check 2m (2G); rui-pr-check 2m (2G); codex-credential-actor 15s (384M); rui-host-status-test 2s (171M); rui-activity-client-test 2s (179M) |
| PR [43985009032](https://github.com/DivyanshGolyan/rui/actions/runs/43985009032) | 2026-11-17T00:07:16Z | success | 220.0 | miss | 5990708323 | 183.067 | 22.859 / 159.994 | 167.0 | 402.0 | rui-debug-check 2m (2G); rui-pr-check 2m (2G); codex-credential-actor 24s (379M); rui-terminal-notice-test 3s (221M); rui-host-status-test 1s (172M) |
| PR [43984463902](https://github.com/DivyanshGolyan/rui/actions/runs/43984463902) | 2026-11-17T00:03:23Z | success | 161.0 | miss | 5990708323 | 128.566 | 24.473 / 103.8 | 330.0 | 501.0 | rui-pr-check 5m (2G); rui-debug-check 4m (2G); rui-upgrade-release-fixture 4m (1G); codex-credential-actor 52s (405M); rui-terminal-notice-test 7s (218M) |
| PR [43982596855](https://github.com/DivyanshGolyan/rui/actions/runs/43982596855) | 2026-11-16T23:49:42Z | success | 315.0 | hit | 5879140960 | 209.171 | 27.589 / 181.213 | 266.0 | 595.0 | rui-debug-check 2m (2G); rui-pr-check 2m (2G); rui-upgrade-release-fixture 2m (1G); translate-c 1m (1G); rui-qualification-sqlite3 23s (266M) |
| PR [43979557104](https://github.com/DivyanshGolyan/rui/actions/runs/43979557104) | 2026-11-16T23:28:19Z | success | 159.0 | hit | 5879140960 | 132.298 | 29.022 / 102.912 | 281.0 | 453.0 | rui-debug-check 3m (1G); rui-pr-check 3m (1G); codex-credential-actor 26s (388M); rui-terminal-notice-test 7s (203M); rui-host-status-test 3s (164M) |
| PR [43978752008](https://github.com/DivyanshGolyan/rui/actions/runs/43978752008) | 2026-11-16T23:22:41Z | success | 210.0 | hit | 5879140960 | 179.611 | 25.226 / 154.172 | 213.0 | 437.0 | rui-debug-check 2m (2G); rui-pr-check 2m (2G); rui-upgrade-release-fixture 2m (1G); codex-credential-actor 22s (411M) |
| PR [43977953996](https://github.com/DivyanshGolyan/rui/actions/runs/43977953996) | 2026-11-16T23:17:16Z | success | 242.0 | hit | 5759030541 | 202.314 | 24.891 / 177.044 | 249.0 | 504.0 | rui-pr-check 3m (2G); rui-upgrade-release-fixture 3m (1G); rui-debug-check 2m (2G); codex-credential-actor 24s (389M); rui-qualification-sqlite3 21s (235M) |
| PR [43973161947](https://github.com/DivyanshGolyan/rui/actions/runs/43973161947) | 2026-11-16T22:46:00Z | success | 247.0 | miss | 5759030541 | 126.035 | 29.734 / 95.907 | 319.0 | 578.0 | rui-pr-check 3m (1G); rui-debug-check 2m (1G); translate-c 1m (1G); codex-credential-actor 28s (384M); uucode_generate 6s (315M) |
| PR [43971821505](https://github.com/DivyanshGolyan/rui/actions/runs/43971821505) | 2026-11-16T22:37:20Z | success | 166.0 | miss | 5759030541 | 131.71 | 31.906 / 99.312 | 381.0 | 561.0 | rui-pr-check 4m (2G); rui-upgrade-release-fixture 4m (1G); rui-debug-check 3m (2G); codex-credential-actor 28s (403M); rui-terminal-notice-test 6s (194M) |

## Skipped and cancelled PR inventory

| Run | UTC created | Build status | Setup s | Compile s | Total job s |
|---|---|---|---:|---:|---:|
| [44008586139](https://github.com/DivyanshGolyan/rui/actions/runs/44008586139) | 2026-11-17T03:12:55Z | skipped | — | — | — |
| [43998957748](https://github.com/DivyanshGolyan/rui/actions/runs/43998957748) | 2026-11-17T01:53:33Z | skipped | — | — | — |
| [43998263648](https://github.com/DivyanshGolyan/rui/actions/runs/43998263648) | 2026-11-17T01:47:49Z | skipped | — | — | — |
| [43993652960](https://github.com/DivyanshGolyan/rui/actions/runs/43993652960) | 2026-11-17T01:11:34Z | skipped | — | — | — |
| [43992411477](https://github.com/DivyanshGolyan/rui/actions/runs/43992411477) | 2026-11-17T01:02:13Z | skipped | — | — | — |
| [43986691150](https://github.com/DivyanshGolyan/rui/actions/runs/43986691150) | 2026-11-17T00:19:29Z | skipped | — | — | — |
| [43986306051](https://github.com/DivyanshGolyan/rui/actions/runs/43986306051) | 2026-11-17T00:16:36Z | skipped | — | — | — |
| [43985726962](https://github.com/DivyanshGolyan/rui/actions/runs/43985726962) | 2026-11-17T00:12:24Z | skipped | — | — | — |
| [43985537073](https://github.com/DivyanshGolyan/rui/actions/runs/43985537073) | 2026-11-17T00:11:01Z | cancelled | 266.0 | 192.0 | 474.0 |
| [43985258685](https://github.com/DivyanshGolyan/rui/actions/runs/43985258685) | 2026-11-17T00:09:04Z | skipped | — | — | — |
| [43984828114](https://github.com/DivyanshGolyan/rui/actions/runs/43984828114) | 2026-11-17T00:05:58Z | skipped | — | — | — |
| [43984738938](https://github.com/DivyanshGolyan/rui/actions/runs/43984738938) | 2026-11-17T00:05:21Z | skipped | — | — | — |
| [43984358943](https://github.com/DivyanshGolyan/rui/actions/runs/43984358943) | 2026-11-17T00:02:38Z | skipped | — | — | — |
| [43984259395](https://github.com/DivyanshGolyan/rui/actions/runs/43984259395) | 2026-11-17T00:01:54Z | skipped | — | — | — |
| [43983850200](https://github.com/DivyanshGolyan/rui/actions/runs/43983850200) | 2026-11-16T23:59:00Z | skipped | — | — | — |
| [43982633948](https://github.com/DivyanshGolyan/rui/actions/runs/43982633948) | 2026-11-16T23:49:58Z | skipped | — | — | — |
| [43981661289](https://github.com/DivyanshGolyan/rui/actions/runs/43981661289) | 2026-11-16T23:43:00Z | skipped | — | — | — |
| [43981007452](https://github.com/DivyanshGolyan/rui/actions/runs/43981007452) | 2026-11-16T23:38:20Z | skipped | — | — | — |
| [43980955946](https://github.com/DivyanshGolyan/rui/actions/runs/43980955946) | 2026-11-16T23:37:57Z | skipped | — | — | — |

Initial last-20 completed PR sample extended by completed workflows observed in the last-100 REST response, ordered by created_at descending, until 20 successful linux_build jobs; a newly completed run 44006777354 joined during collection. Original initial sample is preserved separately.

## Diagnosis and first experiment

Promotion compilation accounts for a median 80.2% of job wall time. PR setup and compilation account for median per-job shares of 49.7% and 47.0%; component medians do not necessarily sum to the job median.
In the newest Promote, compiler installation after a miss cost 7.249 seconds. The 6.613 GB build archive took 39.138 seconds to download and 211.800 seconds to extract, correcting the brief's attribution of the latter to download.

Read from `.github/actions/setup/caches/action.yml`: source-specific keys restore the previous same-part snapshot, then save the complete local/global caches and package roots. Inference: successive saves retain old source artifacts alongside new ones. The measured growth from 1.688 GB on November 15 to 6.613 GB on November 17 supports accumulation, but does not identify entries safe to delete. No age-based or object-file pruning is justified without an unchanged warm-hit comparison and an edited-source comparison.
The compiler key is independent of dependency/source hashes and hit in 9/10 Promote and 13/20 PR builds. The newest Promote attempted to save it but lost a reservation race; later PRs hit it. The proxy refused both cache usage and inventory REST reads with HTTP 403, so eviction and the repository's effective quota remain unverified.

The first experiment extends the existing Linux x86_64 PR producer's `-j8` to LLVM producers. `-Dpr-ci` remains PR-only. Target selection, split parts, emitted artifacts, artifact verification and suite execution retain their existing owners.
Installed Zig 0.17.1 source explains the scheduling mechanism: `lib/compiler/Maker.zig` applies `-jN` to the async limit and submits build steps through `group.async`; `lib/std/Io/Threaded.zig` defaults the worker limit to CPU count minus one, executes work synchronously when busy, and blocks a worker during child-process waits. Eight slots can overlap independent work otherwise held behind these waits. This is a hypothesis requiring hosted timing, not a measured speedup.

The LLVM fixture and ReleaseSafe product each reported a rounded 4G MaxRSS, ReleaseSmall 2G, Debug 2G and translate-c 1G. These are individual peaks, not simultaneous memory measurements, and Zig floors the displayed units. More overlap needs a successful full LLVM build to establish feasibility; no memory-headroom claim follows from adding these rounded values.

The existing `check.yml` workflow dispatch can reproduce the newest Promote's Linux compile selection with base `c90bb4554d84b4ead8cc5f9a6b21f5b7533950d0`. Comparing `ci_plan.plan` with promotion true and false gives identical `linux_compile_targets` and `linux_split`; the dispatch retains LLVM because its event is not `pull_request`. This avoids adding a separate diagnostic build owner. Hosted before/after results belong in the PR Evidence once available. PR concurrency already uses eight slots, so it is a control rather than an expected scheduling speedup.

## Reproduction and provenance

For each run, retrieve `gh api repos/DivyanshGolyan/rui/actions/runs/RUN/jobs?per_page=100`, choose `linux_build` or `selected / linux_build`, then retrieve `gh api repos/DivyanshGolyan/rui/actions/jobs/JOB/logs`.
Subtract the REST step timestamps for setup and compile; parse the matching build-cache action's cache-hit, received-byte, tar and restored-successfully timestamps for archive size, download and extraction. Zig's summary supplies rounded node durations and RSS, not summed wall time.
Use `gh api 'repos/DivyanshGolyan/rui/actions/workflows/promote.yml/runs?per_page=10'` for the Promote sample. For PRs, paginate `check.yml` runs with `event=pull_request&status=completed`, retaining the first 20 successful Linux build jobs; retain skipped/cancelled jobs as inventory, outside timing medians.

The collection's raw logs, REST payloads, analysis scripts, structured metrics, skipped/cancelled inventory and SHA256SUMS are retained at `/mnt/project-files/ci-speed-1116/linux-build-1599-measurements/`. Six independent measurement-validation checks passed. These hosted baselines and source inspections are not evidence of the experiment's result.


## Part 2: snapshot contents and compiler disappearance

A Linux LLVM diagnostic on November 17, 2026, [run 44017555448](https://github.com/DivyanshGolyan/rui/actions/runs/44017555448), restored a 6,695,209,472-byte compressed snapshot. Setup took 256 seconds, including 216.891 seconds for that restore: 32.093 seconds receiving and 184.557 seconds extracting. The compiler archive hit and restored in 1.507 seconds. The instrumented compile took 484 seconds and the producer job 757 seconds; `strace` overhead prevents treating this as an ordinary build comparison.

The restored four roots held 41,826,321,591 apparent bytes: local cache 41,320,346,503; global compiler cache 278,602,931; packages 180,916,197; screen packages 46,455,960. `du -a -b` suppresses repeated hardlinked entries, so these are inventory values, not allocated bytes or a full independent per-file logical sum.

| Restored understood CLI class | Directories | Apparent directory bytes | Manifest input references | Opened by measured producer |
|---|---:|---:|---:|---:|
| Debug | 48 | 13,385,947,737 | 0 | 0 |
| ReleaseSafe | 47 | 6,709,376,928 | 0 | 0 |
| ReleaseSmall | 47 | 1,331,659,816 | 0 | 0 |
| Upgrade fixture / PR check | 0 | 0 | 0 | 0 |
| Total | 142 | 21,426,984,481 | 0 | 0 |

All 142 directories were outputs of old complete manifests. Revision-specific generated options give historical CLI compilations distinct input manifests, so retaining every discovered manifest output retains those obsolete generations too. Compaction instead preserves all manifest **inputs**, the actual current installed CLI content and unknown output classes. Only complete recognized native CLI layouts with proven local owning manifests may expire; their manifests are invalidated first. This does not infer that every unopened directory is dead: the measured producer opened only 144/1,221 restored local output directories, and most unvisited classes remain untouched. In particular, 73 `test` output directories account for another 9,196,551,989 apparent bytes including companions, but three were used by the rest producer and this first sweep retains the entire class.

The compiler key and installation path are unchanged across hits and misses. In Promote 44003556067, unit producer [133773548353](https://github.com/DivyanshGolyan/rui/actions/runs/44003556067/job/133773548353) missed at 02:31:50 UTC and successfully recreated `rui-compiler-Linux-X64-0.17.1` at 02:32:45. The long producer's reservation collision at 02:51 followed that successful recreation; it did not cause the disappearance. Maintenance logs contain no compiler-sized scripted deletion in either investigated miss window. A preceding publisher replaced a 6,484,314,810-byte build snapshot with a 6,612,528,053-byte one. Their potential overlap alone totals 13,096,842,863 bytes, before other partitions/platforms. Capacity pressure is the leading inference, not a measured eviction event: cache inventory/usage access was refused, so actual quota, simultaneous persistence and external deletion remain unverified. The evidence does not justify an independent compiler-key change. The snapshot and retention fix addresses the shared pressure; new maintenance logging records key/version and retained group bytes for future attribution.

The raw compiler lifecycle, publisher and maintenance logs, source provenance and checksums are under `/mnt/project-files/ci-speed-1116/linux-build-1599-measurements/compiler-misses/`. The diagnostic artifact, manifests, trace, classified inventories and 30 passing consistency checks are under the sibling `cache-profile/` directory. These are measured diagnosis and source evidence. The 21.4 GB figure is **not yet** a compressed saving or a no-extra-compiles result.

The opt-in paired diagnostic begins after a successful ordinary LLVM producer. It checkpoints the main-only cache, protects its installed production CLIs (and the upgrade fixture when selected) and tests unchanged and fixed-source-edit producers in both LLVM and PR profiles. Each control/candidate arm restores the same manifests and mutable outputs, runs the existing inode restat and compares named compile/cache statuses plus verbose C/link commands. Existing executable trees stay in place with inode/metadata guards; an unexpected write fails the experiment. This bounds disk use while preserving evidence. The diagnostic also streams identical tar+zstd commands before and after compaction, recording compressed bytes and elapsed time without storing two multi-GB archives. Publication is disabled for diagnostics, including main dispatches.

Qualification remains pending until these actual paired builds and hosted byte measurements finish. This in-place comparison does not independently reproduce a second complete tar extraction or a fresh-inode checkout. Ordinary PR restore timing after compaction also requires a trusted main publication: branch and PR workflows restore main's caches and cannot publish the optimized snapshot themselves. Keep that distinction when adding the before/after setup and producer timing table.


### Fresh ordinary PR baseline before part 2 publication

The newest three successful ordinary PR producers after #1601, collected at 2026-11-17T07:45:45Z, show continued archive growth. All three compiler restores hit the same 86,862,966-byte archive; all build restores were prefix hits.

| Baseline | Setup s | Compile s | linux_build s | Build archive B | Restore / download / extract s |
|---|---:|---:|---:|---:|---:|
| PR [44034556280](https://github.com/DivyanshGolyan/rui/actions/runs/44034556280/job/133889572371), attempt 2 | 358 | 267 | 642 | 7,313,055,640 | 313.469 / 62.769 / 250.179 |
| PR [44033721963](https://github.com/DivyanshGolyan/rui/actions/runs/44033721963/job/133871683724) | 192 | 326 | 528 | 7,313,055,640 | 164.439 / 30.283 / 133.869 |
| PR [44025518071](https://github.com/DivyanshGolyan/rui/actions/runs/44025518071/job/133844918998) | 258 | 215 | 486 | 7,022,722,895 | 223.486 / 25.210 / 198.073 |
| Fresh three-job median | 258 | 267 | 528 | 7,313,055,640 | 223.486 / 30.283 / 198.073 |

Two observations are attempts from the same PR; workloads and runners differ, and two parent workflows failed outside these successful producers. This is an observational pre-compaction baseline, with no speedup inference. Full keys, target/part lists, REST timestamps, raw logs, 50 passing extraction/selection checks and checksums are retained under `/mnt/project-files/ci-speed-1116/linux-build-1599-measurements/part2-before/`.


### First main publication and qualification preflight

After #1618 auto-merged, [main run 44053736418, job 133937839403](https://github.com/DivyanshGolyan/rui/actions/runs/44053736418/job/133937839403) passed with setup 378 s, compile 326 s and job 856 s. It restored a 7,633,162,867-byte v2 archive, then saved a 7,716,570,173-byte v3 archive. Compaction **skipped** with `manifest has no final sentinel`: no bytes were removed and no reduction is established. The save took 129.188 s; restore took 334.051 s (118.503 s download, 215.136 s extraction). The compiler hit. This is a publication witness, not a compacted-cache result.

Pinned `std.Build.Cache.Manifest.checkLocked` treats a zero-byte h file as never finalized and returns an incomplete-manifest miss. `finalize` appends the final sentinel only when writing a complete manifest. The restored diagnostic inventory contains such ordinary zero-length placeholders. They must be preserved and checked for mutation, but cannot be decoded as complete artifact owners. In contrast, a one-byte NUL manifest is complete with zero inputs. Nonempty invalid manifests still block compaction. The corrected publication policy uses v4 with legacy restore fallback because the untrimmed v3 exact key is immutable.

The earlier [qualification dispatch 44050257637](https://github.com/DivyanshGolyan/rui/actions/runs/44050257637/job/133926218927) passed its 147-step initial LLVM producer (setup 333 s, traced compile 526 s), then failed checkpointing Ghostty's relative shared-library aliases. Its uploaded summary has zero comparison pairs: no audit, candidate compaction or parity build ran. Contained relative file aliases need identity/target guards and literal-link backup; escaping, broken, cyclic, absolute and directory aliases remain unsupported. The follow-up prints full errors and pair differences in the job log. Neither preflight failure demonstrates additional compilation from a compacted snapshot; real paired reuse and size qualification remains required.
