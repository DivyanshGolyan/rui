# Rui coding standards

Load sections through [AGENTS.md](AGENTS.md#before-work). These standards own engineering methods, not runtime behavior or qualification requirements.

## Contract maintenance

Each requirement has one home: [Architecture](ARCHITECTURE.md) owns accepted behavior, terminology, decisions and rationale; [Verification](VERIFICATION.md) owns required evidence and gates; GitHub issues hold unresolved decisions and research. Implementation slices link accepted contracts and define proof.

Edit [Architecture](ARCHITECTURE.md) or [Verification](VERIFICATION.md) only when a change alters user-visible behavior, the Store format or a gate. Accepted behavior changes only by the user's decision: when an implementation departs from it, raise the conflict and change the code or ask, keeping the contract text as accepted. Then edit the owning section and affected verification cases; keep rationale beside the contract. Identify conflicts with accepted behavior explicitly. Replace superseded text rather than creating parallel ADRs, proposals, glossaries, summaries or amendment ledgers. Keep [Research](research/README.md) a compact index of reproducible evidence.

## Engineering

Ground design in concrete caller behavior. Before work from a design, mock or multi-PR plan starts, map every requirement, every "reuse X" and every element of the referenced design to a PR or task, or to a "left out" list the user sees before approving. Keep independent concerns independent; familiarity and line/module counts do not establish simplicity. Obtain independent opinions on material design questions.

### Ownership and transitions

Keep state, validation and transitions with their owner. Express lifecycle decisions as compact value transitions testable without OS effects; keep handles, storage, processes and accounting in a thin imperative owner preserving atomic checks and resource lifetimes. Test transitions exhaustively through the owner interface, then verify adapters and handoffs with focused native integrations. A documented any/every/never rule is tested over its whole domain (every key and encoding, draft state and width in range), with expected outcomes taken from an independent source such as the base commit's behavior, never from the table under test. A functional core takes the values its shell read (a record under its lock, rows inside the transaction, the current time) and returns the decision or action the shell applies; it keeps no copy of a fact another owner holds. List each core in `src/logic_tests.zig` so `test-logic` checks its boundary.

Expose semantic intent and opaque, pointer-stable handles rather than storage rows, internal lifecycle state or generic command buses. Use closed typed variants for different authorities. Do not copy or abstract resource handles merely to make code functional.

Reuse an existing owner whole. A new surface that does the same job as an existing component calls that component; when a boundary keeps a core from importing it, the shell owns the component and passes its outcomes in.

Before correcting a failure, identify its owner, invariant and earliest violating transition. Correct that transition or replace the owning model, not a downstream observer. From the first review finding, name its class, sweep the change for siblings and correct the structure that allows the class, so one round closes it. When another correction touches the same lifecycle, redraw states, authorities, handoffs and release conditions. Prefer replacing superseded state over additional flags, retries, test hooks or timing allowances.

Respect architectural transaction/effect boundaries. Give each mutable handle one owner. Construct callback state in final storage before registration; retain its address and custody through safe cleanup. Validate external syntax and consequential meaning. Notifications are hints; committed facts are authority. Trust validated local/SQLite facts within their documented boundary.

### Resources and cleanup

Every allocation/resource needs an owner, population multiplier, bound, failure behavior and release point. Stream variable content without duplicating complete payloads. Derive limits from consumers; retain guards until replacement storage is verified. Never silently truncate semantic input. Separate orchestration from workload memory; account for shared budgets and justify independent pools against aggregate demand and isolation needs.

Make allocator dependencies explicit at allocation sites. Document returned pointers/slices as owned or borrowed, including invalidation. Use `defer`/`errdefer` at scope-bound release; transferred/asynchronous resources remain owned until cleanup is safe.

Cleanup is an owner transition: reclamation must be retry-safe, distinguish confirmed absence from unconfirmed removal, retain actionable resources after failure, and release custody and accounting exactly once after success.

### Zig and errors

Follow the [Zig 0.17.0 style guide](https://ziglang.org/documentation/0.17.0/#Style-Guide) and installed standard-library APIs: `TitleCase` for types/type-producing functions and files with top-level instance fields, `camelCase` for other functions, `snake_case` for values and namespace files. Name declarations in their full namespace without redundant prefixes or miscellaneous utility buckets. Keep helpers with their consumer until a shared responsibility warrants extraction.

Assert programmer errors; return typed expected failures. Handle errors and explain intentionally ignored cleanup failures at their shared wrapper. Put exceptions beside their owning code or contract, with consumer, retained guarantee and evidence.

### Performance

Use [Abseil Performance Hints](https://abseil.io/fast/hints.html) when implementing or reviewing performance. Estimate repeated work, copies and allocation multipliers before adding complexity. Keep optimizations behind owning interfaces; measure representative end-to-end gains while preserving clarity, pointer stability, asynchronous lifetimes and the accepted contract.

Before changing the build graph or enabling experimental incremental compilation for speed, measure comparable edit-rebuild cycles with `--summary all`; preserve non-incremental, empty-cache evidence where required. Consult [build-latency research](research/build-times-sources.md) for measured costs and Zig 0.16 caveats. Gate cadence remains in Verification.

#### Host stacks

A Host thread keeps its stack's high-water pages for its life, and ReleaseSafe probes every page of a frame on entry. On Host threads:

- A value larger than 1 KiB has one address. Its owner passes `*T` and the producer fills it; it is never returned or copied by value. A big type initializes in place with `fn init(self: *T, ...)`.
- A frame holds at most 8 KiB. Larger storage belongs to the owner of the work: the exchange's heap objects for per-request work, the engine `Workspace` for recurring engine work, and `pages.Mapped` ([os/pages.zig](src/os/pages.zig)) for rare per-call work.
- An explicit `= undefined` in a struct literal writes 0xAA over those bytes in ReleaseSafe. Declare a field an initializer leaves unset `= undefined` in the type and leave it out of the literal.
- A literal that names a field stores field by field and skips fields whose default is `undefined`. An empty `.{}`, a field's default value, `null` and a payload-free union tag store every byte of the type. Name a big field's small parts instead, as in `.{ .workspace = .{ .len = 0 } }`.
- Rare work with scratch of its own (a trace, a diagnostic line, an error envelope, startup) is a `noinline` function, so the scratch stays off its caller's frame.

`stack-frames` enforces the frame budget ([canonical gates](VERIFICATION.md#canonical-gates)).

## Review

Before opening a PR, and again on each review-fix round, run one independent correctness, design and complecting review in a fresh context (a subagent, or another thread when none is available), using the [product tenets](VERIFICATION.md#product-tenets). The author fixes each finding before opening the PR, or records in the PR why it stays, and fixes it at its class ([Ownership and transitions](#ownership-and-transitions)). Review signoff does not gate landing a coherent green change; [Landing](AGENTS.md#landing) owns the required proof and handling of known failed counterexamples.

Review parity and failure paths as well as the diff:

- **Parity.** List what the change re-implements, replaces or drops: each sibling component, previous version and contract line it touches. Confirm each keeps its behavior. A second implementation of a behavior an existing component owns is a finding.
- **Discarded failures.** List every error a secondary path (after commit, on cancel or return, in a worker, during setup or teardown, a catch-all switch arm) discards, turns into `null` or treats as unreachable. Route each to the main path's failure boundary, or justify it beside the code.
- **In-flight effects.** Each effect the change emits has one record from emission to a definite answer. On every exit (return, error, cancel), the owner reports each still-open record to the caller's failure boundary.
- **Design.** Check the change against the approved design, not only the issue derived from it. An edit to a contract document that makes it match the change's own code is a finding, and so is a "by design" that cites text the same change added.

Trace beyond changed lines to owning state/control flow and existing causes of workarounds. Identify duplicated authority, scattered policy and dependencies on private representation, call order or cleanup details; connect findings to the change. Justify affected state, layers, caches, queues and per-slot allocations by required behavior or demonstrated cost.

Validate findings against the contract and owner. For each actionable finding, give code/location, scenario, consequence, smallest complete correction, removable machinery, preserved guarantees and behavior/memory verification. Quantify relevant memory multipliers; distinguish estimates from measurements. Prefer simplicity, explainability and memory efficiency over implementation speed. Keep unrelated cleanup separate; exclude personal style, speculative extensibility and gate-enforced formatting.

## Evidence

Use [canonical gates](VERIFICATION.md#canonical-gates) for required commands, focused checks, cache conditions and assembled-versus-independently-merged cadence; confirm commands in `build.zig`. During review-fix rounds, run the `select_tests.py --phase development` targets, the touched owners' focused tests and a mutation that reverts each fix and shows its new test fails; the PR's Selected run executes the review-phase set on the pushed head. Broaden/repeat checks only for changes or unresolved concerns. Live provider checks remain opt-in.

Test meaningful failures and recovery against independent expectations. Drive fault injection through production transitions. Unit tests may inspect owner internals; integration and qualification must assert durable owner-boundary outcomes rather than timing, scheduler order, private representation or fixture-only authority. A concurrent test peer records what it observed before it replies or exits, so cancelling or joining it once the code under test returns cannot change the result; check this by temporarily delaying each peer read, reply and exit. Order test actors with a gate or event, never a sleep. Tests wait for a condition only through `wait_for` in `tests/integration/host_process.py` or `waitUntil` in `src/testing/poll.zig`, which accept only a check that finishes before the deadline; `tests/ci/test_harness_contracts.py` counts every other sleep in a fixture, a Zig `test` block or a test-only Zig file against a shrink-only allowlist.

Fixtures and qualification harnesses observe the Host only through its boundaries. Read native evidence from the lossless test observation channel; stderr phase traces drop records under contention and are never evidence (`tests/ci/test_harness_contracts.py` rejects them in qualification). Take Host-decided values such as the canonical Store, capacities and descriptor requirements from readiness rather than recomputing them; pass each Host option once through the shared launcher; and let synthesized durable populations pass a production read before measuring them. Code that runs only on scheduled or one-platform jobs gets no other drift check.

For each new owner-boundary regression on a [strict path](AGENTS.md#landing), demonstrate that its counterexample goes red on the unfixed path or a targeted mutation at the intended assertion, not fixture setup. Examples: [#271 custody negative control](https://github.com/DivyanshGolyan/rui/commit/186514f) and [#258 qualification-oracle correction](https://github.com/DivyanshGolyan/rui/pull/258#issuecomment-5745097364).

For documentation, check contract preservation, references and `git diff --check`. Report passed checks, material limits, pre-existing failures and interrupted/unrun checks; state whether delivery is local, committed, published or deployed. Implementation claims require inspected source. Keep accepted decisions, source inspection, prototypes, compilation and native process-crash evidence distinct. OS-crash and power-loss recovery are outside the supported contract.

For changes touching the [strict landing paths](AGENTS.md#landing), pause the affected outcome after a failed or unknown check, not independent work; assertions, unexplained timeouts and unknown results require diagnosis, not replay. Elsewhere, Selected CI retries a failed shard once automatically, and other reds follow the landing rule: file an issue and fix forward. Diagnostic reruns need no routine grant; state the hypothesis or correction and preserve every failure. An unexplained fail-then-pass is not reliable green.

Required checks execute on the gated tip; build caches accelerate compilation and never cache test acceptance. Keep results in PR checks and existing artifacts rather than growing coordination records. Pin consumed dependencies, not unused installed-Amp bytes or fixture-policy hashes.
