# Working on Rui

Build the simplest complete runtime users can explain through ordinary work, failure and recovery. Prefer the simplest coherent final design over the smallest diff. Ground design in concrete caller behavior. Keep independent concerns independent; familiarity and line/module counts do not establish simplicity. Justify machinery by required behavior or demonstrated cost.

## Read and maintain the contract

Read [README.md](README.md) for scope/status, affected [ARCHITECTURE.md](ARCHITECTURE.md) sections for behavior/terminology, and applicable [VERIFICATION.md](VERIFICATION.md) cases for required evidence.

Each requirement has one home. Edit its owning section and affected verification cases; keep rationale beside the contract. Remove superseded text rather than adding parallel ADRs, proposals, glossaries, summaries or amendment ledgers. Git preserves history. Keep [research/README.md](research/README.md) a compact index of reproducible evidence.

For issue-driven work, read the live issue, relevant discussion and dependencies. [Issue #2](https://github.com/DivyanshGolyan/rui/issues/2) owns readiness. Open issues hold unresolved decisions/research; implementation slices link accepted contracts and define proof. Follow the latest accepted decision, not historical planning instructions. Use technical judgment within scope; involve the user in consequential behavior or scope choices while continuing independent work.

Inspect source before claiming implementation. Distinguish accepted behavior, prototype evidence, production qualification and remaining uncertainty.

## Make changes

Inspect the working-tree diff first; preserve concurrent work. Keep reviews read-only unless fixes are requested. Infer intent from the request and conversation; carry authorized work through implementation, applicable verification and issue acceptance criteria without reopening settled choices or stopping at a scaffold.

Resolve routine reversible choices from the contract and code. Ask only for unresolved consequential product/architecture choices, missing access or authorization. Before asking, complete already-authorized independent work so the question is concrete and reviewable; give bounded options, a recommendation and their machinery/failure consequences.

Implementation approval does not authorize pushing, creating/updating PRs or issues, closing issues, merging, deploying or other shared/irreversible effects. Obtain specific authorization unless already granted; prepare the local result first.

Delegate bounded independent investigations when they save time or improve evidence, and obtain independent opinions on material design questions. Parallelize independent work where tools allow; continue settled work while it runs. Retain ownership of the core task, validate returned evidence and integrate results.

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

Give each independent opinion one programmer's lens: Rich Hickey by default; John Ousterhout, Rob Pike or Joe Armstrong when better suited. Ground likely challenges and recommendations in their published ideas and this code. Label this an interpretation, not their opinion or endorsement; contract and evidence decide.

## Verify and report

Run applicable [verification gates](VERIFICATION.md#canonical-gates); confirm commands in `build.zig`. Test meaningful failures and recovery boundaries with independent expectations. Drive fault injection through production transitions. Unit tests may inspect owner internals; integration and qualification evidence must assert durable owner-boundary outcomes rather than timing, scheduler order, private representation or fixture-only authority. Keep live provider checks opt-in. Broaden/repeat checks only for changes or unresolved concerns.

For a new owner-boundary regression, show that the counterexample goes red on the unfixed path or a targeted mutation, at the intended assertion rather than fixture setup. [Wayne's invariant counterexamples](https://www.youtube.com/watch?v=d9cM8f_qSLQ) motivate the negative case; Rui's [#271 custody review fix](https://github.com/DivyanshGolyan/rui/commit/186514f) checked that disabling duplicate detection exposed orphan custody, while the [#258 execution-service review](https://github.com/DivyanshGolyan/rui/pull/258#issuecomment-5745097364) reproduced false-positive qualification before correcting its oracle.

For fast development feedback, keep Zig caches warm and run the narrowest relevant build step (`test-logic` for portable owner/turn logic, or a focused native/integration step for its boundary). A test filter may trigger a distinct compilation; a narrow step never replaces applicable canonical gates. Before changing the build graph or enabling experimental incremental compilation for speed, measure comparable edit-rebuild cycles with `--summary all` and preserve non-incremental, empty-cache evidence where required. See [development build latency research](research/build-times-sources.md) for measured costs and Zig 0.16 caveats.

For documentation, check contract preservation, references and `git diff --check`. Report changes, passed checks and material limits, including pre-existing failures and interrupted/unrun checks. State the actual delivery state: local, committed, published or deployed. Keep prototype, compile and process-crash evidence distinct from production and power-loss qualification.

Lead with the main point in concise, concrete paragraphs; use lists only when they help. Distinguish observations, recommendations, decisions and evidence limits. Explain unfamiliar designs through concrete caller flows in small steps. Report meaningful findings or blockers rather than routine progress narration or canned summaries.

## Documentation and repository tools

Explicit user instructions take precedence over skill guidelines; Rui's owning documentation governs repository policy where generic skills conflict. Apply this to confirmation checkpoints, test scope, publication steps and document layout. Skills supply techniques, not authorization or new contract homes. If a skill would pause or divert requested work, link its exact file/instruction, distinguish its requirement from your interpretation, and resolve the conflict using these priorities before asking.

Use the `writing-for-agents` skill when editing skills, `AGENTS.md` or Markdown reached from `AGENTS.md`; use `visual-pr` for pull request descriptions. Issues are tracked in GitHub; see [issue-tracker guidance](docs/agents/issue-tracker.md) and [triage labels](docs/agents/triage-labels.md). [Domain guidance](docs/agents/domain.md) routes terminology and decision work to its owning contract.
