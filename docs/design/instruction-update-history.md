# Preserve explicit instruction updates

Accepted in architecture discussion on 2026-09-10. Documentation only; no production implementation or provider qualification is claimed.

## Decision

Preserve each successfully admitted explicit instruction update in model-visible history, in configuration admission order. OnePage does not coalesce intermediate updates, remove reversals or compare content to decide whether the user's update deserves an entry. A -> B -> A includes B followed by the second A, even when no model request used B alone. A -> B -> C includes B then C.

A fresh explicit instruction update is an update even when it repeats the current text. Reusing the same configuration request identity recovers the original answer and does not create another update. Omitting instructions, or changing only Permission Mode, effort or output schema, creates no System Instruction. No new coalescing setting is introduced.

## Ownership and inclusion

Session configuration records each explicit instruction update with its existing revision/request provenance and immutable content reference. Reuse identical content bytes without removing distinct updates. Other settings retain their existing configuration semantics; this decision does not turn every Host setting into a model-visible message.

At the next fresh assistant-response request admission, select every not-yet-included instruction update through that transaction's committed configuration view. After preceding Tool Results and applicable User Message projections, append those System Instructions in admission order at the established provider-supported position. Validate the prospective replay recipe and commit the entries, projections, model Operation and frozen manifest together. This retains the existing placement rule; it does not promise wall-clock interleaving of instructions with independently projected messages.

Each entry references its originating update. Derive inclusion from those canonical references and the initial baseline, including entries covered by compaction. Do not use text equality as inclusion identity or add a separate pending queue, applied flag or receipt. Exact columns and bounded traversal remain implementation work.

The request uses the latest selected configuration while its instruction history contains all included updates in order. An already-admitted request and its replacement Attempts keep their frozen inputs. Later changes wait for a fresh request. Configuration alone starts no model work. Recording an update is distinct from its inclusion in a request, and inclusion is not proof of provider consumption.

## Recovery and compaction

Rollback before request admission appends none of the prospective entries; the independent configuration updates remain eligible for later inclusion. After request commit, recovery reuses its manifest and entries without appending them again. Failure of the admitted model request does not erase its instruction history.

Pre-admission compaction continues to use already-included context, leaving all pending instruction updates for the next assistant-response request. If further updates arrive during compaction, that next request includes them too in order. Compaction after an admitted overflow includes the entries already committed. Compaction does not erase canonical Conversation or allow old updates to be included twice. Required provider continuation and instruction meaning remain governed by the accepted compatibility contract.

More updates can mean more model input. Existing bounded materialization, resource checks and compaction apply; OnePage must not silently discard pending updates to make a request fit.

## Required examples

- A -> B -> A and A -> B -> C before a request include both updates in order.
- A fresh explicit A -> A update gets an entry; replay of its request key gets no duplicate.
- A configuration patch omitting instructions creates no instruction entry.
- Request/entry rollback preserves all pending updates; lost reply after commit reuses the exact manifest.
- Changes during a request or tool wait do not rewrite admitted inputs or split a tool call/result pair.
- Changes during compaction remain pending and enter the next fresh request in order.
- A compaction-covered instruction stays included; content reuse cannot collapse distinct updates.

## Superseded rule

This replaces the net-content comparison in the historical [first-inclusion trace](system-instruction-first-inclusion.md) and [Session interface exploration](session-workflow-interface.md). The [Session core calculation review](session-core-calculation-review.md) originally used suppression of A -> B -> A as an example; that policy is rejected. Keep its independent transactional-ownership guidance. The owning [architecture](../../ARCHITECTURE.md#sparse-context-and-exact-model-requests), [product](../../PRODUCT.md#conversation), [terminology](../../CONTEXT.md) and [verification](../../VERIFICATION.md) carry this amendment.
