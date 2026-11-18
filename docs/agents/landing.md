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
Open the PR to obtain its number, then publish the frames. Screens are required by `admission` for merge; the build and tests run without them. After posting, the workflow attempts to rerun a failed `admission` job for that head.
Admission accepts a GitHub Actions sticky screens comment with the current head SHA and at least one image. It also accepts a body line that, after leading whitespace, starts with `![`, `<img` or `<video` and contains a `https://github.com/user-attachments/` URL outside fenced code and HTML comments. Inline-code examples, reference images, other hosts, bare URLs and repository page links do not pass. A change that provably draws nothing different may instead carry `No screen change: <nonempty reason>` on its own line.
It derives UI paths from Overview's production import closure minus Host dependencies and test owners, including the base tree for deleted files, and also covers verify-rui's `frames.json`.
For interaction changes, show the sequence with a recording or labelled before/after screenshots. State the source revision, terminal surface and limits, retain raw capture provenance, and exclude secrets.
Show before/after PNGs to the person who requested the work in your own conversation when possible. Humans with browsers may still upload images or videos as `github.com/user-attachments` media.
A local path or CI artifact pointer alone does not meet the evidence requirement; visual evidence does not replace behavior assertions or hosted acceptance.
Keep published commits unchanged so their CI evidence retains its SHA.

Green means the required `admission` check completed successfully for the PR's current head; it need not be rerun after `main` moves.
[The main ruleset](../../.github/main-ruleset.json) records the required GitHub enforcement; the live ruleset must keep matching it.
Pending, skipped, cancelled or earlier-head success is not green.
A green PR squash-merges without waiting for review signoff or a promotion.
Follow [Review](../../CODING_STANDARDS.md#review) for Codex requests and findings.
Ship later fixes as follow-up PRs.

The admin bypass in [the main ruleset](../../.github/main-ruleset.json) is a last resort, used only for changes on the critical path.
Use it only when every red or missing check is a macOS job that GitHub never assigned a runner, every check that ran passed, and an infra-retry also failed to get a runner; state why in the merge commit or a PR comment.

Merge `origin/main` into a PR only when it conflicts with `main`; [Conflict alert](../../.github/workflows/conflict-alert.yml) comments on each PR a move of `main` leaves conflicting.
After that merge, refresh local evidence invalidated by integration and wait for the new head's CI, including its required all-unit compile.
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
The fastest fix for a red `main` is often a revert of the one merged PR that broke it.
The [main build](../../.github/workflows/main-build.yml) names the PRs merged since `main` last compiled in its `ci-red` issue, and when two of them crossed, a revert of the later one is the fast fix.
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
Promote without asking once the merged batch holds the fixes users are waiting for, and at least before each working day: `gh workflow run promote.yml --ref main`.
Whoever dispatches a promotion watches it to the end and reports the result unprompted.
A failed step means the promotion is red even while its bisect step keeps the run in progress for up to four hours; report it then.
A red promotion names, on each `promotion-red` issue it files, the first batch commit where each failed step of that job fails; a suite batch with several causes names only its earliest.
Fix forward through an ordinary PR, then promote again.
Recover a red Release as [Release publication](../verification/release.md#release-publication) says; a red wire recheck there follows publication, not a failed one.
