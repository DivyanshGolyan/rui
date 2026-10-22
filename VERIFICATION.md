# Verification

[ARCHITECTURE.md](ARCHITECTURE.md) owns behavior. This document owns required evidence: the gates below and the [contract index](#contract-index). Test production interfaces and real SQLite transactions against independent expectations. Crash tests kill a fixture process and reopen in a fresh one; injected returned errors are fault tests. Record revision, machine, dependencies, inputs and measurements. Prototypes, source inspection and compilation are not production qualification; [research evidence](research/README.md) records those limits. Git history keeps earlier test specifications and dated results.

## Canonical gates

Integration fixtures require Python 3.11 or newer on PATH; the composed driver rejects older interpreters and records the one selected. On macOS, do not use `/usr/bin/python3`. Diagnose interpreter failures apart from product assertions.

| Change class | Required gate or evidence |
| --- | --- |
| Documentation | References, consistency and `git diff --check` |
| Runtime behavior | Subsystem mapping below on the landing tip for Linux main acceptance; Mac mapping and full Debug recovery on the exact main SHA before stable promotion. A skip is not evidence |
| Build or dependency | Linux `check-full` and mapped checks on the landing tip; macOS `check-full` and empty-cache acceptance daily |
| Resource owner | Comparable measurements and lifecycle evidence on applicable runners |
| Evaluator integration | `workflow-check` for child and process cases, `evaluator-host-integration` for the private lifecycle owner, and complete evaluator and Workflow native qualification before a public integration claim. Only the private owner gates exist, on Linux; full cross-platform cases are planned |

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
| Model and transport | `test`, `dispatch-integration`, `transport-h2-integration`; `test-logic` for `src/transport_policy.zig` | Live provider remains opt-in |
| Codex credentials | `test`, Codex, credential and Codex H2 targets; `test-logic` for `src/codex_credential_policy.zig` and `src/codex_token_wire.zig` | No real account login required |
| Evaluator | `workflow-check`, `evaluator-host-integration`, `evaluator-churn`; string sanitizer for string changes | No Host resource campaign for an unchanged Host |
| Product defaults (`src/product_defaults.zig`, `tests/integration/product_defaults.py`) | `test-logic`, `check`, `admission-debug-integration` and the startup-capacity targets on both systems | Every omitted-value surface consumes the module. `host-launch-integration` reads the module instead of copying values. `test-logic` pins the approved values |
| Native launch or descriptor and startup capacity | `test`, `host-launch-integration`, `descriptor-capacity-integration`, `codex-h2-integration`, `transport-h2-integration` on both systems | Composed gates cover the first three only |
| Shared `check.sh` driver | Driver tests and `check-full` once | Driver tests require exact fixture membership, overlap, batch drainage and failure propagation; native fixtures need not run again through `check` |
| Dispatch scenarios | `dispatch-integration` and `dispatch-debug-integration` on both systems | `dispatch_integration.py` owns scenarios; shared helpers live in `model_fixture.py`. Neither composed gate runs the Debug `failure-correlation` mode |
| Shared control, model and Host-process fixture helpers | `check`, both H2 targets and affected standalone Current or reply-delivery targets | `model_fixture.py` keeps all shared consumers. H2 and standalone consumers are outside the composed driver |
| Standalone Current, reply-delivery and login-signal oracles | Owning integration target; login signal on Linux only | Neither composed gate runs them. Changes to their helpers keep these targets |
| Canonical-failure oracle | `canonical-failure-integration` on both systems | Skip it when a composed gate is selected; the human CLI fixture runs all cases |
| Build, dependencies or bootstrap | `check-full`, full Debug admission, long timeout and churn witnesses, relevant H2 and standalone targets, scheduled empty-cache evidence | Transport build, dependency pins and bootstrap select both H2 targets |
| Stable promotion (all paths) | Mac Selected and the [upgrade check](.github/workflows/previous-release-upgrade.yml) on hosted Linux and macOS, all on the exact main SHA | `previous_release_upgrade.py` installs the pinned prior build, saves real work, then restarts the same Store under the candidate. Strict paths add no main gate |
| CI policy | Selector tests, workflow validation and `test-logic` on both runner architectures | Exercise actual CI bootstrap |

`test-logic` compiles `src/logic_tests.zig`, which includes answer-rendering tests absent from `src/tests.zig`. Neither composed gate covers that root, so run it with a selected composed gate. The compiler and dependency setup action is bootstrap, not CI policy. An unavailable selection base is an error. `wip/land-*` pushes select the tip's complete delta against the main merge base. An exact-tip dispatch replaces a cancelled push run; a dispatched Selected run lands only if main contains its `base` and `base..tip` spans `main..tip`'s paths.

Qualification Go changes select `measurement-check`. Linux-memory Python or C changes also run the collector unittests and compile the diagnostic probe on Linux. Other qualification changes state manual syntax or compilation requirements. Stored historical results select no product suites. Syntax checks, probe compilation and unrelated product tests do not qualify a resource claim.

### Landing cadence

[AGENTS.md](AGENTS.md#landing) owns the landing rule and per-commit proof. Append each small, coherent green change to the single open `wip/land-N` immediately and qualify its current exact tip. Lane completion and review signoff are not prerequisites. Focused checks on changed layers are development feedback. Daily suites do not qualify intermediate merges.

Selected CI uses affected-owner targets on both platforms for PRs, but only Linux for `wip/land-*`. The `linux` aggregate alone gates main, including strict paths; overall Selected status cannot turn a Mac failure into a main gate. After landing, Auto-land explicitly dispatches Mac Selected and the upgrade workflow on main because GITHUB_TOKEN pushes do not emit ordinary push workflows. Stable qualification selects from the previous stable, forces Mac `check` and full `admission-debug-integration` even for an empty native mapping, and retains additional mapped targets. Both upgrade platforms always execute for stable candidates.

Stable advances non-force to the newest main SHA with successful exact-SHA Mac and upgrade evidence. The recorded selection base must be an ancestor of current stable, and its candidate delta must cover every path current stable..candidate changes, including reversions after the base. Candidate-as-base and noncovering ancestry cannot qualify. Absent, skipped, red or older checks cannot qualify a descendant or rewind stable. Missing/offline Mac holds only stable. Fix Mac reds forward on main; revert only if the fix is slow. Daily full Linux and macOS qualification remains a backstop and files an issue when red. Renderer-only Linux diffs omit `check`; strict mixed changes retain it. Other branches run nothing. Draft PRs keep `test-logic`; ready PRs test the merge ref. Report native architecture, skips and unrun cases; cross-compilation and skips are not native passes. Keep sensible timeouts and cleanup and resource guards.

The existing always-run Auto-land promotion phase reconciles missing current-main dispatches before deciding stable. It submits only an absent stable-titled Selected run or absent upgrade run; queued, running, offline, failed, cancelled and skipped attempts are retained, not relaunched. Ordinary diagnostic Selected dispatches do not hide a stable qualification. Each main qualification explicitly dispatches a completion callback. Its bounded CLI wait runs outside the ref-writer lock and supplies no acceptance evidence. Failed or timed-out waits skip that callback's writer; incomplete workflows remain ineligible, and the next normal promotion pass rechecks completed evidence. [Landing](AGENTS.md#landing) documents bootstrap, lost-completion and diagnosed Auto-land-job recovery. No timer or automatic native-test retry is part of this recovery.

### Composed gates

`check` runs formatting, ReleaseSafe native tests and process integrations, a Debug artifact and recovery smoke, and ReleaseSmall deliverables. Required functional assertions stay required when their fixture changes. Native and process suites run concurrently, except short-deadline Host-startup and Debug smoke cases, which follow the parallel batch. The Debug smoke covers streamed-capture failure and recovery, Store-lease exclusion, committed-but-lost Message replies, changed-source capture preservation and same-key configuration and Message replay after a Host crash.

`zig build check-full` runs routine native tests, the pinned evaluator string sanitizer, evaluator owner cases and process integrations serially after formatting and production builds. Selected CI runs it on Linux for build or dependency changes; macOS `check-full` runs in Daily Mac CI. Run the unsplit default locally for release qualification and isolated process-latency claims. It is not an every-edit gate. Serial execution reduces unrelated load but does not establish scheduler order; use owner-visible outcomes or handshakes for ordering claims.

Linux Selected CI and each platform's qualification run the full gate as `-Dcheck-part=execution` and `-Dcheck-part=callers` on two isolated runners at the same revision. Both must pass. Their disjoint fixtures cover the full gate once; callers run Host-process, allocator, launch and Debug smoke cases serially after the parallel batch. [qualification.py](tests/ci/qualification.py) packs other Linux targets so a Selected run never exceeds ten shards. Only when the diff touches no strict path does a shard rerun a failed batch once and report both results; a pass after the rerun is a flake to fix. Qualification keeps one job per target. macOS packs native work into at most three workers: execution plus portable logic, callers, and remaining native targets. Composed gates, long witnesses, evaluator churn, launch, Debug admission, reply delivery and H2 stay isolated from other target batches. The `linux` and `macos` statuses fail if any selected job fails or is cancelled. Use unsplit `zig build check-full` for single-machine isolated-latency or release evidence.

Driver `fixture passed: exit=0 elapsed=1.234s` records (`failed` on nonzero exit) attribute fixture cost, not CPU time, isolated latency or speedup.

Use explicit gates, not hold durations, for race ordering. Artificial shared setup or pair deadlines and prelaunch fit reserves are not routine prerequisites.

### Renderer contracts

[Renderer contracts](.github/workflows/renderer-contracts.yml) run nonblocking build targets on pull requests and `wip/land-*` pushes that touch source or the harnesses, and nightly: `renderer-contracts-selftest`, the synthetic `direct-pty` key matrix with tmux smoke and Ghostty vectors, `direct-pty-controls`, `input-equivalence`, unattended input replay and `sequence-model`. No gate root imports their sources, and neither Selected checks nor the landing rule requires them; a red result is a defect to fix, not a waiver. The nightly run adds the [renderer mutation runner](tests/ci/renderer_mutation.py) for `test`, `test-logic` and `sequence-model` and files an issue on failure.

Run decoded-input replay with `zig build terminal-restoration-integration -- input-replay`; the default restoration gate excludes it. Its native actor drives production `SessionTerminal`, `TerminalInput` and `TerminalEditor` without a Host and requires exact keys, modifiers, paste provenance, editor outcomes, draft bytes and carets for Shift+Enter `ESC CR`, Opt+Enter forms, Kitty, modifyOtherKeys, marked paste and Ctrl-C. `ESC CR` becomes `ESC LF` under ICRNL and inserts a newline, never a submission. Every case checks cleanup bytes, saved terminal configuration and descriptor flags after reap. [Input equivalence tests](src/terminal_input_equivalence_test.zig) own exhaustive fragmentation. Injected PTYs are not physical keyboard, terminal-emulator or display qualification.

### Long witnesses

Long witnesses are explicit qualification steps outside `check` and `check-full`. Run them apart from load-generating suites. Changes to their build wiring or fixtures need both routine and long-step evidence.

| Witness | Required cadence | Retained or deferred evidence |
| --- | --- | --- |
| `zig build test-full` | Client response-wait, inactivity or timeout-default changes, relevant toolchain or platform changes, release qualification | The 61-second witness checks the production 60-second setting in real time. Routine runs report this one skip |
| `zig build evaluator-churn` | Evaluator or process lifecycle or dependency changes, relevant toolchain or platform changes, release qualification | 1,000 cycles check cumulative native failures. Routine gates keep ten cycles. The 300-second outer timeout is not a throughput requirement |

`check-full` alone does not claim exact-duration or 1,000-cycle evidence. Release evidence requires `check-full`, both long steps and applicable platform and resource gates.

Optional `cross-check-linux` and `cross-check-macos` compile supported and experimental architectures. They are not native evidence or a support promise. The Mac cross-build requires an Apple SDK.

### CI artifacts and caches

[Selected CI](.github/workflows/check.yml) cancels superseded checks per branch; main stable qualification keeps distinct SHAs so a newer candidate cannot cancel an older candidate's evidence. Build caches hold compilation inputs and outputs, not acceptance. All Zig unit Run steps bypass Zig acceptance caching, and Go tests use `-count=1`. Cache-policy changes run [the fixed-seed execution regression](tests/ci/cache_execution.py) on Linux before main and Mac during stable qualification, in a job the `linux` and `macos` statuses do not require. Build-cache keys separate native tools, Apple SDK, architecture, dependency pins, scripts, source inputs and shard. PR caches never feed a privileged workflow.

Each platform builds its target closure once with `ci-build -Dci-targets=...`. [build_artifact.py](tests/ci/build_artifact.py) transfers the executables and pinned package sources through an immutable same-run artifact that expires after one day. Workers verify the exact artifact ID, archive digest, run and attempt, source and tree, platform selection, OS, architecture, compiler digest and executable hashes before use; runner image versions are logged, not compared. Extraction rejects traversal, special files, hardlinks and symlinks. On any mismatch or rejection the worker discards the artifact, fetches pinned packages and compiles its own checkout with `ci-build`, stating why; a failed local fetch or compile stops the worker with its exit status. The receipt records compilation, never a test result. Gates then execute through the existing driver with `-Dci-artifacts=.zig-cache/o/ci-compiled`. Go tests, the string sanitizer and fixture C helpers compile fresh in their worker. Every selected gate executes on the run's own revision; no earlier result substitutes for execution.

The compiled handoff selects Zig's baseline CPU (`x86_64` on Linux, `apple_m1` on macOS ARM64) and emits `ci-cpu.json`. Consumers check that manifest before any gate. The build graph rejects incompatible target or optimization overrides. Transport's C build uses explicit platform targets without host-specific CPU flags. Ordinary local builds keep native CPU selection. Architecture and runner-image equality do not establish CPU compatibility.

A fixture that retains a failed root copies its `probe.log`, PTY gate metadata and native-observation failure metadata through [host_process.py](tests/integration/host_process.py), excluding private directories, symlinks and special files. Each root reserves one of sixteen slots, holding at most eight files and one MiB, so concurrent fixtures stay within 128 files and sixteen MiB. Uploads expire after three days. Successful gates do not capture. Native observation failure metadata is copied after reap and before temporary-root deletion.

[Cache maintenance](.github/workflows/cache-maintenance.yml) warms production compilation daily and after trusted main pushes that change build, dependency or maintenance inputs. Cleanup keeps the newest snapshot per platform and partition for open PRs and two for main, and removes closed PR caches; these are targets, not a quota. Warm baselines are not test acceptance. Maintenance also builds the pinned previous release per platform for the read-only upgrade check. The API-only cleanup job runs trusted main code with cache-deletion permission and consumes no producer code, caches or artifacts.

CI uses only standard `ubuntu-24.04` and Apple Silicon `macos-15` runners in this public repository, with no paid host or storage expansion. Free eligibility does not prove capacity; report the actual runner outcome and do not raise paid spend silently. Apart from the shard rerun above, test execution has no automatic retry.

### Hosted qualification

[Linux qualification](.github/workflows/qualify-linux.yml) runs full native gates in isolated jobs on demand and daily, including credentials, measurement checks and long witnesses. [Daily Mac CI](.github/workflows/daily-macos.yml) runs full sharded native qualification, including macOS `check-full`, and the complete resource campaign when main changed since its last completed scheduled attempt. A failed attempt files or updates an issue for that SHA. These backstops report the actual main SHA, not coverage of intermediate merges. A failed, cancelled or skipped attempt is never a pass.

[On-demand Mac qualification](.github/workflows/qualify-macos.yml) resolves a requested ref once and runs existing targets on `macos-15` VMs: `gh workflow run qualify-macos.yml -f ref=<revision> -f suite=<suite>`. Suites: `footprint` (20-wave repeated work), `resources` (all resource targets, footprint included), `native` (full checks, standalone integrations, long witnesses) and `all`. Gates execute fresh. A ref lacking the setup action, handoff tooling or targets fails rather than substituting checks. Requested-ref qualification uses workflow-level `cache-mode: read`; it can restore but not publish caches. `contents: read` alone does not impose that boundary. Pinned actionlint 1.7.7 predates the key, so validation ignores only its top-level-key diagnostic for that workflow; `test_requested_ref_cannot_publish_shared_caches` rejects absent policy or job-level overrides.

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
| Model self-address, Bash send to a peer with its Host-recorded sender (`RUI_ADDRESS`, leading sender part and rule, capture recovery of the saved sender) and installed CLI | `peer_integration.py`, `human_cli_integration.py` | Native Linux x86-64 and macOS arm64. Compaction, replacement Attempt, restart and maximum-length or NUL addresses: none located |
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
| Reasoning effort and `rui models` | `'Current facts'` | Client parse only. Effort wire bytes and the catalog: none located |

### Provider validation and output ownership

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Answer and tool-call acceptance](ARCHITECTURE.md#accepting-an-answer-or-tool-calls) | `'Bash descriptions'`, `'complete call outcomes'`, `'message phases'`, `'synthetic gpt-6-luna shaped'`, `dispatch_integration.py phased-messages` | Synthetic streams, not recovered live captures. Phased and unphased messages interleave calls, select one result, replay exact items and survive Host crash/restart. Duplicate finals and unsupported phases reject |
| Codex credentials, H2 and cache affinity | `codex-integration`, `codex-credential-integration`, `codex-h2-integration`, `'Codex affinity'` | Synthetic. H2 needs `h2==4.3.0` and is not in `check-full`. Refresh HTTP is unverified |
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
| [Retries and timeouts](ARCHITECTURE.md#retries-and-timeouts): 1 + 3 Attempts, 2, 4 and 8 s waits, 5 min timeouts | `'model retry decision'`, `'Retry-After'`, `'inactivity defaults'`, `bash_owner_integration.py` | Retries may duplicate billing. Bash 5 min default: none located |

#### Runnable Bash caller acceptance audit

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Saved Bash result and cleanup recover after a Host crash | `bash-walkthrough` | Not live provider, power loss or a crash during an active Attempt |

### Bash lifecycle scenarios

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Expired Bash budget: exact budget, partial output and retry guidance in the saved result | `bash_owner_integration.py` | Successful commands omit timeout guidance |
| Stop during descriptor decoding launches nothing | none located | None |
| Original group does not retire naturally | `bash_lifecycle_integration.py` | Retirement facts precede reuse |
| [Detached writer survives](ARCHITECTURE.md#releasing-custody) | `'finite tail closes'`, `bash_lifecycle_integration.py` | Capture ends finitely without claiming retirement |
| Cleanup facts unavailable: fence only while facts stay unconfirmed | `bash_lifecycle_integration.py`, `'service acts'` | macOS `EPERM` |
| Cross-scenario matrix: splits, cutoff and status | `'resumable Bash parser'`, `'wide process exit'` | Native Linux and macOS. Cross-compilation does not qualify `WNOWAIT` |
| Capture cannot be completed | `'stops a running Attempt'` | None |
| Evidence layers | `test-logic`, `bash-owner-integration`, `bash-lifecycle-integration` | No reruns to pass |
| [Frozen catalog and permission mode](ARCHITECTURE.md#authorizing-exact-actions) | `'frozen catalog'`, `'allow once survives'` | Workflow bypass across restart: none located |

## Exact Edit

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Exact Edit](ARCHITECTURE.md#exact-edit) ranges, copyback, failures | none located | Edit execution is unimplemented |

## Workflow replay and cancellation

### Creation and public calls

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Compile-only entry/import validation](ARCHITECTURE.md#evaluator-containment) | `workflow-check` (`evaluator_integration.py`), `evaluator-host-integration` | Run in `check`. No creation or call-form checks. Entry-check negative control: none located |
| [Workflow identity, creation keys, Session functions](ARCHITECTURE.md#workflow-identity-and-saved-calls) | none located | Workflow Runtime unimplemented |

### Evaluation and result binding

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Restricted Promise and global surface | `evaluator_integration.py` | None |
| [Evaluator output and scratch ownership](ARCHITECTURE.md#owning-evaluator-input-and-output) | `evaluator-host-integration` | Private owner only; no Runtime population |
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
| Gated race ordering: sealed holds, four incomplete terminal inputs, dispatch stall witness, queued H1 expiry | `control_integration.py`, `human_cli_integration.py` `incomplete_input_case`, `dispatch_integration.py` | Incomplete inputs run serially against one Host. Pasted typeahead before readiness must not approve an Action. The stall witness owns one inactivity failure; exhaustion and progressing cases own theirs |
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
| [Bare entry](ARCHITECTURE.md#human-entry-and-authentication) and `require_model` | `human_cli_integration.py`, `host_launch_integration.py`, `store.zig` `'capability-required configuration'` | Mac terminal, interrupted-login and post-send lost-reply evidence required |
| [Saved defaults](ARCHITECTURE.md#store-selection-and-defaults) | `'preference edits'`, `human_cli_integration.py` | Not credential, launch, Mac or power-loss |
| Preference publication faults | `preference-policy-integration`, `zig test -lc src/preferences.zig --test-filter 'directory sync'` | Linux and macOS in `check`. No crash or power-loss durability |
| Provider selection, credential status | `'installed local credential status'` | Selection does not prove remote acceptance |
| Login chooser, keys and SIGINT | `'login owner'`, `codex_token_wire` tests, `human_cli_integration.py` | DEL, BS and Kitty Backspace edit. Unbound Alt and lone combining marks leave the choice with a notice; malformed keys reject at Enter. Restore saved termios. Full synthetic exchange and Mac PTY remain required |
| Masked login signal installation | `login-signal-integration` | Linux only. Unfixed owner must fail |
| [Bounded editor](ARCHITECTURE.md#staged-persistent-input) | `test-logic -Dtest-filter=TerminalEditor`, `'malformed keyboard values'`, `human_cli_integration.py long-input` and `renderer` | 65,536 bytes accept; 65,537 reject even after Backspace. Malformed keys reject Action choices; modifier 256 is valid, unknown keys are ignored. ESC ESC `[201~` rejects and ends paste; later input is draft text. Linux PTY is not Mac display or physical keys |
| [Lost-reply recovery](ARCHITECTURE.md#recovering-a-submission-after-a-lost-reply) in the composer | `human_cli_integration.py`, `zig test src/SessionSubmission.zig -lc --test-filter 'submission bounded'` | Count mutation exchanges, not only provider runs. Removing digest check must fail |
| Tool activity presentation | `human_cli_integration.py` | Native Linux and macOS visual qualification required |
| Departure and consent values | `session_departure`, `session_consent` in `test-logic` | Not native consent evidence |
| [Exact Action consent](ARCHITECTURE.md#authorizing-exact-actions) | `human_cli_integration.py` with `RUI_TEST_ACTION_READY_FD` | Disabling fresh-choice flush must fail the pre-Action `a` case at its owner assertion |
| Frames, paging, history | `human_cli_integration.py renderer`, `SessionScreen` tests, `stagePage` tests | Hosted Apple Silicon required. Physical terminals unverified, SIGKILL cleanup not promised |
| Terminal restoration, blocked output | `terminal-restoration-integration` (`renderer-backpressure`, `visible-stream`, `forwarding`) | Linux and macOS. Darwin excludes only termios `PENDIN`/`FLUSHO` and flag `FWASWRITTEN` |
| Detach notice | `'detached notice'`, `terminal-restoration-integration -- notice` | None |
| Composer readiness waits | `human_cli_integration.py terminal-waits` | Withheld composer is not readiness. 15 s readiness, 10 s exit, no renewal. Named selections are partial evidence |
| Fixture disposal | `host_process.dispose_all` in `host_process_test.py` | Body failure stays primary; failed cleanup after success fails |
| [Session listing](ARCHITECTURE.md#session-listing) | `session_list_integration.py`, `session_list_facts_integration.py`, `client.zig` `'Session list'` | Interrupted delivery and Mac footprint unqualified |
| [Conversation cursor bounds](ARCHITECTURE.md#public-conversation-pages) | `protocol.zig` `'conversation cursor parser rejects'`, `conversation_page_integration.py` | None |
| [Store ownership](ARCHITECTURE.md#exclusive-store-ownership) through listener failure | `admission_integration.sh` (`InjectedListenerFailure`) | A fixed sleep is not ownership evidence |
| [Ingress through admission](ARCHITECTURE.md#ingress-ownership-through-admission) | `admission_integration.sh` | None |
| Slow report readers beside controls | `server_delivery_integration.py` | Mid-capture and partial-delivery failure: none located |

### Server ownership and connection capacity

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Client transport](ARCHITECTURE.md#client-transport-and-observations) cancellation and backlog | `'transport cancellation'`, `test-full` | Backlog case Linux-only. Four mutation negatives must go red. Not File/sink preemption, Mac cancellation or aggregate footprint |
| [Host information](ARCHITECTURE.md#exclusive-store-ownership) probe and CLI status | `'Host information'`, `host-status-integration` | Mode-000 denial needs non-root client. Held-connection descriptor negative: none located |
| Detached launch, C adapter argv witness and startup refusal | `host-launch-integration`, `host_launch_exit_test.py`, `'startup diagnostics'` | Linux does not qualify Darwin helper or PTY detach. PID SIGKILL is crash cleanup |
| [Exact-instance stop](ARCHITECTURE.md#infrastructure-shutdown) and effect-aware drain | `host-stop-integration`, `host_stop_integration_test.py`, `'shutdown fences'` | Not power loss. Forced kill is crash cleanup. Fixed-timeout and wait-removal mutations must fail. Python oracle is not native proof |
| [Ingress ownership](ARCHITECTURE.md#ingress-ownership-through-admission), deadlines and retained cleanup | `'ingress'`, `host-status-integration` | Not disk latency or forced cleanup |
| [100 incomplete exchanges](ARCHITECTURE.md#connection-capacity-and-control-headroom) beside controls | `'hundred incomplete'` | Burst is not an admission quota |
| Session-list resource census | `session_list_integration.py`, `session_list_release_proof.py` | Held-cleanup and leak negatives are opt-in, Linux |
| Reply delivery inactivity and drain | `'reply delivery'`, `server-delivery-integration`, `PeerCensus` | Run apart from load. Not Mac drain or SIGPIPE |
| Controls queue behind settlement | `'active model settlement'`, `control_integration.py` | Store hold proves exclusion, not latency. Unordered contention reports unavailable |
| Control reply bounds | `'exact worst-case'` | Full 128-byte keys. No fixed 8 KiB allowance |
| [Conversation pages](ARCHITECTURE.md#public-conversation-pages) and streaming | `'public'`, `'sequential work'`, `'public assistant message provenance'`, `conversation_page_integration.py` | Exact message item, public projection, Session, Turn and Attempt bindings. No earlier-prefix authentication or aggregate memory |
| [Proposal reads](ARCHITECTURE.md#historical-proposal-reads) | `proposal-integration` | Not activity chronology. Cannot clear historical Mac reds |
| [Session activity](ARCHITECTURE.md#public-session-activity) and tool labels | `activity-integration`, `'tool label'` | `RUI_ACTIVITY_MEASURE=1` samples. No latency bound |
| [Content step faults fence](ARCHITECTURE.md#canonical-content-reads-and-retention) | `'public content SQLite step'` | None |

## Execution tracking and waiting

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Fixed custody population](ARCHITECTURE.md#capacity-ownership) | `'execution slots agree with custody across the complete population'`, `'no-work admission restores only its temporary custody reservation'` | Full scan, no free list; never a durable slot registry |
| Attempt admission rollback | `dispatch-integration` | Sample custody after `releaseUnused` in the same owner turn; suppressing it must fail |
| [Selection progress](ARCHITECTURE.md#capacity-and-selection-progress) and waits | `test-logic`, `'kind-specific admission'`, `'production turn preserves skipped continuation'`, `'receive advancement'`, `'receive scans without resume capacity'`, `'runnable discovery measures eligible ineligible and history populations independently'` | Not native transport or cross-platform qualification |
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
| Shared H2 and bounded H1 | `transport-h2-integration` | Opt-in; needs Python `h2==4.3.0`, OpenSSL CLI. Not footprint |
| Repeat-work footprint | `transport_h2_integration.py zig-out/bin/rui --observed-shape-churn` | macOS ReleaseSmall, opt-in; fails above 25,000,000 bytes. Not the Go repeat-work profile |
| Original result and release deadlines: one deadline per population, forwarded through reads and global release | `transport_h2_integration_test.py`, `host_process_test.py` | A clean reply at or after the deadline fails. Held cleanup must refuse through the deadline |
| Transfer finalization | `'Transfer finalization waits for real writer drainage and seals once'` | None |

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
| [Bounded content reads](ARCHITECTURE.md#canonical-content-reads-and-retention) | `'content reader owns the bounded result-delivery window'`, `'public content SQLite step failure fences after successful preparation'` | None |
| [Retention FIFO](ARCHITECTURE.md#retained-output-and-its-queue) | `'retention entry capacity derives from fixed orchestration memory'`, `'already absent retained files release their entries and scratch charge'` | None |
| Retention failure keeps result | `bash-owner-integration` | Host is not fenced |
| [10,000-byte tool tail](ARCHITECTURE.md#tool-excerpts-and-full-output) | `'UTF-8 excerpt keeps the newest source and reports replacement expansion'` | No line/total-capture quota or rerun for truncation |
| [Result sections](ARCHITECTURE.md#tool-excerpts-and-full-output): no empty stream header, full path only for a truncated stream, no confirmed-retirement note | `'results show only nonempty stream sections and mark truncation'`, `'cleanup deadline cuts off'`, `bash_integration.py`, `bash_owner_integration.py`, `bash_lifecycle_integration.py` natural exit, `human_cli_integration.py` permission case | Natural exit asserts the exact saved and model result on both systems, including macOS group-signal `EPERM`; injected signal failure stays visible |
| [Settings and faults](ARCHITECTURE.md#sqlite-and-representation) | `'production Store applies finite durable SQLite settings'`, `'an outside SQLite writer cannot take the open Store's lock'`, `'real SQLite full during import publishes no canonical prefix'`, `'measurement Store can force a smaller SQLite cache without changing production defaults'` | None |
| [Store durability](ARCHITECTURE.md#store-durability) | `'Store WAL lifecycle at the maximum path: sidecars, lock ownership, crash copy, checkpoint and restore'`, `'fresh Store uses current schema and rejects the prior version'`, process-crash recovery in `bash-recovery-integration` and `admission-debug-integration` | The crash copy is a file snapshot of an open Store, not an OS crash; no power-loss test |

## Evaluator lifecycle and limit replacement

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| [Evaluator containment](ARCHITECTURE.md#evaluator-containment): 16 MiB heap, 1 s CPU, 5 s lifetime, stack, descriptors | `workflow-check`, `evaluator-host-integration` | Mach-O reservation, mismatched-stack artifact, five-run timing: none located. Limit readback is not enforcement |
| 1,000 tiny same-parent evaluations | `evaluator-churn` | Canonical cadence; routine checks keep ten |
| Evaluator boundary and lifecycle-owner cases: diagnostics, settlement, output budget, prelaunch unlink, cancellation, driver rejection, blocked append, child wait ownership, delayed watchdog, terminal decisions | `workflow-check`, `evaluator-host-integration` | Run before process integrations. Rejection mutated to status 7 must fail `reject_check`; removing parent termination must fail live-child retirement. Blocked append is not a disk-stall witness |
| Bounded QuickJS string reader | `evaluator-string-sanitizer`, `evaluator-host-integration` | Recheck on QuickJS upgrades. Not Host scheduling or full resource qualification |
| Integration measurements before delivery replacement | none located | Prepared/requested ratio alone does not justify it |

## Diagnostics

### Native owner observations

| Contract | Canonical checks | Limits and exceptions |
| --- | --- | --- |
| Bounded channel, ordering, loss, startup credit, final state | `host_process_test.py`, `'private owner observations'` | Discover via `src/tests.zig`. Startup credit covers one inspection cohort, not a whole plan |
| Cleanup custody retires before publication | `'cleanup publication follows'` | Reversed retirement must fail. Not lease release |
| Receipt versus publication retirement | `prove_intentional_crash_retirement`, `prove_observation_disposal` | Crash paths stay unsealed; ordinary teardown seals |
| No-launch crash cut | `bash_integration.py` `prepared-before-handoff`, `prove_gate_broadcast` | Released gate must fail. Marker absence and publication retirement are not evidence |
| Capture receipts | `prove_required_capture_receipts`, `transport_h2_integration.py` capture cases, `terminal_restoration_integration.py capture-receipt` | Single cases are partial |
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
| Bounded export | none located | None |
## Release demonstrations

Package under the Rui identity and verify executable and package names, state and credential identifiers, build and distribution references, and fixtures. Fixture recreation under the [Store format policy](ARCHITECTURE.md#store-format-and-upgrades) does not authorize changing user Stores; state packaging, state-path and credential-identifier obligations explicitly before release.

Release demonstrations cover explicit start, no-client progress, restart, direct Sessions, first configuration, cross-Workflow inspected-reference reuse, fan-out and joins, permissions, ordered tools, uncertain Bash and Edit, and shared cancellation. Independent native or Cloudflare walkthroughs add no embedding or cloud release requirement. Keep evidence attached to the real owners and label remaining gaps before claiming release readiness.

## Memory explanation evidence

For allocation, buffer, thread or resource-lifetime changes, record build and workload, allocation origin and owner, population multiplier, lifetime and attribution gaps. Distinguish live allocations, allocation volume, physical footprint and virtual reservation; overlapping counters are not additive. The [small Host memory trial](research/memory-trial/README.md) is a collection example, not a quota or a substitute for simultaneous-workload qualification.
