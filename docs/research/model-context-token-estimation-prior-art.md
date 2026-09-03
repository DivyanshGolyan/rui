# Model-context token estimation prior art

Research date: 2026-09-03

This note asks how a provider-neutral agent harness should decide when to compact when exact local
tokenization is unavailable or not worth its cost. It distinguishes the provider's hard context
boundary from a user-selected earlier compaction policy. It uses current first-party API documentation
and source code. It is design research, not a normative decision.

> Decision status: completed issue #93 supersedes this note where it proposed a one-retry rule or left irreducible overflow unresolved. Issue #91 owns retry budgets; an irreducible fitting failure settles the Turn as `ResourceExceeded` without changing Conversation.

## Headline conclusion

OnePage does not need an exact local tokenizer, and it should not turn a token estimate into a durable
content limit.

The recurring implementation pattern is:

1. use model metadata for the provider's advertised hard boundary;
2. use token usage returned by the latest successful model call as the best available anchor;
3. estimate only model-visible content added after that anchor with a cheap character or byte heuristic;
4. use the resulting number only to trigger compaction early; and
5. treat the provider's typed context-overflow response as authoritative.

OpenAI, Anthropic, and Gemini now also expose server-side token-count endpoints. Those endpoints are
useful when exact preflight is genuinely required, especially for media and provider-added structure,
but calling one before every model request adds a second network request, a second request-lowering pass,
and another failure and rate-limit surface. The major open-source harnesses inspected here do not do that
for every ordinary text step.

The simplest defensible V1 rule is therefore:

- admit immutable User Message content without a token quota;
- freeze the model hard boundary, output reservation, and optional user **Compaction Trigger** in the
  Model Request Manifest;
- compute a bounded-memory approximation from durable provider usage plus post-anchor content;
- compact before dispatch when the approximation crosses the trigger;
- disable silent provider truncation; and
- on a typed overflow, resolve the rejected Operation before compaction and a new model Operation;
  issue #91 owns the Turn-wide corrective budget rather than this research note freezing one retry.

This reverses the earlier idea that User Message admission itself should reject content based on a local
token estimate. A heuristic is not strong enough to decide whether canonical user content may exist.
Fit belongs to the exact Model Operation and provider binding.

## Keep two limits separate

| Boundary | Meaning | Enforcement |
|---|---|---|
| **Provider hard context boundary** | What the selected provider/model will accept for one exact request, including provider-specific treatment of input, output, tools, reasoning, and media. | Model metadata is advisory; an exact count endpoint can preflight it; the provider's response is authoritative. |
| **User Compaction Trigger** | A lower token target chosen for cost, quality, or working-context policy. Crossing it asks OnePage to compact before the next model dispatch. | A best-effort trigger may use provider usage plus a local estimate. It is not a content-admission limit or a promise that every request stays below the number. |

The effective trigger is the lower of the user trigger and the provider-specific safe input boundary.
There is no independent OnePage-wide token ceiling. A provider adapter must interpret whether a catalog
exposes a shared context window, a separate input limit, or both; a universal `context - output` formula
is not correct for every API.

A single current User Message can legitimately exceed the user's earlier compaction target while still
fitting the model: the trigger controls when old context is compacted, not how large canonical content may
be. If even the irreducible request cannot fit the provider, OnePage must report that fact explicitly.
Automatically splitting or truncating the message would change its meaning.

## Prior art

### OpenAI Responses API and Codex

