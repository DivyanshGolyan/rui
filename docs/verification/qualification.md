# Native qualification and demonstrations

[Verification](../../VERIFICATION.md) owns shared evidence rules and the subsystem index.

## Hosted qualification

[Linux qualification](../../.github/workflows/qualify-linux.yml) runs full native gates in isolated jobs on demand, including credentials, measurement checks and long witnesses.
CI's only scheduled workflow is [Qualify main](release.md#qualify-main), which runs the promotion tier on `main`.
Full native and resource campaigns remain available through manual qualification on both platforms.
[report_issue.py](../../tests/ci/report_issue.py) remains an on-demand tool for recording failure signatures from full job logs.
A signature names the failing fixture and assertion, a Zig test, or a gate's own error.
A later green run alone does not prove a recurring defect fixed; retain the counterexample and name the fixing commit.
Manual qualification reports the requested SHA, not coverage of intermediate merges, and does not file issues automatically.
A failed, cancelled or skipped attempt is never a pass.

[On-demand Mac qualification](../../.github/workflows/qualify-macos.yml) resolves a requested ref once and runs existing targets on `macos-15` VMs: `gh workflow run qualify-macos.yml -f ref=<revision> -f suite=<suite>`.
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

[fetch_dependencies.sh](../../src/fetch_dependencies.sh) imports pinned native archives in save mode, verifies hashes against the unchanged manifest and fetches the complete graph.
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

## Measurement and release evidence

Measurement runners use Go 1.27.1 and modules pinned in `tests/qualification/go.mod` and `go.sum`; Go is measurement-only.
Before `zig build measure-*`, run `GOTOOLCHAIN=local go -C tests/qualification mod download`, then `zig build measurement-check`.
Record Go and gopsutil versions, `go.sum` and binary hashes, platform, Git revision and dirty state.
Measurement provenance reports a revision only when `git -C` resolves the measurement root as its top level; otherwise both fields are unavailable.

Release evidence includes deterministic Session, model, tool, permission, context, compaction and server fixtures; hard-termination recovery at each acknowledgement and effect boundary; compiler-backed discovery of both production graphs; and the opt-in live Codex repair through those owners.
Classify unused, conditional and test declarations and remove obsolete interfaces.
Never label interrupted or unrun checks passed.
## Platform qualification

Run affected behavior and process-crash recovery checks natively on Linux x86-64 before main and macOS Apple Silicon before stable promotion.
Run resource comparisons when the resource owner or claim changes.
Record actual architecture, toolchain, platform skips and unavailable counters.
OS-crash, power-loss and general sandbox guarantees are outside scope; keep exact internal limits and best-effort external runaway and cleanup tests.
A known incompatibility needs an explicit response, not a hidden fallback.
Verify the selected credential backend, access checks, account-preserving refresh and failed atomic save without plaintext fallback or credential inheritance.
Same-user authorized Bash can access credential files.
Installer and startup checks use disposable HOME and checkouts; personal installations, Stores and credentials are not fixtures.

For a fixture-created private temporary root, call `canonical_fixture_root` from [host_process.py](../../tests/integration/host_process.py) once, right after creation, before deriving Store, Workspace or HOME.
Use that root for Host and client arguments, wire identities and expected values: macOS `/var` and `/private/var` name one directory but differ under exact wire identity.
Keep intentional alias and security negatives raw, as in the [Conversation fixture](../../tests/integration/conversation_page_integration.py).

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

