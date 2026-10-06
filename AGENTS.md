# Working on Rui

Build the simplest complete runtime users can explain through ordinary work, failure and recovery. Prefer the simplest coherent final design over the smallest diff; justify machinery by required behavior or demonstrated cost.

## Task router

Read [README.md](README.md) for scope/status, affected [ARCHITECTURE.md](ARCHITECTURE.md) sections for accepted behavior/terminology/rationale, and applicable [VERIFICATION.md](VERIFICATION.md) cases for required evidence. GitHub issues own unresolved decisions; [issue #2](https://github.com/DivyanshGolyan/rui/issues/2) owns readiness. For issue-driven work, read the live issue, relevant discussion and dependencies; follow the latest accepted decision rather than historical planning instructions.

Read the following standards **before the corresponding work**; multiple routes can apply:

- **Design, implement or fix code, resources or build configuration:** [Implementation and design](CODING_STANDARDS.md#implementation-and-design), including owner transitions, resource/custody cleanup and performance constraints.
- **Review code or design, or implement review findings:** [Review](CODING_STANDARDS.md#review), including the mandatory independent read-only opinion and programmer's lens. Reviews remain read-only unless fixes are requested.
- **Write tests, verify changes or report evidence:** [Verification and evidence](CODING_STANDARDS.md#verification-and-evidence), including owner-boundary oracles and regression negative controls; use [canonical gates](VERIFICATION.md#canonical-gates) for required commands and cadence.
- **Change documentation, terminology or decisions:** [Documentation maintenance](CODING_STANDARDS.md#documentation-maintenance), including single contract ownership and the no-parallel-ADR/glossary policy. Load `writing-for-agents` before editing skills, this file or Markdown reached from it.
- **Use skills, manage issues or write PR descriptions:** [Repository tools and skill precedence](CODING_STANDARDS.md#repository-tools-and-skill-precedence).

## Authority to act

Inspect the working-tree diff before changes; preserve concurrent work. Carry authorized work through applicable verification and issue acceptance criteria without reopening settled choices. Resolve routine reversible choices from the contract and code. For unresolved consequential behavior/architecture/scope choices, missing access or authorization, first complete independent authorized work, then present bounded options, a recommendation and machinery/failure consequences.

Implementation approval does not authorize pushing, creating/updating PRs or issues, closing issues, merging, deploying or other shared/irreversible effects. Obtain specific authorization unless already granted; prepare the local result first.
