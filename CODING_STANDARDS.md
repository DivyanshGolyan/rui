# Rui coding standards

Load sections through [AGENTS.md](AGENTS.md#before-work).
These standards own engineering methods, not runtime behavior or qualification requirements.

## Contract maintenance

Each requirement has one home.
[Architecture](ARCHITECTURE.md) owns shared guarantees, terminology, and the source map.
The accepted-contract sections in its linked subsystem references own behavior, decisions, and rationale.
[Verification](VERIFICATION.md) owns global evidence rules and gates; the required-evidence sections in its linked subsystem references own the cases.
GitHub issues hold unresolved decisions and research.
Implementation slices link accepted contracts and define proof.
A Store format change appends one version, bootstrap digest row and forward step for each dialect; main's existing rows and every released step remain immutable (an unreleased step whose text cannot run may be repaired in place without asking), and `python3 tests/ci/schema_number.py --check` confirms the number against current main. The Store keeps no wire label (format 74), so a wire bump is no Store format change.
A MySQL migration step must not search `information_schema.CHECK_CONSTRAINTS.CHECK_CLAUSE` for a needle with a single or double quote character (a backtick-quoted column name is fine): MySQL 8.4 stores each literal with a charset introducer and escapes its quotes, so the search never matches, the step's DDL is NULL and PREPARE fails with 1064. Match a bare identifier that only the target CHECK contains, as format 94 does with `LOCATE('loaded_tools',cc.CHECK_CLAUSE)`. `check_clause_lint` in [release_numbers.py](tests/ci/release_numbers.py) enforces this in the policy suite, because PR CI runs SQLite only.
The [wire-version gate](tests/ci/test_wire_version.py) requires a version greater than the newest release's when generated `openapi.json` changes beyond `info.version` and documentation-only annotations, under the [wire contract rule](docs/contracts/session-ui.md#staged-persistent-input).

Edit the owning contract or required-evidence section only when a change alters user-visible behavior, the Store format, or a gate.
An organization-only move preserves every requirement and migrates its references and enforcement consumers together.
Accepted behavior changes only by the user's decision: when an implementation departs from it, raise the conflict and change the code or ask, keeping the contract text as accepted.
Then edit the owning section and affected verification cases; keep rationale beside the contract.
Identify conflicts with accepted behavior explicitly.
Replace superseded text rather than creating parallel ADRs, proposals, glossaries, summaries or amendment ledgers.
Keep [Research](research/README.md) a compact index of reproducible evidence.
Write for the document's audience and purpose, with coherent paragraphs that reduce reader effort.
Source line breaks are separate from sentence length and paragraph structure.
For cleaner diffs, optionally use `python3 tests/ci/sentence_lines.py [paths ...]` to put sentences on separate source lines without changing rendering.
Its `--check` mode is opt-in; sentence-per-line layout is not a merge requirement.

## Contract enforcement

Each listed contract has one owning enforcement; change the owner and its check together.

| Contract | Owning enforcement | Existing local and CI checks |
| --- | --- | --- |
| [Mutation presentation and admission truth](docs/contracts/cli.md#public-operations) | `cli.writeMutationReply` owns quiet Configure success and contextual errors through `MutationPresentation`. Configure records admission before output and always invokes that renderer. | `human_cli_integration.py` checks quiet success; `canonical_failure_integration.py` checks original context, binding/null failures and no resend. Both run in `check`. |
| [Original result and release deadlines](docs/contracts/resources.md#transport) | `model_fixture.wait_for_result_release` requires a deadline. Population callers create one deadline before their first result wait and forward it through all reads and global release. | `transport_h2_integration_test.py` drives shared, managed and seven population caller clocks; `host_process_test.py` drives the stop-receipt caller. Both run through existing build targets. |
| [Required native receipts](docs/contracts/diagnostics.md#shared-optional-stderr) | `start_ready_process` selects native capture and crash-cut plans and external failure retention before launch. `HostDiagnostics` rejects optional authority for named required phases. | `host_process_test.py` rejects missing, duplicate, lost and optional-only receipts and verifies retention after root teardown; `check` runs it. |
| [Receipt versus publication retirement](docs/contracts/diagnostics.md#native-owner-observations) | `crash_host` requires unsealed publication retirement within its original crash/reap budget. Ordinary teardown uses sealed `stop_process`; immutable final validity remains mandatory. | `host_process_test.py` holds delivered custody and injects a future writer through the actual crash caller; existing native publication holds remain in `check`. |
| [No-launch crash cut](docs/contracts/diagnostics.md#native-owner-observations) | The existing opt-in prepared transition blocks before launch authority. `ReleaseGate.assert_held` requires the owned empty FIFO, independently of marker absence and observation retirement. | Native Bash integration retains the gated prelaunch crash and recovery; `host_process_test.py` rejects released, credited and replaced gates and verifies unlink-failure closure. |
| [Canonical fault fencing](docs/contracts/store.md#canonical-state-and-transactions) | `enter` and `Access.finish`/`finishTransaction` in `src/store/Store.zig` own every locked Store entry point. Each declares the ordinary errors its body returns, checked at compile time; every other error from the body fences the Store before it returns. | `src/store/tests/` pins locking, fencing and classifier return to that owner and fences injected SQLite step faults on six entry points; `canonical_failure_integration.py` checks that a Host read fault fences instead of returning `result_not_found`. Both run in `check`. |
| [Stable installation and activation](docs/contracts/store.md#store-format-and-upgrades) | `Installation` alone publishes complete managed builds; the local upgrade coordinator composes separate publication and exact-instance Host lifecycle outcomes. Shell installers share the native publication and PATH owners, then invoke the sequential restart-all coordinator, which reuses HostLifecycle rather than owning launch or exact-stop policy. | `upgrade-integration` exercises real CLI, both PTY/tmux screens, cancellation and exact pinned activation; focused native owner tests and both installer suites check final eligibility, ordering and reporting; restart-all cases cover two Stores, already-current Hosts, stale/unreadable sockets and explained application-owned skips. |
| [Shared Session rules](CODING_STANDARDS.md#ownership-and-transitions) | `tests/ci/client_locality.py` scans client production sources for named Host rules; its existing exceptions carry their removal issues and only shrink against trusted `origin/main`. | `test_client_locality.py` tests the scan and ratchet; prepush and CI policy run the gate. |
| [Caller diagnostics](docs/contracts/cli.md#help-and-prerequisites) | `caller_error.of`, its catalog and invocation-owned witnesses classify CLI failures; `tests/ci/caller_errors.py` inventories CLI-owned production errors and ratchets pending causes against the same scoped trusted-main inventory. | `test_caller_errors.py` rejects pending growth, raw caller error names and unmapped errors in CLI-owned sources, without catalog coupling to Host-internal owners; prepush and CI policy run the gate. |
| Per-agent Host memory | `tests/ci/host_memory.py` owns `PER_AGENT_BUDGET` and its verdict over one Host's 100 -> 1,000 waiting-agent Private_Dirty slope, measured on the release archive | `host-memory` runs in Promote's qualification tier only (the `memory` job), never on a PR; `test_host_memory.py` tests the verdict and the table in the policy job. |
| [Primary failure and mandatory disposal](CODING_STANDARDS.md#evidence) | Shared process, held-endpoint, Control and Bash disposal owners attempt every cleanup and keep the original failure primary. | `host_process_test.py` injects disposal and retention failures; `transport_h2_integration_test.py` drives body/cleanup fault pairs and successful-body cleanup failure. Existing build targets run both. |

## Engineering

Ground design in concrete caller behavior.
Before work from a design, mock or multi-PR plan starts, map every requirement, every "reuse X" and every element of the referenced design to a PR or task, or to a "left out" list the user sees before approving.
When the user drops a requirement, list every planned or merged piece that only it justified, and propose deleting each one before building more.
Keep independent concerns independent; familiarity and line/module counts do not establish simplicity.
Obtain independent opinions on material design questions.

### Goal

Every PR body has a visible goal line naming an issue by number or full GitHub issue URL, with at least three explanation words.
Use `Fixes #123 <how this change finishes the issue>` when merging the PR completes the issue, so GitHub closes it on merge; nobody closes it by hand afterwards.
Use `Goal: #123 <how this change serves the issue>` for an issue that stays open, such as a workstream, a parent or a multi-PR issue.
A PR can carry both, and one line per finished issue.
For housekeeping, red-main reverts, model trials or similar work without an issue, use `No issue: <reason>` instead.
The plan checks the text, not whether the issue exists.
[PR labels](.github/workflows/pr-labels.yml) gives the PR the workstream label (`TUI`, `Host parity`, `CI`, ...) of its goal-line issue or that issue's nearest labelled parent, so file new work under its workstream issue, and label a new workstream issue when it is created.

### Shape before code

Before writing code for a change to `src/`, show the changed structure in a fenced diagram, diff-sketch or tree in the PR's `## Summary`.
The plan checks for a nonempty closed sketch in Summary; review answers the applicable questions below, not a repeated section template:

- **[Values in](#ownership-and-transitions).** The value each user action or worker result arrives as.
  An input carries what the user saw (the drawn row, list or frame), never state re-read later.
- **[Who decides](#ownership-and-transitions).** The core `step` or transition function that makes each decision; shell code only applies the effects it returns.
- **[Owner reused](#review).** For each behavior that already exists (joining a reader, reporting a failure, editor recovery, a choice), the function the change calls.
  A second path doing an existing job is a finding.
- **[Facts derived](#ownership-and-transitions).** For each new flag, marker or counter, the committed fact it is derived from instead.
- **[Outcomes whole](#review).** Each result type crossing a boundary and the one function that settles it on completion, cancel and departure; no field is dropped on the way.

When a review finding falls under one of these, the fix names it and corrects every site in the change before the next push.

### Ownership and transitions

Keep state, validation and transitions with their owner.
Express lifecycle decisions as compact value transitions testable without OS effects; keep handles, storage, processes and accounting in a thin imperative owner preserving atomic checks and resource lifetimes.
Test transitions exhaustively through the owner interface, then verify adapters and handoffs with focused native integrations.
A documented any/every/never rule is tested over its whole domain (every key and encoding, draft state and width in range), with expected outcomes taken from an independent source such as the base commit's behavior, never from the table under test.
A functional core takes the values its shell read (a record under its lock, rows inside the transaction, the current time) and returns the decision or action the shell applies; it keeps no copy of a fact another owner holds.
List each core in `src/logic_tests.zig` so `test-logic` checks its boundary.

A rule every viewer of a Session must agree on is decided by the Host and served to clients; a client sends intents and draws served state. New terminal UI interaction logic, such as selection, folding, order hold and drafts, is a step function over plain values with no terminal cells, widths or key codes in its inputs or outputs, listed in `src/logic_tests.zig`.

Expose semantic intent and opaque, pointer-stable handles rather than storage rows, internal lifecycle state or generic command buses.
Use closed typed variants for different authorities.
Do not copy or abstract resource handles merely to make code functional.

Reuse an existing owner whole.
A new surface that does the same job as an existing component calls that component; when a boundary keeps a core from importing it, the shell owns the component and passes its outcomes in.

Before correcting a failure, identify its owner, invariant and earliest violating transition.
Correct that transition or replace the owning model, not a downstream observer.
For a bug, that owner answers why the bug was possible: a rule with two owners, a rule applied beyond its case, a check only one path runs, a caller that must know a policy or a call order, or a test that pinned the broken promise ([Bugs refine the catalog](docs/verification/testing.md#bugs-refine-the-catalog)).
The bug fix's `## Summary` states it in a `Why possible:` line and how the fix removes that class.
Only a root fix that needs a user decision under [Authority](AGENTS.md#authority) (a contract or behavior change, or wider scope) may land after the instance fix, as a linked issue under the same workstream.
From the first review finding, name its class, sweep the change for siblings and correct the structure that allows the class, so one round closes it.
When another correction touches the same lifecycle, redraw states, authorities, handoffs and release conditions.
Prefer replacing superseded state over additional flags, retries, test hooks or timing allowances.
A cache, memo or "already shown" check keys on every input that changes its value (revision, caret, source, the commit a run tested); a result computed from an older input is dropped, never applied over a newer one.
Every refused or rejected state a user can reach (an editor overflow, a failed sign-in, a closed pane's focus) has a tested way out.

Respect architectural transaction/effect boundaries.
Check every precondition before the first step that cannot be undone (stopping a Host, deleting a credential, marking work pending); a check that runs after it can only report damage.
Independent targets (two logins, several Hosts or Stores) succeed or fail independently, and each reports its own outcome.
Give each mutable handle one owner.
Construct callback state in final storage before registration; retain its address and custody through safe cleanup.
Validate external syntax and consequential meaning.
Notifications are hints; committed facts are authority.
Trust validated local/SQLite facts within their documented boundary.

### Resources and cleanup

Every allocation/resource needs an owner, population multiplier, bound, failure behavior and release point.
Stream variable content without duplicating complete payloads.
Derive limits from consumers; retain guards until replacement storage is verified.
Never silently truncate semantic input.
Separate orchestration from workload memory; account for shared budgets and justify independent pools against aggregate demand and isolation needs.

Make allocator dependencies explicit at allocation sites.
Document returned pointers/slices as owned or borrowed, including invalidation.
Use `defer`/`errdefer` at scope-bound release; transferred/asynchronous resources remain owned until cleanup is safe.

Cleanup is an owner transition: reclamation must be retry-safe, distinguish confirmed absence from unconfirmed removal, retain actionable resources after failure, and release custody and accounting exactly once after success.

### Zig and errors

Follow the [Zig 0.17.1 style guide](https://ziglang.org/documentation/0.17.1/#Style-Guide) and installed standard-library APIs: `TitleCase` for types/type-producing functions and files with top-level instance fields, `camelCase` for other functions, `snake_case` for values and namespace files.
Name declarations in their full namespace without redundant prefixes or miscellaneous utility buckets.
Keep helpers with their consumer until a shared responsibility warrants extraction.

Assert programmer errors; return typed expected failures.
Handle errors and explain intentionally ignored cleanup failures at their shared wrapper.
Put exceptions beside their owning code or contract, with consumer, retained guarantee and evidence.

### Performance

Use [Abseil Performance Hints](https://abseil.io/fast/hints.html) when implementing or reviewing performance.
Estimate repeated work, copies and allocation multipliers before adding complexity.
Keep optimizations behind owning interfaces; measure representative end-to-end gains while preserving clarity, pointer stability, asynchronous lifetimes and the accepted contract.

Before changing the build graph or enabling experimental incremental compilation for speed, measure comparable edit-rebuild cycles with `--summary all`; preserve non-incremental, empty-cache evidence where required.
Consult [build-latency research](research/build-times-sources.md) for measured costs and Zig 0.16 caveats.
Gate cadence remains in Verification.

#### Host stacks

A Host thread keeps its stack's high-water pages for its life, and ReleaseSafe probes every page of a frame on entry.
On Host threads:

- A value larger than 1 KiB has one address.
  Its owner passes `*T` and the producer fills it; it is never returned or copied by value.
  A big type initializes in place with `fn init(self: *T, ...)`.
- A frame holds at most 8 KiB.
  Larger storage belongs to the owner of the work: the exchange's heap objects for per-request work, the engine `Workspace` for recurring engine work, and `pages.Mapped` ([os/pages.zig](src/os/pages.zig)) for rare per-call work.
- An explicit `= undefined` in a struct literal writes 0xAA over those bytes in ReleaseSafe.
  Declare a field an initializer leaves unset `= undefined` in the type and leave it out of the literal.
- A literal that names a field stores field by field and skips fields whose default is `undefined`.
  An empty `.{}`, a field's default value, `null` and a payload-free union tag store every byte of the type.
  Name a big field's small parts instead, as in `.{ .workspace = .{ .len = 0 } }`.
- Rare work with scratch of its own (a trace, a diagnostic line, an error envelope, startup) is a `noinline` function, so the scratch stays off its caller's frame.

Review enforces these rules; the Host's fixed stack cost shows in the Empty Host row of each release's memory table.

## Review

Codex is the code review; request `@codex review for duplicated authority and braided concerns, and against the PR's Summary shape and against the linked issue's goal; group symptoms by owner` when production or operational changes invalidate the previous review.
[Landing](docs/agents/landing.md#publish-and-merge) owns draft-first publication, clean review evidence and its reuse exceptions.
The [Code Review Rules](AGENTS.md#code-review-rules) own how it groups and orders its findings; the rules it applies stay here.
The author's own reviews are design reviews of the approved design, and a redesign when fixes keep producing new findings.
Reviewers apply the rules below and the [product tenets](docs/verification/gates.md#product-tenets).
The author fixes each finding at its class ([Ownership and transitions](#ownership-and-transitions)), or records in the PR why it stays.
A person's signoff does not gate landing a green change with a clean review ([Landing](AGENTS.md#landing), [Review evidence](docs/agents/landing.md#review-evidence)).

Review parity and failure paths as well as the diff:

- **Intent.** Read the PR Goal and linked issue before the diff; identify drift from the issue, a wrong approach to its goal, and symptom patches where redesign of an earlier finding fits.
- **Parity.** List what the change re-implements, replaces or drops: each sibling component, previous version and contract line it touches.
  Confirm each keeps its behavior.
  A second implementation of a behavior an existing component owns is a finding.
- **Discarded failures.** List every error a secondary path (after commit, on cancel or return, in a worker, during setup or teardown, a catch-all switch arm) discards, turns into `null` or treats as unreachable.
  Route each to the main path's failure boundary, or justify it beside the code.
- **In-flight effects.** Each effect the change emits has one record from emission to a definite answer.
  On every exit (return, error, cancel), the owner reports each still-open record to the caller's failure boundary.
- **Consumers.** When the change alters a shared value (a label, status text, column, step list, exit convention or file list), search for the old form. A test or fixture that restates it reads it from its owner instead ([Evidence](#evidence)); a consumer that cannot (a skill, helper script or document) changes in the same change.
- **Runnable instructions.** A command in a skill, doc or script runs as written on the platforms it names: required inputs are supplied, nothing depends on one machine's paths or permissions, and a step that needs a person (such as a hardware check at the Mac) says so.
- **Tests.** A change to production logic moves the touched owners' tests onto the [test requirements](docs/verification/testing.md#migration): catalog rows for the owners' promises, one owner test per invariant at the lowest level that observes it, and the replaced legacy tests deleted. A new test that names no invariant, checks internals, waits on time or replays one bug is a finding.
- **Design.** Check the change against the approved design, not only the issue derived from it.
  An edit to a contract document that makes it match the change's own code is a finding, and so is a "by design" that cites text the same change added.

Trace beyond changed lines to owning state/control flow and existing causes of workarounds.
Identify duplicated authority, scattered policy and dependencies on private representation, call order or cleanup details; connect findings to the change.
Justify affected state, layers, caches, queues and per-slot allocations by required behavior or demonstrated cost.

Validate findings against the contract and owner.
For each actionable finding, give code/location, scenario, consequence, correction, removable machinery, preserved guarantees and behavior/memory verification. **Simplify first:** lead the correction with the simpler design that removes the finding's whole class ([Ownership and transitions](#ownership-and-transitions)), such as deleting a copy, deriving a fact instead of syncing it, or giving a rule one owner; offer the smallest complete patch only when no such design exists, and say why.
Simple means unbraided, as in Rich Hickey's "Simple Made Easy": independent concerns kept independent, whatever the line count.
Quantify relevant memory multipliers; distinguish estimates from measurements.
Prefer simplicity, explainability and memory efficiency over implementation speed.
Keep unrelated cleanup separate; exclude personal style, speculative extensibility and gate-enforced formatting.

## Evidence

Use [canonical gates](docs/verification/gates.md#canonical-gates) for required commands, focused checks, cache conditions and assembled-versus-independently-merged cadence; confirm commands in `build.zig`.
This section owns the local feedback policy; [landing](docs/agents/landing.md#publish-and-merge) owns publication and merge gates.

Use `python3 tests/ci/prepush.py` for cheap changed-file feedback before first publication and after changes invalidate that feedback.
Its default and installed hook (`--quick`) check committed whitespace, changed Zig formatting and AST, changed Python undefined names, relevant generation and schema numbering, and focused owner-policy tests.
Before the next push, the hook also re-runs the last completed CI red's failing tests on the branch's current remote head.
Checks that need hosted facilities are printed as skipped, never passed.
When a changed path is a functional core registered in `src/logic_tests.zig`, default and `--quick` also run only the core-boundary test through `test-logic-only` with its name filter.
Shared or unmapped policy inputs leave broad policy tests to CI.
Use `--plan` to inspect commands; selection uses the committed diff against the merge base, while commands read working-tree contents.
Commit corrected whitespace and generated artifacts before publishing.
Deleted inputs still select their owner checks.
A receipt records the tree, merge base, mode and each command's exit or explicit CI deferral.
Dirty trees, failed commands and deferred-only runs cover no push.
When no receipt covers a push, the hook refuses a pushed commit other than the checkout's HEAD; push from the checkout or worktree that has it checked out.
A matching receipt reuses local feedback only; it never establishes hosted acceptance or turns a deferred obligation into a pass.
The hook prints outstanding CI deferrals even when feedback is cached.
Install it with `python3 tests/ci/prepush.py --install-hook` when setup has not installed it.

Run the smallest behavioral tests relevant to the changed owners.
For a high-risk regression, use a targeted negative control when it establishes that the test detects the defect; strict-path regressions retain the intended-assertion requirement below.
Reuse focused test, runtime, negative-control and independent review evidence when its relevant owner, oracle, inputs and integration context are unchanged.
Record the evidence's revision or tree and explain relevant changes since it ran.
Rerun evidence invalidated by semantic changes or the final integration of changed paths, not by a commit, push or review round alone.
A new TUI interaction still needs the independent plain-PTY journey in [landing](docs/agents/landing.md#publish-and-merge); compilation and CI do not demonstrate it.

Ready CI owns selected broad unit and integration tests, Mac checks, live engines, migrations and premerge all-unit compilation obligations ([canonical gates](docs/verification/gates.md#canonical-gates)).
`python3 tests/ci/prepush.py --full` remains an opt-in diagnostic, not a publication toll.
It adds the CI policy suite with the same unchanged-input self-check skips, development targets, Mac typechecking, unfiltered unit compilation and selected reachable local MySQL checks.
UID-global Upgrade remains hosted on an ordinary runner; local output records it as deferred, never passed.
Use a full composed suite (`zig build test`, `check`, the review-phase selection or a local mirror of CI) only to diagnose a CI red.
In Claude Code, `.claude/hooks/block_full_runs.py` requires `RUI_CI_RED=<run or issue>` for those commands.
Live provider checks remain opt-in.

Test meaningful failures and recovery against independent expectations.
Drive fault injection through production transitions.
Unit tests may inspect owner internals; integration and qualification must assert durable owner-boundary outcomes rather than timing, scheduler order, private representation or fixture-only authority.
A concurrent test peer records what it observed before it replies or exits, so cancelling or joining it once the code under test returns cannot change the result; check this by temporarily delaying each peer read, reply and exit.
Order test actors with a gate or event, never a sleep.
Tests wait for a condition only through `wait_for` in `tests/integration/host_process.py` or `waitUntil` in `src/testing/poll.zig`, which accept only a check that finishes before the deadline; `tests/ci/flake_sources.py` counts every other sleep in a fixture, a Zig `test` block or a test-only Zig file against a shrink-only allowlist.

Shared fixture owners hold the I/O and platform cases that broke fixtures before, and `tests/ci` lints name the owner when a fixture bypasses one: Store fixture SQL passes the Store's own statement grammar (`rsql.fixtureError`), a child's stdin closes through `host_process.close_stdin`, a refusing TCP port comes from `socket_fixture.refusedPort`, a `std.testing.tmpDir` a test chmods or lists opens with `.iterate = true`, and trust in a fixture CA goes explicitly through `--set network.caFile=PATH` or the settings document's `network.caFile`, or through `os_semantics.system_trust` on Linux only.
A fixture module, one with a main block or one that `build.zig` or `check.sh` launches, imports no other: fixtures share helpers through library modules such as `control_fixture.py`, and cases another script also runs live in a `*_cases.py` library behind a thin entry script.
`FixtureImportTest` in `tests/ci/test_harness_contracts.py` enforces it, so a change to one fixture selects only the targets that run it.

Fixtures and qualification harnesses observe the Host only through its boundaries.
Read native evidence from the lossless test observation channel; stderr phase traces drop records under contention and are never evidence (`tests/ci/test_harness_contracts.py` rejects them in qualification).
Take Host-decided values such as the canonical Store, capacities and descriptor requirements from readiness rather than recomputing them; pass each Host option once through the shared launcher; and let synthesized durable populations pass a production read before measuring them.
A value another file owns is pinned only by that owner's tests: other tests read the Store format, wire version, product defaults, catalog windows and efforts, and built-in tools from their owners (`host_process`, `product_defaults` and `tools.built_in_tool_set`), and match a caller error by its exit status, the invocation's context and its `[code]`, not the catalog's prose.
`test_store_schema_fixtures.py`, `test_wire_version.py` and `test_fixture_literals.py` in `tests/ci` take the forbidden values from the owners and reject restated ones.
Code that runs only on scheduled or one-platform jobs gets no other drift check.

For a fix on a [strict path](tests/ci/strict_paths.py), demonstrate that the owning invariant's test goes red on the unfixed path or a targeted mutation at the intended assertion, not fixture setup; the fix sharpens that invariant rather than adding a test for the one bug ([Test requirements](docs/verification/testing.md#bugs-refine-the-catalog)).
Examples: [#271 custody negative control](https://github.com/DivyanshGolyan/rui/commit/186514f) and [#258 qualification-oracle correction](https://github.com/DivyanshGolyan/rui/pull/258#issuecomment-5745097364).

For documentation, check contract preservation, references and `git diff --check`.
Report passed checks, material limits, pre-existing failures and interrupted/unrun checks; state whether delivery is local, committed, published or deployed.
Implementation claims require inspected source.
Keep accepted decisions, source inspection, prototypes, compilation and native process-crash evidence distinct.
OS-crash and power-loss recovery are outside the supported contract.

Required admission failures and unknown results block merging the current candidate, including native checks.
A signature that already fails on main is not permission to bypass admission.
Assertions, unexplained timeouts and unknown results require diagnosis, not replay.
Pause the affected outcome, not independent work; a publication failure does not create another main admission gate.
Diagnostic reruns need no routine grant; state the hypothesis or correction and preserve every failure.
An unexplained fail-then-pass is not reliable green; only a [listed flake](docs/verification/gates.md#listed-flakes)'s signature may fail then pass.

Required checks execute on the gated tip; build caches accelerate compilation and never cache test acceptance.
Keep results in PR checks and existing artifacts rather than growing coordination records.
Pin consumed dependencies, not unused installed-Amp bytes or fixture-policy hashes.
