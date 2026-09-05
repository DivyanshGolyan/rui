# Append-only provider context and changing Session settings

> **Research record, published 6 September 2026.** Findings and proposals below reflect the dated investigation. Subsequent decisions are owned by [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCT.md](../../PRODUCT.md); historical recommendations and implementation-ticket references do not override them.

Checked 5 September 2026 against official provider documentation and schemas. Research only: this note does not accept a new OnePage contract. No model requests, paid probes, normative-document edits, or issue updates were performed.

## Subsequent decision

The user accepted the append-only model-visible update direction after discussing this research. The [Session decision record](https://github.com/DivyanshGolyan/onepage/issues/101#issuecomment-5550876667) owns that acceptance. The user subsequently selected System Instruction as a distinct Conversation Entry kind, visible in Session history. Exact storage/wire encoding and first-inclusion transaction mapping remain unresolved; the provider findings below and unselected implementation suggestions remain research evidence.

## Anthropic

### Preserved thinking is a compatibility constraint

Fable 5.1 checks whether replayed thinking was produced under the same preceding system prompt, tools, and messages. Prefix changes normally reject; an explicit option drops affected reasoning instead. Enforcement defaults on for accounts created from 31 August 2026, with all-account enforcement planned for later models. Request options outside that prefix, including output configuration, are excluded. This does not prohibit legitimate context changes generally: it constrains retaining old thinking beneath an edited prefix. [Preserved thinking](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking)

Anthropic attributes the change to anti-distillation measures. Its rollout covers new Claude Platform organizations and the specified cloud-account/project boundaries; older Fable 5.1 accounts are initially exempt. This stated motivation does not establish that other vendors intend the same restriction. [Anthropic explanation and rollout](https://support.claude.com/en/articles/16761192-preserved-thinking-changing-how-the-messages-api-handles-thinking-blocks-to-protect-against-distillation)

### There is an actual appended system-message API

Supported models accept `role: "system"` inside `messages` with operator-level authority and no beta header. This is not universally supported across Claude models. Content must follow a user/tool-result turn or certain server-tool completions; it cannot split a tool call from its result or be the first message. Later instruction changes append another message. Tool availability uses typed addition/removal blocks under a separate beta, not merely prose. Keep external tool/document data at its original lower authority. [Mid-conversation system messages](https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages)

For previously unknown tools, the preserved-thinking guide permits adding deferred definitions and exposing them through a later tool-addition reference. Existing exposed definitions cannot simply be rewritten. [Deferred tool discovery](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking#add-or-remove-tools-with-tool_addition-and-tool_removal)

### Effort, compaction, and performance need separate treatment

Supported models also offer beta per-message effort changes, effective from the next user turn. Top-level effort changes remain legal but can restart the cache; Anthropic says chronological changes steer effort more reliably. That is provider guidance, not an independently measured OnePage performance result. [Effort changes](https://platform.claude.com/docs/en/build-with-claude/effort#change-effort-mid-conversation)

Anthropic recommends preserving returned assistant blocks, appending changes, and using supported compaction/context editing. Client compaction can instead begin from a full summary without replaying earlier thinking. Therefore append-only canonical storage does not require resending an unlimited uncompressed prefix, but a compaction boundary must follow the adapter's valid continuation contract. [Fable 5.1 prompting guidance](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1#keep-the-conversation-history-append-only)

## OpenAI

### Instruction changes and message roles

Responses accepts `system` and `developer` messages inside its input-item sequence; these have higher instruction priority than `user` messages. Therefore an appended developer message can be a real instruction update, rather than user text dressed as a system instruction. The official generated input schema also requires preservation of assistant `phase` when replaying applicable models' history. This establishes the supported representation, not a benchmark of every position or combination. [Responses input schema](https://github.com/openai/openai-python/blob/main/src/openai/types/responses/easy_input_message_param.py)

Separately, request-level `instructions` may change between Responses calls. With `previous_response_id`, prior request-level instructions are not inherited; the reference explicitly describes swapping them for the next response. Thus OpenAI does not document a blanket prohibition on changing the initial instruction field. [Responses create reference](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)

Chat Completions also supports developer messages in its message array. This must not be confused with Responses' richer item history and encrypted reasoning continuation. [Chat developer-message schema](https://github.com/openai/openai-python/blob/main/src/openai/types/chat/chat_completion_developer_message_param.py), [Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses)

### Reasoning preservation and configuration changes

For a function-calling sequence, OpenAI recommends retaining reasoning, calls, and results since the last user message; manual replay should leave that span unchanged. Current docs additionally support an appended `configuration_update` for reasoning effort on **GPT-6 Astra, standard single-agent mode only**. It keeps request-level effort unchanged, persists until superseded, must remain in its original replay position, and cannot be adjacent to another update. Automatic compaction/truncation and the standalone compact endpoint do not support histories containing these updates; an explicit compaction-trigger path is documented instead. This is a provider-specific capability, not a general settings protocol to copy into OnePage. [Reasoning guide](https://developers.openai.com/api/docs/guides/reasoning#keeping-reasoning-items-in-context)

Stateless Responses supports replaying encrypted reasoning items. Discarding them is not equivalent to preserving the previous reasoning state, even when the visible conversation remains. [Stateless reasoning migration](https://developers.openai.com/api/docs/guides/migrate-to-responses#4-decide-when-to-use-statefulness)

### Tools and caching

Cache matching uses the rendered prefix, including tools and instructions. Changing tool names, descriptions, schemas, ordering, output schema, or relevant generation settings can change that prefix. OpenAI recommends stable initial instructions, placing dynamic information such as timestamps later, and appending messages instead of rewriting history. A settings update can therefore be legal while reducing cache reuse; an unchanged local transcript alone does not guarantee an unchanged provider prefix. These are documented caching properties, not evidence that one strategy universally improves task accuracy. [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching#prompt-structure)

OpenAI also documents developer-role `additional_tools` input items. Tools become available at that point, and manual replay must retain the item's position. This is typed tool registration, not a natural-language claim that a tool exists. [Tool additions in context](https://developers.openai.com/api/docs/guides/tools-tool-search#add-tools-at-a-specific-point-in-the-input)

## Gemini

### Interactions API

`previous_interaction_id` preserves input/output history. `system_instruction`, `tools`, and generation settings are scoped to the new interaction and must be supplied again when needed. Changing those fields is therefore part of the documented interface. Stateful continuation can improve implicit cache reuse, but stateless mode also supports implicit caching. [Interactions overview](https://ai.google.dev/gemini-api/docs/interactions-overview#server-side-state-management)

The current Interactions schema has `user_input`, `model_output`, thought, and tool steps, but no system/developer input step. High-priority instructions use the separate `system_instruction` field. An appended user step containing a “system update” label is not a native system-role message. [Interactions reference](https://ai.google.dev/api/interactions-api), [OpenAPI schema](https://ai.google.dev/static/api/interactions.openapi.json)

In stateful mode, Gemini retains thought blocks/signatures on the server. In stateless mode, its guide requires resending all thought blocks unchanged. The encrypted signature belongs to a dedicated thought step (or certain built-in tool steps), rather than ordinary user/model text. [Interactions thinking](https://ai.google.dev/gemini-api/docs/thought-signatures)

### generateContent API

Conversation `Content.role` is `user` or `model`; system instructions and tool declarations are separate request fields. Thus this API also lacks an appended high-priority system message in ordinary conversation history. A `role` shown inside a separate system-instruction object is not evidence that `contents[]` supports system messages. [generateContent reference](https://ai.google.dev/api/generate-content#Content)

Thought signatures are attached to response parts in this API. Pass them back exactly; Gemini 3 function-calling continuation can return a validation error when required signatures are absent. Retaining complete response objects avoids treating visible text as the entire continuation state. [generateContent thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures)

Google recommends common content at the beginning and similar request prefixes for implicit caching. This supports keeping stable history, but does not establish that replacing system instructions is forbidden or quantify an accuracy penalty. [Context caching](https://ai.google.dev/gemini-api/docs/caching)

## Boundaries of this evidence

- Append-only durable storage, immutable provider continuation state, and a stable rendered prompt prefix are different properties.
- Native high-priority appended messages are not a uniform cross-provider wire primitive. User-message fallbacks change instruction authority.
- Updating tool availability still needs actual provider tool declarations; announcing a tool in conversation does not register it.
- The documents establish present capabilities and restrictions. They do not establish future provider policy or a measured OnePage performance benefit.

## Implications for OnePage — proposals for discussion

The existing [provider-continuation ADR](../adr/0023-preserve-provider-replay-without-silent-degradation.md) already protects provider-owned reasoning items and rejects incompatible replay. The current [architecture](../../ARCHITECTURE.md) separately permits persistent configuration changes and freezes every model request. Neither property alone proves that two successive request prefixes are compatible: selecting new instructions at request construction can still rewrite the prefix beneath retained reasoning. The previous suggestion to refresh date text inside the initial system prompt needs this qualification.

A candidate minimal model is a stable initial instruction prefix followed by ordered model-visible context updates. Session configuration remains caller-facing current state. A model-visible change acquires a fixed position when it is first included in a request, and later requests replay that same entry and rendering at that position. Reuse immutable configuration content and references rather than persisting duplicate full prompts. Changes never rewrite prior observations. Exact placement and transaction mapping are not decided by this note.

This would require an explicit design amendment: Conversation currently has only User text, assistant text, Tool Calls, and Tool Results. Decide how ordered host context updates participate in the canonical input history, without disguising trusted operator instructions as user text or making every host setting a conversation entry. Updating the current value and recording what the model actually received are different facts; unpublished intermediate configuration values need not become model-visible messages automatically.

The candidate follows ordinary construction: select current state at the next legal request boundary, append the required update once, and freeze the resulting request. Retries reuse it. Mode changes used solely by Action authorization retain their existing Action-admission rule. A date update does not need a timer or a new request by itself. File observations remain tool results. Actual Workspace rebinding would separately change execution targets; announcing a new path to the model is not enough, and this research does not approve that feature.

Provider adapters still need real instruction roles, typed tool/configuration changes, and supported compaction rules. In particular, do not adopt a provider's append-only effort item without checking its compaction restrictions. An adapter that lacks equivalent high-priority input cannot silently downgrade an instruction into a user message.

The expected simplicity benefit is one stable account of what the model knew when it acted, rather than reconstruction from today's settings. Sparse on-disk entries can preserve bounded resident memory; context length, wire volume, and cached-token charges still grow with appended material. Avoid adding unchanged timestamps or whole configuration snapshots each request. No quantitative memory, quality, or cost claim has been measured here.

## Suggested evidence before adopting the representation

- Baseline, response with opaque continuation, appended context change, next response, and a retry after restart: earlier rendered input stays unchanged.
- Configuration changes while a tool call is pending: preserve the complete call/result sequence and apply the update only at a provider-legal position.
- Two changes before any new request: specify whether only the selected current value is exposed, preserving the existing no-activation-queue promise.
- Tool discovery/removal and effort/output-schema changes: use real provider controls, preserve history, and identify supported compaction paths.
- Repeat the same task with a stable prefix plus updates versus rewritten instructions; measure cache hits, input/output tokens, latency, task quality, and history growth independently.

These are proposed fixtures, not results. No production implementation, normative contract, GitHub issue, or model account was changed by this research.
