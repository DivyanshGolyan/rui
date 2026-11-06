---
name: rui-ci-triage
description: Triage CI: find why a Rui run is red and whether the commit under test caused it. Use when asked why CI, stable, Daily Mac or a nightly is red, or when Selected checks, stable qualification, cold acceptance or Auto-land failed, or a job stalled, timed out or shows cancelled.
---

# rui-ci-triage

Name the failing fixture and assertion from the log, decide whether the commit under test caused it, and route the fix. Rerun, retry and assertion rules live in [Landing](../../../docs/agents/landing.md#ci-failures) and [Evidence](../../../CODING_STANDARDS.md#evidence); this skill never relaxes them.

## 1. Find the failure record

- Fetch failed-job logs through the GitHub MCP: `get_job_logs` with `run_id` and `failed_only: true` (or one `job_id`) and `return_content: true`. Large logs land in a file; search the file. Fetch logs yourself rather than asking the user. On a 5xx from the log endpoint, fetch again.
- `check` and `check-full` run fixtures in parallel, so their output interleaves. Never classify from the tail: it holds the build summary and whichever peers finished last, and the failing fixture is often hundreds of lines up. Search the whole log for the driver's per-fixture record: `failed: exit=`, `terminated with signal`, `panic:`, `timed out`. A Python gate's own error (for example `renderer mutation gate failed:`) sits just before `##[error]`.
- Green runs also print Tracebacks, `AssertionError`, `BrokenPipeError` and "failed" from negative-path tests. Never classify a failure from those lines.
- Record the signature as fixture plus assertion text. Line numbers shift between SHAs.

## 2. Read every failed job

A run can fail in several jobs for different reasons. Read each failed job's own failing step before calling it derivative. An Auto-land `completion` job fails when its parent qualification was red or cancelled, so read the parent's jobs too, but it can also fail on its own, such as a dispatch HTTP 500. Recover with the matching procedure in [Landing cadence](../../../VERIFICATION.md#landing-cadence): the lost-completion dispatch, or a rerun of the diagnosed Auto-land job after a runner failure.

## 3. Decide whether the diff caused it

Before blaming the commit under test or calling it a stale base, look up the signature on other SHAs and workflows: stable qualification, Daily Mac, Selected and on-demand Mac runs.

- **Intermittent** when the signature fails on SHAs that never touched the fixture or its owner (`git log <a>..<b> -- <paths>`), or when one SHA both passes and fails across workflows. Stable qualification runs Mac checks whatever the diff, so unrelated SHAs failing one fixture point to a race, not a stale base.
- **Caused by the diff** when the signature is new and the diff touches the fixture's owner.
- **A job that stalled or hit its timeout** shows as cancelled, not failed, and has no per-fixture `timed out` record. Treat it as a failure. Find the last test that started. If the diff added tests to that binary, suspect them first. Compare the same job's duration on main and other PRs before an A/B run or asking the user.

Search the open `stable-red` and CI-red issues for the signature before filing, and group them by fixture; several signatures in one fixture are often one race. [Landing](../../../docs/agents/landing.md#ci-failures) says who owns a recurring red and when it counts as fixed.

## 4. Fix and prove an intermittent

- Mac-only reds can be timing or buffer-size races that slower hosted Macs expose, not named Darwin divergences. Reproduce on Linux by forcing the suspected ordering, using the peer delays from [Evidence](../../../CODING_STANDARDS.md#evidence), or by imposing Darwin-sized limits such as a small AF_UNIX send buffer.
- Darwin's temp root is long and is a symlink (`/var` to `/private/var`, `/tmp` to `/private/tmp`). A test that compares a resolved path with an unresolved one, or packs a temp path into a fixed-size field such as a socket path, fails only on Mac. Reproduce it on Linux by pointing `TMPDIR` at a long symlinked directory.
- Accept a race fix only when the forced run fails without it and passes with it. A later Mac green proves nothing alone.
- Changes to fixtures that use raw sockets or wait on process lifetime also need the on-demand Mac run in [Landing cadence](../../../VERIFICATION.md#landing-cadence).

## Report

Give the signature, the SHAs and workflows where it passed and failed, whether the diff caused it and why, the issue link, and the fix with its forced-ordering proof. The fix PR says `Fixes #N` for every open issue whose signature it fixes. Leave a cause "unknown" only after the full-log search, and say what was searched.