OpenAI now provides `POST /responses/input_tokens`. It accepts the same input shape as a Responses create
request and returns the provider's accurate preflight count, including request-structure tokens that a
local tokenizer cannot see. OpenAI explicitly calls out images, files, tools, schemas, reasoning, and
caching as reasons not to rely on `characters / 4`
([token-counting guide](https://developers.openai.com/api/docs/guides/token-counting),
[endpoint reference](https://developers.openai.com/api/reference/cli/resources/responses/subresources/input_tokens/methods/count)).
Completed Responses also report `usage.input_tokens`, `usage.output_tokens`, and `usage.total_tokens`
([Responses reference](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)).

OpenAI can enforce a user-selected lower threshold itself. Responses server-side compaction takes a
`compact_threshold` and runs when the rendered token count crosses it. The standalone compact endpoint is
another exact provider-specific option
([compaction guide](https://developers.openai.com/api/docs/guides/compaction#server-side-compaction)).
Conversely, with truncation disabled, an oversized input fails rather than silently dropping old items
([Responses truncation contract](https://developers.openai.com/api/reference/cli/resources/responses/methods/create)).

The open-source Codex CLI nevertheless uses a hybrid local estimator rather than preflighting every
request through the count endpoint:

- its shared estimate is ceiling-divided UTF-8 bytes at four bytes per token
  ([source](https://github.com/openai/codex/blob/728cb12fe5794b0c3a8e776fb4994b1650b973a8/codex-rs/utils/string/src/truncate.rs#L4-L84));
- full-history estimation is documented as a coarse lower bound, not tokenizer-accurate
  ([source](https://github.com/openai/codex/blob/728cb12fe5794b0c3a8e776fb4994b1650b973a8/codex-rs/core/src/context_manager/history.rs#L361-L389));
- after a successful model item, Codex anchors on the provider's latest usage and estimates only locally
  added items not reflected in that usage
  ([source](https://github.com/openai/codex/blob/728cb12fe5794b0c3a8e776fb4994b1650b973a8/codex-rs/core/src/context_manager/history.rs#L568-L614));
- model metadata separates the context window, a usable-window percentage, and an auto-compact token
  threshold; a configured lower threshold is clamped below the model-derived one
  ([source](https://github.com/openai/codex/blob/728cb12fe5794b0c3a8e776fb4994b1650b973a8/codex-rs/protocol/src/openai_models.rs#L433-L510)); and
- the Responses error code `context_length_exceeded` is promoted to a typed context-window error
  ([source](https://github.com/openai/codex/blob/728cb12fe5794b0c3a8e776fb4994b1650b973a8/codex-rs/codex-api/src/sse/responses.rs#L703-L704)).

**Lesson:** even the first-party CLI treats local counting as scheduling guidance, corrects it with
provider usage, and keeps a typed reactive overflow path.

### Anthropic API and Claude Code

Anthropic provides `POST /v1/messages/count_tokens` for the same structured messages, system prompt,
tools, images, and documents used by Messages. Anthropic calls the result an estimate and says the actual
input count can differ slightly
([token-counting guide](https://platform.claude.com/docs/en/build-with-claude/token-counting),
[endpoint reference](https://platform.claude.com/docs/en/api/http/messages/count_tokens)). Every
completed response reports usage. If input alone exceeds the context window, the API returns a 400
`invalid_request_error` with “prompt is too long”; output exhaustion has a separate
`model_context_window_exceeded` stop reason on supported models
([context-window behavior](https://platform.claude.com/docs/en/build-with-claude/context-windows#context-window-overflow-behavior)).

Anthropic's server-side compaction accepts an input-token trigger, defaults to 150,000, and currently
requires at least 50,000. This is a provider capability, not evidence for a OnePage minimum
([compaction parameters](https://platform.claude.com/docs/en/build-with-claude/compaction#parameters)).

Claude Code exposes both an effective window and a percentage override: a user can lower
`CLAUDE_CODE_AUTO_COMPACT_WINDOW`, and `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` selects a percentage of that
window. The effective value is capped by the real model window. Increasing maximum output tokens reduces
the space available before compaction
([Claude Code environment variables](https://code.claude.com/docs/en/env-vars)). Its implementation is
not open source, so these public docs establish behavior but not its counting algorithm. Claude Code also
stops after repeated compaction thrashing instead of looping indefinitely
([Claude Code agent-loop behavior](https://code.claude.com/docs/en/how-claude-code-works#when-context-fills-up)).

**Lesson:** a lower compaction policy is distinct from the model's real window, and an overflow or
non-shrinking compaction needs a terminal decision for that operation rather than unlimited retries.

### Google Gemini API and Gemini CLI

Gemini exposes `models.countTokens`, which runs the selected model's tokenizer over the request. Model
generation returns `usageMetadata`, including prompt, candidate, thought, tool-use, cached, and total token
counts. Google also describes four characters per token as a rough text rule
([countTokens reference](https://ai.google.dev/api/tokens),
[usage metadata](https://ai.google.dev/api/generate-content#UsageMetadata),
[token guide](https://ai.google.dev/gemini-api/docs/tokens)).

Gemini CLI avoids a count call for ordinary text and tools. Its current estimator uses roughly three
ASCII characters per token, 1.5 tokens per non-ASCII character, fixed media estimates, and a four-character
fallback for very large text. It calls `countTokens` for media and falls back locally if that call fails
([source](https://github.com/google-gemini/gemini-cli/blob/55b495d6db1794bf5b7f37a9bc03ebcab5103673/packages/core/src/utils/tokenCalculation.ts#L11-L35),
[selection logic](https://github.com/google-gemini/gemini-cli/blob/55b495d6db1794bf5b7f37a9bc03ebcab5103673/packages/core/src/utils/tokenCalculation.ts#L149-L185)).
Its compaction decision uses the last provider prompt-token count and a user-configurable fraction of the
model limit
([source](https://github.com/google-gemini/gemini-cli/blob/55b495d6db1794bf5b7f37a9bc03ebcab5103673/packages/core/src/context/chatCompressionService.ts#L245-L285),
[configuration](https://github.com/google-gemini/gemini-cli/blob/55b495d6db1794bf5b7f37a9bc03ebcab5103673/docs/reference/configuration.md#L552-L557)).

**Lesson:** exact server counting can be reserved for content that is difficult to estimate; local text
estimation and post-call usage are sufficient to trigger ordinary compaction.

### Pi

Pi has the clearest small hybrid. It takes the last valid provider usage block, adds a four-characters-per-
token estimate only for messages added after that response, and compares the result with
`contextWindow - reserveTokens`. Both reserve and recent-tail targets are configurable
([usage anchoring](https://github.com/badlogic/pi-mono/blob/265a33393eeea4191b5b6ede216d38b7a32203c5/packages/agent/src/harness/compaction/compaction.ts#L151-L248),
[local estimate](https://github.com/badlogic/pi-mono/blob/265a33393eeea4191b5b6ede216d38b7a32203c5/packages/agent/src/harness/compaction/compaction.ts#L250-L306)).

**Lesson:** OnePage can get a useful compaction trigger from a few persisted numbers plus immutable
content lengths; it does not need to retokenize the complete Conversation or retain it in memory.

### OpenCode

OpenCode's current V2 token utility estimates text at four characters per token
([source](https://github.com/anomalyco/opencode/blob/f12e14cf1640cbf0dfb6b1ff425b2daaef459eec/packages/core/src/util/token.ts#L1-L5)).
Its overflow decision primarily consumes provider-reported input, output, cache-read, and cache-write
usage, then compares that with model input/context metadata after reserving output space
([source](https://github.com/anomalyco/opencode/blob/f12e14cf1640cbf0dfb6b1ff425b2daaef459eec/packages/opencode/src/session/overflow.ts#L1-L34)).
Configuration exposes automatic compaction, retained-token, and buffer controls
([source](https://github.com/anomalyco/opencode/blob/f12e14cf1640cbf0dfb6b1ff425b2daaef459eec/packages/core/src/config/compaction.ts#L1-L15)).

OpenCode also illustrates a trap rather than a rule to copy: its fixed 20,000-token output reservation
interacts poorly with models whose output allowance is larger. This is why OnePage's hard-fit calculation
must come from the exact model/provider contract and frozen output bound, not one universal safety margin.

## Recommended OnePage rule

### 1. Persist policy, observations, and estimates separately

The Model Request Manifest should freeze:

- provider/model compatibility identity;
- advertised input/context boundary and how that provider interprets it;
- the requested maximum output tokens;
- an optional user Compaction Trigger in tokens; and
- the estimator/version used for this request.

Attempt Completion evidence should preserve the provider's raw token-usage fields and typed overflow
code. A local estimate is derived scheduling data, never Conversation or Completion truth.

### 2. Start with the small hybrid

For the V1 text-only seam:

```text
estimated next context
  = latest compatible provider usage anchor
  + estimated model-visible content added after that anchor
```

Use a documented four-UTF-8-bytes-per-token approximation for the post-anchor delta. It is consistent
with Codex, Pi, OpenCode, and Google's public rough rule, but it must be named and exposed as an estimate,
not “token count.” If multilingual workloads matter, a later provider-specific estimator can adopt the
more conservative ASCII/non-ASCII split used by Gemini CLI without changing the domain model.

Do not add a universal safety margin. The frozen provider/model contract and maximum output request own
hard-boundary headroom; the user trigger owns how early policy compaction happens. Any conservative bias
belongs to the named estimator and can be replaced without changing durable content.

The estimate can be computed from immutable content metadata and fixed-window reads. It requires only
counters and a small shared window in memory; it does not require a materialized Conversation, request,
or tokenizer table per active Turn.

### 3. Do not call a token-count endpoint before every ordinary V1 request

The count APIs prove that exact or near-exact preflight is possible, not that it is free. A universal
preflight would duplicate provider request lowering and create a second network dependency for every
model step. Provider usage plus a delta estimate is much simpler and is already the dominant harness
pattern.

Keep exact counting as an optional provider capability. It becomes justified when:

- a provider or modality cannot be estimated responsibly, such as media;
- the user explicitly requests a strict pre-dispatch token ceiling rather than an early compaction
  trigger; or
- an overflow investigation needs to distinguish stale model metadata from estimator error.

If added, lower the same immutable Manifest through the same fixed-window request source, persist the
count as provider evidence, and do not make a complete request buffer resident. Whether the Codex
subscription transport used by OnePage exposes OpenAI's public `/responses/input_tokens` endpoint is not
established and must be tested rather than assumed.

### 4. Make overflow explicit and bounded

Disable provider auto-truncation because it can silently change Conversation meaning. A typed provider
overflow is a successful observation that the exact request did not fit; it is not a transient transport
failure and must not be blind-retried.

Before any model output or external Tool effect is accepted, OnePage may create one smaller Model Context
through compaction and dispatch a new exact Model Operation. If there is no removable history, the
derived Compaction Base is invalid or non-shrinking, or the allowed replacement still cannot fit, settle
the Turn as `ResourceExceeded`. Canonical Conversation content remains intact.

### 5. Leave attachments as a representation seam, not a V1 feature

V1 can keep one UTF-8 User Message body behind an immutable Content Reference. Future ordered attachment
references can be added without changing User Message identity. No attachment tables, limits, token
rules, or public fields are needed until a supported provider path exists. Exact provider counting is the
appropriate future tool for media because character heuristics are not meaningful there.

## Settled product boundary

Completed issue #93 chooses `ResourceExceeded` when an irreducible current User Message cannot fit any
legal projection for the selected model. OnePage does not silently truncate, split, delete, or exclude the
canonical message.
