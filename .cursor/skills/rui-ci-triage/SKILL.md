---
name: rui-ci-triage
description: Find why a Rui CI run is red and whether the commit under test caused it. Use when Selected checks, stable qualification, Daily Mac, a nightly, cold acceptance or Auto-land failed, or when asked why CI, stable or Mac is red.
---

# rui-ci-triage

Name the failing fixture and assertion from the log, decide whether the commit under test caused it, and route the fix. Never rerun, skip or weaken an assertion to get green; [Landing](../../../AGENTS.md#landing) owns retry policy.

## 1. Find the failure record

- Fetch failed-job logs through the GitHub MCP: `get_job_logs` with `run_id` and `failed_only: true` (or one `job_id`) and `return_content: true`. It works in cloud sessions. Large logs land in a file; search the file. Never ask the user for logs. A 5xx from the log endpoint is transient; fetch again.
- `check` and `check-full` run fixtures in parallel, so their output interleaves. The tail holds the build summary and whichever peers finished last; the failing fixture is often hundreds of lines up. Search the whole log for the driver's per-fixture record: `failed: exit=`, `terminated with signal`, `panic:`, `timed out`. A Python gate's own error (for example `renderer mutation gate failed:`) sits just before `##[error]`.
- Green runs also print Tracebacks, `AssertionError`, `BrokenPipeError` and "failed" from negative-path tests. Never classify a failure from those lines.
- Record the signature as fixture plus assertion text. Line numbers shift between SHAs.

## 2. Read every failed job

A run can fail in several jobs for different reasons. An Auto-land `completion` failure usually means its parent qualification was red or cancelled, so read the parent's jobs. Its own step can still fail independently, such as a dispatch HTTP 500; after a green qualification that loses the promotion, so recover with the lost-completion command in [Landing](../../../AGENTS.md#landing).

## 3. Decide whether the diff caused it

Before blaming the commit under test or calling it a stale base, look up the signature on other SHAs and workflows: stable qualification, Daily Mac, Selected and on-demand Mac runs.

- **Intermittent** when one SHA both passes and fails across workflows, or when the signature fails on SHAs that never touched the fixture or its owner (`git log <a>..<b> -- <paths>`). Stable candidates run Mac `check` whatever their diff, so unrelated SHAs failing one fixture point to a race, not a stale base.
- **Caused by the diff** when the signature is new and the diff touches the fixture's owner.

For an intermittent, search the issues for the signature, then file or update one issue keyed by fixture plus assertion and own the race fix. Retriggering, or landing until a candidate happens to pass, is not a fix.

## 4. Fix and prove

- Mac-only reds here are usually timing or buffer-size races that slower hosted Macs expose, not named Darwin divergences. Reproduce on Linux by forcing the suspected ordering, delaying each peer read, reply and exit as [Evidence](../../../CODING_STANDARDS.md#evidence) describes, or by imposing Darwin-sized limits such as a small AF_UNIX send buffer. Replace sleeps with explicit gates.
- Accept a fix when the forced run fails before it and passes after it. A later Mac green proves nothing alone.
- A red is resolved only when `git log <red-sha>..<green-sha> -- <fixture and owner paths>` shows the fix.
- Run fixtures locally as a non-root user; under root, permission denials pass and permission assertions fail.
- When the fix touches sockets or process lifetime, dispatch `qualify-macos.yml` with `ref=<revision>` and `suite=native` before landing.

## Report

Give the signature, the SHAs and workflows where it passed and failed, whether the diff caused it and why, the issue link, and the fix with its forced-ordering proof. Leave a cause "unknown" only after the full-log search, and say what was searched.
