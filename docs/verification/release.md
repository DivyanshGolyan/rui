# Landing and release evidence

[Verification](../../VERIFICATION.md) owns shared evidence rules and the subsystem index.

## Landing cadence

`main` is the integration branch; `stable` and the latest release are what users run.
PRs open as drafts and become ready once Codex is clean, so selected CI runs once per reviewed head; [scheduled promotion](#scheduled-promotion) runs the expensive tier on `main` every three hours and publishes a green HEAD to users, and a manual promotion publishes a qualified commit.
GitHub must require pull requests and the GitHub Actions `admission` check on `main`, with no bypass; it does not require an up-to-date base.
Use squash merges under linear history.
A PR's checks qualify its merge with the base they ran on, so a green PR merges without rerunning after `main` moves.
Nothing runs on `main` per merge.
Two PRs that pass alone but break `main` together, by compilation or by a test, and a break the PR tier does not select, are caught by [scheduled promotion](#scheduled-promotion) within one three-hour tick, which names the batch commits suspected of each failed step and publishes nothing while HEAD is red.
The owner accepted, on 18 Nov 2026, that the fast PR tier lets more breaks reach `main` and that they are found there within hours.
A changed head requires current candidate checks before merge.

Before admission, a Store schema edit compiles every native and Store unit partition unfiltered on the exact candidate.
A branch that merged main gets only what its candidate's own diff selects; Scheduled and manual promotions compile every partition on main, so a merge that breaks only a unit partition is found there.
`ci_plan.py` widens `linux_compile_targets` with `test` only when the selected `test`, `check` or `check-full` closure does not already cover those partitions.
The single PR job compiles that selection; execution targets and live-engine obligations stay selected independently.
This is compilation, not execution of every unit test, and does not add portable `test-logic` unless that root is selected separately.
Required producers must succeed even when no product execution target was selected.

[Selected checks](../../.github/workflows/check.yml) qualify each ready PR's immutable merge candidate with the PR tier only: Linux compilation and the [fast tier](gates.md#two-tiers) of the affected Linux targets from [select_tests.py](../../tests/ci/select_tests.py), without whole-suite gates or live database servers.
[ci_plan.py](../../tests/ci/ci_plan.py) owns that tier and routes everything else to promotion: native macOS, `typecheck-macos`, the `stack-frames` oracle for a change outside Host source and build inputs, the previous installed-release upgrade, renderer contracts, the cache-execution proof and the Linux-memory collector checks.
The owner accepted on 18 Nov 2026 that a defect only those checks catch now surfaces at promotion, which the promotion's suspects report points at the batch, rather than on the PR; in the five days measured these checks took about 48% of PR runner-minutes.
The selector still computes the [Mac paths](../../tests/ci/platform_boundary.py) and the upgrade and `typecheck-macos` obligations; on a PR they only keep a change out of the documentation lane.
Promotion selects them over its whole batch: native Mac runs its core targets plus the batch's selection, `typecheck-macos`, cache execution and Linux memory run when the batch touches their paths.
Scheduled promotion applies that selection to each batch since `stable`, so every merge that touches compile inputs is type-checked for macOS within hours.
Darwin-only linking and settings live in `build/darwin.zig`, a Mac path.
The [previous installed-release upgrade](../../.github/workflows/previous-release-upgrade.yml) runs on both systems in every promotion.
In the same job and suite, `--running-host` starts the pinned v0.88.0 release on a private Store, saves a completed provider answer and Session configuration, and leaves the Host running while the candidate's rendered `release/install.sh` runs.
In a promotion the candidate is that promotion's own release executable; elsewhere it is the existing `upgrade-fixture` production actor with a synthetic numeric release identity (ordinary untagged source builds report `unreleased`). Archive transport is local, but checksum verification, extraction, publication and restart use the real release installer.
The installer must exit 0 and name that Store's restart; without any subsequent start/restart command, status must report a new instance and the socket peer's executable must be the selected candidate and report its release version.
The saved answer, request binding and configuration must survive without another provider request.
The pinned v0.88.0 Host speaks wire 22, so this also gates observation of a Host on another wire through its own executable (`host status`) and authenticated socket-probe discovery before exact-instance pause/replacement.
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

### Scheduled promotion

[Promote](../../.github/workflows/promote.yml) runs every three hours, with empty inputs, so it promotes main HEAD.
When [stable](#promote) already holds HEAD it does nothing.
When HEAD has a red `main-qualified` record it skips qualification, since the failing run filed its issues under its own label (`main-red` when scheduled, `promotion-red` by hand).
The scheduled run then fails with a `main HEAD failed qualification` error that names the red run and the way out: merge a fix to main, or, for a flake or infrastructure red, rerun that run's failed jobs with `gh run rerun <id> --failed`, which reruns the `qualified` recorder and rewrites the record.
While the red stands, an infrastructure failure in `dependency_lag` or `race_sweep` is not retried automatically, since the run already has a check failure in `batch`; infra-retry never reruns the scheduled run either.
Otherwise it qualifies HEAD, or publishes the archives of HEAD's green record, exactly as a manual promotion does below, and a green HEAD that main has moved past since the last release becomes a release without anyone dispatching it.
The batch runs from `stable`, the last promoted commit, so a failing step's suspects are the commits since the last release.
A failing job files or updates one `main-red` issue per cause, with its failed steps' suspects on it; a manual promotion files `promotion-red` instead.
Setting the repository variable `SCHEDULED_RELEASES` to `paused` (`gh variable set SCHEDULED_RELEASES --body paused`) holds scheduled publication: scheduled runs still qualify HEAD and record its verdict, and a manual promotion publishes a green record's archives; deleting the variable resumes it.
Every run records its verdict as the `main-qualified` commit status of HEAD, whose target is the run: green only when every tier passed, red when one failed, and unfinished when a tier was cancelled, which the next tick qualifies again.
[main_qualified.py](../../tests/ci/main_qualified.py) alone writes and reads that record and names the batch.
Runs never overlap: the `promote` concurrency group queues a newer run behind the current one, so an idle `main` whose HEAD is already in `stable` costs one short job per tick.
A rerun of its failed jobs records the rerun's verdict on the same SHA.
Scheduled and manual runs share that queue, so neither cancels a running promotion, but GitHub keeps only one waiting run per group: a newer tick or dispatch replaces a waiting one.
A scheduled tick that replaces a waiting dispatch promotes main HEAD, as a default dispatch would; dispatch again after the running promotion when the replaced one named a `sha`.

### Promote

[Promote](../../.github/workflows/promote.yml) is the only path to a release. It starts on the [schedule](#scheduled-promotion) for main HEAD, and by hand on `main`: `gh workflow run promote.yml --ref main`.
It publishes main HEAD by default; `-f sha=<commit>` names a first-parent `main` commit after `stable`, and `-f sha=qualified` the newest one with a green record.
When that commit's `main-qualified` record is green, its run still holds the release archives, and the release plan still gives the version that run built, Promote publishes those archives at once and qualifies nothing.
A red record refuses a manual promotion: fix forward and promote a later commit, or promote an earlier green one.
Otherwise only main HEAD can be promoted, and Promote qualifies it as below and records the verdict on it, so the next scheduled run skips it, and fails naming its run while it is red.
Promote is the sole caller of the one owner of the tier and its verdict, [qualification-tier.yml](../../.github/workflows/qualification-tier.yml): it builds and tests, records `main-qualified` and files issues under the label Promote passes (`main-red` on schedule, `promotion-red` by hand), and Promote publishes after it. Its jobs appear as `qualify / <job>`.
Promote qualifies main HEAD against the batch since `stable`, the last promoted commit, and runs everything the PR tier skips: Linux and macOS `check-full`, `test-logic` and full Debug admission recovery with the batch's selected targets, `stack-frames`, Linux `mysql-wire-integration`, the upgrade check on both systems and the renderer contracts.
A failing suite, upgrade or contract job ranks suspects for each step that failed without replaying anything: the batch's first-parent commits whose changed lines name identifiers in the step's failing output (test names, assertion and file references; plain words do not count), most shared first, then the commits that the selector maps to that step's targets, most direct first (a commit owning the target's own source or script, then one whose import, link or path rule reaches it, then one only a fallback selects), newer first within a tier; the top five, each with its PR number, the reason it ranks and the touched files that match.
A manual bisect, dispatched on [Promote](../../.github/workflows/promote.yml) with `bisect-step` and a range, replays one named step by binary search over the batch's first-parent commits on Linux, with a 90-minute budget shared across its replays. The step must name build targets at HEAD (a script's step such as `pty` has no `zig build` command, so the dispatch refuses it); the job's setup takes those targets, and the setup action installs what they need. The bisect runs in its own `promote-bisect` concurrency group, so it never waits on or holds up a promotion, and its job's limit is 240 minutes. Its setup restores caches only, and it rewrites `verdict.json` after each step finishes, so a killed job keeps the steps it completed.
Once it runs out, no new replay starts, though a running replay finishes, and the cut-short step names the narrowed range rather than a commit.
A step the budget ran out on before its HEAD replay says so and points to its log.
The report prints the tail of each failed step's output beside its suspects, each line prefixed `Promotion excerpt:` so the issue filer does not parse it; the issue carries the suspects only. A commit the selector cannot read stays listed last as unattributed rather than hiding the others. A step that is not a build target says `not a selector target; read its log`.
A step is one suite batch, one upgrade check or one contract; a suite job stops at its first failed batch, and [steps.py](../../tests/ci/steps.py) runs every upgrade check and contract even after one fails.
Each failed step's suspect lines name the commits to read first, and a suspect is a candidate rather than a verdict; a manual bisect's verdict names the first failing commit, says the red did not reproduce at HEAD, or says it already fails at `stable`, and its replay logs are retained with the run.
Two failed steps get separate suspect lists; the job's issues carry every suspect line, and a job with several causes says so.
The run then files one `promotion-red` issue (`main-red` when scheduled) per failure signature through [report_issue.py](../../tests/ci/report_issue.py), with the suspects on it.
Each new issue carries an `escape:<class>` label and an `Escape class` line saying why the ready PR tier did not catch the failure.
The classes are `own-files:<target>`; `promotion-only:<target>` for a target the PR tier never runs (today only `rsql-table`), or bare `promotion-only` for a whole-tier job (the renderer contracts, the release build, cache execution); `live-mysql`, which comes only from the failing cause's own text naming MySQL, with `:<target>` when a target is named; `macos`; `upgrade`; `pr-tier`; `cold-cache-timeout`; and `unknown`.
`pr-tier` means the PR tier did run the check, so its selection or a combination of tests let the failure through; a target the PR tier runs is `pr-tier` even where promotion also runs it.
A `check-full` failure that names no target is `unknown`.
An infrastructure red, as [failure_cause.py](../../tests/ci/failure_cause.py) classifies it, carries no escape class.
[report_issue.py](../../tests/ci/report_issue.py) classifies from the owners in [select_tests.py](../../tests/ci/select_tests.py), and the label is the record: relabelling an issue changes the class its recurrences show.
A new issue whose class a selection rule can fix (`own-files`, `promotion-only`, `live-mysql`, `macos`, `upgrade`) repeats when an issue with the same label was created within 14 days; the filer then comments on that issue and adds `escape-repeat`, which asks for a narrow `select_tests` rule.
The comparison uses only the issues that existed before the run, so two new causes of one class in one run never flag each other.
Issues filed before this change carry no escape label, so repeats start counting only after it lands.
A red promotion publishes nothing and leaves `stable` where it is; fix forward on `main` through ordinary PRs and promote again.
A suspect list never turns a promotion green, and a promotion never merges or reverts.
From the start, beside the suites, [Release build](../../.github/workflows/release-build.yml) numbers the release and builds the cold versioned archives of main HEAD; it publishes nothing.
The upgrade check and renderer contracts test those release executables instead of compiling their own ReleaseSafe Rui (`-Drui-under-test` and the upgrade's `--candidate-release`); the upgrade check's source install still compiles the candidate, and a manual bisect of a selected target compiles each commit's own Rui.
A failed release build fails the promotion.
Only when every tier passes, here or in the run that qualified the commit, does it call [Release](../../.github/workflows/release.yml) with the qualified SHA, the planned version and the run holding the archives, to publish them; it never rebuilds.
The owner accepted, on 18 Nov 2026, that a release build now runs before qualification decides and that a release-only failure surfacing in the tested executable is named by its suspects, with source builds to check them.
The publisher owns release identity, schema compatibility checks, complete assets and monotonic publication.
It accepts only a commit on `main`; an arbitrary PR ref cannot publish.
The `stable` branch remains a non-rewinding pointer to the last successfully published, promoted release.
Promote when something users need has landed; with a green record that takes minutes.
Ranking suspects costs no replay, and a manual bisect of a batch of about 22 merges costs at most five replays of a failing target.
No completion callback or global open-issue hold owns `stable`.

[Scheduled promotion](#scheduled-promotion) is the only scheduled CI workflow, and the schedule is the only automatic trigger of a release.
Manual qualification and resource campaigns remain diagnostics, not a second release authority.
Record recurring failures by fixture and assertion, preserve their counterexamples, and close them through the fixing commit.
An unrelated issue does not freeze publication of qualified main commits.
Report native architecture, skips and unrun cases; cross-compilation and skips are not native passes.
Keep cleanup and resource bounds, and do not retry failed required acceptance to obtain a pass; only a [listed flake](gates.md#listed-flakes) reruns, and only its listed signature may fail then pass.

## Release publication

[Release](../../.github/workflows/release.yml) runs only inside a green [promotion](#promote) and publishes the immutable main SHA qualified for it, from the archives the qualifying run's [Release build](../../.github/workflows/release-build.yml) made and its tiers tested: the promotion's own run, or the earlier scheduled or manual promotion run its green record names.
Release build records `SHA256SUMS` for every archive and npm tarball when it packs them; publication checks the downloaded files against that record and publishes it, so a byte that changed after the tests cannot ship.
Only verified publication advances the `stable` pointer.
To recover an interrupted publication, rerun the promotion's failed jobs: `gh run rerun <promotion run id> --failed`.
When every failure of a promotion's first attempt was infrastructure, such as a macOS job GitHub never gave a runner, [Retry infrastructure failures](gates.md#ci-artifacts-and-caches) does this once automatically.

After publishing, Release rechecks the [wire-version gate](../../tests/ci/test_wire_version.py) on open wire-changing PRs: [recheck_wire_prs.py](../../tests/ci/recheck_wire_prs.py) reruns `policy` (on a ready PR, the single `linux pr` job that runs the policy checks), and so `admission`, on each open, non-draft PR based on main that touches `openapi.json` or `src/wire_version.zig` and whose latest check ran before publication.
A red recheck step means the release did ship; its error names each PR it could not recheck and why.
Do not rerun the promotion for it: push to each named PR, or rerun that PR's `policy` job; a PR whose run is past GitHub's 30-day rerun limit needs a push.

[release.py](../../tests/ci/release.py) skips a SHA only when a verified public release already includes it, and can repair a missed pointer update without rebuilding.
Drafts and orphan tags reserve a version for their exact SHA; recovery reuses that identity rather than skipping incomplete publication.
A newer main SHA gets a newer version; one release covers a whole promotion batch.
Each platform's native runner builds the tagged commit with empty caches and ReleaseSafe, in Release build before qualification.
Its archives live as run artifacts for seven days, so a promotion's failed jobs must be rerun within that window, and a commit an earlier promotion qualified publishes without rebuilding for that long, less two hours' margin; after that Promote qualifies main HEAD again.
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
No hosted job checks a trace. Hosted runs of a released archive are the promotion's upgrade check (host launch and the running-Host upgrade), its renderer contracts and that Host memory measurement.
