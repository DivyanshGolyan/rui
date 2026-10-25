# Host execution ownership

This is the L3 design note before the slot-ownership replacement. The replacement is not implemented or qualified by this note. [Architecture](../ARCHITECTURE.md#capacity-ownership) remains the runtime contract.

## The audit found duplicate authority, not a reproduced race

The [audit](https://ampcode.com/threads/T-01a1500e-2a79-72ed-9be6-b9e1b1a69b57) inspected base `cdad5aaf4dc43cbb7864f0fa0a4a08bf4f25a8ff`. `NativeTurn.firstFreeSlot` selects an `ExecutionSlot`, then `CustodyPool.reserve` independently selects a custody record. Both retain the Attempt binding. Admission, completion, and cleanup must update both owners. `checkSlotCustodyAgreement` detects disagreement after complete transitions, including orphaned custody.

Those checks document a maintenance burden. They do not prove a cancellation race or a resource leak. Replacing them needs ownership evidence, not a claim that the existing code is broken.

## Transfer interpretation precedes the ownership replacement

The first layer separates transfer failure decisions and provider interpretation from effects:

- `provider.zig` owns the HTTP/2 Client, response capture and sealing, sealed response lifetime, and transport observations.
- `model_adapter.zig` owns Codex interpretation. Its closed result contains validated output or rejection facts. `invalid_output` and `context_overflow` do not decide whether a Turn ends.
- `execution.zig` classifies transfer failure facts without I/O. It distinguishes answered HTTP failure, unanswered local capture failure, and canonical request-source corruption.
- `server.zig` claims terminal delivery, invokes Store settlement, fences dispatch, and disposes resources. Store owns retry allowance and Turn scheduling.

The schema-support check runs before metadata acquisition. Interpretation borrows the sealed source and metadata writer through validation. Success retains both resources through Store import and commit or rollback. A returned decision never releases capacity.

## One record owns reservation through reclamation

The proposed final owner is a startup-fixed, slot-indexed record array in the execution owner. A token addresses that same array index and generation. Admission scans that array once. There is no independent free-slot selection or second custody pool.

Each record contains its generation and one tagged state:

- `free` has no owner or payload.
- `reserved` holds an admission-local credit but no Attempt binding.
- `owned` holds one typed model or Action binding, one-shot launch authority, terminal-delivery authority, and the current resource payload.

The payload distinguishes admission-local work, model preparation, authentication, provider transfer, Bash preparation, running Bash, and retained cleanup. The model or Action binding belongs to the enclosing owner, not every payload. Resource objects may retain their own identity where their existing interface requires it, such as the provider capture's immutable Attempt identity. That identity must not become a second admission or release authority.

`owned` includes the admission-local interval before a preparation payload exists. Today that interval legitimately has attached custody and a free slot. The replacement must represent it directly rather than forbid it with an assertion.

The execution thread alone mutates records. Concurrent inspection reads bounded atomic aggregate observations, not the resource union. `held` excludes reserved admission probes, as the current public inspection contract requires. Those aggregates grant no reservation or launch authority. Their updates belong to the same transition methods as the record changes.

This replaces a duplicated ownership model. Merely nesting the existing custody and slot arrays in another structure would retain the problem.

## Transitions retain separate semantic and physical facts

Every edge has one record transition owner:

| Edge | Required result |
| --- | --- |
| Free to reserved | Increment the generation and return a token for the selected record. No Attempt exists yet. |
| Admission has no work or rolls back | Return that reservation to free without a binding, launch, or saved failure. |
| Admission commits | Consume the typed permit once and bind the same record. Failure after commit cannot refund allowance. |
| Preparation advances | Replace only the payload after its previous borrower has retired or transferred ownership. |
| Launch | Check generation and the complete typed binding, consume launch authority once, then enter the existing Store handoff and Host launch gate in that order. |
| Terminal delivery | Claim once while applicable. Store rechecks control supersession inside settlement. A failed save fences dispatch, not cleanup. |
| Cancel or shutdown before launch | Suppress launch and dispose preparation or the returned authentication request through its current owner. |
| Provider cancellation | Cancel the stream, which leaves nothing of it outstanding, then dispose the transfer at once. No ordinary shutdown settlement is added. |
| Semantic completion with resources held | Close terminal-delivery authority while retaining the payload, capacity, scratch charge, and cleanup obligation. |
| Cleanup fails | Keep the same record and actionable resources. Existing low-frequency retry remains responsible for progress. |
| Cleanup succeeds | Retire the payload and release the record once, before publishing `cleanup_completed`. |
| Stale or foreign token | Reject without changing the current record or consuming its launch or delivery authority. |

Bash delivery closure does not establish process reap, original-group absence, pipe retirement, or scratch reclamation. Its existing lifecycle owner establishes those facts independently. Model semantic completion likewise does not establish retained-file removal. Immediate retirement still needs a complete transition even when no delayed payload remains.

The HTTP/2 Client holds the Transfer's stream by address from `Transfer.start`. The record array must never move or resize. Its provider union arm remains active until the stream is collected or cancelled. A transition must not copy a live transfer to a temporary or initialize it before installing its final union arm.

The Store lease outlives execution drainage and intake drainage. Infrastructure shutdown requests every effect's retirement before waiting for any one provider or retained file. A peer-held provider stream cannot delay a sibling Bash stop request.

## Qualification follows the edges

The owner tests must cover each transition above through the production record interface. Include both model and Action bindings, every identity field, stale tokens after reuse, double launch, double terminal delivery, no-work admission, rollback, and committed-but-unprepared failure. For retained cleanup, include failed removal followed by success, empty charged owners, Bash cleanup, and admission-local Action cleanup.

Native checks retain the existing owner boundaries. The server tests cover callback identity, delayed authentication return, cleanup publication, control supersession, and both admission orders during shutdown. Dispatch, Control, Bash recovery, descriptor-capacity, and H2 fixtures cover real Store handoffs, capture drainage, saved-result identity, exact custody and scratch release, and independent sibling progress. A value test cannot replace these checks.

Each new owner-boundary regression needs a targeted mutation that fails at the intended assertion. Particularly important mutations release a record before capture drainage, accept a stale generation, report cleanup before freeing the record, or release accounting after an unconfirmed unlink.

The maintained [selector](../tests/ci/select_tests.py) sets the minimum gates. The final assembled candidate also needs exact-head hosted Linux and macOS checks and both installed-release upgrade jobs. Local compilation, skipped native assertions, prior-head acceptance, and a same-family review do not establish readiness. Cross-family review must use capacity independent of the renderer allocation.

Record layout measurements must report `@sizeOf` for the old custody record plus slot and the proposed complete record, multiplied by configured Active Capacity. Distinguish that fixed storage from payload allocations, HTTP/2 and TLS storage, and process physical footprint. No memory improvement is claimed before measurement.

## Integration and limits

L1 owns Store, provider-output grammar, and the output-format extraction. L3 adopts its exact green output-format checkpoint before changing server type references. The clean Store failure-facts interface must replace the old settlement input atomically with its callers. L2 owns the clean ScratchBudget API. L3's provider capture and request writer require reclaim-capable `allocate`, not accounting-only `reserve`.

The renderer owns all reserved frontend, terminal, selector, workflow, and shared-fixture files. This design does not require editing them. A needed overlap must be resolved with its owner before editing. No personal Mac, live Store, renderer Claude allocation, or main write belongs to this work.

Divyansh's default is no backward compatibility. This design adds no old reader, migration, dual format, legacy identity preservation, deprecated alias, or mixed-client protocol support. An incompatible format needs its actual version marker changed and explicit mismatch rejection. It does not justify a compatibility layer without Divyansh's authorization. The current transfer extraction changes no persisted format or public wire meaning.

The source principles were read at cursor/plugins commit `0b8e952052d482ee6de06deebf14d590d77b1b34`:

- [Sequence verifiable units](https://github.com/cursor/plugins/blob/0b8e952052d482ee6de06deebf14d590d77b1b34/pstack/skills/principle-sequence-verifiable-units/SKILL.md).
- [Fix root causes](https://github.com/cursor/plugins/blob/0b8e952052d482ee6de06deebf14d590d77b1b34/pstack/skills/principle-fix-root-causes/SKILL.md).
- [Prove it works](https://github.com/cursor/plugins/blob/0b8e952052d482ee6de06deebf14d590d77b1b34/pstack/skills/principle-prove-it-works/SKILL.md).

An independently green transfer layer and this design note are a valid partial result. They do not qualify an unimplemented ownership replacement.
