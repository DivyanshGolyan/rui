---
status: superseded by ADR-0021
---

# Separate captured model output from semantic admission

OnePage streams one bounded provider outcome into Host-owned provisional capture and returns one typed candidate-or-failure outcome. No SQLite transaction spans the network call. The Storage Owner atomically imports complete captured content and its Attempt Completion; a later bounded semantic-admission transaction validates that evidence and creates the model Operation Resolution, Conversation entries, input request, Turn Outcome, or child Action Operations. Crash before Completion publication leaves no recoverable capture and may require a replacement Attempt with duplicate-work disclosure. Crash after publication reuses the same evidence without provider redispatch. Provider capture is evidence, never Conversation or execution authority.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes historical Attempt/Completion authority, separate Resolution identity and Completion-owned final-content bindings in this record. Operations own current execution/retry facts, immutable final Resolution values and required final content by reference. Existing effect-specific uncertainty, request freezing, accepted continuation, public replay and bounded-memory guarantees remain in force. The original text remains historical decision evidence; the current [execution contract](../../ARCHITECTURE.md#host-runtime-execution-and-settlement) and [verification requirements](../../VERIFICATION.md#operations-attempts-and-recovery) govern implementation.
