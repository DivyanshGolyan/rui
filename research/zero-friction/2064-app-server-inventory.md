# #2064: codex app-server protocol against Rui's adapter design

Researched 2026-11-23 from source. Read, not run: no app-server, Symphony or Vibe Kanban process was started.

## Answer

Both apps launch app-server through a command string the user can change. Symphony's `codex.command` (default `codex app-server`) and Vibe Kanban's profile `base_command_override` each accept a Rui binary with no code change to the app. The binary has to speak app-server JSON-RPC (newline-delimited JSON on stdio). Rui's Host speaks HTTP over a Unix socket and has no `app-server` subcommand, so a thin stdio adapter has to be built.

The core loop maps onto Rui's Host commands: `initialize`, `thread/start`, `turn/start`, the `turn/completed` ending, command approvals, `item/completed` for messages and Bash, token usage and model choice. Every server-to-client event has to be derived from Rui's pull feed, which is the "pushed feed" gap already named. Three more needs land in gaps the pi map already names: Symphony's `item/tool/call` (app-run tools), `item/agentMessage/delta` (streaming text, #2042) and Vibe's `thread/fork` (branching, #2036). The adapter design does not cover file-change items or approvals, plan and diff notifications, `item/tool/requestUserInput`, or Vibe's `account/read` gate.

## Sources

- Symphony: `openai/symphony` main, `SPEC.md` §§ on `codex.command` (lines 468–478, 627, 953–1035) and `elixir/lib/symphony_elixir/codex/app_server.ex` (1071 lines), `status_dashboard.ex`, `config/schema.ex:181`, `tracker.ex:138`.
- Vibe Kanban: `BloopAI/vibe-kanban` main, `crates/executors/src/executors/codex.rs`, `codex/client.rs`, `codex/normalize_logs.rs`, `crates/executors/src/command.rs:179`, `crates/executors/Cargo.toml:40-41`.
- Protocol: `openai/codex` tag `rust-v0.132.0`, `codex-rs/app-server-protocol/src/protocol/common.rs`, which holds the method-name table. Also `codex-rs/app-server/README.md` on main.
- Rui: `src/protocol.zig:692-723` (request union), `src/command_input.zig:412`, `src/mutation_answer.zig:14`, `clients/ts/src/{sessions,feed,client}.ts`, `docs/contracts/inspection.md`, `ARCHITECTURE.md:15,97`, and issues #2034, #2036 (resolution comment) and #2042.

## Launch and swap

| | Symphony | Vibe Kanban |
|---|---|---|
| Command | `bash -lc "exec <codex.command>"` in the issue workspace, or over SSH (`app_server.ex:192-235`) | `npx -y @openai/codex@0.132.0` + `app-server` [+ `--oss`] (`codex.rs:447-458`) |
| Configurable | yes: `codex.command`, a shell string with default `codex app-server` (`schema.ex:181`, SPEC:627) | yes: profile `cmd.base_command_override` (shlex-split) and `additional_params` (`command.rs:179-193`). `app-server` is still appended, so Rui would be run as `rui app-server`. |
| Version check | none. SPEC says to follow "the targeted Codex app-server version" | no `--version` call. The availability check is only that `~/.codex/version.json` or the Codex MCP config exists (`codex.rs:273-285`). The version is pinned at compile time: Vibe deserializes with `codex-app-server-protocol` from tag `rust-v0.132.0`, so the replies have to match that schema's types. |
| Handshake | `initialize` with `experimentalApi:true` and clientInfo `symphony-orchestrator`, then the `initialized` notification | same, with clientInfo `vibe-codex-executor` |
| Stop/interrupt | neither sends `turn/interrupt`. Symphony stops on `turn_timeout_ms` and the port ends. Vibe kills the process group (`kill_on_drop`, cancel token). It reads `turn/completed` with status `interrupted` but never asks for one. | |

Swap verdict: with a `rui app-server` stdio adapter, neither app needs a code change; each needs one configuration value. Vibe also needs `account/read` to report signed-in or `requiresOpenaiAuth:false` (`codex.rs:600-605`). Otherwise it refuses with `AuthRequired`.

## Inventory

Legend for the Rui column. **Served**: a Host command or feed row exists today. **Served, gap: pushed feed**: the data exists, but Rui serves it through the pull `activity_page` feed (polling 250 ms to 2 s, `feed.ts:62`), and the adapter has to turn it into a push notification. **pi gap**: a gap already named on the pi map. **Not covered**: nothing in Rui or the adapter design.

| Method (direction) | Sym | VK | Rui status | Gap / note |
|---|---|---|---|---|
| `initialize` / `initialized` (c→s) | ✓ | ✓ | Adapter-only | Handshake with the Host. `experimentalApi` is accepted and ignored. |
| `thread/start` (cwd, approvalPolicy, sandbox, model, instructions, config) | ✓ | ✓ | Served: `configure` (workspace, model, instructions, effort, `permission_mode` ask/bypass) | Rui has no sandbox. Permissions are per action, not a filesystem sandbox (`ARCHITECTURE.md:15`). `sandbox` would be dropped. |
| `thread/start.dynamicTools` + `item/tool/call` (s→c) | ✓ | rejects with `success:false` | pi gap: app-run tools (#2036 item 3) | Symphony's tracker tools depend on this. Today the only route is an MCP server registered at connect. |
| `thread/fork` (follow-ups) | – | ✓ | pi gap: branching (#2036 item 4) | Vibe uses it for every follow-up. An adapter could continue the same Session, but the original thread would not stay unchanged. |
| `turn/start` (text input, cwd, approvalPolicy, sandboxPolicy; Vibe adds `collaborationMode`) | ✓ | ✓ | Served: `message` (`send`) | `send` resolves at admission, and the `turn` id comes from the feed. `collaborationMode` (plan mode) is not covered. |
| `thread/started`, `turn/started` | ✓ | ✓ | Served, gap: pushed feed | `admission`/`user` rows |
| `turn/completed` (status) | ✓ | ✓ | Served, gap: pushed feed | `turn_ended` row. Its ending maps to completed, interrupted or failed (`inspection.md:285`). |
| `item/started` / `item/completed` for agentMessage | ✓ | ✓ | Served, gap: pushed feed | `assistant` row (finished text only) |
| `item/*` for commandExecution | ✓ | ✓ | Served, gap: pushed feed | `call` + `tool_result` rows. Bash is Rui's main local tool. |
| `item/*` for mcpToolCall | ✓ | ✓ | Served, gap: pushed feed | Rui is an MCP client. Call rows are the same kind. |
| `item/*` for fileChange, `item/fileChange/outputDelta` | ✓ | ✓ | Not covered | Rui has no edit or patch tool (#2036 item 2, file tools) |
| `item/agentMessage/delta` | display | ✓ | pi gap: streaming text (#2042) | Rui ignores provider deltas today |
| `item/commandExecution/outputDelta` | display | ✓ | Served, gap: pushed feed | `read_action` reads output by offset (`sessions.ts:412`), which has to be polled |
| `item/reasoning/*` deltas, `summaryPartAdded` | display | ✓ | Not covered | Same route as #2042 if it is ever added |
| `item/plan/delta`, `turn/plan/updated`, `turn/diff/updated` | display | plan used | Not covered | No plan tool, and Rui computes no diff |
| `thread/tokenUsage/updated` | ✓ | ✓ | Served, gap: pushed feed | Usage on `model_call` rows |
| `item/commandExecution/requestApproval` (s→c) → `acceptForSession`/accept/decline | ✓ | ✓ | Served, gap: pushed feed | `approval_requested` row plus `permission_decision`. Rui has only `allow_once`/`deny` (`mutation_answer.zig:14`), so the adapter has to remember "for session" itself, or use `bypass` when the policy is `never`. |
| `item/fileChange/requestApproval` | ✓ | ✓ | Not covered | No file tool |
| legacy `execCommandApproval` / `applyPatchApproval` | ✓ | errors | Not needed | v1 only |
| `item/tool/requestUserInput` | ✓ (auto-answers MCP approvals) | ✓ | Not covered | Rui has no ask-user tool |
| `mcpServer/elicitation/request`, `item/permissions/requestApproval`, `attestation/generate` | – | null reply | Not needed | |
| `account/read` | – | ✓ (gate) | Not covered on the wire | Rui does ChatGPT device sign-in and OpenAI key sign-in in the CLI or Host. No Host read reports account state, so the adapter could answer from `model_list` sources or a constant. |
| `account/updated`, `account/rateLimits/updated`, `account/chatgptAuthTokens/refresh` | display only | null reply | Not covered | Rui's sign-in worker manages tokens itself |
| `account/rateLimits/read`, `config/read`, `config/batchWrite`, `mcpServerStatus/list`, `thread/compact/start`, `thread/read`, `review/start` | – | ✓ (slash commands, `/review`) | Mostly not covered | Rui compacts on its own (#2036 item 5, compaction). Its MCP status and config are fixed when the Host starts. |
| `model/list` | – | – | Served: `model_list` | Neither app calls it. Vibe uses a static list. |
| `turn/interrupt` | – | – | Served: `model_interruption` | Unused by both apps |
| `error`, `model/rerouted`, `configWarning`, `contextCompacted`, `thread/status/changed` | – | ✓ (display) | Partly | `compacted` row exists. The rest are not covered. |

## Unverified

- Whether the `rust-v0.132.0` protocol differs from current main for the methods above. Only v0.132.0's method table was read. Symphony is not pinned to any version.
- The exact payload shapes, for example `ThreadItem` fields. Field-level compatibility with Rui's feed rows was not checked.
- Whether `bash -lc` in Symphony's command picks up a `rui` on PATH. This was inferred, not run.
- Whether Rui's feed rows carry everything `item/completed` needs, such as an aggregated command output and exit code. Not checked.
