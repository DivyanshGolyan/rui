# Rejected model tool calls: prior art and Rui boundaries

Research date: 2026-09-16. This report compares current local source checkouts of Codex CLI, OpenCode v2, Pi and DeepSeek Harness. It asks what happens when model-produced tool input is malformed, names an unavailable tool, fails parameter validation, fails before execution or is denied by a person. It is source evidence for the contract boundary adopted for [issue #198](https://github.com/DivyanshGolyan/rui/issues/198), not runtime qualification.

## Sources and method

Four independent read-only agents inspected one checkout each. The parent reread the principal parser, dispatch, permission and sibling-ordering paths. No upstream source was edited.

| Runtime | Branch and revision | Local checkout used |
| --- | --- | --- |
| Codex CLI | `main`, [`a592c38c16cdd7623dacc9168926ebccedfb67d3`](https://github.com/openai/codex/commit/a592c38c16cdd7623dacc9168926ebccedfb67d3) | `/Users/divyanshgolyan/Documents/GitHub/codex` |
| OpenCode | `v2`, [`cda2bc5100f3c0875f3240793f56ee9ee776d553`](https://github.com/anomalyco/opencode/commit/cda2bc5100f3c0875f3240793f56ee9ee776d553) | disposable clone `/tmp/rui-rejected-tool-research/opencode-v2` |
| Pi | `main`, [`6671c604766b3670ed95f405aa7856835d0ca702`](https://github.com/earendil-works/pi/commit/6671c604766b3670ed95f405aa7856835d0ca702) | disposable clone `/tmp/rui-rejected-tool-research/pi` |
| DeepSeek Harness | `master`, [`0d1f50007f9bca3f52b06e1c3074fa14d5fb0720`](https://github.com/deepseek-ai/deepseek-harness/commit/0d1f50007f9bca3f52b06e1c3074fa14d5fb0720) | disposable clone `/tmp/rui-rejected-tool-research/deepseek-harness` |

The disposable clones can be reproduced with their named branch and reset to the recorded commit. The comparison is static source and test inspection. It does not establish provider-side behavior before bytes reach these clients, production crash behavior or resource bounds.

## The important distinction

The implementations separate three cases that should not all be called an “invalid call”:

1. **No trustworthy call envelope exists.** The provider stream or response item is malformed, contradictory or cannot supply a usable call identity. There is no call to pair with a Tool Result.
2. **A call envelope exists, but the invocation cannot run.** It has a call identity and tool name, but its arguments are malformed, violate the tool schema, name no available tool or fail a tool precondition.
3. **A valid invocation is denied authority.** The call and descriptor are valid, but policy or a person refuses execution.

The systems differ at the first boundary and on denial policy. They mostly agree that the second case is a model-visible result for one call, not rejection of every sibling.

## Comparison

| Case | Codex CLI | OpenCode v2 | Pi | DeepSeek Harness |
| --- | --- | --- | --- | --- |
| Malformed provider event/item | Malformed SSE JSON and structurally invalid completed items are logged and dropped; stream/API failure can fail the model request. No synthetic Tool Result exists. | Provider-executed malformed calls fail the provider response. Local malformed calls depend on adapter: native parsing repairs them; the AI SDK path records an unexecuted `tool.input-json` failure. | Provider adapter failure records an assistant error and ends the run. Streamed argument JSON is otherwise repaired, with `{}` as the final fallback. | DeepSeek Messages rejects the complete response as `MALFORMED_RESPONSE`; Chat Completions retains opaque argument text for the tool layer. |
| JSON/schema-invalid parameters after a recognizable call | Handler decoding returns a failed `function_call_output`; the model receives it on the next request. | The captured tool runtime saves a failed tool result; the model receives it on continuation. | Validation produces an error Tool Result; the model receives it on continuation. | Typed tools produce `INVALID_ARGS`; the model receives the error Tool Result. |
| Unknown tool name | Failed output for that call; continuation follows. | Failed tool result for that call; continuation follows. | `Tool <name> not found` result; continuation follows. | `UNKNOWN_TOOL` result; continuation follows. |
| Tool precondition/implementation error | Expected errors become failed outputs; only explicitly fatal internal errors fail the turn. | Expected and most unexpected errors become failed tool state; continuation normally follows. | Throws become error Tool Results; continuation follows. | Throws and policy failures become error Tool Results; continuation follows. |
| Human denial | Failed output for that exact call; siblings continue. | A denial **with feedback** becomes one model-visible error. A no-feedback denial aborts the assistant step and rejects other pending permission requests in the Session; there is no normal continuation. | Extension/UI block becomes an error Tool Result for that call; siblings continue. | Rejected approval becomes an error Tool Result for that call; siblings continue. |
| One ordinary failed sibling | Does not cancel siblings; outputs are collected in call order. | Does not cancel siblings. A no-feedback permission denial is the exception above. | Does not cancel siblings; final result messages preserve source order. | Does not cancel siblings; results commit in model order. |

### Codex CLI

Codex retains function-call arguments as a raw string at the provider boundary. It records a recognized call before execution and queues one future for it ([`handle_output_item_done`](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/core/src/stream_events_utils.rs#L300-L411)). Built-in handlers deserialize and validate their own typed arguments; ordinary decoding and precondition failures use `RespondToModel`, while `Fatal` is a distinct internal-failure class ([handler parsing](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/core/src/tools/handlers/mod.rs#L85-L135), [`FunctionCallError`](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/tools/src/function_call_error.rs#L1-L10)). Unknown names similarly become `RespondToModel` rather than invalidating the response ([registry dispatch](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/core/src/tools/registry.rs#L495-L565)).

The tool runtime converts every nonfatal failure into a call-ID-bound output marked unsuccessful ([parallel runtime](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/core/src/tools/parallel.rs#L74-L94), [failure output](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/core/src/tools/parallel.rs#L246-L270)). Eligible siblings can execute concurrently; collection preserves call order. Approval denial is normalized through the same expected-error path, so it does not acquire response-wide authority ([approval conversion](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/core/src/tools/approvals.rs#L434-L463)).

One notable weakness is earlier than that boundary: malformed SSE JSON or a completed item that cannot deserialize is logged and skipped rather than converted to a model-visible error ([Responses SSE parser](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/codex-api/src/sse/responses.rs#L353-L364), [SSE JSON handling](https://github.com/openai/codex/blob/a592c38c16cdd7623dacc9168926ebccedfb67d3/codex-rs/codex-api/src/sse/responses.rs#L568-L683)). Rui need not copy that behavior.

### OpenCode v2

OpenCode has two relevant parsing paths. Its native tool stream tries strict JSON, then partial repair, and finally `{}` for a local tool; malformed provider-executed tools remain terminal ([shared parsing](https://github.com/anomalyco/opencode/blob/cda2bc5100f3c0875f3240793f56ee9ee776d553/packages/ai/src/protocols/shared.ts#L163-L170), [`ToolStream`](https://github.com/anomalyco/opencode/blob/cda2bc5100f3c0875f3240793f56ee9ee776d553/packages/ai/src/protocols/utils/tool-stream.ts#L72-L96)). Its AI SDK adapter instead emits a local malformed-input event. The Session publisher persists that exact input boundary and a failed, unexecuted `tool.input-json` result; replay gives the model a synthetic empty input plus the error rather than malformed JSON ([event conversion](https://github.com/anomalyco/opencode/blob/cda2bc5100f3c0875f3240793f56ee9ee776d553/packages/core/src/aisdk.ts#L707-L752), [malformed-input settlement](https://github.com/anomalyco/opencode/blob/cda2bc5100f3c0875f3240793f56ee9ee776d553/packages/core/src/session/runner/publish-llm-event.ts#L243-L321)).

The request captures a tool snapshot. That snapshot owns name lookup, while the tool runtime owns schema conversion/validation and implementation execution ([tool snapshot](https://github.com/anomalyco/opencode/blob/cda2bc5100f3c0875f3240793f56ee9ee776d553/packages/core/src/tool.ts#L220-L285), [runtime validation](https://github.com/anomalyco/opencode/blob/cda2bc5100f3c0875f3240793f56ee9ee776d553/packages/core/src/tool/runtime.ts#L28-L132)). Ordinary failures settle independently and the next request reconstructs call/result pairs from durable Session facts.

Permission denial is intentionally exceptional. A denial with feedback becomes a correction visible to the model. A no-feedback denial fails the selected deferred and every other pending permission request in that Session ([permission reply](https://github.com/anomalyco/opencode/blob/cda2bc5100f3c0875f3240793f56ee9ee776d553/packages/core/src/permission.ts#L254-L307)); the Session layer treats it as interruption rather than an ordinary model-visible Tool Result. This is a product choice, not a necessity imposed by the tool protocol.

### Pi

Pi’s adapters tolerate malformed streamed argument JSON with strict parsing, repair and partial parsing before falling back to `{}` ([streaming JSON parser](https://github.com/earendil-works/pi/blob/6671c604766b3670ed95f405aa7856835d0ca702/packages/ai/src/utils/json-parse.ts#L97-L124)). A provider-level error instead records an assistant error and ends the agent run without Tool Results ([agent-loop response boundary](https://github.com/earendil-works/pi/blob/6671c604766b3670ed95f405aa7856835d0ca702/packages/agent/src/agent-loop.ts#L211-L240)).

For an accepted response, the agent loop looks up each tool, prepares and validates arguments, invokes the optional pre-tool policy hook and turns any ordinary failure into one error result ([preflight](https://github.com/earendil-works/pi/blob/6671c604766b3670ed95f405aa7856835d0ca702/packages/agent/src/agent-loop.ts#L589-L675)). A permission extension uses that hook; a block supplies the Tool Result reason. Prepared calls can run concurrently, while final Tool Result messages retain assistant source order ([parallel execution](https://github.com/earendil-works/pi/blob/6671c604766b3670ed95f405aa7856835d0ca702/packages/agent/src/agent-loop.ts#L487-L560)). One blocked sibling does not stop permitted siblings.

### DeepSeek Harness

DeepSeek demonstrates that provider grammar can legitimately choose a stricter boundary than the generic tool runtime. Its Messages translator validates completed tool input as a JSON object and rejects the whole provider response if that check fails ([Messages translation](https://github.com/deepseek-ai/deepseek-harness/blob/0d1f50007f9bca3f52b06e1c3074fa14d5fb0720/packages/llm/llm-deepseek/src/protocols/messages/translate.ts#L140-L161)). Its Chat Completions translator retains argument fragments as opaque text. The shared agent loop then preserves invalid JSON as text rather than silently declaring a valid descriptor ([argument parsing](https://github.com/deepseek-ai/deepseek-harness/blob/0d1f50007f9bca3f52b06e1c3074fa14d5fb0720/packages/core/agent-loop/src/tool-calls.ts#L60-L111)).

The tool-definition owner validates schema immediately before implementation ([schema and `defineTool`](https://github.com/deepseek-ai/deepseek-harness/blob/0d1f50007f9bca3f52b06e1c3074fa14d5fb0720/packages/core/tools/src/schema.ts#L460-L588)). Unknown names, invalid parameters, expected failures and approval denial become one Tool Result. Calls may execute concurrently, but call/result persistence and added contexts commit in model order ([scheduler](https://github.com/deepseek-ai/deepseek-harness/blob/0d1f50007f9bca3f52b06e1c3074fa14d5fb0720/packages/core/agent-loop/src/tool-calls.ts#L113-L246)). Approval audit events remain host/UI facts; only the final denial result enters model context.

## What the comparison says about Rui

### Accepted boundary after review

Rui retains complete-candidate rejection when malformed or contradictory provider structure prevents faithful unique call/result correspondence. Once a trustworthy call envelope exists, an unknown tool or invalid descriptor receives a call-bound rejection result without an Action, permission or Attempt; valid siblings remain intact. A denied Action is different: it has a valid executable descriptor and receives an exact Resolution without an Attempt. Each outcome is accepted independently. Once every call has one, Rui derives Tool Results in original call order and continues the model without storing a second result copy ([architecture](../ARCHITECTURE.md#accepting-an-answer-or-tool-calls), [verification](../VERIFICATION.md#provider-validation-and-output-ownership)).

The denial rule agrees with Codex, Pi and DeepSeek: authority belongs to one exact Action, and refusing it does not silently rewrite siblings. OpenCode’s no-feedback denial is evidence for a different product policy, not evidence that denial must fan out.

The previous contract was stricter than all four systems for **recognizable calls with unknown tools or schema-invalid arguments**. Each inspected runtime can turn those into one failed Tool Result and preserve valid siblings. DeepSeek Messages supports whole-response rejection specifically for malformed provider grammar, while its generic tool layer still uses per-call errors. The accepted boundary now preserves that distinction.

### Responsibility map

| Responsibility | Home under Rui’s existing architecture | Must not own |
| --- | --- | --- |
| SSE/JSON grammar, terminal consistency, supported provider item variants and exact raw field ranges | Codex provider interpreter and its bounded metadata writer | Permission, current Session policy, Action admission or model retry policy |
| Whether a provider item is a recognizable function-call envelope with stable item ID, call ID, name and arguments field | Provider interpreter under the frozen wire contract | Whether the named tool was offered or executable |
| Frozen Tool Catalog lookup and descriptor validation | Core settlement using the proposing Operation’s historical view, delegating Bash/Edit argument semantics to the closed tool descriptor owner | Latest Session configuration, permission decisions or process launch |
| Atomic publication of assistant prefix, ordered calls and all child consequences | Store/core model-settlement transaction | External execution or temporary-file authority |
| One trustworthy call’s frozen-catalog classification and optional immutable rejection result | Producing model Operation's call facts | Permission, Attempt, custody or an Action-shaped invalid variant |
| One applicable proposal’s immutable descriptor, permission provenance and Resolution | Child Action owner | Rejected calls, sibling policy, Conversation order or provider transport |
| `ask`/`bypass` selection and exact keyed decision | Core permission owner at Action admission | Descriptor repair, batch denial or execution |
| Accepting each rejection/Resolution independently, then requiring complete coverage to derive call-ordered Tool Results and admit the next model Operation | Continuation owner introduced in #199 | A copied result batch, current-settings revalidation or physical completion order |
| Whole-Turn failure when no faithful call/result continuation can be formed | Existing model/Turn settlement owner | Converting an accepted exact denial into a provider failure |

The provider interpreter should establish what the provider actually said. The frozen Tool Catalog should establish whether that proposed invocation belongs to the request Rui made. Permission should answer only whether one valid invocation may execute. Keeping these checks separate does not require separate public layers or generic registries; each can remain a private operation of its current owner.

### Consequences for #198

1. **Candidate-invalid remains structural.** Malformed provider structure, missing/wrong-typed required fields, duplicate identity and contradictory order admit nothing because Rui cannot form trustworthy call/result correspondence.
2. **Descriptor-invalid is call-local.** Unknown tools, malformed argument JSON, wrong shapes and deterministic descriptor failures save bounded rejection results. They create no Action-shaped invalid variant, Permission Request, Authorization, Attempt or custody.
3. **Permission remains exact and independent.** Human denial resolves only its valid Action. Session stop remains the separate wider authority.
4. **Issue ownership follows the facts.** #198 owns envelope validation, frozen-catalog classification, atomic rejection/Action admission, observation and denial. #199 owns terminal acceptance provenance, complete-coverage continuation and call-ordered result derivation across mixed rejected calls and resolved Actions. #200 receives only exact authorized executable descriptors and owns Attempt admission and external-effect uncertainty.

The owning contract and verification cases record the accepted behavior. This report retains the source evidence and rationale; it does not qualify the implementation.

## Limits

- Provider services may reject, normalize or repair output before these local parsers see it.
- Codex currently drops some malformed events; that is observed implementation behavior, not a recommendation.
- OpenCode has materially different native and AI SDK adapters, so “OpenCode behavior” is route-dependent.
- Pi repairs malformed JSON aggressively; its per-call validation evidence is stronger for schema-invalid values than for preserving malformed raw input.
- DeepSeek Messages and Chat Completions intentionally differ at the provider boundary.
- This research did not exercise Rui, live providers, crashes, restart or resource accounting. Rui's owning contract and verification cases remain authoritative.
