---
name: rui-ci-triage
description: Triage CI: find why a Rui run is red and whether the commit under test caused it. Use when Selected checks, pre-merge admission, Qualify main, Promote or Release fails, or a job stalls, times out or shows cancelled.
---

# rui-ci-triage

Name the failing fixture and assertion from the log, decide whether the commit under test caused it, and route the fix.
Rerun, retry and assertion rules live in [Landing](../../../docs/agents/landing.md#ci-failures) and [Evidence](../../../CODING_STANDARDS.md#evidence); this skill never relaxes them.

## 1. Find the failure record

- Fetch failed-job logs through the GitHub MCP: `get_job_logs` with `run_id` and `failed_only: true` (or one `job_id`) and `return_content: true`.
  Large logs land in a file; search the file.
  Fetch logs yourself rather than asking the user.
  On a 5xx from the log endpoint, fetch again.
- `check` and `check-full` run fixtures in parallel, so their output interleaves.
  Never classify from the tail: it holds the build summary and whichever peers finished last, and the failing fixture is often hundreds of lines up.
  Search the whole log for the driver's per-fixture record: `failed: exit=`, `terminated with signal`, `panic:`, `timed out`.
  A Python gate's own error (for example `renderer mutation gate failed:`) sits just before `##[error]`.
- Green runs also print Tracebacks, `AssertionError`, `BrokenPipeError` and "failed" from negative-path tests.
  Never classify a failure from those lines.
- Record the signature as fixture plus assertion text.
  Line numbers shift between SHAs.

## 2. Read every failed job

A run can fail in several jobs for different reasons.
Read each failed job's own failing step before calling it derivative.
The required `admission` job can fail because an upstream acceptance job failed or was cancelled.
Read that upstream failure rather than blaming the aggregate.
A Promote run whose step has failed is red even while its bisect step keeps the run in progress (up to four hours); report it as red at once.
Qualify main runs Promote's tier and bisect on `main` every three hours and files `main-red` issues; triage its runs as a promotion's.
A Promote failure bisects each failed step of the job inside that job: read every `Promotion bisect: <step>:` line and the retained replay logs before diagnosing the commit each names.
A Release failure inside a green promotion is publication or the post-publication wire recheck; [Release publication](../../../docs/verification/release.md#release-publication) says which, and what recovers each.

## 3. Decide whether the diff caused it

Before blaming the commit under test or calling it a stale base, look up the signature on other SHAs and workflows: Selected and on-demand qualification runs.

- **Infrastructure first** for a cancelled or timed-out job.
  Read the aggregate job's "Name each failed job and its cause" lines.
  A Mac job cancelled at exactly 15 minutes with no steps never got a runner; rerun the failed jobs.
  A compile job that times out after a dependency change may have restored only a cold cache: compare its "Cache restored from key" line and snapshot size with the last green run of that job.
  Cache maintenance now warms `baseline`, `compiled` and `compiled-unit` on Linux and macOS when trusted main build/dependency pins change.
  Main publishers save verified compiler downloads even after later failure. Completed compilation saves exact keys; failed/step-timed-out compilation after successful setup saves only run-scoped `-partial-<run_id>-<run_attempt>` keys. These prefix hits still fetch dependencies and rebuild; failed setup/fetch saves no compilation snapshot. Package, previous-release and actionlint caches remain save-on-success. PRs remain restore-only and exact hits are immutable.
  Job budgets are unchanged. A work-step timeout is job budget minus the documented cold-setup allowance and save reserve, only where it exceeds the recorded green duration by at least two minutes. Setup and shard restore/rebuild remain uncapped by new step deadlines; short-budget jobs retain only their job deadline. Pruning keeps the newest partial separately from the newest complete snapshot. Check the explicit save step and its upload result: step failure can save, but a job timeout, runner loss, forced cancellation or upload failure can still prevent saving. A compiler installation must finish verification before publication.
  Suspect the diff only after these are ruled out.
- **Broken main** when the failing file or fixture is not in the PR's diff.
  Reproduce on main HEAD before routing it to the PR's owner: `gh workflow run check.yml --ref main -f base=$(git rev-parse origin/stable)`.
  Selection covers `base..main`, so a base at the last promoted commit selects every Linux check the merged batch touched.
  That dispatch runs no native macOS targets and no upgrade gate, so reproduce those on their own workflow at main HEAD instead: a native Mac failure with `gh workflow run qualify-macos.yml -f ref=main -f suite=native`, and an upgrade failure with `gh workflow run previous-release-upgrade.yml --ref main`.
  A green run that skipped the failing check proves nothing about `main`.
  If main is red, find the merged pair that crossed (two PRs green alone, broken together, or a release that shipped between a wire PR's green run and its merge), name them, and route one main fix or a revert of the later PR.

- **Intermittent** when the signature fails on SHAs that never touched the fixture or its owner (`git log <a>..<b> -- <paths>`), or when one SHA both passes and fails across workflows.
  Promotion runs native Mac and the full suite over a batch, so unrelated SHAs failing one fixture can expose a race rather than a stale base.
- **Caused by the diff** when the signature is new and the diff touches the fixture's owner.
- **A job that stalled or hit its timeout** shows as cancelled, not failed, and has no per-fixture `timed out` record.
  Treat it as a failure.
  Find the last test that started.
  After the infrastructure checks above, if the diff added tests to that binary, suspect them.
  Compare the same job's duration on main and other PRs before an A/B run or asking the user.

Search the open CI issues for the signature before filing, and group them by fixture; several signatures in one fixture are often one race.
[Landing](../../../docs/agents/landing.md#ci-failures) says who owns a recurring red and when it counts as fixed.

## 4. Fix and prove an intermittent

- Mac-only reds can be timing or buffer-size races that slower hosted Macs expose, not named Darwin divergences.
  Reproduce on Linux by forcing the suspected ordering, using the peer delays from [Evidence](../../../CODING_STANDARDS.md#evidence), or by imposing Darwin-sized limits such as a small AF_UNIX send buffer.
- Darwin's temp root is long and is a symlink (`/var` to `/private/var`, `/tmp` to `/private/tmp`).
  A test that compares a resolved path with an unresolved one, or packs a temp path into a fixed-size field such as a socket path, fails only on Mac.
  Reproduce it on Linux by pointing `TMPDIR` at a long symlinked directory.
- Accept a race fix only when the forced run fails without it and passes with it.
  A later Mac green proves nothing alone.
- Changes to fixtures that use raw sockets or wait on process lifetime need real native Mac evidence: PRs run no macOS, so dispatch Selected checks with `native_targets` on the candidate.

## Report

Give the signature, the SHAs and workflows where it passed and failed, whether the diff caused it and why, the issue link, and the fix with its forced-ordering proof.
The fix PR says `Fixes #N` for every open issue whose signature it fixes.
Leave a cause "unknown" only after the full-log search, and say what was searched.
