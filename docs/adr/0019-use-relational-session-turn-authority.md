---
status: accepted
---

# Use relational Session and Turn facts as authority

OnePage stores one linear Conversation and its Session, User Message, Turn, Operation, Attempt, Completion, Resolution, permission, and context relationships directly in SQLite. These canonical rows and constraints are semantic authority; a generic Session Ledger, persisted reducer image, continuation blob, cached lifecycle phase, or resident Session graph would duplicate facts that SQLite can commit and query directly. Turn Condition, unprojected User Messages, and observer views are derived from bounded queries. This flag-day V1 decision supersedes ADR-0001, ADR-0007, and ADR-0009 and amends ADR-0018; unreleased databases and fixtures are recreated rather than migrated through a compatibility path.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes historical Attempt/Completion authority, separate Resolution identity and Completion-owned final-content bindings in this record. Operations own current execution/retry facts, immutable final Resolution values and required final content by reference. Existing effect-specific uncertainty, request freezing, accepted continuation, public replay and bounded-memory guarantees remain in force. The original text remains historical decision evidence; the current [execution contract](../../ARCHITECTURE.md#host-runtime-execution-and-settlement) and [verification requirements](../../VERIFICATION.md#operations-attempts-and-recovery) govern implementation.
