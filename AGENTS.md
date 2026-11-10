# Working on Rui

## Before work

Inspect the working-tree diff and preserve concurrent work.
Load guidance for the task at hand, combining applicable routes:

- **Product scope or behavior:** read [README.md](README.md) and the affected [Architecture](ARCHITECTURE.md) sections.
- **Engineering:** for implementation, design, debugging, builds or engineering review, read [Engineering](CODING_STANDARDS.md#engineering).
- **Review:** read [Review](CODING_STANDARDS.md#review), including when implementing findings.
  Reviews are read-only unless fixes are requested.
- **Performance:** for implementation or review, read [Performance](CODING_STANDARDS.md#performance), including build-latency changes.
- **Documentation, terminology or decisions:** read [Contract maintenance](CODING_STANDARDS.md#contract-maintenance) and the documentation checks in [Evidence](CODING_STANDARDS.md#evidence).
- **Implementation or verification:** read [Evidence](CODING_STANDARDS.md#evidence) and the applicable [Verification](VERIFICATION.md) cases.
- **Test selection or CI changes:** read [Canonical gates](VERIFICATION.md#canonical-gates).
- **Red CI:** use [rui-ci-triage](.claude/skills/rui-ci-triage/SKILL.md).
- **Issue work:** read the live issue, discussion and dependencies, then [issue guidance](docs/agents/issue-tracker.md) and [triage labels](docs/agents/triage-labels.md).
  Follow the latest accepted decision.
- **Contract ownership or enforcement changes:** read [Contract enforcement](CODING_STANDARDS.md#contract-enforcement).

## Authority

User instructions outrank skills, and Rui's documents own repository policy over generic skills.
Skills supply techniques, not authorization.
Make reversible choices inside the accepted contract yourself.
For unresolved behavior, architecture, scope or access, finish independent authorized work, then present bounded options with a recommendation and consequences.

A request to create or update a PR authorizes scoped pushes and follow-up fixes for review or CI, including across agent handoffs.
Ask before publishing elsewhere, widening scope, force-pushing, deploying or closing issues.
Honor narrower user limits and one-way-door approvals.

## Code Review Rules

These rules state [Review](CODING_STANDARDS.md#review) in the form Codex applies on a PR.

### One finding per class

- When two or more symptoms share a cause (a fact derived in two places, a rule with two owners, state synced instead of derived), report one finding at the owner, list every site and make the correction the design that removes the class.
  Safe path: one function or owner that every reader calls.
- Simple means unbraided, as in Rich Hickey's "Simple Made Easy": independent concerns kept independent, whatever the line count.

### Boundaries

- Flag a decision made inside a shell (a file that reads the terminal, the Store, the network or the clock) that mixes that I/O with policy.
  Safe path: a core that takes the values the shell read and returns the decision, listed in `src/logic_tests.zig`; the shell only reads and applies.

### Deep modules

- Flag new public surface that exposes representation, call order or cleanup details, and a second implementation of a behavior an existing component owns.
  Safe path: the caller states intent and the existing owner does the work.

### Domain tests

- For an edge case in a combination of states, report once the missing test over the owner's whole domain, and name the cases it must include.
  Do not report each case as its own finding.

## Status updates

Report progress, blockers and verification results relevant to the requested task.
Include repository-wide health only when it affects that task or the user asks for it.

## Landing

Standing grant: merge each small, coherent change once its PR is green, without further approval, lane completion or review signoff.
Changes reach `main` only by merging their PR.
The admin bypass in [the main ruleset](.github/main-ruleset.json) is a last resort, used only for changes on the critical path.
Use it only when every red or missing check is a macOS job that GitHub never assigned a runner, every check that ran passed, and an infra-retry also failed to get a runner.
State why in the merge commit or a PR comment.
A rename, removal or signature change of a shared name lands only when no open PR uses it or the same PR fixes those that do; check with `python3 tests/ci/pr_overlap.py` ([Concurrent PRs](docs/agents/landing.md#concurrent-prs)).
For PR publication, stacking, landing or CI-failure ownership, read [Landing procedures](docs/agents/landing.md).
