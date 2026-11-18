# Canonical verification gates

[Verification](../../VERIFICATION.md) owns shared evidence rules and the subsystem index.

## Canonical gates

Integration fixtures require Python 3.11 or newer on PATH, with the packages pinned in [tests/integration/requirements.txt](../../tests/integration/requirements.txt) (python-h2 serves every loopback fixture over h2c); the composed driver rejects older interpreters and records the one selected.
PTY fixtures read the screen through libghostty-vt, from the test-only package in [screen-emulator](../../screen-emulator/build.zig.zon); build.zig builds it with a child `zig build` for the steps that run the observer and names it in `RUI_TEST_GHOSTTY_VT`.
The first such step fetches its pinned release tarball and packages into `screen-emulator/zig-pkg` and takes a few minutes; installs never fetch it.
On macOS, do not use `/usr/bin/python3`.
Diagnose interpreter failures apart from product assertions.

Run fixtures as a non-root user.
Root bypasses the file and socket permission denials that fixtures assert, so a root run fails them or proves nothing.
Every fixture entry enters the boundary in [host_process.py](../../tests/integration/host_process.py) before it starts anything.
A Python fixture calls `host_process.enter()` first in its main block.
Anything else runs through `python3 tests/integration/host_process.py exec COMMAND...`, which enters and then executes the command: `admission_integration.sh` re-enters itself this way, `check.sh` runs its native test binary this way, and build.zig runs every Go `measure-*` step this way.
`check.sh` also enters once before any case starts.
Entering stops a root process with that instruction, whether a build step or a person launched it.
It also replaces the process environment with the variables `INHERITED` names there (PATH, HOME, TMPDIR, locale and named fixture inputs, each with its reason) plus `TERM=xterm-256color`, so a caller's `RUI_*`, TLS trust or proxy settings cannot change what a fixture proves.
A fixture sets its own variables after entering, and its children inherit only those.
`host_process.py exec-mysql COMMAND...` additionally holds the shared MySQL socket lease across exec; the TypeScript process tests use it to exclude the Store shard-zero prelude of server-global tests, two long history fixtures and the exact session Handler-read comparison.
Importing host_process changes nothing, so tests/ci and fixture libraries can use it freely.
`FixtureEntryTest` in [test_harness_contracts.py](../../tests/ci/test_harness_contracts.py) finds every fixture entry (each shell script, and each Python module with a main block), runs it with root simulated and requires that refusal.
It also requires that every `measure-*` step goes through the exec entry.
Where the shell is root, as in many containers, run the command through `.agents/as-fixture-user LANE [--ref REF] -- COMMAND...`, for example `.agents/as-fixture-user pr4 -- python3 tests/integration/host_process_test.py`.
On first use it creates the ordinary account `rui-LANE`, which owns its home, its checkout of the committed REF (HEAD by default), its Zig cache and its Python 3.12 environment from the pinned requirements; later runs reuse them, and `.agents/as-fixture-user --remove LANE` deletes them.
Each lane has its own account, so concurrent lanes never share a checkout, a Host or a Store.
The account reads nothing of root's in place: root exports REF, `origin/main` and the `v*` tags into a repository only that account's group reads, copies the files and directories the caller's trust variables name beside it (each entry of an `SSL_CERT_DIR` list separately), and copies any Python 3.12, Zig or Go whose binary lies outside `/usr`, `/bin` and `/sbin`, with the trees the tool reports reading (`sys.base_prefix`, `zig env`'s lib directory, `go env GOROOT`), made readable by every user, all under `/var/lib/rui-fixture`, so the source checkout and toolchains may stay root-private.
COMMAND starts from an empty environment with the caller's proxy and trust variables, each trust variable the caller set pointing at the copy of what it named and no other set; [network_variables.py](../../tests/integration/network_variables.py) names the proxy and OpenSSL ones, which `host_process.py` still withholds from fixtures, and [fixture_user.py](../../tests/ci/fixture_user.py) names the tools' own and everything else the run keeps.
Every process the account runs gets its values through its environment, never its command line, which other accounts can read.

A fixture starts every process on a PTY through `spawn` in [terminal_process.py](../../tests/integration/terminal_process.py), never `subprocess.Popen`.
`spawn` runs the process as the foreground job of a session leader that owns the PTY ([terminal_leader.py](../../tests/integration/terminal_leader.py)), as a terminal's shell runs a program: `/dev/tty` is that PTY, and the PTY keeps the job's termios after it exits.
The process is never a session leader itself, because on macOS a session leader's exit revokes its terminal and resets the termios that restoration checks compare.
Closing the master hangs up the job, and so does the fixture's exit.
`spawn` takes Popen's arguments except `preexec_fn`; pass `default_signals=` and `rlimits=` instead.
An ignored signal stays ignored in the job, as in a Popen child, so a case that sends ^C passes `default_signals=(signal.SIGINT,)`.
The screen observer is the only terminal that answers the process's queries (DA1, DECRQM, OSC 11 and the rest libghostty-vt answers); `answers_to` in terminal_process.py sends each answer to the PTY the process reads.
A capture made with no `reply` is a silent terminal, for a fixture that answers that terminal itself.

