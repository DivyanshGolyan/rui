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

## Code Review Rules

PR reviewers, including Codex, apply [Review](CODING_STANDARDS.md#review); its **Simplify first** rule shapes every suggested correction.

## Contract enforcement

| Contract | Owning enforcement | Existing local and CI checks |
| --- | --- | --- |
| [Mutation presentation and admission truth](ARCHITECTURE.md#public-operations) | `cli.writeMutationReply` owns quiet Configure success and contextual errors through `MutationPresentation`. Configure records admission before output and always invokes that renderer. | `human_cli_integration.py` checks quiet success; `canonical_failure_integration.py` checks original context, binding/null failures and no resend. Both run in `check`. |
| [Original result and release deadlines](VERIFICATION.md#transport) | `model_fixture.wait_for_result_release` requires a deadline. Population callers create one deadline before their first result wait and forward it through all reads and global release. | `transport_h2_integration_test.py` drives shared, managed and seven population caller clocks; `host_process_test.py` drives the stop-receipt caller. Both run through existing build targets. |
| [Required native receipts](ARCHITECTURE.md#shared-optional-stderr) | `start_ready_process` selects native capture and crash-cut plans and external failure retention before launch. `HostDiagnostics` rejects optional authority for named required phases. | `host_process_test.py` rejects missing, duplicate, lost and optional-only receipts and verifies retention after root teardown; `check` runs it. |
| [Receipt versus publication retirement](VERIFICATION.md#native-owner-observations) | `crash_host` requires unsealed publication retirement within its original crash/reap budget. Ordinary teardown uses sealed `stop_process`; immutable final validity remains mandatory. | `host_process_test.py` holds delivered custody and injects a future writer through the actual crash caller; existing native publication holds remain in `check`. |
| [No-launch crash cut](VERIFICATION.md#native-owner-observations) | The existing opt-in prepared transition blocks before launch authority. `ReleaseGate.assert_held` requires the owned empty FIFO, independently of marker absence and observation retirement. | Native Bash integration retains the gated prelaunch crash and recovery; `host_process_test.py` rejects released, credited and replaced gates and verifies unlink-failure closure. |
| [Canonical fault fencing](ARCHITECTURE.md#canonical-state-and-transactions) | `enter` and `Access.finish`/`finishTransaction` in `src/store/Store.zig` own every locked Store entry point. Each declares the ordinary errors its body returns, checked at compile time; every other error from the body fences the Store before it returns. | `src/store/tests.zig` pins locking, fencing and classifier return to that owner and fences injected SQLite step faults on six entry points; `canonical_failure_integration.py` checks that a Host read fault fences instead of returning `result_not_found`. Both run in `check`. |
| [Caller diagnostics](ARCHITECTURE.md#help-and-prerequisites) | `caller_error.of`, its catalog and invocation-owned witnesses classify CLI failures; `tests/ci/caller_errors.py` inventories CLI-owned production errors and ratchets pending causes against the same scoped trusted-main inventory. | `test_caller_errors.py` rejects pending growth, raw caller error names and unmapped errors in CLI-owned sources, without catalog coupling to Host-internal owners; prepush and CI policy run the gate. |
| [Host stack budget](CODING_STANDARDS.md#host-stacks) | `tests/ci/stack_frames.py` and [stack_frames.json](tests/ci/stack_frames.json) own the ReleaseSafe frame budget, each Host thread's chain ceiling and the shrink-only exceptions. | `stack-frames` runs in `check`. `test_stack_frames.py` self-tests the gate and fails when an exception or ceiling grows past the trusted `origin/main` copy; the policy job runs it with the other `tests/ci` unittests. |
| [Primary failure and mandatory disposal](CODING_STANDARDS.md#evidence) | Shared process, held-endpoint, Control and Bash disposal owners attempt every cleanup and keep the original failure primary. | `host_process_test.py` injects disposal and retention failures; `transport_h2_integration_test.py` drives body/cleanup fault pairs and successful-body cleanup failure. Existing build targets run both. |

## Authority

User instructions outrank skill guidelines; Rui's owning documentation governs repository policy over generic skills.
Skills supply techniques, not authorization or contract homes.
Resolve conflicts on that basis before asking; cite the exact skill instruction if it would pause or divert work.

Resolve reversible choices within the accepted contract.
For unresolved consequential behavior, architecture or scope, missing access or authorization, complete independent authorized work first; present bounded options, a recommendation and machinery/failure consequences.

Own one implementation outcome through its applicable checks and authorized publication.
Advance without routine grants, candidate ledgers, evidence-adoption ceremonies, or frozen fixture policies.
Serialize actual shared-file, target-branch, or interfering native operations; independent work continues.
Historical failed attempts remain failures.

Outside the standing [Landing](#landing) grant, implementation approval alone does not authorize publication.
A request to create or update a PR authorizes pushing its relevant branch and maintaining that PR within the approved scope, including follow-up pushes for requested fixes, review findings and CI failures.
Carry that authorization across agent handoffs without asking again for each commit or correction.

Ask before publishing to a different destination, expanding scope, force-pushing or acting outside the approved outcome.
Deploying and closing issues still require explicit authorization.
Honor narrower user limits.

## Landing

Standing grant: land each small, coherent green change without further stage approval or waiting for lane completion.
Proof gates landing, not review signoff.
Known failed counterexamples require fixes and passing proof before the affected change merges.
Existing one-way-door approvals still apply.

- Changes reach `main` only by merging their PR; there is no other landing path.
- Every PR commit states its actual test commands and results, plus applicable performance A/B numbers.
  TUI changes also include a real-screen tmux capture.
  Each commit carries its owning lane's `Amp-Thread-ID: <thread URL>` trailer; inspect Amp's generated trailers and avoid duplicates.
  Preserve published source refs rather than rewriting them.
  Changing a commit message changes its SHA and invalidates its exact-head receipts.
- Before merging, the PR head must pass the Linux Selected aggregate, including mapped recovery checks.
  Strict paths add no Mac or upgrade gate to main.
  Missing, pending or red Mac checks delay only `stable`.
- [Auto-land](.github/workflows/auto-land.yml) fast-forwards `stable` to the newest main commit whose Mac Selected and Linux/macOS upgrade workflows passed on that exact SHA.
  Every stable candidate runs real Mac checks, full Debug admission recovery and upgrades even when its changed paths would select none.
  Missing or failed checks never qualify descendants; older completions never rewind stable.
  An open `stable-red` issue holds every promotion ([Landing cadence](VERIFICATION.md#landing-cadence)).
  Its promotion job is serialized, and it first dispatches any genuinely missing Mac or upgrade qualification for current main; existing pending, offline, failed or cancelled runs are never automatically retried.
- Run the independent review when [Review](CODING_STANDARDS.md#review) says; its signoff does not block green changes.
- A PR whose CI is green and whose Codex review is clean merges now.
  Green means the `linux` check on the PR's current head commit completed with success; pending, skipped, cancelled or a green run on an earlier head is not green, and main's ruleset requires it.
  Do not hold it for a local run of tests CI repeats (full `zig build test`, `check`, or a local mirror of Selected); [Evidence](CODING_STANDARDS.md#evidence) sets the focused pre-push checks.
  Ship post-merge fixes as follow-up PRs.
  Merge `origin/main` into a PR only when GitHub reports a conflict, then run `python3 tests/ci/prepush.py` and wait for that head's own CI: a merge commit is new content (#882 brought 2,129 untracked files in through one).
  A PR that merely trails main merges as it is; two PRs green on their own can still break main together (#768 and #769), and main's CI catches that.
  If main's CI then fails, fix it forward in a new PR.
- Never sit idle on CI or Codex, however long they take.
  Once a PR is pushed, start the next piece at once: independent work on a fresh branch from `origin/main`, dependent work on a branch stacked on the open one.
  Return to merge when the checks finish.
- Run PRs in parallel only when they touch different files.
  Work that shares a file with an open PR, in this lane or another, is dependent: stack it on that PR and land the stack in order.
  Before splitting work across lanes, check the open PRs for files the new work would touch.
- For work published as PRs, open a PR that depends on another after its base lands on `main`, rebased onto `origin/main`.
- Mac and upgrade qualification run after main advances; daily full runs remain backstops.
  Fix Mac reds forward on main; revert only if the fix is slow.
  Keep the previous stable until a newer main SHA qualifies.
- A red is fixed only when a commit between it and a later green changed its failing fixture or owner; a green without one leaves it open.
  A fixture-and-assertion signature that recurs on SHAs that did not touch its code has no culprit to revert: the agent that finds it updates or files one issue keyed by that signature and owns the race fix without weakening the assertion.
  Later green candidates do not close that issue; the fixing commit says `Fixes #N`, and a recurrence reopens it.
  When the bot files the issue, no agent finds it, so the coordinating agent hands it at once to the thread that owns its fixture.
  Every status names the stable hold, meaning the open `stable-red` issues and the hours since the last promotion, until it clears; `python3 tests/ci/stable_hold.py status` prints both, grouped by fixture.
  Before opening a fix, search the open `stable-red` issues for the touched fixture and write `Fixes #N` for each one it fixes; the policy job warns on a PR that touches a held fixture without `Fixes #N` or `Refs #N`.
- After ready, at most one rerun per item.
  Fixes for red CI retain the failure evidence.
- Install from `stable`, the last exact-SHA Mac-and-upgrade-qualified main commit.
  After each promotion, Auto-land dispatches [Release](.github/workflows/release.yml), which publishes the promoted SHA as version `0.S.N` with prebuilt archives.

After a diagnosed interruption that left current main's qualification absent, the agent that diagnosed it runs `GITHUB_REPOSITORY=DivyanshGolyan/rui python3 -B tests/ci/auto_land.py --qualify-main`.
It fills only absent runs; repeated calls preserve existing attempts and do nothing when main already equals stable.
Never run it while an Auto-land promotion job is running.
A later Auto-land run performs the same recovery in its serialized promotion job; after a runner failure, rerun that diagnosed Auto-land job, not the native qualification workflows.

Each main qualification explicitly dispatches Auto-land with its parent run ID because GITHUB_TOKEN suppresses downstream `workflow_run` events.
Auto-land validates the parent repository, main branch and qualification workflow, then uses `gh run watch` with a 120-second timeout and five-second kill grace outside the writer lock.
The parent ID only selects the wait; unchanged completed-workflow, exact-SHA and coverage checks decide promotion.
Wait failure or timeout skips that callback's writer.
The next promotion pass can pick up completed evidence.
There are no timers or automatic native-test retries.
To recover a lost completion without rerunning tests, use `gh workflow run auto-land.yml --ref main -f completed_run=<main-qualification-run-ID>`.

The strict paths are `src/store*`, every path under `src/store/`, `src/*schema*`, `src/server*`, `src/execution*`, `src/*recovery*`, `tests/integration/*recovery*`, `tests/integration/bash*`, `build.zig`, `build.zig.zon` and `install.sh`.
[strict_paths.py](tests/ci/strict_paths.py) owns this list for fail-without-retry handling.
A PR runs Linux [Selected checks](.github/workflows/check.yml), and a ready PR that changes a [Mac-specific path](tests/ci/platform_boundary.py) also runs Mac Selected; every main-tip stable qualification runs Mac Selected and the [upgrade check](.github/workflows/previous-release-upgrade.yml), regardless of strict paths.
