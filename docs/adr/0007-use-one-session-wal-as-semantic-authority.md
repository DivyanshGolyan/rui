---
status: superseded by ADR-0009
---

# Use one Session WAL as semantic authority

Each Session has one append-only semantic ledger that orders every fact required to reconstruct its lifecycle, including task admission, model and Action Operation admission, Attempts, Authorization, Results, Conversation advancement, cancellation, and Outcome. ADR-0009 replaces the physical per-Session WAL with normalized ledger rows in the Host Store, and ADR-0018 requires immutable content and its first durable reference to commit in the same SQLite transaction. Committed Core State, runnable indexes, manifests, and observer read models are rebuildable views at a named ledger sequence.

The Session WAL replaces the effect-only operation journal as authority; it is not a third history and does not duplicate Conversation content. Conversation remains the immutable model-visible tree, while the WAL establishes when its entries become authoritative for a Session. Streaming deltas, terminal rendering, diagnostics, scheduler polling, and raw payload bytes are excluded because they are not semantic lifecycle facts.

One prepared transition is one bounded SQLite transaction, so recovery never exposes only part of a semantic change. The Storage Owner may atomically import immutable Result content and publish a bound envelope in the non-authoritative Completion Inbox before Harness receives the notification; Harness alone validates that evidence and commits the terminal Result transaction that advances the Session.