| Change class | Required gate or evidence |
| --- | --- |
| Documentation | Review references and consistency. The plan runs `git diff --check` on the committed candidate diff. Only nonempty, exclusively allowlisted regular nonexecutable documentation and asset changes qualify for the [documentation lane](../../tests/ci/docs_only.py); executable, unknown and mixed changes keep normal verification. Source sentence layout remains optional |
| Runtime behavior | Subsystem mapping below on the PR head for Linux main acceptance; Mac mapping and full Debug recovery on the exact main SHA before stable promotion. A skip is not evidence |
| Build or dependency | Linux `check-full` and mapped checks before merge; `typecheck-macos` in the main build after merge; macOS `check-full` in promotion; manual empty-cache acceptance |
| Resource owner | Comparable measurements and lifecycle evidence on applicable runners |

The executable minimum is [select_tests.py](../../tests/ci/select_tests.py), using targets from [build.zig](../../build.zig) and its modules under `build/`.
An edit to `build.zig`, `build.zig.zon` or a hub module (`build/product.zig`, the Rui every target builds, and `build/ci.zig`, the CI artifact handoff) selects the full build gate; an edit to another module under `build/` selects only the targets its `BUILD_MODULES` entry names, which include every target it defines.
PR CI selects against the immutable merge candidate's first parent (`HEAD^1`), not a moving `origin/main` or the branch-head tree.
Run it locally only to diagnose a CI red.
[Evidence](../../CODING_STANDARDS.md#evidence) owns cheap local feedback, opt-in diagnostics and evidence reuse. Local receipts never establish hosted acceptance.
The selector reads the import graph of the tree it runs on: Zig `@import` and `@embedFile`, and the Python imports and `src/` reads of `tests/integration`.
A changed file selects each unit root that compiles it and each process fixture whose scripts use it or whose driven owners (`FIXTURES`) reach it, and the Host's dispatch into them.
A changed production `src/` file also selects fixtures whose Python or shell scripts contain a literal (including f-string constant parts) present in that file's quoted or Zig multiline string bodies at base or head, limited to at least 12 stripped characters containing a space and occurring in string bodies in fewer than three production `src/` files in the selector's working tree (counted only for prose found in changed files).
A functional core listed in `src/logic_tests.zig` selects only its unit roots and the fixtures that name it as an owner.
`RULES` add what no import names: C sources, generators, non-Zig consumers and fixtures that probe an owner from outside.
A selection that holds every case `check` runs becomes `check`; source that neither the graph nor a rule names falls back to `check`.
Promotion runs every fixture, so an edge the graph misses surfaces there and is added to `FIXTURES` or `RULES`.
Long, churn, full Debug and H2 targets follow their mappings, not an unconditional per-PR gate.

### Two tiers

The selection above is the main tier: promotion runs it, as do manual dispatches.
A ready PR runs the PR tier, which `fast_tier` in [select_tests.py](../../tests/ci/select_tests.py) derives from the same selection and [ci_plan.py](../../tests/ci/ci_plan.py) applies to `pull_request` events only:

- The whole-suite gates `check`, `check-full` (both parts), `test` and `test-full` never run on a PR. Any of them becomes `test-native`, the native unit root; a fallback `check` for a path the graph does not know becomes `test-native` and `test-logic` only.
- `test-logic` runs whenever the diff selects any product target.
- The short fixtures and unit roots the import graph, `RULES` and asserted text select still run individually.
- `test-store` runs only when the diff touches `src/store.zig` or `src/store/`, and every PR shard runs on SQLite alone: the plan provisions no MySQL 8.4 or Postgres server, so `forEachEngine` skips its MySQL and MySQL-rerun legs, `test-pg` runs only its offline tests, and `mysql-wire-integration` and `stack-frames` move to promotion.
- `upgrade-integration` and `human-cli-integration` (over three minutes each) run only when the diff touches their own scripts, executables or `FIXTURES` owners.

A green PR therefore no longer proves: the composed `check` and `check-full` driver runs, ReleaseSmall deliverables, the deadline witness in `test-full`, unit and fixture behavior against a live MySQL or Postgres server, the Store unit partition for non-Store changes, the human CLI and upgrade fixtures for changes outside their owners, and everything [Promote](../../.github/workflows/promote.yml) alone runs (macOS, `stack-frames`, the installed-release upgrade, renderer contracts).
Promotion proves those on main HEAD and bisects a failure to its commit; the owner accepted on 18 Nov 2026 that such a break reaches main first.

| Subsystem | Main-tier minimum (a PR runs its [PR tier](#two-tiers)) | Exceptions and notes |
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
| HTTP/2 client (`src/h2/`) | `test-h2`; `test-logic` for `src/h2/policy.zig` | Runs in `check` and the `check-full` execution part. Its peer tests run over loopback h2c and TLS in process. Linux system trust takes the host's certificate directory only when it holds a readable subject-hash entry, tested over hashed, bundle-only, absent and all-dangling directories; overrides replacing that probe are tested with a fixture CA the host does not know. System trust against real servers is manual, on each platform (macOS SecTrust above all), and not a gate: `RUI_H2_LIVE_URL=https://api.openai.com/v1/models zig build test-h2` and `RUI_H2_LIVE_NEGATIVE=1 zig build test-h2` |
| Postgres wire client (`src/store/wire/pg*.zig`, `scram.zig`, `tls.zig`) | `test-pg`, available in opt-in local diagnostics, for `src/tls_client/` (its OpenSSL settings and trust, shared with `test-h2`) | Runs in `check` and the `check-full` execution part. Decode tests use bytes captured from Postgres 16 and RFC 7677's SCRAM exchange. On Linux CI the live tests run against `postgres:15` over verified TLS with SCRAM-SHA-256-PLUS and fail if it is missing (`RUI_TEST_REQUIRE_ENGINES=postgres`); elsewhere they run only when `RUI_TEST_PG_PORT`, `RUI_TEST_PG_PASSWORD` and `RUI_TEST_PG_CA_FILE` name a server. A pipeline deeper than the socket buffers is the driver's concern and is not covered here |
| MySQL wire client (`src/store/wire/mysql.zig`) and the Store's blocking connection (`mysql_connection.zig`) | `test-logic` and `mysql-wire-integration`, available in opt-in local diagnostics; also `test` for those two files and `tests/integration/mysql_server.py` | `test-logic` runs `mysql.zig`'s own tests, and `test` replays its captures through the connection over a socket. `mysql-wire-integration` runs `mysql_wire_test.zig` through the connection against a MySQL 8.4 server in Docker, over its Unix socket, plaintext TCP and verified TLS, and fails, never skips, without Docker. `mysql_server.py` holds the one image pin; this harness and `check.yml`'s dialect-check server both start the image through it |
| Session focus, feed, welcome and list tabs | `test-native -Dtest-filter=SUI-4 -Dtest-filter=SUI-17 -Dtest-filter=SUI-19 -Dtest-filter=SUI-44 -Dtest-filter=SUI-45` | Catalogued screen-seam owners for focus and Settings, activity and message layout, welcome lifetime, and clipped tab rendering and hit targets; see `docs/invariants/session-ui.md` |
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
| Build, dependencies, bootstrap or the CI artifact producer | `check-full`, full Debug admission, long timeout and churn witnesses, relevant H2 and standalone targets, manual empty-cache evidence | Transport build, dependency pins and bootstrap select both H2 targets |
| Main admission, every ready PR | Successful plan and Linux aggregate on the immutable merge candidate: Linux compilation and format and the [PR tier](#two-tiers) of the selected Linux unit roots and integration targets, on SQLite only. Normal changes also require policy. The PR tier runs nothing else: native Mac, `typecheck-macos`, `stack-frames`, the [upgrade check](../../.github/workflows/previous-release-upgrade.yml), [renderer contracts](#renderer-contracts), the cache-execution proof and the Linux-memory collector checks belong to promotion, which the plan in [ci_plan.py](../../tests/ci/ci_plan.py) routes them to. The owner accepted on 18 Nov 2026 that a Mac, frame, upgrade or renderer defect now surfaces at promotion rather than on the PR | The conservative documentation lane requires explicit empty product selections and skipped policy, native and cache jobs. Admission requires the PR tier's Mac and cache-execution jobs to be skipped. Required admission runs before main |
| Promotion, manual | [Promote](../../.github/workflows/promote.yml) on main HEAD: Linux and macOS `check-full`, `test-logic` and `admission-debug-integration` with the batch's selected targets, `stack-frames`, the upgrade check on both systems, [renderer contracts](#renderer-contracts), then cold release builds | A failing job bisects each failed step over the batch since `stable` and files one `promotion-red` issue per cause. Only a fully green promotion publishes a release and advances `stable` |
| Host stack frames (Zig the Host compiles: `server.zig` and the `host_modules` closure; other `src/` inputs, `build.zig`, `tests/ci/stack_frames.*`) | `stack-frames` on x86-64 Linux in promotion; `check` runs it outside `-Dpr-ci`, `check-full` does not, and pull requests never run it | [stack_frames.py](../../tests/ci/stack_frames.py) reads the ReleaseSafe binary's prologues and direct calls. It fails on a frame over 8 KiB reachable from a Host thread or a function of a module in `host_modules` unless an exception in [stack_frames.json](../../tests/ci/stack_frames.json) names its cause, and on a thread whose deepest chain passes its `chain_ceiling`. Exceptions and ceilings only shrink. Calls through function pointers outside `host_modules` are not followed, and no other platform is measured |
| Caller error coverage (`cli.zig`, `cli_args.zig`, `client.zig`, `preferences.zig` and root `caller_*.zig` under `src/`) | `python3 tests/ci/caller_errors.py`, the prepush driver and CI policy | Caller-facing CLI modules cannot use raw `@errorName`; every literal production error reference or declaration in that inventory needs a catalog mapping or an existing pending entry. The trusted `origin/main` pending set only shrinks; first rollout bootstraps from the same trusted CLI-owned sources and the exact pinned Zig standard library. Closed inferred sets also fail compilation through `caller_error.of`; unmapped errors widened from other owners remain `internal_unexpected`, exit 1 (unclassified), without extending the CLI inventory. |
| CI policy | Selector tests, workflow validation and `test-logic` on both runner architectures | Exercise actual CI bootstrap. The policy job runs every `tests/ci` test except the self-checks in `POLICY_SELF_CHECKS` ([select_tests.py](../../tests/ci/select_tests.py)), each of which runs only when the diff changes a file it reads |
| Client locality (Zig client production import closure and named client sources, and `clients/ts/src` excluding generated `wire.ts`) | `python3 tests/ci/client_locality.py`, prepush and CI policy; `test_client_locality.py` tests the scan and ratchet | Production source scans reject named Host rule owners outside the existing allowlist. Exceptions only shrink against trusted `origin/main`; the first rollout accepts the initial list when no baseline exists. |
| Provider locality (any Zig under `src/`) | `tests/ci` unit tests, which run [test_provider_locality.py](../../tests/ci/test_provider_locality.py) | Core production code imports no sign-in file, names no ChatGPT header, ChatGPT endpoint or OpenAI error code, and names no provider by its tag (`Provider.codex`, `.openai =>`); tests and comments are blanked first. The owners are listed in the script; one allowance (the transport's own Host field list) names why. Text checks: a renamed header or a code spelled another way passes |

`test-logic` compiles `src/logic_tests.zig`, which includes answer-rendering tests absent from `src/tests.zig`.
Neither composed gate covers that root, so run it with a selected composed gate.

The verify-rui feature map is policy input: `test_verify_rui_map.py` checks that every named frame belongs to one linked feature recipe with the required sections.
Changes under `.claude/skills/verify-rui/features/` use the normal policy lane so documentation classification cannot skip this check; local feedback also selects it for those files and `scripts/frames.json`.

The compiler and dependency setup action is bootstrap, not CI policy.
An unavailable selection base is an error.
PR selection uses its recorded base and immutable merge candidate.
Ready normal changes retain policy and the Linux aggregate even for a narrow diff.
Only an explicit documentation classification or draft plan can omit policy; an empty target list alone cannot.
The Linux aggregate always checks the plan's selected parts or exact skips.

Qualification Go changes select `measurement-check`.
Changes to the CLI configuration surface (CLI grammar and client, creation defaults, the wire protocol and `openapi.json`, and Host configuration admission) select it too: its configure contract runs the measurement runners' `session configure` call and a replay of its saved record against the current Rui, so drift fails in the PR that causes it rather than in the next campaign.
Linux-memory Python or C changes also run the collector unittests and compile the diagnostic probe on Linux in promotion.
Other qualification changes state manual syntax or compilation requirements.
Stored historical results select no product suites.
Syntax checks, probe compilation and unrelated product tests do not qualify a resource claim.

## Composed gates

`check` runs formatting, ReleaseSafe native tests and process integrations, a Debug artifact and recovery smoke, ReleaseSmall deliverables and, on x86-64 Linux, `stack-frames`.
Required functional assertions stay required when their fixture changes.
Native, Store and process suites run concurrently, except short-deadline Host-startup and Debug smoke cases, which follow the parallel batch.
The Store unit root compiles once and runs as four concurrent processes through [the shared shard launcher](../../tests/ci/store_shards.py); native and each Store process retain separate 1200-second deadlines.
Shard zero first runs the seven tests that change MySQL server-global settings, the two long admission-history fixtures and the exact session Handler-read comparison under an exclusive socket lease, then releases the other shards. The history fixtures retain their 300-second test deadline and avoid competing MySQL clients during setup/replay. The Handler test already reads the Store connection's session counters; its exclusive window also excludes peer DDL that could add internal dictionary reads through shared metadata caches. Its warm-up and strict equality remain unchanged. Native and live MySQL process fixtures share the ordinary phase.
[Native unit roots](../../tests/ci/unit-roots.md) owns timing-based assignment, MySQL isolation and record aggregation.
Explicit `-Dtest-filter` runs retain one filtered aggregate process.
The Debug smoke covers streamed-capture failure and recovery, Store-lease exclusion, committed-but-lost Message replies, changed-source capture preservation and same-key configuration and Message replay after a Host crash.

Human CLI caller, renderer, terminal-restoration and canonical-failure cases run as separate parallel peers in `check` and the `callers` partition.
The driver waits for every peer before isolated cases and fails if any peer fails.
The unsplit serial gate retains its original case order and assertions.

`zig build check-full` runs the native/Store unit group before its serial process integrations, after formatting and production builds.
Within that group native and the four Store shard processes overlap, with the same per-process deadlines and MySQL isolation as `test` and `check`.
Selected CI runs it on Linux for build or dependency changes; promotion runs it on macOS, and manual qualification runs it on request.
Run the unsplit default locally for release qualification and isolated process-latency claims.
It is not an every-edit gate.
Serial execution reduces unrelated load but does not establish scheduler order; use owner-visible outcomes or handshakes for ordering claims.

Linux Selected CI and each platform's qualification run the full gate as `-Dcheck-part=execution` and `-Dcheck-part=callers` on two isolated runners at the same revision.
Both must pass.
The execution partition overlaps the native/Store unit group with its serial process fixtures; the unsplit gate finishes the group before starting those fixtures.
Their disjoint fixtures cover the full gate once; callers run Host-process, allocator, launch and Debug smoke cases serially after the parallel batch.
[qualification.py](../../tests/ci/qualification.py) packs other Linux targets so a Selected run never exceeds ten shards.
A long gate (`check`, `check-full`, `test`, `stack-frames`) runs alone, and beside one the short targets share three shards: they end inside the gate's run, so more shards would only repeat setup.
Only non-promotion manually dispatched runs whose diff touches no strict path rerun a failed batch once and report both results; a pass after the rerun is a flake to fix.
Ready PRs, promotions and the documentation lane never rerun, except a batch that failed only on [listed flakes](#listed-flakes).
Qualification keeps one job per target. macOS packs native work into at most three workers: execution plus portable logic, callers, and remaining native targets.
Composed gates, long witnesses, launch, Debug admission, reply delivery, H2 and UID-wide Upgrade stay isolated from other target batches.
Within a macOS worker using verified CI artifacts, independent acceptance commands overlap through Zig's existing DAG scheduler.
The shared build CI owner checks their exit status and keeps execution fresh while buffering combined output on stderr; inherited terminal I/O would hold Zig's global stderr lock.
Compilation, generated outputs, explicit I/O checks and Zig test protocols keep their existing owners.
The compiler-backed acceptance regression runs explicitly in the existing compiler-equipped `cache_execution` job alongside the warm-cache execution proof; its explicit `ACCEPTANCE_INPUTS` also select that job and focused local feedback, while it stays outside the five-minute Python policy suite.
A Selected checks dispatch can supply a JSON `native_targets` array to reproduce an exact native selection through the same producer, matrix and acceptance owners; this diagnostic mode disables retries and quarantine.
The `linux` and `macos` statuses fail if any selected job fails or is cancelled.
A failing aggregate names each failed job of its run and whether infrastructure or a check failed it ([failure_cause.py](../../tests/ci/failure_cause.py)), so a red never reads only as an exit code.
Use unsplit `zig build check-full` for single-machine isolated-latency or release evidence.

Driver `fixture passed: exit=0 elapsed=1.234s` records (`failed` on nonzero exit) attribute fixture cost, not CPU time, isolated latency or speedup.

Use explicit gates, not hold durations, for race ordering.
Artificial shared setup or pair deadlines and prelaunch fit reserves are not routine prerequisites.

## Renderer contracts

[Renderer contracts](../../.github/workflows/renderer-contracts.yml) run build targets in every promotion and on manual dispatch, never on pull requests: `renderer-contracts-selftest`, the synthetic `direct-pty` key matrix and Ghostty vectors, `direct-pty-controls` and `input-equivalence`.
No gate root imports their sources, and neither Selected checks nor merging requires them; a red result is a defect to fix, not a waiver.
Every promotion requires them, and a failing contract bisects the batch.
Manual dispatch adds the [renderer mutation runner](../../tests/ci/renderer_mutation.py) for `test` and `test-logic`.
There is no scheduled campaign, and only a promotion files issues.
Its anchors are checked per change: [`renderer_mutation_test.py`](../../tests/ci/renderer_mutation_test.py), run by the Selected `policy` job, requires each mutation's anchor exactly once in current source, so moving a protection re-anchors its mutation in the same change.

Injected PTYs are not physical keyboard, terminal-emulator or display qualification.

## Long witnesses

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

## CI artifacts and caches

[Selected CI](../../.github/workflows/check.yml) cancels superseded PR checks per branch.
The release publisher is serialized and never treats cancelled acceptance as a pass.
Build caches hold compilation inputs and outputs, not acceptance.
All Zig unit Run steps bypass Zig acceptance caching, and Go tests use `-count=1`.
Cache-policy changes run [the fixed-seed execution regression](../../tests/ci/cache_execution.py) in promotion when the batch changed cache policy, never on pull requests.
Cache policy is the proof, the prune script and the cache publication policy module themselves, and changed non-comment lines that name a Zig build cache or `has_side_effects` in the build, the workflows and the setup action, whose caches are all build caches; any change to the `cache_execution` job counts too.
The plan never selects it for a pull request, so `admission` requires it skipped there.
Build-cache keys separate native tools, Apple SDK, architecture, dependency pins, scripts, source inputs and shard.
Only `main` saves caches; PR jobs restore main's snapshots and save none, so PR caches never feed a privileged workflow or evict main's.
Setup restores caches and captures missing exact keys; an explicit `save-only` invocation of the same cache composite runs under `always()` after compilation, before long failure diagnostics.
The cache owner's `save-keys.cjs` derives publication keys from the setup and bounded work outcomes; it never overwrites an exact hit.
Only completed work is published under an exact key. The compiler download may save after later failure, but only after installation and version verification finish.
Except for the compacted Linux `compiled` snapshot, build and build-runner compilation that fails or step-times-out after successful setup saves under `<exact>-partial-<run_id>-<run_attempt>`, never under the exact key; failed setup/fetch publishes no compilation snapshot.
These partial keys match the existing prefix restore keys, report a non-exact hit, and therefore still run dependency fetch and the full build before publishing a complete exact key.
The same final publication owner sends every build candidate to [cache_snapshot.py](../../tests/ci/cache_snapshot.py). A missing exact Linux x86_64 `compiled` snapshot receives a save key only after successful compaction; partial candidates from failed or cancelled compilation receive no key, because they lack an authoritative current output set. Other platforms and partitions retain their partial-save policy. Compaction may remove superseded native CLI output directories. The same-run producer receipt must describe successful main LLVM compilation of the full gate, with the three current production CLI products installed; unit, partial, failed, narrower and PR producers skip compaction. Current executable content, every manifest input and all unknown output classes are retained. Optional upgrade/PR CLI classes are retained in full unless their current version is installed too. Only the five named CLI layouts and their exact `_zcu.o` companion are eligible, and their proven local owning manifests are invalidated before removing outputs. Global objects, C libraries, generated sources, test binaries and packages are preserved. Unrecognized state declines this build publication, while verified compiler and other eligible cache saves continue.
With the mark, compaction keeps only the linked outputs the publisher's own compilation read, so PRs restore about one generation, not every revision main built. Setup marks each restored local manifest unread (a fixed 1970 access time) after restat and before compilation, but only on main's Linux `compiled` publisher, and only when a probe shows that reads move access times. Zig reads a manifest whenever its step checks for a hit. Publication reads the access times before anything else reads manifests. A directory holding only native executables or shared libraries, their `_zcu.o` objects and in-directory aliases is removed with its owners when every owner is local and unread and no manifest input references it. C objects, archives, generated sources, global objects, packages, unowned and unknown outputs stay. If the mark missed a current installed CLI, publication is declined. Without a usable mark, only the five-CLI rule above applies.
Zero-length h files are Zig's never-finalized cache misses. Compaction retains and reports them, excludes them from owner/input/output provenance, and checks that they remain unchanged during the audit. Complete zero-input manifests still decode normally; any nonempty malformed manifest skips the entire compaction.

Linux `compiled` uses a v4 publication key with v3/v2 restore fallback. The first v3 publisher safely skipped compaction on an unfinished manifest and saved an untrimmed immutable key; v4 allows the corrected policy to publish. Maintenance keeps legacy fallbacks until a complete v4 snapshot exists, then prefers v4 even if an older in-flight v3/v2 writer finishes later. Other platform and partition keys retain their versions. Maintenance logs deleted key/version identities and retained bytes per main cache group, so compiler-cache disappearance can be distinguished from scripted deletion.
The opt-in `cache_profile` workflow dispatch records the restored inventory and filesystem accesses, then compares the original and compacted main cache with unchanged and edited LLVM and PR producers. Each arm starts from the same main-only checkpoint and compares named compilation/cache statuses and verbose C/link invocations. It also streams before/after tar+zstd byte counts. Diagnostics disable publication; those profiles never enter main's saved LLVM snapshot. This experiment is compilation evidence, never test acceptance.
Package, previous-release and actionlint caches remain save-on-success, with the previous-release build and linter install required to finish first.
Shards configure and save the build runner after verified artifact restoration, before acceptance; tests still execute normally.
Cold acceptance still bypasses build, package and build-runner caches.
A [job timeout cancels the job](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idtimeout-minutes), and [cancellation forcibly terminates remaining work after five minutes](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation), so `always()` alone cannot guarantee an upload then.
New work-step deadlines exist only to reserve cache publication time: job budget minus a 25-minute cold-setup allowance minus a three-minute save reserve, and only when that limit covers the slowest sampled green step plus at least two minutes.
The allowance covers the observed 213-second setup (Selected run 43832831879) plus four further retry/request windows (200 + 90 seconds each); it is accounting, not a setup deadline or a measured bound on network tails.
The workflow comments and cache-maintenance regression record the observed durations and run IDs and check both the derivation and the margin.
Setup/fetch, cache uploads, linter installation, shard restore/rebuild and subsequent shard configuration have no new step deadline. Existing acceptance and bisect deadlines are unchanged.
Where the measured save window cannot fit, including short-budget unit/typecheck/proof/codegen jobs, compilation retains only its unchanged job deadline. Saves still run on step failure; on a job timeout they run only if GitHub allows them. Hard runner loss, forced cancellation or an upload failure can also prevent publication.
Partial Zig compilation caches are safe to restore: [Zig's content-addressed cache validates hashed inputs and manifests, treating incomplete manifests as misses](https://github.com/ziglang/zig/blob/0.17.1/lib/std/Build/Cache.zig).
That safety argument is source inspection, not a claim of native interrupted-build qualification; cached output never substitutes for test execution.

Linux x86_64 pull requests use `-Dpr-ci=true`: both `rui-pr-check` and the synthetic-release `rui-upgrade-release-fixture` are ReleaseSafe integration products built without LLVM through `product.addIntegrationRui`.
The upgrade fixture uses the same production sources with a synthetic release identity; its archive size and checksum are derived from the supplied binary.
In PR mode only, that fixture also strips debug data, matching shipped Linux archive packaging and avoiding unnecessary checksum and extraction work in native publication tests.
Promotion, release and default local builds retain Zig's default backend, as does the production binary used by `stack-frames`.

Each platform builds its target closure once with `ci-build -Dci-targets=...`.
Linux x86_64 producers use eight Zig async job slots so subprocess waits do not serialize independent compiles; this also applies to promotion's LLVM builds, while `-Dpr-ci` remains exclusive to pull requests.
Changes to the shared artifact producer select the full Linux build gate and Debug admission so PR CI exercises the artifacts its command emits; promotion retains native macOS coverage.
On Linux and macOS, when the selection compiles the single-threaded unit test binary alongside other gates, one producer builds only that binary (`-Dci-part=unit`) and another builds the rest (`-Dci-part=rest`); build.zig refuses a split whose selection never reaches the unit compile.
[build_artifact.py](../../tests/ci/build_artifact.py) transfers the executables and pinned package sources through immutable same-run artifacts that expire after one day.
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

A fixture that retains a failed root copies its `probe.log`, PTY gate metadata and native-observation failure metadata through [host_process.py](../../tests/integration/host_process.py), excluding private directories, symlinks and special files.
Each root reserves one of sixteen slots, holding at most eight files and one MiB, so concurrent fixtures stay within 128 files and sixteen MiB.
Uploads expire after three days.
Successful gates do not capture.
Native observation failure metadata is copied after reap and before temporary-root deletion.

[Cache maintenance](../../.github/workflows/cache-maintenance.yml) warms production compilation (`baseline`) and both split producer partitions (`compiled` and `compiled-unit`) on Linux and macOS after trusted main pushes that change build, dependency or maintenance inputs.
The producer warmers run the same `build_artifact.py build` command as Selected checks and Promote, using `rest` and `unit` respectively with the full promotion core (`check-full`, `test-logic`, `admission-debug-integration`, plus Linux `stack-frames`).
The new split warmers retain their 120-minute job budget and have a derived 92-minute compile step. No existing job budget increases: baseline stays at 30 minutes, runner maintenance at 15, previous release at 45, Linux unit/typecheck at 15, cache proof/codegen at 20, ordinary shards at 35 and Renderer contracts at 45. The existing 60-minute Linux and Mac producer safety nets remain. Only the measured, sufficiently long jobs receive derived work-step deadlines; no job budget changes to make space for saving.
A build partition restores its own newest snapshot, for the current dependencies first and then across a dependency repin; a partition with neither, such as one only pull requests run, starts from that baseline for the current dependencies, and no partition restores another's snapshot.
It also compiles the build runner on six Linux slots and one Mac, so test shards on the CPU models those slots drew restore it from main.
Cleanup keeps main's newest complete snapshot per platform and partition, per build-runner CPU model, of each platform's compiler and of the package set, and removes every PR cache; these are targets, not a quota. It separately keeps at most the newest partial compilation snapshot per platform/partition or runner CPU prefix, so a partial cannot evict the retained complete snapshot.
Warm compilation snapshots are not test acceptance. Cleanup waits for all maintenance publishers, including the previous-release warmer.
Maintenance also builds the pinned previous release per platform for the read-only upgrade check.
The API-only cleanup job runs trusted main code with cache-deletion permission and consumes no producer code, caches or artifacts.

CI uses standard `ubuntu-24.04` and Apple Silicon `macos-15` runners, plus `ubuntu-24.04-arm` for the Linux arm64 release build and the optional [self-hosted Mac runner](#self-hosted-mac-runner) for eligible Selected checks, including promotion's, with no paid host or storage expansion.
Free eligibility does not prove capacity; report the actual runner outcome and do not raise paid spend silently.
Apart from the shard rerun above and a [listed flake](#listed-flakes)'s rerun, test execution has no automatic retry.
Infrastructure failures are not test execution: [Retry infrastructure failures](../../.github/workflows/infra-retry.yml) reruns a PR run's or a Promote run's failed jobs once when every failure was infrastructure (no runner took or kept the job, or a step that only fetches, installs or starts services failed with a network error such as GitHub's 504) and the PR run still tests the PR's head, or no later Promote run was dispatched.
A build or test step's failure, a later attempt, any check failure in the run or a failed job routed to `rui-mac` (whose hook rejects the bot that triggers the rerun) never reruns, and a rerun job's tests had not run.
A promotion's rerun also reruns `qualified` and Release, so publication still requires every tier, and Release resumes an interrupted publication rather than publishing twice ([Release publication](release.md#release-publication)).

## Self-hosted Mac runner

Selected checks decides once per run, promotion included, whether to send `macos_build`, `macos_build_unit` and `macos_suites` to `["self-hosted", "macOS", "ARM64", "rui-mac"]`.
Only same-repository pull requests authored by DivyanshGolyan, with both actor and triggering actor allowlisted, and manual dispatches by those actors are eligible.
The allowlist lives in [mac_runner.py](../../tests/ci/mac_runner.py).
Fork PRs, including NimishGolyan/rui, stay hosted.
A promotion dispatched by an allowlisted actor routes by the same rule, so hosted macOS capacity no longer gates a release; its Mac suite jobs then share the one runner, and their measurements are not comparable with hosted VMs.
Compile-only main builds (which publish main's caches), the promotion's previous-release upgrade and cache-execution checks, and the Release builds (cold, released bytes) keep their hosted runners.
The routing job reads `GET /repos/{repo}/actions/runners` with the repository secret `MAC_RUNNER_STATUS_TOKEN`, a fine-grained PAT limited to this repository with Administration: read; Promote passes only that secret to its Selected checks call.
An online `rui-mac` selects the Mac when idle or when its queued jobs are fewer than hosted queued jobs plus one if at least five hosted jobs are running; ties select `macos-15`. If queue data is unavailable, only an idle Mac is selected; unavailable runner status, an offline runner or `RUI_MAC_RUNNER=off` selects hosted macOS.
This is a snapshot, not a reservation: after choosing the Mac, jobs queue for its one runner process; a later disconnect does not reroute that run.
The Mac restores caches but never publishes them to GitHub.
Compilation and build-runner cache keys include the actual native-tool identity (including Xcode and SDK); compiler/package caches have their existing platform/dependency keys.

An administrator signed into `gh` as DivyanshGolyan runs `bash tests/ci/mac-runner/install.sh` on the Apple Silicon Mac with full Xcode selected.
The script checks native fixture tools, warns about a readable admin home (`--lock-home` sets mode 700), enables approval for all external fork contributors, and installs one runner under hidden standard user `ruici` with a LaunchDaemon at lowered priority.
Rerunning repairs or updates the installation.
One root-owned registration record retains the installed name and remote ID across hostname changes and interrupted setup/removal; repair and uninstall check that identity against a fresh API snapshot.
Conflicting remote identities, missing credentials or damaged configuration preserve local recovery state; an old removal marker never authorizes deleting a new registration.
`bash tests/ci/mac-runner/install.sh status-token` opens GitHub's fine-grained-token form; select only this repository, then supply the token on stdin to store the status secret.
The root-owned job-started hook, installed `mac_runner.py` policy and generated allowlist live outside the runner application under the protected `ruici` home.
Routing and the hook call the same pure admission predicate; the hook executes the exact protected installed source bytes, avoiding checkout, package and bytecode shadowing.
Before any job step, the hook rejects another repository, event, actor, triggering actor, fork head or non-allowlisted PR author, independently of workflow routing.
A nonzero hook exit alone still permits workflow steps using `always()`; on any hook failure, its Bash exit trap kills its direct parent job worker so those steps cannot run.
This relies on the direct worker-child process relationship checked in `actions/runner` v2.338.2; a rejection can appear in GitHub as a crashed-worker failure.
Never run `job-started.sh` directly: a rejected invocation kills its calling process.
The process-supervision test runs in a disposable subprocess; installation and native Actions behavior still need verification on the Mac.
It deletes the global Zig cache before a job when that cache exceeds 40 GiB.
After admission it also stops every other `ruici` process outside its own runner ancestry and empties `ruici`'s TMPDIR, because only one job runs at a time and a hosted VM would have discarded both; a leftover `rui host serve` otherwise shows up in a later job's Host discovery.
The separate account isolates local files; it still executes trusted PR code on a personal Mac.

Pause scheduling with `gh variable set RUI_MAC_RUNNER --repo DivyanshGolyan/rui --body off` (unset it or set `on` to resume).
Stop the local service with `sudo launchctl bootout system /Library/LaunchDaemons/com.rui.actions-runner.plist`; bootstrap the same plist to resume it.
Run `bash tests/ci/mac-runner/uninstall.sh` as the signed-in administrator to stop the daemon, deregister the runner and delete `ruici` and its home.

## Listed flakes

[quarantine.json](../../tests/ci/quarantine.json) lists intermittent failures by their fixture-and-assertion signature, as [report_issue.py](../../tests/ci/report_issue.py) names them, with the file, an open `ci-red` issue, an owner and an expiry at most 14 days after the entry was added.
A listed test still runs and reports.
When every failure of a suite batch is a listed, unexpired signature, [run_selected.py](../../tests/ci/run_selected.py) reruns the batch once.
In PR admission a second failure that is again only listed signatures passes with a warning; promotion fails on it, so promotion blocks on two consecutive failures.
Any other failure in the batch, a failed step that names no listed fixture or an unparsed failure keeps it red, and a PR touching a [strict path](../../tests/ci/strict_paths.py) gets no quarantine.
Store, recovery and upgrade tests are never listed ([quarantine.py](../../tests/ci/quarantine.py) checks each entry, and `test_quarantine.py` runs in the policy job).
For a listed signature, and only for it, a fail-then-pass is green; every other fail-then-pass stays unexplained.
An expired entry blocks again: fix the race and remove the entry in the commit that says `Fixes #N`, or renew it in a reviewed PR with a new 14-day window.

## Product tenets

The [Review](../../CODING_STANDARDS.md#review) checks the change's completed caller flow against the following tenets.
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
  Use the [resource targets](../contracts/resources.md#resources-and-accepted-host-qualification-targets); stage checks do not replace qualification of the complete simultaneous workload or introduce per-module quotas.

Record these in the review's findings.
