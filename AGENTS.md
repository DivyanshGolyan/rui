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

## Status updates

Report progress, blockers and verification results relevant to the requested task.
Include repository-wide health only when it affects that task or the user asks for it.

## Landing

Standing grant: merge each small, coherent change once its PR is green, without further approval, lane completion or review signoff.
Changes reach `main` only by merging their PR.
For PR publication, stacking, landing or CI-failure ownership, read [Landing procedures](docs/agents/landing.md).
