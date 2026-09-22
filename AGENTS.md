# Working on Rui

Build the smallest complete runtime users can explain through ordinary work, failure and recovery. Ground design in concrete caller behavior. Keep independent concerns independent; familiarity and line/module counts do not establish simplicity. Justify machinery by required behavior or demonstrated cost.

## Read and maintain the contract

Read [README.md](README.md) for scope/status, affected [ARCHITECTURE.md](ARCHITECTURE.md) sections for behavior/terminology, and applicable [VERIFICATION.md](VERIFICATION.md) cases for required evidence.

Each requirement has one home. Edit its owning section and affected verification cases; keep rationale beside the contract. Remove superseded text rather than adding parallel ADRs, proposals, glossaries, summaries or amendment ledgers. Git preserves history. Keep [research/README.md](research/README.md) a compact index of reproducible evidence.

For issue-driven work, read the live issue, relevant discussion and dependencies. [Issue #2](https://github.com/DivyanshGolyan/rui/issues/2) owns readiness. Open issues hold unresolved decisions/research; implementation slices link accepted contracts and define proof. Follow the latest accepted decision, not historical planning instructions. Use technical judgment within scope; involve the user in consequential behavior or scope choices while continuing independent work.

Inspect source before claiming implementation. Distinguish accepted behavior, prototype evidence, production qualification and remaining uncertainty.

## Deliver usable slices

[Issue #164](https://github.com/DivyanshGolyan/rui/issues/164) owns implementation order. Its [direct-core development-readiness checkpoint](https://github.com/DivyanshGolyan/rui/issues/168) is not full stage completion: a runnable caller path, essential failure/recovery evidence and a representative resource/control baseline can unblock dependent capabilities while [full qualification](https://github.com/DivyanshGolyan/rui/issues/231) remains open. The behavior, complete-stage checks and numerical qualification targets in Architecture and Verification are unchanged. Do not claim readiness merely because an issue was narrowed or an administrative ticket was closed.

Build one complete usable slice within its declared scope, with essential authorization, identity, recovery, containment and resource-owner tests. Keep known consequential defects, missing enforced bounds and native evidence needed for current safety on the critical path. Unsupported surfaces must fail or report unavailable explicitly; no credential fallback, discarded context or simulated durability to make a thin path work.

Use sufficient existing production tests and effective negative evidence before adding another proof. New or materially changed critical guards need targeted failure evidence; unchanged oracles do not require a repeated mutation campaign. Delete machinery actually superseded by the change, but do not make a repository-wide test migration or a speculative prefactor a new feature prerequisite. Refactors and optimizations need a concrete responsibility or attributed cost to remove.

## Make changes

Inspect the working-tree diff first; preserve concurrent work. Keep reviews read-only unless fixes are requested. Complete authorized work within scope without reopening settled choices.

Follow the [Zig 0.16 style guide](https://ziglang.org/documentation/0.16.0/#Style-Guide) and installed standard-library APIs: `TitleCase` for types/type-producing functions and files with top-level instance fields, `camelCase` for other functions, `snake_case` for values and namespace files. Name declarations in their full namespace without redundant prefixes or miscellaneous utility buckets. Keep helpers with their consumer until a shared responsibility warrants extraction.

Keep state, validation and transitions with their owner. Express lifecycle decisions as compact value transitions that can be tested without OS effects. Keep handles, storage, processes and accounting in a thin imperative owner that executes those decisions while preserving atomic checks and resource lifetimes. Test transition cases exhaustively through the owner interface, then use focused native integrations to verify adapters and handoffs. Do not copy or abstract resource handles merely to make code functional; expose semantic intent and opaque, pointer-stable handles rather than storage rows, internal lifecycle state or generic command buses. Use closed typed variants for cases with different authority.

Before correcting a failure, identify the owner, its invariant and the earliest transition that violated it. Correct that transition or replace the owning model rather than patching a downstream observer. When another corrective patch touches the same lifecycle, stop and redraw its states, authorities, handoffs and release conditions. Prefer deleting or replacing superseded state over adding flags, retry paths, test hooks or timing allowances.

Every allocation/resource needs an owner, population multiplier, bound, failure behavior and release point. Stream variable content without duplicating complete payloads. Derive limits from consumers; retain guards until replacement storage is verified. Never silently truncate semantic input. Separate orchestration from workload memory; account for shared budgets and justify independent pools against aggregate demand and isolation needs.

Use [Abseil Performance Hints](https://abseil.io/fast/hints.html) when implementing or reviewing performance: estimate repeated work, copies and allocation multipliers before adding complexity. Keep optimizations behind owning interfaces and measure gains on representative end-to-end workloads. Preserve clarity, required pointer stability, asynchronous lifetimes and the accepted contract.

Make allocator dependencies explicit at allocation sites. Document returned pointers/slices as owned or borrowed, including invalidation. Use `defer`/`errdefer` when scope exit is the release boundary; transferred/asynchronous resources stay owned until cleanup is safe. Treat cleanup as an owner transition: reclamation must be retry-safe, distinguish confirmed absence from unconfirmed removal, retain actionable resources after failure and release custody and accounting exactly once after success.

Respect architectural transaction/effect boundaries. Give each mutable handle one owner. Construct callback state in its final storage before registration; retain its address and custody through safe cleanup. Validate external syntax and consequential meaning. Notifications are hints; committed facts are authority. Trust validated local/SQLite facts within their documented boundary.

Assert programmer errors; return typed expected failures. Handle errors and explain intentionally ignored cleanup failures at their shared wrapper. Comments explain non-obvious invariants. Put exceptions beside their owning code or contract, with consumer, retained guarantee and evidence.

## Review

Review simplicity alongside correctness in every PR and local review, including Codex reviews, using the [simplicity gate](VERIFICATION.md#product-tenets-at-stage-completion).

- Trace affected design beyond changed lines to owning state/control flow, including existing causes of workarounds. Flag duplicated authority, scattered policy and dependencies on private representation, call order or cleanup details; connect each finding to the change.
- Justify affected state, layers, caches, queues and per-slot allocations by required behavior or demonstrated cost. Prefer the smallest complete correction at the responsible owner, including removal/replacement, over another special case. More changed lines can be simpler; keep unrelated cleanup separate.
- For each finding, identify code, scenario, consequence, smallest correction and guarantees to preserve. Quantify relevant memory multipliers; distinguish estimates from measurements.
- Report actionable design consequences, excluding personal style, speculative extensibility and gate-enforced formatting. Passing tests does not waive simplicity review.

For every review, obtain a read-only opinion from an agent independent of implementer and reviewer before implementing findings. Validate findings against the contract and owning state/control flow. Recommend the smallest complete correction, what can be removed, and how to verify memory and behavior. Prioritize simplicity, explainability and memory efficiency over implementation speed; require evidence before adding machinery.

Keep independent review, but bound its stopping rule. Block for a supported consequential defect, a violated resource/authority invariant or an essential missing test of introduced dangerous behavior. A request for broader proof must name the failure existing evidence could miss and why it blocks this slice; a new measurement must name the decision or support claim that needs it now. Defer unrelated redesign, speculative workload dimensions and repeated proof of unchanged behavior.

Give each independent opinion one programmer's lens: Rich Hickey by default; John Ousterhout, Rob Pike or Joe Armstrong when better suited. Ground likely challenges and recommendations in their published ideas and this code. Label this an interpretation, not their opinion or endorsement; contract and evidence decide.

## Verify and report

Run applicable [verification gates](VERIFICATION.md#canonical-gates); confirm commands in `build.zig`. Test meaningful failures and recovery boundaries with independent expectations. Drive fault injection through production transitions. Unit tests may inspect owner internals; integration and qualification evidence must assert durable owner-boundary outcomes rather than timing, scheduler order, private representation or fixture-only authority. Keep live provider checks opt-in. Broaden/repeat checks only for changes or unresolved concerns.

Explain each introduced resource's owner, multiplier, bound and release with implementation. Measure representative changed-owner peak and retained behavior at useful integration checkpoints and investigate unexplained growth. Run the full required populations, platform cases and provenance/validator checks before making the corresponding support, performance or release claims. Small development baselines do not qualify larger populations. Keep deferred evidence explicitly pending with its qualification owner; unavailable or historical evidence is never promoted to a current pass.

For documentation, check contract preservation, references and `git diff --check`. Report changes, passed checks and material limits, including pre-existing failures and interrupted/unrun checks. Keep prototype, compile and process-crash evidence distinct from production and power-loss qualification.

## Documentation and repository tools

Use the `writing-for-agents` skill when editing skills, `AGENTS.md` or Markdown reached from `AGENTS.md`; use `visual-pr` for pull request descriptions. Issues are tracked in GitHub; see [issue-tracker guidance](docs/agents/issue-tracker.md) and [triage labels](docs/agents/triage-labels.md). [Domain guidance](docs/agents/domain.md) routes terminology and decision work to its owning contract.
