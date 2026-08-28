# Provider and transcript abstractions in DeepSeek Harness, pi, and OpenCode V2

Research date: 2026-08-27

- DeepSeek Harness revision: [`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`](https://github.com/deepseek-ai/deepseek-harness/tree/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e)
- pi revision: [`ccfe79ed238674f760c986e3a61493aab794000a`](https://github.com/badlogic/pi-mono/tree/ccfe79ed238674f760c986e3a61493aab794000a)
- OpenCode V2 revision: [`42422a1e036fe97ad74048810368b36a2ea2edbb`](https://github.com/anomalyco/opencode/tree/42422a1e036fe97ad74048810368b36a2ea2edbb) (`v2` branch)

## Verdict

Yes: OnePage should have a house transcript and convert at the edges.

Provider implementations need different authentication, credential refresh, endpoint and model discovery, request serialization, HTTP/SSE/WebSocket mechanics, error classification, and replay quirks. They should not own different durable Conversation formats or different Session recovery rules. DeepSeek Harness, pi, and OpenCode V2 all converge on that split:

1. store provider-independent messages or semantic session events;
2. derive the bounded model context from that durable history;
3. lower it into the selected provider's wire format;
4. normalize the provider stream back into house events and content;
5. retain provider-private replay data only as optional, namespaced metadata beside authoritative canonical content.

OnePage already has the right high-level ownership: an immutable Conversation, a bounded Model Context projection, and a deliberately narrow `Provider`. Its current `ONEREQ` and `model_protocol` formats are not yet a sufficient semantic house protocol for a live provider, however. `ONEREQ` frames Conversation entries as `kind + raw blob`, while an `assistant` blob can mean final text, encoded Bash arguments, or patch bytes. A provider adapter would therefore have to understand OnePage's tool-storage encodings and infer call/result pairing. The seam should be deepened before the first live adapter, not replaced with a provider-specific transcript.

## Which DeepSeek source this means

The exact first-party harness is [`deepseek-ai/deepseek-harness`](https://github.com/deepseek-ai/deepseek-harness). That is the most likely meaning of “the DeepSeek harness”: it is published by the DeepSeek organization and presents itself as a complete agent harness, including a direct DeepSeek adapter and a pi-backed multi-provider adapter.

There is one ambiguity worth recording. “DeepSeek harness” can also informally mean a harness using DeepSeek's OpenAI-compatible API, such as pi or OpenCode. This note uses the official DeepSeek Harness repository because the comparison named a harness alongside pi and OpenCode, and because its adapter architecture is directly relevant.

The pi repository also has a naming transition in progress. The requested canonical source is Mario Zechner's [`badlogic/pi-mono`](https://github.com/badlogic/pi-mono); at the pinned revision, packages and documentation use the `@earendil-works` namespace. This note uses the pinned `badlogic/pi-mono` source rather than the older Pi fork already cited elsewhere in this repository.

## Comparative shape

| Concern | DeepSeek Harness | pi | OpenCode V2 | OnePage implication |
|---|---|---|---|---|
| Durable authority | Typed append-only Session events; messages are derived | Append-only JSONL tree; context is projected from one branch | Durable Session events/messages in SQLite; model messages are projected | Keep Conversation and recovery facts authoritative |
| House message format | Role, typed content blocks, source/provenance | User, assistant, tool-result messages with typed content | Durable `SessionMessage` plus a separate canonical LLM `Message` | Add a semantic request projection above blob framing |
| Provider conversion | Adapter serializes house messages | API adapter transforms messages before wire serialization | Protocol lowers canonical LLM messages | Conversion belongs wholly at the edge |
| Tool correlation | Canonical `CallId` on call and result | Canonical `id` / `toolCallId`, remapped if a protocol restricts it | Canonical tool-call ID on call, input stream, and result | Persist an explicit stable call ID and tool name |
| Streaming | Normalized block start/delta/end, usage, finish | Normalized text/thinking/tool start/delta/end, done/error | Normalized `LLMEvent` union, then durable publication | Normalize outside Core; commit only complete semantic values |
| Authentication | Credential service/plugin; transport resolves per request | Provider auth contract plus app-owned credential store | Credential records/services and protocol auth are outside messages | Keep OAuth/key storage, refresh, and catalog out of Core and Session content |
| Provider-hosted IDs | Opaque replay envelope and request diagnostics | Optional response ID/deferred handle | Namespaced provider state/metadata | Optional optimization/provenance, never resume authority |
| Model/provider switch | Request selects route; incompatible replay state is stripped | Stored model changes; transformer degrades incompatible fields | Stored model selection; projection gates provider state by compatibility | V1 can fix one model per Session; format should not hard-code it |
| Escape hatch | Adapter-private replay envelope | Signatures, response ID, raw stop reason, options hooks | `providerMetadata`, `native`, provider state | Namespaced, versioned, optional, discardable |

## DeepSeek Harness

### Canonical messages and edge conversion

The LLM package says its types are the “canonical provider-neutral message and streaming vocabulary” and that adapters alone translate provider wire messages ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/types.ts#L1-L4)). Its content vocabulary includes text, reasoning, image, tool call, and tool result. A tool call carries a provider-issued `CallId`, name, and raw JSON arguments; its result names the same `CallId` and adds content plus an error flag ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/types.ts#L53-L105)).

A fully assembled `GenerateOptions` selects provider and model while carrying canonical messages, system prompt, tools, sampling settings, and optional model-hidden Session identity ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/types.ts#L340-L376)). The direct DeepSeek adapter then serializes this request and translates DeepSeek SSE responses; its own header describes the adapter as transport-only and says the registering plugin owns connection validation and credential policy ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm-deepseek/src/adapter.ts#L1-L7)).

### Stream normalization and failure vocabulary

All adapters emit the same `StreamChunk` union: block start, text/reasoning/tool deltas, block end with the assembled canonical block, normalized usage, and one terminal finish. Adapter exceptions are normalized into terminal error or aborted finishes before consumers see them ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/types.ts#L304-L324)). Provider failures also have a shared machine code, HTTP status, retry delay, and optional upstream request ID ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/types.ts#L39-L51)).

The direct adapter documents several provider-specific rules—usage can arrive on different SSE chunks, DeepSeek's `off` effort has a distinct wire representation, reasoning must be passed back on tool turns, and cache fields require provider-specific accounting—but none of those rules change the canonical transcript ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm-deepseek/README.md#L93-L104)).

### Credentials, hosted identity, and replay

The adapter resolves validated connection facts once per operation and resolves the referenced key per request. Configuration stores the credential reference rather than a literal key ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm-deepseek/src/adapter.ts#L64-L120)). A harness Session ID is placed in a request header, outside model-visible content ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm-deepseek/README.md#L87-L99)).

Canonical assistant content is accompanied by provider/model provenance and optional adapter-private replay state ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/message.ts#L7-L29)). The replay envelope is explicitly opaque to the harness and can carry response-level and block-aligned private metadata ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/types.ts#L283-L302)). On a later call, replay state is retained only when the same adapter instance owns both the historical and target provider routes; otherwise it is removed while the canonical message remains ([source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/index.ts#L877-L890), [source](https://github.com/deepseek-ai/deepseek-harness/blob/b150a551b8d465e31e418e1b2eaf5e79bbb7d28e/packages/llm/llm/src/index.ts#L974-L983)). This is the cleanest of the three examples of “canonical content plus discardable native replay.”

## pi

### Canonical messages and provider runtime

pi's `Context` is a system prompt, canonical messages, and tools. Its message union consists of user, assistant, and tool-result messages. Assistant content is text, thinking, or tool calls; a tool result explicitly carries `toolCallId`, `toolName`, content, and `isError` ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/types.ts#L350-L380), [source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/types.ts#L421-L467), [source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/types.ts#L521-L525)).

A `Provider` owns provider identity, auth semantics, model discovery, and stream implementation; the `Models` collection resolves auth and delegates the request to the provider owning the model ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/models.ts#L88-L155)). That provider interface is broader than OnePage needs initially, but the ownership split is sound.

### Conversion, correlation IDs, and switching

pi transforms canonical history before each provider API sees it. The transformer normalizes tool-call IDs to target-protocol constraints and rewrites the matching results; keeps signed/encrypted reasoning only when compatible; turns portable reasoning into text when switching models; strips incompatible provider signatures; ignores failed partial assistant turns; and, for APIs that require balanced calls/results, can synthesize a missing result ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/api/transform-messages.ts#L59-L157), [source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/api/transform-messages.ts#L158-L222)). The important pattern is explicit compatibility conversion rather than changing stored history when the target provider changes.

pi's normalized stream protocol covers start, text/thinking/tool-call start/delta/end, and one done/error terminal carrying the final canonical assistant message ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/types.ts#L527-L551)).

### Persistence, resume, and auth

The coding agent's Session is an append-only parent-linked tree. `buildSessionContext()` follows the selected branch, applies the latest compaction projection, and turns only context-bearing entries into model messages ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/coding-agent/src/core/session-manager.ts#L379-L470), [source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/coding-agent/src/core/session-manager.ts#L1256-L1303)). Model changes are separate durable entries and are recovered by walking the branch ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/coding-agent/src/core/session-manager.ts#L362-L376), [source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/coding-agent/src/core/session-manager.ts#L1083-L1095)). Provider-hosted `responseId` and deferred handles live on assistant metadata, not as Session identity or the only way to resume ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/types.ts#L409-L447)).

The reusable AI library defaults to an in-memory credential store and explicitly expects applications to inject persistent storage ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/auth/credential-store.ts#L4-L9)). The coding agent supplies a locked JSON-backed store keyed by provider ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/coding-agent/src/core/auth-storage.ts#L324-L367), [source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/coding-agent/src/core/auth-storage.ts#L441-L489)). This keeps secrets and refresh policy out of the transcript.

### Useful caveat

pi's format is pragmatic rather than perfectly pure. Canonical assistant messages directly contain provider, API, model, response ID, text/thinking signatures, raw stop reason, usage, and diagnostics ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/types.ts#L350-L380), [source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/types.ts#L427-L447)). Request options also expose broad payload, response, header, sampling, transport, and metadata hooks ([source](https://github.com/badlogic/pi-mono/blob/ccfe79ed238674f760c986e3a61493aab794000a/packages/ai/src/types.ts#L123-L225)). These are valuable compatibility valves in a multi-provider library, but OnePage should prefer DeepSeek Harness's clearer separation between canonical content and an opaque replay sidecar.

## OpenCode V2

### Durable domain messages and canonical LLM messages

OpenCode V2 separates two house representations. Durable `SessionMessage` records express product/session semantics: stable identity, user/system/assistant messages, model selection, text and reasoning, tool lifecycle state, compaction, finish state, token accounting, and optional provider state ([source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/schema/src/session-message.ts#L22-L56), [source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/schema/src/session-message.ts#L72-L196), [source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/schema/src/session-message.ts#L210-L294)).

The AI layer has a second, provider-neutral `Message`: role plus text, media, reasoning, tool-call, and tool-result parts. Tool calls and results share an explicit ID and name; generic metadata and namespaced provider metadata are optional escape hatches ([source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/ai/src/schema/messages.ts#L14-L56), [source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/ai/src/schema/messages.ts#L135-L204)). The extra domain-to-LLM projection layer is useful precedent for OnePage: durable storage need not be byte-for-byte identical to the provider-facing request, but both should have explicit semantics.

### Projection and provider-state compatibility

`toLLMMessages()` lowers durable Session messages into canonical LLM messages. It preserves provider state only when the target model/provider is compatible, converts incompatible reasoning into ordinary text, and keeps tool calls/results paired by stable IDs ([source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/core/src/session/runner/to-llm-message.ts#L95-L221), [source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/core/src/session/runner/to-llm-message.ts#L224-L294)). This is almost exactly the desired “house format, conversion at the edges” shape.

The V2 Session contract is explicit that the full transcript is durable, model selection affects request assembly rather than becoming an instruction source, provider continuation does not cross compaction, and startup recovery is bounded rather than pretending provider calls or tools are exactly once ([source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/specs/v2/session.md#L40-L88)). Provider-hosted result payloads remain provider-owned state; generic tool results are reconstructed from canonical content ([source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/specs/v2/tools.md#L144-L152)).

### Streaming and credentials

Every protocol produces one normalized `LLMEvent` union for text/reasoning lifecycle, tool-input lifecycle, complete calls/results/errors, usage and normalized finish reasons, and provider errors ([source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/ai/src/schema/events.ts#L91-L237), [source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/ai/src/schema/events.ts#L239-L257)). The Session runner maps these transport-neutral events into durable Session events and batches live deltas without making them transcript authority ([source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/core/src/session/runner/publish-llm-event.ts#L68-L125), [source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/core/src/session/runner/publish-llm-event.ts#L125-L191)).

Credentials are a separate domain/service backed by typed key or OAuth records and persisted independently of messages ([source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/schema/src/credential.ts#L31-L51), [source](https://github.com/anomalyco/opencode/blob/42422a1e036fe97ad74048810368b36a2ea2edbb/packages/core/src/credential.ts#L33-L54)).

### Useful caveat

OpenCode V2 has a large provider/protocol registry, dynamic packages, account records, several transport modes, provider-hosted tools, and stateful Session transports. That machinery serves a mature multi-provider product. It is evidence for boundary placement, not a template for OnePage V1's dependency surface.

## Consequences for OnePage's current seams

### Conversation remains the durable house authority

The current ADR already says Conversation is an immutable parent-linked tree and Model Context is a bounded root-to-leaf projection ([local ADR](../adr/0001-append-only-conversation-tree.md)). Keep that. Do not introduce `CodexConversation`, `AnthropicConversation`, or provider-owned thread state as alternate authorities.

What should change is the semantic payload of model-visible entries. `ConversationKind` currently distinguishes only user, assistant, tool result, and context checkpoint ([current source](../../src/session_transition.zig)). `lifecycle.zig` appends Bash call bytes and patch bytes as generic assistant entries, while final answer text is also an assistant entry. It appends tool-specific result blobs as generic tool-result entries. The durable tree therefore lacks enough information for a provider-neutral adapter to determine, without tool-specific knowledge:

- whether an assistant blob is text or a tool call;
- the tool's canonical name;
- the stable call ID that pairs a call with its result;
- whether a result succeeded, failed, or was indeterminate;
- which bytes are canonical model-visible content rather than an execution descriptor.

OnePage should store five semantic Conversation kinds: user text, assistant text, tool call, tool result, and context checkpoint. A tool result must be the immediate child of its call; the call entry identity pairs it with the result parent. Execution descriptors and recovery evidence remain separate from this model-visible content.

### Model Context should select; request projection should interpret

`Core.ModelContext` should remain the bounded selection—currently `first_entry` plus `entry_count`. The host should still be unable to choose a different semantic history. A separate deterministic request builder should interpret those selected entries into a provider-neutral stream such as:

```text
request(version, selected model contract, instructions, tool_catalog_digest)
tool_definition(tool_key, provider_name, description, input_schema, result_contract)
user_text(bytes)
assistant_text(bytes)
tool_call(call_entry_id, tool_key, canonical_json_arguments)
tool_result(call_entry_id, canonical_content)
request_end
```

This can remain windowed and bounded; “semantic” does not imply a resident object graph. The exact Tool Catalog, model contract, instructions, Model Context, and request digest are fixed per model Operation and shared by every replacement Attempt. A provider adapter may remap the stable keys for a restrictive wire protocol, but it must preserve the mapping when translating the corresponding result.

### Keep `Provider` narrow, but deepen what its bytes mean

The current `Provider.dispatch(context, RequestReader, ResponseWriter)` capability is a good security and ownership boundary. It receives no Session or owner authority. Do not widen it into a combined provider/auth/catalog/session manager.

Instead:

- make `RequestReader` expose a documented provider-neutral semantic request protocol rather than raw Conversation blobs;
- have the concrete host adapter own OAuth/API-key lookup, refresh, endpoint, HTTP transport, streaming assembly, and wire conversion;
- have the adapter write one documented complete captured response: assistant text, Tool Key plus bounded exact JSON arguments, or typed failure;
- keep credential references and secrets outside Session content and Core state.

The concrete adapter can close over a host-owned credential service and model selection. The Core does not need to know that Codex uses ChatGPT OAuth while another provider uses an API key.

### `model_protocol` is an adequate V1 terminal disposition, not a complete adapter protocol

The response protocol carries one text answer or one Tool Key plus bounded exact JSON arguments under `StrictToolJsonV1`, or a small terminal status. The closed Host mapping, rather than the Provider contract, decides whether that admitted Tool Key is executable.

Do not push transport data into Core. Define two levels:

1. provider-private streaming assembly and diagnostics;
2. the bounded complete house response: final answer, one generic tool call, or typed failure.

Live deltas may be published as volatile UI events. Only a fully assembled canonical assistant message or complete tool call may become authoritative or authorize an effect. Provider request IDs and usage can be durable diagnostics outside the model-visible Conversation. Add a bounded replay sidecar only if the Codex feasibility spike proves it necessary.

### Provider-hosted conversation state is an optimization

Codex/OpenAI response IDs, Anthropic thinking signatures, Gemini thought signatures, DeepSeek reasoning passback, and provider-side cache/session IDs can improve fidelity or efficiency. Preserve them only behind a contract like:

```text
ProviderReplay {
  adapter_id
  schema_version
  historical_provider
  historical_model
  opaque_lossless_bytes
}
```

The adapter declares whether it can reuse the sidecar for a target request. If not, OnePage discards it and serializes canonical content. Restart, compaction, export, and provider switching must all remain possible without it.

### Model switching can remain deferred

pi and OpenCode record model changes explicitly; all three gate or degrade provider-private data when the target changes. OnePage V1 already intends to fix the selected raw model ID before the first model attempt. Keep that simpler rule. The house format should nevertheless record provider/model provenance separately from content and avoid embedding Codex wire objects, so a later explicit model-change Conversation or Session fact does not require a transcript migration.

## Adopt

1. Five semantic Conversation kinds: user text, assistant text, tool call, tool result, and context checkpoint.
2. Strict V1 call/result grammar with one outstanding call and an immediate result child paired by Conversation identity.
3. A bounded immutable Tool Catalog whose stable Tool Keys, descriptions, input schemas, and result contracts are model-visible data rather than execution authority.
4. One versioned provider-neutral semantic request over the Core-selected Model Context and exact Tool Catalog, frozen per model Operation rather than per Attempt.
5. A Provider boundary that owns authentication, endpoint, wire conversion, streaming assembly, and provider error mapping, then returns one complete generic response.
6. A closed host admission switch that maps only the allowed `bash` and `apply_patch` Tool Keys to their existing Actions and permissions.
7. Local durable history as the only resume authority. Add provider replay data only if the live Codex spike proves it necessary.
8. Deterministic contract tests for arbitrary Tool Key round-trip, exact request reproduction across retries, name mapping, malformed histories, and unknown execution bindings.

## Do not copy

- Pi's broad provider object, unrestricted payload hooks, or mixing every provider-specific field directly into OnePage's canonical assistant record.
- DeepSeek Harness's plugin graph or dynamic route registry.
- OpenCode V2's full protocol/package/account/transport system.
- A dynamic tool registry, MCP execution lifecycle, plugin loader, or generic effect executor.
- Provider wire JSON as durable Conversation content.
- A provider-hosted thread or `previous_response_id` chain as the only resumable history.
- Silent transcript mutation when switching providers. Conversion may deliberately omit incompatible private metadata; it should not rewrite the durable Conversation.
- Synthetic repair of malformed tool histories if OnePage can make malformed pairing impossible when committing Conversation entries.

## Recommended next design step

Before implementing the Codex transport, specify and fixture-test semantic request protocol V2 and its normalized complete response. Keep `Provider.dispatch`, Conversation, and Model Context ownership intact. Prove that every Attempt under one model Operation projects to identical house request bytes, that provider-facing names map back to stable Tool Keys, and that an arbitrary fixture Tool Key round-trips without gaining execution authority. Do not build a fake second provider solely to justify the abstraction.

That creates the correct extension point without prematurely building a general provider registry. The first live provider can remain Codex subscription access; the transcript and lifecycle will already be ready for a second provider without becoming provider-specific.
