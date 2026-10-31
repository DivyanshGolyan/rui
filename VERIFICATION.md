# Verification

[ARCHITECTURE.md](ARCHITECTURE.md) owns behavior. This document owns required evidence: the gates below and the [contract index](#contract-index). Test production interfaces and real SQLite transactions against independent expectations. Crash tests kill a fixture process and reopen in a fresh one; injected returned errors are fault tests. Record revision, machine, dependencies, inputs and measurements. Prototypes, source inspection and compilation are not production qualification; [research evidence](research/README.md) records those limits. Git history keeps earlier test specifications and dated results.

## Canonical gates

Integration fixtures require Python 3.11 or newer on PATH, with the packages pinned in [tests/integration/requirements.txt](tests/integration/requirements.txt) (python-h2 serves every loopback fixture over h2c); the composed driver rejects older interpreters and records the one selected. On macOS, do not use `/usr/bin/python3`. Diagnose interpreter failures apart from product assertions.

Run fixtures as a non-root user. Root bypasses the file and socket permission denials that fixtures assert, so a root run fails them or proves nothing. Every fixture entry enters the boundary in [host_process.py](tests/integration/host_process.py) before it starts anything. A Python fixture calls `host_process.enter()` first in its main block. Anything else runs through `python3 tests/integration/host_process.py exec COMMAND...`, which enters and then executes the command: `admission_integration.sh` re-enters itself this way, `check.sh` runs its native test binary this way, and build.zig runs every Go `measure-*` step this way. `check.sh` also enters once before any case starts. Entering stops a root process with that instruction, whether a build step or a person launched it. It also replaces the process environment with the variables `INHERITED` names there (PATH, HOME, TMPDIR, locale and named fixture inputs, each with its reason) plus `TERM=xterm-256color`, so a caller's `RUI_*`, TLS trust or proxy settings cannot change what a fixture proves. A fixture sets its own variables after entering, and its children inherit only those. Importing host_process changes nothing, so tests/ci and fixture libraries can use it freely. `FixtureEntryTest` in [test_harness_contracts.py](tests/ci/test_harness_contracts.py) finds every fixture entry (each shell script, and each Python module with a main block), runs it with root simulated and requires that refusal. It also requires that every `measure-*` step goes through the exec entry. Where the shell is root, as in many containers, use an ordinary account that owns its checkout, Zig caches and Python environment.

| Change class | Required gate or evidence |
| --- | --- |
| Documentation | References, consistency and `git diff --check` |
| Runtime behavior | Subsystem mapping below on the landing tip for Linux main acceptance; Mac mapping and full Debug recovery on the exact main SHA before stable promotion. A skip is not evidence |
| Build or dependency | Linux `check-full` and mapped checks on the landing tip; macOS `check-full` and empty-cache acceptance daily |
| Resource owner | Comparable measurements and lifecycle evidence on applicable runners |

The executable minimum is [select_tests.py](tests/ci/select_tests.py), using targets from [build.zig](build.zig). Run `python3 tests/ci/select_tests.py --base origin/main --phase review` on the candidate. The selector unions affected subsystems and falls back to `check` for unmapped source or integration code. It does not infer dependencies. Long, churn, full Debug and H2 targets follow their mappings, not an unconditional per-PR gate.

| Subsystem | Landing-tip minimum | Exceptions and notes |
| --- | --- | --- |
| Portable turn, request encoding, answer rendering | `test-logic` | Value transitions do not change native adapters |
| CLI, client, preferences, provider selection | `check`, `admission-debug-integration` | Covers preference publication and unnamed human CLI consumers |
| Frontend consent, departure and submission recovery | `test-logic`, `test`, `admission-debug-integration`, `terminal-restoration-integration`, `canonical-failure-integration` | `Terminal*` owners omit `test`; the selector owns their exact mapping. Mixed strict or non-frontend code retains `check` |
| Store SQL owners | Linux `check`, Mac `test`, `dispatch-debug-integration` on both systems, changed owning integration targets | The Debug failure-correlation subset checks saved provider bytes through reopen |
| Proposal and activity fixtures, typed read clients | `proposal-integration` or `activity-integration` on both systems | Both run in `check` and `check-full`; select separately only without a composed gate |
| Preference privacy fixture and native actor | `preference-policy-integration` on both systems | Runs in `check` and `check-full` |
| Server, protocol, shared execution and scratch | `check` on both systems | None |
| Server admission or capture owner, admission fixture | Also `admission-debug-integration` on both systems | The routine Debug smoke does not cover the recovery matrix |
| Bash | `test`, Bash owner, lifecycle, recovery and caller targets; `test-logic` for `src/BashLifecycle.zig` | No general sandbox or power-loss claim |
| HTTP/2 client (`src/h2/`) | `test-h2`; `test-logic` for `src/h2/policy.zig` | Runs in `check` and the `check-full` execution part. Its peer tests run over loopback h2c and TLS in process. System trust against real servers is manual, on each platform (macOS SecTrust above all), and not a gate: `RUI_H2_LIVE_URL=https://api.openai.com/v1/models zig build test-h2` and `RUI_H2_LIVE_NEGATIVE=1 zig build test-h2` |
| Model and transport | `test`, `dispatch-integration`, `transport-h2-integration`; `test-logic` for `src/transport_policy.zig` | Live provider remains opt-in |
| Codex credentials | `test`, Codex, credential and Codex H2 targets; `test-logic` for `src/codex_credential_policy.zig` and `src/codex_token_wire.zig` | No real account login required |
| Product defaults (`src/product_defaults.zig`, `tests/integration/product_defaults.py`) | `test-logic`, `check`, `admission-debug-integration` and the startup-capacity targets on both systems | Every omitted-value surface consumes the module. `host-launch-integration` reads the module instead of copying values. `test-logic` pins the approved values |
| Native launch or descriptor and startup capacity | `test`, `host-launch-integration`, `descriptor-capacity-integration`, `codex-h2-integration`, `transport-h2-integration` on both systems | Composed gates cover the first three only |
| Shared `check.sh` driver | Driver tests and `check-full` once | Driver tests require exact fixture membership, overlap, batch drainage and failure propagation; native fixtures need not run again through `check` |
| Dispatch scenarios | `dispatch-integration` and `dispatch-debug-integration` on both systems | `dispatch_integration.py` owns scenarios; shared helpers live in `model_fixture.py`. Neither composed gate runs the Debug `failure-correlation` mode |
| Shared control, model and Host-process fixture helpers | `check`, both H2 targets and affected standalone Current or reply-delivery targets | `model_fixture.py` keeps all shared consumers. H2 and standalone consumers are outside the composed driver |
| Standalone Current, reply-delivery and login-signal oracles | Owning integration target; login signal on Linux only | Neither composed gate runs them. Changes to their helpers keep these targets |
| Canonical-failure oracle | `canonical-failure-integration` on both systems | Skip it when a composed gate is selected; the human CLI fixture runs all cases |
| Build, dependencies or bootstrap | `check-full`, full Debug admission, long timeout and churn witnesses, relevant H2 and standalone targets, scheduled empty-cache evidence | Transport build, dependency pins and bootstrap select both H2 targets |
| Stable promotion (all paths) | Mac Selected and the [upgrade check](.github/workflows/previous-release-upgrade.yml) on hosted Linux and macOS, all on the exact main SHA | `previous_release_upgrade.py` installs the pinned prior build, saves real work, then restarts the same Store under the candidate. Strict paths add no main gate |
| Host stack frames (Zig under `src/` outside frontend owners, `build.zig`, `tests/ci/stack_frames.*`) | `stack-frames` on x86-64 Linux; `check` runs it, `check-full` does not | [stack_frames.py](tests/ci/stack_frames.py) reads the ReleaseSafe binary's prologues and direct calls. It fails on a frame over 8 KiB reachable from a Host thread or a function of a module in `host_modules` unless an exception in [stack_frames.json](tests/ci/stack_frames.json) names its cause, and on a thread whose deepest chain passes its `chain_ceiling`. Exceptions and ceilings only shrink. Calls through function pointers outside `host_modules` are not followed, and no other platform is measured |
| CI policy | Selector tests, workflow validation and `test-logic` on both runner architectures | Exercise actual CI bootstrap |

`test-logic` compiles `src/logic_tests.zig`, which includes answer-rendering tests absent from `src/tests.zig`. Neither composed gate covers that root, so run it with a selected composed gate. The compiler and dependency setup action is bootstrap, not CI policy. An unavailable selection base is an error. `wip/land-*` pushes select the tip's complete delta against the main merge base. An exact-tip dispatch replaces a cancelled push run; a dispatched Selected run lands only if main contains its `base` and `base..tip` spans `main..tip`'s paths.

Qualification Go changes select `measurement-check`. Linux-memory Python or C changes also run the collector unittests and compile the diagnostic probe on Linux. Other qualification changes state manual syntax or compilation requirements. Stored historical results select no product suites. Syntax checks, probe compilation and unrelated product tests do not qualify a resource claim.

### Landing cadence

[AGENTS.md](AGENTS.md#landing) owns the landing rule and per-commit proof. Append each small, coherent green change to the single open `wip/land-N` immediately and qualify its current exact tip. Lane completion and review signoff are not prerequisites. Focused checks on changed layers are development feedback. Daily suites do not qualify intermediate merges.

Selected CI runs affected-owner targets on Linux for PRs and `wip/land-*`; upgrade checks run once, on stable candidates. Linux predicts Mac except where code may differ by platform: a ready PR that changes a Mac-specific path also runs its native mapping on Mac (`check` when none is mapped). [platform_boundary.py](tests/ci/platform_boundary.py) owns those paths: C, patches, build and packaging inputs, Mac CI wiring, `src/os/` and `tests/integration/os_semantics.py`. Its test fails when any other Zig source or fixture names the platform or calls a syscall whose Darwin semantics diverge. The scan cannot see runtime divergence such as socket buffering or process timing, so a change to a fixture that uses raw sockets or waits on process lifetime also runs [on-demand Mac qualification](#hosted-qualification) (`qualify-macos.yml`, `suite=native`) on its revision before landing. Every Linux Selected run with targets also runs `zig build typecheck-macos`, which type-checks the product and unit tests for Apple Silicon without an SDK, link or run, so a Darwin-only compile error fails the Linux gate. The `linux` aggregate alone gates main, including strict paths; overall Selected status cannot turn a Mac failure into a main gate. After landing, Auto-land explicitly dispatches Mac Selected and the upgrade workflow on main because GITHUB_TOKEN pushes do not emit ordinary push workflows. A merged PR's push to main wakes the same promotion phase. Stable qualification selects from the previous stable, forces Mac `check` and full `admission-debug-integration` even for an empty native mapping, and retains additional mapped targets. Both upgrade platforms always execute for stable candidates.

Stable advances non-force to the newest main SHA with successful exact-SHA Mac and upgrade evidence. The recorded selection base must be an ancestor of current stable, and its candidate delta must cover every path current stable..candidate changes, including reversions after the base. Candidate-as-base and noncovering ancestry cannot qualify. Absent, skipped, red or older checks cannot qualify a descendant or rewind stable. While any `stable-red` issue is open, no candidate promotes, however green: a later green run is not evidence that the race is gone, and only the fixing commit's `Fixes #N` closes the issue. A stable red adds the label to an issue another workflow filed, and any later failure with that signature reopens it, holding stable again. A stable qualification wakes Auto-land only after its report job, and a failed issue listing also holds promotion. A failed report job is red and leaves no hold; file that red by hand. Missing/offline Mac holds only stable. Fix Mac reds forward on main; revert only if the fix is slow. Daily full Linux and macOS qualification remains a backstop and files an issue when red. Renderer-only Linux diffs omit `check`; strict mixed changes retain it. Other branches run nothing. Draft PRs keep `test-logic`; ready PRs test the merge ref. Report native architecture, skips and unrun cases; cross-compilation and skips are not native passes. Keep sensible timeouts and cleanup and resource guards.

The existing always-run Auto-land promotion phase reconciles missing current-main dispatches before deciding stable. It submits only an absent stable-titled Selected run or absent upgrade run; queued, running, offline, failed, cancelled and skipped attempts are retained, not relaunched. Ordinary diagnostic Selected dispatches do not hide a stable qualification. Each main qualification explicitly dispatches a completion callback. Its bounded CLI wait runs outside the ref-writer lock and supplies no acceptance evidence. Failed or timed-out waits skip that callback's writer; incomplete workflows remain ineligible, and the next normal promotion pass rechecks completed evidence. [Landing](AGENTS.md#landing) documents bootstrap, lost-completion and diagnosed Auto-land-job recovery. No timer or automatic native-test retry is part of this recovery. Control-plane calls whose repetition creates no test evidence make up to three attempts: Auto-land's qualification and release dispatches, the completion wake and the release artifact download annotate each retry as a warning, and toolchain and dependency downloads use curl's own retry. Before resubmitting a qualification dispatch, Auto-land checks whether the failed submission created the run; a repeated wake or release dispatch is harmless because the writer and release are serialized and release skips a released SHA.

### Composed gates

`check` runs formatting, ReleaseSafe native tests and process integrations, a Debug artifact and recovery smoke, ReleaseSmall deliverables and, on x86-64 Linux, `stack-frames`. Required functional assertions stay required when their fixture changes. Native and process suites run concurrently, except short-deadline Host-startup and Debug smoke cases, which follow the parallel batch. The Debug smoke covers streamed-capture failure and recovery, Store-lease exclusion, committed-but-lost Message replies, changed-source capture preservation and same-key configuration and Message replay after a Host crash.

Human CLI caller, renderer, terminal-restoration and canonical-failure cases run as separate parallel peers in `check` and the `callers` partition. The driver waits for every peer before isolated cases and fails if any peer fails. The unsplit serial gate retains its original case order and assertions.

`zig build check-full` runs routine native tests and process integrations serially after formatting and production builds. Selected CI runs it on Linux for build or dependency changes; macOS `check-full` runs in Daily Mac CI. Run the unsplit default locally for release qualification and isolated process-latency claims. It is not an every-edit gate. Serial execution reduces unrelated load but does not establish scheduler order; use owner-visible outcomes or handshakes for ordering claims.

Linux Selected CI and each platform's qualification run the full gate as `-Dcheck-part=execution` and `-Dcheck-part=callers` on two isolated runners at the same revision. Both must pass. Their disjoint fixtures cover the full gate once; callers run Host-process, allocator, launch and Debug smoke cases serially after the parallel batch. [qualification.py](tests/ci/qualification.py) packs other Linux targets so a Selected run never exceeds ten shards. Only when the diff touches no strict path does a shard rerun a failed batch once and report both results; a pass after the rerun is a flake to fix. Qualification keeps one job per target. macOS packs native work into at most three workers: execution plus portable logic, callers, and remaining native targets. Composed gates, long witnesses, launch, Debug admission, reply delivery and H2 stay isolated from other target batches. The `linux` and `macos` statuses fail if any selected job fails or is cancelled. Use unsplit `zig build check-full` for single-machine isolated-latency or release evidence.

Driver `fixture passed: exit=0 elapsed=1.234s` records (`failed` on nonzero exit) attribute fixture cost, not CPU time, isolated latency or speedup.

Use explicit gates, not hold durations, for race ordering. Artificial shared setup or pair deadlines and prelaunch fit reserves are not routine prerequisites.

### Renderer contracts

[Renderer contracts](.github/workflows/renderer-contracts.yml) run nonblocking build targets on pull requests and `wip/land-*` pushes that touch source or the harnesses, and nightly: `renderer-contracts-selftest`, the synthetic `direct-pty` key matrix with tmux smoke and Ghostty vectors, `direct-pty-controls`, `input-equivalence`, unattended input replay and `sequence-model`. No gate root imports their sources, and neither Selected checks nor the landing rule requires them; a red result is a defect to fix, not a waiver. The nightly run adds the [renderer mutation runner](tests/ci/renderer_mutation.py) for `test`, `test-logic` and `sequence-model` and files an issue on failure. Its anchors are checked per change: [`renderer_mutation_test.py`](tests/ci/renderer_mutation_test.py), run by the Selected `policy` job, requires each mutation's anchor exactly once in current source, so moving a protection re-anchors its mutation in the same change.

Run decoded-input replay with `zig build terminal-restoration-integration -- input-replay`; the default restoration gate excludes it. Its native actor drives production `SessionTerminal`, `TerminalInput` and `TerminalEditor` without a Host and requires exact keys, modifiers, paste provenance, editor outcomes, draft bytes and carets for Shift+Enter `ESC CR`, Opt+Enter forms, Kitty, modifyOtherKeys, marked paste and Ctrl-C. `ESC CR` becomes `ESC LF` under ICRNL and inserts a newline, never a submission. Every case checks cleanup bytes, saved terminal configuration and descriptor flags after reap. [Input equivalence tests](src/terminal_input_equivalence_test.zig) own exhaustive fragmentation. Injected PTYs are not physical keyboard, terminal-emulator or display qualification.

### Long witnesses

Long witnesses are explicit qualification steps outside `check` and `check-full`. Run them apart from load-generating suites. Changes to their build wiring or fixtures need both routine and long-step evidence.

| Witness | Required cadence | Retained or deferred evidence |
| --- | --- | --- |
| `zig build test-full` | Client response-wait, inactivity or timeout-default changes, relevant toolchain or platform changes, release qualification | The 61-second witness checks the production 60-second setting in real time. Routine runs report this one skip |

`check-full` alone does not claim exact-duration evidence. Release evidence requires `check-full`, the long step and applicable platform and resource gates.

Optional `cross-check-linux` and `cross-check-macos` compile supported and experimental architectures. They are not native evidence or a support promise. The Mac cross-build requires an Apple SDK.

### CI artifacts and caches

[Selected CI](.github/workflows/check.yml) cancels superseded checks per branch; main stable qualification keeps distinct SHAs so a newer candidate cannot cancel an older candidate's evidence. Build caches hold compilation inputs and outputs, not acceptance. All Zig unit Run steps bypass Zig acceptance caching, and Go tests use `-count=1`. Cache-policy changes run [the fixed-seed execution regression](tests/ci/cache_execution.py) on Linux before main and Mac during stable qualification, in a job the `linux` and `macos` statuses do not require. Build-cache keys separate native tools, Apple SDK, architecture, dependency pins, scripts, source inputs and shard. PR caches never feed a privileged workflow.

Each platform builds its target closure once with `ci-build -Dci-targets=...`. On Linux, when the selection compiles the single-threaded unit test binary alongside other gates, one producer builds only that binary (`-Dci-part=unit`) and another builds the rest (`-Dci-part=rest`); build.zig refuses a split whose selection never reaches the unit compile. [build_artifact.py](tests/ci/build_artifact.py) transfers the executables and pinned package sources through immutable same-run artifacts that expire after one day. Workers accept either one whole part or exactly the unit and rest parts, with disjoint executable inventories that together match the extracted tree, and verify each exact artifact ID, archive digest, run and attempt, source and tree, platform selection, OS, architecture, compiler digest and executable hashes before use; runner image versions are logged, not compared. Extraction rejects traversal, special files, hardlinks and symlinks. On any mismatch or rejection the worker discards the artifact, fetches pinned packages and compiles its own checkout with `ci-build`, stating why; a failed local fetch or compile stops the worker with its exit status. The receipt records compilation, never a test result. Gates then execute through the existing driver with `-Dci-artifacts=.zig-cache/o/ci-compiled`. Go tests, the string sanitizer and fixture C helpers compile fresh in their worker. Every selected gate executes on the run's own revision; no earlier result substitutes for execution.

The compiled handoff selects Zig's baseline CPU (`x86_64` on Linux, `apple_m1` on macOS ARM64) and emits `ci-cpu.json`. Consumers check that manifest before any gate. The build graph rejects incompatible target or optimization overrides. Transport's C build uses explicit platform targets without host-specific CPU flags. Ordinary local builds keep native CPU selection. Architecture and runner-image equality do not establish CPU compatibility.

A fixture that retains a failed root copies its `probe.log`, PTY gate metadata and native-observation failure metadata through [host_process.py](tests/integration/host_process.py), excluding private directories, symlinks and special files. Each root reserves one of sixteen slots, holding at most eight files and one MiB, so concurrent fixtures stay within 128 files and sixteen MiB. Uploads expire after three days. Successful gates do not capture. Native observation failure metadata is copied after reap and before temporary-root deletion.

[Cache maintenance](.github/workflows/cache-maintenance.yml) warms production compilation daily and after trusted main pushes that change build, dependency or maintenance inputs. Cleanup keeps the newest snapshot per platform and partition for open PRs and two for main, and removes closed PR caches; these are targets, not a quota. Warm baselines are not test acceptance. Maintenance also builds the pinned previous release per platform for the read-only upgrade check. The API-only cleanup job runs trusted main code with cache-deletion permission and consumes no producer code, caches or artifacts.

CI uses only standard `ubuntu-24.04` and Apple Silicon `macos-15` runners in this public repository, with no paid host or storage expansion. Free eligibility does not prove capacity; report the actual runner outcome and do not raise paid spend silently. Apart from the shard rerun above, test execution has no automatic retry.

### Hosted qualification

[Linux qualification](.github/workflows/qualify-linux.yml) runs full native gates in isolated jobs on demand and daily, including credentials, measurement checks and long witnesses. [Daily Mac CI](.github/workflows/daily-macos.yml) runs full sharded native qualification, including macOS `check-full`, and the complete resource campaign when main changed since its last completed scheduled attempt. [report_issue.py](tests/ci/report_issue.py) files each failure under its cause signature: the failing fixture and its raising line, a Zig test, or a gate's own error, read from the full job logs. One `ci-red` issue holds each signature and its recurrences. Stable qualification files its reds the same way, labelled `stable-red`; a `wip/land-*` tip files only the failures its passing jobs retried. A later green run never closes an issue: the commit that fixes the fixture or its owner says `Fixes #N`, and a recurrence reopens the issue. These backstops report the actual main SHA, not coverage of intermediate merges. A failed, cancelled or skipped attempt is never a pass.

[On-demand Mac qualification](.github/workflows/qualify-macos.yml) resolves a requested ref once and runs existing targets on `macos-15` VMs: `gh workflow run qualify-macos.yml -f ref=<revision> -f suite=<suite>`. Suites: `footprint` (20-wave repeated work), `resources` (all resource targets, footprint included), `native` (full checks, standalone integrations, long witnesses) and `all`. Gates execute fresh. A ref lacking the setup action, handoff tooling or targets fails rather than substituting checks. Requested-ref qualification uses workflow-level `cache-mode: read`; it can restore but not publish caches. `contents: read` alone does not impose that boundary. Pinned actionlint 1.7.7 predates the key, so validation ignores only its top-level-key diagnostic for the workflows that declare it; `test_requested_ref_cannot_publish_shared_caches` rejects absent policy or job-level overrides.

Artifacts expire after three days and keep the source SHA, VM and toolchain identity, gate output, bounded footprint reports and failed-fixture diagnostics, never Stores, HOME, credentials or payloads. Missing evidence is not a pass. Hosted counters describe that VM, not a physical Mac; physical comparisons and desktop UI need hardware. Live-provider checks need authorized credentials. Hosted runs establish no power-loss durability, mixed-workload qualification or aggregate memory from Host-only evidence.

The macOS resource campaign runs daily in Daily Mac CI, not per candidate; Linux resource campaigns run on request. The workflow offers all ten resource targets on macOS and the six portable ones on Linux; admission, message admission, model dispatch and model retry reject Linux. Linux cannot qualify the macOS footprint counter and shared-runner pacing is unqualified, so the campaign is not candidate acceptance. Its nonzero exits remain failures and file an issue.

[Scheduled cold acceptance](.github/workflows/cold-acceptance.yml) builds and runs the serial full gate daily on both platforms with empty local, global and package caches. Cold findings stay attached to the scheduled SHA. Routine orb work is incremental rebuilding, the affected mapping and reproducing one failure; full, churn, long, credential and measurement campaigns belong in hosted qualification. Keep timing-sensitive measurements on an isolated native machine when shared-runner evidence is invalid.

[fetch_dependencies.sh](src/fetch_dependencies.sh) imports pinned native archives in save mode, verifies hashes against the unchanged manifest and fetches the complete graph. Use it on both platforms. Stock Zig 0.17 no-save fetch ignores `--pkg-dir`. To reproduce a cold build from a clean source export without `zig-pkg`:

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

Releases add no gate. [Release](.github/workflows/release.yml) publishes only commits that `stable` contains, so the evidence that promoted a commit also qualifies its release. Auto-land dispatches the workflow after each promotion. To recover a lost dispatch, run `gh workflow run release.yml --ref main -f sha=<stable SHA>`.

[release.py](tests/ci/release.py) skips a SHA that an existing release already includes, and it numbers the version from existing tags. Each platform's native runner builds the tagged commit with empty caches and ReleaseSafe. The targets are portable: a baseline CPU, glibc 2.34 on Linux and macOS 15 on Apple Silicon. Each build must report the version and exact SHA from `rui --version`. The Linux executables are stripped, and their debug info ships as a separate `-debug` archive that crash traces read once it is extracted beside them. The release attaches the archives, `SHA256SUMS` and an `install.sh` that pins the archive digests.

`test_release.py` uses fake archives. It covers version planning, template filling and the installer's update, digest, version and preservation behavior. One manual check installed tagged archives through the filled installer on macOS 15, and under dash on Ubuntu 22.04 x86-64 with glibc 2.35. Debian 11, with glibc 2.31, refuses to load the Linux build. Another manual check built the Linux release, ran the stripping step, extracted the debug archive into an installer-shaped build, and sent `rui host serve` SIGSEGV: the trace showed source lines, and without the debug files it showed `???`. No hosted job runs a published archive or checks a trace.

### Measurement and release evidence

Measurement runners use Go 1.27.1 and modules pinned in `tests/qualification/go.mod` and `go.sum`; Go is measurement-only. Before `zig build measure-*`, run `GOTOOLCHAIN=local go -C tests/qualification mod download`, then `zig build measurement-check`. Record Go and gopsutil versions, `go.sum` and binary hashes, platform, Git revision and dirty state. Measurement provenance reports a revision only when `git -C` resolves the measurement root as its top level; otherwise both fields are unavailable.

Release evidence includes deterministic Session, model, tool, permission, context, compaction, workflow and server fixtures; hard-termination recovery at each acknowledgement and effect boundary; compiler-backed discovery of both production graphs; and the opt-in live Codex repair through those owners. Classify unused, conditional and test declarations and remove obsolete interfaces. Never label interrupted or unrun checks passed.
### Product tenets at stage completion

After each coherent change lands, independently review its completed caller flow on `main` against the following tenets. This design review is not a landing gate. Required behavior, recovery and resource proof remains in the [canonical gates](#canonical-gates).

- **Simplicity:** explain the required behavior or demonstrated cost that justifies each added module, durable fact, cache or queue. Check for duplicate authority and caller-owned coordination that belongs inside an existing owner; compare a simpler approach where one could preserve the required behavior. Identify dependencies introduced or removed on another owner's representation, call order or lifetime, and justify each retained one by required behavior. Passing tests establish tested behavior, not design simplicity.
- **Explainability:** walk ordinary work, failure and recovery in plain language using the stage's normal results and inspection. A reader can tell what happened, what remains uncertain and what can happen next. Explanations follow owning facts and do not treat optional diagnostics as recovery authority. Check this as each caller path appears, before final presentation work.
- **Memory footprint:** rerun comparable fixtures as resource owners are added, recording aggregate peak and retained-idle footprint, including native libraries and Rui helpers. At fixed capacity, vary payload and durable-history populations independently and exercise fill and drain with delayed cleanup or failure. Explain changes from the preceding measurement and resolve unexplained growth before dependent work builds on it. Use the [resource targets](#resources-and-accepted-host-qualification-targets); stage checks do not replace qualification of the complete simultaneous workload or introduce per-module quotas.

Record these with the stage's existing evidence.

## Platform qualification

Run affected behavior and process-crash recovery checks natively on Linux x86-64 before main and macOS Apple Silicon before stable promotion. Run resource comparisons when the resource owner or claim changes. Record actual architecture, toolchain, platform skips and unavailable counters. OS-crash, power-loss and general sandbox guarantees are outside scope; keep exact internal limits and best-effort external runaway and cleanup tests. A known incompatibility needs an explicit response, not a hidden fallback. Verify the selected credential backend, access checks, account-preserving refresh and failed atomic save without plaintext fallback or credential inheritance. Same-user authorized Bash can access credential files. Installer and startup checks use disposable HOME and checkouts; personal installations, Stores and credentials are not fixtures.

For a fixture-created private temporary root, call `canonical_fixture_root` from [host_process.py](tests/integration/host_process.py) once, right after creation, before deriving Store, Workspace or HOME. Use that root for Host and client arguments, wire identities and expected values: macOS `/var` and `/private/var` name one directory but differ under exact wire identity. Keep intentional alias and security negatives raw, as in the [Conversation fixture](tests/integration/conversation_page_integration.py).

Native PTY capture keeps the parent's slave open through output collection, caller reap and terminal-restoration checks, because Darwin can discard unread output when the last slave closes. Child exit alone is not completed capture. Marker readers reject EOF or Linux `EIO` immediately with their retained prefix. Only intentional hangup and EOF controls release the slave before collection. These fixture lifetimes do not change product deadlines.

`python3 tests/integration/host_allocator_test.py /path/to/rui` runs in both composed gates. On macOS it requires one same-PID allocator-default replacement when defaults are missing, preserved explicit or empty values, no replacement with both supplied or with `RUI_HOST_MALLOC_DEFAULTS=0`, no Store effects before replacement, and startup failure without a Store if the executable disappears. Non-Host invocations add no defaults, and Linux shows no replacement. Run workload correctness with defaults enabled and disabled, and measure the uninstrumented binary separately: constructor probes prove startup order, not memory savings. Record the macOS version and caller overrides; untested OS releases are not covered.

Run the provider fuzz campaign with `zig build test -Dtest-filter='fuzz provider' --fuzz=1K --summary all -j2`. Native Mac live C-linked fuzzing fails at link with the stock Zig 0.17 compiler (missing `__sanitizer_cov_trace_*` hooks). Seeded corpus and allocation passes on Mac are not a live-fuzz pass.

## Qualification workload and measurement boundary

These rules define the workload behind the [Host targets](#resources-and-accepted-host-qualification-targets):

- **Capacity:** 100 model Operations live at once, each completing its original result and releasing scratch and custody, in two fill and drain rounds on one Host. Keep 1, 8 and 16 capacity baselines and independent payload, item, history-growth and failure checks. A 1,000-capacity model, Bash, Edit and mixed proof belongs to finished-product qualification.
- **Repeated work:** `zig build measure-repeat-work` runs 20 six-second waves on one Host across 100 stable Sessions. It validates each request's complete history and input, exact results, one H2 connection and 100 ready streams per wave, and custody and scratch release. Record per-wave lifetime-peak and retained-idle footprint, CPU, I/O, descriptors and SQLite configuration and usage, and keep `heap --noContent -s` and `vmmap -summary` output after each drain; report missing tools as unavailable, not zero. The 25,000,000-byte target applies to every wave. Retained-idle deltas need attribution before a stable-churn claim. The snapshots are diagnostics, not additive counters. Obsolete request encodings do not qualify.
- **Pacing:** 260-byte SSE records at nominally 30 events per second per stream (100 at capacity 100) across 60 seconds: exactly 1,800 or 6,000 events per stream, none dropped, delivery after all streams are ready. Record actual delivery duration, achieved rate and gaps; they are diagnostics. A run with jitter qualifies only the observed workload. The 120-second collection bound is a test timeout, not a throughput promise.
- **CPU:** exclude the provider fixture from Rui totals but record it; its populations must drive representative transport allocations inside Rui. Start the first Host CPU read no earlier than second 10 and the second no earlier than second 50 and 40 seconds after the first finishes. Divide by the interval from the first read's finish to the second read's start (at least 40 seconds), and finish the second read before any stream completes. Report both read brackets and the measured delivery duration; missing overlap evidence leaves average CPU unqualified. Measure complete-work CPU from admission through result audit and release without an idle tail, and tool or mixed CPU separately.
- **Controls:** keep 100 live model Operations before each control sample and replace cancelled work. Include exact interruption and Session stop, inspect saved outcomes and verify cleanup. Keep inspection and import-contention checks. Report physical cleanup apart from acknowledgement, and retry discovery apart from dispatch.

Model-output runners keep JSON evidence and exit nonzero for failed, incomplete or target-miss verdicts. A miss needs an implementation or product decision; adding pools or rerunning until green does not satisfy it. Measure the Rui CLI and helpers separately from the Host target.
## Contract index

ARCHITECTURE owns behavior; tests own cases. Quoted names are Zig filters: `zig build test -Dtest-filter='immutable binding'`. Other identifiers name targets, `tests/integration/` fixtures, modes or functions. `none located` means no check; `planned` means unimplemented behavior. Neither is coverage. Update rows with checks.

## Asynchronous peer collaboration

These rows target the accepted [peer composition](ARCHITECTURE.md#agent-identity-and-peer-composition) and [non-interactive CLI](ARCHITECTURE.md#cli-modes-and-commands), not today's runtime. Extend existing owners and their gates; replace obsolete wait wrappers and fixed-quota assertions while keeping capture, original-result, control, delivery and cleanup coverage.

### Native behavior and failure cases

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Model self-address, `rui --help` pointer and self-label command, unchanged preamble, Workspace and caller instructions; separate peer sender and local-result facts; explicit report delivery through Bash with its Host-recorded sender (`RUI_ADDRESS`, Action handle, capture recovery) | `peer_integration.py`, `human_cli_integration.py`, `'request preparation'`, `'recorded sender facts'` | Scripted provider proves workflow and rendered facts, not future model compliance. Fixture-observer snapshots synchronize holds and audit saved outcomes. Native Linux x86-64 and macOS arm64. Compaction and replacement Attempt identity: none located |
| Peer self-send admitted with explicit and generated capture; canonical Store alias and bare Session ID; plain answers saved as request results without implicit delivery; parent receives literal backticks, `$()` and quotes byte-exact through Bash tool stdin and file sends without shell evaluation or login | `peer_integration.py`, `'a peer capture preserves'` | No sender is inferred for human or script sends; original-capture recovery is unchanged. Shared text owns prose; independent request encoding, structural validation, history and digest negatives remain |
| Peer page identities and TUI labels carry the same full six-character ID; Activity decoding rejects obsolete abbreviation metadata without changing Message selection | `activity_integration.py`, `store.zig` `'a peer sender'`, `session_view.zig` `'a peer reference'` | Conversation decoding retains its ordinary unknown-field policy. No independent label allocation or abbreviation collision machinery |
| Bare `--to ID`; sender Store beats conflicting HOME defaults; anonymous explicit Store selection; conflicting peer Store override and malformed peer context reject before capture; JSON, prefix, UUID, NUL, uppercase and excluded alphabet variants reject without aliases | `'grammar rejects ambiguous'`, `peer_integration.py`, `sender_identity_integration.py` | Genuine no-sender external sends remain anonymous. Noncanonical references are never coerced or prefix-matched |
| Store allocates exactly six CSPRNG Crockford characters under unique insertion; actual collision retries, original creation replay, unknown update no-create; ten concurrently created peers each start and send back by ID; guessed unknown IDs admit no work | `store.zig` `'Store allocates six'`, `peer_integration.py` | Forced secure-entropy draws exercise the collision branch independently of random chance. Scripted provider proves runtime routing, not model compliance |
| `session start` atomically allocates and admits its first Message; committed lost output and concurrent first admissions/replays retain one ID and input; rollback/rejection leave no orphan; cancellation/reopen never readmit | `store.zig` `'initial Message'`, `server.zig` `'initial Message reply'`, `peer_integration.py` | An ID is admission, not execution/completion. Existing Message observation and original-result contracts apply |
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
| [Capture, recovery and descriptor bound](ARCHITECTURE.md#caller-capture-and-recovery) | `'capture retransmits'`, `'capture publication'`, `human_cli_integration.py`, `saved_request_resources.py BASELINE CANDIDATE` | The `fsync` cut is Linux-only and not power loss. The resource fixture needs `/proc` and samples descriptors without asserting the bound |
| Configuration binding, Message admission and selection | `'immutable binding'`, `'message admissions remain'`, `'runnable discovery'`, `dispatch_integration.py`, `canonical_failure_integration.py` | Sizes are qualification workloads, not request quotas |
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
| [Independent requested and reported model identity](ARCHITECTURE.md#codex-wire-binding) | `'provider interpretation preserves independently reported model evidence'`, `dispatch-integration` evidence cases | Exact source-separated certificate, absent sources, differing headers and body, unchanged raw items, original public answer and correlation through restart. Malformed body metadata and conflicting duplicate values for one header still reject. Synthetic, not live provider or cross-model continuation evidence |
| [Answer and tool-call acceptance](ARCHITECTURE.md#accepting-an-answer-or-tool-calls) | `'Bash descriptions'`, `'complete call outcomes'`, `'message phases'`, `'partial answer fixture'`, `'synthetic gpt-6-luna shaped'`, `dispatch_integration.py phased-messages` | Synthetic streams, not recovered live captures. Commentary, partial-answer and unphased messages interleave calls, select one result, replay exact items and survive Host crash/restart. The partial-answer item shape comes from the pinned first-party fixture linked in Architecture, not executed upstream-test proof. Missing finals without calls, duplicate finals and unsupported phases reject |
| [Refusal preservation](ARCHITECTURE.md#codex-wire-binding) | `'provider refusal'`, `'replay compatibility'`, `dispatch_integration.py refusals` in `dispatch-integration` | Synthetic refusal-only and mixed text/refusal messages preserve public result and Conversation text through Host crash/restart. Canonical raw items and replay retain the refusal type. Missing, null and duplicate refusal text, unsupported blocks, delta-only responses and incomplete streams still reject |
| [Reasoning text is private evidence, not replay input](ARCHITECTURE.md#codex-wire-binding) | `'without its private reasoning text'`, `'large private replay validation'` | Synthetic saved items: ordered, reordered, whitespace and escaped `content` keys drop under three emission schedules while summary, `encrypted_content`, status and open fields replay exactly; empty `content` and a prefix-named open field stay. Existing malformed-reasoning controls still fence or reject on the saved text. Not live backend acceptance evidence |
| Empty selected answers complete with no result text; nonblank answers retain surrounding whitespace | `'completed empty assistant answers'`, `dispatch_integration.py empty-answers`, `human_cli_integration.py empty-answers` | Synthetic phased and unphased empty/Unicode-whitespace answers, exact nonblank bytes, inspect/read-result, crash/restart replay and a usable TUI composer. Existing missing-final, duplicate-final, malformed and incomplete controls remain required |
| [Codex per-Turn sticky routing](ARCHITECTURE.md#adapter-historical-reads) | `'turn state observation'`, `'Codex turn state replays'`, `'owner changes invalidate paused Turns'`, `'Codex headers carry turn state'`, `codex-integration` turn-state journey | Synthetic h2c fixture: no value at Turn start or after an error answer, first successful value replayed unchanged on a 503 retry and a tool continuation, none for a later Turn in the same Session or a continuation after Host restart, and no Store row holds it. Account/FedRAMP changes invalidate paused Turns and reject old-epoch completions before and after the original account returns; refresh preserves the epoch. These owner transitions, first-value and least-recently-used replacement are value tests; the fixture credential cannot switch accounts. Not live routing evidence |
| Codex credentials, H2 and cache affinity | `codex-integration`, `codex-credential-integration`, `codex-h2-integration`, `'Codex affinity'`, `'refresh transport'`, `'only a refresh proven'`, `'sent or uncertain refresh'`, `'refresh rejection bodies'`, `'selection refreshes'` | Synthetic. Raw h2c peers cover not-sent evidence (refused connect, peer gone before its SETTINGS, an HTTP/1.1 peer) and a sent request with a lost reply; `test-h2`'s exchange cases cover the total deadline's sent flag. Every failure after HEADERS are packed retains pending. Value tests cover body codes and the inclusive 300-second margin. H2 needs `h2==4.3.0` ([requirements.txt](tests/integration/requirements.txt)) and is not in `check-full`. Live refresh HTTP is unverified |
| [One forced refresh after a managed model 401](ARCHITECTURE.md#authentication-and-transport-lifetime) | `'a refresh claim'`, `'a forced refresh runs only'`, `'only an answered model 401'`, `'a 401 forced refresh is claimed'`, `codex-integration` forced-refresh journey | Synthetic h2c covers an identical replacement, a second 401, login-required failure and newer ready or pending credentials preserving the answered 401 and correlation without resend. Value tests cross ready/pending state with equal/different generation. Store tests cover the durable claim across transient failures and reopen, stale binding and the final Attempt boundary. The fixture republishes synthetic tokens, not remote refresh HTTP. Cross-Host generation exclusion is a unit test; crash recovery is Store reopen, not a Host-process cut. Stop during refresh is untested |
| [Codex request envelope](ARCHITECTURE.md#codex-wire-binding) and supported-model compaction defaults | `codex-integration`, `codex-h2-integration`, `'supported model compaction'`, `'request preparation'` | Synthetic outgoing HTTP bodies and revision header, all eight exact IDs and both parallel policies. Unknown IDs retain no inferred trigger and no parallel calls. No live backend qualification |
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
| HTTP 429 quota versus rate limits | `'HTTP 429 quota'`, `'HTTP quota refusal'`, `dispatch_integration.py http-quota` in `dispatch-integration` | Three distinct permanent codes, valid reset and request correlation through reopen, one Attempt, unchanged temporary rate-limit recovery. Unknown or malformed codes grant no quota authority. Synthetic provider only |
| SSE failure classification, clean close and nullable evidence | `'provider interpretation'`, `'provider completion treats null'`, `'retryable stream rejections'`, `dispatch_integration.py stream-failures` in `dispatch-integration` | Synthetic `error` and `response.failed` retries, permanent quota and policy controls, malformed framing and code controls, four-Attempt exhaustion, exact final diagnostic and correlation through reopen, and no accepted failed prefix. No live provider evidence |
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
| Evidence layers | `test-logic`, `bash-owner-integration`, `bash-lifecycle-integration` | No reruns to pass |
| [Frozen catalog and permission mode](ARCHITECTURE.md#authorizing-exact-actions) | `'frozen catalog'`, `'allow once survives'` | Workflow bypass across restart: none located |
| Bash-only catalog and configuration: exact `bash`/`none` CLI, `["bash"]`/`[]` wire; removed Edit and duplicate/alternate spellings reject | `human_cli_integration.py`, `proposal_integration.py`, `dispatch_integration.py`, `'Current facts'` | Public arrays and private SQLite masks remain distinct representations |

## Exact Edit

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Exact Edit](ARCHITECTURE.md#exact-edit) ranges, copyback, failures | none located | Edit execution is unimplemented |

## Workflow replay and cancellation

### Creation and public calls

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Compile-only entry/import validation](ARCHITECTURE.md#evaluator-containment) | none located | Workflow Runtime unimplemented |
| [Workflow identity, creation keys, Session functions](ARCHITECTURE.md#workflow-identity-and-saved-calls) | none located | Workflow Runtime unimplemented |

### Evaluation and result binding

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Restricted Promise and global surface | none located | Workflow Runtime unimplemented |
| [Evaluator output and scratch ownership](ARCHITECTURE.md#owning-evaluator-input-and-output) | none located | Workflow Runtime unimplemented |
| [Saved-result binding and selection](ARCHITECTURE.md#reevaluating-from-saved-results) | none located | Workflow Runtime unimplemented |

### Cancellation and submission recovery

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Workflow cancellation, intent tokens](ARCHITECTURE.md#cancelling-a-workflow) | none located | Workflow Runtime unimplemented |
| [Same-key caller recovery](ARCHITECTURE.md#caller-capture-and-recovery) | `human_cli_integration.py`, `control_integration.py` | Direct clients only |

## Controls, inspection and local server

### Durable controls

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Control replay and conflicts](ARCHITECTURE.md#recovering-a-submission-after-a-lost-reply) | `'exact model interruption'`, `'idle Session stop'`, `'controls remove scheduled retries'`, `'allow once survives'`, `'immutable binding'` | Reopen is not crash recovery |
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
| [Sessions associated with a Workflow](ARCHITECTURE.md#inspecting-sessions-associated-with-a-workflow) | none located | Host facts only; reject local-record or SQLite discovery. Declarations or rejections alone add no Session |
| [Default and terminal-only waits](ARCHITECTURE.md#work-state-and-wait-conditions) | none located | Waits never start, resume or follow future work. Permission returns do not replace exact-target validation |
| Opening and older history: frozen opening, exact pending count without previews, each admitted Message exactly once across older pages, listing and retained copy after eviction | `human_cli_integration.py` | Equal-content Messages included; labels as of their read |
| Current selection, pending count, ten recent Messages | `'Current facts'`, `current-facts-integration`, `store.zig` `'Current selects active then queued'` | Suppressing callbacks beyond 128 rows must fail the complete count. Fixed storage is not process memory or Mac evidence |
| [Per-key outcomes as data](ARCHITECTURE.md#outcomes-and-observation-errors) | `human_cli_integration.py`, `store.zig` `'Current reports progress alongside'` | Composed reads may span commits. A timeout proves neither rejection nor work failure |
| [Full report inventory](ARCHITECTURE.md#capturing-and-delivering-reports) and scratch | `store.zig` `'Full exposes exact closed'`, `'report scratch exhaustion'` | Latency and growth matrix: none located |
| [Mutation presentation](ARCHITECTURE.md#public-operations) and canonical envelope | `canonical-failure-integration`, modes `producers`, `committed`, `interactive`, `presentMutationReply` tests | Negatives fail at exact assertion, not setup. PTYs use one unrenewed ten-second exit deadline. No macOS, power-loss or aggregate claim |
| Null and binding corruption rejection | `canonical_failure_integration.py nulls`, `bindings`, `null-interactive`, `binding-interactive` | Unfixed null witness fails at invalid-response; omitted binding check fails native mismatch and caller typed-error assertions, not setup |
| Keyed observation decoder | `canonical_failure_integration.py keyed`, `keyed-bindings`, `keyed-output` | `keyed-bindings` and `keyed-output` fail on unchanged baseline at omitted-binding and unknown-DOM assertions |
| Keyed owner footprint | `message_observation_resources.py BASELINE CANDIDATE` | Uninstrumented ReleaseSafe. Not aggregate memory or Mac |
| [Caller capture and recovery](ARCHITECTURE.md#caller-capture-and-recovery) | `human_cli_integration.py` | Uncertain Bash effect never replayed |
| [Bare entry](ARCHITECTURE.md#human-entry-and-authentication) overview and `require_model` | `human_cli_integration.py` `overview_cases`: bare `rui` creates nothing and shows the empty-Store hint; composer `/configure --permission-mode ask --label` then Enter sends one `session start` with `require_model` and those settings and opens the new Session; Enter opens a row and Esc returns; `session resume` then Esc shows the overview; a start captured and never sent recovers. `canonical_failure_integration.py`: a canonical Store failure in a start's reply restores the terminal, exits nonzero and names the start's recovery handle; a mismatched or null-code reply keeps the overview open and names it. Store selection, the login offer, TMPDIR and capture-failure cases expect the overview and no request. `Overview.zig` tests: each effect runs its client operation, each source reaches the core, a reply is unconfirmed only when the request may have reached the Host, a canonical Store failure in a listing, first-line read or start ends the overview, Ctrl-C leaves while output is blocked, and the composer is the conversation's line editor: bytes that are not text, an overfull draft, every Shift-Enter and Alt-Enter encoding and caret edits. `'every key does what the overview's table says'` presses each key of `src/keymap.zig` in each of its encodings on an empty and on a rejected draft and expects the table's action, or nothing where it binds none; `'Shift-Up and Shift-Down select'` the row above and below whatever the draft holds; `'a start freezes the composer'` until its answer while the table's keys still act, and `'a start sends what its Enter captured'` after Esc clears the draft and settings. `overview_view.zig`: an open or unconfirmed stop keeps its row stopping and refuses a second stop; a mark pulses out of step with others while its change is under three seconds old, then holds still; a state change under the same mark (working, Bash, working) does not pulse under a changed or full listing, and a new mark does; and never in ASCII, `NO_COLOR` or a faded view; the core ticks as each pulse ends; the screen asks for frames only while a pulsing mark shows; a frame writes only the spans that changed. `Overview.zig` tests also cover each frame rewriting a pulsing mark alone until the tick that ends it, and the poll budget cut to the next frame only while the screen pulses. `host_launch_integration.py`, `store.zig` `'capability-required configuration'` | Mac terminal, interrupted-login and post-send lost-reply evidence required. Ctrl-X stop and the Host-unavailable view are verified with their own issue |
| Overview look: Khadi skins, background query, top lines | `overview_view` in `test-logic`: every colour role has an entry in both skins and its nearest 256-colour entry; whole screens at 80x24 and 200x60 for each skin and depth, played through a model terminal that checks every cell's colour; `NO_COLOR` draws bold and reverse only; skin choice for a dark, light and missing answer; Indian grouping at 0, 999, 1,000, 1,00,000 and 1,00,00,000; the headline, the Since-you-looked line (a failure or a Host restart shows it, a keypress clears it, finishes alone do not) and the Host-stopped band's priority. `TerminalInput.zig` `'a background answer is a colour report; a malformed one is dropped and keeps the next key'` | Live tmux lanes only: the OSC 11 answer and the 200 ms wait are not measured on physical or Mac terminals. Fonts are the terminal's choice |
| [Saved defaults](ARCHITECTURE.md#store-selection-and-defaults) | `'preference edits'`, `human_cli_integration.py` | Not credential, launch, Mac or power-loss |
| [Release-supported model IDs](ARCHITECTURE.md#supported-model-ids) | `human_cli_integration.py compiled-models` in `check` | Exact shared help/error/notice membership; rejected explicit and saved IDs before capture or input reads; accepted IDs, retained stale pins, one detached startup notice and quiet attach, valid and cleared defaults. Fixture endpoints do not prove account entitlement or live qualification |
| Preference publication faults | `preference-policy-integration`, `zig test -lc src/preferences.zig --test-filter 'directory sync'` | Linux and macOS in `check`. No crash or power-loss durability |
| Provider selection, credential status | `'installed local credential status'` | Selection does not prove remote acceptance |
| Login chooser, keys and SIGINT | `'login owner'`, `codex_token_wire` tests, `human_cli_integration.py` | DEL, BS and Kitty Backspace edit. Unbound Alt and lone combining marks leave the choice with a notice; malformed keys reject at Enter. Restore saved termios. Full synthetic exchange and Mac PTY remain required |
| Masked login signal installation | `login-signal-integration` | Linux only. Unfixed owner must fail |
| [Bounded editor](ARCHITECTURE.md#staged-persistent-input) | `test-logic -Dtest-filter=TerminalEditor`, `'malformed keyboard values'`, `human_cli_integration.py long-input` and `renderer` | 65,536 bytes accept; 65,537 reject even after Backspace. Malformed keys reject Action choices; modifier 256 is valid, unknown keys are ignored. ESC ESC `[201~` rejects and ends paste; later input is draft text. Linux PTY is not Mac display or physical keys |
| [Lost-reply recovery](ARCHITECTURE.md#recovering-a-submission-after-a-lost-reply) in the composer | `human_cli_integration.py`, `zig test src/SessionSubmission.zig -lc --test-filter 'submission bounded'` | Count mutation exchanges, not only provider runs. Removing digest check must fail |
| Tool activity presentation | `human_cli_integration.py` | Native Linux and macOS visual qualification required |
| [Conversation keys](ARCHITECTURE.md#human-entry-and-authentication) | `SessionFrontend.zig` in `test`: `'End on an empty draft'` stays in the conversation; `'Ctrl-R beside a ready Action refuses its line'` in every encoding; `'Ctrl-R while approval is paused'` keeps the draft and recovers nothing; `'an Esc that expires'` does what a whole Esc does at the Action, from a paused draft and from the settled view; `'every way out of the conversation ends consent'`. `terminal_input_equivalence_test.zig` in `test-logic` | Linux PTY replay, not physical keys |
| Departure and consent values | `session_departure`, `session_consent` in `test-logic` | Not native consent evidence |
| [Exact Action consent](ARCHITECTURE.md#authorizing-exact-actions) | `human_cli_integration.py` with `RUI_TEST_ACTION_READY_FD` | Disabling fresh-choice flush must fail the pre-Action `a` case at its owner assertion |
| Frames, paging, history | `human_cli_integration.py renderer`, `SessionScreen` tests, `stagePage` tests | Hosted Apple Silicon required. Physical terminals unverified, SIGKILL cleanup not promised |
| Terminal restoration, blocked output | `terminal-restoration-integration` (`renderer-backpressure`, `visible-stream`, `forwarding`) | Linux and macOS. Darwin excludes only termios `PENDIN`/`FLUSHO` and flag `FWASWRITTEN` |
| Detach notice | `'detached notice'`, `terminal-restoration-integration -- notice` | None |
| Composer readiness waits | `human_cli_integration.py terminal-waits` | Withheld composer is not readiness. 15 s readiness, 10 s exit, no renewal. Named selections are partial evidence |
| Fixture disposal | `host_process.dispose_all` in `host_process_test.py` | Body failure stays primary; failed cleanup after success fails |
| [Session listing](ARCHITECTURE.md#session-listing) | `session_list_integration.py`, `session_list_facts_integration.py`, `client.zig` and `protocol_reply.zig` `'Session list'`, `store.zig` `'a list row carries its Session's Label, times, first Message, work and peers'` and `'Session list capture and cursor storage stay page bounded'`, `'a list row reads the same steps however long its Session's history'`. `session_list_facts_integration.py` fails a later page and requires a nonzero exit with nothing on stdout. `protocol.SessionRow.budget_bytes` fails the build when a worst-case row exceeds 32 KiB | Interrupted delivery and Mac footprint unqualified |
| Session listing `since` | `change_ring` in `test-logic`: coverage after eviction, an entry point touching too many Sessions, the distinct changed set in ID order, one Workspace's entries, token grammar. `store.zig` `'a since listing answers only the Sessions changed since its token, or everything'`; `'a Workspace's changed page reads only its own Sessions, however many others changed'`: with 4,095 distinct Sessions of another Workspace changed after the token, a scoped page takes the same VM steps as with none. `'a failed Workspace-key read fails and fences the entry point that touched its Session'`: an interrupted key read during a relabel and during a Message fails that command, commits nothing and fences. `'a Session creation that rolls back never reaches a since listing'`. Every Store test runs under the test-build touch oracle, which panics when an entry point changes a Session's rows without recording it; `'the touch oracle names a Session whose rows changed without a touch'`. `protocol_reply.zig` `'a since reply answers its request's token'` and `'a traversal keeps its first page's token'`; `server.zig` `'an unchanged listing echoes its token'`. `session_list_integration.py`: an unchanged Store answers `not_modified` with the same token, a relabel answers exactly that row as `changed`, another opening's token answers `full`, and a malformed token is refused. `session_list_facts_integration.py`: a changed listing whose continuation is answered by a full first page prints that full listing alone, each Session once; a later page that fails, before or after that restart, prints nothing and exits nonzero | Spurious changes are allowed. `not_modified` taking no Store lock is by construction, not counted. Ring overflow under load is #557's measurement |
| [Session work](ARCHITECTURE.md#work-state-and-wait-conditions) | `session_work` in `test-logic`: each table row and tie, a past-due retry reading `pending`, the coarse status map, a quota failure's reset time, and `error.CorruptStore` for inputs no writer produces. `store.zig` `'Current, activity pages and Message progress report one work in each state'` and `'... through an approval'`, `'a stop that selected no Turn decides work only through the input it excluded'`, `'a quota reset is read from a saved record and never fences'`, `'contradictory work inputs fence the Store'`. With the clock stepped back: `session_work` `'the newer fact dates work, even when the clock stepped back'`; `store.zig` `'Session work dates a tool group by its last acceptance, even when the clock stepped back'` (approval after a denial, a settled group, and `bypass` Bash waiting after a sibling ran) and `'queued input is pending from the newer of its admission and the latest outcome, even when the clock stepped back'` | Different reads may observe different commits. An `allow_once` decision against a sibling's resolution, and the earliest launch for `bash`, are ordered by time: neither claims a position |
| Times pinned to state | `store.zig` `'each state-bearing row keeps exactly the time its state owns'`: a direct UPDATE that changes state without its time is rejected. `'every transition dates its fact from the Host clock'` | Wall-clock order is not asserted |
| [Store format](ARCHITECTURE.md#store-format-and-upgrades) closed value sets | `store.zig` `'closed value columns accept exactly their values'`: each enumerated Command kind, Conversation entry kind, Model Output Item kind, reasoning effort and Action Resolution column accepts its listed values and rejects others on a CHECK | A Conversation entry kind outside 1 to 3 is rejected by both its column CHECK and the kind-specific CHECK, so the probe cannot tell which one rejected it |
| Session position claims | `store.zig` `'claiming Session positions stops at the largest position, and fails when its write does not land'`: inside a write transaction, a claim ending at the largest position succeeds, a claim past it fails without moving the counter, and a claim whose guarded write changes no row fails with `CorruptStore` | The guard on the read value cannot be observed alone: within one write transaction no other writer moves the counter between the read and the write |
| [Activity `at`](ARCHITECTURE.md#public-session-activity) | `store.zig` `'every activity row is dated by the fact that owns it'` and `'a Tool Result is dated by its group's last acceptance, even when the clock stepped back'`, `protocol_reply.zig` `'an activity row carries its time'`, `activity_integration.py` | None |
| [Label](ARCHITECTURE.md#naming-and-configuring-a-session) | `store.zig` `'a Label is configured, replayed, cleared and validated like any setting'`, `cli.zig` `'a Label argument sets, clears or refuses before capture'`. `peer_integration.py`: A labels itself with `session configure --session "$RUI_ADDRESS"` and starts B with `--label`; listing shows both, and B's model requests never carry its Label. `human_cli_integration.py`: `/status` shows `Label: not set`, then the composer-set Label | Same idempotency and conflict rules as other settings |
| First Message, starter and `from_person_at` | `store.zig` `'a list row carries its Session's Label, times, first Message, work and peers'`. `peer_integration.py`: B's first Message names A as its sender, A's names none, and only A has a Message from a person or script | Configure-only Sessions report `null` |
| Creating Message `require_model` | `store.zig` `'a creating Message with require_model creates nothing without a model'`, `protocol.zig` `'only a creating Message carries require_model, and it binds the digest'` | Low-level `session start` without the condition stays available |
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
| [Conversation pages](ARCHITECTURE.md#public-conversation-pages) and streaming | `'public'`, `'sequential work'`, `'public assistant message provenance'`, `conversation_page_integration.py` | Exact message item, public projection, Session, Turn and Attempt bindings. No earlier-prefix authentication or aggregate memory |
| [Proposal reads](ARCHITECTURE.md#historical-proposal-reads) | `proposal-integration` | Not activity chronology. Cannot clear historical Mac reds |
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

## Resources and accepted Host qualification targets

Targets (Host-only; CLI/helpers separate):

- ≤25,000,000 bytes macOS lifetime-peak physical footprint at Active Capacity 1/8/16/100 and cold/retained idle: `measure-model-output`, `measure-call-classification`
- ≤256 MiB physical footprint, eventual 1,000-operation model/Bash/Edit/mixed load: none located
- Idle CPU <1% of one core: `measure-model-retry`, `measure-model-dispatch`
- Retry discovery ≤2 s after due at free capacity/light load: `measure-model-retry`
- ≤2 cores observed model-fixture CPU and ≤120 CPU s complete work, two same-Host rounds: `measure-model-output`
- p95 durable control acknowledgement ≤1 s with 100 live streams and 100 occupied custody records: `measure-model-control`
- 0/100/1,000/10,000 Dormant Sessions at fixed capacity: `measure-admission`
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
| [Installed upgrade](ARCHITECTURE.md#store-format-and-upgrades) | `previous-release-upgrade.yml`, `previous_release_upgrade.py` | Refusal until migrations exist |

### Canonical reads, retained output and SQLite

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Bounded content reads](ARCHITECTURE.md#canonical-content-reads-and-retention) | `'content reader owns the bounded result-delivery window'`, `'public content SQLite step failure fences after successful preparation'`, `'retained raw and projected readers allow checkpoints between committed windows'`, `'historical preparation yields covered group populations and cancels proposal authentication'`, `'yielded Bash preparation leaves checkpoints free while retaining its descriptor'`, `server_delivery_integration.py` held raw/projected Reply reads beside committed configurations | Checkpoint/reuse is not a hard WAL file-size quota |
| [Retention FIFO](ARCHITECTURE.md#retained-output-and-its-queue) | `'retention entry capacity derives from fixed orchestration memory'`, `'already absent retained files release their entries and scratch charge'` | None |
| Retention failure keeps result | `bash-owner-integration` | Host is not fenced |
| [10,000-byte tool tail](ARCHITECTURE.md#tool-excerpts-and-full-output) | `'UTF-8 excerpt keeps the newest source and reports replacement expansion'` | No line/total-capture quota or rerun for truncation |
| [Result sections](ARCHITECTURE.md#tool-excerpts-and-full-output): no empty stream header, full path only for a truncated stream, no confirmed-retirement note | `'results show only nonempty stream sections and mark truncation'`, `'cleanup deadline cuts off'`, `bash_integration.py`, `bash_owner_integration.py`, `bash_lifecycle_integration.py` natural exit, `human_cli_integration.py` permission case | Natural exit asserts the exact saved and model result on both systems, including macOS group-signal `EPERM`; injected signal failure stays visible |
| [Settings and faults](ARCHITECTURE.md#sqlite-and-representation) | `'production Store applies finite durable SQLite settings'`, `'an outside SQLite writer cannot take the open Store's lock'`, `'real SQLite full during import publishes no canonical prefix'`, `'measurement Store can force a smaller SQLite cache without changing production defaults'` | None |
| [Store durability](ARCHITECTURE.md#store-durability) | `'Store WAL lifecycle at the maximum path: sidecars, lock ownership, crash copy, checkpoint and restore'`, `'fresh Store uses current schema and rejects the prior version'`, process-crash recovery in `bash-recovery-integration` and `admission-debug-integration` | The crash copy is a file snapshot of an open Store, not an OS crash; no power-loss test |

## Evaluator lifecycle and limit replacement

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Evaluator containment](ARCHITECTURE.md#evaluator-containment): 16 MiB heap, 1 s CPU, 5 s lifetime, stack, descriptors | none located | Workflow Runtime unimplemented. Limit readback is not enforcement |
| Integration measurements before delivery replacement | none located | Prepared/requested ratio alone does not justify it |

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

Package under the Rui identity and verify executable and package names, state and credential identifiers, build and distribution references, and fixtures. Fixture recreation under the [Store format policy](ARCHITECTURE.md#store-format-and-upgrades) does not authorize changing user Stores; state packaging, state-path and credential-identifier obligations explicitly before release.

Release demonstrations cover explicit start, no-client progress, restart, direct Sessions, first configuration, cross-Workflow inspected-reference reuse, fan-out and joins, permissions, ordered tools, uncertain Bash and Edit, and shared cancellation. Independent native or Cloudflare walkthroughs add no embedding or cloud release requirement. Keep evidence attached to the real owners and label remaining gaps before claiming release readiness.

## Memory explanation evidence

For allocation, buffer, thread or resource-lifetime changes, record build and workload, allocation origin and owner, population multiplier, lifetime and attribution gaps. Distinguish live allocations, allocation volume, physical footprint and virtual reservation; overlapping counters are not additive. The [small Host memory trial](research/memory-trial/README.md) is a collection example, not a quota or a substitute for simultaneous-workload qualification.
