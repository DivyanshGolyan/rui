# Landing and release evidence

[Verification](../../VERIFICATION.md) owns shared evidence rules and the subsystem index.

## Landing cadence

`main` is the integration branch; `stable` and the latest release are what users run.
PRs open as drafts and become ready once Codex is clean, so selected CI runs once per reviewed head; a manual promotion runs the expensive tier on a batch of merged commits before it reaches users.
GitHub must require pull requests and the GitHub Actions `admission` check on `main`, with no bypass; it does not require an up-to-date base.
Use squash merges under linear history.
A PR's checks qualify its merge with the base they ran on, so a green PR merges without rerunning after `main` moves.
The [main build](../../.github/workflows/main-build.yml) compiles `main` after every merge without running a test (each gate, every unit root, ReleaseSmall and `typecheck-macos`), so two PRs that pass alone but no longer compile together turn it red within one build.
While it is red it keeps one open `ci-red` issue naming the PRs merged since its last green build, and its next green build of main HEAD closes that issue (a rerun of an older build changes nothing); it is never a required check.
Two PRs that break only a test together are caught by promotion, which qualifies main HEAD and bisects to the commit that broke it.
A changed head requires current candidate checks before merge.

Before admission, a Store schema edit or a branch that merged main since its merge base compiles every native and Store unit partition unfiltered on the exact candidate.
The selector checks the published branch's merge history against the candidate's base, excluding the synthetic candidate merge itself.
`ci_plan.py` widens `linux_compile_targets` with `test` only when the selected `test`, `check` or `check-full` closure does not already cover those partitions.
The existing Linux producers and artifact restore share that compile selection; execution targets, matrices and live-engine obligations stay selected independently.
This is compilation, not execution of every unit test, and does not add portable `test-logic` unless that root is selected separately.
Required producers must succeed even when no product execution target was selected.

