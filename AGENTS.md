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

## Contract enforcement

| Contract | Owning enforcement | Existing local and CI checks |
| --- | --- | --- |
| [Mutation presentation and admission truth](ARCHITECTURE.md#public-operations) | `cli.writeMutationReply` owns quiet Configure success and contextual errors through `MutationPresentation`. Configure records admission before output and always invokes that renderer. | `human_cli_integration.py` checks quiet success; `canonical_failure_integration.py` checks original context, binding/null failures and no resend. Both run in `check`. |
| [Original result and release deadlines](VERIFICATION.md#transport) | `model_fixture.wait_for_result_release` requires a deadline. Population callers create one deadline before their first result wait and forward it through all reads and global release. | `transport_h2_integration_test.py` drives shared, managed and eight population caller clocks; `host_process_test.py` drives the capture caller. Both run through existing build targets. |
| [Required native receipts](ARCHITECTURE.md#shared-optional-stderr) | `start_ready_process` selects native capture and crash-cut plans and external failure retention before launch. `HostDiagnostics` rejects optional authority for named required phases. | `host_process_test.py` rejects missing, duplicate, lost and optional-only receipts and verifies retention after root teardown; `check` runs it. |
| [Receipt versus publication retirement](VERIFICATION.md#native-owner-observations) | `crash_host` requires unsealed publication retirement within its original crash/reap budget. Ordinary teardown uses sealed `stop_process`; immutable final validity remains mandatory. | `host_process_test.py` holds delivered custody and injects a future writer through the actual crash caller; existing native publication holds remain in `check`. |
| [No-launch crash cut](VERIFICATION.md#native-owner-observations) | The existing opt-in prepared transition blocks before launch authority. `ReleaseGate.assert_held` requires the owned empty FIFO, independently of marker absence and observation retirement. | Native Bash integration retains the gated prelaunch crash and recovery; `host_process_test.py` rejects released, credited and replaced gates and verifies unlink-failure closure. |
| [Canonical fault fencing](ARCHITECTURE.md#canonical-state-and-transactions) | `Store.enter` and `Access.finish`/`finishTransaction` own every locked Store entry point. Each declares the ordinary errors its body returns, checked at compile time; every other error from the body fences the Store before it returns. | `store.zig` pins locking, fencing and classifier return to that owner and fences injected SQLite step faults on six entry points; `canonical_failure_integration.py` checks that a Host read fault fences instead of returning `result_not_found`. Both run in `check`. |
| [Primary failure and mandatory disposal](CODING_STANDARDS.md#evidence) | Shared process, capture, Control, H1 and Bash disposal owners attempt every cleanup and keep the original failure primary. | `host_process_test.py` injects disposal and retention failures; `transport_h2_integration_test.py` drives body/cleanup fault pairs and successful-body cleanup failure. Existing build targets run both. |

## Authority

User instructions outrank skill guidelines; Rui's owning documentation governs repository policy over generic skills. Skills supply techniques, not authorization or contract homes. Resolve conflicts on that basis before asking; cite the exact skill instruction if it would pause or divert work.

Resolve reversible choices within the accepted contract. For unresolved consequential behavior, architecture or scope, missing access or authorization, complete independent authorized work first; present bounded options, a recommendation and machinery/failure consequences.

Own one implementation outcome through its applicable checks and authorized publication. Advance without routine grants, candidate ledgers, evidence-adoption ceremonies, or frozen fixture policies. Serialize actual shared-file, target-branch, or interfering native operations; independent work continues. Historical failed attempts remain failures.

Implementation approval alone does not authorize publication. A request to create or update a PR authorizes pushing its relevant branch and maintaining that PR within the approved scope, including follow-up pushes for requested fixes, review findings and CI failures. Carry that authorization across agent handoffs without asking again for each commit or correction.

Ask before publishing to a different destination, expanding scope, force-pushing or acting outside the approved outcome. Merging, deploying and closing issues still require explicit authorization. Honor narrower user limits.
