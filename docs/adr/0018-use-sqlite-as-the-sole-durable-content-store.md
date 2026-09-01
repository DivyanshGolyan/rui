---
status: amended by ADR-0019
---

# Use SQLite as the sole durable content store

Every recoverable OnePage-owned semantic or content byte lives in the Host Store's one SQLite database. Subscription credentials are non-semantic security material delegated to the OS credential store and are never Session, Conversation, Turn, Run, or effect authority. Immutable content records bind scope, logical reference, exact length, typed digest, and payload. The Storage Owner imports content through bounded windows in the same short transaction that creates its first canonical Conversation, Completion, Resolution, interaction, Turn, Run, or output reference. External work holds no SQLite transaction; bounded unlinked scratch has no durable identity and disappears on close or process exit. V1 adds no external blob tree, second semantic store, background writer, cross-store publication, compression, deduplication, or custom VFS.
