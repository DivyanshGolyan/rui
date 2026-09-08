# Working on OnePage

OnePage is a resource-bounded, crash-resumable local runtime for programmable coding-agent workflows. Aim for the smallest complete design that delivers the promised behavior. Justify complexity through concrete execution, recovery, and resource scenarios.

## Read for the task

- [README.md](README.md): project orientation, implementation status, prerequisites, and build entry points. Read when starting unfamiliar work.
- [PRODUCT.md](PRODUCT.md): promised behavior and V1 scope. Read before changing a user flow or assessing completeness.
- [CONTEXT.md](CONTEXT.md): canonical domain language. Read the relevant definitions before changing entities, names, or ownership.
- [ARCHITECTURE.md](ARCHITECTURE.md): authority, execution, recovery, and resource contracts. Follow its execution, workflow or resource topic links and affected ADRs before designing or implementing changes.
- [docs/style.md](docs/style.md): implementation discipline. Read before editing production code.
- [VERIFICATION.md](VERIFICATION.md): required evidence. Follow the matching topic contract before choosing tests or claiming a guarantee.

Load the sections needed for the task; follow their references when the decision depends on them. Keep detailed contracts in these owning documents.

## Establish the current contract

For issue-driven work, read the live issue, its discussion, and relevant dependencies. [V1 workstream #2](https://github.com/DivyanshGolyan/onepage/issues/2) is the entry point for current decision scope and readiness; discover the affected work from its live links. During design, keep open issues for decisions and research rather than speculative implementation slices. Accepted requirements belong in the owning normative documents. Create implementation issues when ready to implement the aligned V1 contract; link those sections and the slice-specific evidence instead of duplicating the specification. Closed superseded planning issues are historical evidence, not completed work or current implementation instructions.

Distinguish accepted design, unresolved proposals, and implemented behavior. Inspect source before making implementation claims. Requirements, unchecked acceptance criteria, and prototype measurements are not passing production evidence.

Accepted ADRs and normative documents define the documented contract. Issue resolution comments may record accepted amendments awaiting publication. When sources disagree, identify the exact conflict and accepted decision that resolves it. Treat unselected candidates and historical research as evidence. Leave unresolved product choices to the user while continuing work independent of them.

**Ready to change:** the intended behavior, affected owner, applicable decisions, and required evidence are identified. For a design decision, trace the motivating scenario through durable facts, temporary resources, and failure boundaries before choosing a representation.

## Make the change

Complete work authorized by the request, using reasonable assumptions for routine implementation choices. Follow explicit user scope over workflow defaults; distinguish investigating a decision from deciding it, and preparing a change from publishing it.

Inspect the working-tree diff before editing and preserve concurrent changes. Keep reviews read-only unless fixes are requested. Scope implementation to the selected task and its necessary dependencies.

When changing an accepted contract, update its owning document and affected references within the authorized scope. Keep terminology and verification aligned. Preserve historical records as historical evidence rather than rewriting them to imply the new design already existed.

## Verify and hand off

Use the applicable gates in [docs/style.md](docs/style.md) and [VERIFICATION.md](VERIFICATION.md); confirm command definitions in `build.zig`. Match verification to the changed behavior. Repeat or broaden checks only after changes, failures, or unresolved concerns justify it. Keep live provider checks opt-in.

For documentation-only changes, check references, consistency, and whitespace. Run `git diff --check` on the changed files. Report pre-existing failures separately.

**Done:** the requested result is complete, relevant checks have passed or their limits are stated, and the handoff explains what changed and the evidence supporting it. Describe unrun or interrupted checks accurately; keep implementation, prototype, and release-certification claims distinct.
