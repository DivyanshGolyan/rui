# Claude Code dynamic workflows and OnePage

Research date: 2026-08-27

## Scope

This note uses current first-party Anthropic documentation, the Anthropic article introducing dynamic workflows, and 40 saved workflow scripts from the user's local Claude Code project history. It distinguishes Claude Code's native workflow runtime from Skills, the model-visible Agent tool, agent teams, hooks, and the Claude Agent SDK.

## Verdict

Claude Code dynamic workflows validate OnePage's possible product direction: a resource-bounded runtime for orchestrating many short-lived agents. They do **not** suggest making OnePage merely a library imported by a Claude workflow script.

A Claude dynamic workflow is an isolated JavaScript program whose runtime, outside any worker model, owns fan-out, barriers, loops, intermediate values, and result collection. The script calls `agent()` and `pipeline()`; it does not need the parent model to invoke the Agent tool for every worker. Only the final workflow result enters the parent conversation. This is deliberately script-held rather than turn-by-turn model-held orchestration ([workflow comparison and execution model](https://code.claude.com/docs/en/workflows#when-to-use-a-workflow), [saved script example](https://code.claude.com/docs/en/workflows#what-the-saved-script-looks-like)).

The adopted V1 direction for OnePage is therefore:

1. retain one native Zig Host Runtime as the sole agent runtime;
2. make model calls, tools, agent jobs, and user decisions asynchronous waits that relinquish the Activation Slot;
3. expose `onepage run workflow.js` through a fresh restricted QuickJS evaluator that is destroyed at every durable Job barrier;
4. reconstruct JavaScript control from exact source, arguments, and durable keyed Job Outputs rather than checkpointing a VM;
5. defer an Agent-like model-visible tool for recursive/model-directed delegation such as RLMs.

"Asynchronous" should mean that an outstanding wait does not retain an Activation Slot. It should not mean that every effect may run concurrently. Anthropic concurrently executes read-only calls but serializes state-changing tools; custom tools default to sequential execution unless marked read-only ([Agent SDK loop](https://code.claude.com/docs/en/agent-sdk/agent-loop)). OnePage should make waiting uniform while retaining explicit admission, ordering, and conflict rules.

## What dynamic workflows actually are

Dynamic workflows require Claude Code 2.1.154 or later. They are available on paid Claude Code plans and supported provider routes. Claude writes a JavaScript script for the requested task, then an isolated runtime executes it in the background while the interactive session remains responsive ([official workflow documentation](https://code.claude.com/docs/en/workflows), [Anthropic introduction](https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code)).

The division of responsibility is unusually explicit:

| Mechanism | Who owns the next step? | Where intermediate results live |
| --- | --- | --- |
| Subagent | Claude, turn by turn | Parent model context |
| Skill | Claude following instructions | Model context |
| Agent team | Lead agent, turn by turn | Shared task list and agent contexts |
| Dynamic workflow | JavaScript runtime | Script variables |

The workflow body is plain JavaScript with top-level `await`. `agent(prompt, options)` starts one worker. `pipeline(items, callback)` invokes a worker for each item and resolves to an array of results. Normal JavaScript supplies branching, filtering, reduction, tournaments, and iterative stopping conditions. An agent that is stopped or ends on an unrecoverable API error resolves to `null`, which the script must handle ([script shape](https://code.claude.com/docs/en/workflows#what-the-saved-script-looks-like)).

This answers an important design question: the workflow generally **joins agents externally**. A synthesizer can be another explicit `agent()` call receiving prior results, but the runtime holds those prior values and decides when the barrier has completed. The workers do not need the Agent tool merely to participate in this graph.

The saved scripts confirm that this is the normal practical shape, not just a documentation example. They export phase metadata, invoke schema-constrained leaf agents through `agent()`, use `parallel()` for independent fan-out, use `pipeline()` for staged map-and-verify work, retain intermediate results in JavaScript values, and often finish with a dedicated synthesis agent. Several scripts deliberately run candidate-finding, adversarial verification, and synthesis as separate barriers. None relies on a worker invoking an Agent tool to form or join the graph.

The runtime records progress and completed agent results, which makes a stopped run resumable within the same Claude Code session. Resume is limited: a worker that had not finished restarts, and all workers started after the first unfinished worker replay as well, even if they had completed. Exiting Claude Code starts the workflow fresh in the next session ([resume semantics](https://code.claude.com/docs/en/workflows#resume-after-a-pause)). OnePage's durable Operation/Attempt model could provide stronger cross-process recovery without copying this replay rule.

## Agent tool versus workflow-owned agent calls

Claude Code's Agent tool is model-directed delegation: Claude decides during its agent loop to create a subagent. A dynamic workflow's `agent()` is script-directed orchestration: the already-approved program decides when and how many workers to start.

The Agent tool remains useful when delegation itself is part of the model's reasoning. Current Claude Code can let subagents spawn nested subagents up to a default depth of three, and it has a default limit of 20 concurrently running Agent-tool subagents. Both limits are configurable. Workflow agents and agent-team peers have separate limits ([nested subagents and concurrency](https://code.claude.com/docs/en/sub-agents#let-subagents-spawn-their-own-subagents)).

For OnePage this suggests two separable surfaces over one native agent runtime:

- a host-facing `start_agent`/`await_agent` job capability for deterministic workflow code;
- an optional model-visible `Agent` tool that submits the same kind of child job when a model chooses to delegate.

The first is sufficient for V1 dynamic workflows. The second is needed only for a genuinely recursive language-model design where a model can decide to call another model, so it remains post-V1. A future model-visible Agent tool should submit the same kind of durable Job without inheriting ambient authority.

## Background work, waiting, and joins

Claude Code subagents may run in the foreground or background. Foreground delegation blocks the parent turn; background delegation lets the session continue and later delivers a completion notification. A background result is not silently merged while the model is generating: Claude observes it on a later turn and waits for the notification before reporting the result ([foreground and background subagents](https://code.claude.com/docs/en/sub-agents#run-subagents-in-foreground-or-background)).

Dynamic workflow runs are themselves background tasks. The user can inspect phases and workers, pause or resume the run, stop or restart workers, and receive the final report when the graph completes ([workflow progress](https://code.claude.com/docs/en/workflows#watch-the-run)). A workflow has up to 16 concurrent workers, reduced when the host exposes fewer CPUs, and up to 1,000 total workers per run ([workflow limits](https://code.claude.com/docs/en/workflows#behavior-and-limits)). Anthropic also warns that workflows can consume materially more tokens and subjects runs to the user's plan and rate limits ([workflow cost](https://code.claude.com/docs/en/workflows#cost)).

These are host-level resource limits, not per-conversation memory reservations. This is close to OnePage's desired separation:

- a Session records semantic progress;
- an Operation can be waiting without holding an Activation Slot;
- the host admits actual model/tool/agent Attempts under global concurrency, memory, and provider-rate budgets;
- a completed child result wakes the parent workflow as a new bounded activation.

Every V1 potentially long wait should use that lifecycle, including model transport, subprocesses, Jobs, and Permission Decisions. The architectural invariant is **no scarce activation memory remains pinned merely because an external party has not answered**. V1 does not turn arbitrary human interaction into a workflow intrinsic; the foreground CLI supplies Permission Decisions through the ordinary Harness input seam.

Parallelism is a separate decision. Anthropic runs read-only tools concurrently, while `Edit`, `Write`, and `Bash` run sequentially to avoid conflicts; in-process custom tools are sequential unless their MCP annotations contain `readOnlyHint` ([tool scheduling](https://code.claude.com/docs/en/agent-sdk/agent-loop)). OnePage adopts a simpler V1 rule: arbitrary Bash is never classified as read-only, and a bounded Host-owned fence serializes Bash and patch Attempts per exact Workspace. Effects against different Workspaces and model calls may still proceed concurrently.

## User input is asynchronous, but not a Claude workflow feature

Claude dynamic workflows do not allow arbitrary mid-run user input. Only permission prompts can pause a run; a workflow requiring sign-off between stages must be split into separate workflows ([workflow limits](https://code.claude.com/docs/en/workflows#behavior-and-limits)).

The Claude Agent SDK has a different interaction model. Permission requests and `AskUserQuestion` calls suspend execution through an asynchronous `canUseTool` callback. That callback may remain pending indefinitely; TypeScript also supports a deferred decision that lets the process exit and resume later from persisted session state ([approvals and user input](https://code.claude.com/docs/en/agent-sdk/user-input)). Streaming input supports follow-up messages and interruptions during a long-lived session ([streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)).

OnePage already models a Permission Decision as asynchronous Harness input rather than a blocking function inside an Activation Slot. V1 does not expose general durable human input to workflow JavaScript. A broader caller event capability may be considered later if a concrete workflow needs it.

## Skills, commands, hooks, plugins, and the SDK

These surfaces are complementary rather than interchangeable:

- **Skills and commands** are reusable instructions that Claude follows. A Skill can run in the main context or a forked subagent, and Claude can invoke it from its description. Skills do not provide a deterministic workflow graph by themselves ([Skills](https://code.claude.com/docs/en/skills)).
- **Hooks** are deterministic reactions to lifecycle events. They can enforce permissions, transform a tool request, run checks, or inject later context. Asynchronous command hooks continue in the background, but cannot retroactively block an action that already happened ([Hooks](https://code.claude.com/docs/en/hooks#run-hooks-in-the-background)).
- **Plugins** distribute Skills, subagents, hooks, MCP servers, and saved workflow scripts. A OnePage Claude integration could naturally ship this way ([Plugins](https://code.claude.com/docs/en/plugins), [workflow distribution](https://code.claude.com/docs/en/workflows#distribute-a-workflow-in-a-plugin)).
- **Agent teams** are experimental peer sessions coordinated by a lead through a shared task list and mailbox. They suit communicating long-running peers rather than a script-owned high-fan-out graph ([agent teams](https://code.claude.com/docs/en/agent-teams)).
- **The Agent SDK** embeds Claude's agent loop in a Python or TypeScript application and supports custom asynchronous tools, subagents, sessions, hooks, streaming input, and permissions ([Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)).

A saved Claude workflow cannot import a OnePage library, call the filesystem, or execute shell commands directly. Its workers perform effects, and dynamic `import()` is rejected ([workflow runtime constraints](https://code.claude.com/docs/en/workflows#behavior-and-limits)). OnePage should therefore not target Claude's proprietary workflow runtime as an embedding API. Its own caller-agnostic CLI should execute a supplied workflow script; Claude Code, Codex, CI, or a person may create or invoke that script without a Claude-specific OnePage interface.

There is also an authentication boundary. Anthropic states that third-party applications built on the Agent SDK may not offer claude.ai login or subscription rate limits without prior approval; they should use API-key authentication. That restriction does not prevent a plugin or workflow running inside a user's own Claude Code session from using that session, but it means OnePage should not assume it can embed Claude subscription access as a provider ([Agent SDK authentication policy](https://code.claude.com/docs/en/agent-sdk/overview#compare-the-agent-sdk-to-other-claude-tools)). This does not affect the separate decision to make Codex subscription access OnePage's first provider.

## Accepted V1 boundary

V1 uses one native Zig Host Runtime as the sole agent runtime and a fresh restricted QuickJS process
only as the caller-side evaluator. The caller-agnostic CLI replays exact stored source and arguments
against durable keyed Jobs; every Job owns an ordinary Session and returns a bounded Job Output. No
JavaScript process or continuation survives a durable barrier.

V1 does not add a model-visible Agent tool, general durable human waits, a Host-owned DAG, recursive
delegation, or a second agent runtime. Host admission remains bounded by transferable Active Credits.
Because arbitrary Bash cannot be assumed read-only, one bounded Workspace Effect Fence serializes
admitted Bash and patch effects per Workspace while allowing model calls and effects in different
Workspaces to proceed concurrently. RLM execution remains an architectural compatibility goal rather
than a V1 product claim.

## Resolved decisions and remaining implementation gates

1. **Script surface.** V1 uses `export default async function workflow({ agent }, args)` and one explicit `agent({ key, task, input, schema, agent_profile })` shape. Ordinary JavaScript owns composition; OnePage supplies no helper API. A Claude plugin or MCP wrapper can be added later without changing that contract.
2. **Workflow compatibility.** The saved scripts establish the practical JavaScript shape, but Anthropic does not promise that its runtime helper API or on-disk schema is a stable third-party extension contract. Treat the scripts as workload examples and acceptance fixtures, not an API to clone.
3. **Job Output contract.** V1 returns Final Answer text or one bounded canonical data value locally validated against the bound schema; it does not pass a Conversation subtree into JavaScript.
4. **Cancellation and late completion.** Run cancellation stops new Job admission but cannot erase admitted effects. Late terminal evidence remains durable and cannot complete a cancelled Run.
5. **Conflict domains.** The Host serializes every admitted Bash and patch Attempt per exact Workspace through a Workspace Effect Fence; it never guesses that arbitrary Bash is read-only.
6. **RLM scope.** RLM execution is an architectural compatibility goal, not a V1 product claim. Recursive model-visible delegation adds prompt, budget, depth, and abuse-policy questions that require a later decision.

## Ambiguities

- Claude Code's workflow feature is new and version-sensitive. Current limits and subagent nesting behavior have already changed across recent releases.
- The public documentation describes the workflow script shape but not a compatibility guarantee for implementing or replacing its runtime.
- Dynamic workflows, ordinary Agent-tool subagents, and agent teams use separate concurrency policies; their exact internal scheduling is not public.
- Anthropic documents subscription availability for workflows inside Claude Code and API-key requirements for third-party Agent SDK products. Any deeper subscription-based embedding assumption needs a legal and technical feasibility check.
- The saved scripts are generated artifacts from the user's local Claude Code history, not a public compatibility contract. Their helper calls and metadata may change with Claude Code versions.
