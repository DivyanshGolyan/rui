# #2045 — Agent memory inside apps: Codex SDK and Claude Agent SDK

Date: 2026-11-23. Machine: the same Linux cloud container (4 vCPU, 16 GB) class used for Rui's published benchmark; the SDK rows were measured in this session, the Rui/pi/app-server/OpenCode rows are copied from `docs/waiting-agent-memory.md` and were **not** re-measured here.

## Answer

Both vendor SDKs run one OS process per agent, so memory grows by a whole agent process per agent.
Measured here, a waiting agent costs about **101–118 MB of private memory with the Claude Agent SDK** (TS 0.3.330, bundled Claude Code 2.1.330) and about **25 MB with the Codex TypeScript SDK** (0.171.0, one `codex exec` per run).
That is roughly 100x (Codex SDK) and 400x (Claude Agent SDK) pi's in-process SDK at about 0.27 MB per added agent, and about 3,000x / 12,000x Rui's ~0.008 MB per added agent.
Programs that run many agents at once on these process-per-agent models include OpenAI Symphony (default 10 concurrent, one `codex app-server` per issue), Vibe Kanban, Happy, Emdash and Conductor; OpenClaw used pi's in-process SDK but has since replaced it.

## Method (measured rows)

- Harness: a copy of `/mnt/project-files/blog-update-1030/linux-hold/hold.py` with two added server modes, `codex-sdk` and `claude-sdk`. Both launch one Node 22 process (`sdk_many.mjs`) that imports the SDK and starts N agents, each with its own cwd, against the same fake model that accepts the request and never answers. An agent counts as held when its tokenised request with a tool list reached the fixture. All N were held in every run.
  - Codex SDK: `new Codex().startThread({workingDirectory, skipGitRepoCheck:true}).run(prompt)` per agent; provider config points `codex` at the fixture (same `config.toml` as the published app-server row).
  - Claude Agent SDK: `query({prompt, options:{cwd, model}})` per agent, iterated; `ANTHROPIC_BASE_URL` points at the fixture (same env as the harness's existing `claude` mode).
- Metric: `Private_Dirty` from `smaps_rollup`, summed over the whole process tree (Node host + every spawned CLI), 10 s after all agents were held. Medians of 3 rounds. Decimal MB (KiB × 1.024 / 1000), same conversion as the published table.
- No real API keys were used; packages were installed from npm into the session scratchpad.
- Harness, driver, runner and raw results: `/mnt/project-files/zero-friction-map/research/2045-sdk-memory-harness/` (`hold.py`, `sdk_many.mjs`, `run.sh`, `results.jsonl`).
- Process model confirmed in source/docs:
  - Codex TS SDK `dist/index.js` (0.171.0) builds `["exec", "--experimental-json", ...]` and `spawn`s the `codex` binary for each `Thread.run` (read in installed package source). Measured: 1 + N processes.
  - Claude Agent SDK: "When your code calls `query()`, the SDK spawns a separate `claude` CLI process … One agent session maps to one subprocess. Running N concurrent sessions takes N subprocesses" — https://code.claude.com/docs/en/agent-sdk/hosting (sourced). Measured: 1 + N processes.

## Numbers

Private memory, MB, whole process tree, waiting agents.

| Runtime | 0 | 1 | 10 | 50 | 100 | Per added agent | Label |
|---|---|---|---|---|---|---|---|
| Rui | 1.7 | 2.2 | 2.2 | – | 2.5 | ~0.008 | published (repo doc) |
| pi SDK, in-process | 85.6 | 93.6 | 97.5 | – | 112.4 | ~0.27 | published (repo doc) |
| Codex app-server, one process | 14.7 | 25.5 | 49.6 | – | 206.5 | ~1.9 | published (repo doc) |
| OpenCode serve | 174.2 | 529.8 | 556.7 | – | 650.7 | ~4.8 | published (repo doc) |
| **Codex TS SDK** (`codex exec` per run) | 8.6 | 34.3 | 261.4 | 1,225.3 | 2,485.6 | **~24.8** | **measured here** |
| **Claude Agent SDK** (TS, `claude` per query) | 34.1 | 152.4 | 1,187.1 | 5,069.3 | not run | **~101–118** | **measured here** |

Per-agent figures: (value at N − value at 0) / N. Claude Agent SDK: 118.3 at N=1, 115.3 at N=10, 100.7 at N=50. Codex SDK: 25.7, 25.3, 24.3, 24.8 at N=1/10/50/100. Round-to-round spread was under 3% for every cell.

The 0-agent column for the SDK rows is the Node host with the SDK imported, before any agent; it is not comparable to Rui's daemon baseline.

Other figures from the same runs (measured): Claude Agent SDK RSS was about 8.9 GB at 50 agents (RSS double-counts shared pages; use Private_Dirty), so 100 agents were not run on the 16 GB machine. Codex SDK RSS was about 14.4 GB at 100 agents for the same reason.

Sourced comparison: Anthropic's hosting guide gives "1 GiB RAM, 5 GiB disk, and 1 CPU per agent" as "a reasonable starting point for a freshly started instance" and says memory "grows with session length and tool activity" (https://code.claude.com/docs/en/agent-sdk/hosting). Our ~0.1 GB is the idle floor of one waiting agent; the 1 GiB figure is the vendor's sizing guidance for a working agent.

Codex Python SDK (sourced, not measured): "The Python SDK controls the local Codex app-server over JSON-RPC" (https://learn.chatgpt.com/docs/codex-sdk). If one app-server hosts many threads it should cost about the app-server row (~1.9 MB per added agent); this is an **inference**, not measured. The Claude Python SDK spawns the same `claude` CLI per session (hosting guide), so its per-agent cost should match the TS row plus the Python host; **inferred, not measured**.

## Programs that run many agents at once

| Program | Runtime | Concurrency | Evidence |
|---|---|---|---|
| OpenAI Symphony (28.1k stars) | `codex app-server`, one subprocess per issue workspace | `max_concurrent_agents` default 10; reference `WORKFLOW.md` sets 10 | SPEC.md §5.3.5, §10.2 "Start the app-server subprocess in the per-issue workspace" — https://github.com/openai/symphony/blob/main/SPEC.md ; https://github.com/openai/symphony/blob/main/elixir/WORKFLOW.md |
| Vibe Kanban (28.8k stars; README says it is sunsetting) | per workspace: `npx @anthropic-ai/claude-code@2.1.119 … --output-format=stream-json` (same CLI protocol the Agent SDK drives) and `npx @openai/codex@0.132.0 app-server` | one agent per kanban workspace, no stated cap | `crates/executors/src/executors/claude.rs` lines 65, 190; `codex.rs` lines 448–453 — https://github.com/BloopAI/vibe-kanban |
| Happy (slopus/happy) | `happy-cli` depends on `@anthropic-ai/claude-agent-sdk ^0.3.328`; also wraps Codex | multiple sessions started from phone/web while the computer is online; no stated cap | https://github.com/slopus/happy/blob/main/packages/happy-cli/package.json ; packages/happy-cli/README.md |
| Emdash (6.3k stars) | detects installed provider CLIs (Claude Code, Codex, …), one per git worktree; root package.json references the claude-agent-sdk and codex platform packages | "Run multiple coding agents at once", no stated cap | https://github.com/generalaction/emdash |
| Conductor (closed source, macOS) | Claude Code / Codex per workspace (git worktree) | parallel workspaces, no stated cap | https://www.conductor.build/docs/core/parallel-agents ; whether it uses the Agent SDK is **unverified** |
| OpenClaw (pi, historical) | embedded pi via `createAgentSession()` in the gateway process | many agents per gateway | earlier docs/talks (e.g. https://www.ai.engineer/talks/vAIDdLKB6-w-piece-pi-embedding-openclaw-coding-agent); current docs say "OpenClaw owns the built-in agent runtime" and "No external agent framework packages remain" (https://docs.openclaw.ai/pi), and current package.json keeps only `@earendil-works/pi-tui` |

No public program was found that drives many concurrent threads through `@openai/codex-sdk` (TS) specifically; the large Codex orchestrators use `codex app-server` directly.

## Not verified / limits

- Waiting agents only, with a fake model; no tool runs, no long transcripts. Real sessions grow (the hosting guide says so).
- Codex binary here is 0.171.0; the published app-server row's Codex version was not rechecked, so cross-row Codex comparison may span versions.
- Claude Agent SDK at 100 agents not run (memory headroom); per-agent cost at 100 is extrapolated from the flat 50-agent slope.
- Python SDKs not measured; their figures above are inferences.
- Concurrency in the programs list is from their docs/config, not from user telemetry; how many agents their users actually run is unknown.
- Star counts are as shown on GitHub pages fetched 2026-11-23.
