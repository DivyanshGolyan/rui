# Drift's pi-durable use, mapped onto Rui

Research for #2068 (part of #2034). It is not merged; it lives on the `research/pi-durable-surface` branch.

**Sources.** pi-durable 1.6.0 (`README.md`, `dist/index.d.ts`), Divyansh's summary of Drift's pi use (Drift pins pi-ai and pi-durable 1.4.0), and Rui `main` at 7ce8af39 (`clients/ts/src/sessions.ts`, `docs/contracts/*`). Rui has no access to Drift's repository, so rows marked **Check** need Drift's call list before they are final.

**Rule.** Every row maps one pi-durable use to exactly one Rui feature, and keeps Drift's behavior the same or better. A row where Rui is weaker is a Rui gap, closed before Drift moves.

**Status words.**
- **Same**: Rui does this today. The interface only translates.
- **Rui handles**: Drift deletes its own code because Rui owns this.
- **Gap**: Rui's core needs a change. Every interface then gets it.
- **Drift drops**: Drift stops using this before it moves (Divyansh, 2026-11-23).
- **Check**: whether Drift uses it, or how, decides the row.

## Storage and startup

| pi-durable | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `Storage` (pluggable) | `mysql-storage.ts`: Drift's own MySQL tables, with a fence so only the namespace owner writes | Rui's MySQL Store, by URL. It holds its own tables, owner lock and fence (`host.md:62`). | **Rui handles.** Drift deletes `mysql-storage.ts`. Its data moves through the importer. |
| `Harness.open(storage, { models, registry, settings, onReport })` | `openNamespaceAgent` | `Rui.connect(settings)` | **Same.** `onReport` maps to report events: see Hooks. |
| `harness.root()`, `ROOT_CONVERSATION_ID` | Opens the root conversation | `sessions.create` with a fixed idempotency key returns the same Session every time | **Same**, in the interface. |
| `harness.resume()` | Continues unfinished runs after a restart | The Host resumes eligible work when it starts (`host.md:322`) | **Rui handles.** |
| `createRegistry`, `defineExtension` | `createDriftRegistry`, which accepts only `drift.*` extensions | No Rui concept. The registry is the interface's list of client tools and prompt sections. | **Same**, in the interface. |

## Conversations

