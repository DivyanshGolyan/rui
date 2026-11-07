# Land a change

[AGENTS.md](../../AGENTS.md#authority) owns authorization and the [standing landing grant](../../AGENTS.md#landing).
[Landing cadence](../../VERIFICATION.md#landing-cadence) owns candidate admission, releases, strict paths and recovery.

## Publish and merge

Before publishing, run the focused checks in [Evidence](../../CODING_STANDARDS.md#evidence).
For PR descriptions, use the `pr` skill.
Every PR commit states its actual test commands and results.
Performance changes include A/B numbers, and TUI changes include a real-screen tmux capture.
Keep published commits unchanged so their CI evidence retains its SHA.

Green means the required `admission` check completed successfully for the current, up-to-date PR merge candidate.
[The main ruleset](../../.github/main-ruleset.json) records the required GitHub enforcement.
Its active remote configuration must match before the publication cutover.
Pending, skipped, cancelled or earlier-head success is not green.
A green PR squash-merges without waiting for review signoff or repeated correctness checks after main.
Follow [Review](../../CODING_STANDARDS.md#review) for Codex requests and findings.
Ship later fixes as follow-up PRs.

Update the PR when its base advances or GitHub reports a conflict.
After updating it, run `python3 tests/ci/prepush.py` and wait for the current candidate's CI.
An earlier green candidate does not qualify a stale base.

## Concurrent PRs

Before splitting work across lanes, check open PRs for files the new work would touch.
PRs run independently only when they touch different files.
Work sharing a file with an open PR stacks on that PR, including across lanes.
Land a stack in order.
Only its front PR takes `origin/main`; each later PR takes main once, after its parent lands.

## CI failures

Diagnose failures through [rui-ci-triage](../../.claude/skills/rui-ci-triage/SKILL.md) and follow [Evidence](../../CODING_STANDARDS.md#evidence) for reruns, strict-path holds and failure retention.
A red counts as fixed only when a commit between the red and a later green changed its failing fixture or owner.
For a recurring fixture-and-assertion signature on SHAs that did not touch its code, update or file one issue for that signature and own the race fix.
Preserve the assertion's strength.
The fixing commit says `Fixes #N`, and a recurrence reopens the issue.
For bot-filed issues, the coordinating agent hands the fix to the thread that owns the fixture.

Before opening a fix, search open CI issues for the touched fixture and include `Fixes #N` for each issue it fixes.
Issues record defects; they do not form a separate publication gate.
Diagnose publication failures in the single Release workflow, and recover the same release without rerunning product correctness.
