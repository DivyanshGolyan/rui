---
status: accepted
---

# Use relational Session and Turn facts as authority

OnePage stores one linear Conversation and its Session, Turn, Operation, Attempt, Completion, Resolution, interaction, and context relationships directly in SQLite. These canonical rows and constraints are semantic authority; a generic Session Ledger, persisted reducer image, continuation blob, cached lifecycle phase, or resident Session graph would duplicate facts that SQLite can commit and query directly. Turn Condition and observer views are derived from bounded queries. This flag-day V1 decision supersedes ADR-0001, ADR-0007, and ADR-0009 and amends ADR-0018; unreleased databases and fixtures are recreated rather than migrated through a compatibility path.
