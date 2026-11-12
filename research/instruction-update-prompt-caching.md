# Instruction updates under provider prompt caching

Research for [issue #224](https://github.com/DivyanshGolyan/rui/issues/224), inspected 2026-09-17. This is primary-source decision evidence, not an accepted-contract amendment or provider qualification. The later accepted decision in [issue #218](https://github.com/DivyanshGolyan/rui/issues/218) supersedes #224's original Rui-policy inference that canonical history could coalesce updates unseen by a model Operation; the provider evidence remains applicable. Mutable documentation can change; commit links pin the first-party implementation examples inspected on that date.

## Conclusion

Both providers cache an exact rendered **prefix**, not application configuration history. Changing an earlier system/developer instruction changes that prefix and prevents reuse at and after the first divergence; an earlier unaffected breakpoint may still match. Both providers therefore favor a stable beginning and appended changes:

- OpenAI accepts developer messages in Responses input, recommends stable developer instructions first, dynamic developer instructions later, and says to append messages rather than rewrite history. Later developer messages are valid, but on GPT-5.6+ only the end of the initial consecutive developer-message group is an automatic developer cache boundary; a later reusable developer message needs an explicit breakpoint when that boundary matters.[1][2]
- Anthropic explicitly recommends appending a mid-conversation `system` message instead of editing top-level `system`, but only on its listed models and at constrained message positions. Later system messages take precedence for following turns. Unsupported models must use top-level `system`, accepting the cache invalidation.[3][4]

The evidence supports separating canonical history from provider rendering, as accepted in [issue #218](https://github.com/DivyanshGolyan/rui/issues/218). Rui's canonical Conversation retains every explicit instruction update, including A→B→C between model Operations. At each Operation boundary core freezes that canonical historical view and its effective instruction; the provider adapter may append, coalesce or otherwise lower those immutable facts for its model while preserving effective authority. Thus B remains canonical even when a provider projection can represent only C as effective. Once a request is admitted, replay preserves its frozen view under the applicable adapter rules rather than rebuilding it from current configuration. Compaction or deliberate context replacement is a separate provider policy that knowingly changes the rendered prefix without rewriting canonical Conversation.

## Four separate questions

### Wire validity

**OpenAI.** Responses input accepts `developer` messages, a multi-turn conversation may contain several message types, and top-level `instructions` is approximately a developer message for one request. Top-level `instructions` is not retained when continuing with `previous_response_id`; persistent instruction history therefore must be represented again or carried as input history.[2] OpenAI's caching guide itself shows consecutive stable and dynamic developer messages and directs changing content into later conversation messages.[1] First-party Codex goes further in practice: when managed developer instructions change, it appends a developer message saying the new value replaces the old one; its prompt-caching test keeps the complete first request as the second request's prefix and appends changed settings.[7]

**Anthropic.** The dedicated feature guide makes `role: "system"` inside `messages` valid without a beta header on Claude Fable 5.1, Mythos 5.1, Fable 5, Mythos 5, Opus 4.8 and Opus 5, on the Claude API, Amazon Bedrock and Google Cloud; it is unavailable on Sonnet 5.[4] Such a message must immediately follow a user turn (or an assistant turn ending in a server-tool result), and must end the array or be followed immediately by an assistant turn; invalid placement returns 400. Consecutive system messages are accepted. The generated API schema and pinned TypeScript SDK include `system` in `MessageParam.role`, despite stale generic API prose that still says there is no system input role.[5][8] The specialized guide and model gate are the operative evidence.

Wire acceptance alone says neither that an instruction is cacheable at a useful boundary nor how Rui should record application mutations.

### Cache economics and exact matching

**OpenAI.** The cache covers the full rendered context: hidden OpenAI instructions, developer messages, tools and conversation history. Reuse requires the entire rendered prefix through an eligible lookup boundary to match. A relevant change before a boundary prevents reuse after the divergence; lookup does not test arbitrary token offsets.[1]

For GPT-5.6+, explicit breakpoints can be put on supported content blocks in input messages, but not on top-level `instructions`. In implicit mode the latest eligible message is a breakpoint; for developer messages, eligibility is limited to the last message in the **initial consecutive group**. Lookup also considers bounded earlier eligible endings. Developer messages later in history are not automatic implicit boundaries, so a reusable later developer message should carry an explicit breakpoint. Earlier models use model-dependent implicit intervals. Minimum lengths, lookup-boundary limits, routing, lifetime and model support still determine whether an identical prefix actually hits.[1]

**Anthropic.** Rendering and cache hierarchy are `tools` → top-level `system` → `messages`. A hit requires 100% identical content through the breakpoint. Each explicit write hashes the cumulative prefix through its marked block; reads search backward for entries earlier requests actually wrote, at most 20 block positions per breakpoint. Thus changing top-level `system` invalidates reuse of its system and message suffix, while a separately written tools prefix can remain reusable. Appending messages leaves the old prefix intact.[3]

Neither provider says caching changes generation: cached state avoids recomputing the same prefix, while output is generated anew.[1][3]

### Model behavior

Cache identity is not instruction precedence. OpenAI's Model Spec says all applicable instructions are followed except those conflicting with higher authority or superseded by a later message at the same authority; a later instruction supersedes when it contradicts, overrides or makes the earlier one irrelevant.[6] Therefore an appended developer instruction can replace an earlier developer instruction semantically, but an implementation should make replacement explicit rather than assume every pair of instructions conflicts cleanly. The spec describes intended behavior, not a cache rule or a guarantee that every deployed snapshot follows it perfectly.

Anthropic documents stronger feature-specific behavior: a mid-conversation system instruction applies from its position onward; later system messages take precedence over earlier system messages, and mid-conversation system messages take precedence over top-level `system` for following turns.[4] Anthropic says to append an evolved instruction and avoid editing or removing one already sent, because the edit invalidates the cache from that point and can invalidate later thinking blocks on affected models.[4]

### Rui policy implication

Provider evidence observes only requests and therefore does not determine Rui's durable facts. Combined with Rui's accepted append-only Conversation contract, the boundary is:

1. Every admitted explicit instruction update appends a canonical Conversation entry, whether or not a model Operation immediately observes it.
2. At Operation admission, core freezes the canonical historical boundary and effective instruction selected for that Operation.
3. The adapter lowers those immutable facts for its provider/model. It may append one authoritative block per entry, coalesce entries to the effective value, or use another supported representation; cache optimization cannot weaken effective authority.
4. Replacement Attempts retain the admitted Operation's frozen view. Later configuration cannot rewrite it. With unchanged adapter rules, reconstruction is equivalent; a deliberate adapter change may alter rendering without changing canonical history.
5. Apply provider gates during lowering: OpenAI developer messages and breakpoint rules differ by model; Anthropic mid-conversation system messages are model- and placement-limited. A provider that cannot express an appended authoritative update may require a changed early prompt and the resulting cache miss.

This selects **append-only canonical history plus adapter-owned projection**. It does not require one provider block per canonical entry, nor permit provider cache economics to coalesce Rui's Conversation. The distinction is Rui policy; neither provider defines Rui's durable facts.

## Sources and reproducibility

Mutable first-party documentation, force-refetched 2026-09-17:

1. OpenAI, [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching): rendered-prefix identity, breakpoints and lookup boundaries, initial developer group, stable-first/append-only guidance, output-generation neutrality.
2. OpenAI, [Prompt engineering](https://developers.openai.com/api/docs/guides/prompt-engineering): developer messages, multi-turn roles, authority, and request-scoped top-level `instructions`.
3. Anthropic, [Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching): render order, cumulative writes, 20-position read lookback, exact matching and invalidation hierarchy.
4. Anthropic, [Mid-conversation system messages](https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages): recommendation, supported models/platforms, precedence, placement and append-without-edit rules.
5. Anthropic, [Messages API](https://platform.claude.com/docs/en/api/messages): generated `MessageParam.role` union and the contradictory generic prose noted above.
6. OpenAI, [Model Spec, 2025-02-12: chain of command](https://model-spec.openai.com/2025-02-12.html#chain_of_command): same-authority supersession. This dated public spec is authoritative guidance for intended behavior, not a snapshot-specific conformance test.

Pinned first-party source:

7. OpenAI Codex [`b0659c53865dd48b0cd69c454368cea3980017cc`](https://github.com/openai/codex/tree/b0659c53865dd48b0cd69c454368cea3980017cc): [managed developer replacement messages](https://github.com/openai/codex/blob/b0659c53865dd48b0cd69c454368cea3980017cc/codex-rs/core/src/context/world_state/managed_developer_instructions.rs) and [prompt-prefix tests](https://github.com/openai/codex/blob/b0659c53865dd48b0cd69c454368cea3980017cc/codex-rs/core/tests/suite/prompt_caching.rs). This is implementation evidence, not an API contract Rui must copy.
8. Anthropic TypeScript SDK [`d10318284eece2f612d2758a6d5935fe32dc6f7d`](https://github.com/anthropics/anthropic-sdk-typescript/tree/d10318284eece2f612d2758a6d5935fe32dc6f7d): [`MessageParam.role` includes `system`](https://github.com/anthropics/anthropic-sdk-typescript/blob/d10318284eece2f612d2758a6d5935fe32dc6f7d/src/resources/messages/messages.ts#L2605-L2609). Schema support does not remove the feature guide's model and placement gates.
9. OpenAI Cookbook [`9a8e9f07dd8b90e67e6ea11d9c90f8e7dc4bfa35`](https://github.com/openai/openai-cookbook/tree/9a8e9f07dd8b90e67e6ea11d9c90f8e7dc4bfa35), [`Prompt_Caching_201.ipynb`](https://github.com/openai/openai-cookbook/blob/9a8e9f07dd8b90e67e6ea11d9c90f8e7dc4bfa35/examples/Prompt_Caching_201.ipynb): exact-prefix examples and the Codex pattern of appending runtime configuration changes rather than mutating the prefix.
10. Anthropic skills [`34040c9c568585f6929bedeaad110ad08f079624`](https://github.com/anthropics/skills/tree/34040c9c568585f6929bedeaad110ad08f079624), [`prompt-caching.md`](https://github.com/anthropics/skills/blob/34040c9c568585f6929bedeaad110ad08f079624/skills/claude-api/shared/prompt-caching.md): first-party operational summary of the prefix invariant and model-gated mid-conversation system-message recommendation.

No live provider request was needed: the question is what current first-party guidance and pinned implementations establish, not whether a particular account/model currently realizes a cache hit. Cache-hit rates, model adherence and Rui integration remain unqualified.
