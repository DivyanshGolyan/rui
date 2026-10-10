# Working on Rui

Build the simplest complete runtime users can explain through ordinary work, failure and recovery. Prefer a coherent final design over the smallest diff; justify machinery by required behavior or demonstrated cost.

## Before work

Inspect the working-tree diff; preserve concurrent work. Read [README.md](README.md) for scope/status and affected [ARCHITECTURE.md](ARCHITECTURE.md) sections for accepted behavior.

Load applicable guidance before acting; routes combine:

- **Implement, design, debug, change builds, or review engineering:** [Engineering](CODING_STANDARDS.md#engineering).
- **Review, including documentation, or implement review findings:** [Review](CODING_STANDARDS.md#review). Reviews are read-only unless fixes are requested.
- **Implement or review performance changes:** [Performance](CODING_STANDARDS.md#performance), including build-latency exceptions.
- **Change documentation, terminology or decisions:** [Contract maintenance](CODING_STANDARDS.md#contract-maintenance). Load `writing-for-agents` before editing skills, this file or Markdown reached from it.
- **Implement, test, verify or report:** [Evidence](CODING_STANDARDS.md#evidence) and applicable [Verification](VERIFICATION.md) cases.
- **Select checks or change CI:** [Canonical gates](VERIFICATION.md#canonical-gates). Use the maintained subsystem mapping as the minimum, with reviewer-accepted reasons for reductions.
- **Issue work:** read the live issue, discussion and dependencies, then [issue guidance](docs/agents/issue-tracker.md) and [triage labels](docs/agents/triage-labels.md). Follow the latest accepted decision.
- **PR descriptions:** use `pr`.

## Authority

User instructions outrank skill guidelines; Rui's owning documentation governs repository policy over generic skills. Skills supply techniques, not authorization or contract homes. Resolve conflicts on that basis before asking; cite the exact skill instruction if it would pause or divert work.

Resolve reversible choices within the accepted contract. For unresolved consequential behavior, architecture or scope, missing access or authorization, complete independent authorized work first; present bounded options, a recommendation and machinery/failure consequences.

Own one implementation outcome through its applicable checks and authorized publication. Advance without routine grants, candidate ledgers, evidence-adoption ceremonies, or frozen fixture policies. Serialize actual shared-file, target-branch, or interfering native operations; independent work continues. Historical failed attempts remain failures.

Implementation approval does not authorize pushing, issue/PR mutations, closing, merging, deploying or other shared/irreversible effects. Obtain specific authorization.
