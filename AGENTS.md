# Working on Rui

Build the smallest complete runtime whose rules the user can explain through ordinary work, failure and recovery. Ground design discussions in concrete caller behavior. Simplicity means keeping independent concerns independent; familiarity and line or module counts are poor proxies. Additional machinery must earn its complexity through necessary behavior or demonstrated cost.

## Read and maintain the contract

Read [README.md](README.md) for scope/status, the affected sections of [ARCHITECTURE.md](ARCHITECTURE.md) for behavior and terminology, and [VERIFICATION.md](VERIFICATION.md) for required evidence. Read only what the task needs.

Each requirement has one home. Change the owning section and its affected verification cases. Put necessary rationale beside the contract; do not create parallel ADRs, design proposals, glossaries, summaries or amendment ledgers. Remove superseded text; Git preserves history. Keep [research/README.md](research/README.md) as a compact index of reproducible evidence, not another specification.

For issue-driven work, read the live issue and relevant discussion/dependencies. [Issue #2](https://github.com/DivyanshGolyan/rui/issues/2) owns readiness. Open issues hold unresolved decisions/research; implementation slices link accepted contracts and define their proof. Historical or closed planning issues are not implementation instructions. Resolve conflicts against the latest accepted decision. Exercise technical judgment within agreed scope; involve the user in consequential behavior or scope choices while continuing independent work. Keep settled decisions and remaining uncertainty clear.

Inspect source before claiming implementation. Keep accepted behavior, prototype evidence and passing production qualification distinct.

## Make changes

Inspect the working-tree diff first and preserve concurrent work. Keep reviews read-only unless fixes are requested. Complete authorized work without reopening settled choices; stay within the requested scope.

Follow the [Zig 0.16 style guide](https://ziglang.org/documentation/0.16.0/#Style-Guide) and installed standard-library APIs. Use `TitleCase` for types/type-producing functions, `camelCase` for other functions, and `snake_case` for values and namespace files; files with top-level instance fields use `TitleCase`. Name declarations in their full namespace without redundant prefixes or miscellaneous utility buckets. Keep helpers with their consumer until a concrete shared responsibility warrants extraction.

Keep state, validation and transitions together under their owner. Separate compact decision facts from effects within that owner, preserving atomic checks and resource lifetimes. Expose semantic intent and opaque, pointer-stable resource handles, not storage rows, internal lifecycle state or generic command buses. Use closed typed variants where different cases carry different authority.

Every allocation and external resource needs an owner, population multiplier, bound, failure behavior and release point. Stream variable content; do not duplicate complete payloads. Derive limits from their actual consumer, retain safety checks until replacement storage is verified, and never silently truncate semantic input. Separate orchestration memory from workload memory. Account for shared budgets across owners; justify independent pools against aggregate demand and required isolation.

Use [Abseil Performance Hints](https://abseil.io/fast/hints.html) as an implementation and review reference: prefer efficient choices that preserve clarity; estimate repeated work, copies and allocation multipliers before adding complexity. Keep optimizations behind owning interfaces and validate measured gains against representative end-to-end workloads. Preserve required pointer stability and asynchronous lifetimes; the guide does not override the accepted contract.

Make allocator dependencies explicit where allocation occurs. Document returned pointers/slices as owned or borrowed, including invalidation. Pair acquisition with `defer`/`errdefer` only when scope exit is the actual release boundary; transferred or asynchronous resources remain with their owner until cleanup is safe.

Respect the architecture's transaction and effect boundaries. One owner accesses each mutable handle. Do not free callback state or recycle custody before safe cleanup. Validate external syntax and consequential meaning; treat notifications as hints and committed facts as authority. Trust already-validated local/SQLite facts within their documented boundary rather than layering redundant validation.

Assert programmer errors; return typed expected failures. Handle errors and explain intentionally ignored cleanup failures at their shared wrapper. Comments explain non-obvious invariants, not syntax. Put local exceptions beside the code and architectural exceptions in the owning contract, with their consumer, retained guarantee and evidence.

## Code Review Rules

Explicitly review every PR for simplicity alongside correctness, using the [simplicity gate](VERIFICATION.md#product-tenets-at-stage-completion). Apply these rules to Codex PR reviews as well as local reviews.

- Review the affected design beyond changed lines. Trace complexity to its owning state or control flow, including existing code that forces the change into workarounds. Flag duplicated authority, scattered policy and dependencies on private representation, call order or cleanup details; explain how each finding relates to the PR.
- Examine state, layers, caches, queues and per-slot allocations in the affected path for a required behavior or demonstrated cost that justifies them. Prefer correcting the responsible design, including removing or replacing existing machinery, over adding another special case. Choose the smallest complete design correction, even when it changes more lines; keep unrelated cleanup separate.
- For each finding, identify the affected code, concrete scenario and consequence, then describe the smallest correction and the guarantees it must preserve. Quantify memory multipliers when relevant; distinguish estimates from measurements.
- Report actionable design consequences. Keep personal style preferences, speculative extensibility and formatting enforced by the canonical gates out of findings. Passing tests does not waive simplicity review.

For every review, obtain a read-only opinion from an agent independent of the implementer and reviewer before implementing its findings. Check the finding against the accepted contract, trace the cause to its owning state or control flow, and recommend the smallest complete correction, including what can be removed and how memory and behavior will be verified. Prioritize simplicity, explainability and memory efficiency over implementation speed; do not accumulate patches or machinery to satisfy unproven assumptions.

Give each independent design opinion one named programmer's lens: Rich Hickey by default, or John Ousterhout, Rob Pike or Joe Armstrong when their perspective better fits the finding. Explain what they would likely challenge and recommend, grounded in their published ideas and this code. Present this as an interpretation, not their actual opinion or endorsement; the accepted contract and evidence decide the outcome.

## Verify and finish

Use the applicable [verification gates](VERIFICATION.md#canonical-gates); confirm commands in `build.zig`. Test meaningful failures and recovery boundaries, not copies of the implementation. Keep live provider checks opt-in. Broaden or repeat checks only when changes or unresolved concerns justify them.

For documentation changes, check contract preservation, references and `git diff --check`. Report what changed, what passed and material limits; identify pre-existing failures and interrupted/unrun checks accurately. Do not label prototypes, compilation or process-crash checks as broader production or power-loss qualification.
