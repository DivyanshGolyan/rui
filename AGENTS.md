# Working on Rui

Build the smallest complete runtime users can explain through ordinary work, failure and recovery. Ground design in concrete caller behavior. Keep independent concerns independent; familiarity and line/module counts do not establish simplicity. Justify machinery by required behavior or demonstrated cost.

## Read and maintain the contract

Read [README.md](README.md) for scope/status, affected [ARCHITECTURE.md](ARCHITECTURE.md) sections for behavior/terminology, and applicable [VERIFICATION.md](VERIFICATION.md) cases for required evidence.

Each requirement has one home. Edit its owning section and affected verification cases; keep rationale beside the contract. Remove superseded text rather than adding parallel ADRs, proposals, glossaries, summaries or amendment ledgers. Git preserves history. Keep [research/README.md](research/README.md) a compact index of reproducible evidence.

For issue-driven work, read the live issue, relevant discussion and dependencies. [Issue #2](https://github.com/DivyanshGolyan/rui/issues/2) owns readiness. Open issues hold unresolved decisions/research; implementation slices link accepted contracts and define proof. Follow the latest accepted decision, not historical planning instructions. Use technical judgment within scope; involve the user in consequential behavior or scope choices while continuing independent work.

Inspect source before claiming implementation. Distinguish accepted behavior, prototype evidence, production qualification and remaining uncertainty.

## Make changes

Inspect the working-tree diff first; preserve concurrent work. Keep reviews read-only unless fixes are requested. Correct the owning invariant rather than a downstream symptom; retain transaction, effect and lifetime boundaries. Justify added state, layers, queues and allocations by required behavior or demonstrated cost.

Follow the [Zig 0.16 style guide](https://ziglang.org/documentation/0.16.0/#Style-Guide) and installed standard-library APIs: `TitleCase` for types/type-producing functions and files with top-level instance fields, `camelCase` for other functions, `snake_case` for values and namespace files. Name declarations in their full namespace without redundant prefixes or miscellaneous utility buckets. Keep helpers with their consumer until a shared responsibility warrants extraction.

Keep state, validation and transitions with their owner. Express lifecycle decisions as testable value transitions; keep OS handles, storage, processes and accounting in the thin owner that executes them. Use closed variants for different authority and opaque, pointer-stable handles rather than rows or generic command buses.

Test transitions through the owner interface and native integrations at adapter handoffs. Every allocation needs an owner, multiplier, bound, failure behavior and release point. Stream variable content, account for shared budgets and document borrowed/owned pointers and invalidation. Use [Abseil Performance Hints](https://abseil.io/fast/hints.html) to estimate repeated work, copies and allocation multipliers before adding complexity. Cleanup is an owner transition: distinguish confirmed absence from unconfirmed removal, retain actionable resources after failure and release custody/accounting exactly once after success.

Validate external syntax and consequential meaning. Notifications are hints; committed facts are authority. Assert programmer errors and return typed expected failures. Put non-obvious invariants and exceptions beside their contract or owner.

## Review

Review simplicity alongside correctness in every PR and local review, including Codex reviews, using the [simplicity gate](VERIFICATION.md#product-tenets-at-stage-completion).

- Trace affected design beyond changed lines to owning state/control flow, including existing causes of workarounds. Flag duplicated authority, scattered policy and dependencies on private representation, call order or cleanup details; connect each finding to the change.
- Justify affected state, layers, caches, queues and per-slot allocations by required behavior or demonstrated cost. Prefer the smallest complete correction at the responsible owner, including removal/replacement, over another special case. More changed lines can be simpler; keep unrelated cleanup separate.
- For each finding, identify code, scenario, consequence, smallest correction and guarantees to preserve. Quantify relevant memory multipliers; distinguish estimates from measurements.
- Report actionable design consequences, excluding personal style, speculative extensibility and gate-enforced formatting. Passing tests does not waive simplicity review.

For every review, obtain a read-only opinion from an agent independent of implementer and reviewer before implementing findings. Validate findings against the contract and owning state/control flow. Recommend the smallest complete correction, what can be removed, and how to verify memory and behavior. Prioritize simplicity, explainability and memory efficiency over implementation speed; require evidence before adding machinery.

Give each independent opinion one programmer's lens: Rich Hickey by default; John Ousterhout, Rob Pike or Joe Armstrong when better suited. Ground likely challenges and recommendations in their published ideas and this code. Label this an interpretation, not their opinion or endorsement; contract and evidence decide.

## Verify and report

Run applicable [verification gates](VERIFICATION.md#canonical-gates); confirm commands in `build.zig`. Test meaningful failures and recovery boundaries with independent expectations. Drive fault injection through production transitions. Unit tests may inspect owner internals; integration and qualification evidence must assert durable owner-boundary outcomes rather than timing, scheduler order, private representation or fixture-only authority. Keep live provider checks opt-in. Broaden/repeat checks only for changes or unresolved concerns.

For documentation, check contract preservation, references and `git diff --check`. Report changes, passed checks and material limits, including pre-existing failures and interrupted/unrun checks. Keep prototype, compile and process-crash evidence distinct from production and power-loss qualification.

## Documentation and repository tools

Use the `writing-for-agents` skill when editing skills, `AGENTS.md` or Markdown reached from `AGENTS.md`; use `visual-pr` for pull request descriptions. Issues are tracked in GitHub; see [issue-tracker guidance](docs/agents/issue-tracker.md) and [triage labels](docs/agents/triage-labels.md). [Domain guidance](docs/agents/domain.md) routes terminology and decision work to its owning contract.
