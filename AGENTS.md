# Working on Latifa

Build the smallest complete runtime whose rules the user can explain through ordinary work, failure and recovery. Ground design discussions in concrete caller behavior. Additional machinery must earn its complexity through necessary behavior or demonstrated cost.

## Read and maintain the contract

Read [README.md](README.md) for scope/status, the affected sections of [ARCHITECTURE.md](ARCHITECTURE.md) for behavior and terminology, and [VERIFICATION.md](VERIFICATION.md) for required evidence. Read only what the task needs.

Each requirement has one home. Change the owning section and its affected verification cases. Put necessary rationale beside the contract; do not create parallel ADRs, design proposals, glossaries, summaries or amendment ledgers. Remove superseded text; Git preserves history. Keep [research/README.md](research/README.md) as a compact index of reproducible evidence, not another specification.

For issue-driven work, read the live issue and relevant discussion/dependencies. [Issue #2](https://github.com/DivyanshGolyan/latifa/issues/2) owns readiness. Open issues hold unresolved decisions/research; implementation slices link accepted contracts and define their proof. Historical or closed planning issues are not implementation instructions. Resolve conflicts against the latest accepted decision. Exercise technical judgment within agreed scope; involve the user in consequential behavior or scope choices while continuing independent work. Keep settled decisions and remaining uncertainty clear.

Inspect source before claiming implementation. Keep accepted behavior, prototype evidence and passing production qualification distinct.

## Make changes

Inspect the working-tree diff first and preserve concurrent work. Keep reviews read-only unless fixes are requested. Complete authorized work without reopening settled choices; stay within the requested scope.

Keep state, validation and transitions together under their owner. Expose semantic intent and opaque, pointer-stable resource handles, not storage rows, internal lifecycle state or generic command buses. Use closed typed variants where different cases carry different authority. Extract helpers for concrete reuse or clearer reasoning.

Every allocation and external resource needs an owner, population multiplier, bound, failure behavior and release point. Stream variable content; do not duplicate complete payloads. Derive limits from their actual consumer, retain safety checks until replacement storage is verified, and never silently truncate semantic input. Separate orchestration memory from workload memory.

Respect the architecture's transaction and effect boundaries. One owner accesses each mutable handle. Do not free callback state or recycle custody before safe cleanup. Validate external syntax and consequential meaning; treat notifications as hints and committed facts as authority. Trust already-validated local/SQLite facts within their documented boundary rather than layering redundant validation.

Assert programmer errors; return typed expected failures. Handle errors and explain intentionally ignored cleanup failures at their shared wrapper. Comments explain non-obvious invariants, not syntax. Put local exceptions beside the code and architectural exceptions in the owning contract, with their consumer, retained guarantee and evidence.

## Verify and finish

Use the applicable [verification gates](VERIFICATION.md#canonical-gates); confirm commands in `build.zig`. Test meaningful failures and recovery boundaries, not copies of the implementation. Keep live provider checks opt-in. Broaden or repeat checks only when changes or unresolved concerns justify them.

For documentation changes, check contract preservation, references and `git diff --check`. Report what changed, what passed and material limits; identify pre-existing failures and interrupted/unrun checks accurately. Do not label prototypes, compilation or process-crash checks as broader production or power-loss qualification.
