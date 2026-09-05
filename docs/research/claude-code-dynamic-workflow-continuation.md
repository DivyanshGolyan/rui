# Claude Code dynamic workflows and Session continuation

> **Research record, published 6 September 2026.** Findings and proposals below reflect the dated investigation. Subsequent decisions are owned by [ARCHITECTURE.md](../../ARCHITECTURE.md) and [PRODUCT.md](../../PRODUCT.md); historical recommendations and implementation-ticket references do not override them.

Checked 5 September 2026. Research input to [Choose replay-stable Session continuation from agent results](https://github.com/DivyanshGolyan/onepage/issues/101); no interface decision is accepted by this note.

## Finding

Claude Code's workflow-script API returns the answer directly and does not expose a documented way to continue that worker's conversation. Its separate subagent and SDK interfaces do expose conversation identity. Workflow replay and conversation continuation are different contracts; copying the workflow return shape alone does not complete OnePage's existing reusable-Session contract.

## Native Dynamic Workflows

The official [workflow documentation](https://code.claude.com/docs/en/workflows) describes JavaScript orchestration with intermediate results in script variables. Its example reads the schema result directly. Individual agent cancellation or terminal API failure returns `null`. The page delegates the detailed API reference to the bundled `/workflow-authoring` skill.

The [resume contract](https://code.claude.com/docs/en/workflows#resume-after-a-pause) reuses completed results in start order. The first changed prompt or failed call causes that call and all later calls to run again, including completed siblings. Calls interrupted by stopping the whole workflow restart, without being classified as failed. Saved results are scoped to the parent Claude session.

### Bundled authoring reference

Read the installed official Claude Code artifact, version 2.1.261, without executing it. Its authoring reference describes:

- `agent(prompt, options)` returning final text or a schema-validated object, with `null` for an individually skipped agent or terminal API error.
- Options for labels, phase, schema, model, effort, isolation, and agent type. It documents no Session reference, agent continuation option, or result metadata accessor.
- Coordination through `pipeline`, `parallel`, `phase`, and `log`; inputs through `args`; a token-budget interface; and one-level child-workflow composition. None is a documented conversation-continuation capability.
- Workflow resumption through the outer tool's `runId` and `resumeFromRunId`. Its fallback advice concerns reading saved transcripts and authoring a continuation script, not a script-level method for reopening a worker.

This establishes the documented surface of the installed version, not a promise that every internal or future execution path lacks such a capability. A narrow runtime spot-check corroborates the separation: cached records contain an agent ID and a result, but the cache-hit path returns the result to the script and sends the ID through progress reporting. Internal possession of identity does not make it available to workflow code.

## Adjacent interfaces expose identity separately

| Surface | Identity and continuation | What it establishes |
| --- | --- | --- |
| Outer `Workflow` tool | Output `runId`; later input `resumeFromRunId` | Identity for replaying orchestration, not a worker conversation |
| Ordinary `Agent` tool | `agentId` alongside completed content or asynchronous launch details | Identity can be runtime metadata outside model output |
| Ordinary subagents | `SendMessage` addressed to an agent ID or name | Continuing a supported worker's existing history |
| Agent SDK session | `session_id` in result messages; later `resume` input | Explicit conversation selection across SDK invocations |

The [SDK TypeScript reference](https://code.claude.com/docs/en/agent-sdk/typescript) documents the first two rows as distinct tool contracts. A Workflow launch can return a background task ID before completion; its run ID is not an individual worker's ID. The ordinary Agent tool's output envelope cannot be assumed to be the value that workflow-script `agent()` returns.

The current [subagent documentation](https://code.claude.com/docs/en/sub-agents#resume-subagents) says supported workers retain history under the same ID on continuation. Explore and Plan are one-shot. Human cancellation blocks automatic resumption; completion or an agent-issued TaskStop does not impose that same restriction. Name-reuse protection refuses delivery when a previously addressed name resolves to a different worker. That protects identity, but the page does not specify an expected conversation revision. Search snippets showing older Agent.resume examples were not used as the current contract.

The [SDK session documentation](https://code.claude.com/docs/en/agent-sdk/sessions) supplies `session_id` on success and error result messages, with earlier access through initialization. Explicit `resume` selects a conversation; selecting the most recent session is weaker for concurrent callers. A process or transport failure may prevent a result from arriving, so result metadata alone cannot guarantee a caller learns the identity. The documented API does not establish an expected-revision precondition comparable to OnePage's. Session persistence also does not roll back filesystem changes.

## Implications for OnePage

These are design assessments, not decisions:

1. **Keep output distinct from runtime identity.** A model-generated schema field cannot be authoritative Session identity. Claude's ordinary Agent interface provides useful precedent for attaching metadata outside model output; its workflow interface avoids exposing continuation altogether.
2. **Preserve historical continuation facts.** OnePage needs the Session ID and both revisions fixed by a committed outcome. Reading whatever revisions are current when replay happens would let identical workflow code admit a different Turn. Claude's documented identity checks do not solve this stronger requirement.
3. **Keep completed keyed work reusable.** OnePage's immutable per-key binding is a better match for the accepted cost expectations than adopting ordered-prefix invalidation. A changed binding should retain its explicit conflict semantics; extra spending on unfinished work need not imply rerunning successful siblings.
4. **Define failure references deliberately.** Claude's workflow `null` combines several outcomes. OnePage already promises frozen typed Turn errors. Whether those errors also supply usable continuation facts depends on how failed Turns settle pending User Messages, the separate open decision.

The smallest candidates remain an explicit result envelope, or an explicit reference associated with the call while the awaited value remains unchanged. An envelope makes metadata easy to discover but changes successful return shape. A call reference preserves that shape but introduces another operation or handle, whose reconstruction after evaluator destruction must be specified. Neither needs a new server component. Neither is selected here.

The next design exercise should show the same two-Turn workflow under each candidate: create a Session, obtain the answer and continuation facts, discard the evaluator, replay, then continue the Session. Repeat after a failed Turn and after another caller advances the Session. The examples should reveal the simplest complete interface before any API is adopted.

## Reproducibility and limits

- OnePage source baseline: `3bdadc8395716e587f3da11f0b85ecdb3b91274a`; current working-tree design amendments were preserved.
- Local Claude artifact: `/Users/divyanshgolyan/.local/share/claude/versions/2.1.261`, 199,241,568 bytes.
- SHA-256: `5efecaff231b798be3c66def9be54183623b328b80eaef17f93c43987024e82a`.
- Zero-based byte anchors: authoring-reference heading `175589596`; `agent(prompt` signature `175593344`; resume heading `175606003`. Inspect bounded UTF-8 windows around these markers; the bundled template contains escaped punctuation and interpolation.
- Runtime corroboration: cache-return/progress path around `171770400`; journal result records around `171771224`. This was a local spot-check, not an audit of all runtime generations or deployment flags.
- Official TypeScript reference was also read through its `.md` endpoint because its HTML exceeded the browser fetch limit.
- No Claude process, workflow, model call, user transcript, or user configuration was executed or read. No crash-recovery or latency guarantees were experimentally tested. Live documentation can change; the installed reference is pinned above.
