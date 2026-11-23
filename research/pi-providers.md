# What a second provider codec costs Rui, measured against pi

Written 2026-11-23 for [#2040](https://github.com/DivyanshGolyan/rui/issues/2040), part of #2034. Rui source is `origin/main` at 5a6b6e5. Pi sources are the published packages `@earendil-works/pi-coding-agent` 1.6.0 and `@earendil-works/pi-ai` 1.6.0, read from unpacked tarballs. Paths such as `pi-ai dist/api/anthropic-messages.js:717` are inside those packages.

Labels: **[read]** means I read it in the cited file. **[ran]** means I ran it. **[inferred]** means I reasoned from what I read; nothing exercised it. **[unverified]** means a fact about an outside service that is not in any source I read. Nothing here was run against a live provider, and no Rui code was built or changed.

## Answer

1. Pi has no usage data in either package. The sources show only what pi supports, the order it tries defaults in, and what it documents first. Anthropic and OpenAI lead its docs, but no source says which providers users configure. **[read]**
2. Pi's bundled catalog speaks ten wire APIs for chat models. Chat Completions (`openai-completions`) carries 29 of 42 providers and 748 of 1,698 chat models. Anthropic Messages is second with 10 providers and 417 models. OpenAI Responses is third with 7 providers and 142 models. **[ran]**, counted from `dist/providers/data/*.json`. Counts measure catalog size, not use.
3. Rui's codec seam is a close fit for Anthropic Messages on three counts. The Store already pins a codec by name and has an unused `codec_options` slot. `Usage` already has a cache-write count. The neutral output kinds (reasoning, message, function call) map onto thinking, text and `tool_use`. Two parts do not fit: the response side, and the credential and endpoint plumbing. **[read]** and **[inferred]**
4. The response side is the real ABI gap. Rui's interpreter gets one SSE event and names ranges inside it. An accepted output item is a range of one event. Anthropic builds one block from many events (`content_block_start`, deltas, `content_block_stop`), so the ABI needs an accumulation step it lacks today. **[read]** for the ABI, **[inferred]** for the consequence.
5. An OpenAI-compatible base URL does not reach most local models. Rui has no HTTP/1.1 route: HTTPS needs ALPN `h2`, and loopback `http://` is h2c by prior knowledge (`docs/contracts/model-io.md:376-378`). I believe llama.cpp, Ollama, LM Studio and vLLM serve HTTP/1.1 only **[unverified]**, so they would be unreachable until Rui gains an HTTP/1.1 client. OpenRouter is reachable over h2.
6. Rough size: an Anthropic codec is about 1.8k to 2.8k lines of Zig, plus 600 to 900 lines of tests, plus 10 to 15 touched files for provider, credential and endpoint plumbing. A Chat Completions codec is of similar size, with a larger compatibility matrix. Details are in [Size](#size). **[inferred]**

## 1. What pi supports and defaults to

### Providers

`pi-ai` lists 42 providers with chat models (`dist/types.d.ts:26`, `README.md:62-99`). `docs/providers.md` says most hosted providers take OAuth or an API key through `/login`, and it lists one environment variable per provider. Amazon Bedrock and Google Vertex can also use ambient cloud credentials. **[read]**

Wire API per provider, from the bundled catalog **[ran]**:

| API (pi name) | Providers, by chat model API | Notes |
| --- | --- | --- |
| `openai-completions` | 29 providers, 22 of them only this API: ant-ling, baseten, cerebras, cloudflare-workers-ai, deepseek, groq, huggingface, kimi-coding, moonshotai (+cn), nvidia, qwen-token-plan (4), together, xiaomi (4), zai (+cn). Also most of openrouter (397 of 417 chat models) and parts of azure, copilot, fireworks, opencode and others. | 748 chat models. |
| `anthropic-messages` | 10 providers. Only this API: anthropic, minimax (+cn), vercel-ai-gateway. Also openrouter (20 chat models), github-copilot, fireworks, opencode, opencode-go, cloudflare-ai-gateway. | 417 chat models. |
| `openai-responses` | openai, xai, meta only; also copilot (18 models), opencode, opencode-go and cloudflare-ai-gateway. | 142 chat models. |
| `azure-openai-responses` | azure (OpenAI models; Foundry models go through Chat Completions) | `docs/providers.md`, Azure section. |
| `openai-codex-responses` | openai-codex (ChatGPT subscription) | Rui's `codex` and `chatgpt` providers are this family. |
| One provider each | amazon-bedrock (`bedrock-converse-stream`), google (`google-generative-ai`), google-vertex, mistral (`mistral-conversations`), radius (`pi-messages`) | |

`docs/models.md` ("Configure a compatible endpoint") says an OpenAI-, Anthropic- or Google-compatible endpoint is added through `models.json`, which "includes most Ollama, LM Studio, vLLM, SGLang, and proxy deployments". Its worked example is Ollama at `http://localhost:11434/v1` with `"api": "openai-completions"` and a dummy key. Pi integrates the llama.cpp router directly (`docs/llama-cpp.md`, default `http://127.0.0.1:9931`). **[read]**

### Defaults

- With no saved choice, pi picks the first provider in `defaultModelPerProvider` that has a usable credential and its listed model, and otherwise the first available model (`pi-coding-agent dist/core/model-resolver.js:9-40, 395-424`). **[read]**
- That table's key order is amazon-bedrock, ant-ling, anthropic, openai, azure, openai-codex, radius and so on. The order is a fallback sequence, not a statement that pi favours Bedrock. **[read]**
- The default models are Anthropic `claude-opus-5-5`, OpenAI `gpt-6.2-sol`, OpenRouter `moonshotai/kimi-k2.7-code`, Google `gemini-4-argon`, xAI `grok-4.7`, and `deepseek-v4-pro`. **[read]**
- A saved `defaultProvider` and `defaultModel` in settings take priority (`docs/settings.md:13-14`). The default thinking level is `medium` (`dist/core/defaults.js:1`). **[read]**
- `docs/quickstart.md` sends users to `/login`; it names no default provider. **[read]**

I did not look for download or issue statistics, so "which providers do pi users actually configure" stays open. The nearest evidence is the table above: pi spends the most effort on Chat Completions compatibility.

## 2. What Rui's codec seam covers today

### What the ABI covers

All of this is **[read]** from `src/codec_abi.zig`, `src/codecs.zig`, `src/provider_name.zig` and `docs/contracts/execution.md:285-312`.

- **Pinning and dispatch.** `protocol.Codec` is `provider_name.Codec`, an enum with three members, `openai-responses/1`, `/2` and `/3`. `src/codecs.zig` dispatches at comptime to a codec module providing `manifest`, `RequestHeader`, `requestHeaders`, `Encoder`, `Carry`, `classify`, `Stream`, `interpretEvent`, `nextMember`, `hostedCall` and `finish`. A new codec is one more enum member and one more `module()` arm. The Store keeps `codec` as `text` of 3 to 40 bytes and has a nullable `codec_options` bytes column of up to 512 (`src/store/schema.zig:1299-1300`), so no schema change is needed for a new name.
- **Request encoding.** The shell hands the codec one neutral item at a time (`settings`, `message`, `output_open`, `output_part`, `output_close`, `tool_result`, `image_*`, `declare_*`, `tools_start`, `tool`, `request_end` and others) with content named by handle. The codec answers with pieces: literal bytes, a JSON-escaped handle, or raw-image base64 (`Pieces`, `max_pieces = 8`). Its entire state between items is a small `Carry`, which the history memo stores and resumes (`docs/contracts/model-io.md:412-430`).
- **Headers.** A codec names up to 8 lowercase request headers, 192 bytes in total, and the response headers the transport observes.
- **Error classification.** `classify` reads a 4xx or 5xx body and names context overflow, one of four neutral refusals (quota, plan, policy, model unavailable) and report ranges.
- **Response interpretation.** `interpretEvent` takes one SSE event and returns `added`, `item`, `completed` or `failed`. Usage is `{uncached, cache_read, cache_write, output}`.
- **Locality rule.** `tests/ci/provider_locality.py` fails CI when core code names a provider, and when a codec reads a model name (`modelName(`). A per-model fact goes in `src/model_catalog.zig` (`docs/contracts/model-io.md:499`).

### What is OpenAI-shaped

- `Provider` is `{codex, openai, chatgpt}`. `Facts` carries an `endpoint` that every test requires to start with `https://` and end with `/responses` (`src/provider_name.zig:98-112`). `Credential` is `sign_in` or `api_key`.
- `endpointUnder` hard-codes the `/responses` suffix (`src/endpoint_value.zig:39-48`).
- The Host writes `authorization` itself from the credential; a codec may not name it (`execution.md:301-302`).
- `Listing` parses OpenAI's `/models` (`src/providers.zig:170-179`, `src/model_list.zig:46`).
- `ItemKind` includes `compaction_trigger`, `web_search` and `text_format`. `OutputKind` is `reasoning, message, function_call, compaction, web_search_call`, stored as `item_kind BETWEEN 1 AND 5` (`src/store/schema.zig:1746`).
- `Reason` names Responses-specific rejections such as `continuation_unavailable`.

## 3. An Anthropic Messages codec

### Fits without ABI change **[inferred]**, from the sources read

| Need | Where Rui already has it | Pi's equivalent |
| --- | --- | --- |
| System prompt as top-level field | `openai-responses/1` writes `"instructions"` before `"input"` when the first item is an instruction message (the `message` arm of `src/codecs/responses.zig`'s encoder). The same carry state would write `"system"`. | `pi-ai dist/api/anthropic-messages.js:1119-1136` |
| Reasoning effort | `Effort` is `none..max`; `/1` writes top-level effort per request. Anthropic has `thinking` and `output_config.effort`. | `anthropic-messages.js:1170-1194` |
| Four-way usage including cache write | `codec_abi.Usage`. The Responses codec reports `cache_write = 0` (`model-io.md:196`). Anthropic's `message_start` carries `cache_read_input_tokens` and `cache_creation_input_tokens`. | `anthropic-messages.js:689-695, 843-850` |
| Images in user input and tool results | `image_message_open`, `input_image`, `image_tool_open`, with a pinned base64 cursor (PNG and JPEG). Anthropic's block is `{"type":"image","source":{"type":"base64","media_type":...,"data":...}}`, which is literals plus `out.base64(0)`. | `anthropic-messages.js:1256-1320` |
| Tool call id and arguments | The neutral function call stores name, call id and arguments as ranges (`OutputItem.call: [3]Range`). `tool_use.id` maps to the call id and `input` to arguments, written verbatim as raw JSON. | `anthropic-messages.js:1357-1363` |
| Memo and rebuild parity | `Carry` is a codec-owned value. A new codec supplies its own. | n/a |
| Provider-run tools | `Facts.runs_tools` per provider. Anthropic would list none. Pi sets up no Anthropic web search (no matches in `anthropic-messages.js`), and the Responses hosted-search items (`web_search_call`, `hostedCall`) are OpenAI-shaped. | |
| Cross-model replay | Rui's D192 omits reasoning from a different requested model (`model-io.md:242`). Pi drops thinking blocks when the model changes (`transform-messages.js:91-106`; `README.md:1586-1587`). The rules agree. | |

### Needs new ABI or shell work **[inferred]**

| Gap | Why | Evidence |
| --- | --- | --- |
| **Response accumulation.** | The shell gives the codec each SSE event whole as one slice, and an item or part is a `Range` into that event (`execution.md:304-312`; `Event.item: OutputItem`, `Member.part.text: Range`). Anthropic streams a block as `content_block_start`, then `text_delta`, `thinking_delta`, `signature_delta` or `input_json_delta`, then `content_block_stop`; no event holds the finished block. Responses emits `response.output_item.done` with the whole item, which the ABI assumes (`model-io.md:530`). The ABI needs either an item built from several event ranges, or a codec-owned scratch the shell lends. Both change the "plain values over one event" contract. | Pi assembles blocks itself: `anthropic-messages.js:717-727, 772-786`. |
| **Request-shape grouping.** | Anthropic needs one assistant message per response whose content is thinking, text and `tool_use` blocks in order, and one user message holding all of a turn's `tool_result` blocks, first, before any new user text. Rui walks neutral items one at a time, so the carry must hold "assistant message open" and "user message open" and close lazily at the next item. `history_end` and `request_end` already exist to close the last one. This fits the ABI, but it is the main encoder complexity, and every cut point needs memo and rebuild parity tests like the existing `a resumed encoder writes what an uninterrupted one writes`. | Pi: `anthropic-messages.js:1385-1397` ("Collect all consecutive toolResult messages"). |
| **Credential header.** | Anthropic's API key goes in `x-api-key` with an `anthropic-version` header. The Host always writes `authorization: Bearer` for a key credential and forbids a codec from naming `authorization`; the codec cannot see the key. `anthropic-version` can be a codec `RequestHeader`, but the key header needs a per-provider choice in `providers.zig` or `provider.zig`. Bearer is used only for `ANTHROPIC_AUTH_TOKEN` in pi. | Pi: `providers/anthropic.js` (key, auth token, OAuth token, workload identity); `docs/providers.md`. The `x-api-key` header form itself is **[unverified]**, from my knowledge of the API, not read in a source here. |
| **Endpoint shape.** | Every `Provider` endpoint ends `/responses`, and a test asserts it. Anthropic's path is `/v1/messages`; Chat Completions is `/chat/completions`. | `src/provider_name.zig:98-112`, `src/endpoint_value.zig:39-48`. |
| **Required `max_tokens`.** | Anthropic requires it per request. `codec_abi.Settings` carries no output limit (`effort`, `starting_effort`, `session_affinity`, `model`). The manifest does freeze an output reservation (`model-io.md:16, 175`), so a field would need adding to `Settings`. | Pi: `anthropic-messages.js:1109`. |
| **Compaction.** | Rui's compaction is the Responses `compaction_trigger` plus encrypted `compaction` items, kept opaque (`model-io.md:133`). Pi's Anthropic path has no matching feature (no `compaction` or `context_management` matches). Without a summarising Operation an Anthropic Session cannot compact. A codec can decline (`error.Declined`, which fails `provider_codec_failed`), but that is a product decision, not an encoding detail. | `execution.md:297`. Decision needed. |
| **Mid-history instruction updates.** | Rui writes later instruction updates as `developer` input messages. Anthropic has top-level `system` only; pi folds later system messages into the leading one unless a model flag says mid-conversation system messages work (`supportsMidConvoSystemMessages`, `anthropic-messages.js:157`; `docs/models-configuration.md`, `supportsMidConvoSystemMessages`). Options are: append as user text, rewrite `system` (costs the cache), or use the model-flagged native form. Decision needed. | |
| **Tool changes keep cache only on flagged models.** | Rui's `/2` declares tools inside the history so a tool change keeps the prompt cache (`model-io.md:476`). Pi shows a native `tool_addition` / `tool_removal` block for flagged models (`anthropic-messages.js:1083-1095, 1232-1270`). Elsewhere `tools` is a top-level array and a change would invalidate the cache. Rui freezes a Session's tool set (`frozen tool set` is part of the view's keys), which limits the cost. | **[inferred]** |
| **Error and stop vocabulary.** | `Reason` is a closed enum. Anthropic's `{"type":"error","error":{...}}` envelope, mid-stream `event: error`, `stop_reason` values (`max_tokens`, `refusal`, `pause_turn`) and overload semantics need mapping onto it. Mostly additive. | `anthropic-messages.js:1529` for stop reasons. |
| **Image limits.** | Rui accepts at most 1,500 images and 512,000,000 request bytes (`model-io.md:279`). Anthropic's own per-request limits are different and are **[unverified]** here. The limits would become a per-codec fact. | |

### Neutral history: what it must carry

Rui stores each accepted output item "in Rui's neutral form plus a provider bag", and the bag keeps every other member exactly as received, including IDs, signatures and unknown fields (`model-io.md:123-133`). That design already holds what Anthropic needs:

- **Thinking signatures.** A `thinking` block is `{thinking, signature}`. It maps to a reasoning item (kind 1) whose private text is a `reasoning_text` part and whose `signature` stays in the item bag. A `redacted_thinking` block's opaque `data` maps to an item bag, or to a `PartKind.opaque_block` part, which the Responses encoder currently declines (`responses.zig`, `output_part` arm) but another codec would not. The one real difference is that Rui's Responses replay deliberately omits `reasoning_text` (`replay_omits_reasoning_text`, `src/store/schema.zig:1750`; `model-io.md:296, 554`). An Anthropic codec must set `omit_reasoning_text = false` and replay the text verbatim with its signature. Pi sends such a block only when a non-empty signature is present, and turns an unsigned block into plain text (`anthropic-messages.js:1323-1355`). Rui's continuation check would be the analogue: an unsigned thinking block must fail, as an empty `encrypted_content` fails `continuation_unavailable`. No new item kind is needed. **[inferred]**
- **Cache control.** It is not history: it marks request positions. Pi puts `cache_control: {type: "ephemeral"}` (plus `ttl: "1h"` for long retention) on the system prompt, the last tool, and the last block of the last user or tool-result message (`anthropic-messages.js:37-47, 1119-1136, 1407-1427, 1521`), so the breakpoint moves with every request. For Rui that placement conflicts with the history memo, which copies exact bytes and must not carry a stale marker. The codec has to write the last block without its closing `}` and complete it with the marker at `history_end` (the `owed` pattern in `responses.zig`'s `Carry`). That needs a test of memo and rebuild parity at every element boundary. A retention setting (short or long) would enter `Settings`. No new item kind is needed. Anthropic's breakpoint count and lookback limits are **[unverified]** here. **[inferred]**
- **tool_use ids.** The call id is already neutral and stays as received. Pi's `normalizeToolCallId` (`[^a-zA-Z0-9_-]` replaced by `_`, cut to 64) exists for cross-provider replay (`anthropic-messages.js:1220-1222`; `transform-messages.js:113-127`), which Rui excludes ("incompatible handoff", `ARCHITECTURE.md`, final lines) because a Session pins its codec. Rui therefore needs no normalisation. Two edge rules remain: an Anthropic `tool_use` needs its `tool_result` in the very next user message, and an empty or missing `input` must be written as `{}`, not as an empty string.
- **Images.** The ABI already streams PNG and JPEG base64. One rule is missing: Anthropic rejects images in error tool results, so pi moves them after the results (`anthropic-messages.js:1385-1397`, `splitErrorToolResultImages`). The ABI's `tool_result` item has no error flag. Rui renders `isError` wording as leading text (`model-io.md:33`), so the codec cannot tell an error result from its handles. A small ABI addition is needed only if error results can hold images. **[inferred]**

Net: the Store and the neutral output kinds hold an Anthropic transcript without a new kind. New work sits in the request encoder (grouping, cache marker, settings fields), the response interpreter (accumulation), and the credential, endpoint and compaction decisions above.

## 4. Would an OpenAI-compatible base URL cover OpenRouter and local models?

### What a base URL buys today

Rui already lets a key provider point at another HTTPS endpoint (`providers.openai.endpoint`, `src/host_settings.zig:240-243`, and the test at `:1818-1820`, "HTTPS API-key endpoints remain configurable"). That is a Responses endpoint, which is not Chat Completions. Pi serves only xai, meta and part of copilot and opencode through Responses; it puts OpenRouter and the local servers on Chat Completions, and OpenRouter's Claude models on Anthropic Messages (20 models, `providers/data/openrouter.json`). Whether xAI or Meta accepts Rui's exact Responses request (`store:false`, `reasoning.encrypted_content`, `additional_tools`) is **[unverified]**; nothing here tests it.

### Chat Completions as a codec **[inferred]**

- **Encoder.** Chat Completions puts the text and the `tool_calls` of one reply in a single assistant message, and tool results are separate `tool` messages. The grouping problem is the same as for Anthropic, and the carry would hold an open assistant message.
- **Interpreter.** It has the same accumulation gap: tool-call ids arrive once and arguments in fragments (`openai-completions.js:427-`). It also has no per-item done event and no `response.completed`. Completion is `finish_reason` plus a usage chunk that exists only when `stream_options.include_usage` is requested (`openai-completions.js:573`), then `[DONE]`. The ABI already has a `done_marker`.
- **Compatibility matrix.** Pi's `compat` block for `openai-completions` has about 25 fields: `maxTokensField`, `supportsDeveloperRole`, `requiresToolResultName`, `requiresAssistantAfterToolResult`, `requiresThinkingAsText`, `requiresReasoningContentOnAssistantMessages`, a `thinkingFormat` with 11 values (`openai`, `openrouter`, `deepseek`, `together`, `baseten`, `zai`, `qwen`, `chat-template`, `qwen-chat-template`, `string-thinking`, `ant-ling`), cache-affinity formats and more (`docs/models-configuration.md`, "openai-completions" table). Pi auto-detects many from the provider and base URL (`openai-completions.js:1236-1290`) and warns not to enable them "based only on an endpoint advertising OpenAI compatibility". Reasoning replay differs by server: `reasoning_content`, `reasoning`, `reasoning_text`, or structured `reasoning_details` (`openai-completions.js:139, 372-402, 993-1038`). Rui forbids a codec from branching on a model name, so these facts would need a catalog row or settings field per model, delivered to the codec through `Settings`. That is a new design question, not a transcription.
- **Cache control.** OpenAI-style servers cache automatically, but pi sends Anthropic-style `cache_control` for `anthropic/*` models on OpenRouter (`openai-completions.js:1265`; `compat.cacheControlFormat`).
- **Model list.** `parseOpenAi` already reads `{data:[{id}]}`, which OpenAI-compatible `/models` endpoints use (**[inferred]** from the parser, not run against them).

### OpenRouter **[inferred]** except the h2 probe

- **Reachable by transport.** `curl --http2 https://openrouter.ai/` reported HTTP version 2 and `api.anthropic.com` did too **[ran]**. I ran it through the sandbox's TLS-intercepting agent proxy, so it is weak evidence of what the origin negotiates, and it does not test Rui's ALPN check.
- **Covered by one Chat Completions codec**: 397 of OpenRouter's 417 chat models in pi's catalog.
- **Anthropic path through OpenRouter**: 20 models use pi's `anthropic-messages` route, so an Anthropic codec would reach those too.
- **Extra work specific to OpenRouter**: a `/models/user` filter and its own thinking format and routing object (`providers/openrouter.js`; `docs/providers.md`, OpenRouter section).

### Local models (llama.cpp, Ollama, LM Studio, vLLM)

- **Transport blocks them.** `model-io.md:376-378` says HTTPS needs ALPN `h2`, loopback `http://` is h2c by prior knowledge, and "there is no HTTP/1.1 route". `docs/contracts/host.md:20` repeats "HTTP/1.1 and HTTP/3/QUIC are absent". I believe those local servers speak HTTP/1.1 and not h2c, so a Chat Completions codec alone would not connect to them **[unverified]**: nothing on disk states their protocol. An HTTP/1.1 client, or an h2c front proxy, would be a separate piece of work. The transport is its own module (`src/h2/`, a separate build module).
- **Endpoint policy blocks LAN hosts.** Cleartext is allowed only for `127.0.0.1` and `[::1]` (`src/endpoint_value.zig:27-31`; `validateEndpoint` refuses other `http://`). A llama.cpp box elsewhere on a LAN would need TLS.
- **No-credential route exists.** An `unauthenticated` setting ("Send no credential to a development endpoint", `src/host_settings.zig:243`) already covers servers with no key. Pi's dummy-key convention is not needed.
- **Verdict.** A Chat Completions codec plus a base URL covers hosted OpenAI-compatible providers (OpenRouter, Groq, Together, DeepSeek and the rest of the 22 Chat-Completions-only providers) and does not cover typical local servers without an HTTP/1.1 route.

## Size

Rui's own Responses codec is the yardstick. `src/codecs/responses.zig` is 2,420 lines: about 1,900 production and about 520 tests; `src/codecs.zig` is 638; `src/codec_abi.zig` is 410; `src/codecs/json.zig`, the shared strict JSON reader, is 684. The production lines split roughly as encoder 250, error classification 900 (most of it a strict JSON judge private to this file), and response interpretation about 700. **[read]**, counted with `wc` and line numbers.

| Piece | Anthropic Messages | Chat Completions | Basis |
| --- | --- | --- | --- |
| Encoder (grouping, system, images, cache marker) | 350 to 500 lines | 350 to 500 | Responses encoder is 250; grouping and the cache marker add state. |
| Error classifier | 250 to 450 | 250 to 450 | Smaller body vocabulary than Responses, but a strict JSON judge is needed; sharing the Responses judge means first extracting it from `responses.zig`, per the one-owner rule in `AGENTS.md`. |
| Response interpreter plus accumulation | 900 to 1,400 | 800 to 1,300 | New ABI shape; several events per block. |
| Codec subtotal | about 1.8k to 2.8k | about 1.7k to 2.6k | |
| Tests and fixtures for the codec | 600 to 900 | 600 to 900 | Responses has 15 tests in 520 lines, plus `src/codecs/fixtures/`. |
| Plumbing | 10 to 15 files, 200 to 500 lines | similar, plus compat settings | `protocol.Codec`/`provider_name.zig`, `providers.zig`, `host_settings.zig`, `provider.zig` credential header, `endpoint_value.zig`, `model_list.zig`, `model_catalog.zig`, `server_execution.zig`, `model_adapter.zig`, `output_decode.zig`, `history_memo.zig`, CLI login, `provider_locality.py`, docs. |
| Contract and verification docs | `ARCHITECTURE.md`, `docs/contracts/model-io.md`, `execution.md`, `VERIFICATION.md` rows | same | Required by `AGENTS.md`. |

Pi's own implementations for scale: `anthropic-messages.js` is 1,548 lines, `openai-completions.js` 1,350, `openai-responses.js` plus `openai-responses-shared.js` 1,129, `transform-messages.js` 213 (JavaScript with SDK helpers and auth, not comparable line for line). Several `src/` files already have `.openai`/`.codex`/`.chatgpt` references (55 non-test files name a provider tag), so a new `Provider` arm will surface in more places than the list above; I did not trace them. All of the table is **[inferred]**.

## Decisions this leaves open

1. **Which second API first.** Anthropic Messages reaches Anthropic, MiniMax, Vercel AI Gateway, and Claude models on OpenRouter, Copilot, Fireworks and others. Chat Completions reaches the largest provider count but forces the compatibility-matrix design and, for local servers, an HTTP/1.1 transport.
2. **Accumulating response codecs.** Both candidates need the ABI to support an item assembled from several events. That decision belongs before either codec, and it touches the `output_decode` shell and the ABI contract that `execution.md:285` calls a value contract for out-of-process codecs.
3. **Compaction and mid-history instructions** for a codec with no `compaction` item and no developer role.
4. **Credential header form** (`x-api-key` versus Bearer), and endpoint shape beyond `/responses`.
5. **Whether local models are in scope.** If so, the HTTP/1.1 route is the first piece of work, ahead of any codec.

## Not verified

- No live request to any provider was made. The only network call was the `curl --http2` probe above.
- Anthropic API specifics not in the pi sources (the `x-api-key` and `anthropic-version` headers, image and breakpoint limits, which servers speak HTTP/1.1 or h2c) come from my general knowledge or inference.
- Pi's catalog model IDs and the "default" models are what pi 1.6.0 ships. They do not say which models Rui should support.
- Counts of models per API come from `dist/providers/data/*.json` for chat models only and double-count models served by more than one provider.
- Line estimates for new Rui code are inferences from the existing codec's size and structure.
