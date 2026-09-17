# Working on Rui

Build the smallest complete runtime users can explain through ordinary work, failure and recovery. Ground design in concrete caller behavior. Keep independent concerns independent; familiarity and line/module counts do not establish simplicity. Justify machinery by required behavior or demonstrated cost.

## Read and maintain the contract

Read [README.md](README.md) for scope/status, affected [ARCHITECTURE.md](ARCHITECTURE.md) sections for behavior/terminology, and applicable [VERIFICATION.md](VERIFICATION.md) cases for required evidence.

Each requirement has one home. Edit its owning section and affected verification cases; keep rationale beside the contract. Remove superseded text rather than adding parallel ADRs, proposals, glossaries, summaries or amendment ledgers. Git preserves history. Keep [research/README.md](research/README.md) a compact index of reproducible evidence.

For issue-driven work, read the live issue, relevant discussion and dependencies. [Issue #2](https://github.com/DivyanshGolyan/rui/issues/2) owns readiness. Open issues hold unresolved decisions/research; implementation slices link accepted contracts and define proof. Follow the latest accepted decision, not historical planning instructions. Use technical judgment within scope; involve the user in consequential behavior or scope choices while continuing independent work.

Inspect source before claiming implementation. Distinguish accepted behavior, prototype evidence, production qualification and remaining uncertainty.

## Agent skills

### Agent-facing documentation

Use the `writing-for-agents` skill when creating or editing skills, `AGENTS.md` or Markdown reached from `AGENTS.md`.

### Pull request descriptions

Use the `visual-pr` skill when creating or updating a pull request description.

### Issue tracker

Issues are tracked in GitHub. See [docs/agents/issue-tracker.md](docs/agents/issue-tracker.md).

### Triage labels

The default Matt Pocock triage vocabulary is used. See [docs/agents/triage-labels.md](docs/agents/triage-labels.md).

### Domain docs

Rui keeps accepted domain terminology and decisions in its owning contract. See [docs/agents/domain.md](docs/agents/domain.md).

## Make changes

Inspect the working-tree diff first; preserve concurrent work. Keep reviews read-only unless fixes are requested. Complete authorized work within scope without reopening settled choices.

Follow the [Zig 0.16 style guide](https://ziglang.org/documentation/0.16.0/#Style-Guide) and installed standard-library APIs: `TitleCase` for types/type-producing functions and files with top-level instance fields, `camelCase` for other functions, `snake_case` for values and namespace files. Name declarations in their full namespace without redundant prefixes or miscellaneous utility buckets. Keep helpers with their consumer until a shared responsibility warrants extraction.

Keep state, validation and transitions with their owner. Separate compact decision facts from effects while preserving atomic checks and resource lifetimes. Expose semantic intent and opaque, pointer-stable handles rather than storage rows, internal lifecycle state or generic command buses. Use closed typed variants for cases with different authority.

Every allocation/resource needs an owner, population multiplier, bound, failure behavior and release point. Stream variable content without duplicating complete payloads. Derive limits from consumers; retain guards until replacement storage is verified. Never silently truncate semantic input. Separate orchestration from workload memory; account for shared budgets and justify independent pools against aggregate demand and isolation needs.

Use [Abseil Performance Hints](https://abseil.io/fast/hints.html) when implementing or reviewing performance: estimate repeated work, copies and allocation multipliers before adding complexity. Keep optimizations behind owning interfaces and measure gains on representative end-to-end workloads. Preserve clarity, required pointer stability, asynchronous lifetimes and the accepted contract.

Make allocator dependencies explicit at allocation sites. Document returned pointers/slices as owned or borrowed, including invalidation. Use `defer`/`errdefer` when scope exit is the release boundary; transferred/asynchronous resources stay owned until cleanup is safe.

Respect architectural transaction/effect boundaries. Give each mutable handle one owner. Construct callback state in its final storage before registration; retain its address and custody through safe cleanup. Validate external syntax and consequential meaning. Notifications are hints; committed facts are authority. Trust validated local/SQLite facts within their documented boundary.

Assert programmer errors; return typed expected failures. Handle errors and explain intentionally ignored cleanup failures at their shared wrapper. Comments explain non-obvious invariants. Put exceptions beside their owning code or contract, with consumer, retained guarantee and evidence.

## Code Review Rules

Review simplicity alongside correctness in every PR and local review, including Codex reviews, using the [simplicity gate](VERIFICATION.md#product-tenets-at-stage-completion).

- Trace affected design beyond changed lines to owning state/control flow, including existing causes of workarounds. Flag duplicated authority, scattered policy and dependencies on private representation, call order or cleanup details; connect each finding to the change.
- Justify affected state, layers, caches, queues and per-slot allocations by required behavior or demonstrated cost. Prefer the smallest complete correction at the responsible owner, including removal/replacement, over another special case. More changed lines can be simpler; keep unrelated cleanup separate.
- For each finding, identify code, scenario, consequence, smallest correction and guarantees to preserve. Quantify relevant memory multipliers; distinguish estimates from measurements.
- Report actionable design consequences, excluding personal style, speculative extensibility and gate-enforced formatting. Passing tests does not waive simplicity review.

For every review, obtain a read-only opinion from an agent independent of implementer and reviewer before implementing findings. Validate findings against the contract and owning state/control flow. Recommend the smallest complete correction, what can be removed, and how to verify memory and behavior. Prioritize simplicity, explainability and memory efficiency over implementation speed; require evidence before adding machinery.

Give each independent opinion one programmer's lens: Rich Hickey by default; John Ousterhout, Rob Pike or Joe Armstrong when better suited. Ground likely challenges and recommendations in their published ideas and this code. Label this an interpretation, not their opinion or endorsement; contract and evidence decide.

## Verify and finish

Run applicable [verification gates](VERIFICATION.md#canonical-gates); confirm commands in `build.zig`. Test meaningful failures and recovery boundaries with independent expectations. Keep live provider checks opt-in. Broaden/repeat checks only for changes or unresolved concerns.

For documentation, check contract preservation, references and `git diff --check`. Report changes, passed checks and material limits, including pre-existing failures and interrupted/unrun checks. Keep prototype, compile and process-crash evidence distinct from production and power-loss qualification.
