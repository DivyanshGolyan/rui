# Claude workflow API: Session initialization prior art

Checked 10 September 2026. Research input only; this note does not change OnePage's accepted contracts.

## Finding

Claude Code Dynamic Workflows provide useful precedent for composing agent work with JavaScript results. Their documented script API does not expose reusable worker Sessions, so it does not decide whether OnePage should use explicit creation or first-configuration initialization. Neither option follows from the syntax of `agent()`.

## Documented script boundary

The [official workflow guide](https://code.claude.com/docs/en/workflows#what-the-saved-script-looks-like) demonstrates `await agent(prompt, options)` producing data consumed by later script stages. It directs detailed API questions to the bundled `/workflow-authoring` reference.

The installed Claude Code 2.1.267 authoring reference documents:

| Surface | Contract relevant here |
| --- | --- |
| `agent(prompt, options)` | Starts a subagent; resolves with final text, a validated object, or `null` for specified terminal cases |
| Agent options | Label, phase, schema, model, effort, isolation and agent type; no documented worker Session key, reference, creation, configuration-update or continuation argument |
| `parallel(thunks)` | Waits for the group; failed members become `null`, rather than rejecting the group |
| `pipeline(items, stages...)` | Each item advances independently; a throwing stage produces `null` and skips that item's remaining stages |
| `workflow(nameOrRef, args)` | Invokes a child workflow and returns its result; the reference selects a workflow definition, not a worker conversation |

These are documented behavior claims from the bundled reference, not a runtime audit. In particular, its `parallel()` is not interchangeable with `Promise.all()` on failure.

## Identity, completion and replay

The [official cookbook](https://platform.claude.com/cookbook/claude-agent-sdk-08-dynamic-workflows) shows an outer `Workflow` launch followed by background execution and progress events. Launch and completion are separate SDK turns. This establishes that the outer launch can finish before the workflow, but does not specify a durable per-worker admission acknowledgement or when a provider request is sent. The example's task-ID extraction is explicitly a convenience rather than a stable API.

At the script boundary, awaiting `agent()` obtains the agent's outcome; it does not return a Session-creation acknowledgement. The bundled outer tool's `runId` / `resumeFromRunId` select workflow execution history, not a worker Session for another message.

The [current replay contract](https://code.claude.com/docs/en/workflows#resume-after-a-pause) reuses completed results in agent start order. The first changed prompt or failed agent invalidates that call and subsequent calls, including completed siblings. Interrupted workers start over. Results belong to the surrounding Claude session, and an unavailable prior result set causes relaunch to fail. This differs from an immutable binding between a caller request key and its original admission answer.

## Implications for the OnePage discussion

The following are design inferences, not Claude guarantees:

1. **Result composition is separable from Session lifecycle.** A convenient `agent()` wrapper can hide several core operations. Its compact syntax gives no evidence that initialization itself must be absent, lazy, atomic with the first message, or acknowledged only after model work starts.
2. **Caller-owned naming remains independent.** Constructing a local reference need not become a Session core operation merely because applying configuration is durable core work. A later request can use an already-known key while its Promise represents acceptance or completion.
3. **Real dependencies still matter.** If a message requires a successfully committed configuration, the workflow must express that dependency. Ordinary awaited operations can express it; no identity-discovery result is needed. Whether a convenience wrapper combines those operations is a separate interface choice.
4. **Reusable Sessions require an additional contract.** Claude's documented workflow surface cannot resolve creation-versus-configuration behavior for an unknown Session key, ordering of later configuration changes, or request-key scope. Those decisions need OnePage scenarios and its recovery guarantees.

The strongest usable precedent is therefore the separation of orchestration from agent execution and the direct use of results in subsequent code. The prior art does not select OnePage's Session lifecycle API.

## Evidence and limits

- Public documentation and cookbook were read live on the date above.
- Installed artifact: `/Users/divyanshgolyan/.local/share/claude/versions/2.1.267`, 200,489,184 bytes, SHA-256 `a681f3008f0050029aeebcab3af51bb6a55ddeb625a3af3141a4416d43cd2558`. The parent investigation extracted its bundled authoring reference; this comparison read the bounded extracted template, including the `agent(prompt` signature at byte offset 178,683,441.
- The public TypeScript reference could not be fetched in this pass: its HTML exceeded the fetch limit and its Markdown endpoint was unavailable through the attempted readers. No new claims rely on it.
- No workflow, model request, configuration mutation, latency measurement or crash test was performed. Internal durability, transaction boundaries and request dispatch timing remain unverified.
