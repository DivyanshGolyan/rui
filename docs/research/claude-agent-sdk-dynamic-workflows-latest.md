# Claude Agent SDK and Dynamic Workflows

Date: 2026-09-02

Status: current primary-source research for the OnePage comparison benchmark.
This is not a normative OnePage architecture contract.

## Recommendation

Use the **Python Claude Agent SDK to launch and observe a saved Dynamic
Workflow**, because it gives us a repeatable, non-interactive run and structured
progress and completion events. Do not use many concurrent `query()` calls:
that creates many Claude Agent processes and measures a different topology.

Do not make the SDK run the only published Claude Code memory number. Run the
same saved workflow twice:

1. directly through headless Claude Code, for the clean `Claude Code`
   comparison; and
2. through one Python Agent SDK `query()`, for reproducible orchestration,
   event capture, and the full developer-harness comparison.

Report the whole process-tree footprint in each case. For the SDK run, also
report the Python controller and its Claude Code child separately, but do not
subtract the controller from the headline total. If the headline names Claude
Code, use the direct headless result. If it names the Claude Agent SDK, use the
combined SDK process-tree result.

## Current support

As checked on 2026-09-02, the latest published releases are:

| SDK | Version | Bundled Claude Code |
| --- | ---: | ---: |
| [TypeScript package](https://www.npmjs.com/package/%40anthropic-ai/claude-agent-sdk?activeTab=versions) | `0.3.258` | `2.1.258` |
| [Python package](https://pypi.org/project/claude-agent-sdk/) | `0.2.151` | `2.1.258` |

The Python package records the bundled version directly in its
[`_cli_version.py`](https://github.com/anthropics/claude-agent-sdk-python/blob/v0.2.151/src/claude_agent_sdk/_cli_version.py).
Anthropic's official Dynamic Workflow cookbook requires only Claude Code
`2.1.154+` and Python SDK `0.2.90+`, so both current SDKs are comfortably beyond
the required floor. The SDK bundles and drives the Claude Code runtime; the
workflow implementation lives in that runtime, not in Python or TypeScript
itself ([cookbook](https://platform.claude.com/cookbook/claude-agent-sdk-08-dynamic-workflows)).

Dynamic Workflows are therefore **officially supported from the Agent SDK, but
they are not a host-language workflow API**. The documented path is:

- permit the `Workflow` tool;
- send one prompt through `query()` asking to run a workflow, or invoke a saved
  workflow command; and
- consume launch, progress, notification, and final-result messages from the
  query stream.

Claude calls `Workflow` with a complete JavaScript script and the Claude Code
runtime executes it. There is no documented Python or TypeScript
`runWorkflow(script)` method. The official SDK example describes this exact
flow and notes that one stream carries both the launch turn and the completion
turn ([Agent SDK Dynamic Workflow cookbook](https://platform.claude.com/cookbook/claude-agent-sdk-08-dynamic-workflows)).

## Live tool-call probe

We verified the boundary locally with Claude Code `2.1.258` on 2026-09-02. A
headless Sonnet session was allowed only the `Workflow` tool and asked to launch
one subagent that returned `PONG`. The persisted transcript contained this
successful call shape:

```json
{
  "name": "Workflow",
  "input": {
    "script": "export const meta = { ... }\nconst result = await agent(...)\nreturn result"
  }
}
```

The tool result returned a task ID, run ID, transcript directory, persisted
script path, and instructions for later calls using `scriptPath` and optional
`resumeFromRunId`. The SDK package exports type definitions for
`WorkflowInput` and `WorkflowOutput`; accepted input fields are `script`,
`name`, `args`, `scriptPath`, and `resumeFromRunId`.

It does **not** export a public method for invoking a built-in tool. Its public
execution surface remains `query()` (plus session and control methods), whose
input is a string or stream of user messages. `Workflow` is an in-process
Claude Code tool: the runtime executes it when a model response contains the
tool-use block. Sending an equivalent tool-use block through the Anthropic
Messages API would merely hand the call back to the API client; it would not
gain access to Claude Code's private Workflow runtime.

The probe also exposed why a saved workflow is preferable for benchmarking.
Claude's first script wrapped the body in `export default async function`,
which the runtime rejected. Claude repaired it and called `Workflow` again.
The tiny one-agent probe therefore used two orchestration turns and cost about
`$0.196`, before considering the repeatability problem introduced by generating
the script afresh on each run.

Direct invocation could only be achieved by depending on an undocumented
Claude Code internal protocol or reimplementing the Workflow runtime. Neither
is a sound benchmark or production dependency. The supported deterministic
route is to save the script and ask one SDK query to invoke that named workflow;
that still uses a model turn to issue `Workflow`, but avoids regenerating and
repairing the orchestration script.

## Can a saved workflow script run through the SDK?

Yes. Claude Code saves reusable scripts under `.claude/workflows/`; they become
slash commands that can be invoked again. A script may use the runtime globals
`agent()`, `parallel()`, `pipeline()`, `phase()`, `log()`, and `args`, with plain
JavaScript between them
([Dynamic Workflows documentation](https://code.claude.com/docs/en/workflows)).
The Agent SDK loads project filesystem features through `settingSources`
([SDK filesystem features](https://code.claude.com/docs/en/agent-sdk/claude-code-features)).

The boundary matters:

- `agent()` creates one clean-context Claude Code subagent;
- `parallel()` is a barrier over concurrent agent tasks;
- `pipeline()` lets separate items advance through stages independently;
- intermediate results remain in script variables and only the returned value
  reaches the launching conversation; and
- these names are globals inside the isolated Workflow runtime, not imports or
  SDK functions available to the Python or TypeScript controller.

The script itself cannot load modules or directly use the filesystem or shell;
only its agents can use configured tools. Claude Code currently permits at most
16 simultaneously running Workflow agents (possibly fewer on a CPU-limited
host), 1,000 agents total per run, and 4,096 items in one `parallel()` or
`pipeline()` call
([behavior and limits](https://code.claude.com/docs/en/workflows#behavior-and-limits)).

## Relevant SDK primitives

| Need | Current primitive | Source |
| --- | --- | --- |
| One autonomous run | `query()` returns an asynchronous message stream; `ClaudeSDKClient` supports a continuing interactive session | [Python SDK repository](https://github.com/anthropics/claude-agent-sdk-python) |
| Programmatic subagents | `agents` definitions plus the `Agent` tool; each subagent has a fresh context and returns to its parent | [SDK feature mapping](https://code.claude.com/docs/en/agent-sdk/claude-code-features#choose-the-right-feature) |
| Dynamic orchestration | Claude's `Workflow` tool executes `agent()` / `parallel()` / `pipeline()` scripts | [official cookbook](https://platform.claude.com/cookbook/claude-agent-sdk-08-dynamic-workflows) |
| Independent parallel runs | The host language may run independent `query()` calls concurrently; each call is a separate agent process, so this is not the Dynamic Workflow topology | [parallel-query use case](https://platform.claude.com/cookbook/claude-agent-sdk-00-the-one-liner-research-agent), [process model](https://platform.claude.com/cookbook/claude-agent-sdk-07-hosting-the-agent) |
| Sessions | Disk-persisted session IDs with continue, resume, and fork; Python also offers `ClaudeSDKClient` for multi-turn use | [session guide](https://code.claude.com/docs/en/agent-sdk/sessions) |
| Tools | Claude Code built-ins, MCP servers, and in-process SDK MCP tools | [Python SDK repository](https://github.com/anthropics/claude-agent-sdk-python#using-tools) |
| Hooks | Filesystem hooks and programmatic callbacks across the agent lifecycle | [hooks in the SDK](https://code.claude.com/docs/en/agent-sdk/claude-code-features#hooks) |
| Permissions | allow and deny rules, permission modes, `canUseTool`, and pre-tool hooks | [permission evaluation](https://code.claude.com/docs/en/agent-sdk/permissions) |
| Streaming | Complete assistant messages by default; optional partial API events, plus Workflow task progress and notifications in the normal query stream | [streaming output](https://code.claude.com/docs/en/agent-sdk/streaming-output), [Workflow SDK example](https://platform.claude.com/cookbook/claude-agent-sdk-08-dynamic-workflows) |

## Benchmark consequence

The SDK is better for **orchestration evidence**:

- a checked-in script makes fan-out deterministic instead of relying on the
  lead model to decide how many agents to spawn;
- structured task events expose launch, progress, completion, failure, cost,
  and elapsed time without opening the interactive UI; and
- one parameterized launcher can repeat cold and warm runs at the requested
  sizes.

It is not automatically better for an apples-to-apples **memory** claim. The
SDK adds a Python or Node controller around the bundled Claude Code runtime.
Anthropic explicitly describes an Agent SDK agent as a process and its session
as disk-persisted conversation state
([hosting model](https://platform.claude.com/cookbook/claude-agent-sdk-07-hosting-the-agent)).
Measuring only the Claude child would hide part of the harness a developer has
to run; measuring the combined tree and calling it merely "Claude Code" would
also conflate two products. The paired direct/SDK runs resolve that ambiguity.

## Codex-backed SDK measurement

On 2026-09-02, we ran the saved eight-agent heavy-read workflow through the
Python SDK and its bundled Claude Code runtime, with every Claude model alias
mapped to `gpt-5.6-sol` through a loopback-only CLIProxyAPI instance authenticated
with Codex OAuth. `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` were both absent from
the launched processes. The run completed all eight agents successfully.

An external sampler recorded macOS physical footprint every two seconds for the
Python controller and its descendant Claude Code process. The separately
running provider proxy was deliberately excluded, just as remote provider
infrastructure is excluded from a normal Claude Code measurement.

| Phase | Samples | Whole tree | Python controller | Claude Code child |
| --- | ---: | ---: | ---: | ---: |
| Connected baseline | 7 | 189 MiB median | 64 MiB median | 125 MiB median |
| Eight agents active | 13 | 229 MiB median; 245 MiB peak | 65 MiB median | 164 MiB median; 180 MiB peak |
| 90-second post-completion retention | 44 | 246 MiB median; 246 MiB final | 65 MiB median | 181 MiB median; 181 MiB final |

Relative to the connected baseline, the workflow added **40 MiB at the active
median**, **56 MiB at the active peak**, and retained **57 MiB after 90
seconds**. This single run corroborates the earlier direct Claude Code
observation that an eight-agent Dynamic Workflow costs on the order of 45--60
MiB, but it is not yet a publication-grade distribution: cold/warm repetitions
and the equivalent OnePage fixture remain necessary.

The 189 MiB connected baseline is not agent memory. It is the resident SDK
controller and Claude Code runtime before fan-out. Likewise, the 246 MiB
post-completion footprint shows that completed workflow state remained resident
during the observation window; it must not be presented as active-agent cost.
Changing the provider model makes this probe independent of the Claude model
subscription, but does not remove Claude Code's own runtime and workflow
machinery—the memory under comparison.

## Simplest comparison topology

1. Check in one parameterized, read-only saved workflow in an isolated fixture
   workspace. Every agent receives the same bounded coding task and performs
   the same model, file-read, shell, and bounded-result shape. Use the script's
   `args` only for agent count and run identifier.
2. Pin SDK, bundled Claude Code, model, effort, tools, permissions, working
   directory, and environment. Load only project settings needed to discover
   the workflow; disable unrelated user/local settings, plugins, hooks,
   connectors, skills, and auto-memory.
3. Start **one** Dynamic Workflow from **one** headless Claude Code session or
   **one** SDK `query()`. Do not fan out with eight independent SDK queries.
4. Run counts `1`, `8`, and `24`. Eight gives the direct comparison. Twenty-four
   proves queueing above the runtime's observed local concurrency. Record actual
   simultaneously running agents from task events rather than treating requested
   membership as concurrency.
5. Sample physical footprint every two seconds from an external sampler. Record
   idle baseline, active peak/delta, completion, and 90-second retained memory
   for the full process tree; repeat cold and warm trials.
6. Run the identical semantic fixture through OnePage at `1`, `8`, `24`, and
   `100`. Compare OnePage and Claude at equal observed concurrency first, then
   report OnePage's 100-active result separately. Claude Code's documented
   Workflow ceiling means a claim about 100 simultaneous Claude Workflow agents
   would be false.

This produces two defensible statements instead of one muddled ratio:

> Eight equivalent agents add X MiB in OnePage and Y MiB in Claude Code.

> OnePage sustains 100 concurrent agents at Z MiB; Claude Code Dynamic
> Workflows currently cap local concurrency at 16 or fewer.
