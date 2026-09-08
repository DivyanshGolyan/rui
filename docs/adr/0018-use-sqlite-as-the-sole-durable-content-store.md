---
status: amended by ADR-0019
---

# Use SQLite as the sole durable content store

Every recoverable OnePage-owned semantic or content byte lives in the Host Store's one SQLite database. Subscription credentials are non-semantic security material delegated to the OS credential store and are never Session, Conversation, Turn, Run, or effect authority. Immutable content records bind scope, logical reference, exact length, typed digest, and payload. The Storage Owner imports content through bounded windows in the same short transaction that creates its first canonical Conversation, User Message, Completion, Resolution, permission, Turn, Run, or output reference. External work holds no SQLite transaction; bounded unlinked scratch has no durable identity and disappears on close or process exit. V1 adds no external blob tree, second semantic store, background writer, cross-store publication, compression, deduplication, or custom VFS.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes this record’s per-try authority and final-content ownership. Use the current [execution contract](../architecture/execution.md) and [verification](../verification/execution.md); retain the original wording as history.

## Accepted amendment — disposable tool-output paths, 7 September 2026

A Spillover Tool Result saves its bounded excerpt, command outcome, omission notice and ordinary temporary-file path in canonical Conversation. The complete file is disposable, shared-budget temporary content, not another durable content store or durable Content Reference. The Agent reads selected output with the existing Bash tool; FIFO cleanup or Host exit/crash may make the file unavailable without changing the saved result or authorizing automatic old-command replay.

This is a scoped exception to immediate unlinking for tool output kept for optional later reading. Other private scratch and all required durable effect evidence retain their existing contracts. The Host must never reuse a published path for different output; external replacement has ordinary filesystem behavior and does not change the saved canonical result. Named-file access/cleanup must still satisfy bounded ownership and byte accounting; see [tool output and spillover](../architecture/execution.md#tool-output-and-spillover). No production implementation is claimed.