These rules define the workload behind the [Host targets](../contracts/resources.md#resources-and-accepted-host-qualification-targets):

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
## Release demonstrations

`upgrade-integration` builds `rui-upgrade-release-fixture` from the current production sources with a synthetic release version and the actual source revision.
Its focused `download` selector runs the terminal recovery case with a PATH-local curl fixture: successful attempts use real curl against the loopback release server, and a failed attempt injects an exit code without changing DNS settings.
The terminal recovery case activates the Settings Version row, waits at archive preparation, then checks native Host restart and unchanged credentials.
Deliberate PATH guidance retains the old terminal client. The case checks its success status, terminal restoration, and final installation receipt rather than assuming no other same-user Hosts exist.
The discovery cases keep one real curl 403 at release discovery, reported as `upgrade_download_failed` with curl's own last line.
`download_policy.zig` owns the rest at the Module level: curl's confined argument list for every request kind, fixture origin and address family (SH-70); one IPv4 retry only for exit 6 or 28 with the connection budget left, over every exit code, a signal and both families, and the attempt sequence of a whole run across discovery, checksums and archive, including IPv4 reuse within a run and normal selection on the next (SH-44); and the final diagnostic, which is only the last line of the last attempt (SH-71).
`upgrade_process.zig` native tests check a decreasing budget across attempts, no retry after a transfer deadline, and no child after cancellation or an expired deadline.

The historical Host-info profiles include wire 17, wire 16 (v0.72.0), wire 15 (v0.71.0) and wire 14 (v0.70.0), with all provider routes required. Parser, framing, discovery and exact-instance lifecycle tests exercise them alongside wires 13 and 9; ordinary readiness remains current-wire only.

Its `restart_all_cases` suite also runs alone with `python3 tests/integration/upgrade_integration.py REAL_RUI restart-all` as an isolated non-root user.
Two real retained managed builds serve separate Stores; `host restart --all` must replace both instances with the selected pinned executable and retire both old PIDs, preserve capacity/environment, then leave both current instances unchanged on retry.
The suite checks no-Host/no-start behavior, mandatory `--all`, refusal of per-Store selection, a live unreadable socket as an operational failure, a legacy stale refused socket without a Store hint as unconfirmed rather than an inferred absence, and an application-owned Host as an explained successful skip even without an installed target.
It also restarts a retained managed source Host onto a newly selected managed source build, verifies exact pinned process replacement and an already-current retry, and confirms Upgrade still refuses a selected source installation without changing the Host.
The lifecycle suite's `upgrade_journey` installs once over a managed Host, an application-owned Host and a live unreadable socket, starting a second managed Host on another Store while the archive is held: both managed instances/PIDs must change, the second through fresh post-publication discovery; the application-owned Host must remain with its reason; the pre-install warning must name the Stores found then; the socket must contribute a failed result and `host_restart_failed` exit 6 without rolling back the binary; and a second run must find both Hosts current without downloading.
The SH-75 run-ending table crosses release ordering, installed/unchanged publication and Host summaries; every ending uses the receipt target. `upgrade_status.zig` owns the corresponding status bar, Settings and relaunch text. Preparation remains version-neutral, and cancellation/discovery/transport failures cannot substitute the candidate. Installation owner tests assert the no-downgrade winner's receipt version and retain it after its executable disappears.
`upgrade_run.zig` owns the order and route of one Upgrade run and its CLI exit class over every world of observation, preparation, publication and restart failures (SH-37, SH-72 to SH-74); `upgrade.check`, `upgrade.install` and `rui upgrade` apply the effects it names. The upgrade report embeds the shared restart-all report exactly and adds its rollback note only with guidance.
`host_activation.zig` decides whether a running Host is restartable (SH-49: every observation in order, the first failing one naming the limitation, so an unknown managed build or a retained managed source Host needs no install to witness), each check before the stop and every outcome after it (SH-24, SH-81), and when a replacement is proven ready (SH-80); `HostLifecycle` only reads and applies what it names. It also owns how every outcome counts, whether it leaves guidance and whether it keeps the client safe, folded over a batch with the client's own Store, other Stores, unlocated entries and batch failures (SH-60); `host_restart_all` and `upgrade` read those answers.
`host_restart_all` native unit tests cover every activation outcome (including a verified pinned launch with an incompatible client, counted as restarted with selected-client advice rather than readiness), every limitation and every failed/unconfirmed stage; platform/client tests cover runtime filtering and missing directories.
The discovery boundary covers missing socket paths, stale refused sockets without hints, live saturated backlogs (immediate refusal on Darwin, pending on Linux) and connected unreadable peers; none grants absence authority without a verified Store lease observation.
`Host information` decoder unit tests cover current and pre-ChatGPT same-wire replies, every explicit provider route, absent `chatgpt` as `unserved`, required older fields and malformed/unknown/duplicate fields; released wire-9 facts retain their strict profile.
Additional platform/client cases distinguish a refused socket with its Store lock held from a stale socket with its Store lock free, reject a mismatched hint and verify private publication and clean hint retirement.
The native restart-all suite explicitly crashes a real Host before its empty-runtime assertion: discovery must silently skip that free-lease socket, retain it without deletion and start nothing. This also covers stale sockets left by earlier lifecycle cases.
Both installer suites record the exact newly selected command's restart-all invocation, retain its output and require exit zero after a failed restart handoff.
`tool_custody_cases` runs that same restart CLI inside a real Host Bash tool with the originating Host first in socket order, crossing an exec'd process-group leader / retained installer shell with open / already-broken stdout.
Both Stores must retire their old native PIDs, become ready on the selected pinned executable and preserve capacity/environment; complete ordered restart receipts must survive through stderr diagnostics after the caller's output closes.
It also exercises CLI Upgrade from the retained installer shell (the restart rows cover both process shapes of the same coordinator), replacing both Stores and retaining the complete ordered batch receipt after the first restart closes the caller/event pipe. Upgrade's pre-publication warning still requires a report reader.
The focused `custody` selector runs these cases; `restart-all` and `lifecycle` include their respective custody rows.
Coordinator native tests round-trip every progress stage and ActivationOutcome (all limitations and failure stages), batch routing, pinned targets and per-Store discovery failures; the broken-pipe reporting test counts every outcome without requiring a report reader.
The existing terminal selector exercises inline UpgradeJob through the same activation owner, including post-publication departure, cancellation guidance and relaunch.

Only the fixture's build identity differs; installation eligibility, publication, Host lifecycle and terminal code are the production owners.
Ordinary untagged builds still report `unreleased`.
`zig build upgrade-fixture` exposes that same native actor for focused terminal evidence without a network download or a stale tagged binary.

`installer-integration` runs source and release installer cases with the compiled production executable supplied by the build graph.
Their staged test commands delegate publication and PATH facts to that executable, never to a second writer or an on-demand compiler.
The compiler-free policy suite retains release planning and template checks; its boundary regression runs those checks with no Zig on PATH and confirms every native case receives an explicit publisher.

Package under the Rui identity and verify executable and package names, state and credential identifiers, build and distribution references, and fixtures.
Fixture recreation under the [Store format policy](../contracts/store.md#store-format-and-upgrades) does not authorize changing user Stores; state packaging, state-path and credential-identifier obligations explicitly before release.

Release demonstrations cover explicit start, no-client progress, restart, direct Sessions, first configuration, permissions, ordered tools, uncertain Bash and Edit, and shared cancellation.
Independent native or Cloudflare walkthroughs add no embedding or cloud release requirement.
Keep evidence attached to the real owners and label remaining gaps before claiming release readiness.
