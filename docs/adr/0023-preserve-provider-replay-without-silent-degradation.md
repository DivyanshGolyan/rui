---
status: accepted
---

# Preserve provider continuation without duplicate replay authority

For implementation, read the consolidated [model-output contract](../../ARCHITECTURE.md#model-output-and-multiple-tool-calls) and [execution ownership](../architecture/execution.md). The record below preserves the original decision and later amendments; superseded wording is historical.

## Accepted amendment — System Instructions in Conversation

The [Session decision](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667) adds System Instruction as a fifth Conversation Entry kind. Appended instructions are visible alongside user messages, assistant replies, and tool results, with immutable ordering and content. They are host/operator inputs, not model-output projections, and grant no Action Authorization. Provider-only reasoning remains private Completion-owned content. First inclusion commits atomically with its assistant-response request; exact storage/wire encoding remains implementation work. This supersedes only the four-kind enumeration in the original decision below; the continuation ownership and no-duplicate-content rules remain in force.

## Accepted amendment — rejected output and diagnostics

The [local diagnostic contract](../../ARCHITECTURE.md#local-diagnostics-and-application-state), recorded during the [execution-model comparison](https://github.com/DivyanshGolyan/onepage/issues/105), replaces the permanent full-evidence requirement for unsupported rejected output below with a bounded typed rejection and necessary producing-request/causal provenance. Additional raw detail belongs to explicit bounded diagnostic capture. Accepted output, unknown fields inside accepted replayable items, private continuation, exact bytes and their canonical references retain their existing requirements. Execution scratch remains non-authoritative and is released normally; diagnostic capture grants no replay or publication authority. This changes rejected-evidence retention, not execution representation or accepted-output ownership.

## Original decision

Conversation remains OnePage's complete four-kind semantic history, but visible Conversation alone may be insufficient to preserve provider reasoning continuity. Each model Attempt Completion therefore owns one ordered canonical set of Model Output Items. Each item retains its supported semantic fields, provider-only continuation fields—including opaque or encrypted reasoning and compaction values—and response-evidence fields exactly once. Conversation references the same supported semantic content. A provider adapter derives any later replay-input view by stripping response-only or non-replayable fields; OnePage stores neither a Provider Replay Receipt nor a complete serialized request body as second authority.

Unknown open fields inside a known record are preserved. An unknown consequential union discriminator is preserved as Completion evidence but resolves as `unsupported_provider_output`; it publishes no Conversation, continuation, or effect consequence. Generic content reads never expose private continuation material. Raw HTTP or SSE capture remains temporary scratch and is deleted after successful canonical import.

A Model Request Manifest freezes the provider protocol operation, requested concrete model, rendered instructions, Tool Catalog, replay format, behavior-affecting protocol options, limits, and one total ordered Model Context over canonical host inputs and accepted model Operation Resolutions. Replacement Attempts reconstruct the same request semantics from those sources. Core validates structural recipe integrity, including identity, ordering, lineage, suffix completeness, content presence, digest, and supported stored format. Provider wire compatibility is a pure adapter-owned predicate over immutable source and target facts; OnePage persists no validity or compatibility-policy version. Codex V1 begins with the proven same-concrete-model rule while recording requested-model binding and served-model evidence; broader compatibility requires adapter fixtures.

An accepted compaction model Operation Resolution may serve as a derived Compaction Base. Its source manifest defines its complete covered frontier and lineage; its selected Completion owns the canonical replacement output. There is no separate Compaction Checkpoint relation. Later requests select the newest accepted base in the current lineage first and then validate that exact base. A failed or unresolved compaction does not displace it, and missing, corrupt, unsupported, or incompatible selected material fails as `continuation_unavailable` rather than selecting an older base or falling back to visible Conversation.

OnePage never silently drops reasoning, asks a provider to drop incompatible blocks, or reconstructs an apparently equivalent continuation from visible Conversation alone. V1 implements this contract for Codex/OpenAI Responses output; a later Claude adapter may add its prefix-binding rules without changing Core ownership. This amends ADR-0005, ADR-0012, and ADR-0020.

## Accepted amendment — Operation-owned execution and results

[ADR-0026](0026-let-operations-own-current-execution-and-final-results.md) supersedes this record’s per-try authority and final-content ownership. Use the current [execution contract](../architecture/execution.md) and [verification](../verification/execution.md); retain the original wording as history.