| pi-durable | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `submit({ type: "input", requestId })`, then `wait()` | Input to agents | `session.send(text, { idempotencyKey })`, then the feed's `turn_ended` | **Same.** `send` resolves at admission. The interface waits on the feed. |
| Follow-up while busy (default) | Likely | Input queues and starts the next Turn (`conversation.md:24`) | **Same.** |
| `whenBusy: "steer"` | Unknown | None. Queued input waits for the Turn to end. | **Check**, then **Gap** if used. |
| `whenBusy: "reject"`, `ConversationBusy`, `whenIdle` | Unknown | None | **Check.** |
| `type: "continue"` after a failed run | Unknown | A failed Session can take new input. There is no input-free continue. | **Check.** |
| `type: "write"`, `defineEntry` | `agent-messaging.ts` | None | **Drift drops.** App notes go in Drift's own tables. Text the model must see is sent as a message. |
| `reset()`, `ResetEntry` | Used | None. A Session's context is cut only by compaction. | **Gap.** "Start a new context, keep history in storage." |
| `abort()` | Stop | `session.stop()` / `session.interrupt()` | **Same.** |
| `configure({ model, thinkingLevel, instructions, tools })` | `settings.ts`, agent types | `session.update({ model, effort, instructions, tools })` | **Same.** `thinkingLevel` maps to `effort`. |
| `configure({ maxTurns })`, `turn_limit` | Unknown | None | **Check**, then **Gap**. |
| `fork()` | Not listed | None (#2037: Rui's history is linear) | Out until a user needs it. |

## Tools

| pi-durable | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `defineTool({ parameters, execute })` | `tool.ts`, `file-tools.ts`, `namespace-tools.ts` | Client tools on the wire (#2039, decided) or an MCP server (#838). Neither is built for client tools yet. | **Gap.** The route is open on a decision card. |
| `api.output()` progress | Likely | Shown live, never saved (#2039) | **Check.** pi-durable saves partial output about every second, so after a crash the model sees the output so far. If Drift relies on that, live-only progress is weaker. |
| `replay: "safe"`, `restartLimit`, `DEFAULT_RESTART_LIMIT` | Uses `DEFAULT_RESTART_LIMIT` | Never reruns (`execution.md:390`) | **Gap** (agreed 2026-11-23): rerun tools marked safe, up to a limit, then an error result. |
| Result `usage`, `control.terminate`, `control.handoff`, `structuredOutput`, `details` | Unknown | None | **Check.** |
| `wrapTool` | `withActivity` wraps every tool | The tool runs in Drift's process, so wrapping stays in Drift | **Same**, in the interface. |
| `CodingTools` (read, write, edit, bash) | Drift has its own `file-tools.ts` | Rui has `bash`. Drift's file tools become client tools. | **Same** once client tools exist. |
| Tool search | `find-tools.ts` | Rui's built-in tool loading (`loadedTools`, `find_tools`) | **Rui handles**, if the two behave alike. **Check.** |
| Tool calls in parallel (`toolExecution`) | Unknown | Not checked | **Check.** |

## Prompt

| pi-durable | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `section()`, `PromptSection` | Used | One `instructions` string per Session | **Same**, in the interface: it renders the sections and calls `update` when the text changes. A section that depends on each request's environment would not map. **Check.** |

## Hooks

| pi-durable | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `hook(GenerationTask, afterResponse)`, progress tracking, model-request logging | `map-agent.ts:530-553`, `model-requests.ts` | The activity feed has `model_call` rows, but it is polled and has no hook surface | **Gap**: watching hooks as events (agreed 2026-11-23). |
| `hook(CompactionTask, …)` to reset state after compaction | Used | No compaction event to the app | **Gap**, part of watching hooks. |
| `hook(ToolTask, afterTool)` for wake activity | `wake-activity.ts` | Feed `call` and `tool_result` rows | **Same** if a moment's delay is fine. Otherwise part of the watching-hooks **Gap**. |
| `beforeRequest`, `beforeProviderRequest`, `onYield`, `afterTools`, `afterRun` | Some | None. These change the loop inside Rui. | **Drift drops.** |
| `beforeTool` block or sleep (gates) | Unknown | Ask mode and `session.decide` | **Check.** |
| `onReport` | `Harness.open` | Diagnostics, not delivered to the app | **Gap**, part of watching hooks. |

## Shared state and agents

| pi-durable | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `defineDoc`, `defineDocFamily`, `AgentDoc` | `session-file-store.ts`, `root-state.ts` | None | **Drift drops.** The state moves to Drift's own tables. |
| `LiveDoc` (run state) | Likely read for UI | `session.status()` and the feed | **Same.** |
| `defineTask`, `configure`, submissions, `ConversationHandle` for workers | `agent-messaging.ts`, `ticket-workers.ts` | `start_agent` and `message_agent` for the model; `sessions.create({ parent })` for the app | **Drift drops** its own messaging and uses Rui's agents. |

## Settings and errors

| pi-durable | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `settings.retry`, `stream.timeoutMs` | Drift also wraps each request with its own timeouts | Rui's retry allowance and inactivity timeouts (`execution.md:418-430`) | **Rui handles.** Drift deletes its wrapper. |
| `CompactionPolicy` (`reserveTokens`, `keepRecentTokens`, `backgroundTokens`) | `settings.ts` | `compactAt` only | **Check** which fields Drift sets away from the defaults. |
| Custom instructions on automatic compaction | Drift's local patch | None | **Gap**, already filed as #1650. |
| `SessionFailed` | Used | The Host fences on storage failure (`execution.md:391`). The TS client likely shows `RuiUnavailableError` (inferred). | **Gap**: one named storage-failure error for every waiting caller. |
| `runFailure` reasons | Likely | Failure classes in Session status | **Same**, in the interface. |

## pi-ai

| pi-ai | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `createModels`, `createProvider`, Marlin OpenAI Responses rail | `marlin-models.ts` | `providers.openai.endpoint` for an OpenAI-compatible endpoint (`model-io.md:621`), as decided in #847 | **Same**, with one condition: Rui speaks only HTTP/2 to providers (`model-io.md:376-377`). **Check** that Marlin answers over HTTP/2. If it doesn't, that's a **Gap**. |
| Anthropic Messages rail | Not used now (Divyansh) | None | Out. |
| Patch: parse tool arguments once at the end | Local patch | Rui decodes the sealed response once (`output_decode.zig`) | **Rui handles.** |
| Patch: no retry on 4xx other than 408 and 429 | Local patch | Permanent request errors are not retried (`execution.md:423`) | **Rui handles.** |
| `calculateCost`, `OPENAI_MODELS`, `PI_AI_VERSION` | Prices each run | Rui reports token usage. Drift keeps pi-ai for prices. | **Same.** Drift records Rui's version beside pi-ai's. |
| Message types (`Message`, `AssistantMessage`, …) | Trace and transcript code | Feed rows | **Same**, in the interface: it converts feed rows to pi-ai message shapes. |
| `TSchema`, `Static` | Tool parameters | Client tools take JSON Schema | **Same.** |
| `Models` used directly | `web-search/searcher.ts` | Not agent work | **Same**: one-off model calls stay on pi-ai. |

## Testing

| pi-durable | Drift's use | Rui | Status |
| --- | --- | --- | --- |
| `pi-durable/testing` | Drift's tests | None shipped. The rehearsal's scripted provider shows the shape. | **Gap**, already filed as #1655. |

## What this adds up to

**Gaps in Rui's core** (each reaches every interface):
1. Client tools on the wire (#2039), or the MCP route, depending on the open card.
2. Watching hooks as events, including compaction and `onReport`.
3. Rerunning tools marked safe after a crash, up to a restart limit.
4. A named storage-failure error for every waiting caller.
5. Custom compaction instructions (#1650).
6. A test kit (#1655).
7. Reset: start a new context and keep the history.

**Interface work** (translation only): root by fixed key, prompt sections rendered into `instructions`, waiting on the feed, run-failure reasons, and feed rows converted to pi-ai message shapes.

**Drift drops**: its own storage, shared documents, custom entries and tasks, loop-changing hooks, its request timeout wrapper, and two pi-ai patches.

**Checks for Drift's call list**: steer, reject and continue; `maxTurns`; tool result controls; whether saved partial tool output matters; `beforeTool` gates; parallel tool calls; non-default compaction policy fields; whether prompt sections depend on each request; whether `find_tools` behaves alike; and Marlin over HTTP/2.
