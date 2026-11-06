# Working on Rui

Build the simplest complete runtime users can explain through ordinary work, failure and recovery.
Prefer a coherent final design over the smallest diff; justify machinery by required behavior or demonstrated cost.

## Before work

Inspect the working-tree diff; preserve concurrent work.
Read [README.md](README.md) for scope/status and affected [ARCHITECTURE.md](ARCHITECTURE.md) sections for accepted behavior.

Load applicable guidance before acting; routes combine:

- **Implement, design, debug, change builds, or review engineering:** [Engineering](CODING_STANDARDS.md#engineering).
- **Review, including documentation, or implement review findings:** [Review](CODING_STANDARDS.md#review).
  Reviews are read-only unless fixes are requested.
- **Implement or review performance changes:** [Performance](CODING_STANDARDS.md#performance), including build-latency exceptions.
- **Change documentation, terminology or decisions:** [Contract maintenance](CODING_STANDARDS.md#contract-maintenance).
- **Implement, test, verify or report:** [Evidence](CODING_STANDARDS.md#evidence) and applicable [Verification](VERIFICATION.md) cases.
- **Select checks or change CI:** [Canonical gates](VERIFICATION.md#canonical-gates).
  `select_tests.py` decides; no reviewer acceptance.
- **Diagnose red CI:** use [`rui-ci-triage`](.claude/skills/rui-ci-triage/SKILL.md).
- **Issue work:** read the live issue, discussion and dependencies, then [issue guidance](docs/agents/issue-tracker.md) and [triage labels](docs/agents/triage-labels.md).
  Follow the latest accepted decision.
- **PR descriptions:** use `pr`.
- **Change a contract's owner or its check:** [Contract enforcement](CODING_STANDARDS.md#contract-enforcement).

## Code Review Rules

PR reviewers, including Codex, apply [Review](CODING_STANDARDS.md#review); its **Simplify first** rule shapes every suggested correction.

## Authority

User instructions outrank skills, and Rui's own documents outrank generic skills on repository policy.
Skills supply techniques, not authorization.

Make reversible choices inside the accepted contract yourself.
When behavior, architecture, scope or access is unresolved, finish the independent authorized work first, then present bounded options with a recommendation and their consequences.

A request to create or update a PR authorizes pushing its branch and maintaining that PR within scope: follow-up pushes for requested fixes, review findings and CI failures, carried across agent handoffs.
Ask before publishing to another destination, widening scope, force-pushing, deploying or closing issues.
Honor narrower user limits.

## Landing

Standing grant: merge each small, coherent change once its PR is green, with no further approval, lane completion or review signoff.
One-way-door approvals still apply.

- Changes reach `main` only by merging their PR.
- Green means the `linux` check on the PR's current head completed with success; pending, skipped, cancelled, or green on an earlier head is not green.
  Main's ruleset requires it.
- A PR whose CI is green and whose Codex review is clean merges now.
  Hold it for nothing CI repeats (full `zig build test`, `check`, a local mirror of Selected); [Evidence](CODING_STANDARDS.md#evidence) sets the focused pre-push checks.
  Ship later fixes as follow-up PRs.
- Every PR commit states its actual test commands and results, plus performance A/B numbers when the change touches performance.
  TUI changes also include a real-screen tmux capture.
  Keep published commits as they are: a rewritten commit has a new SHA and loses its CI.
- Merge `origin/main` into a PR only when GitHub reports a conflict, then run `python3 tests/ci/prepush.py` and wait for that head's own CI: a merge commit is new content (#882 brought 2,129 untracked files in through one).
  A PR that merely trails main merges as it is; two PRs green on their own can still break main together (#768 and #769), and main's CI catches that, so fix it forward in a new PR.
- Keep working while CI or Codex runs, however long they take.
  Once a PR is pushed, start the next piece at once: independent work on a fresh branch from `origin/main`, dependent work on a branch stacked on the open one, and return to merge when the checks finish.
- PRs run in parallel only when they touch different files.
  Work that shares a file with an open PR, in this lane or another, stacks on that PR.
  A stack lands in a fixed order, and only its front PR takes `origin/main`; each later PR takes main once, after its parent lands.
  Before splitting work across lanes, check the open PRs for files the new work would touch.
- After ready, rerun an item at most once; a fix for red CI keeps the failure evidence.
- A red is fixed only by a commit, between it and a later green, that changed its failing fixture or owner.
  A fixture-and-assertion signature that recurs on SHAs that did not touch its code has no culprit to revert: the agent that finds it updates or files one `stable-red` issue keyed by that signature and owns the race fix, keeping the assertion as strong.
  The fixing commit says `Fixes #N`, and a recurrence reopens the issue.
  When the bot files the issue, the coordinating agent hands it at once to the thread that owns its fixture.
- Before opening a fix, search the open `stable-red` issues for the touched fixture and write `Fixes #N` for each one it fixes; the policy job warns on a PR that touches a held fixture without `Fixes #N` or `Refs #N`.
  Every status names the stable hold (open `stable-red` issues and hours since the last promotion) until it clears; `python3 tests/ci/stable_hold.py status` prints both.
- Mac and upgrade checks qualify `stable` after main advances; they never gate main.
  Fix Mac reds forward on main, and revert only if the fix is slow.
  Users install from `stable`.
  [Landing cadence](VERIFICATION.md#landing-cadence) owns promotion, Auto-land, releases, strict paths and recovery from a lost qualification.