[Selected checks](../../.github/workflows/check.yml) qualify each ready PR's immutable merge candidate with the PR tier only: Linux compilation and the affected Linux targets from [select_tests.py](../../tests/ci/select_tests.py).
[ci_plan.py](../../tests/ci/ci_plan.py) owns that tier and routes everything else to promotion: native macOS, `typecheck-macos`, the `stack-frames` oracle, the previous installed-release upgrade, renderer contracts, the cache-execution proof and the Linux-memory collector checks.
The owner accepted on 18 Nov 2026 that a defect only those checks catch now surfaces at promotion, which bisects the batch, rather than on the PR; in the five days measured these checks took about 48% of PR runner-minutes.
The selector still computes the [Mac paths](../../tests/ci/platform_boundary.py) and the upgrade and `typecheck-macos` obligations; on a PR they only keep a change out of the documentation lane.
Promotion selects them over its whole batch: native Mac runs its core targets plus the batch's selection, `typecheck-macos`, cache execution and Linux memory run when the batch touches their paths, and the main build type-checks macOS after every merge.
Darwin-only linking and settings live in `build/darwin.zig`, a Mac path.
The [previous installed-release upgrade](../../.github/workflows/previous-release-upgrade.yml) runs on both systems in every promotion.
In the same job and suite, `--running-host` starts the pinned v0.69.1 release on a private Store, saves a completed provider answer and Session configuration, and leaves the Host running while the candidate's rendered `release/install.sh` runs.
The candidate is the existing `upgrade-fixture` production actor with a synthetic numeric release identity (ordinary untagged source builds report `unreleased`); archive transport is local, but checksum verification, extraction, publication and restart use the real release installer.
The installer must exit 0 and name that Store's restart; without any subsequent start/restart command, status must report a new instance and the socket peer's executable must be the selected candidate and report its release version.
The saved answer, request binding and configuration must survive without another provider request.
The real v0.69.1 Host has neither the later `chatgpt` route fact nor a Store hint beside its socket, so this also gates historical wire-13 fact normalization and authenticated socket-probe discovery before exact-instance pause/replacement.
Startup, install, observation and cleanup are bounded; failures stop both the known previous child and any candidate Host, retain private diagnostics only in the job's artifact directory, and otherwise remove the fixture root after confirmed lease release.
The historical source pin still tests stopped-Store unsupported-format refusal separately.
For a Store format change, run `python3 tests/ci/schema_number.py --check`, exercise the affected migrations with `-Dtest-filter`, and remove the new step's statements as a negative control. Ready CI supplies the unfiltered compile described above. Existing main digest rows and steps stay unchanged. Format 70's wire-label tests cover the exact one-statement step on both dialects and populated wire-13 SQLite reopen; its live MySQL witness requires a configured server. Format 74's tests cover the label's deletion on both dialects, a new Store without one, reopening without one, a populated format-73 SQLite Store whatever its label reads, and older formats still migrating; the MySQL witnesses require a configured server. Format 75's pin migration tests preserve populated Commands and stop references, create empty canonical pin objects, accept the new kind, retain nullable current pointers, and reopen through production SQLite admission. Its MySQL witnesses cover both a fresh format-74 shape and historical upgrades, plus absent and ambiguous kind-CHECK refusal before DDL. Run with a configured MySQL server; a skip is not proof.
The documentation lane skips heavyweight policy, product builds and suites.
It requires a successful plan with canonical empty product outputs and a successful Linux aggregate that verifies all product producers were skipped.
The allowlist reads committed Git paths and modes against the selector's resolved base and candidate; any selected runtime, native, cache or resource obligation restores normal verification.
Reference and consistency checks remain reviewed evidence, not automated link validation.
The always-run `admission` aggregate requires the exact results for the declared change kind; on a PR the Mac and cache-execution jobs must be skipped.
Failed, cancelled, missing or unexpectedly skipped required jobs do not qualify a candidate, and an unselected Mac job must be skipped.
A draft PR runs only the plan (candidate, `git diff --check` and selection summary) and cheap aggregates; policy, builds and suites are skipped.
The plan owns draft routing without changing the diff's documentation/normal classification; readiness computes a fresh full selection.
Draft checks never satisfy `admission`.
Local `prepush.py` supplies cheap feedback only; [landing](../agents/landing.md#publish-and-merge) keeps current-candidate admission and clean Codex evidence as merge gates.
Correctness failures are fixed on the PR before it reaches `main`.

[Promote](../../.github/workflows/promote.yml) is the only path to a release, and it starts only by manual dispatch on `main`: `gh workflow run promote.yml --ref main`.
It qualifies main HEAD against the batch since `stable`, the last promoted commit, and runs everything the PR tier skips: Linux and macOS `check-full`, `test-logic` and full Debug admission recovery with the batch's selected targets, `stack-frames`, the upgrade check on both systems and the renderer contracts.
A failing suite, upgrade or contract job bisects each step that failed, on the same runner, by replaying that step's recorded command: once at HEAD, then by binary search over the batch's first-parent commits.
A step is one suite batch, one upgrade check or one contract; a suite job stops at its first failed batch, and [steps.py](../../tests/ci/steps.py) runs every upgrade check and contract even after one fails.
Each step's verdict names the first commit where it fails, or says the red did not reproduce at HEAD or already fails at `stable`; replay logs and the verdicts are retained with the run.
Two steps broken by different commits get different verdicts, but a suite batch with several causes names only its earliest; the job's issues carry every verdict line.
The run then files one `promotion-red` issue per failure signature through [report_issue.py](../../tests/ci/report_issue.py), with the verdict on it.
A red promotion publishes nothing and leaves `stable` where it is; fix forward on `main` through ordinary PRs and promote again.
A bisect never turns a promotion green, and a promotion never merges or reverts.
Only when every tier passes does it call [Release](../../.github/workflows/release.yml) with the qualified SHA for cold versioned builds and publication.
The publisher owns release identity, schema compatibility checks, complete assets and monotonic publication.
It accepts only a commit on `main`; an arbitrary PR ref cannot publish.
The `stable` branch remains a non-rewinding pointer to the last successfully published, promoted release.
Promote when something users need has landed; a batch of about 22 merges costs at most five replays of a failing target to bisect.
No completion callback or global open-issue hold owns `stable`.

There are no scheduled CI workflows.
Manual qualification and resource campaigns remain diagnostics, not a second release authority.
There is no automatic promotion trigger.
Record recurring failures by fixture and assertion, preserve their counterexamples, and close them through the fixing commit.
An unrelated issue does not freeze publication of qualified main commits.
Report native architecture, skips and unrun cases; cross-compilation and skips are not native passes.
Keep cleanup and resource bounds, and do not retry failed required acceptance to obtain a pass; only a [listed flake](gates.md#listed-flakes) reruns, and only its listed signature may fail then pass.

## Release publication

[Release](../../.github/workflows/release.yml) runs only inside a green [promotion](#landing-cadence) and publishes the immutable main SHA that promotion qualified.
Only verified publication advances the `stable` pointer.
To recover an interrupted publication, rerun the promotion's failed jobs: `gh run rerun <promotion run id> --failed`.
When every failure of a promotion's first attempt was infrastructure, such as a macOS job GitHub never gave a runner, [Retry infrastructure failures](gates.md#ci-artifacts-and-caches) does this once automatically.

After publishing, Release rechecks the [wire-version gate](../../tests/ci/test_wire_version.py) on open wire-changing PRs: [recheck_wire_prs.py](../../tests/ci/recheck_wire_prs.py) reruns `policy`, and so `admission`, on each open, non-draft PR based on main that touches `openapi.json` or `src/wire_version.zig` and whose latest check ran before publication.
A red recheck step means the release did ship; its error names each PR it could not recheck and why.
Do not rerun the promotion for it: push to each named PR, or rerun that PR's `policy` job; a PR whose run is past GitHub's 30-day rerun limit needs a push.

[release.py](../../tests/ci/release.py) skips a SHA only when a verified public release already includes it, and can repair a missed pointer update without rebuilding.
Drafts and orphan tags reserve a version for their exact SHA; recovery reuses that identity rather than skipping incomplete publication.
A newer main SHA gets a newer version; one release covers a whole promotion batch.
Each platform's native runner builds the tagged commit with empty caches and ReleaseSafe.
The targets are portable: a baseline CPU, glibc 2.34 on Linux and macOS 15 on Apple Silicon.
Each build must report the version and exact SHA from `rui --version`.
The Linux executables are stripped, and their debug info ships as a separate `-debug` archive that crash traces read once it is extracted beside them.
The release attaches the archives, `SHA256SUMS` and an `install.sh` that pins the archive digests.
Before publishing, the publish job measures the released linux-x86_64 executable with [host_memory.py](../../tests/ci/host_memory.py) from the release's own source and adds its table to the release notes, so Host memory can be tracked release by release.
Each scenario in its `SCENARIOS` list is one row: a fresh Host brought to one state by the `tests/integration` fixtures without network, its `/proc/PID/smaps_rollup` field read once it stops changing, over a fixed number of runs, reported as median and range in KiB with the runner's image, CPU, kernel and glibc.
The rows are an empty Host and 100 agents waiting on the model (`Private_Dirty`), and a Host holding an OpenAI model listing or an MCP `tools/list` open at start (`Anonymous`); a feature adds a row by adding an entry.
Numbers compare only release to release on the same runner type, and nothing fails on them: a scenario that cannot be measured says `not measured` with its reason in its row, and a measuring step that fails or passes its five minutes leaves one `not measured` line, never a failed release.
`test_host_memory.py` checks the table and the `not measured` path; only a real release run measures on the hosted runner.

`test_release.py` uses fake archives.
It covers version planning, template filling with the shared publication fragment, every report state (first install, update, reinstall, Store format change, Host and `PATH` states) and the installer's update, digest, version and preservation behavior.
`host-status-integration` checks the fragment's reading of the real `defaults inspect` output.
One manual check installed tagged archives through the filled installer on macOS 15, and under dash on Ubuntu 22.04 x86-64 with glibc 2.35.
Debian 11, with glibc 2.31, refuses to load the Linux build.
Another manual check built the Linux release, ran the stripping step, extracted the debug archive into an installer-shaped build, and sent `rui host serve` SIGSEGV: the trace showed source lines, and without the debug files it showed `???`.
No hosted job checks a trace; the only hosted run of a released archive is that Host memory measurement.
