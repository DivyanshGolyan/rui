# Post-main complecting/design review: cad75f79 against 0392b87a

Reviewer thread: https://ampcode.com/threads/T-01a16270-2112-737f-80d6-a6efb06c55ce (Claude Opus 5.5, read-only).
Scope: 73a8e9db (tool-turn harness, tree identical to 14c2f1ed) and cad75f79 (main/stable split).
Nonblocking post-landing review. It does not gate landing or the next item.

## Verdict

No safety false pass found. Main lands on Linux only, stable promotion is monotonic, and stable moves only on exact-SHA Mac and upgrade evidence. The split holds these properties in code and in the bare-Git test. Three findings are about liveness, cost and latent coupling, plus one latent coupling in the harness.

## Findings

F1 (medium, liveness): qualification dispatch has no recovery, and the manual path is undocumented.
- `land()` pushes main and then calls `qualify_main()`. If either `gh workflow run` call fails, or the job dies between the push and the dispatch, the next Auto-land run returns early with "already in main" (`main()` at `contains(main_sha, sha)`). Nothing then re-dispatches for that main tip. Stable stays put until the next landing or a manual `auto_land.py --qualify-main`.
- Manual bootstrap pushes of workflow-file tips (the `manual` verdict) never wake Auto-land: main has no push trigger. These tips always need a hand-run dispatch. That is what happened for cad75f79: runs 39735705307 and 39735709182 are `workflow_dispatch` by DivyanshGolyan, not Auto-land.
- `--qualify-main` appears only in auto_land.py. AGENTS.md says such tips "require an explicitly authorized agent or user bootstrap" but does not say to dispatch qualification afterward.
- Consequence: stable stalls silently and stays safe. Smallest fix: in `promote_stable`, dispatch `qualify_main` once if the current main tip has no stable-titled Selected run or no upgrade run. Alternatively, document `--qualify-main` as a step of the bootstrap procedure.
- Not yet exercised in production: the automatic GITHUB_TOKEN path, land → dispatch → workflow_run → promote. cad75f79 was bootstrapped by hand. Per GitHub docs the dispatch path should work: GITHUB_TOKEN `workflow_dispatch` creates runs, and the chain stays within the workflow_run depth limit. The first automatic landing is its real proof.

F2 (low-medium, cost regression on PRs): the upgrade concurrency group now includes `github.sha` for every event.
- `previous-release-upgrade-${{ github.ref }}-${{ github.sha }}` with `cancel-in-progress: true` gives each PR push a new group. Superseded strict-path PR upgrade runs, each with a macOS job of up to 45 minutes, are therefore no longer cancelled.
- Only stable dispatches needed per-SHA groups. Fix: `${{ github.event_name == 'workflow_dispatch' && github.sha || '' }}`, matching check.yml's `inputs.stable` scoping.

F3 (low, unused authority): the stable base is parsed but never checked.
- `STABLE_BASE` captures the base, but `stable_ready` checks only the title. A stable dispatch whose base is the candidate itself, for example `gh workflow run check.yml -f base=<main sha> -f stable=true`, qualifies with only the forced `check` and `admission-debug-integration`, dropping additional mapped Mac targets. Probe: `stable_ready` returned True for base==candidate.
- Only write-access dispatchers can do this, and the forced floor still runs. Fix: require `contains(stable_sha, base)` in `promote_stable`, or drop the capture group.

F4 (cost note, design tradeoff): every landing starts a full Mac `check` plus full Debug admission and both upgrade platforms, and per-SHA groups never cancel. At the measured cad75f79 duration (about 19 minutes of Mac Selected wall time plus about 13 minutes of upgrade time), runs for older candidates keep consuming Mac minutes after a newer candidate is queued. This follows the accepted "newest passing" rule. Batching or cancelling non-newest candidates is a policy choice, not a defect.

H1 (low, latent false-pass coupling, harness): `toolAcceptance` keys barrier acceptance on whether `release` is non-nil, not on the configured `barrier` mode.
- Today a barrier run always records `barrier_release` or returns early as incomplete, so there is no current false pass.
- `TestToolAcceptanceFailsClosed` asserts that a nil release with overlap 1 passes. So if a later change stops recording or renames `barrier_release`, a barrier run would pass without the parked==N or overlap==N checks.
- Fix: pass `barrier bool` and require release facts when it is true.

## Checked without findings
- decide(): Linux aggregate only; pending on missing aggregate; red on failure/cancelled/skipped; covers() still enforced for dispatches; workflow-file tips go manual.
- promote_stable(): stable must be an ancestor of main; first-parent newest-first scan; exact head_sha+branch=main; stable-titled run, overall success, macos aggregate success, upgrade success; non-force push; replay is a no-op; descendants never borrow ancestor evidence.
- check.yml stable mode: asserts ref main; forces Mac check + admission-debug; retry off; Linux targets empty (Linux acceptance was on the same SHA via wip/land); per-SHA concurrency only for stable; preflight skipped on main only.
- Single-stack/ref serialization unchanged: preflight unchanged; both writers inside one non-cancelling `auto-land` group; manual bootstrap pushes are outside that group but non-force pushes and `moved()` handle the race.
- Harness acceptance layering (provider validateOutputs for exact issued calls and markers; toolAcceptance for counts, window and barrier; toolOriginalFailure for Host results and exact answers) has distinct fact sources rather than duplicated authority. The count checks partly duplicate provider Errors, which is redundant but fail-closed.
- PSS coverage is reported, not gated. "status: passed" means turn correctness only; consumers must read sample_coverage and limits. Historical measurements are not current acceptance.

## Evidence
- `python3 -B -m unittest discover -s tests/ci -p test_landing.py`: 11 tests OK (2.06s).
- `GOTOOLCHAIN=local go -C tests/qualification test -count=1 ./model-output/provider`: ok 6.41s; `-run 'Tool|Barrier' ./model-output`: ok 0.11s (no -race, bounded).
- Hosted runs read via gh API: 39735188096 (push wip/land-21, success), 39735705307 (workflow_dispatch by user, "Stable qualification from base 0392b87a", macos suites (native) success), 39735709182 (dispatch by user, success), 39737791497 (Auto-land workflow_run on main, success). main == stable == cad75f79 at review time.

## Limits
- Source and unit review only; no hosted runs, Mac execution, campaigns or runtime launches.
- Did not open the prior Sol tarball (.amp/tool-turn-sol-review.tar.gz) or re-derive the 58/60 audit or the 11 mutation controls.
- Fork/fd/signal behavior of the harness is source-limited; GitHub chain-depth and GITHUB_TOKEN dispatch behavior come from docs, not observation.
