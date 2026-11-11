# Verification

[ARCHITECTURE.md](ARCHITECTURE.md) owns behavior.
This document owns required evidence: the gates below and the [contract index](#contract-index).
Test production interfaces and real SQLite transactions against independent expectations.
Crash tests kill a fixture process and reopen in a fresh one; injected returned errors are fault tests.
Record revision, machine, dependencies, inputs and measurements.
Prototypes, source inspection and compilation are not production qualification; [research evidence](research/README.md) records those limits.
Git history keeps earlier test specifications and dated results.

## Canonical gates

Integration fixtures require Python 3.11 or newer on PATH, with the packages pinned in [tests/integration/requirements.txt](tests/integration/requirements.txt) (python-h2 serves every loopback fixture over h2c); the composed driver rejects older interpreters and records the one selected.
PTY fixtures read the screen through libghostty-vt, from the test-only package in [screen-emulator](screen-emulator/build.zig.zon); build.zig builds it with a child `zig build` for the steps that run the observer and names it in `RUI_TEST_GHOSTTY_VT`.
The first such step fetches its pinned release tarball and packages into `screen-emulator/zig-pkg` and takes a few minutes; installs never fetch it.
On macOS, do not use `/usr/bin/python3`.
Diagnose interpreter failures apart from product assertions.

Run fixtures as a non-root user.
Root bypasses the file and socket permission denials that fixtures assert, so a root run fails them or proves nothing.
Every fixture entry enters the boundary in [host_process.py](tests/integration/host_process.py) before it starts anything.
A Python fixture calls `host_process.enter()` first in its main block.
Anything else runs through `python3 tests/integration/host_process.py exec COMMAND...`, which enters and then executes the command: `admission_integration.sh` re-enters itself this way, `check.sh` runs its native test binary this way, and build.zig runs every Go `measure-*` step this way.
`check.sh` also enters once before any case starts.
Entering stops a root process with that instruction, whether a build step or a person launched it.
It also replaces the process environment with the variables `INHERITED` names there (PATH, HOME, TMPDIR, locale and named fixture inputs, each with its reason) plus `TERM=xterm-256color`, so a caller's `RUI_*`, TLS trust or proxy settings cannot change what a fixture proves.
A fixture sets its own variables after entering, and its children inherit only those.
Importing host_process changes nothing, so tests/ci and fixture libraries can use it freely.
`FixtureEntryTest` in [test_harness_contracts.py](tests/ci/test_harness_contracts.py) finds every fixture entry (each shell script, and each Python module with a main block), runs it with root simulated and requires that refusal.
It also requires that every `measure-*` step goes through the exec entry.
Where the shell is root, as in many containers, use an ordinary account that owns its checkout, Zig caches and Python environment.

A fixture starts every process on a PTY through `spawn` in [terminal_process.py](tests/integration/terminal_process.py), never `subprocess.Popen`.
`spawn` runs the process as the foreground job of a session leader that owns the PTY ([terminal_leader.py](tests/integration/terminal_leader.py)), as a terminal's shell runs a program: `/dev/tty` is that PTY, and the PTY keeps the job's termios after it exits.
The process is never a session leader itself, because on macOS a session leader's exit revokes its terminal and resets the termios that restoration checks compare.
Closing the master hangs up the job, and so does the fixture's exit.
`spawn` takes Popen's arguments except `preexec_fn`; pass `default_signals=` and `rlimits=` instead.
An ignored signal stays ignored in the job, as in a Popen child, so a case that sends ^C passes `default_signals=(signal.SIGINT,)`.
The screen observer is the only terminal that answers the process's queries (DA1, DECRQM, OSC 11 and the rest libghostty-vt answers); `answers_to` in terminal_process.py sends each answer to the PTY the process reads.
A capture made with no `reply` is a silent terminal, for a fixture that answers that terminal itself.

| Change class | Required gate or evidence |
| --- | --- |
| Documentation | Review references and consistency. The plan runs `git diff --check` on the committed candidate diff. Only nonempty, exclusively allowlisted regular nonexecutable documentation and asset changes qualify for the [documentation lane](tests/ci/docs_only.py); executable, unknown and mixed changes keep normal verification. Source sentence layout remains optional |
| Runtime behavior | Subsystem mapping below on the PR head for Linux main acceptance; Mac mapping and full Debug recovery on the exact main SHA before stable promotion. A skip is not evidence |
| Build or dependency | Linux `check-full`, `typecheck-macos` and mapped checks before merge; macOS `check-full` in promotion; manual empty-cache acceptance |
| Resource owner | Comparable measurements and lifecycle evidence on applicable runners |

The executable minimum is [select_tests.py](tests/ci/select_tests.py), using targets from [build.zig](build.zig) and its modules under `build/`.
An edit to `build.zig`, `build.zig.zon` or a hub module (`build/product.zig`, the Rui every target builds, and `build/ci.zig`, the CI artifact handoff) selects the full build gate; an edit to another module under `build/` selects only the targets its `BUILD_MODULES` entry names, which include every target it defines.
CI runs `python3 tests/ci/select_tests.py --base origin/main --phase review` on the pushed head.
Run it locally only to diagnose a CI red; [Evidence](CODING_STANDARDS.md#evidence) lists the pre-push checks.
The selector reads the import graph of the tree it runs on: Zig `@import` and `@embedFile`, and the Python imports and `src/` reads of `tests/integration`.
A changed file selects each unit root that compiles it and each process fixture whose scripts use it or whose driven owners (`FIXTURES`) reach it, and the Host's dispatch into them.
A changed production `src/` file also selects fixtures whose Python or shell scripts contain a literal (including f-string constant parts) present in that file's quoted or Zig multiline string bodies at base or head, limited to at least 12 stripped characters containing a space and occurring in string bodies in fewer than three production `src/` files in the selector's working tree (counted only for prose found in changed files).
A functional core listed in `src/logic_tests.zig` selects only its unit roots and the fixtures that name it as an owner.
`RULES` add what no import names: C sources, generators, non-Zig consumers and fixtures that probe an owner from outside.
A selection that holds every case `check` runs becomes `check`; source that neither the graph nor a rule names falls back to `check`.
Promotion runs every fixture, so an edge the graph misses surfaces there and is added to `FIXTURES` or `RULES`.
Long, churn, full Debug and H2 targets follow their mappings, not an unconditional per-PR gate.

| Subsystem | Landing-tip minimum | Exceptions and notes |
| --- | --- | --- |
| Portable turn, request encoding, answer rendering | `test-logic` | Value transitions do not change native adapters |
| Native unit aggregate (`src/tests.zig`) | `test` | It is no product code; each file it newly lists selects its own owner's checks |
| CLI, client, preferences, provider selection | The fixtures that reach them, `admission-debug-integration` | Usually every case `check` runs, so `check` |
| Frontend consent, departure and submission recovery | `test-logic`, `test`, `admission-debug-integration`, `terminal-restoration-integration`, `canonical-failure-integration` | The import graph owns the exact mapping; the human CLI fixture composes the PTY cases |
| Store SQL owners | `test`, the fixtures that reach the Store, `dispatch-debug-integration` on both systems | The Debug failure-correlation subset checks saved provider bytes through reopen |
| Activity fixture, typed read client | `activity-integration` on both systems | Runs in `check` and `check-full`; select separately only without a composed gate |
| Preference privacy fixture and native actor | `preference-policy-integration` on both systems | Runs in `check` and `check-full` |
| Server, protocol, shared execution and scratch | The fixtures that reach them on both systems, usually `check` | None |
| Server admission or capture owner, admission fixture | Also `admission-debug-integration` on both systems | The routine Debug smoke does not cover the recovery matrix |
| Bash | `test`, Bash owner, lifecycle, recovery and caller targets; `test-logic` for `src/BashLifecycle.zig` | No general sandbox or power-loss claim |
| HTTP/2 client (`src/h2/`) | `test-h2`; `test-logic` for `src/h2/policy.zig` | Runs in `check` and the `check-full` execution part. Its peer tests run over loopback h2c and TLS in process. System trust against real servers is manual, on each platform (macOS SecTrust above all), and not a gate: `RUI_H2_LIVE_URL=https://api.openai.com/v1/models zig build test-h2` and `RUI_H2_LIVE_NEGATIVE=1 zig build test-h2` |
| Postgres wire client (`src/store/wire/pg*.zig`, `scram.zig`, `tls.zig`) | `test-pg`, also in local development feedback, for `src/tls_client/` (its OpenSSL settings and trust, shared with `test-h2`) | Runs in `check` and the `check-full` execution part. Decode tests use bytes captured from Postgres 16 and RFC 7677's SCRAM exchange. On Linux CI the live tests run against `postgres:15` over verified TLS with SCRAM-SHA-256-PLUS and fail if it is missing (`RUI_TEST_REQUIRE_ENGINES=postgres`); elsewhere they run only when `RUI_TEST_PG_PORT`, `RUI_TEST_PG_PASSWORD` and `RUI_TEST_PG_CA_FILE` name a server. A pipeline deeper than the socket buffers is the driver's concern and is not covered here |
| MySQL wire client (`src/store/wire/mysql.zig`) and the Store's blocking connection (`mysql_connection.zig`) | `test-logic` and `mysql-wire-integration`, also in local development feedback; also `test` for those two files and `tests/integration/mysql_server.py` | `test-logic` runs `mysql.zig`'s own tests, and `test` replays its captures through the connection over a socket. `mysql-wire-integration` runs `mysql_wire_test.zig` through the connection against a MySQL 8.4 server in Docker, over its Unix socket, plaintext TCP and verified TLS, and fails, never skips, without Docker. `mysql_server.py` holds the one image pin; this harness and `check.yml`'s dialect-check server both start the image through it |
| Skills discovery, capture and immutable catalog instructions | Focused `test -Dtest-filter='skills '`, `test -Dtest-filter='inline '` and `skills-integration` | Scanner/parser/delta/resource and Store/admission/history/`/name` binding and skill-entry owners plus isolated real Host wire; native malformed filename case may skip on macOS/APFS, which rejects creating the fixture |
| Model and transport | `test`, `dispatch-integration`, `transport-h2-integration`; `test-logic` for `src/transport_policy.zig` | Live provider remains opt-in |
| Codex credentials | `test`, Codex, credential and Codex H2 targets; `test-logic` for `src/codex_credential_policy.zig` and `src/codex_token_wire.zig` | No real account login required |
| Product defaults (`src/product_defaults.zig`, `tests/integration/product_defaults.py`) | `test-logic`, `check`, `admission-debug-integration` and the startup-capacity targets on both systems | Every omitted-value surface consumes the module. `host-launch-integration` reads the module instead of copying values. `test-logic` pins the approved values |
| Native launch or descriptor and startup capacity | `test`, `host-launch-integration`, `descriptor-capacity-integration`, `codex-h2-integration`, `transport-h2-integration` on both systems | Composed gates cover the first three only |
| Shared `check.sh` driver | Driver tests and `check-full` once | Driver tests require exact fixture membership, overlap, batch drainage and failure propagation; native fixtures need not run again through `check` |
| Dispatch scenarios | `dispatch-integration` and `dispatch-debug-integration` on both systems | `dispatch_integration.py` owns scenarios; shared helpers live in `model_fixture.py`. Neither composed gate runs the Debug `failure-correlation` mode |
| Shared control, model and Host-process fixture helpers | `check`, both H2 targets and affected standalone Current or reply-delivery targets | `model_fixture.py` keeps all shared consumers. H2 and standalone consumers are outside the composed driver |
| Standalone Current, reply-delivery and login-signal oracles | Owning integration target; login signal on Linux only | Neither composed gate runs them. Changes to their helpers keep these targets |
| Canonical-failure oracle | `canonical-failure-integration` on both systems | Skip it when a composed gate is selected; the human CLI fixture runs all cases |
| Build, dependencies or bootstrap | `check-full`, full Debug admission, long timeout and churn witnesses, relevant H2 and standalone targets, manual empty-cache evidence | Transport build, dependency pins and bootstrap select both H2 targets |
| Main admission, every ready PR | Successful plan and Linux aggregate on the immutable merge candidate: compile and format, `typecheck-macos` for compile inputs, `stack-frames` and the selected unit roots and integration targets. Normal changes also require policy. Native Mac runs only for [Mac paths](tests/ci/platform_boundary.py), the code Linux never executes as a Mac does; build plumbing is not one. The [upgrade check](.github/workflows/previous-release-upgrade.yml) runs on hosted Linux only for upgrade, installer and Store-format paths | The conservative documentation lane requires explicit empty product selections and skipped policy, native, upgrade and cache jobs. Admission requires the exact Mac and upgrade results the plan selected: success when selected, skipped otherwise. Required admission runs before main |
| Promotion, manual | [Promote](.github/workflows/promote.yml) on main HEAD: Linux and macOS `check-full`, `test-logic` and `admission-debug-integration` with the batch's selected targets, `stack-frames`, the upgrade check on both systems, [renderer contracts](#renderer-contracts), then cold release builds | A failing job bisects each failed step over the batch since `stable` and files one `promotion-red` issue per cause. Only a fully green promotion publishes a release and advances `stable` |
| Host stack frames (Zig the Host compiles: `server.zig` and the `host_modules` closure; other `src/` inputs, `build.zig`, `tests/ci/stack_frames.*`) | `stack-frames` on x86-64 Linux; `check` runs it, `check-full` does not | [stack_frames.py](tests/ci/stack_frames.py) reads the ReleaseSafe binary's prologues and direct calls. It fails on a frame over 8 KiB reachable from a Host thread or a function of a module in `host_modules` unless an exception in [stack_frames.json](tests/ci/stack_frames.json) names its cause, and on a thread whose deepest chain passes its `chain_ceiling`. Exceptions and ceilings only shrink. Calls through function pointers outside `host_modules` are not followed, and no other platform is measured |
| Caller error coverage (`cli.zig`, `cli_args.zig`, `client.zig`, `preferences.zig` and root `caller_*.zig` under `src/`) | `python3 tests/ci/caller_errors.py`, the prepush driver and CI policy | Caller-facing CLI modules cannot use raw `@errorName`; every literal production error reference or declaration in that inventory needs a catalog mapping or an existing pending entry. The trusted `origin/main` pending set only shrinks; first rollout bootstraps from the same trusted CLI-owned sources and the exact pinned Zig standard library. Closed inferred sets also fail compilation through `caller_error.of`; unmapped errors widened from other owners remain `internal_unexpected`, exit 1 (unclassified), without extending the CLI inventory. |
| CI policy | Selector tests, workflow validation and `test-logic` on both runner architectures | Exercise actual CI bootstrap. The policy job runs every `tests/ci` test except the self-checks in `POLICY_SELF_CHECKS` ([select_tests.py](tests/ci/select_tests.py)), each of which runs only when the diff changes a file it reads |
| Provider locality (any Zig under `src/`) | `tests/ci` unit tests, which run [test_provider_locality.py](tests/ci/test_provider_locality.py) | Core production code imports no sign-in file, names no ChatGPT header, ChatGPT endpoint or OpenAI error code, and names no provider by its tag (`Provider.codex`, `.openai =>`); tests and comments are blanked first. The owners are listed in the script; one allowance (the transport's own Host field list) names why. Text checks: a renamed header or a code spelled another way passes |

`test-logic` compiles `src/logic_tests.zig`, which includes answer-rendering tests absent from `src/tests.zig`.
Neither composed gate covers that root, so run it with a selected composed gate.
The compiler and dependency setup action is bootstrap, not CI policy.
An unavailable selection base is an error.
PR selection uses its recorded base and immutable merge candidate.
Ready normal changes retain policy and the Linux aggregate even for a narrow diff.
Only an explicit documentation classification or draft plan can omit policy; an empty target list alone cannot.
The Linux aggregate always checks the plan's selected parts or exact skips.

Qualification Go changes select `measurement-check`.
Changes to the CLI configuration surface (CLI grammar and client, creation defaults, the wire protocol and `openapi.json`, and Host configuration admission) select it too: its configure contract runs the measurement runners' `session configure` call and a replay of its saved record against the current Rui, so drift fails in the PR that causes it rather than in the next campaign.
Linux-memory Python or C changes also run the collector unittests and compile the diagnostic probe on Linux.
Other qualification changes state manual syntax or compilation requirements.
Stored historical results select no product suites.
Syntax checks, probe compilation and unrelated product tests do not qualify a resource claim.

### Landing cadence

`main` is the integration branch; `stable` and the latest release are what users run.
Draft PRs run quick checks while Codex reviews; ready PRs run the full selected tier before merge; a manual promotion runs the expensive tier on a batch of merged commits before it reaches users.
GitHub must require pull requests and the GitHub Actions `admission` check on `main`, with no bypass; it does not require an up-to-date base.
Use squash merges under linear history.
A PR's checks qualify its merge with the base they ran on, so a green PR merges without rerunning after `main` moves.
Two PRs that pass alone but break together are caught by promotion, which qualifies main HEAD and bisects to the commit that broke it.
A changed head requires current candidate checks before merge.

[Selected checks](.github/workflows/check.yml) qualify each ready PR's immutable merge candidate.
For normal changes, Linux runs the affected targets from [select_tests.py](tests/ci/select_tests.py), `typecheck-macos` when the change touches what it compiles (Zig, C, the build, patches and embedded files), and, when selected, the `stack-frames` oracle.
Native macOS runs the affected targets, or `check`, only when the change touches a [Mac path](tests/ci/platform_boundary.py): Darwin branches, C and shell sources, the PTY launcher, the HTTP/2 client, release and install scripts, and the Mac workflow.
Darwin-only linking and settings live in `build/darwin.zig`, a Mac path.
Other build plumbing (`build.zig`, `build.zig.zon`, the setup action, `tests/ci/qualification.py`) is not a Mac path: Linux runs it, `typecheck-macos` compiles Rui for Darwin, and promotion links and runs it on a Mac.
The [previous installed-release upgrade](.github/workflows/previous-release-upgrade.yml) runs on Linux against that same candidate only for upgrade, installer and migration paths, the check itself, and a `schema.zig` edit that changes the Store format: its `schema_version`, a `bootstrap_digests` row or a migration step.
Promotion runs it on both systems.
Renderer contracts run nonblocking only for renderer and frontend owners.
The documentation lane skips heavyweight policy, product builds and suites, and prior-release upgrades.
It requires a successful plan with canonical empty product outputs and a successful Linux aggregate that verifies all product producers were skipped.
The allowlist reads committed Git paths and modes against the selector's resolved base and candidate; any selected runtime, native, cache or resource obligation restores normal verification.
Reference and consistency checks remain reviewed evidence, not automated link validation.
The always-run `admission` aggregate requires the exact results for the declared change kind, including the selected Mac, upgrade and cache-execution checks for normal changes.
Failed, cancelled, missing or unexpectedly skipped required jobs do not qualify a candidate, and an unselected Mac or upgrade job must be skipped.
A draft PR runs only the plan (candidate, `git diff --check` and selection summary) and cheap aggregates; policy, builds, suites, codegen, typecheck, cache execution and previous-release upgrades are skipped.
The plan owns draft routing without changing the diff's documentation/normal classification; readiness computes a fresh full selection.
Draft checks never satisfy `admission`.
Local `prepush.py` supplies development feedback; [landing](docs/agents/landing.md#publish-and-merge) keeps Codex rounds on the draft until clean.
Correctness failures are fixed on the PR before it reaches `main`.

[Promote](.github/workflows/promote.yml) is the only path to a release, and it starts only by manual dispatch on `main`: `gh workflow run promote.yml --ref main`.
It qualifies main HEAD against the batch since `stable`, the last promoted commit, and runs everything the PR tier skips: Linux and macOS `check-full`, `test-logic` and full Debug admission recovery with the batch's selected targets, `stack-frames`, the upgrade check on both systems and the renderer contracts.
A failing suite, upgrade or contract job bisects each step that failed, on the same runner, by replaying that step's recorded command: once at HEAD, then by binary search over the batch's first-parent commits.
A step is one suite batch, one upgrade check or one contract; a suite job stops at its first failed batch, and [steps.py](tests/ci/steps.py) runs every upgrade check and contract even after one fails.
Each step's verdict names the first commit where it fails, or says the red did not reproduce at HEAD or already fails at `stable`; replay logs and the verdicts are retained with the run.
Two steps broken by different commits get different verdicts, but a suite batch with several causes names only its earliest; the job's issues carry every verdict line.
The run then files one `promotion-red` issue per failure signature through [report_issue.py](tests/ci/report_issue.py), with the verdict on it.
A red promotion publishes nothing and leaves `stable` where it is; fix forward on `main` through ordinary PRs and promote again.
A bisect never turns a promotion green, and a promotion never merges or reverts.
Only when every tier passes does it call [Release](.github/workflows/release.yml) with the qualified SHA for cold versioned builds and publication.
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
Keep cleanup and resource bounds, and do not retry failed required acceptance to obtain a pass; only a [listed flake](#listed-flakes) reruns, and only its listed signature may fail then pass.

### Composed gates

`check` runs formatting, ReleaseSafe native tests and process integrations, a Debug artifact and recovery smoke, ReleaseSmall deliverables and, on x86-64 Linux, `stack-frames`.
Required functional assertions stay required when their fixture changes.
Native and process suites run concurrently, except short-deadline Host-startup and Debug smoke cases, which follow the parallel batch.
The Debug smoke covers streamed-capture failure and recovery, Store-lease exclusion, committed-but-lost Message replies, changed-source capture preservation and same-key configuration and Message replay after a Host crash.

Human CLI caller, renderer, terminal-restoration and canonical-failure cases run as separate parallel peers in `check` and the `callers` partition.
The driver waits for every peer before isolated cases and fails if any peer fails.
The unsplit serial gate retains its original case order and assertions.

`zig build check-full` runs routine native tests and process integrations serially after formatting and production builds.
Selected CI runs it on Linux for build or dependency changes; promotion runs it on macOS, and manual qualification runs it on request.
Run the unsplit default locally for release qualification and isolated process-latency claims.
It is not an every-edit gate.
Serial execution reduces unrelated load but does not establish scheduler order; use owner-visible outcomes or handshakes for ordering claims.

Linux Selected CI and each platform's qualification run the full gate as `-Dcheck-part=execution` and `-Dcheck-part=callers` on two isolated runners at the same revision.
Both must pass.
The execution partition overlaps native tests with its serial process fixtures; the unsplit gate remains serial.
Their disjoint fixtures cover the full gate once; callers run Host-process, allocator, launch and Debug smoke cases serially after the parallel batch.
[qualification.py](tests/ci/qualification.py) packs other Linux targets so a Selected run never exceeds ten shards.
A long gate (`check`, `check-full`, `test`, `stack-frames`) runs alone, and beside one the short targets share three shards: they end inside the gate's run, so more shards would only repeat setup.
Only non-promotion manually dispatched runs whose diff touches no strict path rerun a failed batch once and report both results; a pass after the rerun is a flake to fix.
Ready PRs, promotions and the documentation lane never rerun, except a batch that failed only on [listed flakes](#listed-flakes).
Qualification keeps one job per target. macOS packs native work into at most three workers: execution plus portable logic, callers, and remaining native targets.
Composed gates, long witnesses, launch, Debug admission, reply delivery and H2 stay isolated from other target batches.
The `linux` and `macos` statuses fail if any selected job fails or is cancelled.
A failing aggregate names each failed job of its run and whether infrastructure or a check failed it ([failure_cause.py](tests/ci/failure_cause.py)), so a red never reads only as an exit code.
Use unsplit `zig build check-full` for single-machine isolated-latency or release evidence.

Driver `fixture passed: exit=0 elapsed=1.234s` records (`failed` on nonzero exit) attribute fixture cost, not CPU time, isolated latency or speedup.

Use explicit gates, not hold durations, for race ordering.
Artificial shared setup or pair deadlines and prelaunch fit reserves are not routine prerequisites.

### Renderer contracts

[Renderer contracts](.github/workflows/renderer-contracts.yml) run nonblocking build targets on pull requests that touch renderer, frontend or terminal owners, `build.zig` or the harnesses, and on manual dispatch: `renderer-contracts-selftest`, the synthetic `direct-pty` key matrix and Ghostty vectors, `direct-pty-controls` and `input-equivalence`.
No gate root imports their sources, and neither Selected checks nor merging requires them; a red result is a defect to fix, not a waiver.
`src/os` holds no PTY or terminal code, so its edits run the Selected fixtures that reach them, not these contracts.
Every promotion requires them, and a failing contract bisects the batch.
Manual dispatch adds the [renderer mutation runner](tests/ci/renderer_mutation.py) for `test` and `test-logic`.
PR failures remain visible in workflow results; there is no scheduled campaign, and only a promotion files issues.
Its anchors are checked per change: [`renderer_mutation_test.py`](tests/ci/renderer_mutation_test.py), run by the Selected `policy` job, requires each mutation's anchor exactly once in current source, so moving a protection re-anchors its mutation in the same change.

Injected PTYs are not physical keyboard, terminal-emulator or display qualification.

### Long witnesses

Long witnesses are explicit qualification steps outside `check` and `check-full`.
Run them apart from load-generating suites.
Changes to their build wiring or fixtures need both routine and long-step evidence.

| Witness | Required cadence | Retained or deferred evidence |
| --- | --- | --- |
| `zig build test-full` | Client response-wait, inactivity or timeout-default changes, relevant toolchain or platform changes, release qualification | The 61-second witness checks the production 60-second setting in real time. Routine runs report this one skip |

`check-full` alone does not claim exact-duration evidence.
Release evidence requires `check-full`, the long step and applicable platform and resource gates.

Optional `cross-check-linux` and `cross-check-macos` compile supported and experimental architectures.
They are not native evidence or a support promise.
The Mac cross-build requires an Apple SDK.

### CI artifacts and caches

[Selected CI](.github/workflows/check.yml) cancels superseded PR checks per branch.
The release publisher is serialized and never treats cancelled acceptance as a pass.
Build caches hold compilation inputs and outputs, not acceptance.
All Zig unit Run steps bypass Zig acceptance caching, and Go tests use `-count=1`.
Cache-policy changes run [the fixed-seed execution regression](tests/ci/cache_execution.py) on Linux before main, and on macOS in promotion when the batch changed cache policy.
Cache policy is the proof and the prune script themselves, and changed non-comment lines that name a Zig build cache or `has_side_effects` in the build, the workflows and the setup action, whose caches are all build caches; any change to the `cache_execution` job counts too.
The required `admission` aggregate includes this job when selected.
Build-cache keys separate native tools, Apple SDK, architecture, dependency pins, scripts, source inputs and shard.
Only `main` saves caches; PR jobs restore main's snapshots and save none, so PR caches never feed a privileged workflow or evict main's.

Each platform builds its target closure once with `ci-build -Dci-targets=...`.
On Linux and macOS, when the selection compiles the single-threaded unit test binary alongside other gates, one producer builds only that binary (`-Dci-part=unit`) and another builds the rest (`-Dci-part=rest`); build.zig refuses a split whose selection never reaches the unit compile.
[build_artifact.py](tests/ci/build_artifact.py) transfers the executables and pinned package sources through immutable same-run artifacts that expire after one day.
Workers accept either one whole part or exactly the unit and rest parts, with disjoint executable inventories that together match the extracted tree, and verify each exact artifact ID, archive digest, run, source and tree, an attempt no later than their own (a rerun of failed jobs keeps its passed producer's artifact), platform selection, OS, architecture, compiler digest and executable hashes before use; runner image versions are logged, not compared.
Extraction rejects traversal, special files, hardlinks and symlinks.
On any mismatch or rejection the worker discards the artifact, fetches pinned packages and compiles its own checkout with `ci-build`, stating why; a failed local fetch or compile stops the worker with its exit status.
The receipt records compilation, never a test result.
Gates then execute through the existing driver with `-Dci-artifacts=.zig-cache/o/ci-compiled`.
Go tests, the string sanitizer and fixture C helpers compile fresh in their worker.
Every selected gate executes on the run's own revision; no earlier result substitutes for execution.

The compiled handoff selects Zig's baseline CPU (`x86_64` on Linux, `apple_m1` on macOS ARM64) and emits `ci-cpu.json`.
Consumers check that manifest before any gate.
The build graph rejects incompatible target or optimization overrides.
Transport's C build uses explicit platform targets without host-specific CPU flags.
Ordinary local builds keep native CPU selection.
Architecture and runner-image equality do not establish CPU compatibility.

A fixture that retains a failed root copies its `probe.log`, PTY gate metadata and native-observation failure metadata through [host_process.py](tests/integration/host_process.py), excluding private directories, symlinks and special files.
Each root reserves one of sixteen slots, holding at most eight files and one MiB, so concurrent fixtures stay within 128 files and sixteen MiB.
Uploads expire after three days.
Successful gates do not capture.
Native observation failure metadata is copied after reap and before temporary-root deletion.

[Cache maintenance](.github/workflows/cache-maintenance.yml) warms production compilation after trusted main pushes that change build, dependency or maintenance inputs.
It also compiles the build runner on six Linux slots and one Mac, so test shards on the CPU models those slots drew restore it from main.
Cleanup keeps main's newest snapshot per platform and partition, per build-runner CPU model, of each platform's compiler and of the package set, and removes every PR cache; these are targets, not a quota.
Warm baselines are not test acceptance.
Maintenance also builds the pinned previous release per platform for the read-only upgrade check.
The API-only cleanup job runs trusted main code with cache-deletion permission and consumes no producer code, caches or artifacts.

CI uses only standard `ubuntu-24.04` and Apple Silicon `macos-15` runners, plus `ubuntu-24.04-arm` for the Linux arm64 release build, in this public repository, with no paid host or storage expansion.
Free eligibility does not prove capacity; report the actual runner outcome and do not raise paid spend silently.
Apart from the shard rerun above and a [listed flake](#listed-flakes)'s rerun, test execution has no automatic retry.
Infrastructure failures are not test execution: [Retry infrastructure failures](.github/workflows/infra-retry.yml) reruns a PR run's failed jobs once when every failure was infrastructure (no runner took or kept the job, or a step that only fetches, installs or starts services failed with a network error such as GitHub's 504) and the run still tests the PR's head.
A build or test step's failure, a later attempt or any check failure in the run never reruns, and a rerun job's tests had not run.

### Listed flakes

[quarantine.json](tests/ci/quarantine.json) lists intermittent failures by their fixture-and-assertion signature, as [report_issue.py](tests/ci/report_issue.py) names them, with the file, an open `ci-red` issue, an owner and an expiry at most 14 days after the entry was added.
A listed test still runs and reports.
When every failure of a suite batch is a listed, unexpired signature, [run_selected.py](tests/ci/run_selected.py) reruns the batch once.
In PR admission a second failure that is again only listed signatures passes with a warning; promotion fails on it, so promotion blocks on two consecutive failures.
Any other failure in the batch, a failed step that names no listed fixture or an unparsed failure keeps it red, and a PR touching a [strict path](tests/ci/strict_paths.py) gets no quarantine.
Store, recovery and upgrade tests are never listed ([quarantine.py](tests/ci/quarantine.py) checks each entry, and `test_quarantine.py` runs in the policy job).
For a listed signature, and only for it, a fail-then-pass is green; every other fail-then-pass stays unexplained.
An expired entry blocks again: fix the race and remove the entry in the commit that says `Fixes #N`, or renew it in a reviewed PR with a new 14-day window.

### Hosted qualification

[Linux qualification](.github/workflows/qualify-linux.yml) runs full native gates in isolated jobs on demand, including credentials, measurement checks and long witnesses.
CI has no scheduled workflows.
Full native and resource campaigns remain available through manual qualification on both platforms.
[report_issue.py](tests/ci/report_issue.py) remains an on-demand tool for recording failure signatures from full job logs.
A signature names the failing fixture and assertion, a Zig test, or a gate's own error.
A later green run alone does not prove a recurring defect fixed; retain the counterexample and name the fixing commit.
Manual qualification reports the requested SHA, not coverage of intermediate merges, and does not file issues automatically.
A failed, cancelled or skipped attempt is never a pass.

[On-demand Mac qualification](.github/workflows/qualify-macos.yml) resolves a requested ref once and runs existing targets on `macos-15` VMs: `gh workflow run qualify-macos.yml -f ref=<revision> -f suite=<suite>`.
Suites: `footprint` (20-wave repeated work), `resources` (all resource targets, footprint included), `native` (full checks, standalone integrations, long witnesses) and `all`.
Gates execute fresh.
A ref lacking the setup action, handoff tooling or targets fails rather than substituting checks.
Requested-ref qualification uses workflow-level `cache-mode: read`; it can restore but not publish caches.
`contents: read` alone does not impose that boundary.
Their setup calls pass `publish-caches: 'false'`, so a ref's setup action only restores instead of trying a save the token refuses; a requested ref older than that input still attempts the save, and the token rejects it with a warning.
Pinned actionlint 1.7.7 predates the key, so validation ignores only its top-level-key diagnostic for the workflows that declare it; `test_requested_ref_cannot_publish_shared_caches` rejects absent policy, job-level overrides, a read-only setup call that would save, and a setup save step without its matching restore-only step.

Artifacts expire after three days and keep the source SHA, VM and toolchain identity, gate output, bounded footprint reports and failed-fixture diagnostics, never Stores, HOME, credentials or payloads.
Missing evidence is not a pass.
Hosted counters describe that VM, not a physical Mac; physical comparisons and desktop UI need hardware.
Live-provider checks need authorized credentials.
Hosted runs establish no power-loss durability, mixed-workload qualification or aggregate memory from Host-only evidence.

Resource campaigns run on request on both platforms, not per candidate.
The workflow offers all ten resource targets on macOS and the six portable ones on Linux; admission, message admission, model dispatch and model retry reject Linux.
Linux cannot qualify the macOS footprint counter and shared-runner pacing is unqualified, so the campaign is not candidate acceptance.
Its nonzero exits remain failures.

Empty-cache serial full acceptance is manual on both platforms; no automatic cold-build backstop remains.
The reproduction below uses empty local, global and package caches.
Routine orb work is incremental rebuilding, the affected mapping and reproducing one failure; full, churn, long, credential and measurement campaigns belong in hosted qualification.
Keep timing-sensitive measurements on an isolated native machine when shared-runner evidence is invalid.

[fetch_dependencies.sh](src/fetch_dependencies.sh) imports pinned native archives in save mode, verifies hashes against the unchanged manifest and fetches the complete graph.
Use it on both platforms.
Stock Zig 0.17 no-save fetch ignores `--pkg-dir`.
To reproduce a cold build from a clean source export without `zig-pkg`:

```sh
(
set -eu
test ! -e zig-pkg
export ZIG_LOCAL_CACHE_DIR="$(mktemp -d)"
export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d)"
export ZIG_LOCAL_PKG_DIR="$PWD/zig-pkg"
mkdir -p "$ZIG_LOCAL_CACHE_DIR/tmp" "$ZIG_GLOBAL_CACHE_DIR/tmp"
bash src/fetch_dependencies.sh
zig build -Doptimize=ReleaseSafe -j2 --summary all
)
```

### Release publication

[Release](.github/workflows/release.yml) runs only inside a green [promotion](#landing-cadence) and publishes the immutable main SHA that promotion qualified.
Only verified publication advances the `stable` pointer.
To recover an interrupted publication, rerun the promotion's failed jobs: `gh run rerun <promotion run id> --failed`.

[release.py](tests/ci/release.py) skips a SHA only when a verified public release already includes it, and can repair a missed pointer update without rebuilding.
Drafts and orphan tags reserve a version for their exact SHA; recovery reuses that identity rather than skipping incomplete publication.
A newer main SHA gets a newer version; one release covers a whole promotion batch.
Each platform's native runner builds the tagged commit with empty caches and ReleaseSafe.
The targets are portable: a baseline CPU, glibc 2.34 on Linux and macOS 15 on Apple Silicon.
Each build must report the version and exact SHA from `rui --version`.
The Linux executables are stripped, and their debug info ships as a separate `-debug` archive that crash traces read once it is extracted beside them.
The release attaches the archives, `SHA256SUMS` and an `install.sh` that pins the archive digests.

`test_release.py` uses fake archives.
It covers version planning, template filling with the shared publication fragment, every report state (first install, update, reinstall, Store format change, Host and `PATH` states) and the installer's update, digest, version and preservation behavior.
`host-status-integration` checks the fragment's reading of the real `defaults inspect` output.
One manual check installed tagged archives through the filled installer on macOS 15, and under dash on Ubuntu 22.04 x86-64 with glibc 2.35.
Debian 11, with glibc 2.31, refuses to load the Linux build.
Another manual check built the Linux release, ran the stripping step, extracted the debug archive into an installer-shaped build, and sent `rui host serve` SIGSEGV: the trace showed source lines, and without the debug files it showed `???`.
No hosted job runs a published archive or checks a trace.

### Measurement and release evidence

Measurement runners use Go 1.27.1 and modules pinned in `tests/qualification/go.mod` and `go.sum`; Go is measurement-only.
Before `zig build measure-*`, run `GOTOOLCHAIN=local go -C tests/qualification mod download`, then `zig build measurement-check`.
Record Go and gopsutil versions, `go.sum` and binary hashes, platform, Git revision and dirty state.
Measurement provenance reports a revision only when `git -C` resolves the measurement root as its top level; otherwise both fields are unavailable.

Release evidence includes deterministic Session, model, tool, permission, context, compaction and server fixtures; hard-termination recovery at each acknowledgement and effect boundary; compiler-backed discovery of both production graphs; and the opt-in live Codex repair through those owners.
Classify unused, conditional and test declarations and remove obsolete interfaces.
Never label interrupted or unrun checks passed.
### Product tenets

The [Review](CODING_STANDARDS.md#review) checks the change's completed caller flow against the following tenets.
This design review is not a landing gate.
Required behavior, recovery and resource proof remains in the [canonical gates](#canonical-gates).

- **Simplicity:** explain the required behavior or demonstrated cost that justifies each added module, durable fact, cache or queue.
  Check for duplicate authority and caller-owned coordination that belongs inside an existing owner; compare a simpler approach where one could preserve the required behavior.
  Identify dependencies introduced or removed on another owner's representation, call order or lifetime, and justify each retained one by required behavior.
  Passing tests establish tested behavior, not design simplicity.
- **Explainability:** walk ordinary work, failure and recovery in plain language using the change's normal results and inspection.
  A reader can tell what happened, what remains uncertain and what can happen next.
  Explanations follow owning facts and do not treat optional diagnostics as recovery authority.
  Check this as each caller path appears, before final presentation work.
- **Memory footprint:** rerun comparable fixtures as resource owners are added, recording aggregate peak and retained-idle footprint, including native libraries and Rui helpers.
  At fixed capacity, vary payload and durable-history populations independently and exercise fill and drain with delayed cleanup or failure.
  Explain changes from the preceding measurement and resolve unexplained growth before dependent work builds on it.
  Use the [resource targets](#resources-and-accepted-host-qualification-targets); stage checks do not replace qualification of the complete simultaneous workload or introduce per-module quotas.

Record these in the review's findings.

## Platform qualification

Run affected behavior and process-crash recovery checks natively on Linux x86-64 before main and macOS Apple Silicon before stable promotion.
Run resource comparisons when the resource owner or claim changes.
Record actual architecture, toolchain, platform skips and unavailable counters.
OS-crash, power-loss and general sandbox guarantees are outside scope; keep exact internal limits and best-effort external runaway and cleanup tests.
A known incompatibility needs an explicit response, not a hidden fallback.
Verify the selected credential backend, access checks, account-preserving refresh and failed atomic save without plaintext fallback or credential inheritance.
Same-user authorized Bash can access credential files.
Installer and startup checks use disposable HOME and checkouts; personal installations, Stores and credentials are not fixtures.

For a fixture-created private temporary root, call `canonical_fixture_root` from [host_process.py](tests/integration/host_process.py) once, right after creation, before deriving Store, Workspace or HOME.
Use that root for Host and client arguments, wire identities and expected values: macOS `/var` and `/private/var` name one directory but differ under exact wire identity.
Keep intentional alias and security negatives raw, as in the [Conversation fixture](tests/integration/conversation_page_integration.py).

Native PTY capture keeps the parent's slave open through output collection, caller reap and terminal-restoration checks, because Darwin can discard unread output when the last slave closes.
Child exit alone is not completed capture.
Marker readers reject EOF or Linux `EIO` immediately with their retained prefix.
Only intentional hangup and EOF controls release the slave before collection.
These fixture lifetimes do not change product deadlines.

`python3 tests/integration/host_allocator_test.py /path/to/rui` runs in both composed gates.
On macOS it requires one same-PID allocator-default replacement when defaults are missing, preserved explicit or empty values, no replacement with both supplied or with `RUI_HOST_MALLOC_DEFAULTS=0`, no Store effects before replacement, and startup failure without a Store if the executable disappears.
Non-Host invocations add no defaults, and Linux shows no replacement.
Run workload correctness with defaults enabled and disabled, and measure the uninstrumented binary separately: constructor probes prove startup order, not memory savings.
Record the macOS version and caller overrides; untested OS releases are not covered.

Run the provider fuzz campaign with `zig build test -Dtest-filter='fuzz provider' --fuzz=1K --summary all -j2`.
Native Mac live C-linked fuzzing fails at link with the stock Zig 0.17 compiler (missing `__sanitizer_cov_trace_*` hooks).
Seeded corpus and allocation passes on Mac are not a live-fuzz pass.

## Qualification workload and measurement boundary

These rules define the workload behind the [Host targets](#resources-and-accepted-host-qualification-targets):

- **Capacity:** 100 model Operations live at once, each completing its original result and releasing scratch and custody, in two fill and drain rounds on one Host.
  Keep 1, 8 and 16 capacity baselines and independent payload, item, history-growth and failure checks.
  A 1,000-capacity model, Bash, Edit and mixed proof belongs to finished-product qualification.
- **Repeated work:** `zig build measure-repeat-work` runs 20 six-second waves on one Host across 100 stable Sessions.
  It validates each request's complete history and input, exact results, one H2 connection and 100 ready streams per wave, and custody and scratch release.
  Record per-wave lifetime-peak and retained-idle footprint, CPU, I/O, descriptors and SQLite configuration and usage, and keep `heap --noContent -s` and `vmmap -summary` output after each drain; report missing tools as unavailable, not zero.
  The 25,000,000-byte target applies to every wave.
  Retained-idle deltas need attribution before a stable-churn claim.
  The snapshots are diagnostics, not additive counters.
  Obsolete request encodings do not qualify.
- **Pacing:** 260-byte SSE records at nominally 30 events per second per stream (100 at capacity 100) across 60 seconds: exactly 1,800 or 6,000 events per stream, none dropped, delivery after all streams are ready.
  Record actual delivery duration, achieved rate and gaps; they are diagnostics.
  A run with jitter qualifies only the observed workload.
  The 120-second collection bound is a test timeout, not a throughput promise.
- **CPU:** exclude the provider fixture from Rui totals but record it; its populations must drive representative transport allocations inside Rui.
  Start the first Host CPU read no earlier than second 10 and the second no earlier than second 50 and 40 seconds after the first finishes.
  Divide by the interval from the first read's finish to the second read's start (at least 40 seconds), and finish the second read before any stream completes.
  Report both read brackets and the measured delivery duration; missing overlap evidence leaves average CPU unqualified.
  Measure complete-work CPU from admission through result audit and release without an idle tail, and tool or mixed CPU separately.
- **Controls:** keep 100 live model Operations before each control sample and replace cancelled work.
  Include exact interruption and Session stop, inspect saved outcomes and verify cleanup.
  Keep inspection and import-contention checks.
  Report physical cleanup apart from acknowledgement, and retry discovery apart from dispatch.

Model-output runners keep JSON evidence and exit nonzero for failed, incomplete or target-miss verdicts.
A miss needs an implementation or product decision; adding pools or rerunning until green does not satisfy it.
Measure the Rui CLI and helpers separately from the Host target.
## Contract index

ARCHITECTURE owns behavior; tests own cases.
Quoted names are Zig filters: `zig build test -Dtest-filter='model revisions'`.
Other identifiers name targets, `tests/integration/` fixtures, modes or functions.
`none located` means no check; `planned` means unimplemented behavior.
Neither is coverage.
Update rows with checks.

## Asynchronous peer collaboration

These rows target the accepted [peer composition](ARCHITECTURE.md#agent-identity-and-peer-composition) and [non-interactive CLI](ARCHITECTURE.md#cli-modes-and-commands), not today's runtime.
Extend existing owners and their gates; replace obsolete wait wrappers and fixed-quota assertions while keeping capture, original-result, control, delivery and cleanup coverage.

### Native behavior and failure cases

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Model self-address, `rui --help` pointer, self-label command and peer start/report/read-result facts, unchanged preamble, Workspace and caller instructions; separate peer sender and local-result facts; explicit report delivery through Bash with its Host-recorded sender (`RUI_ADDRESS`, Action handle, capture recovery) | `peer_integration.py`, `human_cli_integration.py`, `'request preparation'`, `'recorded sender facts'` | Scripted provider proves workflow and rendered facts, not future model compliance. Fixture-observer snapshots synchronize holds and audit saved outcomes. Native Linux x86-64 and macOS arm64. Compaction and replacement Attempt identity: none located |
| Peer self-send admitted with explicit and generated capture; canonical Store alias and bare Session ID; plain answers saved as request results without implicit delivery; parent receives literal backticks, `$()` and quotes byte-exact through Bash tool stdin and file sends without shell evaluation or login | `peer_integration.py`, `'a peer capture preserves'` | No sender is inferred for human or script sends; original-capture recovery is unchanged. Shared text owns prose; independent request encoding, structural validation, history and digest negatives remain |
| Peer page identities and TUI labels carry the same full six-character ID; Activity decoding rejects obsolete abbreviation metadata without changing Message selection | `activity_integration.py`, `store/tests.zig` `'a peer sender'`, `session_view.zig` `'a peer reference'` | Conversation decoding retains its ordinary unknown-field policy. No independent label allocation or abbreviation collision machinery |
| Bare `--to ID`; sender Store beats conflicting HOME defaults; anonymous explicit Store selection; conflicting peer Store override and malformed peer context reject before capture; JSON, prefix, UUID, NUL, uppercase and excluded alphabet variants reject without aliases | `'grammar rejects ambiguous'`, `peer_integration.py`, `sender_identity_integration.py` | Genuine no-sender external sends remain anonymous. Noncanonical references are never coerced or prefix-matched |
| Store allocates exactly six CSPRNG Crockford characters under unique insertion; actual collision retries, original creation replay, unknown update no-create; ten concurrently created peers each start and send back by ID; guessed unknown IDs admit no work | `store/tests.zig` `'Store allocates six'`, `peer_integration.py` | Forced secure-entropy draws exercise the collision branch independently of random chance. Scripted provider proves runtime routing, not model compliance |
| `session start` atomically allocates and admits its first Message; committed lost output and concurrent first admissions/replays retain one ID and input; rollback/rejection leave no orphan; cancellation/reopen never readmit | `store/tests.zig` `'initial Message'`, `server.zig` `'initial Message reply'`, `peer_integration.py` | An ID is admission, not execution/completion. Existing Message observation and original-result contracts apply |
| Refused peer creation and malformed addressed sends retain their sender position, key, code and replay identity; public activity uses a null peer without fabricating creation intent | `store/tests.zig` `'refused peer creation activity'`, `'a peer sender'`; `client.zig` `'client failed-send target'`; `session_view.zig` `'failed peer Messages distinguish absent targets'`; schema 58 and populated migration tests; generated OpenAPI and TS feed checks | The regression crosses Store activity serialization and strict client decoding. Canonical unknown peers stay present; invalid non-null peers and omitted target still fail. Supported Store migration preserves saved attempts; no format-49 upgrade or per-row decoder recovery is implied |
| Message and instruction stdin preserve NUL, UTF-8 and trailing newlines; file-valued/literal alternatives reject; malformed peer context cannot downgrade; errors distinguish Store, stdin read, parse, content-file read, connect and uncertain admission | `peer_integration.py`, `admission_integration.sh`, `'grammar rejects ambiguous'` | Linux/synthetic evidence is separate from physical Mac qualification. No automatic report delivery or provider parser change |
| Action-issued sender identity; forged, missing, empty, unknown and misbound handles fail closed; exit, stop and restart retire authority; exact committed capture replay preserves admission after retirement | `'a peer sender is resolved'`, `'peer wire rejects old'`, `sender_identity_integration.py` (in `check`) | Single Host only. Handles never appear in public snapshots or model context. Native fixture uses a controlled scripted provider |
| Conflicting explicit peer Store fails before capture; forged foreign-Store context reaches the receiving Host, saves `invalid_sender_handle`, replays its rejection and creates no recipient admission | `peer_integration.py` | Successful cross-Store peer delivery is unsupported; no RPC, issuer startup, foreign Store reads or claimed-sender mode |
| 5 s reply inactivity | `'renews mutation inactivity'` | Intake independence, held credit, peer burst and native stall: none located |
| Peer selection progress and Host stop | `'skipped continuation'`, `host-stop-integration` | Peer input: none located. Iterated stops are not group cancellation |

### Per-call accounting and 100-agent acceptance

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Per-call cost decomposition of a real send | planned | None |
| 100 collaborating Sessions | planned | A live task needs spending authorization |
| ≤25,000,000 bytes Rui memory and 95% of sends in ≤1 s | planned | Includes CLI helpers. No throttling to pass |

## Authority, Session identity and admission

### Capture, configuration and command identity

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Capture, recovery and descriptor bound](ARCHITECTURE.md#caller-capture-and-recovery) | `'capture retransmits'`, `'capture publication'`, `'saved request wire mismatch'`, `human_cli_integration.py`, `saved_request_resources.py BASELINE CANDIDATE` | The `fsync` cut is Linux-only and not power loss. The resource fixture needs `/proc` and samples descriptors without asserting the bound |
| Configuration revisions, Message admission and selection | `'start_agent and configure parse the same plain agent spec'`, `'initial Message ingress streams the plain spec'`, `'model revisions'`, `'model switch'`, `'message admissions remain'`, `'runnable discovery'`, `dispatch_integration.py`, `canonical_failure_integration.py` | The shared plain spec covers all table fields, nullable/omitted states, object schemas with canonical digest parity, schema objects larger than metadata, and three streamed creating-Message contents. Sizes are qualification workloads, not request quotas |
| [Loaded tools](ARCHITECTURE.md#authorizing-exact-actions) | `store/tests.zig` `'loaded tools configure'`; loaded-set history and call rejection regressions in `store/sqlite_tests.zig`; schema 53-to-54 forward migration | Strict subsets require a future `find_tools` catalog entry; visibility tests seed stored subsets |
| [MCP missing tool admission](ARCHITECTURE.md#selecting-current-settings) | `'MCP missing tools'`, `'start_agent narrows configured tool names'`, `'replies the Host renders'`, `'openapi requests parse'`, TypeScript request-error tests; `stack-frames -Dcpu=baseline` | All empty-server combinations, one/multiple empty servers, no servers and all servers with records; saved-copy admission across create/update/creating Message/start_agent; same-key refusal replay, maximum advisory size, and a mutation removing the server check. Native Store cases cover SQLite; live MySQL requires its configured fixture |
| Core key domain, including empty keys | `'core preserves empty keys'` | 128-byte accept and 129-byte reject bounds, recovery-binding retention: none located |

## Context, provider output and compaction

### Historical inputs and settings

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Frozen request inputs](ARCHITECTURE.md#operations-and-frozen-requests) | `'selection freezes its'`, `'request preparation'` | Sizes are qualification workloads |
| [Reasoning effort](ARCHITECTURE.md#selecting-current-settings), exact catalog defaults and supported overrides | `'reasoning effort uses exact catalog'`, `'configuration token heuristics and effort'`, `'capture configure requests'`, `'Current settings'`, `'request preparation emits catalog or explicit effort'` | Synthetic request bytes, sealed length and scratch release, including compaction. Catalog support is not live backend qualification |

### Provider validation and output ownership

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Independent requested and reported model identity](ARCHITECTURE.md#codex-wire-binding) | `'provider interpretation preserves independently reported model evidence'`, `dispatch-integration` evidence cases | Exact source-separated certificate, absent sources, differing headers and body, unchanged saved items, original public answer and correlation through restart. Malformed body metadata and conflicting duplicate values for one header still reject. Synthetic, not live provider or cross-model continuation evidence |
| [Answer and tool-call acceptance](ARCHITECTURE.md#accepting-an-answer-or-tool-calls) | `'Bash descriptions'`, `'complete call outcomes'`, `'message phases'`, `'partial answer fixture'`, `'synthetic gpt-6-luna shaped'`, `dispatch_integration.py phased-messages` | Synthetic streams, not recovered live captures. Commentary, partial-answer and unphased messages interleave calls, select one result, replay exact items and survive Host crash/restart. The partial-answer item shape comes from the pinned first-party fixture linked in Architecture, not executed upstream-test proof. Missing finals without calls, duplicate finals and unsupported phases reject |
| [Saved call lines](ARCHITECTURE.md#accepting-an-answer-or-tool-calls) | `store/tests.zig` 'MCP settlement saves one decoded presentation line or the tool name', 'saved MCP call lines survive all work reads pending, running and completed at every boundary'; `session_work.zig` 'saved MCP call lines survive pending, running and completed Actions at every boundary'; `overview_view.zig` 'a saved MCP running line fits overview rows without narrowing its saved bound'; `tool_presentation.zig` 'saved call descriptions allow 200 bytes without widening Labels'; `tools.zig` 'rejected Bash arguments name what is wrong'; `session_view.zig` and `protocol_reply.zig` focused tests | 100-, 101- and 200-byte lines survive pending, running and completed MCP Actions through Current, Activity, Session list and Message progress; overview rows fit long lines at UTF-8 boundaries. Exact 200-byte ASCII, multibyte UTF-8 and escaped lines survive settlement; missing, mistyped, blank, multiline and overlong values fall back. Bash and Labels remain 100 bytes; MCP consent uses the saved line without parsing arguments. |
| [Refusal preservation](ARCHITECTURE.md#codex-wire-binding) | `'provider refusal'`, `'the item grammar'`, `dispatch_integration.py refusals` in `dispatch-integration` | Synthetic refusal-only and mixed text/refusal messages preserve public result and Conversation text through Host crash/restart. Saved neutral parts and replay retain the refusal type. Missing, null and duplicate refusal text, unsupported blocks, delta-only responses and incomplete streams still reject |
| [Usage counts](ARCHITECTURE.md#model-requests-continuation-and-compaction) | `"responses usage maps onto Rui's four counts"`, `'compaction exact threshold zero reservation'`, `'compaction pressure uses the latest accepted output even without usage'`, `dispatch_integration.py` neutral usage columns | Cached tokens split from input, null or empty details, cached above input, duplicate, fractional, negative and over-range counts, a total alone, saturating sum at the threshold. No live cached-token report |
| [Session codec binding](ARCHITECTURE.md#store-format-and-upgrades) | `'a Session pinned to a codec this Host cannot build fences its settings'`, `'persisted settings survive reopen'` | Another codec version or any codec options fence; label CHECK rejects uppercase, leading digit, dot, empty and 17-byte labels and empty options. No second served provider yet |
| [Message text stored once](ARCHITECTURE.md#retaining-accepted-output) | `"a message's text is stored once and its parts replay as lengths of it"`, `"a large message's parts read only their own ranges"`, `'replay fences part damage that keeps every digest'`, `'public assistant message provenance'`, `dispatch_integration.py` saved parts | One public row per message with empty and escaped parts; a part length that overruns or leaves text uncovered, and changed text bytes under the same digest, fence replay. A memo hit reads no part text, so it checks nothing |
| [Prefix seal](ARCHITECTURE.md#prefix-seal) | `'prefix seal'` in `model_adapter.zig` and `prefix_seal.zig` | Restarted-Host rebuilds over six rounds of reasoning, message, call and denied-result history keep and replace the seal; a flipped digest, a longer or shorter seal fail `encoding_drift`, keep it and keep no memo; another anchor is replaced and a later view's seal kept; a memo hit is not rehashed. No upgrade between real Host versions |
| [Codec encode contract](ARCHITECTURE.md#effect-interfaces-and-evidence) and the append-only history span | `'request preparation'` goldens, `'every replayed output item parses equal'`, `"request N+1 begins with request N's history span"`, `'a history memo hit writes exactly the bytes'`; `test-logic` `'a resumed encoder writes what an uninterrupted one writes'`, `'every item at its longest fits max_pieces and names only handles it has'`, `'an encoder resumed from a carry separates its next input item only after an earlier one'`, `'a tool entry escapes'` | Byte-identical requests through the codec over six rounds of reasoning, message, call and denied-result history; a fresh encoder resumed from any element's carry writes the bytes of one encoder never resumed; every item the Host can give, with each handle set it can give it, from every encoder state, takes at most `max_pieces` pieces, the longest exactly that many, and names only handles it has. Only the built-in native codec |
| `provider_codec_failed` | `'an encode failure settles unanswered and releases request scratch'` in `server_execution.zig`; `'a codec that declines fails provider_codec_failed before any request exists and leaves no scratch'` in `model_adapter.zig` | The Responses codec declines an opaque block that carries text, which the Store never holds, so a test fault gives it one in place of an item. A codec declining at `settings`, a message or `request_end` leaves no request, no scratch charge and no retained file. The execution owner settles a codec that declines at `request_end`, after every earlier item already wrote request scratch, unanswered as `provider_codec_failed`, with custody and scratch released and dispatch unfenced, the path `request_write_failed` and `request_seal_failed` exercise in `dispatch-integration`. `provider_codec_unavailable` is not reachable: the Store fences a Session pinned to a codec this Host cannot build |
| [Codec request headers](ARCHITECTURE.md#effect-interfaces-and-evidence) and their order | `"a prepared request carries the Responses codec's headers"` in `model_adapter.zig`; `'ChatGPT headers carry the routing value only when the Turn has one'`, `'an API key goes only over https'` in `providers.zig`; `'a Transfer that fails to start'` in `provider.zig`; `test-logic` `'the request headers ask for the stream'`, `'a header value is printable ASCII'`; `codex-h2-integration` | The Responses codec gives `accept`, `session-id` (hex of the Session's affinity) and `originator` and the prepared request keeps them in that order; the credential path writes only the credential, `user-agent`, FedRAMP and turn state after them, and the synthetic H2 peer sees content-type, codec headers, credential fields, `user-agent`, FedRAMP in that order; codec headers count toward h2's 16 fields |
| Codec headers never name a Host field | `'the Responses headers are lowercase tokens, header-safe, within bounds and name no Host or h2 field'` in `model_adapter.zig`; `'ChatGPT headers carry the routing value only when the Turn has one'` in `providers.zig` | Over every effort and sampled affinities, the Responses headers are distinct lowercase tokens with header-safe values within 8 headers whose values total at most 192 bytes (names are the codec's `RequestHeader` constants and are not counted), none naming a field the Host writes (`authorization`, `chatgpt-account-id`, `content-type`, `user-agent`, `x-openai-fedramp`, `x-codex-turn-state`) or h2's own; every field `providers.Headers` writes is one of those Host fields |
| [Codec classify contract](ARCHITECTURE.md#effect-interfaces-and-evidence) | `'an HTTP error body keeps'`, `'context overflow requires exact valid provider code over HTTP'`, `'a large error body classifies as its small twin does'`, `'a malformed number makes a body not JSON'` in `output_decode.zig`; `'HTTP 429 quota'`, `'quota and policy stream failures permanent'` in `model_adapter.zig`; `'every refusal saves one provider code'`, `'a saved quota record reads back'` in `transport_policy.zig`; `'saved failure codes name what the person can do'` in `failure_class.zig`; `'a file maps read-only'` in `os/pages.zig`; `test-logic` `'classify answers the same with 0xAA or leftover scratch'`, `'the reader accepts exactly the objects std.json accepts'`, `'the reader accepts exactly the numbers std.json accepts'`, `'a value nests at most max_depth deep'` | The Responses classifier, given the sealed body whole through a read-only map, names each provider code it knows as a neutral refusal (quota, plan, policy, model unavailable), which saves `provider_<refusal>` with the provider's code kept in the report, and gives the overflow and report as before, for a body of over 850 KB whose report parts lie at its start and end, and answers the same with its scratch filled with 0xAA or left over from another body; the reader accepts exactly the objects and numbers `std.json` accepts, so a body with a malformed number such as `1.2.3` narrows nothing and keeps no report; a sealed body shorter than its length stays `response_read_failed`. Only the built-in native codec |
| [Codec interpret contract](ARCHITECTURE.md#effect-interfaces-and-evidence) | the grammar, stream, usage and fuzz tests in `output_decode.zig`, ported from `provider_output.zig` with their expected values, among them `'the item grammar rejects unsupported meaning and preserves open fields'`, `'import names the first rule broken in lookup order'`, `'a 4 MiB reasoning item interprets whole as one event'`, `'escaped envelope keys name their fields and repeated unknown keys stay unread'`; `'provider interpretation preserves independently reported model evidence'` in `model_adapter.zig`; `'a write after the map is visible through it'` in `os/pages.zig`; `test-logic` `"the codec's JSON reader names each syntax error as validation did"` in `codecs.zig`, `'every entry point answers the same with 0xAA or leftover scratch'`, `'an accepted item walks as its bag members and parts in document order'`, `'a function call, a reasoning item and the output list walk as acceptance splits them'`, `'an event that is not JSON fails for the reason validation names'`, `"the judge's verdict on an item reaches the shell as its reason or replay rule"`, `"a provider's error names its report, its refusal and context overflow"` | The codec's interpreter and the shell's grammar accept and reject what `provider_output.zig`'s validation did, which an oracle running both over every one of these streams (153 accepted, 369 rejected) proved before validation was deleted: the same event data and metadata bytes, validated counts, digests, answer, evidence, provider failure and rejection code, kind and detail; the item tables now name each rejection's reason, and the JSON reader's error names match validation's by a recorded digest. An escaped envelope key names its field, so an escaped repeat of `type` is a duplicate, and repeated unknown keys are not read. A 4 MiB reasoning part reaches the codec as one slice; event data written after the map is read through it; the codec answers the same with its scratch filled with 0xAA or left over. Only the built-in native codec |
| [Reasoning text is private evidence, not replay input](ARCHITECTURE.md#codex-wire-binding) | `'every replayed output item parses equal to the item the provider sent'`, `'without its private reasoning text'`, `'large private reasoning item within each advance'`, `'fences a saved provider bag whose bytes changed'`, `'replay fences part damage that keeps every digest'` | Synthetic saved items, saved with the replay rule the import grammar judges: ordered, reordered, whitespace and escaped `content` keys drop under three emission schedules while summary, `encrypted_content`, status and open fields replay exactly; empty `content` and a prefix-named open field stay. Saved bag bytes whose digest no longer matches fence on replay, as do a missing part, an inflated part count and a part that does not fit its item. Not live backend acceptance evidence |
| Empty selected answers complete with no result text; nonblank answers retain surrounding whitespace | `'completed empty assistant answers'`, `dispatch_integration.py empty-answers`, `human_cli_integration.py empty-answers` | Synthetic phased and unphased empty/Unicode-whitespace answers, exact nonblank bytes, inspect/read-result, crash/restart replay and a usable TUI composer. Existing missing-final, duplicate-final, malformed and incomplete controls remain required |
| [Codex per-Turn sticky routing](ARCHITECTURE.md#adapter-historical-reads) | `'turn state observation'`, `"a routing value replays one Turn's first value"`, `'owner changes invalidate paused Turns'`, `"two providers' Turns keep their values"`, `'ChatGPT headers carry the routing value'`, `codex-integration` turn-state journey | Synthetic h2c fixture: no value at Turn start or after an error answer, first successful value replayed unchanged on a 503 retry and a tool continuation, none for a later Turn in the same Session or a continuation after Host restart, and no Store row holds it. Account/FedRAMP changes invalidate paused Turns and reject old-epoch completions before and after the original account returns; refresh preserves the epoch. These owner transitions, first-value and least-recently-used replacement are value tests; the fixture credential cannot switch accounts. Not live routing evidence |
| Codex credentials, H2 and cache affinity | `codex-integration`, `codex-credential-integration`, `codex-h2-integration`, `'Codex affinity'`, `'refresh transport'`, `'only a refresh proven'`, `'sent or uncertain refresh'`, `'refresh rejection bodies'`, `'selection refreshes'` | Synthetic. Raw h2c peers cover not-sent evidence (refused connect, peer gone before its SETTINGS, an HTTP/1.1 peer) and a sent request with a lost reply; `test-h2`'s exchange cases cover the total deadline's sent flag. Every failure after HEADERS are packed retains pending. Value tests cover body codes and the inclusive 300-second margin. H2 needs `h2==4.3.0` ([requirements.txt](tests/integration/requirements.txt)) and is not in `check-full`. Live refresh HTTP is unverified |
| [One forced refresh after a managed model 401](ARCHITECTURE.md#authentication-and-transport-lifetime) | `'a refresh claim'`, `'a forced refresh runs only'`, `'only an answered model 401'`, `'a 401 forced refresh is claimed'`, `codex-integration` forced-refresh journey | Synthetic h2c covers an identical replacement, a second 401, login-required failure and newer ready or pending credentials preserving the answered 401 and correlation without resend. Value tests cross ready/pending state with equal/different generation. Store tests cover the durable claim across transient failures and reopen, stale binding and the final Attempt boundary. The fixture republishes synthetic tokens, not remote refresh HTTP. Cross-Host generation exclusion is a unit test; crash recovery is Store reopen, not a Host-process cut. Stop during refresh is untested |
| [Codex request envelope](ARCHITECTURE.md#codex-wire-binding) and supported-model compaction defaults | `codex-integration`, `codex-h2-integration`, `'supported model compaction'`, `'request preparation'`, `'only the pinned table'` | Synthetic outgoing HTTP bodies and revision header, all nine exact IDs and both parallel policies. Unknown IDs retain no inferred trigger and no parallel calls. No live backend qualification |
| Live Codex journey | `python3 tests/integration/codex_live.py /absolute/path/to/rui --live --model EXACT_MODEL` | Opt-in with authorized credentials. Never a gate |
| Compaction on context overflow | `'compaction overflow'`, `dispatch-integration`, `human_cli_integration.py` | Synthetic. Live compaction: none located |

## Execution, retries and permission

### Settlement and recovery scenarios

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Settlement scenarios in the composed gates | `check`, `check-full` | A fixture marker detects duplicate execution; Store facts remain recovery authority |
| Owner invariants at stable checkpoints | `'custody sequences'`, `'slots agree with custody'` | Stable checkpoints only |
| Shared settlement commit order | `'Action settlement'`, `'exact model interruption'` | None |
| [Bash launched, result not committed](ARCHITECTURE.md#commit-boundaries-and-crash-recovery) | `bash-recovery-integration` | Uncertain Bash is never replayed |
| Canonical settlement cannot publish a result | `canonical-failure-integration`, `'Host fences'` | None |
| One sibling settles while another is unresolved | `dispatch_integration.py` | Edit sibling: none located |
| [Retries and timeouts](ARCHITECTURE.md#retries-and-timeouts): 1 + 3 Attempts, 2, 4 and 8 s backoff plus positive post-floor jitter, 5 min timeouts | `'model retry decision'`, `'retry jitter'`, `'retry settlement adds actual entropy'`, `'Retry-After'`, `'inactivity defaults'`, `bash_owner_integration.py` | Deterministic clock and entropy prove floor, positive offset, bounded spread and saturated extreme dates without sleeps. Retries may duplicate billing. Bash 5 min default: none located |
| HTTP 429 quota, refusals at any status and rate limits | `'HTTP 429 quota'`, `'HTTP quota refusal'`, `'an HTTP error body keeps'`, `'transfer decisions exhaust'`, `dispatch_integration.py http-quota` in `dispatch-integration` | Three distinct permanent quota codes, valid reset and request correlation through reopen, one Attempt, unchanged temporary rate-limit recovery. A known refusal code is permanent at 404 and 503 with its own `provider_` code; another code keeps its status code. Each failed Turn keeps the provider's report (`code` else `type`, `message` else `detail`). Unknown, duplicate or malformed codes grant no quota or refusal authority. Synthetic provider only |
| SSE failure classification, clean close and nullable evidence | `'provider interpretation'`, `'provider completion treats null'`, `'retryable stream rejections'`, `dispatch_integration.py stream-failures` in `dispatch-integration` | Synthetic `error` and `response.failed` retries, permanent quota and policy controls each saved under its own `provider_` code, malformed framing and code controls, four-Attempt exhaustion, exact final diagnostic and correlation through reopen, and no accepted failed prefix. `'a provider error event keeps'` and the integration Turn outcomes pin the report: one line, each part shortened at a whole scalar, kept for overflow and exhaustion. No live provider evidence |
| SSE framing and notification authority | `'SSE line framing'`, `'SSE multiline data'`, `'SSE decoded data'`, `'metadata notification'`, `dispatch_integration.py sse-framing` in `dispatch-integration` | BOM and all line endings, exact LF insertion and nested replay spelling through restart, large payload windows, ignored unknown fields/events versus strict output-item namespace, malformed JSON and pending EOF. Shared raw/decoded/metadata charge ceiling and disposal, retained unlink custody, unchanged failed-response bytes and raw rejection offsets. Synthetic provider only |

#### Runnable Bash caller acceptance audit

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Saved Bash result and cleanup recover after a Host crash | `bash-walkthrough` | Not live provider, power loss or a crash during an active Attempt |

### Bash lifecycle scenarios

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Optional literal stdin: exact 122,880-byte decoded boundary, strict UTF-8 without coercion, Unicode/NUL/trailing bytes, large stdout and stderr before reading, EOF, early close and unread-input timeout; missing/null retain `/dev/null` | `bash_integration.py`, `'Bash stdin'`, `'resumable Bash parser'` | Private unlinked read-only offset-zero file, charged to shared scratch; no stdin pipe |
| Exact Action input through pending restart, continuation and uncertain-attempt recovery without replay | `bash_integration.py`, `bash_recovery_integration.py` | Existing Action JSON format; no Store-format change |
| Approval renders supplied literal input and denial launches nothing | `human_cli_integration.py persistent-permission` | Terminal-escaped preview; explicit nullable schema and independent provider/request goldens remain exact |
| Empty `session send` from empty/null tool stdin refuses without a published capture or Message admission; stop and infrastructure shutdown retire charged input with the original group | `bash_integration.py`, `bash_lifecycle_integration.py` | No change to peer routing policy |
| Expired Bash budget: exact budget, partial output and retry guidance in the saved result | `bash_owner_integration.py` | Successful commands omit timeout guidance |
| Stop during descriptor decoding launches nothing | none located | None |
| Original group does not retire naturally | `bash_lifecycle_integration.py` | Retirement facts precede reuse |
| [Detached writer survives](ARCHITECTURE.md#releasing-custody) | `'finite tail closes'`, `bash_lifecycle_integration.py` | Capture ends finitely without claiming retirement |
| Cleanup facts unavailable: fence only while facts stay unconfirmed | `bash_lifecycle_integration.py`, `'service acts'` | macOS `EPERM` |
| Cross-scenario matrix: splits, cutoff and status | `'resumable Bash parser'`, `'wide process exit'` | Native Linux and macOS. Cross-compilation does not qualify `WNOWAIT` |
| Capture cannot be completed | `'stops a running Attempt'` | None |
| [Bash environment](ARCHITECTURE.md#bash-environment): the Turn's first Bash sees the sending terminal's environment led by this `rui`, without the Host's own variables or the terminal's `RUI_` names; a later terminal's Message switches it | `bash_environment_integration.py`, `'received keeps well-formed entries'` | Linux; the macOS system `PATH` and live terminals are lane evidence |
| A peer's Message never displaces a person's environment and fills a Session that holds none; every order of offers keeps the highest rank | `bash_environment_integration.py`, `'Rank.outranks is a strict total order'`, `"every order of offers keeps each Session's highest rank"` | Fallback after a Host restart: unit evidence only |
| Only a fresh admission installs, after commit and before the Store worker takes another request; a replay or rejection installs nothing | `'message admissions remain queued in order'`, `'a peer sender is resolved from its Action handle'`, `'message conflicts and failed commits cannot create another admission'` | None |
| An environment over 64 KiB is refused before connecting, naming its largest variables, and its capture recovers from a smaller environment; no environment value reaches a caller record | `bash_environment_integration.py`, `'a Message uploads its environment ahead of the unchanged record'` | None |
| Host refuses a missing header, an oversized or malformed environment, a repeated name and the header on another route before admission | `bash_environment_integration.py`, `"a Message's environment header and entries are checked before admission"` | None |
| Evidence layers | `test-logic`, `bash-owner-integration`, `bash-lifecycle-integration` | No reruns to pass |
| [Frozen catalog and permission mode](ARCHITECTURE.md#authorizing-exact-actions) | `'frozen catalog'`, `'allow once survives'` | None |
| Bash-only catalog and configuration: exact `bash`/`none` CLI, `["bash"]`/`[]` wire; removed Edit and duplicate/alternate spellings reject | `human_cli_integration.py`, `dispatch_integration.py`, `'Current facts'` | Public arrays and private SQLite masks remain distinct representations |

## Exact Edit

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Exact Edit](ARCHITECTURE.md#exact-edit) ranges, copyback, failures | none located | Edit execution is unimplemented |

## Submission recovery

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Same-key caller recovery](ARCHITECTURE.md#caller-capture-and-recovery) | `human_cli_integration.py`, `control_integration.py` | Direct clients only |

## Controls, inspection and local server

### Durable controls

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Control replay and conflicts](ARCHITECTURE.md#recovering-a-submission-after-a-lost-reply) | `'exact model interruption'`, `'idle Session stop'`, `'controls remove scheduled retries'`, `'allow once survives'`, `'model revisions'` | Reopen is not crash recovery |
| Native control replay | `control_integration.py` `prove_idle_stop_wire_recovery`, `prove_retry_wait_control`, `check_schema`, `bash_integration.py`, `admission_integration.sh` | None |

### Control races and acknowledgement

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Gated race ordering: sealed holds, four incomplete terminal inputs, dispatch stall witness, silent-sibling expiry, exhausted-recovery admission | `control_integration.py`, `human_cli_integration.py` `incomplete_input_case`, `dispatch_integration.py` | Exhausted recovery permits one real call before an opt-in nonblocking hold. The fixture requires its native receipt and owned empty FIFO before checking due/new launches, then releases recovery and checks drainage. A first-call full-drain mutant must fail the unresolved-sentinel assertion. Incomplete inputs run serially against one Host. Pasted typeahead before readiness must not approve an Action. The stall witness owns one inactivity failure; exhaustion and progressing cases own theirs |
| First committed control wins; [hint grants no authority](ARCHITECTURE.md#live-control-notification) | `prove_pre_handoff_stop`, `prove_sealed_interruption_and_cleanup`, `'without a control hint'` | Not remote termination. Omitting only the superseded branch's `finishCustodyNow` must fail the zero-custody deadline; no automated mutation located |
| Release within eight seconds | `HostDiagnostics.wait_model_cleanup`, `wait_for_execution_release`, `claim_inspection`, `host_process_test.py` | Not an idle-population census; no native macOS coverage |
| Control case disposal | `stop_control_case`, `prove_control_disposal_oracle` | Incoming assertion stays primary; cleanup failure still fails |
| [Stop excludes selected prefix](ARCHITECTURE.md#stopping-selected-work) | `'Session stop freezes'` | Successor-selection race: none located |

### Inspection and waits

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Request and adapter waits](ARCHITECTURE.md#work-state-and-wait-conditions) | `request_wait_integration.py`: completion and ask-mode permission return exit 0; timeout returns exit 5 with the latest observation; unknown key returns exit 4; Host stopped mid-wait returns the keyed read-error envelope and its status; restart mid-Bash exposes `recovery`; a Host-side count or lossless test observation proves a tier-2 `not_modified` hit while a sibling Session commits. Focused client tests pin poll schedule and state-to-exit mapping without sleeps; CLI argument tests pin the 300-second default and positive 86400-second bound. | Waits never start, resume or retarget work, or hold capture/Host resources between polls. Permission returns do not replace exact-target validation. Timing alone is not evidence of a token-tier hit |
| Opening and older history: frozen opening, exact pending count without previews, each admitted Message exactly once across older pages, listing and retained copy after eviction | `human_cli_integration.py` | Equal-content Messages included; labels as of their read |
| Current selection, pending count, ten recent Messages | `'Current facts'`, `current-facts-integration`, `store/sqlite_tests.zig` `'Current selects active then queued'` | Suppressing callbacks beyond 128 rows must fail the complete count. Fixed storage is not process memory or Mac evidence |
| [Per-key outcomes as data](ARCHITECTURE.md#outcomes-and-observation-errors) | `human_cli_integration.py`, `store/tests.zig` `'Current reports progress alongside'` | Composed reads may span commits. A timeout proves neither rejection nor work failure |
| [Full report inventory](ARCHITECTURE.md#capturing-and-delivering-reports) and scratch | `store/tests.zig` `'Full exposes exact closed'`, `'report scratch exhaustion'` | Latency and growth matrix: none located |
| [Mutation presentation](ARCHITECTURE.md#public-operations) and canonical envelope | `canonical-failure-integration`, modes `producers`, `committed`, `interactive`, `presentMutationReply` tests | Negatives fail at exact assertion, not setup. PTYs use one unrenewed ten-second exit deadline. No macOS, power-loss or aggregate claim |
| Null and binding corruption rejection | `canonical_failure_integration.py nulls`, `bindings`, `null-interactive`, `binding-interactive` | Unfixed null witness fails at invalid-response; omitted binding check fails native mismatch and caller typed-error assertions, not setup |
| Keyed observation decoder | `canonical_failure_integration.py keyed`, `keyed-bindings`, `keyed-output` | `keyed-bindings` and `keyed-output` fail on unchanged baseline at omitted-binding and unknown-DOM assertions |
| Keyed owner footprint | `message_observation_resources.py BASELINE CANDIDATE` | Uninstrumented ReleaseSafe. Not aggregate memory or Mac |
| [Caller capture and recovery](ARCHITECTURE.md#caller-capture-and-recovery) | `human_cli_integration.py` | Uncertain Bash effect never replayed |
| Overview model picker and read-only Session `/model` | `model-picker-integration` in `check` and the callers partition: plain-PTY filtering, selection, effort, sign-in, saved defaults, narrow view and failed-save recovery; Session `/model` does not change the default. | Fixture providers and libghostty-vt; no live account, physical terminal or power-loss claim. Loading, list failures and durability-unconfirmed saves remain untested through a PTY. |
| [Bare entry](ARCHITECTURE.md#human-entry-and-authentication) overview and `require_model` | `human_cli_integration.py` `overview_cases`: bare `rui` creates nothing and shows the empty-Store hint; composer `/configure --permission-mode ask --label` then Enter sends one `session start` with `require_model` and those settings and opens the new Session; Enter opens a row and Esc returns; `session resume` then Esc shows the overview; a start captured and never sent recovers; in a conversation the Session line ends with `ctrl+x stop` while there is work, and one Ctrl-X stops the Session at the Host and the hint goes. `SessionFrontend.zig` `'Ctrl-X stops the open Session through the overview at once, asking nothing'`; `overview_view.zig` `'ctrl-x in a conversation stops its Session as on its row, listed or not'`; `Overview.zig` `'while a conversation holds the terminal the worker sends only its stop, and a listing's failure stays the overview's'`; `session_line.zig` `'a line is written again when its width or facts change'`, which drops `ctrl+x stop` whole on a narrow line. `canonical_failure_integration.py`: a canonical Store failure in a start's reply restores the terminal, exits nonzero and names the start's recovery handle; a mismatched or null-code reply keeps the overview open and names it. Store selection, the login offer, TMPDIR and capture-failure cases expect the overview and no request. `Overview.zig` tests: each effect runs its client operation, each source reaches the core, a reply is unconfirmed only when the request may have reached the Host, a canonical Store failure in a listing, first-line read or start ends the overview, Ctrl-C leaves while output is blocked, and the composer is the conversation's line editor: bytes that are not text, an overfull draft, every Shift-Enter and Alt-Enter encoding and caret edits. `'every key does what the overview's table says'` presses each key of `src/keymap.zig` in each of its encodings on an empty and on a rejected draft and expects the table's action, or nothing where it binds none; `'Shift-Up and Shift-Down select'` the row above and below whatever the draft holds; `'a start freezes the composer'` until its answer while the table's keys still act, and `'a start sends what its Enter captured'` after Esc clears the draft and settings. `overview_view.zig`: an open or unconfirmed stop keeps its row stopping and refuses a second stop; only your own Session at work (thinking or running a tool) turns the spinner, in step, while every other mark (your approval, queue, retry or stop, others' work, ends) holds still, and ASCII, NO_COLOR and a faded screen hold still; a queued row shows `◌` and a row's words are the Overview groups and rows case's; and never in ASCII, `NO_COLOR` or a faded view; the screen asks for frames only while a spinner shows, not once it scrolls away, its work ends, or the work is another's; a frame writes only the spans that changed. `Overview.zig` tests also cover each frame rewriting your working Session's spinner alone and holding still without colour, and the poll budget cut to the next frame only while the screen spins. `host_launch_integration.py`, `store/tests.zig` `'capability-required configuration'` | Mac terminal, interrupted-login and post-send lost-reply evidence required. Ctrl-X stop and the Host-unavailable view are verified with their own issue |
| Alt-A archive on the overview and exact conversation | `overview_view.zig` `Alt-A` tests cover the shared policy, captured reference, absent listing, busy/approval confirmation, server-only visibility, archived/archiving guards and pending/unknown duplicate suppression. `Overview.zig` and `SessionFrontend.zig` `Alt-A` tests cover unchanged draft bytes, caret/revision and retained original, confirmation precedence and permission-offer spending. `SessionFrontend.zig` conversation slash tests cover shared archive/restore ownership, submitted-line and completion consumption, busy/approval confirmation, mixed-input duplicate suppression, recovery handles and propagated dispatch errors; `Overview.zig` checks the exact unlisted open reference through the worker. | Plain-PTY verify-rui capture required. No live provider needed |
| Overview look: Khadi skins, background query, top lines | `overview_view` in `test-logic`: every colour role has an entry in both skins and its nearest 256-colour entry; whole screens at 80x24 and 200x60 for each skin and depth, played through a model terminal that checks every cell's colour; `NO_COLOR` draws bold and reverse only; skin choice for a dark, light and missing answer; Indian grouping at 0, 999, 1,000, 1,00,000 and 1,00,00,000; the headline and Host health, stable top/list positions through Session completion, failure and Host restarts, reclaimed list space in narrow viewports, and the Host-stopped band's priority over provider alarms. `TerminalInput.zig` `'a background answer is a colour report; a malformed one is dropped and keeps the next key'` | The OSC 11 answer and the 200 ms wait are not measured on physical or Mac terminals. Fonts are the terminal's choice |
| [Overview groups and rows](ARCHITECTURE.md#staged-persistent-input) | `overview_view.zig` in `test-logic`: `'a Session waiting on an Action leads in Needs you, yours or not, and Yours keeps the rest'`; `'queued rows sit last in their group, longest wait first, after work newest first'`, a due retry among them; `'row segments say each state with its mark, and words only for a cause or a wait's countdown'`; `'row segments drop the detail column on a narrow screen and keep mark, title and age'`; `'a needs-you row reads its waiting Action's command once, and again only when the Action changes'`. `session_view.zig` in `test` `'only a Bash Action names a command for its row, whatever another tool's arguments look like'`, with an MCP Action whose arguments parse as Bash's. verify-rui screenshots of the App overview at 80 and 200 columns, Unicode and ASCII: **pending the App shell wiring** | Values only until the App overview draws them; the row text is checked as segments, not cells on a terminal |
| [Counts line and live memory](ARCHITECTURE.md#human-entry-and-authentication) | `overview_view.zig` in `test-logic`: `'the summary counts what the counts line shows by mark: needs you, working, queued and failed'`; `'the counts line counts by mark, leaves zeros out, and colours only needs you and failures'`; `'the counts line shows the slots only while something queues, and memory on the right'`, with memory dropping first at narrow widths, `rui` before `tools`; `'the counts line names the archive view only off the default'`. `process_memory.zig` in `test-logic`: `'rui adds this TUI and its Host, and tools add every process below the Host'`, `'with no tool process, or no Host, tools is null; an unreadable Host leaves rui as the TUI'`, `'a tool that exits mid-walk is left out, and its listed children with it'`, `'a process listed twice, or a cycle a reused pid makes, counts once, and the walk stops at its bound'`, `'totals saturate rather than wrap'`. `host_identity.zig` in `test` `'the live process table reads this process's memory and a child it starts'`. The once-a-second read in the App overview: **pending the App shell wiring** | The live reader has run on Linux only. Draft PRs select no macOS job, so the macOS reader (`proc_pid_rusage`, `proc_listchildpids`) first runs in the macOS `check` once the PR is ready for review. macOS and Linux numbers are close, not identical; a tool that leaves the Host's tree is not counted |
| [Inline `/upgrade`](ARCHITECTURE.md#store-format-and-upgrades) | `upgrade_status.zig` in `test-logic`: `'a run's line: the check, what the restart will do, each step, and a stop'`, `'how a run ended: a notice, or held until another /upgrade when the client cannot go on'`, `'ASCII spells the ellipsis and dot'`. `overview_view.zig`: `'/upgrade runs inline: Esc cancels it before the draft, checking or preparing, and its end sets the Host hold'`, `'every place an Upgrade run can stand decides the hold, Esc and another /upgrade from that one value'`, `'another /upgrade while one runs changes nothing: its progress and Esc stay'`, `'/upgrade is never refused as a Host request: the status bar shows its run at first, while it runs and after a hold'`. `UpgradeJob.zig`: `'the run's status: checking, the release found, each restart step, then how it ended'`, `'a stop asked for shows until the run ends, before the worker starts and while it prepares, and not once it published'`, `'Esc and publication race on one gate: whichever comes first holds'`, `'a cancel before the worker starts ends the run cancelled without checking'`, `'a release already selected but not yet running in the Host is found, so its restart shows'`, `'how a run ends, as the status bar names it'`, `'a check that may not install here names why'`, `'a newer build already selected installs quietly: no older release found, then superseded'`, `'the selected build already current installs quietly: no found release, then up to date'`. `upgrade-integration` on the App overview's status bar: Esc cancels while preparing, then a second `/upgrade` installs and restarts the Host; Esc after publication changes nothing; Esc during the check cancels it and its `--version` probe is reaped; SIGINT during the check and after publication restore the terminal, the latter printing the publication receipt; a checksum and cleanup dual failure prints its retained path on exit; a conversation's `/upgrade` is the same run: Esc cancels while preparing, a second `/upgrade` installs and restarts the Host, and `/status` answers once the conversation has read again; real tmux. `session_upgrade.zig` in `test-logic`: `'an Upgrade holds Host requests from /upgrade until the listing is read under the selected Rui'`, `'a block lasts until another Upgrade, and a listing does not lift it'`, `'an unchanged run reads the listing again, and a conversation's failure blocks'`. `SessionFrontend.zig`: `'/upgrade starts the overview's run, consumes only its line and keeps the original submission; Esc is the run's'`, `'a run quiesces the conversation's Client work, and its end holds Host requests until the conversation reads again'`, `'a conversation is at rest for an Upgrade only with no work running or finished and not yet joined'`, `'no command waits its turn across an Upgrade: /upgrade is refused while one does, and a run's hold refuses every one after'`, `'an Upgrade's hold shows no permission card and sends no decision, shown or prepared'`. `Overview.zig`: `'a conversation's /upgrade waits for the conversation's running read, though the overview ticks first'` | A conversation's failure to settle its Client work or to read again after the run is not exercised. That a withdrawn permission card shows again after the hold is not exercised. A failure after publication still reads `nothing changed`; its exit receipt is exact |
| [Unconfirmed send on the status bar](ARCHITECTURE.md#staged-persistent-input) | `overview_view.zig` `'an original Esc left unconfirmed is named at once and recovered on departure, until the ledger is full'`: `unconfirmedLine` names the newest unconfirmed send, with its recover key when it has one, and sets no notice. `overview_counts_cases.py` `unconfirmed_status` (the PTY check of `! Not confirmed · ctrl+r retries original`, then `! Not confirmed · rui request recover KEY`, on the status row) | |
| [Overview clicks](ARCHITECTURE.md#human-entry-and-authentication) | `overview_view.zig` in `test-logic`: `'one click on a row opens it, under Enter's rules'`, which also checks a click during an Upgrade selects without opening; `'a click on a folded group's more line opens it at its first hidden row'`; `'a heading, a gap and the empty list's line name nothing to click; a row names its Session'`; `'a click that names a Session gone from the list since it was drawn changes nothing'`; `'a click on a Session while a panel shows opens it and closes the panel, as Enter does'`; `'every click obeys the input mode: a frozen screen takes none, whatever it names'`; `'a click on the counts line's view name returns to the default view, as /sessions does'`. `GroupedList.zig`: `'GroupedList reports a left press as what the row under it drew with, after scrolling; a row with nothing takes none'`, `'GroupedList reports what a row drew with, not what its index holds by the time of the press'`, `'GroupedList ignores a press below its last row'`, `'GroupedList without on_press only scrolls on the wheel'`. `Overview.zig`, presses as a terminal sends them through App's hit test: `'a click on a Session row, as a terminal sends it, opens the row under it after the list scrolls'`, `'a click on a group heading, as a terminal sends it, opens nothing'`, `'a click on a panel's or the model picker's lines, as a terminal sends it, opens no Session: only the Sessions hear a press'`, `'a click on the counts line's view name, as a terminal sends it, lists the default view'` | The `more` line's press is the same `on_press` path, checked in the core only. Not verified in a real terminal's mouse reporting |
| [Saved defaults](ARCHITECTURE.md#store-selection-and-defaults) | `'preference edits'`, `human_cli_integration.py` | Not credential, launch, Mac or power-loss |
| [Release-supported model IDs](ARCHITECTURE.md#supported-model-ids) | `human_cli_integration.py compiled-models` in `check` | Exact shipped help/error/notice membership; malformed explicit and saved IDs rejected before capture or input reads; accepted IDs, retained stale pins, one detached startup notice and quiet attach, valid and cleared defaults. Client defaults remain shipped; fixture endpoints do not prove account entitlement or live qualification |
| [Runtime model catalog](ARCHITECTURE.md#supported-model-ids) | `store/tests.zig` `runtime catalog` cases on SQLite and MySQL, SQLite read-failure fencing, capability/list renderer tests and the native client oversized-reply test; `codex_h2_cases.py saved_catalog_run` through `codex-h2-integration` | No source, changed window/efforts, saved-only and removed IDs, null windows, authoritative empty generations, restart, conditional 304, failed refresh/publication, coherent reads during refresh, list order/known/source and replies beyond the shipped bound. The Store round-budget test pins one catalog-read round and one added configuration-admission round; historical frozen compaction and offline defaults remain unchanged |
| Preference publication faults | `preference-policy-integration`, `zig test -lc src/preferences.zig --test-filter 'directory sync'` | Linux and macOS in `check`. No crash or power-loss durability |
| Provider selection, credential status | `'installed local credential status'` | Selection does not prove remote acceptance |
| Login chooser, keys and SIGINT | `'login owner'`, `codex_token_wire` tests, `human_cli_integration.py` | Ordinary terminal line input handles echo, erase and signals before App opens. Exact single-letter choices, EOF, invalid lines and overflow keep their caller outcomes; the chooser changes no termios. Hidden API-key input still restores its modes and wipes secrets. Full synthetic exchange and Mac PTY remain required |
| Masked login signal installation | `login-signal-integration` | Linux only. Unfixed owner must fail |
| Chat footer and state-only empty input | `test -Dtest-filter=SessionChrome`, `test -Dtest-filter=InputArea`, `test -Dtest-filter=Composer`; SessionChrome pins the visible-list gutter and whole-item ellipsis across context values at narrow width; InputArea pins the footer above the unchanged bottom state slot. `SessionFrontend.zig` `'App Session footer takes list visibility from Root across desktop and phone resizes'` covers both sides of the shell boundary. `human_cli_integration.py session-chrome` checks the unchanged bottom state slot, stable identity and active keys; its `caller-core` row keeps permission mode in the status panel and out of the footer. `overview_counts_cases.unconfirmed_status` checks separate chat state/retry cells before the unchanged overview recovery notice. `frames.json` chat, chat-failed and approval reject placeholder and permission-setting hints | Native PTY and L2 captures, not physical input; overview hint text is unchanged |
| Per-chat drafts | `test-logic -Dtest-filter=session_drafts`: whole-snapshot put/take, replacement, stateless empty removal, empty rejection/recall retention, allocation failure, independent Sessions and deinit; `test-logic -Dtest-filter='SessionInput snapshot'`: recall anchor, stale reads, completion and retained submission custody; `test -Dtest-filter='App Session draft'`: A → B → A retains multiline UTF-8 text and caret through back, peer and detached leave paths, including overflow- and malformed-rejected drafts whose Enter still refuses; sending A clears only A. A mutation dropping rejection on restore must fail at the no-send assertion. `frames.json` state `chat-draft-kept` returns through the overview and reopens the saved draft | Frontend tests use App events and an in-memory draft owner; the frame recipe is L2 tmux, not physical input |
| [Bounded editor](ARCHITECTURE.md#staged-persistent-input) | `test-logic -Dtest-filter=TerminalEditor`, including `'oversized marked paste preserves the draft and caret and accepts the next edit'`; strict malformed-key regressions in the vaxis patch; `human_cli_integration.py long-input` and `renderer` | Typed text accepts 65,536 bytes and rejects 65,537 even after Backspace. Oversized marked paste restores the preceding draft and caret, including partial UTF-8 and a joiner merging with the original suffix; the next typed edit and send still work. The overview refusal table checks the notice without clearing the draft. The overview and chat unbound-input tests check that no notice is posted and the draft is unchanged; the chat test also checks redraw when an unbound chord closes the shortcuts overlay. Malformed keys never authorize; modifier 256 is valid, unknown keys are ignored. Linux PTY is not Mac display or physical keys |
| [Lost-reply recovery](ARCHITECTURE.md#recovering-a-submission-after-a-lost-reply) in the composer | `human_cli_integration.py`, `zig test src/SessionSubmission.zig -lc --test-filter 'submission bounded'` | Count mutation exchanges, not only provider runs. Removing digest check must fail |
| Tool activity presentation | `session_view.zig` tool header tests cover every outcome, first-line split and numeric failed exit; `session_history.zig` tool suffix tests cover exact raw tails, sizes 0/1/8191/8192/8193 and multiple windows, mixed spans, the 128-KiB ceiling, discarded-prefix wire corruption, scratch corruption/dropped writes and split UTF-8 escaping. `human_cli_integration.py persistent-permission` checks header-only live, reopening and older history, bounded details and unchanged canonical/model/raw-export bytes | Native Linux and macOS visual qualification required |
| [Conversation keys](ARCHITECTURE.md#human-entry-and-authentication) | `SessionFrontend.zig` in `test`: `'Ctrl-R beside a ready Action refuses its line'` in every encoding; `'Ctrl-R while approval is paused'` keeps the draft and recovers nothing; `'an Esc that expires'` does what a whole Esc does at the Action, from a paused draft and from the settled view; `'every way out of the conversation ends consent'`; `'Esc at the latest view returns to the overview unless unsent text or a choice would be lost'` (standalone frontend without draft custody) and `'Esc hands an unconfirmed original to the overview while it has room, and releases a rejected one'`. The App's per-Session drafts let Esc-with-text return to the overview; `direct-pty` `bare-esc-expiry` reopens the fixture's only Session, checks its identity and restored draft, then submits `abZ`. `overview_view.zig` `'an original Esc left unconfirmed is named at once and recovered on departure, until the ledger is full'`. `human_cli_integration.py` `persistent_input_cases`: Esc after a lost reply shows `! Not confirmed · rui request recover KEY` on the overview, and quitting prints that key's recovery line. | Linux PTY replay, not physical keys |
| [Copy](ARCHITECTURE.md#staged-persistent-input) | `human_cli_integration.py copy`: before an answer `/copy` and `/copy code` say `No answer to copy yet.` and write nothing; after one, each writes exactly one `ESC ] 52 ; c ; BASE64 ESC \` of the answer and of its last complete fenced block and the Session line says `Sent to clipboard`; a block of exactly 75,000 bytes is sent, and an answer over that says `Too large for the clipboard · /copy file` and writes nothing; `/copy file` saves the exact answer, mode 0600, and names it, and keeps 0600 over an earlier 0644 file; with the name a link to a 0640 sentinel, it leaves the sentinel's bytes and mode unchanged and replaces the link with a regular 0600 file holding the answer, leaving no temporary file. `SessionTerminal.zig` `'the clipboard takes its bytes as one OSC 52 sequence, whatever their size'`: several windows, a partial group, and CAN before the next write after a short file; `'a clipboard copy interrupted while the terminal is full ends with CAN before leaving's controls'`: a key pumped mid-copy leaves, and restoration, or the next frame when it stays, sends CAN before anything else, with the alternate scroll its report asked for only after it. `AnswerRenderer.zig` `'the last code block is the last complete fenced block'` in `test-logic`, whole and a byte at a time | Linux PTY and libghostty-vt, not a physical terminal's clipboard |
| Answer code and tables | Focused `AnswerRenderer.zig` tests cover code/strong/emphasis/links inside cells, every feed split, end-of-answer termination, bounded literal overflow without byte loss, CJK display widths and `NO_COLOR`. `ConversationViewport.zig` `'code bands cover blank and wrapped rows'` covers every append split, widths 1–16, clipped continuation rows, retention, prepend, body foreground and colour-disabled backgrounds; `transcript_selection.zig` `'copying code across wrapped and blank band rows'` copies text without presentation markers. `AnswerRenderer.zig` `'plain fenced code never emits a background'` covers every feed split with colour on and off, blank and long lines, EOF fences and escaped source controls; history and answer-adapter tests cover terminal/viewport destinations with both colour settings. Reverting mutations must fail their intended assertions | Native in-memory rendering, not physical-terminal palette or click handling |
| Answer links | `AnswerRenderer.zig` in `test-logic`, whole and a byte at a time: a Markdown link shows its text as an OSC 8 link, a bare web address or local `/` or `~/` path shows itself without trailing punctuation (including `;`) or an unopened `)`; local paths cover explicit HOME expansion, bytewise URI encoding, invalid or missing HOME, UTF-8/control/bidi rejection, code/emphasis and Markdown-target exclusion, the 2,048-byte encoded boundary and literal overflow through a token; broken or unsupported links show every byte; `ConversationViewport.zig`: rendered local path cells carry their file URI while the semicolon cell stays unlinked, and cells carry the hidden address at every append split and take no cell for it, through wrapping, escaping, prepended older pages, and eviction that cuts an address leaves its text unlinked; `SessionScreen.zig` `'links stay within the cell memory budget at every frame and over many frames'` | Not a physical terminal's click handling |
| [Command list and short forms](ARCHITECTURE.md#staged-persistent-input) | `slash_commands.zig` in `test-logic`: every argument shape admits exactly its arguments; the list and Tab's completion over one-line, spaced, multiline, `//` and empty drafts. `TerminalFrame.zig` `'the command list takes rows the draft could grow into'` and the Session line test over every height, status, notice and list size: the draft's row never moves. `TerminalFrame.zig` `'a queued Message's row yields to the command list'`. `SessionScreen.zig` `'a command list of one row shows a command'`. `SessionInput.zig` `'Tab completes a command word'` and `TerminalEditor.zig` `'Tab over a partial character or a rejected draft'`. `SessionFrontend.zig` `'frontend /effort alone lists the efforts'`, `'the /status page marks one changeable row, which Up and Down move and Enter starts changing'`, `'a change run from the /status page replies under the page, which shows the new value on its row; a long failure opens as before'`, `'Esc closes the command list first only when the latest frame drew it'` and the local-command table. `status_page.zig` in `test-logic`: the rows, their lines, Up and Down over them and each row's draft. `cli.zig` `'/effort and /rename give what their /configure spelling gives'` and `'the CLI refuses a line the table does not admit'`. `human_cli_integration.py` compaction settings: `/effort`, `/effort high`, `/effort default` and `/rename` change what `/status` reports, `/rename "lane four"` stores no quotes, `/effort ultra` and an over-long `/rename` say exactly what their `/configure` spelling says, `/effort "high` shows `/effort`'s usage, and typing `/c`, `op`, Tab, then Esc shows, narrows, completes and closes the list above an input row that stays put. `overview_view.zig` in `test-logic`: `'typing / lists the overview's commands'`, `'a short screen lists the commands it has rows for'`, `'Esc closes a shown command list and keeps the draft'` and `'Enter runs a command by the overview's table'` | Linux PTY and libghostty-vt, not a physical terminal; the overview's list is not driven through a PTY |
| Departure and consent values | `session_departure`, `session_consent` and `ActionConsent` in `test-logic`. `Action consent` tests cover the last-drawn request ID, default Allow once, arrows, plain Deny, ignored typing and marked paste across request replacement. | Treating a successor as already drawn must fail the exact-request regression. No reading gate, per-key spending, reason row or flush receipt. These are value tests, not native consent evidence. |
| [Exact Action consent](ARCHITECTURE.md#authorizing-exact-actions) | `terminal-restoration-integration -- app-consent` drives App, Root and ActionConsent under the controlling-PTY launcher with Enter after a draw, with and without request replacement before dispatch, and modifier-zero Enter. `RUI_TEST_ACTION_READY_FD` fires when the card first draws a request. | The oracle checks the exact Action and choice; replacement and malformed Enter must yield no decision. Production screen wiring is a separate obligation. |
| App allocation regression target | `TerminalApp.zig` `'App memory'`: 49,152-cell Unicode surfaces at 24 × 2048 and 192 × 256, resize high-water, and repeated replacements of text, links and link params. | Peak page-rounded backing storage stays below 32 MiB; measurement forwards all allocator operations. These are test sizes, not a geometry ceiling. Not process RSS or a runtime allocation ceiling. |
| Frames, paging, history | `human_cli_integration.py renderer`, `SessionScreen` tests, `stagePage` tests | Hosted Apple Silicon required. Physical terminals unverified, SIGKILL cleanup not promised |
| App terminal restoration | `terminal-restoration-integration -- app-init` checks initialization OOM; `-- app-signals` checks INT, TERM and HUP through App and Root, plus repeated closed-master hangups. A long-lived fixture session leader gives Rui its controlling PTY as a foreground child. Retained-master cases inspect saved terminal attributes and reset sequences after exit. | Linux and macOS. Reader EOF and HUP share the successful quit outcome; callback EOF and other read errors remain failures. A closed master permits no restoration claim. Production hangup must also leave the Host and Sessions running. App attempts restoration on every exit path; vaxis logs failed termios restoration. A successful exit is not a restoration receipt, and `TerminalRestoreFailed` is not a persistent-UI exit outcome. Darwin excludes only termios `PENDIN`/`FLUSHO` and flag `FWASWRITTEN` |
| Detach notice | `'detached notice'`, `terminal-restoration-integration -- notice` | None |
| Composer readiness waits | `human_cli_integration.py terminal-waits` | Withheld composer is not readiness. 15 s readiness, 10 s exit, no renewal. Named selections are partial evidence |
| Fixture disposal | `host_process.dispose_all` in `host_process_test.py` | Body failure stays primary; failed cleanup after success fails |
| [Session listing](ARCHITECTURE.md#session-listing) | `session_list_integration.py`, `session_list_facts_integration.py`, `client.zig` and `protocol_reply.zig` `'Session list'`, `store/tests.zig` `'a list row carries its Session's Label, times, first Message, work and peers'` and `'Session list capture and cursor storage stay page bounded'`, `store/sqlite_tests.zig` `'a list row reads the same steps however long its Session's history'`. `session_list_facts_integration.py` fails a later page and requires a nonzero exit with nothing on stdout. `protocol.SessionRow.budget_bytes` fails the build when a worst-case row exceeds 32 KiB | Interrupted delivery and Mac footprint unqualified |
| Session listing `since` | `change_ring` in `test-logic`: coverage after eviction, an entry point touching too many Sessions, the distinct changed set in ID order, one Workspace's entries, token grammar. `store/tests.zig` `'a since listing answers only the Sessions changed since its token, or everything'`; `store/sqlite_tests.zig` `'a Workspace's changed page reads only its own Sessions, however many others changed'`: with 4,095 distinct Sessions of another Workspace changed after the token, a scoped page takes the same VM steps as with none. `'a failed Workspace-key read fails and fences the entry point that touched its Session'`: an interrupted key read during a relabel and during a Message fails that command, commits nothing and fences. `store/tests.zig` `'a Session creation that rolls back never reaches a since listing'`. Every Store test runs under the test-build touch oracle, which panics when an entry point changes a Session's rows without recording it; `'the touch oracle names a Session whose rows changed without a touch'`. `protocol_reply.zig` `'a since reply answers its request's token'` and `'a traversal keeps its first page's token'`; `server.zig` `'an unchanged listing echoes its token'`. `session_list_integration.py`: an unchanged Store answers `not_modified` with the same token, a relabel answers exactly that row as `changed`, another opening's token answers `full`, and a malformed token is refused. `session_list_facts_integration.py`: a changed listing whose continuation is answered by a full first page prints that full listing alone, each Session once; a later page that fails, before or after that restart, prints nothing and exits nonzero | Spurious changes are allowed. `not_modified` taking no Store lock is by construction, not counted. Ring overflow under load is #557's measurement |
| [Session work](ARCHITECTURE.md#work-state-and-wait-conditions) | `session_work` in `test-logic`: each table row and tie, a past-due retry reading `pending`, the coarse status map, a quota failure's reset time, and `error.CorruptStore` for inputs no writer produces. `store/tests.zig` `'Current, activity pages and Message progress report one work in each state'` and `'... through an approval'`, `'a stop that selected no Turn decides work only through the input it excluded'`, `'a quota reset is read from a saved record and never fences'`, `store/sqlite_tests.zig` `'contradictory work inputs fence the Store'`. With the clock stepped back: `session_work` `'the newer fact dates work, even when the clock stepped back'`; `store/sqlite_tests.zig` `'Session work dates a tool group by its last acceptance, even when the clock stepped back'` (approval after a denial, a settled group, and `bypass` Bash waiting after a sibling ran) and `store/tests.zig` `'queued input is pending from the newer of its admission and the latest outcome, even when the clock stepped back'` | Different reads may observe different commits. An `allow_once` decision against a sibling's resolution, and the earliest launch for `bash`, are ordered by time: neither claims a position |
| Times pinned to state | `store/sqlite_tests.zig` `'each state-bearing row keeps exactly the time its state owns'`: a direct UPDATE that changes state without its time is rejected. `'every transition dates its fact from the Host clock'` | Wall-clock order is not asserted |
| [Store format](ARCHITECTURE.md#store-format-and-upgrades) closed value sets | `store/sqlite_tests.zig` `'closed value columns accept exactly their values'`: each enumerated Command kind, Conversation entry kind, Model Output Item kind, reasoning effort and Action Resolution column accepts its listed values and rejects others on a CHECK | A Conversation entry kind outside 1 to 3 is rejected by both its column CHECK and the kind-specific CHECK, so the probe cannot tell which one rejected it |
| Session position claims | `store/sqlite_tests.zig` `'claiming Session positions stops at the largest position, and fails when its write does not land'`: inside a write transaction, a claim ending at the largest position succeeds, a claim past it fails without moving the counter, and a claim whose guarded write changes no row fails with `CorruptStore` | The guard on the read value cannot be observed alone: within one write transaction no other writer moves the counter between the read and the write |
| Store tests per engine | `tests/ci/store_conformance.py` split `store/tests.zig`: after it moves raw SQL onto the fixtures, tests that name no SQLite mechanism stay there, and those that open a Store run once per `store_testing.Engine` through `forEachEngine` (SQLite only until the MySQL engine lands). `test_store_conformance.py` fails when `store/tests.zig` code names the SQLite module or C API, the connection, the statement cache, engine passes, the content read counters or a Store opened by its path, or imports sqlite.zig. Fixture SQL (`store_testing.exec`, `queryU64`, `withoutForeignKeys`) fails the build when it fails `rsql.portabilityError`, or when outside its string literals it holds a word of `fixture_sqlite_words`, a word starting `sqlite_` or `pragma_`, or `AS TEXT` (`'a fixture's SQL is portable Rui SQL and names no SQLite mechanism'`, over `fixture_text_cases`); the codemod reads those word lists from testing.zig, and `test_store_conformance.py` fails when its verdict on a case differs. `RUI_TEST_REQUIRE_ENGINES` has one parser, `wire/required_engines.zig`, which pg_tests.zig also calls: tokens must equal `sqlite`, `mysql` or `postgres` (`'RUI_TEST_REQUIRE_ENGINES names engines by exact token'`), and a listed `mysql`, which no `Engine` builds, fails every conformance test (`'a required engine these tests do not build fails them'`). `'each Store entry point takes its round budget on its common path'` pins, on one driven path each, the rounds (`Access.run` and `commit`) of each function that enters the Store, and its content rounds (`readRaw` of a non-empty window) per engine. `'every function that enters the Store has a round budget'` reads every Store file but its tests and wire clients (import_architecture.py checks the list), and fails when a function calls `enter(self, ...)` with no budget, when an `enter(` call's first argument is not `self`, or when a `*ForTesting` function enters but is not in `entering_fixtures`. Each population-size work test of `sqlite_tests.zig` but five has a twin in `tests.zig`, named with `, in rounds`, that holds its rounds at the same two sizes | The checks do not run any engine but SQLite. The fixtures' text is not rendered for another dialect yet. A round budget holds only for the driven path, not for every input. The codemod's own scan of fixture text applies the word lists but not rsql's reserved-name and `IS` rules, which the compile applies. Five work tests have no rounds twin: each times a statement, or one `ReadAccess` run, that it drives itself outside any entry point |
| Store SQL on MySQL 8.4 | `store/mysql_dialect_check.zig`, in the unit binary. With `RUI_TEST_MYSQL_SOCKET` and `RUI_TEST_MYSQL_ROOT_PASSWORD` set, it logs in as root over that Unix socket, creates the database `rui_dialect_check`, sets `schema.mysql_session`, and runs each `schema.objects(.mysql)` statement, then a touch-oracle table in `rui_dialect_check_oracle` and the oracle's MySQL triggers (`sqlite.touchOracleTriggers(.mysql, ...)`), each on its own. `'the schema's MySQL DDL and the touch oracle's MySQL triggers run on MySQL 8.4'` fails listing every refused statement with MySQL's error. On its first use in the process, each text `cachedTyped` prepares (as `S.mysql`), the opening's sender sweep, and each statement of the fixture text `store_testing.exec` and `queryU64` run (`withoutForeignKeys` included) is PREPAREd, then DEALLOCATEd, on that database. A refusal logs the text and MySQL's error at err level, which fails the test that reached it without stopping it, so one run lists every refused text it reaches. At compile time, `rsql.portabilityError` refuses as a name every word of `rsql.mysql_reserved`, MySQL 8.4's reserved words as its manual lists them, unless the grammar reads the word as a keyword where it stands (`'every word MySQL 8.4 reserves is a name Rui SQL refuses, unless the grammar reads it as a keyword'`). `'PREPARE on the check's database refuses what MySQL 8.4 refuses'` requires errors 1054, 1093, 1055 and 1235 from four probes. On Linux CI, shards that run `test`, `check` or the `check-full` execution part start `mysql_server.py`'s image with the image's own settings (durability included) and add `mysql` to `RUI_TEST_REQUIRE_ENGINES`, so a missing variable or a failed login fails the run. `check` and `check-full` launch the unit binary through `host_process.py exec`, whose `INHERITED` includes `live_engines.VARIABLES`; `test_live_engines.py` checks that the launcher keeps each of them and that every `RUI_TEST_MYSQL_*`, `RUI_TEST_PG_*` and `RUI_TEST_REQUIRE_ENGINES` name the Zig source or `check.yml` spells is listed there. The check rewrites the file `RUI_TEST_MYSQL_RECORD` names with the DDL statements it ran, the PREPAREs it issued, the refusals, and the probes refused as expected; after the targets run, `live_engine_step.py verify mysql` fails the shard when that record is missing or counts no PREPARE. A change to `src/store.zig`, to `src/store/` outside the Postgres client, or to `mysql_server.py` selects `test` or `check` in review and local development feedback, and `select_tests.py` fails a selection in which a rule of `LIVE_RULES` keeps none of the targets that start its server; `test_selection.py` pins `LIVE_MYSQL_TARGETS` and `LIVE_POSTGRES_TARGETS` to `check.yml`'s conditions. `select()`'s documentation and CI-policy shortcuts only add a reason, so every rule still matches every path; `test_selection.py` checks that a lone change to each path a rule names (a literal pattern, or each tracked file a glob matches) selects something in both phases, that rule's targets in review, and for a live rule a target that starts its server. Elsewhere, without the variables, both tests skip and nothing is prepared | Only texts the unit run reaches are prepared; a statement no test reaches renders at comptime but is never prepared. A later test that reaches an already refused text does not fail again. PREPARE binds no value and runs nothing, so literal typing and binding, guards and row counts, multi-statement batches, transactions, CHECK and foreign-key behaviour, collation and query plans wait for PR 8's conformance run. `failReadsOf` and the fixtures of `store/sqlite_tests.zig`, which go through `store_testing.sqlite_only` (no portability rule, no MySQL check), are not checked; `store_conformance.py` keeps `sqlite_only` out of `store/tests.zig`. Nothing here fires the MySQL oracle triggers. They note a sender's Session only when a column both Sessions read changes, narrower than SQLite's `UPDATE OF` |
| [Store migrations](ARCHITECTURE.md#store-format-and-upgrades) | `schema.zig` 'schema 61 migration preserves saved call rows and accepts 200 UTF-8 bytes' migrates populated format 60, preserves rows and dependents, checks both columns' byte boundaries, foreign keys and reopening. `schema.zig`'s comptime gate fails the build when `schema.migrations` lacks the step to `schema_version`, holds a step past it, or holds steps out of order. `tests/ci/test_store_schema_version.py` compares each step whose `from` is below the released schema_version with its source text at the release tag, whitespace outside strings aside, and fails on a dropped, added or changed one; `test_shipped_steps_rule` proves it on a fixture release where a shipped step and its neighbours are edited together. It also fails on any step whose statements are not all string literals (`test_steps_are_literals_only`), so the source compared is the text that runs; a CHECK copied wrong into a step fails the migration tests below, since the schema's own CHECK passed `rsql.expressionError`. `store/sqlite_tests.zig` `'a Store at the migration baseline with its rows takes every migration at open and reads as a fresh Store'` builds a Store from `migration_baseline.sqlite.sql` and `migration_baseline_rows.sql`, opens it through `Store.open`, and compares every table's rows with a fresh Store given the same rows; with no step it proves the snapshot equals the current schema. `'a migration that rebuilds a referenced table from the schema's text keeps its rows and references, and the Store opens'` and `'a migration that leaves other text than bootstrap's, or a broken reference, or runs on another format, commits nothing'` drive `schema.migrate` with steps of their own. `'a migration whose step fails leaves its backup and the original Store readable, and replaces an earlier backup'` checks that the copy and the Store both hold format 7 and their rows and pass `integrity_check`, that an earlier copy is replaced and files whose names only begin like it are kept, and that a backup that cannot be written refuses the Store before any step runs; `'a Store at the maximum path backs itself up before a migration'` writes the copy for a Store whose path is the longest the Store allows. `store/mysql_dialect_check.zig` `'a MySQL Store at the migration baseline with its rows takes every migration to the current schema's shape and rows'` runs `migration_baseline.mysql.sql`, the rows and the combined `schema.mysqlMigrationFrom(migration_baseline)` text printed by `store schema --from` in one database and `schema.ddl(.mysql)` and the rows in another, seeds saved baseline format, older wire metadata and a Store selector, then compares their information_schema tables, columns, indexes, CHECK clauses and foreign keys and every table's rows and admits the migrated database through the production `mysql_open.open` path; it runs inside the live dialect check, and each pass adds to the record's `migrations` count, which `live_engines.py` requires to be nonzero on every shard that starts MySQL | The rows come from a Store at 51 that the Store fixtures wrote; `sent_rejection` holds none. MySQL constraint names are not compared, since MySQL generates them. Nothing checks a step against a Store a released build wrote. |
| [Ancestor Activity forwarding](ARCHITECTURE.md#public-session-activity) (D135, D180) | `store/sqlite_tests.zig` K4 forwarding regressions: three-level approval and ending feeds, ancestor allow/deny, unrelated and undelivered targets refused, replay, and injected commit failure between durable hops | Focused Store recovery; no OS-crash or power-loss claim |
| [Activity `at`](ARCHITECTURE.md#public-session-activity) | `store/tests.zig` `'every activity row is dated by the fact that owns it'` and `'a Tool Result is dated by its group's last acceptance, even when the clock stepped back'`, `protocol_reply.zig` `'an activity row carries its time'`, `activity_integration.py` | None |
| [Label](ARCHITECTURE.md#naming-and-configuring-a-session) | `store/tests.zig` `'a Label is configured, replayed, cleared and validated like any setting'`, `cli.zig` `'a Label argument sets, clears or refuses before capture'`. `peer_integration.py`: A labels itself with `session configure --session "$RUI_ADDRESS"` and starts B with `--label`; listing shows both, and B's model requests never carry its Label. `human_cli_integration.py`: `/status` shows the Name row `not set`, then the composer-set Label | Same idempotency and conflict rules as other settings |
| First Message, starter and `from_person_at` | `store/tests.zig` `'a list row carries its Session's Label, times, first Message, work and peers'`. `peer_integration.py`: B's first Message names A as its sender, A's names none, and only A has a Message from a person or script | Configure-only Sessions report `null` |
| Creating Message `require_model` | `store/tests.zig` `'a creating Message with require_model creates nothing without a model'`, `protocol.zig` `'only a creating Message carries require_model, and it binds the digest'` | Low-level `session start` without the condition stays available |
| [Conversation cursor bounds](ARCHITECTURE.md#public-conversation-pages) | `protocol.zig` `'conversation cursor parser rejects'`, `conversation_page_integration.py` | None |
| [Store ownership](ARCHITECTURE.md#exclusive-store-ownership) through listener failure | `admission_integration.sh` (`InjectedListenerFailure`) | A fixed sleep is not ownership evidence |
| [Ingress through admission](ARCHITECTURE.md#ingress-ownership-through-admission) | `admission_integration.sh` | None |
| Slow report readers beside controls | `server_delivery_integration.py` | Mid-capture and partial-delivery failure: none located |

### Server ownership and connection capacity

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Client transport](ARCHITECTURE.md#client-transport-and-observations) cancellation and backlog | `'transport cancellation'`, `test-full` | Backlog case Linux-only. Four mutation negatives must go red. Not File/sink preemption, Mac cancellation or aggregate footprint |
| [Host information](ARCHITECTURE.md#exclusive-store-ownership) probe and CLI status | `'Host information'`, `host-status-integration`; there a replacement Host's `started_at` is at or after the replaced Host's, in whole seconds, with no wait between them. `host_launch_integration.py`: one attached Host reports the same `started_at` in every reply and idles at `custody_occupied` 0. `control_integration.py` `prove_sealed_interruption_and_cleanup`: while an interrupted model Operation's settlement is held and its custody record with it, `host status` and Current both report `custody_occupied` 1 | Mode-000 denial needs non-root client. Held-connection descriptor negative: none located. A restart within the same second may report the same `started_at`, so no test shows a restart changing it. Start times order nothing across clock changes |
| Detached launch, C adapter argv witness and startup refusal | `host-launch-integration`, `host_launch_exit_test.py`, `'startup diagnostics'` | Linux does not qualify Darwin helper or PTY detach. PID SIGKILL is crash cleanup |
| [Exact-instance stop](ARCHITECTURE.md#infrastructure-shutdown) and effect-aware drain | `host-stop-integration`, `host_stop_integration_test.py`, `'shutdown fences'` | Not power loss. Forced kill is crash cleanup. Fixed-timeout and wait-removal mutations must fail. Python oracle is not native proof |
| [Ingress ownership](ARCHITECTURE.md#ingress-ownership-through-admission), deadlines and retained cleanup | `'ingress'`, `host-status-integration` | Not disk latency or forced cleanup |
| [100 incomplete exchanges](ARCHITECTURE.md#connection-capacity-and-control-headroom) beside controls | `'hundred incomplete'` | Burst is not an admission quota |
| Session-list resource census | `session_list_integration.py`, `session_list_release_proof.py` | Held-cleanup and leak negatives are opt-in, Linux |
| Reply delivery inactivity and drain | `'reply delivery'`, `server-delivery-integration`, `PeerCensus` | Run apart from load. Not Mac drain or SIGPIPE |
| Controls queue behind settlement | `'active model settlement'`, `control_integration.py` | Store hold proves exclusion, not latency. Unordered contention reports unavailable |
| Host reply and request bounds | `'exact worst-case'` | Each bound derives from the JSON shape its writer writes; full 128-byte keys, escaped Store, Session and workspace strings and escaped 96-byte codes. No fixed 8 KiB allowance |
| [Conversation pages](ARCHITECTURE.md#public-conversation-pages) and streaming | `'public'`, `'sequential work'`, `'public assistant message provenance'`, `conversation_page_integration.py` | Exact message item, public part text, Session, Turn and Attempt bindings. Whole-value reads check stored bytes against their digest at the end; ranged reads past the start do not. No aggregate memory |
| [Session activity](ARCHITECTURE.md#public-session-activity) and tool labels | `activity-integration`, `'tool label'` | `RUI_ACTIVITY_MEASURE=1` samples. No latency bound |
| [Content step faults fence](ARCHITECTURE.md#canonical-content-reads-and-retention) | `'public content SQLite step'` | None |

## Execution tracking and waiting

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Fixed custody population](ARCHITECTURE.md#capacity-ownership) | `'execution slots agree with custody across the complete population'`, `'no-work admission restores only its temporary custody reservation'` | Full scan, no free list; never a durable slot registry |
| Attempt admission rollback | `dispatch-integration` | Sample custody after `releaseUnused` in the same owner turn; suppressing it must fail |
| [Selection progress](ARCHITECTURE.md#capacity-and-selection-progress) and waits | `test-logic`, `'kind-specific admission'`, `'production turn preserves skipped continuation'`, `'each transition that lets a Turn continue without input makes it selectable'`, `'a Turn whose continuation was never recorded fences the Store'`, `'tool continuation selection never visits a Turn waiting for its tool results'`, `'tool continuation selection leaves a ready Turn with queued input to message selection'`, `'runnable discovery measures eligible ineligible and history populations independently'` | Not native transport or cross-platform qualification |
| Resumable model preparation | `test-logic -Dtest-filter='request encoding'`, `'request preparation'`, `dispatch-integration` | Service gaps are observational, not turn-ordering proof |
| Discovery-hint replacement | none | Only when a replacement is introduced |

## CLI refusal and exit contract

The CLI derives exit status from admission certainty and the catalog remedy, not the rejection code alone:

| Exit | Caller action |
| --- | --- |
| 0 | Done. |
| 1 | Failed for a cause not classified above; stderr names it. Treat it as unknown: do not assume the request was or was not sent unless stderr says so. |
| 2 | Invalid fresh invocation; nothing was sent. Fix the invocation. |
| 3 | Rui answered with a saved refusal. Correct the request; a resend needs a new key. |
| 4 | Admission unconfirmed. Run `rui request recover HANDLE` (or the printed explicit-record recovery); never resubmit with a new key. |
| 5 | Retry the same request unchanged later (Host busy or result not ready). |
| 6 | Repair the environment, then retry unchanged (known stopped/unreachable Host, sign-in required or locked Store). |

An error enters 2-6 only once its cause is mapped; every other failure stays exit 1 until it is.

Uncertainty takes precedence over remedy: a busy-looking mutation response without a confirmed admission remains exit 4, not 5.
Multiple outcomes, including `session stop --all`, aggregate in cautious order **4 > 1 > 6 > 5 > 3 > 2 > 0**, never numeric maximum or first failure.
A nonzero exit may follow acceptance; it does not authorize a new identity.

Focused proof: `caller_error.zig` saved-rejection goldens and exhaustive protocol-tag coverage; `caller_exit.zig` certainty/remedy and all-pairs aggregation tests; `cli.zig` saved-reply and uncertainty recovery goldens.
`human_cli_integration.py`, `peer_integration.py` and `admission_integration.sh` assert caller codes and statuses at the process boundary; integration suites require a non-root user.
A fresh unsupported permission mode exits 2 before capture; a wire-created capture or saved replay reaches the Host rejection path and exits 3.
Do not substitute current validators or live accepted sets for saved replay facts.
Neither HTTP statuses nor stdout JSON change.

## Resources and accepted Host qualification targets

Targets (Host-only; CLI/helpers separate):

- ≤25,000,000 bytes macOS lifetime-peak physical footprint at Active Capacity 1/8/16/100 and cold/retained idle: `measure-model-output`, `measure-call-classification`
- ≤256 MiB physical footprint, eventual 1,000-operation model/Bash/Edit/mixed load: none located
- Idle CPU <1% of one core: `measure-model-retry`, `measure-model-dispatch`
- Retry discovery ≤2 s after due at free capacity/light load: `measure-model-retry`
- ≤2 cores observed model-fixture CPU and ≤120 CPU s complete work, two same-Host rounds: `measure-model-output`
- p95 durable control acknowledgement ≤1 s with 100 live streams and 100 occupied custody records: `measure-model-control`
- 0/100/1,000/10,000 Dormant Sessions at fixed capacity: `measure-admission`
- Session environment register: at most 4,096 Sessions and 128 values of at most 1 MiB in total, least recently used replaced, each value freed when no entry names it: `'the table holds at most its Sessions and value bytes'`, `'the table holds at most its values'`, `'a value is freed exactly when no entry names it'`
- Behavior failure vs invalid measurement vs target miss: `measurement-check`

### Descriptor startup capacity

Required: minimum ten-client intake; budget covers wake pair, 100 ordinary exchanges, two controls, one discovery, not as runtime quotas; managed auth adds 8 (Linux) or 10 (macOS).

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Startup limit fit or refusal | `'descriptor'`, `descriptor-capacity-integration`, `codex-h2-integration` | Native Linux and macOS; cross-compilation is not equivalent. Auth allowances are not a physical peak |
| Accept pressure (EMFILE at 512 FDs) | `descriptor-capacity-integration` | Restored fatal accept branch must fail. ENFILE/ENOBUFS/ENOMEM injected, not system-wide exhaustion |

### Transport

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Shared H2, peer-held streams and an isolated write failure | `transport-h2-integration` | Opt-in; needs Python `h2==4.3.0`, OpenSSL CLI. Not footprint |
| Repeat-work footprint | `transport_h2_integration.py zig-out/bin/rui --observed-shape-churn` | macOS ReleaseSmall, opt-in; fails above 25,000,000 bytes. Not the Go repeat-work profile |
| Original result and release deadlines: one deadline per population, forwarded through reads and global release | `transport_h2_integration_test.py`, `host_process_test.py` | A clean reply at or after the deadline fails. Held cleanup must refuse through the deadline |
| Transfer finalization | `'HTTP error capture retires before execution custody'`, `'a completed Transfer finds its own slot and nothing else'` | None |
| Address racing (RFC 8305): families alternate, the next attempt starts on a failure or after 250 ms, at most two sockets | `'the next address starts on a failure or after the delay, the oldest of two giving way'`, `'families alternate, the first answer's family leading, and both fit'`, `'https by name: an address that never answers does not keep the next from connecting'`, `'https by name: two addresses that never answer do not keep the third from its turn'` (`test-h2`) | A never-answering address is a loopback listener with a full accept queue. Name resolution itself is not raced (RFC 8305 section 3) |
| Proxy tunnel (CONNECT over an `http://` proxy): credentials, NO_PROXY and loopback bypass, 407/403/other refusals, interim 1xx answers, nothing after the answer, unusable proxy URLs | `proxy.zig` tests, `'the HTTP/2 client's proxy logic stays within the core boundary'` (`test-logic`), `'any 2xx opens the tunnel; 407 and 403 are their own causes'`, `'exchange: https through a proxy's CONNECT tunnel, with its credentials'`, `'exchange: a proxy's 407, 403 or other refusal ends the setup before any request byte'`, `'exchange: bytes after the proxy's answer fail the tunnel'`, `'exchange: loopback and NO_PROXY hosts connect directly'`, `'exchange: a proxy URL Rui cannot use fails Client init'` (`test-h2`) | The proxy is an in-process test proxy. No `https://` proxy, no proxy auto-configuration or system proxy settings |

### Scratch and cleanup

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [8 GiB scratch accounting](ARCHITECTURE.md#shared-scratch-ownership) | `'concurrent scratch reservations share one ceiling'`, `'ingress charges decoded growth and transfers file charge through cleanup'`, `dispatch-integration` | Real disk-full: none located |
| Startup leftovers | `'startup cleanup removes owned files and preserves lookalikes'`, `'startup reclaims only a stale Unix socket'` | None |

### Host startup availability

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Limit and schema refusal under 5 s | `host-launch-integration` | 256/256 and minimum-1 refuse; exact minimum serves ten clients. Linux and Apple Silicon macOS |
| Moved SQLite Store refuses foreground, detached and interactive startup with both escaped canonical folders, `store_identity_mismatch` and exit 6; old-path symlink still refuses, identity stays unchanged, restoration serves | `host_launch_integration.py store-identity` in `host-launch-integration` | Private stopped fixture Store only |
| [Installed upgrade](ARCHITECTURE.md#store-format-and-upgrades) | `previous-release-upgrade.yml`, `previous_release_upgrade.py` | Exercise supported startup migration and backup as well as unsupported formats; no reset policy |
| Source and release installer publication | `installer-integration` | All 37 installer boundary cases use an explicitly supplied compiled production Rui for native publication and PATH facts; planning and template policy tests require no compiler |
| [Standalone stable Upgrade](ARCHITECTURE.md#store-format-and-upgrades) | `upgrade-integration`, Installation, release, Host lifecycle, PATH and panel value tests | Offline metadata and a same-source synthetic release identity; real native Hosts and the PTY screens prove exact-instance activation and lease retirement, failure reporting and retained drafts without replay. Historical external installers are outside the guarantee |

### Canonical reads, retained output and SQLite

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Bounded content reads](ARCHITECTURE.md#canonical-content-reads-and-retention) | `'content reader owns the bounded result-delivery window'`, `'content readers hold no decode window'`, `'public content SQLite step failure fences after successful preparation'`, `'retained readers allow checkpoints between committed windows'`, `'historical preparation yields covered group populations under small allowances'`, `'yielded Bash preparation leaves checkpoints free while retaining its descriptor'`, `server_delivery_integration.py` held Reply reads beside committed configurations | Checkpoint/reuse is not a hard WAL file-size quota |
| [MCP resolution certainty](ARCHITECTURE.md#operations-and-frozen-requests) | `test-logic` `'result_text classification covers every ending and certainty boundary'`; `test` `'Running oversized JSON and SSE answers'`, `'Running resolves socket replies'`, `'Host MCP Session stop after send'`, `'MCP attempts serialize Sessions'` | One owner table spans every terminal ending, both send sides of stop/deadline, and complete/cut parity across result types, content shapes, explicit/default flags and RPC errors, crossed with 4xx/5xx, JSON/non-JSON media and matching/nonmatching envelopes. Missing defaults and unfinished values remain unknown until established. Native JSON/SSE overflow retains status, media and prefix, including malformed/unsupported results and definite 4xx refusals; Host/Store stop tests check durable indeterminate after send, cancelled before send, no retry and unchanged Bash cancellation. Completed MCP answers survive a settlement/stop race. Over-limit replies retain only the marked prefix, not the unread suffix |
| [Retention FIFO](ARCHITECTURE.md#retained-output-and-its-queue) | `'retention entry capacity derives from fixed orchestration memory'`, `'already absent retained files release their entries and scratch charge'` | None |
| Retention failure keeps result | `bash-owner-integration` | Host is not fenced |
| [MCP excerpts and optional full output](ARCHITECTURE.md#tool-excerpts-and-full-output) | `mcp/Running.zig` 'Running retains only omitted rendered MCP answers and preserves the excerpt', 'Running reports optional MCP retention refusal without changing success'; `bash.zig` 'Bash capture reclaims MCP output from the same scratch budget'; `output_retention.zig` 'retention file write failure keeps partial bytes charged through removal retry', 'retention file reservations protect writers and release failed creation charges' | Native loopback replies cover exact-fit and UTF-8 cuts, mixed error blocks, structured content, RPC and HTTP errors, budget/capacity/reservation/creation refusal and scratch loss; no OS-crash or power-loss qualification |
| [10,000-byte tool tail](ARCHITECTURE.md#tool-excerpts-and-full-output) | `'UTF-8 excerpt keeps the newest source and reports replacement expansion'` | No line/total-capture quota or rerun for truncation |
| [Result sections](ARCHITECTURE.md#tool-excerpts-and-full-output): no empty stream header, full path only for a truncated stream, no confirmed-retirement note | `'results show only nonempty stream sections and mark truncation'`, `'cleanup deadline cuts off'`, `bash_integration.py`, `bash_owner_integration.py`, `bash_lifecycle_integration.py` natural exit, `human_cli_integration.py` permission case | Natural exit asserts the exact saved and model result on both systems, including macOS group-signal `EPERM`; injected signal failure remains in saved/model results and explicit details or full raw export, not normal tool headings |
| [Settings and faults](ARCHITECTURE.md#sqlite-and-representation) | `'production Store applies finite durable SQLite settings'`, `'an outside SQLite writer cannot take the open Store's lock'`, `'real SQLite full during import publishes no canonical prefix'`, `'measurement Store can force a smaller SQLite cache without changing production defaults'` | None |
| [Store durability](ARCHITECTURE.md#store-durability) | `'Store WAL lifecycle at the maximum path: sidecars, lock ownership, crash copy, checkpoint and restore'`, `'fresh Store uses current schema and rejects the prior version'`, process-crash recovery in `bash-recovery-integration` and `admission-debug-integration` | The crash copy is a file snapshot of an open Store, not an OS crash; no power-loss test |

## Diagnostics

### Native owner observations

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Bounded channel, ordering, loss, startup credit, final state | `host_process_test.py`, `'private owner observations'` | Discover via `src/tests.zig`. Startup credit covers one inspection cohort, not a whole plan |
| Cleanup custody retires before publication | `'cleanup publication follows'` | Reversed retirement must fail. Not lease release |
| Receipt versus publication retirement | `prove_intentional_crash_retirement`, `prove_observation_disposal` | Crash paths stay unsealed; ordinary teardown seals |
| No-launch crash cut | `bash_integration.py` `prepared-before-handoff`, `prove_gate_broadcast` | Released gate must fail. Marker absence and publication retirement are not evidence |
| Required stop receipts | `prove_required_receipts`, `transport_h2_integration.py` held cases, `terminal_restoration_integration.py stop-receipt` | Single cases are partial |
| Descriptor witness and refusal | `descriptor-capacity-integration`, `prove_capacity_refusal_oracle` | `BrokenPipeError` is not refusal. FD snapshots cannot replace endpoints |
| Readiness drains PTY and notification pipe | `host-launch-integration` (`check_action_ready`) | Keep withheld-credit tests distinct |
| Failure retention: 16 roots, 128 files, 1 MiB/file, 16 MiB, 3 days | `tests/ci/test_failure_artifacts.py` | Cumulative. Failure keeps original error and teardown |

### Shared optional stderr

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Shared optional stderr](ARCHITECTURE.md#shared-optional-stderr) | `terminal-restoration-integration` (`check_forwarding`), `'required Bash observations publish'` | No universal latency or restoration claim |
| Canonical work unaffected by diagnostic failure | `host_diagnostic_cases` | Wake fallback: none located |

### Diagnostic records and export

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Records](ARCHITECTURE.md#diagnostic-records-and-export): 128 MiB, 16 files, 4 KiB | `'startup diagnostics rotate'` | Reduced cap only |
| [Failed-response records](ARCHITECTURE.md#diagnostic-records-and-export): exact bytes, association, status, 16 MiB, 64 MiB, 256 records, private modes | `'failed response'` tests; `dispatch-integration` invalid-output, transient HTTP, stall and concurrent-retention cases | Truncation, eviction and omitted bodies use reduced caps or an unreadable capture in unit tests. The integration fault is an undeletable record entry, not disk exhaustion |
| Failed-response export through authenticated `session inspect`: exact body and stored metadata, Session/Operation/Attempt binding, read-only snapshots, binary windows, partial and omitted bodies, missing/ambiguous/corrupt records, symlink rejection, clean stdout and fd256 caller. Mandatory scratch unlink failure fences dispatch, preserves the original failure and recovers on startup | `dispatch_integration.py failed-response-export` in `dispatch-integration` | Real fixture-produced `IncompleteProviderOutput` and binary HTTP 400 survive Host restart. Partial/omitted export negatives perturb that real record; retention creation has separate owner tests. Canonical values and retained bytes/write timestamps are compared, not filesystem atime or WAL housekeeping. No live provider or automatic upload |
| General bounded rotated-log export | none located | Unimplemented |
## Release demonstrations

`upgrade-integration` builds `rui-upgrade-release-fixture` from the current production sources with a synthetic release version and the actual source revision.
Only the fixture's build identity differs; installation eligibility, publication, Host lifecycle and terminal code are the production owners.
Ordinary untagged builds still report `unreleased`.
`zig build upgrade-fixture` exposes that same native actor for focused terminal evidence without a network download or a stale tagged binary.

`installer-integration` runs source and release installer cases with the compiled production executable supplied by the build graph.
Their staged test commands delegate publication and PATH facts to that executable, never to a second writer or an on-demand compiler.
The compiler-free policy suite retains release planning and template checks; its boundary regression runs those checks with no Zig on PATH and confirms every native case receives an explicit publisher.

Package under the Rui identity and verify executable and package names, state and credential identifiers, build and distribution references, and fixtures.
Fixture recreation under the [Store format policy](ARCHITECTURE.md#store-format-and-upgrades) does not authorize changing user Stores; state packaging, state-path and credential-identifier obligations explicitly before release.

Release demonstrations cover explicit start, no-client progress, restart, direct Sessions, first configuration, permissions, ordered tools, uncertain Bash and Edit, and shared cancellation.
Independent native or Cloudflare walkthroughs add no embedding or cloud release requirement.
Keep evidence attached to the real owners and label remaining gaps before claiming release readiness.

## Memory explanation evidence

For allocation, buffer, thread or resource-lifetime changes, record build and workload, allocation origin and owner, population multiplier, lifetime and attribution gaps.
Distinguish live allocations, allocation volume, physical footprint and virtual reservation; overlapping counters are not additive.
The [small Host memory trial](research/memory-trial/README.md) is a collection example, not a quota or a substitute for simultaneous-workload qualification.

## Skills

`skills-integration` uses an isolated Workspace and HOME and a deterministic loopback model endpoint which records incoming bytes before replying.
It exercises Host-owned Configure and initial-Message creation, default and explicitly restricted tools, full raw invocation/path, idle no-op and metadata reload, keyed replay after file deletion and process restart, bound model invocation and child `start_agent` discovery.
The fixture uses native public readers and actual provider inputs, not direct Store edits or terminal excerpts.
Mismatched repository symlinks and HOME directory aliases retain their declared names through creation, invocation, reload and replay.

`zig build yaml-linux-compile` compiles all pinned libyaml sources as strict C99 against Linux glibc headers for x86-64 and ARM64 without linking or executing a Host.
It reuses `configureYaml`, whose POSIX feature exposure is scoped to the dependency's C sources; removing it must fail at libyaml's `strdup` declaration, not witness setup.
The ordinary Linux CI builds retain the same dependency compile boundary; this focused target does not add work to an ordinary build.

Focused `skills ` tests cover real YAML scalars/ignored nested metadata, repository-over-home precedence, worktree and non-git roots, symlinks, unreadability, explicit caps, malformed UTF-8 and metadata-only deltas.
Directory-alias regressions cover lowercase, mixed-case, underscore, long and Unicode spellings in both roots, malformed declared-name fallback and bytewise collision winners under reversed creation orders.
External symlink aliases retain canonical paths, deduplicate the same target and produce no catalog delta after an alias-only rename.
Description regressions cover unchanged short and exact-limit ASCII and multibyte scalars, visible Unicode-safe truncation above 1,024 code points, catalog round trips and full unchanged invocation content.
Catalog JSON requires actual string tokens for name, description and path, rejecting numeric/byte-array coercions while preserving escaped Unicode.
A full 4096-entry ordering regression covers the constant-stack heap sorts used by discovery, encoding, decoding and deltas.
The Linux `stack-frames` gate measures the real catalog decode and Configure/creating-Message import paths.
Configure and creating Messages keep their temporary facts at one address in the Store's existing scratch; reload-only scratch stays in its own same-transaction branch.
No skill stack exception or larger scratch allocation is permitted.
A result-arena plus independently reclaiming scratch high-water regression exercises many near-limit project and shadowed home bodies; unsupported native invalid-byte filenames skip only on filesystems that reject their creation.
The actual Ingress tests cover text-free skill custody transfer, fragmented input and invalid text-plus-skill cleanup alongside the existing ordinary text-capture tests.

The Store tests exercise six distinct content imports in child creation, `content_import` and `before_commit` rollback with reopen/retry, same-position/public catalog provenance, empty initial position zero and authenticated peer refusal causality/replay.
Reload fault tests preserve catalog, instruction, position and command-result atomicity through both failure points, then verify same-key replay and no-op behavior after reopen.
Populated format-56/wire-9 and format-58/wire-10 SQLite fixtures upgrade through the production Store and preserve ordinary content; corresponding MySQL migrations run when a live test server is configured.
Archive composition tests retain archive intent on skill refusal and idle reload, unarchive only a fresh admitted invocation, and preserve archive state on keyed replay.
Creation refusal tests cover both Configure and initial Message: a missing Workspace remains `invalid_workspace`, a valid Workspace with inaccessible skills roots remains `skills_unavailable`, and each keyed refusal replays unchanged after repair without allocating a Session or model work.
The adapter lifecycle test checks complete >10,000-byte CRLF/Unicode skill results in saved ordinary content and actual sealed provider input, metadata-only body edits, revision-one/authored-baseline preservation, idle nullable-Turn reports, frozen admitted Operations, serialized history prefixes, memo/cold reconstruction and real reopen after source deletion.
Negative controls revert each boundary fix and must fail its owner assertion or actual Host custody boundary, not fixture setup.
These are synthetic local evidence, not live provider, remote filesystem or power-loss qualification.

### Parent creation (D178)

Focused `configure parent` Store tests cover inherited Workspace/provider, no task,
child reporting and ending delivery, every widening field, missing/archived parents,
update refusal and idempotent replay. The Host test covers inherited in-memory Bash
environment and replay/refusal isolation. The create path retains the ordinary
four-round budget, including selected catalog facts; run these and the unchanged `start_agent`, Store entry-point
round-budget and Current report dependency-depth tests on SQLite and live MySQL.
Mutating the shared tool narrowing refusal must fail both creation and start_agent.
`openapi` focused tests cover generated examples, including the create-only relation.
