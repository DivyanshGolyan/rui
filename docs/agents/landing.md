# Land a change

[AGENTS.md](../../AGENTS.md#authority) owns authorization and the [standing landing grant](../../AGENTS.md#landing).
[Landing cadence](../verification/release.md#landing-cadence) owns candidate admission, promotion, releases, strict paths and recovery.

## Publish and merge

Before publishing, establish or reuse the relevant focused evidence in [Evidence](../../CODING_STANDARDS.md#evidence).
A PR description has a [Goal](../../CODING_STANDARDS.md#goal), a Summary, the Evidence it was checked with, and its Merge danger.
The description lists every behavior change in the diff, small ones included, so the summary and the diff agree.
PRs changing `src/` follow [Shape before code](../../CODING_STANDARDS.md#shape-before-code); the plan checks the description, and review checks the shape.
Every PR commit states its actual test commands and results.
Open every PR with `python3 tests/ci/open_pr.py open --title TITLE --body-file FILE`, which reports overlapping work, opens it as a draft and requests `@codex review`.
It refuses a body admission would reject, so a PR that changes UI files opens with its screens captured (`verify-rui frames`, then `--frames DIR`) or with a `No screen change:` line; publish the frames with `verify-rui publish DIR --pr N` as soon as it prints the number.
A draft runs only the plan job, so Codex rounds do not start, then cancel, the selected suite.
Codex reviews a draft only on request: after each fix push, comment `@codex review` again.
Once Codex is clean on the published head, run `python3 tests/ci/open_pr.py ready`; selected CI then runs once on that head, and the PR merges when it is green.
Two PRs may open ready with `open_pr.py open --ready`, so CI runs beside review: a fix for a red `main`, and a PR other open PRs are waiting on.
Codex is clean when its latest `codex-review-state:v1` summary names the reviewed head and reports no unresolved findings.
A "no major issues" receipt alone is not clean, and an earlier review thread stays open until its author resolves it.
After a fix push, resolve each earlier thread that the fix answered.
Keep clean Codex evidence through unchanged semantics as permitted below; a production or operational change invalidates it and needs `@codex review` again (Codex reviews a ready PR automatically on each push).
A fix whose diff since Codex's clean review changes only test files or blocks (`tests/**/test_*.py`, integration fixtures and their data, `*_test.zig`/test-only Zig roots, or `test "..."` blocks in source) merges once `admission` is green, without another Codex review.
Documentation-only edits that preserve the reviewed contract also reuse the clean review, with the semantic comparison recorded in the PR.
Two more changes merge on green `admission` without another Codex review: a commit that only applies the Store format renumber `tests/ci/schema_number.py` computes, and a pure revert of the one merged PR that broke `main`.
Any other non-test change, including CI, build, release or other operational scripts (the rest of `tests/ci/`, workflows and `build.zig`), needs Codex clean on the new head again.
Performance changes include A/B numbers.
Every UI PR provides actual-implementation screenshots or a screen recording before it is merge-ready.
Use [verify-rui](../../.claude/skills/verify-rui/SKILL.md) and the [feature map](../../.claude/skills/verify-rui/features/README.md) to select states for the changed screens.
Build both pinned revisions, then run `$V frames HEAD --before BASE --only <states for the changed screens> --sizes 140x40,46x30 --record` and `$V publish DIR --pr N` (set `V=.claude/skills/verify-rui/scripts/verify-rui`).
The comparison loads both default recipes from their pinned HEAD/BASE revisions; a newer or dirty checkout cannot change them. Explicit `--scenario` intentionally overrides both. A selected state absent from BASE is new with only an after capture.
The publisher selects changed/new PNGs and GIFs (`--all` includes unchanged pairs), checks the PR head, pushes the media and manifests to `pr-screens`, and dispatches a workflow to post a sticky screens comment. Selected media must total at most 20 MB; the command needs repository push access and permission to dispatch the workflow.
Open the PR to obtain its number, then publish the frames. Screens are required by `admission` for merge; the build and tests run without them. After posting, the workflow retries a failed `admission` only on the latest completed PR run for that head. If admission is already running, it waits for the result; if it has not started, admission reads the new screens itself. A timeout or ambiguous ready transition leaves a warning and may require a manual rerun.
Admission accepts a GitHub Actions sticky screens comment with the current head SHA and at least one image. It also accepts a body line that, after leading whitespace, starts with `![`, `<img` or `<video` and contains a `https://github.com/user-attachments/` URL outside fenced code and HTML comments. Inline-code examples, reference images, other hosts, bare URLs and repository page links do not pass. A change that provably draws nothing different may instead carry `No screen change: <nonempty reason>` on its own line.
It derives UI paths from Overview's production import closure minus Host dependencies and test owners, including the base tree for deleted files, and also covers verify-rui's `frames.json`.
For interaction changes, show the sequence with a recording or labelled before/after screenshots. State the source revision, terminal surface and limits, retain raw capture provenance, and exclude secrets.
Show before/after PNGs to the person who requested the work in your own conversation when possible. Humans with browsers may still upload images or videos as `github.com/user-attachments` media.
A local path or CI artifact pointer alone does not meet the evidence requirement; visual evidence does not replace behavior assertions or hosted acceptance.
Keep published commits unchanged so their CI evidence retains its SHA.

Green means the required `admission` check completed successfully for the PR's current head; it need not be rerun after `main` moves.
When `admission` fails, [Admission notice](../../.github/workflows/admission-notice.yml) comments its errors on the PR; when only `plan` and `admission` failed, editing the PR body reruns them against the new body.
[The main ruleset](../../.github/main-ruleset.json) records the required GitHub enforcement; the live ruleset must keep matching it.
Pending, skipped, cancelled or earlier-head success is not green.
A green PR with a clean review squash-merges without waiting for a person's signoff or a promotion.
Follow [Review](../../CODING_STANDARDS.md#review) for Codex requests and findings.
Ship later fixes as follow-up PRs.

The admin bypass in [the main ruleset](../../.github/main-ruleset.json) is a last resort, used only for changes on the critical path.
Use it only when every red or missing check is a macOS job that GitHub never assigned a runner, every check that ran passed, and an infra-retry also failed to get a runner; state why in the merge commit or a PR comment.

Merge `origin/main` into a PR only when it conflicts with `main`; [Conflict alert](../../.github/workflows/conflict-alert.yml) comments on each PR a move of `main` leaves conflicting.
After that merge, refresh local evidence invalidated by integration and wait for the new head's CI, including its required all-unit compile.
A PR that merely trails `main` merges as it is.

## Review evidence

A PR merges only when its latest completed review is clean.
Codex is that review ([Review](../../CODING_STANDARDS.md#review)).
While Codex is out of allowance (through Tue 2026-12-01), the [pr-reviewer agent](../../.claude/agents/pr-reviewer.md) gives each PR one review instead, once per PR and not per push.
Start it with the PR number alone, then post its verdict with `python3 tests/ci/open_pr.py review --head SHA [--pr N] [--findings FILE]`, where SHA is the head the reviewer reported.
Fix each finding at its class, post `open_pr.py review --fixed` (it refuses unless a finding is unresolved), and merge on green; there is no second review, and the gate is per PR, not per head.
A bare Codex "no major issues" receipt does not clear it.
A revert or fix-forward PR for a red `main` needs the same one review while Codex is out; run it as soon as the PR is open, since the review is short.
A `sonnet-review-state:v1` marker counts only from a maintainer ([pr_timeline.py](../../tests/ci/pr_timeline.py) reads it with Codex's).
[review_before_merge.py](../../.claude/hooks/review_before_merge.py) refuses `merge_pull_request`, `enable_pr_auto_merge` and `gh pr merge` on a PR whose latest review is missing or has unresolved findings, and [merge_review.py](../../tests/ci/merge_review.py) names the next step.
It lets a merge through, with a warning, when GitHub cannot be read.
When Codex reviews again, the same check reads Codex's reviews; delete the interim paragraph then.

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
PRs sharing source, API or operational ownership stack on that dependency, including across lanes.
Documentation-only overlap does not require stacking when the owners compare the changed sections, confirm there is no semantic dependency or contradictory contract, and record that comparison before publication and merge.
Keep sole-writer worktrees and actual source/API dependency order; a textual non-conflict alone does not establish semantic independence.
Land a stack in order.
Only its front PR takes `origin/main`.
When a PR lands, GitHub deletes its branch and retargets the next PR in the stack to `main`.
That next PR then merges as it is, with no push, when its head contains its parent's final head (`git merge-base --is-ancestor PARENT_HEAD CHILD_HEAD`) and GitHub reports no conflict; its earlier green `admission` and clean Codex review still apply to that unchanged head.
Otherwise it first merges its parent's final head, or `origin/main` on a conflict, and waits for the new head's CI.
The ancestry check matters because squash merging gives the parent new commits on `main`: a stacked PR missing the parent's last fix merges without a conflict yet brings back what that fix removed.
Arm auto-merge only on a PR whose base is `main`; on a stacked PR it would merge into the parent's branch.

## CI failures

Diagnose failures through [rui-ci-triage](../../.claude/skills/rui-ci-triage/SKILL.md) and follow [Evidence](../../CODING_STANDARDS.md#evidence) for reruns, strict-path holds and failure retention.
The pre-push hook re-runs the last CI red as described in [local feedback evidence](../../CODING_STANDARDS.md#evidence).
A red whose failing file or fixture is outside the PR's diff is first reproduced on `main`; when `main` itself is red, it gets one fix owner, and the PR's owner is not asked to fix it.

`main` is red while an open `main-red` issue says so.
While `main` is red, a PR selects nothing, as a documentation change does: `plan` lists the open `main-red` issues updated in the last day with [main_red.py](../../tests/ci/main_red.py), and `admission` fails first, naming them, to save runner minutes.
A PR whose body names one of those issues as `#N`, usually its fix with `Fixes #N`, runs as usual; a revert names it too.
PRs run a fast tier, so a break can reach `main`; [scheduled promotion](../verification/release.md#scheduled-promotion) finds it within one three-hour tick, names each failed step's suspect commits, most direct first, and files one `main-red` issue per cause, listing them.
The thread that authored the named commit's PR owns the fix and starts it promptly, as its next work: a fix-forward PR with `Fixes #N`, or a pure revert of that one PR, which merges on green `admission` without another Codex review.
When that thread has ended, the coordinating agent hands the issue to the thread that owns the failing fixture.
A verdict that the red did not reproduce at HEAD, or already failed at the batch's base, names no commit; triage it as below.
While `main` is red, Promote can still publish an earlier commit with a green `main-qualified` record (`-f sha=qualified`).
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
Promote publishes a green main HEAD every three hours when main has moved past `stable`, and publishes a commit a [scheduled promotion](../verification/release.md#scheduled-promotion) already qualified in minutes; it qualifies main HEAD itself, as below, only when no green record of that commit still holds its archives.
Dispatch a promotion by hand without asking once the merged batch holds a fix users are waiting for and the next tick is too late: `gh workflow run promote.yml --ref main`, or `-f sha=qualified` for the newest green commit while main HEAD is red.
A dispatch waits behind a running promotion, and a scheduled tick replaces it while it waits ([Scheduled promotion](../verification/release.md#scheduled-promotion)).
Whoever dispatches a promotion watches it to the end and reports the result unprompted.
A failed step means the promotion is red; report it at once, since its suspects are in the run's log as the job ends.
A red promotion lists, on each `promotion-red` issue it files, the batch commits suspected of each failed step of that job, most direct first.
Fix forward through an ordinary PR, then promote again.
A Promote run whose only failure is batch's `Fail a scheduled run whose main HEAD is red` step is a reminder, not a new red: triage the run its error names, file nothing, and leave it out of green-rate counts.
Recover a red Release as [Release publication](../verification/release.md#release-publication) says; a red wire recheck there follows publication, not a failed one.
