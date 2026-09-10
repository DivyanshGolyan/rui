# Calculations inside Session core transactions

Reviewed 2026-09-10 using the supplied *Boundaries* talk. Design review and implementation guidance proposal; no normative amendment or production changes.

**Subsequent decision, 2026-09-10:** the user rejected automatic instruction coalescing. [Preserve every explicit instruction update](instruction-update-history.md), including B and the second A in A -> B -> A. The content-suppression calculation used as an example below is historical and must not be implemented. Independent transactional ownership and testing guidance remains applicable.

## Conclusion

Keep [one cohesive transactional operation](transactional-operations.md) per meaningful durable change. Extract a private calculation when it has substantial independent behavior and can accept the facts it needs as values. The calculation may run inside the transaction that reads those facts and commits its consequences.

```text
Core operation owns one transaction
  -> read applicable canonical facts
  -> calculate privately where useful
  -> apply guarded writes and constraints
  -> commit
```

This preserves isolation without introducing a public Session snapshot, generic transition object, mutation interpreter or second state model. A private helper's return value is a calculation, not permission to apply stale facts later. Neither a new function for every condition nor a complete pure Session engine follows from the talk.

## Contract precedence

Use the local accepted [Session API](session-core-api-contract.md), [request identity](shared-request-identity.md), [transactional operation](transactional-operations.md) and [Workflow Runtime](evaluator-coordinator-boundary.md) decisions. Preserve the published [Operation-owned execution model](https://github.com/DivyanshGolyan/onepage/issues/106#issuecomment-5556976932): current execution/retry facts and immutable final Resolution/content belong to the Operation; Execution Evidence is transient. Historical durable Completion chains, keyless direct admissions and mandatory classifiers are superseded by those accepted owners. See the [provider review](provider-validation-settlement-review.md#contract-precedence) for the identified baseline conflict.

## Strongest candidate: constructing a model request

A Session has a current configuration, an already-applied instruction history, accepted model/tool results and possibly pending messages. A new assistant-response request must select a compatible replay recipe and bind its exact inputs.

Useful private calculations include resolving sparse settings under a selected revision and checking provider compatibility from fixed source/target facts. Selecting pending instruction updates uses canonical admission/inclusion identity and preserves every explicit update, including equal text. Provider wire rules remain owned by the provider adapter; the core owns structural lineage and source selection. None of these calculations needs to open a network connection or mutate the Session while being tested.

### Historical example — rejected

The original review proposed suppressing A -> B -> A when B had not entered a request. The user rejected that policy: both B and the second A enter model-visible history. This rejected example is retained only to explain the subsequent [instruction-history amendment](instruction-update-history.md), not as implementation guidance.

The transaction still owns reading current configuration, deriving the last included instruction, ordering applicable messages/tool results, selecting the source frontier and writing new projections, instruction entry, Operation and frozen manifest together. Rollback publishes none of those new facts. Actual request materialization and provider dispatch remain outside that transaction under the existing execution contract. A retry reuses the admitted manifest rather than recalculating from later settings.

Do not collect the whole Conversation into a value just to make a helper pure. Use bounded queries, scalar facts and immutable content references. SQL should continue to perform useful existence, ordering and selection work; pure calculation is not a reason to replace an indexed query with an in-memory history traversal. Large-content comparison or rendering retains explicit bounded readers rather than being mislabeled as I/O-free.

## Other decisions: extraction must earn its place

| Decision | Potential private calculation | What stays in the owning transaction |
| --- | --- | --- |
| Retry eligibility | Substantial classification, delay or checked arithmetic using supplied policy/current facts; supply time explicitly when needed | Current Attempt identity, unresolved/applicable work, conserved allowance, retry fact updates and admission |
| Assistant-only settlement | A nontrivial terminality rule over supplied obligation facts, if useful; a single simple condition can stay inline | Read pending messages and other obligations, accept result, insert final outcome if eligible and release occupancy atomically |
| Configuration update | Syntax/value checks and compatibility rules over explicit proposed/existing facts | Read current configuration, enforce keyed replay, append applicable changes and record the committed answer |
| Tool permission admission | Fixed proposal validation; choosing between `ask` and `bypass` alone does not warrant a policy framework | Read current mode, bind exact descriptor/provenance and save Permission Request or Authorization with child admission |
| Message admission | Content syntax and canonical request binding | Original-answer lookup, current Session occupancy/applicability and atomic message/work binding |

These are candidates, not required new modules. Keep small direct checks inline when extraction would merely move a branch and duplicate its inputs. An independently tested predicate cannot establish that the query feeding it selected complete, current facts; that remains integration evidence.

## Three interface rules worth making explicit

### Recover the original keyed answer before reevaluating current conditions

Parse the usable request identity and canonical input sufficiently to verify matching reuse. If the binding already exists, return its original answer; reject changed-input reuse without replacing it. Only a fresh request evaluates current-state admission conditions.

For example, configuration request K changed instructions to B. Another request later changes them to C. Retrying K returns its original answer and leaves C active. Similarly, a saved rejection remains that rejection even if a fresh request would now succeed. A shared preflight helper must not turn replay into a new decision against current settings.

This is not permission to skip current caller authority or accept malformed envelopes. The original-answer rule governs the already-bound operation's admission meaning, under the existing access contract.

### Keep the read, calculation and write under the same transaction owner

A calculation such as “this assistant response can finish the Turn” is valid only for the facts supplied. When a message commits first, settlement must see it and leave the Turn unfinished. When final settlement commits first, later message admission sees released occupancy and follows the current Session contract. Testing the helper alone cannot prove either transaction order.

Do not expose a caller-invoked `canAccept`/`apply` pair that requires the caller to preserve freshness. Nor introduce whole-Session revision tokens solely because a private helper returns a value. Existing serialized ownership and actual transactional checks retain this responsibility.

### A computed consequence is not a committed fact

A prospective manifest, authorization choice or retry time cannot escape as authoritative if writes or commit fail. Commit uncertainty must be resolved using actual transaction/recovery state. Database rollback does not release temporary capacity reservations automatically; the invocation must unwind those resources under the existing ownership rules.

Required follow-up remains discoverable from durable facts. Saved permission can survive a lost notification. An admitted uncertain tool cannot be redispatched merely because a computed dispatch description can be reconstructed. The existing one-shot dispatch and tool no-replay rules remain distinct from public request idempotency.

## Test at the smallest truthful interface

Use value tests for calculations that merit extraction: instruction-content transitions, supported compatibility combinations and nontrivial retry arithmetic. Expected results should follow the contract independently of the implementation. Avoid mock database call sequences or tests that merely repeat a helper's condition.

Use actual SQLite integration tests for original-answer replay, current fact selection, constraints, rollback, immutable result/content publication, configuration/request interleavings, both message/final-settlement orders and reservation cleanup. Fixtures can create only the relevant durable state; they need not boot provider transport or workflow evaluation. Such tests are integration tests but need not be whole-system tests. Production timing evidence is still required before claiming they are fast.

Fresh-process tests establish what survives a crash. External-effect tests establish dispatch and cleanup. Pure calculations, transaction fixtures and process tests prove different obligations; none substitutes for the others.

## Recommendation for the design

The Session core needs no new architectural layer. During implementation, look first at request construction for a useful calculation interface, then extract other logic only when complexity or genuine reuse warrants it. Keep admission and settlement as small public operations that hide queries, transactions and resource obligations.

The historical source still exposes ledger-style facts and transactions in `session_transition.zig` ([source](../../src/session_transition.zig)); it is not implementation evidence for the accepted relational/current-Operation model. This review changes no source and runs no production tests. It clarifies where isolated computation can live without reviving the previously rejected mandatory classifier design.
