# Pi SDK surface against Rui's TypeScript client

Answers [#2036](https://github.com/DivyanshGolyan/rui/issues/2036), part of #2034: for each member of `@earendil-works/pi-coding-agent@1.6.0` that an embedder touches, what is the Rui equivalent in `clients/ts` today?
Scope is the in-process SDK (`createAgentSession`, `AgentSession`, `SessionManager`, `AgentSessionRuntime`, `ToolDefinition`, `ModelRuntime`).
This is source reading, not a run of either system.
Rui side: `origin/main` at `5a6b6e5`, files under `clients/ts/src/`, `ARCHITECTURE.md` and `docs/contracts/`.

## Sources and method

- Pi declarations: `dist/core/sdk.d.ts` (options and result), `dist/core/agent-session.d.ts` (members and `AgentSessionEvent`), `dist/core/agent-session-runtime.d.ts`, `dist/core/session-manager.d.ts`, `dist/core/model-runtime.d.ts`, `dist/core/extensions/types.d.ts` (`ToolDefinition`), and `@earendil-works/pi-agent-core` `dist/types.d.ts` (`AgentEvent`, `AgentTool`), all from the 1.6.0 tarballs.
  The prose contract is `docs/sdk.md` in the same package.
- Use counts, **Ex**: how many of the 14 files in `examples/sdk/*.ts` mention the member (`/14`).
  **Dep**: how many of 5 npm packages that embed pi in-process mention it (`/5`).
  The five, as fetched with `npm pack` on 2026-11-23: `@ai-sdk/harness-pi@1.0.193` (HP), `@assistant-ui/react-pi@0.0.35` (RP), `@5dive/telegram-pi-bridge@0.1.1` (TB), `@youweichen/pi-harness@1.3.1` (YW), `@jetcrab/pi-desk@1.1.51` (PD).
  I found these through the npm registry search for `@earendil-works/pi-coding-agent` and kept the ones whose source calls `createAgentSession` or `createAgentSessionRuntime`.
- The counts are regular-expression text matches over non-test source, not a type-aware analysis.
  Generic names (`cwd`, `model`, `.messages`, `.reload(`, `sessionId`) over-count, and I mark those "noisy".
  The dependents pin older pi versions (TB `^0.80.6`, RP `>=0.80.8`, HP `^1.5.0`, YW `1.0.4`, PD `*`), so a member with Dep 0 may only be unused or may have been renamed; I did not diff versions.
- Not counted, because they do not use the SDK: `pi-acp@0.0.35` and `@pgmi-builds/agent-adapter-pi@0.1.0` spawn `pi --mode rpc` (`pi-acp/package/dist/index.js:131`; `agent-adapter-pi/package/dist/pi-client.js:4`), and `@agentproto/adapter-pi@0.8.1` only installs or invokes the CLI.
  The RPC commands `pi-acp` sends are `prompt`, `abort`, `steer`, `follow_up`, `set_model`, `set_thinking_level`, `set_session_name`, `switch_session`, `compact` and `set_auto_compaction`, plus `get_state`, `get_messages`, `get_session_stats`, `get_available_models`, `get_commands`, `bash` and `export_html` (token search in `pi-acp/package/dist/index.js`, so inferred to be the full set).
  It consumes the events `agent_start`, `agent_end`, `agent_settled`, `message_update`, `tool_execution_start/update/end`, `turn_end`, `session_info_changed`, `auto_retry_start/end` and `auto_compaction_start/end`.
  That is the same surface as the SDK rows below, reached over a pipe.

## Rui mapping vocabulary

- **same**: Rui exposes the same thing with the same meaning.
- **adapter**: an adapter can build it from today's client; the note says what it costs or loses.
- **host change**: needs something Rui's Host or wire does not offer; the note says what.
- **no meaning**: the concept does not exist in Rui's contract.

Rui facts the rows rely on, each from source:

- `Session.send(text, {idempotencyKey})` resolves after admission, not after the answer (`clients/ts/src/sessions.ts:280`, `docs/integrating-rui.md`).
  Sends while a Turn runs queue (`docs/contracts/sessions.md:145`).
- Output is a feed of saved entries, "not token-by-token text" (`docs/integrating-rui.md`).
  Kinds are in `FEED_KINDS` (`clients/ts/src/feed.ts:30`): `user`, `assistant`, `call`, `tool_result`, `turn_ended`, `session_changed`, `compacted`, `model_call`, `approval_requested`, and others.
- Settings per Session are `AgentSpec` (`sessions.ts:20`): `workspace`, `provider`, `model` (string), `instructions`, `outputSchema`, `tools`, `loadedTools`, `permissionMode`, `effort`, `compactAt`, `label`.
  `workspace` and `provider` are fixed at creation.
- Built-in tools are `bash`, `find_tools`, `message_agent`, `read_action`, `read_image`, `read_transcript`, `skill`, `start_agent`, `stop_action`, `web_search` (`src/built_in_tool.zig:3`).
  There is no read, write, edit, grep, find or ls tool, and `edit` is "absent from the current Tool Catalog" (`docs/contracts/execution.md:178`).
- Other tools come only from `settings.tools.mcp`, given at `Rui.connect` (`clients/ts/README.md`).
  V1 "excludes conversation branching, model/provider fallback, incompatible handoff, dynamic tools/MCP" (`ARCHITECTURE.md`, Remaining decisions) and has "no fork, history transfer or cross-provider handoff" (`docs/contracts/admission.md:74`).
- Providers are Host settings (`openai` endpoint, `codex`, `chatgpt`); credentials never reach a Session.
- Reasoning content stays opaque (`docs/contracts/model-io.md:133`).

## `createAgentSession` options and result

| Member | Ex | Dep | Rui mapping |
| --- | --- | --- | --- |
| `cwd` | 9/14 | 5/5 (noisy) | **adapter**: `SessionCreate.workspace`. Rui calls it "not a sandbox", so pi's relative-path semantics for read/write do not carry over (`ARCHITECTURE.md` terms table). |
| `agentDir` | 8/14 | 5/5 | **no meaning**: Rui has a Store (`store.sqlite.dir` or MySQL) and Host settings given at connect, not a per-user config directory. |
| `modelRuntime` | 3/14 | 4/5 | **host change** for anything beyond the three provider adapters; see the ModelRuntime section. Otherwise **adapter** by mapping its provider keys onto `HostSettings.providers` once, at connect. |
| `model` (a `Model<any>` object) | 2/14 | 5/5 (noisy) | **adapter**: pass `model.id` as `AgentSpec.model`. A `Model` carries API, base URL, cost and context window; Rui takes a string and the Host owns those facts. The provider is fixed per Session. |
| `thinkingLevel` | 2/14 | 4/5 | **adapter**: `effort`. Pi's levels are `off, minimal, low, medium, high, xhigh, max` (`pi-agent-core` `types.d.ts:300`); Rui's are `none, low, medium, high, xhigh, max` (`wire.ts:943`). `minimal` has no Rui value, so it maps lossily to `low`. Whether a model accepts a level is Host-checked (`session_changed` carries `reasoning_effort_refused`). |
| `scopedModels` | 0/14 | 1/5 | **no meaning**: it feeds Ctrl+P cycling. An adapter can keep the list itself. |
| `noTools` / `tools` / `excludeTools` | 0 / 3 / 0 of 14 | 3 / 3 / 1 of 5 | **adapter** for the names Rui has (`AgentSpec.tools`, `loadedTools`). **host change** for pi's default `read`, `edit`, `write` and for `grep`, `find`, `ls`: Rui has no such tools, only `bash`. Glob patterns in `tools` (`*`) are not offered; the adapter expands them against a known name list. |
| `customTools` | 0/14 | 3/5 | **adapter, static**: serve the `ToolDefinition`s from an in-process MCP server and register it in `settings.tools.mcp` before `Rui.connect`. Adding a tool after connect needs a Host restart, and per-Session tool sets are impossible: **host change** for dynamic tools. See the ToolDefinition section. |
| `resourceLoader` | 7/14 | 5/5 | Split. System-prompt override or append: **adapter** (`instructions`). Skills: **adapter** in part, since the Host discovers only `<repo>/.agents/skills` and `~/.agents/skills` (`docs/contracts/conversation.md:148`) and an embedder cannot inject a skill list: **host change** for injected skills. Context files such as `AGENTS.md`, prompt templates, extensions, themes: **no meaning** (I found no discovery of context files in `docs/contracts/`; inferred). |
| `sessionManager` | 12/14 | 5/5 | **adapter** for create, open, continue and list; see the SessionManager section. |
| `settingsManager` | 3/14 | 4/5 | **no meaning** as an object. Its useful settings map to per-Session `compactAt`, `effort`, `permissionMode` and to `HostSettings`. |
| `sessionStartEvent` | 1/14 | 0/5 | **no meaning**: it only feeds the extension runtime. |
| result `session` | 14/14 | 5/5 | **same** in role: the `Session` handle. |
| result `extensionsResult` | 0/14 | 1/5 | **no meaning**: Rui has no extensions. |
| result `modelFallbackMessage` | 1/14 | 0/5 | **no meaning**: V1 has no model fallback (`ARCHITECTURE.md`). A Session keeps its saved model. |

## `AgentSession` methods

| Member | Ex | Dep | Rui mapping |
| --- | --- | --- | --- |
| `prompt(text, opts)` | 6/14 | 5/5 | **adapter**: `send` plus a follow of the feed to `turn_ended` to resolve when the run finishes, as pi does. `send` needs an `idempotencyKey` the adapter must generate. **host change** for `images` (`send` carries text only) and none for `expandPromptTemplates` (no templates; `/skill` words bind skills instead, `conversation.md:167`). |
| `steer(text)` | 0/14 | 1/5 (HP) | **adapter, lossy**: a `send` during a Turn queues for the next input boundary (`sessions.md:145`, `:171`). Rui does not distinguish steer from follow-up, and has no "handled by extension" result. Whether the boundary is "after current tool calls" is unverified. |
| `followUp(text)` | 0/14 | 0/5 | **adapter**: the same `send` queue. |
| `sendUserMessage` | 0/14 | 2/5 | **adapter**: `send`. |
| `sendCustomMessage` | 0/14 | 0/5 | **no meaning**: extension-only custom transcript entries. |
| `clearQueue()` / `getSteeringMessages()` / `getFollowUpMessages()` | 0/14 | 3/5 (`clearQueue`) | **host change**: no dequeue command exists in `clients/ts`; only `stop` ends queued input (`sessions.md:40`). Reading the count is **adapter** (`status().pendingMessages`), but not the text. |
| `abort()` | 0/14 | 5/5 | **adapter, different scope**: `interrupt()` cancels the model call only; `stop()` also ends the Turn and queued input (`sessions.md:120`). Pi's `abort` stops the active operation including tools and waits for idle, which is nearest `stop()` plus waiting for `turn_ended`. |
| `waitForIdle()` | 0/14 | 0/5 | **adapter**: poll `status().state` or follow the feed to `turn_ended`. |
| `subscribe(listener)` | 7/14 | 5/5 | **adapter**: map `listActivity({follow:true})` entries to events. Granularity is saved entries, so see the event table for what is missing. |
| `dispose()` | 14/14 | 4/5 | **adapter**: abort the feed iterator via its `signal`. A `Session` handle holds no resource; closing the Host is `Rui.close()`. |
| `bindExtensions()` | 2/14 | 4/5 | **no meaning**. |
| `reload()` | 6/14 | 4/5 (noisy: also `resourceLoader.reload`) | **no meaning** for session reload; the Host snapshots a skill catalog at creation. |
| `setModel(model)` | 0/14 | 4/5 | **adapter**: `update({model})`, within the Session's fixed provider. Cross-provider switch is **host change** (`provider` is fixed for life, `sessions.ts:22`). |
| `cycleModel()` | 0/14 | 1/5 | **adapter**: client-side over `rui.models()` (`sessions.ts:515`). |
| `setThinkingLevel` | 0/14 | 3/5 | **adapter**: `update({effort})`. |
| `getAvailableThinkingLevels()` / `supportsThinking()` | 0/14 | 1/5 | **host change**: `ModelSummary` is `{provider, id, known}` only (`sessions.ts:147`); the effort grammar is inside the Host (`src/model_catalog.zig`, per `ARCHITECTURE.md` source map). |
| `setActiveToolsByName` | 0/14 | 3/5 | **adapter**: `update({tools})` or `loadedTools`. |
| `getActiveToolNames()` | 1/14 | 3/5 | **adapter**: `status().tools` and `.loadedTools`. |
| `getAllTools()` / `getToolDefinition()` | 0/14 | 2/5 | **host change**: no tool catalog listing in `clients/ts` (I found none in `wire.ts` routes; inferred). The adapter knows only its own MCP tools plus the built-in names above. |
| `compact(instructions)` | 0/14 | 3/5 | **host change**: the client has only the `compactAt` trigger and no manual compaction request (`sessions.ts:40`). `abortCompaction` likewise. |
| `setAutoCompactionEnabled` / `autoCompactionEnabled` | 0/14 | 0/5 | **adapter, approximate**: raise `compactAt`; `null` means Host default, so "off" is not expressible. |
| `setAutoRetryEnabled` / `abortRetry` / `retryAttempt` | 0/14 | 1/5 | **no meaning**: the Host owns retry (`src/transport_policy.zig`); `model_call.attempts` reports it afterwards. |
| `executeBash` / `abortBash` / `recordBashResult` | 0/14 | 1/5 (PD) | **host change**: Rui runs Bash only as a model-proposed Action; there is no user-initiated command in the client. |
| `setSessionName` | 0/14 | 3/5 | **adapter**: `update({label})`. |
| `navigateTree` / `getUserMessagesForForking` | 0/14 | 2/5 / 0/5 | **host change**: V1 has no branching or fork (`ARCHITECTURE.md`, `admission.md:74`). |
| `getSessionStats()` | 0/14 | 2/5 | **adapter, partial**: sum `inputTokens`, `outputTokens`, `cachedTokens` from `model_call` entries; message counts from the feed. No cost figure and no `contextUsage`. |
| `getContextUsage()` | 0/14 | 3/5 | **host change**: the Host derives "context left" for its own UI (`model-io.md:182`) but `SessionStatus` does not carry it. |
| `exportToHtml` / `exportToJsonl` | 0/14 | 0/5 | **adapter**: render from the feed; the Store has no export route in the client. |
| `getLastAssistantText()` | 0/14 | 0/5 | **adapter**: last `assistant` entry through `readContent`. |
| `setSteeringMode` / `setFollowUpMode` | 0/14 | 0/5 | **no meaning**. |
| `hasExtensionHandlers`, `createReplacedSessionContext`, `summarizeForBugReport`, `refreshContext`, `setCacheWarmingMode` | 0/14 | 0/5 | **no meaning**. |

## `AgentSession` getters

| Member | Ex | Dep | Rui mapping |
| --- | --- | --- | --- |
| `messages` | 2/14 | 4/5 (noisy) | **adapter**: fold `user`, `assistant`, `call`, `tool_result` entries into messages. Thinking blocks are absent (reasoning is opaque, `model-io.md:133`). Compaction replaces pi's history in place; Rui keeps the full feed plus a `compacted` entry. |
| `model` | 0/14 | 3/5 | **adapter**: `status().model` is a string; the adapter must construct pi's `Model` object, whose other fields Rui does not expose (**host change** for context window, cost, `reasoning`). |
| `thinkingLevel` | 0/14 | 3/5 | **adapter**: `status().effort`. |
| `systemPrompt` | 0/14 | 2/5 | **host change**: the client reads only the `instructions` you set, not the assembled request prompt. Rui also adds its own context (`model-io.md:46`). |
| `isStreaming` / `isIdle` | 0/14 | 3/5 / 2/5 | **adapter**: `status().state` (`working` vs `idle`, `sessions.ts:125`). |
| `isCompacting` | 0/14 | 3/5 | **host change**: no live compaction state; only the finished `compacted` entry. |
| `sessionId` | 1/14 | 4/5 (noisy) | **adapter**: `session.id`, a six-character Store-allocated reference. Pi's ids are UUIDs, so an adapter-facing id shape differs. |
| `sessionFile` | 2/14 | 3/5 | **no meaning**: no per-Session file. The adapter must treat the Session id as the "path". Examples print it; embedders use it to reopen. |
| `sessionName` | 0/14 | 2/5 | **adapter**: `status().label`. |
| `state` (`AgentState`), `agent` | 1/14 / 0/14 | 1/5 / 3/5 | **no meaning** for the `Agent` object (`agent.state.messages`, queue internals). `docs/sdk.md` already says assigning `agent.state.messages` does not replace persisted context. |
| `sessionManager`, `settingsManager`, `resourceLoader`, `extensionRunner`, `promptTemplates`, `scopedModels` | 0/14 | 2-3/5 | **no meaning**, except that `sessionManager` reads are covered in the SessionManager section. |
| `modelRuntime` | 0/14 | 3/5 | **no meaning** as a live object; see ModelRuntime. |
| `pendingMessageCount` | 0/14 | 0/5 | **adapter**: `status().pendingMessages`. |

## `AgentSessionEvent` (via `subscribe`)

Pi's `message_update` carries `assistantMessageEvent` deltas (`pi-agent-core` `types.d.ts:476`).
Rui publishes saved entries only.

| Event | Ex | Dep | Rui mapping |
| --- | --- | --- | --- |
| `message_update` (`text_delta`, thinking deltas) | 6/14 | 5/5 | **host change**: no streaming text on the feed or wire (`docs/integrating-rui.md`). An adapter can emit one `message_update` with the complete text when the `assistant` entry appears, which loses live typing. This is the largest gap, since all five embedders and `pi-acp` stream it. |
| `message_start` / `message_end` | 0/14 | 4/5 | **adapter**: an `assistant` or `user` entry gives the completed message. `message_end` is "the authoritative completed message" in pi (`docs/sdk.md`), which matches. |
| `agent_start` / `agent_end` | 1/14 | 3/5 | **adapter**: synthesize from first entry after `send` and `turn_ended`. `willRetry` has no equivalent. |
| `agent_settled` | 0/14 | 3/5 | **adapter**: `turn_ended` with `state` idle and nothing pending. Rui drives queued successors itself (`sessions.md:145`). |
| `turn_start` / `turn_end` | 0/14 | 3/5 | **adapter, different unit**: pi's turn is one assistant message plus its tool results; a Rui Turn spans whole queued work. `model_call` entries are the nearest unit. |
| `tool_execution_start` / `_end` | 0/14 | 4/5 | **adapter**: `call` (with `tool`, `description`, arguments via `readContent`) and `tool_result` entries. `durationMs` and `isError` come from the result entry. |
| `tool_execution_update` | 0/14 | 4/5 | **host change** for streamed partial results; `readAction(action, offset, after)` (`sessions.ts:412`) reads Bash output of a background Action, which an adapter could poll. |
| `queue_update` | 1/14 | 3/5 | **adapter, partial**: `sent`/`received` entries and `pendingMessages`; no text of queued items. |
| `compaction_start` / `_end` | 0/14 | 4/5 | **adapter** for the end (`compacted` entry). **host change** for the start and its `manual`/`threshold`/`overflow` reason. |
| `auto_retry_start` / `_end` | 0/14 | 2/5 | **no meaning** live; `model_call.attempts` afterwards. |
| `entry_appended` | 0/14 | 3/5 | **adapter**: every feed entry. |
| `session_info_changed` | 0/14 | 2/5 | **adapter**: `session_changed` entry for `label`. |
| `thinking_level_changed` | 0/14 | 2/5 | **adapter**: `session_changed` for `reasoning_effort`. |
| `summarization_retry_*`, `bash_execution_update` | 0/14 | 1-2/5 | **no meaning**. |

## `SessionManager`

| Member | Ex | Dep | Rui mapping |
| --- | --- | --- | --- |
| `create(cwd, sessionDir?)` | 2/14 | 4/5 | **adapter**: `sessions.create({workspace, ...spec}, {idempotencyKey})`. A Rui Session requires `model`, `effort`, `compactAt`, `tools`, `permissionMode` or a preset (`integrating-rui.md`), where pi defaults them from settings. The adapter supplies defaults. |
| `open(path)` | 1/14 | 3/5 | **adapter**: `rui.getSession(id)` (`client.ts`, `getSession`). Takes an id, not a file path. |
| `continueRecent(cwd)` | 1/14 | 1/5 | **adapter**: `sessions.list()` newest first. The list request has a `workspace` filter on the wire but `list` hardcodes it to null (`sessions.ts:494`), and `SessionSummary` carries no workspace, so a small client change is needed. |
| `inMemory()` | 11/14 | 4/5 | **adapter, coarse**: Rui has no per-Session storage choice. An embedder wanting no files starts a Host with a temporary SQLite directory. |
| `forkFrom` / `createBranchedSession` | 0/14 | 0/5 and 1/5 | **host change**: "Future fork creates a new Session with ancestry" (`ARCHITECTURE.md`). |
| `list(cwd)` / `listAll()` | 1/14 / 0/14 | 2/5 each | **adapter**: `sessions.list`. `SessionInfo` fields such as `firstMessage` and message count need feed reads. `archive` filter exists (`sessions.ts:82`). |
| `findById` | 0/14 | 1/5 | **adapter**: Session id lookup. |
| `getEntries` / `getBranch` / `getTree` / `getEntry` | 0/14 | 4/5 | **adapter for the linear list** (`listActivity`); the tree is **no meaning** since a Rui Session is linear. |
| `getLeafId` / `branch` / `resetLeaf` / `branchWithSummary` | 0/14 | 3/5 | **host change** (no branching). |
| `appendMessage` / `appendCustomEntry` / `appendUsage` / `appendContextEdit` | 0/14 | 1/5 | **host change**: injecting history is excluded ("no history transfer", `admission.md:74`). Custom entries are **no meaning**. |
| `buildSessionContext` | 0/14 | 1/5 | **adapter**: from the feed; the model's compacted context is Host-private. |
| `getSessionFile` / `getSessionId` / `getCwd` / `getSessionName` / `getHeader` | 0/14 | 3/5 | **adapter**: `id`, `status().label`; the workspace is not readable from `SessionStatus`: **host change** to read it back. |

## `AgentSessionRuntime`

| Member | Ex | Dep | Rui mapping |
| --- | --- | --- | --- |
| `createAgentSessionRuntime`, `createAgentSessionServices`, `createAgentSessionFromServices`, `CreateAgentSessionRuntimeFactory` | 1/14 each | 1/5 (YW) and 2/5 (YW, PD) | **no meaning**: the `Rui` instance is the runtime and holds many concurrent Session handles; no service graph to recreate. |
| `runtime.session` | 1/14 | 1/5 | **adapter**: the adapter's current handle. |
| `newSession()` | 1/14 | 2/5 | **adapter**: `sessions.create`. |
| `switchSession(path)` | 1/14 | 1/5 | **adapter**: `getSession(id)`. |
| `fork(entryId)` | 0/14 | 1/5 | **host change** (no fork). |
| `importFromJsonl` | 0/14 | 0/5 | **host change** (no history import). |
| `setRebindSession`, `setBeforeSessionInvalidate`, `diagnostics`, `takeUnreportedDiagnostics`, `modelFallbackMessage` | 0-4/14 | 0-3/5 | **no meaning**: Rui handles stay valid, so subscriptions need no rebinding after a switch. |
| `dispose()` | 1/14 | 1/5 | **adapter**: `rui.close()`. |

## `ToolDefinition`

Rui executes tools in the Host; the only embedder-supplied tools are MCP servers, registered at connect.

| Member | Ex | Dep | Rui mapping |
| --- | --- | --- | --- |
| `name`, `description`, `parameters` (TypeBox) | 1/14 | 4/5 | **adapter**: an in-process MCP server exposes these (TypeBox is JSON Schema). Tool names must be chosen in `AgentSpec.tools`. |
| `execute(id, params, signal, onUpdate, ctx)` | 1/14 | 3/5 | **adapter, static**: runs in the embedder's process behind MCP. Host calls it with `callTimeoutMs`. `onUpdate` (partial results) and `ctx` (`ExtensionToolContext`) have no MCP counterpart: **no meaning**. How `signal` maps on stop is unverified. |
| `label`, `renderCall`, `renderResult`, `renderShell` | 0/14 | 0/5 | **no meaning** (pi TUI). |
| `promptSnippet`, `promptGuidelines` | 0/14 | 2/5 | **no meaning**; an adapter could append them to `instructions`. |
| `exposure`, `namespace`, `defaultActive`, `prepareLoadout`, `reachesTools` | 1/14 | 3/5 (noisy) | **adapter** in part: Rui's `loadedTools` versus `tools` is a similar configured-versus-loaded split, and `find_tools` is built in. The rest is **no meaning**. |
| `executionMode` | 0/14 | 2/5 | **no meaning** (Host owns scheduling; inferred, not checked). |
| `prepareArguments`, `outputSchema`, `constrainedSampling`, `annotations` | 0/14 | 0/5 | **no meaning** (a Rui `outputSchema` shapes the Session's final answer, not a tool). |
| Permission to run | n/a | n/a | **different owner**: pi gates through extension `tool_call` hooks (`docs/extensions.md:82`); Rui gates by `permissionMode` and `approval_requested` plus `session.decide` (`sessions.ts:445`). **adapter**. |
| `defineTool()` | 0/14 | 2/5 | **no meaning** (typing helper). |

## `ModelRuntime`

| Member | Ex | Dep | Rui mapping |
| --- | --- | --- | --- |
| `ModelRuntime.create(opts)` | 3/14 | 3/5 | **no meaning** as an object; its job moves to `Rui.connect(settings)` (`providers`, `network.caFile`). |
| `getModels` / `getModel` / `getAvailable` / `getAllAvailable` | 1/14 | 3/5 | **adapter**: `rui.models()` gives `{provider, id, known}`. **host change** for context window, cost, input modalities, thinking flags that pi's `Model` carries. |
| `getAuth` / `checkAuth` / `isUsingOAuth` / `hasConfiguredAuth` | 0/14 | 0/5 | **no meaning**: credentials stay in the Host. |
| `setRuntimeApiKey` / `removeRuntimeApiKey` | 2/14 | 2/5 | **adapter, coarse**: Rui reads keys at Host start (`providers.openai.key`); a changed key means reconnecting. No live key swap: **host change**. |
| `login` / `logout` | 0/14 | 2/5 | **no meaning** in-process; sign-in is the CLI's `rui auth login chatgpt` (`integrating-rui.md`). |
| `registerProvider` / `registerNativeProvider` | 0/14 | 2/5 | **host change** for new provider kinds. Rui has `openai` (any Responses-compatible endpoint), `codex`, `chatgpt` only. An OpenAI-compatible endpoint is **adapter** at connect time. |
| `stream` / `complete` / `generateImages` / `classify` | 0/14 | 0/5 | **no meaning**: Rui does not expose direct model calls outside a Session. |
| `listCredentials` / `getProviderAuthStatus` | 0/14 | 2/5 | **no meaning** (credential admin); `rui.hostInfo` is the only status surface I read. |
| `refresh()` | 0/14 | 3/5 | **adapter**: call `rui.models()` again. |
| `registerVirtualModel`, `resolveModel` | 0/14 | 0/5 | **no meaning**. |

## Biggest gaps

1. **No streaming text.** All five in-process embedders and `pi-acp` consume `message_update` deltas; Rui's feed has complete saved entries only. An adapter can only emit whole messages. Needs a Host or wire change.
2. **No file tools.** Pi's defaults are `read`, `bash`, `edit`, `write` (`sdk.d.ts`); Rui has `bash` and no read/write/edit/grep/find/ls, with `edit` unimplemented. Embedders that restrict to read-only tools lose that option.
3. **No dynamic or in-process tools.** `customTools` works only as a static MCP server registered at connect (ARCHITECTURE excludes dynamic tools); partial results (`onUpdate`) and per-Session tool sets have no path. `harness-pi` uses `customTools` 6 times and `ToolDefinition` 26 times.
4. **No fork, branch or history import.** `navigateTree`, `fork`, `forkFrom`, `branch`, `importFromJsonl` and `appendMessage` have no V1 meaning; `youweichen` and `pi-desk` use the tree and fork surface heavily.
5. **No manual compaction or live context and compaction state.** `compact()`, `isCompacting`, `getContextUsage()` and `compaction_start` need Host exposure; only `compactAt` and the finished `compacted` entry exist.
6. **Thin model and tool metadata.** `rui.models()` has no context window, cost, or supported efforts, and there is no tool catalog or effective system prompt read, so `getAllTools`, `systemPrompt`, `getAvailableThinkingLevels` and a faithful `Model` object cannot be built.
7. **Queue semantics differ.** No dequeue command, no steer-versus-follow-up choice, no image input on `send`, and `abort` splits into `interrupt` (model call) and `stop` (Turn).
8. **Provider and credential model.** Only `openai`-compatible, `codex`, `chatgpt`; providers and keys are fixed at Host start. Pi's `ModelRuntime` login, runtime key swaps and provider registration need a reconnect or have no equivalent.

What is cheap: the session lifecycle (`create`, `open`, `list`, `newSession`, `switchSession`), `prompt` plus settle, `abort`, model, effort and label changes, `getSessionStats` from `model_call`, tool start and end events, and message completion events all map through an adapter on today's client.
Untested here: I did not run an adapter or either runtime, so mappings marked adapter are read from source and not proven to compose.
