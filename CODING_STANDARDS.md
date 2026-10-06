# Rui coding standards

Load sections through [AGENTS.md](AGENTS.md#before-work). These standards own engineering methods, not runtime behavior or qualification requirements.

## Contract maintenance

Each requirement has one home: [Architecture](ARCHITECTURE.md) owns accepted behavior, terminology, decisions and rationale; [Verification](VERIFICATION.md) owns required evidence and gates; GitHub issues hold unresolved decisions and research. Implementation slices link accepted contracts and define proof.

Edit the owning section and affected verification cases; keep rationale beside the contract. Identify conflicts with accepted behavior explicitly. Replace superseded text rather than creating parallel ADRs, proposals, glossaries, summaries or amendment ledgers. Keep [Research](research/README.md) a compact index of reproducible evidence.

## Engineering

Ground design in concrete caller behavior. Keep independent concerns independent; familiarity and line/module counts do not establish simplicity. Obtain independent opinions on material design questions.

### Ownership and transitions

Keep state, validation and transitions with their owner. Express lifecycle decisions as compact value transitions testable without OS effects; keep handles, storage, processes and accounting in a thin imperative owner preserving atomic checks and resource lifetimes. Test transitions exhaustively through the owner interface, then verify adapters and handoffs with focused native integrations.

Expose semantic intent and opaque, pointer-stable handles rather than storage rows, internal lifecycle state or generic command buses. Use closed typed variants for different authorities. Do not copy or abstract resource handles merely to make code functional.

Before correcting a failure, identify its owner, invariant and earliest violating transition. Correct that transition or replace the owning model, not a downstream observer. When another correction touches the same lifecycle, redraw states, authorities, handoffs and release conditions. Prefer replacing superseded state over additional flags, retries, test hooks or timing allowances.

Respect architectural transaction/effect boundaries. Give each mutable handle one owner. Construct callback state in final storage before registration; retain its address and custody through safe cleanup. Validate external syntax and consequential meaning. Notifications are hints; committed facts are authority. Trust validated local/SQLite facts within their documented boundary.

### Resources and cleanup

Every allocation/resource needs an owner, population multiplier, bound, failure behavior and release point. Stream variable content without duplicating complete payloads. Derive limits from consumers; retain guards until replacement storage is verified. Never silently truncate semantic input. Separate orchestration from workload memory; account for shared budgets and justify independent pools against aggregate demand and isolation needs.

Make allocator dependencies explicit at allocation sites. Document returned pointers/slices as owned or borrowed, including invalidation. Use `defer`/`errdefer` at scope-bound release; transferred/asynchronous resources remain owned until cleanup is safe.

Cleanup is an owner transition: reclamation must be retry-safe, distinguish confirmed absence from unconfirmed removal, retain actionable resources after failure, and release custody and accounting exactly once after success.

### Zig and errors

Follow the [Zig 0.16 style guide](https://ziglang.org/documentation/0.16.0/#Style-Guide) and installed standard-library APIs: `TitleCase` for types/type-producing functions and files with top-level instance fields, `camelCase` for other functions, `snake_case` for values and namespace files. Name declarations in their full namespace without redundant prefixes or miscellaneous utility buckets. Keep helpers with their consumer until a shared responsibility warrants extraction.

Assert programmer errors; return typed expected failures. Handle errors and explain intentionally ignored cleanup failures at their shared wrapper. Put exceptions beside their owning code or contract, with consumer, retained guarantee and evidence.

### Performance

Use [Abseil Performance Hints](https://abseil.io/fast/hints.html) when implementing or reviewing performance. Estimate repeated work, copies and allocation multipliers before adding complexity. Keep optimizations behind owning interfaces; measure representative end-to-end gains while preserving clarity, pointer stability, asynchronous lifetimes and the accepted contract.

Before changing the build graph or enabling experimental incremental compilation for speed, measure comparable edit-rebuild cycles with `--summary all`; preserve non-incremental, empty-cache evidence where required. Consult [build-latency research](research/build-times-sources.md) for measured costs and Zig 0.16 caveats. Gate cadence remains in Verification.

## Review

Review correctness and simplicity using the [product-tenet gate](VERIFICATION.md#product-tenets-at-stage-completion), including local and Codex reviews.

For every review, obtain a read-only opinion from an agent independent of implementer and reviewer before implementing findings. Give each opinion one programmer's lens: Rich Hickey by default; John Ousterhout, Rob Pike or Joe Armstrong when better suited. Ground it in published ideas and the affected work; label it an interpretation, not their opinion or endorsement. Contract and evidence decide.

Trace beyond changed lines to owning state/control flow and existing causes of workarounds. Identify duplicated authority, scattered policy and dependencies on private representation, call order or cleanup details; connect findings to the change. Justify affected state, layers, caches, queues and per-slot allocations by required behavior or demonstrated cost.

Validate findings against the contract and owner. For each actionable finding, give code/location, scenario, consequence, smallest complete correction, removable machinery, preserved guarantees and behavior/memory verification. Quantify relevant memory multipliers; distinguish estimates from measurements. Prefer simplicity, explainability and memory efficiency over implementation speed. Keep unrelated cleanup separate; exclude personal style, speculative extensibility and gate-enforced formatting.

## Evidence

Use [canonical gates](VERIFICATION.md#canonical-gates) for required commands, focused checks, cache conditions and assembled-versus-independently-merged cadence; confirm commands in `build.zig`. Broaden/repeat checks only for changes or unresolved concerns. Live provider checks remain opt-in.

Test meaningful failures and recovery against independent expectations. Drive fault injection through production transitions. Unit tests may inspect owner internals; integration and qualification must assert durable owner-boundary outcomes rather than timing, scheduler order, private representation or fixture-only authority.

For each new owner-boundary regression, demonstrate that its counterexample goes red on the unfixed path or a targeted mutation at the intended assertion, not fixture setup. Examples: [#271 custody negative control](https://github.com/DivyanshGolyan/rui/commit/186514f) and [#258 qualification-oracle correction](https://github.com/DivyanshGolyan/rui/pull/258#issuecomment-5745097364).

For documentation, check contract preservation, references and `git diff --check`. Report passed checks, material limits, pre-existing failures and interrupted/unrun checks; state whether delivery is local, committed, published or deployed. Implementation claims require inspected source. Keep accepted decisions, source inspection, prototypes, compilation, process-crash evidence, production and power-loss qualification distinct; identify remaining uncertainty.
