# Matklad on explainable design

Research date: 2026-09-08. Primary-source reading for [Compare complete architecture designs for OnePage](https://github.com/DivyanshGolyan/onepage/issues/119). This note supplies design questions, not an accepted architecture amendment. No implementation or runtime verification was performed.

## Design for the actual work

In [Learning Software Architecture](https://matklad.github.io/2026/05/12/software-architecture.html) (2026-05-12), matklad explains rust-analyzer's architecture through its contributors and tasks. Its build and tests let core contributors concentrate on compiler work; isolated features let occasional contributors make useful changes without destabilizing the rest. Immutable snapshots make that isolation possible. He emphasizes learning through practice rather than expecting a general design recipe to settle everything.

**OnePage inference:** explainability should include a concrete maintenance exercise: where would we add a provider or change Edit recovery, and what unrelated machinery would we have to understand? External embedding and Durable Objects are probes of that boundary, while OnePage's own consumers remain the primary design pressure. A convincing written explanation is a necessary readiness gate, but it cannot prove every implementation assumption. Small, explicitly scoped experiments can test uncertain mechanisms without committing to production architecture.

## Compress the explanation into rules that stay true

[What is an Invariant?](https://matklad.github.io/2023/10/06/what-is-an-invariant.html) (2023-10-06) describes invariants as properties preserved as execution or the codebase evolves. Such properties compress reasoning across many possible paths. The examples also show their cost: identity-free syntax trees simplified refactoring but burdened the more common analysis work; the author questions that tradeoff. A frozen-world interface, by contrast, hides incremental computation behind a simpler consumer model.

**OnePage inference:** extract a few precise rules from our execution trace, then use each to eliminate mechanisms or expose missing ownership. Candidate rules include: no external attempt starts before its record commits; an approval applies to one exact edit; a cancelled local execution cannot publish success; uncertain Edit recovery observes and reports without reapplying. These are useful only if their scope and enforcing owner are clear. A rule that makes every caller carry extra identities or coordinate extra steps deserves scrutiny, even if it sounds principled.

## Judge interfaces in their language and at their call sites

[Three Different Cuts](https://matklad.github.io/2023/07/16/three-different-cuts.html) (2023-07-16, updated 2025-04-21) compares the same string operation in Rust, Go and Zig. Optionality, names, ownership, and ordinary use make their signatures differ. A short signature can leave important behavior implicit; a richer signature can express more but become harder to read. The conclusion is to use the language's natural vocabulary.

**OnePage inference:** write small Zig caller examples before choosing an interface. Include normal completion, errors, allocation ownership and cleanup. Evaluate how much a caller must remember, not just parameter count. Do not import a Rust-shaped ownership abstraction or a generic functional protocol merely because an admired system uses it. This post does not establish which OnePage interface is best; it supplies a way to compare concrete candidates.

## Prefer direct mechanisms where the problem permits them

[Against Query Based Compilers](https://matklad.github.io/2026/02/25/against-query-based-compilers.html) (2026-02-25) argues that general incremental engines cannot overcome the dependency structure of their input language. Where semantics allow independent, coarse stages, direct processing can be simpler and faster than pervasive tracked queries. He contrasts Zig's early file-local processing with Rust's dependencies and shows a direct map-update alternative to recursively composed queries.

**OnePage inference:** first ask whether local ownership, event ordering and ordinary database transactions solve a concrete execution problem. Add generalized decision or reconciliation machinery only for dependencies and failure boundaries that remain. This is an analogy, not evidence against OnePage's proposed snapshot/classification pipeline: that pipeline still deserves evaluation against an actual second consumer and recovery trace. The article argues for problem-specific structure, not a universal ban on intermediate representations or pure functions.

## Next use in the discussion

Revisit one command from the [message-to-edit trace](../design/message-edit-trace.md). State its promise, the few rules it must preserve, one owner for each rule, and the smallest caller-facing operation. Walk through ordinary execution, cancellation, and process loss. Then ask which additional representation or boundary makes those explanations shorter or a likely change more local. Keep a boundary only when we can name that benefit; keep failure complexity when removing it would make a promise false.

## Keep cancellation complexity at its actual owner

[Cancelation Terminology](https://matklad.github.io/2026/08/31/cancelation-terminology.html) distinguishes synchronous cancellation, asynchronous cancellation requiring acknowledgement, and application-level graceful shutdown. Its TigerBeetle example cancels the low-level Grid asynchronously and resets higher layers synchronously, instead of propagating asynchronous teardown through every layer.

**OnePage inference:** the user's serialized completion/cancellation proposal is a useful simplification. Keep result delivery and local cancellation under one owner; where buffers, subprocesses or resolver work still need time to finish, confine that lifetime to the actual resource owner. This does not establish that all curl cleanup is instantaneous, that remote effects stopped, or that process shutdown can ignore the accepted effect-aware cleanup contract. The post's crash-only discussion is not an accepted OnePage amendment.

## Centralize decisions and remove their unnecessary representations

[Push Ifs Up And Fors Down](https://matklad.github.io/2023/11/15/push-ifs-up-and-fors-down.html) suggests concentrating control flow so redundant conditions become visible. Its enum example shows one branch encoded as a value and immediately decoded into the same branch; removing that intermediate value can simplify the program. The batching discussion is separately motivated by amortized work.

**OnePage inference:** this provides a precise question for the mandatory classifier pipeline: is its decision value serving independent consumers, or merely encoding a branch for the next function to decode? Centralize the rule at its actual domain owner, not in ordinary API clients. Do not infer removal is selected, discard transactional checks, or batch away workflow admission/latency semantics.

[Try to Fix It One Level Deeper](https://matklad.github.io/2024/09/06/fix-one-level-deeper.html) argues for investigating the structure behind a bug rather than fixing only its symptom, including removing unnecessary configuration and addressing reentrancy. **OnePage inference:** preventing late result publication through local ownership is preferable to accumulating downstream repair checks for preventable delivery. Durable identity and recovery obligations still remain where crashes genuinely lose information.
