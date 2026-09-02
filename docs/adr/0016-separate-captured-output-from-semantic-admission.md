---
status: superseded by ADR-0021
---

# Separate captured model output from semantic admission

OnePage streams one bounded provider outcome into Host-owned provisional capture and returns one typed candidate-or-failure outcome. No SQLite transaction spans the network call. The Storage Owner atomically imports complete captured content and its Attempt Completion; a later bounded semantic-admission transaction validates that evidence and creates the model Operation Resolution, Conversation entries, input request, Turn Outcome, or child Action Operations. Crash before Completion publication leaves no recoverable capture and may require a replacement Attempt with duplicate-work disclosure. Crash after publication reuses the same evidence without provider redispatch. Provider capture is evidence, never Conversation or execution authority.
