# Land a change

[AGENTS.md](../../AGENTS.md#authority) owns authorization and the [standing landing grant](../../AGENTS.md#landing).
[Landing cadence](../../VERIFICATION.md#landing-cadence) owns candidate admission, promotion, releases, strict paths and recovery.

## Publish and merge

Before publishing, run the focused checks in [Evidence](../../CODING_STANDARDS.md#evidence).
For PR descriptions, use the `pr` skill.
PRs changing `src/` carry a [Shape section](../../CODING_STANDARDS.md#shape-before-code), and the plan job refuses them without it.
Every PR commit states its actual test commands and results.
Open every PR with `python3 tests/ci/open_pr.py open --title TITLE --body-file FILE`, which lists open PRs sharing its files and opens it as a draft.
Draft CI runs only the plan (candidate, whitespace and selection checks) and cheap aggregates; local `prepush.py` owns development feedback.
The opener comments `@codex review`; Codex reviews drafts only on request.
Push fixes to the draft and comment `@codex review` after every push.
Once Codex is clean on the current head, run `python3 tests/ci/open_pr.py ready` to start the full selected suite; it refuses while the PR's head on GitHub differs from the committed checkout or changes are uncommitted.
After readiness, a fix whose diff since Codex's clean review changes only test files or blocks (`tests/**/test_*.py`, integration fixtures and their data, `*_test.zig`/test-only Zig roots, or `test "..."` blocks in source) merges once `admission` is green, without another Codex review.
Any non-test change, including CI, build, release or other operational scripts (the rest of `tests/ci/`, workflows and `build.zig`), needs Codex clean on the new head again.
Performance changes include A/B numbers, and TUI changes include a plain-PTY capture using [verify-rui](../../.claude/skills/verify-rui/SKILL.md).
Keep published commits unchanged so their CI evidence retains its SHA.

Green means the required `admission` check completed successfully for the PR's current head; it need not be rerun after `main` moves.
[The main ruleset](../../.github/main-ruleset.json) records the required GitHub enforcement; the live ruleset must keep matching it.
Pending, skipped, cancelled or earlier-head success is not green.
A green PR squash-merges without waiting for review signoff or a promotion.
Follow [Review](../../CODING_STANDARDS.md#review) for Codex requests and findings.
Ship later fixes as follow-up PRs.

Merge `origin/main` into a PR only when it conflicts with `main`; [Conflict alert](../../.github/workflows/conflict-alert.yml) comments on each PR a move of `main` leaves conflicting.
After that merge, run `python3 tests/ci/prepush.py` and wait for the new head's CI.
A PR that merely trails `main` merges as it is.

## Concurrent PRs

Before splitting work across lanes and again before opening a PR, compare its changed files with open PRs, including PRs opened since work began.
`open_pr.py open` runs that comparison on the committed branch; pass `--base PARENT` for a stacked PR.
It also lists open PRs whose added lines use a top-level or public Zig or Python name the branch renames or removes, which [pr_overlap.py](../../tests/ci/pr_overlap.py) reports alone too.
The check needs GitHub access and reports shared files and those names, not other semantic dependencies, files GitHub shows no patch for, or PRs opened afterward.
Git can merge edits to the same file without a conflict even when one removes a name the other uses.

A change that renames, removes or changes the signature of a name other files use lands only when no open PR uses it, or after it fixes those PRs too.
Before landing one, run `python3 tests/ci/pr_overlap.py` again and search open PRs' diffs for each changed signature, which it does not detect.
Fix each dependent PR on its branch, with its owner's lane told, or wait until it lands.
#1180's `screen_build` rename cost four TUI PRs a merge of `main` and a fresh CI run each.
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
When a `ci-red` issue closes, give it exactly one cause label: `cause:real` when the fix changed product behavior, else `cause:compile`, `cause:stale`, `cause:fixture`, `cause:flake`, `cause:policy` or `cause:infra`.
A reopened issue keeps its label; change it if the next fix finds another cause.
[tp_rate.py](../../tests/ci/tp_rate.py) reports the weekly share of closed `ci-red` issues that were real bugs, and lists those still unlabelled.

## Promote

Promotion publishes a release and advances `stable`; merging never does.
Ask the user before dispatching it: `gh workflow run promote.yml --ref main`.
A red promotion names, on each `promotion-red` issue it files, the first batch commit where each failed step of that job fails; a suite batch with several causes names only its earliest.
Fix forward through an ordinary PR, then promote again.
Recover an interrupted publication by rerunning that promotion's failed jobs, which reuses the same release identity.
