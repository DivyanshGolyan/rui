# ADR-0014: Use ephemeral QuickJS for workflow evaluation

Status: accepted

One native Zig Host Runtime is the only agent runtime. A Host-managed QuickJS evaluator receives one immutable Evaluation Generation, evaluates the stored Workflow Definition from source against one Visibility Snapshot of terminal Turn Outputs and stable failures, returns one terminal outcome, and exits. No JavaScript heap, Promise resolver, continuation, bytecode, or completion callback survives a durable barrier. Caller-defined Agent Call Keys map directly to durable Turns. Equal canonical membership reattaches; changed binding conflicts. Physical Turn completion order is not observable, so V1 supports deterministic joins and excludes `Promise.race` and `Promise.any`.

## Accepted amendment — keyed Session operations

The [accepted Session/workflow decision](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667) supersedes the direct Agent Call Key-to-Turn mapping above. Run-local keys bind distinct Session operations and their original admissions/results; multiple message admissions may share a Turn outcome. The [current workflow contract](../../ARCHITECTURE.md#workflow-runs) preserves replay without retargeting it to later Session work. This does not alter disposable evaluation or deterministic joins.

## Accepted amendment — streamed Workflow Output

Workflow Output has no independent total serialized-result size cap. Bounded serialization and parent capture use shared charged scratch; actual engine/native memory, work/lifetime protection, strict-data validation and atomic publication remain in force. Resource exhaustion fails explicitly without partial success. Replace historical whole-output buffers and separate descriptor-workspace consumers before deleting their safety checks. This selects no new numeric evaluator bound; ARCHITECTURE.md Workflow Runs and VERIFICATION.md own the current contract.

## Accepted amendment — bounded native temporary memory

Keep native evaluator allocations bounded separately from the engine-managed heap, and reuse temporary storage after its last consumer finishes. Parsing-key validation and subsequent request encoding can share a buffer when retained references do not depend on its old contents. This adds no worker, process, pool or custom combined allocator. The numeric native capacity remains open pending the selected representation; neither a fixed 2 MiB requirement nor a physical-RAM saving is inferred from the prototype. ARCHITECTURE.md Disposable evaluator construction and VERIFICATION.md own the contract and required evidence.

## Accepted amendment — initial JavaScript heap limit

Use 16 MiB as the initial engine-managed heap limit per live evaluator. It is an allocation ceiling, not a reserved per-workflow block or a whole-process bound. The generated report-assembly sweep supports this starting value; representative full replay, serialization and Store publication remain required qualification. This does not select native capacity, evaluator concurrency or time limits.

## Accepted amendment — evaluator population and time

Run one evaluation lifecycle at a time per Host, including complete outcome handling and safe cleanup before the next starts. Model/tool work remains concurrent and waiting workflows retain no evaluator. Accept burst queueing rather than introduce parallel evaluator processes initially. Each evaluation receives a 1-second process CPU budget and a 5-second parent-owned elapsed deadline from successful spawn through protocol completion and child exit. Waiting before spawn and external work do not consume those deadlines. Derive internal/kernel checks from this policy; resource failure cannot publish partial success, and physical cleanup finishes before reuse. ARCHITECTURE.md and VERIFICATION.md define scope and required evidence.

## Accepted amendment — minimal evaluator limit model

Remove independent source/argument/visibility byte, total-entry, request-count and microtask policies that duplicate fixed representations. Replace those representations with bounded allocation/streaming and CPU/lifetime checks, preserving checks until replacements exist. Retain strict-data, duplicate-key/exact request, wire/arithmetic, recursion and diagnostic safeguards. Retire the unsupported fixed 64 MiB address-space policy for macOS V1; do not substitute a new memory-monitor service. This completes the evaluator containment design decision, not implementation or release qualification. ARCHITECTURE.md and VERIFICATION.md own the complete accepted contract.

## Accepted amendment — independent branch progress

Accepted 7 September 2026. A workflow branch may continue when its own dependencies become available, without waiting for unrelated branches. For the scanner/verifier pipeline, A's saved findings can enable A's verifiers while scanner B is still running. An explicit join still waits for its required inputs; eligibility does not bypass execution capacity.

The complete blocked set describes unresolved dependencies rather than a global completion barrier. Each generation retains one immutable Visibility Snapshot, evaluates from source, and exits without a retained heap or callbacks. Deterministic joins, stable keyed bindings and the exclusion of `Promise.race`/`Promise.any` remain. This replaces blanket all-dependency waiting; it does not select historical completion-order replay, a wake-up hook, a ready queue or exact eligibility SQL. [The trace](../design/workflow-branch-progress.md) separates the accepted behavior from the remaining mechanism and replay questions owned by [Choose workflow reevaluation eligibility and wake-ups](https://github.com/DivyanshGolyan/onepage/issues/114).

## Accepted amendment — asynchronous pull discovery

Accepted 7 September 2026. The existing Host pulls eligible workflow work from saved generation/dependency/result facts when evaluator capacity is free. After a complete evaluation lifecycle, it checks again without an intentional delay. A check finding no work arms one shared one-second asynchronous idle timer; startup uses the same discovery path. The Host continues ordinary I/O, controls and settlement while waiting. This adds no Turn-completion hook, pending notification list or durable ready queue. A newly available dependency can cause an extra evaluation even before a full join resolves. Generation snapshots remain immutable and publication preserves unobserved result changes for later pulls. ARCHITECTURE.md Workflow Runs and VERIFICATION.md own the detailed contract, lookup/fairness obligations and required qualification; the synthetic probe does not establish production responsiveness or idle CPU.

## Accepted amendment: fresh evaluation after a crash

Accepted 7 September 2026. A Host crash abandons an interrupted workflow evaluation. Recovery starts a fresh generation from source using currently available original keyed results, rather than reconstructing the interrupted generation's Visibility Snapshot. A view remains immutable while its evaluation runs. Already committed keyed operations survive and equal replay reuses them; changed bindings conflict. Unpublished calculations are discarded, incomplete dependency/output publication is not exposed, and the new generation fences stale admissions/publication. Committed terminal output remains authoritative. Interruption is itself a recovery eligibility case even without newly available results.

This supersedes same-generation snapshot reconstruction in earlier discovery discussion and the unaccepted sparse first-visible-generation candidate. No historical visibility metadata is required solely for recovery. The fixed-view capture mechanism and bounded publication remain implementation/design work; effect-specific recovery is unchanged. See ARCHITECTURE.md Workflow Runs, VERIFICATION.md and the [updated mapping](../design/workflow-generation-publication.md).

## Accepted amendment: on-demand original-result decoding

Accepted 7 September 2026 after the input-capture consultation. Fixed visibility does not require eager decoding. Capture exact available keys, outcome tags and original immutable result references in one read view, then materialize captured bodies outside that transaction through bounded content reads and Host service turns. Retain those immutable results through existing ownership. Permit the narrow snapshot-metadata scratch writes during visibility capture and explicitly inherited read-only completed-input descriptors for native positional lookup. Workflow JavaScript gains no path, raw descriptor or storage API; the Host remains the sole SQLite owner. Exact directory/file layout remains a candidate to verify.

Each invocation freshly deserializes its original saved outcome; separate invocations do not share mutable objects merely because their keys match. Reawaiting one Promise preserves its ordinary identity. The bridge keeps no decoded-answer cache after handoff. User-retained values remain subject to the engine limit; immediate available-result delivery is unchanged and no custom delivery scheduler is introduced.

Completely validate output and known bindings before new admissions, use read-only equal replay, retain independently atomic new-call admissions in encounter order, and service other Host work between them and during long preparation/comparison. Preserve committed prefixes after later failure, recheck fences and atomically publish the complete generation outcome/dependencies. This selects neither grouped commits nor a durable admission cursor. ARCHITECTURE.md Workflow Runs and VERIFICATION.md own the details and required evidence; the prototype is not production qualification.

## Accepted amendment: oldest-eligible pull selection

Accepted 7 September 2026. Keep the asynchronous pull loop and select the oldest eligible Run by creation time with a stable identity tie-breaker. Recheck immediately after evaluation/publication or failure cleanup and Host service; wait one second asynchronously only after an empty query. Do not add rotating scan state or a ready queue. Qualification should reflect millisecond evaluations and seconds-to-minutes Turns, while measuring discovery cost and aggregate demand separately. Oldest-first does not promise starvation freedom under sustained evaluator overload. ARCHITECTURE.md and VERIFICATION.md own this policy and its evidence obligations.

## Accepted amendment: stable workflow authoring

Accepted 8 September 2026. Workflow authors derive operation identities and inputs from stable source identities, arguments and original recorded results, not branch completion order. Cross-branch inputs use explicit joins and stable ordering. Ordinary JavaScript and local mutation remain available. Existing canonical binding checks reject changed reuse of a key; they do not detect every authoring error, particularly an unintended distinct new key. No historical promise-delivery replay, static mutation policing or new runtime mechanism is selected. This clarifies the supported composition contract alongside independent branch progress and fresh crash recovery; ARCHITECTURE.md, PRODUCT.md and VERIFICATION.md own the requirements.

## Accepted amendment: returned Promise owns workflow completion

Accepted 8 September 2026. The workflow entry function's returned value or Promise determines completion. A pending root suspends with complete encountered unresolved calls; a fulfilled root supplies output without waiting for unrelated calls. Root rejection follows existing failure handling. Calls encountered in a successful evaluation remain subject to full validation and ordinary independent admissions before terminal output publication. Admitted Session work continues after workflow completion without implicit cancellation; later results do not reevaluate the terminal Run. Unawaited JavaScript continuations are not retained after evaluator exit. Authors await or join required follow-up work. No separate DAG, Promise-reachability analysis, blanket unawaited-call error or detached workflow lifecycle is added. ARCHITECTURE.md, PRODUCT.md and VERIFICATION.md own the contract and required evidence.
