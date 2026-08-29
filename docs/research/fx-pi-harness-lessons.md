# Lessons from fx and Pi for the first OnePage harness

Research date: 2026-08-24

- fx revision: [`88cb3da8d5559a960fc3d08fbaed45e0ba6df863`](https://github.com/vercel-labs/fx/tree/88cb3da8d5559a960fc3d08fbaed45e0ba6df863)
- Pi revision: [`dcd461925db2edf69a43c8135db1180d418afd54`](https://github.com/earendil-works/pi/tree/dcd461925db2edf69a43c8135db1180d418afd54)
- DeepSeek Harness findings remain pinned in [`deepseek-harness-lessons.md`](deepseek-harness-lessons.md).

## Decision

OnePage should copy neither harness's object model. It should combine three behavioural ideas:

1. Pi's irreducible assistant → typed tool → typed result → next assistant loop.
2. fx's strict ownership split between agent policy, provider transport, tool admission, and UI.
3. DeepSeek Harness's durable intent-before-effect and result-before-advance ordering.

The resulting OnePage harness should be a deep module with a very small command/completion interface. It should hide request construction, durable publication, effect admission, page suspension, completion routing, checkpointing, and presentation ordering behind that interface. Model, repository/tool, approval, durable storage, and output adapters should be internal seams used by both production and deterministic tests.

## fx

### Adopt its ownership split

fx explicitly places composition at the root, agent contracts and policy in core, tool implementations under tools, presentation in UI, and provider mechanics in gateway. Its UI may not own product state, and gateway may not absorb product-state logic ([source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/AGENTS.md#L60-L87)).

OnePage should enforce the same ownership in a smaller shape:

- the 64 KiB core owns tool-call interpretation and the termination decision;
- provider transport owns authentication, wire encoding, HTTP, and response reduction;
- tool adapters own bounded repository and process mechanisms;
- terminal presentation observes committed events and owns no agent state;
- the native composition root wires concrete adapters once.

This is more important than matching fx's file layout.

### Adopt provider admission and delivery evidence

fx's provider seam separates request validation/serialization from the moment delivery becomes possible. A provider invokes an admission hook exactly once immediately before delivery; monotonic delivery evidence then distinguishes definitely-unsent requests from requests that may have reached the provider. Retry ownership is explicit so the transport and agent do not both retry the same attempt ([source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/src/core/agent/stream_provider.zig#L43-L100)).

That maps directly to OnePage's operation lifecycle:

```text
submitted request
  -> serialized and validated
  -> durable accepted record
  -> provider admission
  -> definitely_unsent | possibly_sent evidence
  -> durable terminal result or explicit uncertainty
```

The core should decide recovery from this evidence. The transport should not silently retry an agent-owned attempt.

fx also gives providers one typed borrowed request while keeping endpoint selection, headers, HTTP, and stream reduction inside the provider adapter ([source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/src/core/agent/stream_provider.zig#L158-L216), [source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/src/core/agent/stream_provider.zig#L302-L316)). OnePage should adapt that to durable byte-range handles selected by the core rather than passing a resident message array.

### Separate validation, admission, and execution

fx does not collapse tool lookup, argument decoding, structural validation, availability, permission, and execution into one opaque callback. It can validate a registered call without executing it, admit one call only after availability and permission checks, and execute an already-authorized call separately ([source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/src/core/tooling/tool_dispatch.zig#L600-L676), [source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/src/core/tooling/tool_dispatch.zig#L676-L756), [source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/src/core/tooling/tool_dispatch.zig#L779-L860)).

OnePage needs the same phases because approval may suspend the agent between them:

```text
decode -> validate -> classify authority -> request approval -> durable admission -> execute
```

The approved descriptor must be immutable and digest-bound. Resuming after approval must execute that descriptor, not decode mutable model text again.

fx's default permission rule is also a good conservative baseline: allow read-only, reversible actions; require an explicit decision for mutation or irreversible work ([source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/src/core/permissions/permission_gate.zig#L72-L120)).

### Avoid its mature runtime dependency surface

fx's production runtime supports many providers, tools, permission modes, presentation sinks, recovery paths, subagents, hooks, dynamic tools, and secondary publications. That breadth is appropriate for fx, but its runtime dependency record exposes dozens of callbacks and optional capabilities ([source](https://github.com/vercel-labs/fx/blob/88cb3da8d5559a960fc3d08fbaed45e0ba6df863/src/core/agent/runtime/deps.zig#L167-L245)).

For OnePage, copying that surface would make callers learn the implementation choreography. The initial harness should have fixed built-in tool kinds and only the adapters required by the deterministic fixture and first live provider.

### 2026-08-25 follow-up: use Codex subscription access first

At [`fff3f63e348dec846bb235332974226bd2feae26`](https://github.com/vercel-labs/fx/tree/fff3f63e348dec846bb235332974226bd2feae26), fx has a complete Codex subscription path that is a better first live-provider reference than OpenRouter for OnePage's audience:

- `fx login codex` uses an OAuth authorization-code flow with PKCE, a random state value, a loopback callback, and a refresh token ([authorization](https://github.com/vercel-labs/fx/blob/fff3f63e348dec846bb235332974226bd2feae26/src/core/auth/chatgpt_oauth.zig), [callback](https://github.com/vercel-labs/fx/blob/fff3f63e348dec846bb235332974226bd2feae26/src/core/auth/browser_callback.zig)).
- The refreshable session is stored outside agent state with private-directory, file-permission, locking, atomic-replacement, and secret-zeroing rules ([session storage](https://github.com/vercel-labs/fx/blob/fff3f63e348dec846bb235332974226bd2feae26/src/core/auth/chatgpt_session.zig)).
- The access token's account claim binds requests to the matching ChatGPT account, and transport calls the Codex Responses endpoint directly rather than relaying the token through another provider ([transport](https://github.com/vercel-labs/fx/blob/fff3f63e348dec846bb235332974226bd2feae26/src/gateway/openai_codex.zig)).
- Model selection comes from the authenticated Codex catalog rather than a hard-coded or cross-provider model list ([catalog](https://github.com/vercel-labs/fx/blob/fff3f63e348dec846bb235332974226bd2feae26/src/gateway/openai_codex_models.zig)).

OnePage should adopt those boundaries, not fx's full provider system. OAuth login, credential refresh, model-catalog fetching, and wire transport remain host concerns outside Core State, the Activation Slot, Session WAL, Model Context, tool environments, and durable result content. The selected raw Codex model ID is fixed in the Session before the first model Attempt. Ordinary tests use deterministic fake authorization, token, catalog, and Responses endpoints; only an explicitly selected compatibility test uses a real ChatGPT subscription.

Official Codex source treats `originator` as a client-owned identity: `codex_cli_rs` is its default,
but a caller can set another valid value and the request builder forwards the session value
([default client](https://github.com/openai/codex/blob/6478a751fde8884b2fdc76486fe23175a8e795d4/codex-rs/login/src/auth/default_client.rs#L36-L87),
[Responses request](https://github.com/openai/codex/blob/6478a751fde8884b2fdc76486fe23175a8e795d4/codex-rs/core/src/client.rs#L648-L661)).
Pinned Pi similarly sends its truthful `pi` identity and user agent rather than impersonating an
official surface ([Pi transport](https://github.com/badlogic/pi-mono/blob/853a80d26c90a14c1886f0ebb8ffaae133ca2185/packages/ai/src/api/openai-codex-responses.ts#L1493-L1527)).
OnePage therefore sends `originator: onepage`. Compatibility diagnostics retain only the closed
local/HTTP source and a validated provider `error.code` or `error.type`; they never retain a response
message, bearer token, account identifier, or raw response body.

Neither the public Codex SDK nor app-server documentation publishes the private ChatGPT backend endpoint
or an allow-list contract for arbitrary `originator` values. The pinned implementations above are therefore
compatibility evidence, not authority that the backend accepts `onepage`. Until an opt-in live run accepts
that truthful identity, a bounded `provider_http_403/originator_not_allowed` result is a feasibility blocker;
OnePage must not impersonate `pi` or `codex_cli_rs` to bypass it.

## Pi

### Adopt the irreducible loop

Pi's low-level loop has the useful essential shape: stream one assistant response, stop on provider error or abort, collect its tool calls, execute them, append typed results, and begin the next turn. It treats a length-truncated response as incapable of authorizing tool execution because its arguments may be incomplete ([source](https://github.com/earendil-works/pi/blob/dcd461925db2edf69a43c8135db1180d418afd54/packages/agent/src/agent-loop.ts#L152-L224)).

OnePage v1 should simplify further:

- at most one tool call per assistant response;
- exactly one accepted external operation at a time;
- no parallel tool batch;
- no in-page transcript array;
- incomplete or length-truncated output produces a typed failure result and no effect;
- `bash` and `apply_patch` are the complete tool vocabulary;
- a complete non-empty response with no tool call is the Final Answer.

This is enough for Bash inspection → structured patch → Bash verification → Final Answer without inventing an extensibility system.

### Adopt durable operation facts and replay classification

Pi's newer harness records operation start/finish separately from transcript entries. It also records step attempts and tool starts, including the effective arguments, result identity, and whether replay is `safe` or `never` ([source](https://github.com/earendil-works/pi/blob/dcd461925db2edf69a43c8135db1180d418afd54/packages/agent/src/harness/session/types.ts#L87-L160)).

OnePage already has submitted/accepted/completed records and generation fencing. It should add only the facts needed by the first loop:

- run started/finished;
- model attempt intent and delivery certainty;
- tool intent with immutable effective arguments and authority digest;
- approval requested/decided;
- durable content handle created;
- completion result and uncertainty disposition.

Replay safety belongs to the operation kind, not to a generic retry count. A `possibly_executed` Bash Attempt is indeterminate and never replays automatically; `apply_patch` reconciles exact preimage, postimage, or divergent state.

### Avoid the resident `Agent` object graph

Pi's established `Agent` owns resident message arrays, listener sets, steering and follow-up queues, promises, an abort controller, hooks, transport configuration, tool configuration, and mutable streaming state ([source](https://github.com/earendil-works/pi/blob/dcd461925db2edf69a43c8135db1180d418afd54/packages/agent/src/agent.ts#L125-L238)). That is ergonomic for an in-process TypeScript agent, but incompatible with OnePage's claim that sleeping agents are durable records rather than live object graphs.

### Avoid exposing the whole product through the harness interface

Pi's experimental durable `AgentHarness` interface exposes prompting, skills, templates, compaction, navigation, resume, abort, three queue modes, queue cancellation, usage recording, idle callbacks, manual action stepping, model/tool mutation, session access, and watches ([source](https://github.com/earendil-works/pi/blob/dcd461925db2edf69a43c8135db1180d418afd54/packages/agent/src/harness/agent-harness.ts#L265-L303)). Many methods are not yet implemented at the pinned revision.

Pi's session shape is more valuable to OnePage than its broad harness interface. Conversation entries are immutable nodes with stable identity and a parent link, while operation records are a separate type family for recovery and execution history ([source](https://github.com/earendil-works/pi/blob/dcd461925db2edf69a43c8135db1180d418afd54/packages/agent/src/harness/session/types.ts#L14-L74), [source](https://github.com/earendil-works/pi/blob/dcd461925db2edf69a43c8135db1180d418afd54/packages/agent/src/harness/session/types.ts#L80-L160)). Its context builder projects one path and treats the latest compaction entry as a replacement view over older entries rather than deleting the underlying tree ([source](https://github.com/earendil-works/pi/blob/dcd461925db2edf69a43c8135db1180d418afd54/packages/agent/src/harness/session/context.ts#L45-L99)).

OnePage should adopt those semantics in a smaller form: one session, one `main` leaf, immutable parent-linked entries, a separate operation journal, and deterministic branch-to-context projection. It should not adopt resident message arrays, multiple lanes, navigation commands, or compaction behaviour until the first task loop proves the storage and projection path.

This is useful negative evidence for OnePage. The first interface should not mirror every product capability. A deep harness should accept task/completion facts and return progress/outcome while keeping navigation, projection, provider, tools, and recovery inside its implementation.

## DeepSeek Harness findings that remain binding

The existing DeepSeek audit supplies the semantic durability rules that neither fx nor Pi alone fully provides:

- persist request or tool intent before dispatch;
- persist the result before advancing logical state;
- make every model-visible value reconstructable from durable records;
- commit authoritative events before publishing UI projections;
- spill complete output to disk while retaining a bounded RAM tail;
- keep process ownership until the whole subprocess tree reaches quiescence;
- avoid a full resident session log and plugin graph per agent.

See [`deepseek-harness-lessons.md`](deepseek-harness-lessons.md) for pinned source evidence.

## Resulting OnePage design constraints

1. The core command/event protocol is the highest semantic seam. It owns the agent loop and returns one bounded next disposition.
2. The native harness is one deep module around that core protocol. It owns durable effect ordering, page checkpoint/release, operation admission, completion application, and projection publication.
3. Model transport, repository/tool execution, approval input, storage, and output are internal seams because each has a production adapter and a deterministic test adapter.
4. The CLI and black-box tests call the same harness interface. The CLI does not reproduce orchestration logic.
5. The core selects ordered durable handles for model context. The host never receives permission to choose semantic context.
6. Tool handling separates decode/validation, authority and approval, durable admission, and execution.
7. Partial model output may be shown as a volatile projection but cannot authorize an effect.
8. UI and metrics consume committed events. Their failure cannot roll back agent state.
9. One logical agent, one active operation, and one page are enough for the first coding-task loop. Concurrency and capacity configuration follow measurement.
10. The external harness interface should remain small even if its implementation contains several internal modules and adapters.

## Open interface question

The research leaves one real choice for Design It Twice:

- a command/completion driver (`offer` + `drive`) that makes suspension explicit;
- a higher-level `run(task)` facade that owns the whole loop;
- or a process-level CLI seam with the harness entirely internal.

The strongest design will keep a high-level interface for callers and black-box tests while retaining the bounded command/completion protocol as an internal seam for deterministic fault and recovery tests.
