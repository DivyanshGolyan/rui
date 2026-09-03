# Pi and OpenAI native compaction: the third-party hybrid extension

> Decision status: ADR-0023 adopts one canonical Completion-owned output representation and a derived Compaction Base, not a Provider Replay Receipt or Compaction Checkpoint relation. The later conclusion that opaque continuation could remain a future optional optimization is superseded; OnePage never silently degrades to visible Conversation or a semantic summary.

Research date: 2026-09-03

“PyHarness” here is interpreted as **Pi’s harness**. Pi core is compared with the third-party [`algal/pi-openai-server-compaction`](https://github.com/algal/pi-openai-server-compaction) extension, which is the concrete Pi implementation of OpenAI’s opaque Responses compaction.

- Pi source revision used by the extension: [documented upstream integration](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/ARCHITECTURE.md#L12-L26)
- Extension revision: [`8a3de2f3b0c178fdd6f73f2f94172dfc3943e466`](https://github.com/algal/pi-openai-server-compaction/tree/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466)

## Verdict

Pi’s ordinary compaction is a portable, readable summary. The extension adds a second, OpenAI-only continuation path: an opaque OpenAI replacement history. It deliberately keeps both alive, but that is a pragmatic interoperability layer—not a clean semantic model to copy wholesale.

The extension’s authors describe this plainly as “two representations of context”: Pi JSONL plus a readable summary for trees, export and model switches; OpenAI replacement history for compatible later turns. [Architecture](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/ARCHITECTURE.md#L12-L26)

## What plain Pi compaction does

Pi keeps its normal append-only session JSONL and writes a regular compaction entry with a text summary. Its context builder treats the latest compaction entry as a replacement view over older entries rather than deleting the source tree. This makes it readable and provider-independent, but it cannot preserve an OpenAI encrypted reasoning/compaction artifact. [OnePage’s pinned Pi study](fx-pi-harness-lessons.md) [Pi context builder source](https://github.com/earendil-works/pi/blob/dcd461925db2edf69a43c8135db1180d418afd54/packages/agent/src/harness/session/context.ts#L45-L99)

## What the extension adds

### At a compaction boundary

For direct OpenAI Responses/Codex routes only, the `session_before_compact` hook launches two independent operations in parallel:

1. create Pi’s portable text summary;
2. ask OpenAI for native compaction.

If native compaction succeeds, the normal Pi compaction entry stores the readable `summary` **and** `details.remoteCompaction`; if it fails, the local summary still lets Pi continue. If both fail, it falls back to Pi’s default compaction. [Hook and fallback policy](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/index.ts#L202-L290)

The native call serializes the Pi conversation into Responses input, appends `{type: "compaction_trigger"}`, and waits for `response.completed` with exactly one opaque `compaction` item. It retains the newest real user messages within a 20K-token budget alongside that item, and persists the result with a model key and usage snapshot. [Native request and validation](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/remote-compaction.ts#L829-L1009) [Retained-user-message construction](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/remote-compaction.ts#L629-L660)

The local summary is independently generated from the whole Pi conversation, capped at 4,096 tokens, and falls back to Pi’s `compact(...)` helper if the local-summary call fails. [Local summary path](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/remote-compaction.ts#L680-L748)

### On a later OpenAI turn

The native replacement history is selected only when its persisted model key equals the exact active provider/API/model key. It replaces the normal input and removes `previous_response_id`; otherwise Pi uses the ordinary continuation/summary path. [Model key](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/openai.ts#L108-L110) [Continuation injection](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/index.ts#L318-L381) [Resume reconstruction and model gate](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/remote-compaction.ts#L1030-L1072)

For direct OpenAI routes, it also enables ordinary server-side compaction on normal Responses calls (`store: true`, a `context_management` compaction threshold, and safe response-ID chaining). Azure is excluded. [Route gate and normal-request patch](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/openai.ts#L46-L142)

OpenAI’s own contract is consistent with this: server compaction emits an encrypted opaque item in the normal response flow; client-held chaining retains that item and the later suffix, while `previous_response_id` chaining is a separate server-hosted state mechanism. [OpenAI compaction guide](https://developers.openai.com/api/docs/guides/compaction)

## Why the hybrid is uncomfortable

The concern is well-founded. The extension needs two state machines to agree:

- Pi summary / JSONL supports session trees, export, switching and non-OpenAI replay.
- The opaque `remoteCompaction` payload supports continuity only for one exact OpenAI route.

That duplication is intentional and useful in a mature multi-provider product, but it creates extra reconstruction, fallback, and compatibility rules. The extension itself clears/rebuilds native runtime state at switches, forks and tree operations, and falls back to the text summary outside the compatible OpenAI route. [Lifecycle clearing](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/src/index.ts#L172-L200) [Why both are retained](https://github.com/algal/pi-openai-server-compaction/blob/8a3de2f3b0c178fdd6f73f2f94172dfc3943e466/ARCHITECTURE.md#L187-L201)

## Better OnePage shape

Do not make a semantic checkpoint and an opaque checkpoint co-equal durable facts. Keep one immutable canonical Conversation, then have one derived **Model Context Cut** for a particular model attempt:

```text
Conversation (canonical, complete, never compacted)
  └─ Model Context Cut (one source range + one suffix boundary)
       continuation = semantic summary | provider-native opaque item
       compatibility = exact model contract / prompt-tool prefix identity
```

This applies information-hiding and single-authority principles:

- `Conversation` is the only historical truth.
- A context cut is one projection decision, not a second transcript.
- Its continuation value has one active form for that attempt. The provider adapter owns opaque bytes and compatibility; Core only knows that the cut covers a range and begins the suffix.
- Switching provider or changing a security-significant system/tool contract never translates private reasoning into pretend-portable reasoning. The old cut is ineligible; Core either rejects a continuity-required mutation or derives a **new semantic** cut from canonical history for an explicit handoff.

That captures the useful Pi invariant—“latest compaction boundary plus suffix”—without copying its dual live representations. It also keeps an OpenAI opaque continuation as a future provider-edge optimization rather than making it part of V1’s semantic authority.
