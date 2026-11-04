# Rui core and Seams: decision ledger

Extraction only, 2026-11-04. Each decision is written once. Nothing here is new, improved or judged.

Sources: map #838 and tickets #839 to #851 with every comment; the design doc "Rui core and Seams: design with Drift as first user" (https://claude.ai/artifact/Qs5UEecjciB2Cxp7KR3Uyr, rev 14); a Simple Made Easy review of every decision with the outcomes recorded in rui-seams-decisions-1104.md. Times of individual 11-04 and 11-03 log lines come from /mnt/project-files/rui-seams/critique/all-decisions.md, the log the review was run against.

How to read the sources:
- `#NNN` is that ticket's Resolution comment (2026-11-03). `#838 map` is a "Settled while charting" line on the map.
- `11-03 HH:MMZ` and `11-04 HH:MMZ` are timestamped log lines.
- `11-04 04:40Z` marks a 2026-11-04 decision whose exact time is not in the sources. 04:40Z is when the 11-04 decisions were folded into the design doc (section "Decisions on 2026-11-04") and into #838 (section "Decisions 2026-11-04").
- `review #N` is item N of hickey-review.md. Its outcomes: #1 reshaped into the model catalog; #2, #3, #5, #7 and #11 adopted; #4 dropped; #6 rejected; #8 and #9 kept as they are; #10 derived and not stored.
- The "Critique (2026-11-03)" tables in the design doc are proposals. A critique item appears here only where a later decision took it up, and the source given is that decision.
- Precedence: 11-04 beats 11-03 ticket resolutions, which beat "Settled while charting" map lines. Within a day, the later time wins.

## Client API and launch

D1. Rui ships its own revised interface and Drift is ported to it. There is no pi or pi-durable drop-in package. (source: #838 map)
D2. Drift talks to Rui through one small TypeScript package whose shape follows the Azure TypeScript SDK guidelines, Temporal's client, Stripe's idempotency rules and the Codex SDK. Notes kept in the project folder (source: #849)
D3. Drift starts Rui with `Rui.connect({ database, provider: { baseUrl, key }, tools, presets })`, which uses the existing `/v1/host-info` route plus auto-start, and adds two new Host pieces: the MySQL URL and the stdin key handoff. (source: #849)
D4. Drift's npm package starts Rui as a child program in the background on the same machine, pointed at Drift's MySQL. Drift is a single instance. (source: #838 map; 11-04 03:35Z)
D5. Rui lives exactly as long as the Drift process. Rui exits when the stdin pipe that carried the key closes, so a crashed Drift never leaves an orphan holding the Store. Drift owns starting and restarting Rui, and starts it again if Rui alone crashes; state is in the database. (source: 11-04 03:35Z, 03:40Z)
D6. There is no settings fingerprint on connect. A Drift restart always restarts Rui with fresh settings. (source: 11-04 03:35Z)
D7. `rui.sessions.create({ preset, instructions }, { idempotencyKey })` and `session.update({ effort })` use the existing `/v1/configure` route. (source: #849)
D8. `session.send(text, { idempotencyKey })` returns a receipt `{ messageId }` only, over the existing `/v1/message` route. There is no Turn handle, no `result()` and no held wait. Messages that arrive while the agent works are batched into its next turn, as today. (source: 11-04 02:15Z; review #7)
D9. Drift follows one feed, `session.listActivity`, in order. The feed has an "agent finished" entry, so Drift never polls `status()` to learn the agent is done. (source: 11-04 04:40Z; review #7)
D10. `listActivity` uses the existing `/v1/activity-page` route. Sequences are async iterators with `continuationToken` pages, and polling stays inside the client. (source: #849)
D11. `/v1/activity-page` gets a `kinds` filter, the same name as `read_transcript`'s `kinds` and the TS `listActivity` filter. `person-message` (Ctrl-P recall) is folded into it as a `kinds` read with page size 1, and `/v1/person-message` is deleted. (source: 11-03 17:17Z; #851)
D12. `status()` uses the existing `/v1/inspect-session` route. Rui's tables are private and the client API is the contract, with ergonomic reads such as `status()` and `activity({ last })`. (source: #849; #838 map)
D13. The client's transcript read uses the existing `/v1/conversation-page` route plus a new word search, shared with `read_transcript`. (source: #849)
D14. `session.stop()` uses the existing `/v1/control/session-stop` route and is the only way to stop work. Cancelling a wait never stops work. (source: #849)
D15. The TS client has `session.decide(requestId, "allow" | "deny")` for approvals and `session.interrupt()` to cut off the current answer while the Session keeps going. Both use calls the Host already has (ARCHITECTURE.md:210). (source: 11-04 04:49Z)
D16. `rui.getSession(id)` returns a handle and does no I/O. (source: #849)
D17. Request keys are required on every write. The client builds them as `kind:driftId` (`chat:42`, `msg:42`). Core is unchanged: keys are already required (ARCHITECTURE.md:210), a resend after a crash returns the original answer, and a reused key with different inputs is rejected with `idempotency_key_conflict` (Rui's semantic digest). Drift's `drift` and `drift_rui` databases sit on one MySQL server and restore together. Review #4 (a UUIDv4 stored in Drift's row) was dropped. (source: 11-04 03:26Z, 04:40Z; #849)
D18. Errors are typed: `RuiRequestError.code` is Rui's rejection enum, and a failed turn carries an `ending` such as `context_full`, `provider_refused` or `stopped` (design doc: `TurnFailedError.ending`). (source: #849; #851)
D19. Replaced by D172. No transport types are exported. (source: #849)
D20. One public interface: the TUI and CLI use the same routes and get nothing the TS package cannot call. The TUI is a plain consumer of it. (source: #851; 11-03 16:20Z)
D21. `tools` is required in every preset. `[]` means no tools, and there is no Host default. (source: 11-04 04:40Z; review #11)
D22. Presets are named agent specs in Drift's code (for example one per Drift ticket type), passed to Rui at connect and not stored in the database. A caller can name a preset and override fields. The resolved spec is copied into the Session at start, so editing a preset never changes a running agent. (source: #845; #846)

## Core

D23. The core owns Session (with a first-class `parent`), Message, Turn, Operation, Attempt, Resolution, the never-repeat rules ("outcome unknown"), compaction, the scheduler, and agent specs and presets. (source: #851)
D24. `start_agent`, `message_agent`, `read_transcript` and `find_tools` are core-owned tools run as core commands. (source: 11-04 02:17Z)
D25. Concept meanings: a Turn is the work from picking up waiting messages to a final answer or a named ending; an Operation is one model call or one tool call; an Attempt is one physical try of an Operation; a Resolution is an Operation's saved, final result. (source: #851)
D26. The word is Turn, everywhere; the client never says "Run". (source: #851)
D27. The parent link is a core concept: an attached child's Session has `parent`. This replaces "no ... parent-child ownership" at ARCHITECTURE.md:568. Keeping the link in a tool-owned table was rejected, because Tools would reach into the Store and a core stop would call back into a tool. (source: #851)
D28. One agent spec value is today's Session settings and nothing new: instructions, model, effort, tools, compaction trigger, output schema, permission mode, label. Session start, `start_agent` and presets all take it. Drift reads its own doctrine files for instructions. (source: #845; #838 map)
D29. Only the model is fixed for a Session's life (one model per Session). Instructions (rendered as later `developer` messages), effort and the other settings change mid-Session with the provider cache kept. (source: #845)
D30. There is no separate context limit; the compaction trigger is the one setting. When compaction cannot shrink the conversation enough, the turn ends with a named "context full" ending (today `ResourceExceeded`), visible in `status()`. (source: #845)
D31. After "context full" the caller starts a new Session with a brief. The pointer to the old Session is plain text in the brief ("you're continuing session X; read it with read_transcript"), not a saved field: there is no `continues` field until something reads one. (source: #845; #838 map)
D32. Rui never reruns a tool call. When an outcome is unknown, the model is told and checks for itself. Retries are Rui's alone, and Rui's internal ids are unchanged. (source: 11-04 03:51Z, 04:40Z; review #5)
D33. Errors are faithful (say what Rui can know), and nothing needs a human except approvals. (source: 11-04 03:11Z, 04:40Z)
D34. Rui adds no priority, line-jumping or per-kind caps; there are no priority classes. Drift's 9-turn cap protected its own 10-connection MySQL pool, which Rui's turns do not hold; Rui allows 100 executions by default. Databricks keeps its 3-statement queue inside Drift's `run_sql` tool. Revisit only from measured waits. (source: #848)
D35. Rui has four Seams: Client (CLI/TUI; the TypeScript package), Tools (`rui.shell`; MCP servers), Provider (ChatGPT sign-in; OpenAI key or gateway such as Marlin) and Store (SQLite; MySQL). Each Seam needs two real Adapters. "Where tools run" belongs to Tools, and Rui's Bash is one built-in tool. (source: #838 map; #851; 11-04 02:17Z)
D36. Vocabulary: a Seam is a plug-in point of the core and an Adapter is one thing that fits it ("Adapter" replaces "Plug"). "Socket" and "port" are avoided. Seam and Adapter join the term table at ARCHITECTURE.md:101. (source: #838 map; #846; #851)

## Agents

D37. `start_agent(task, spec | preset, attached)` is async: it creates the worker's Session, admits the task as its first Message and returns the worker's id at once. It is one saved step keyed by the call id, like today's idempotent `session start`, so a resend never creates a second worker. No call is held open while the worker runs. (source: #846)
D38. An attached child is first class in core. Stopping a Session stops its children, and "context full" on the parent stops them too. A standalone agent has no parent, gets nothing back automatically, and has its own lifetime. (source: 11-04 03:06Z; #846)
D39. A child's final answer reaches the parent as an ordinary message, on the same path as a message from any other agent (`message_agent` / peer admission), and it wakes the parent. It is delivered, not read on demand. (source: 11-04 03:10Z)
D40. Attached versus standalone stays one switch covering both lifetime and reply address; review #8 (separate `reply_to` and `stops_with` fields) was kept as it is. (source: 11-04 04:40Z; review #8)
D41. `message_agent(id, text)` delivers a Message and returns. Replies arrive later as Messages: automatically from an attached worker, or only when a standalone worker chooses to send one. (source: #846)
D42. `read_transcript(id, query?, kinds?, before?, limit?, full?)` reads any Session in the Store, with no extra access rule. By default it returns an outline, one line per entry with position, author or tool, call note and size. `query` is plain word search with snippets; `kinds` filters (final answers, calls to a named tool, failures); `before`/`limit` page newest first; `full` opens one entry, chunked if large. (source: #846; #838 map)
D43. The agent tools are the primary way agents talk to each other; `rui session send` stays for people and scripts. Today's peer context text shrinks to pointing at these tools ("Agent identity and peer composition" in ARCHITECTURE.md changes). (source: #846)

## Tools

D44. The Tools Seam is `rui.shell` (Bash) plus MCP. Bash keeps its process custody and capture machinery inside `rui.shell`. (source: 11-04 02:17Z; #844)
D45. Drift exposes its tools as an MCP server and Rui is an MCP client. (source: #838 map)
D46. Who runs a tool is derived, not stored: Rui (Bash, MCP), core (the agent tools and `find_tools`) or the provider (web search). Review #10 is derived, not stored. (source: 11-04 04:40Z; review #10)
D47. Provider-run tools are first class and Drift writes one tool list. The Provider Adapter lists the tools it offers, and Session start refuses a preset asking for one the provider lacks. A provider-run call comes back finished inside the model's reply, with no never-repeat handling and no separate timeout or stop. (source: 11-04 02:29Z)
D48. Every tool has one record (name, description, input schema, owning server), saved once by content and referenced. It replaces today's `tools_mask` byte and fixed Bash/web-search bit list (src/tools.zig:243), with a Store format bump. (source: #844)
D49. Each model request saves exactly which tool records it offered. A call to anything else gets the existing rejected-call result and never runs. (source: #844)
D50. The Host decides which built-in tools and MCP servers exist; a Session can only narrow by name. (source: #838 map)
D51. Drift's tool list is fetched once at Session start and saved with the Session. It is refreshed only when the Host is told to reload, so the tool list and the prompt cache stay stable. (source: #844)
D52. A Session lists which tools are loaded from the start; the rest wait behind `find_tools`, which matches words against names and descriptions. Found tools join from the next request through `additional_tools`. Drift's own `find_tools` goes away. (source: #844)
D53. Nothing costs a cache miss. Each Session keeps one append-only list of changes: tool added, tool removed, tool reworded, effort changed. Rui builds every request from the original top plus those entries, and works out the allowed tool set and current effort from the same list. (source: 11-04 03:29Z, 04:40Z; review #2)
D54. A removed tool keeps its description in the request; a call to it gets "this tool was removed", and the model is told. (source: 11-04 03:29Z)
D55. Rui saves the exact tool text it sent. When an MCP server's tool text changes, the top stays as saved and Rui appends the new version further down, by the same route as adding a tool: running Sessions see it, the cache holds, and there is no `encoding_drift` stop. (source: 11-04 03:48Z)
D56. All tool calls in one model reply run at once, for every model, with no model list and no model favourites (#868 merged; today only gpt-5.5, src/codecs/responses.zig:21). There is no per-tool "don't run alongside" flag until a tool needs it. (source: 11-04 02:52Z; #844)
D57. No strict mode: tools are sent without `strict`, each tool checks its own input, and a bad call gets an error tool result. It lands as a follow-up PR from the same build thread as the parallel-calls fix (src/codecs/responses.zig). (source: 11-04 03:42Z)
D58. MCP calls use the same ask/bypass permission as Bash. (source: #844)
D59. Each tool server has a per-call time limit, 10 minutes by default. (source: #844)
D60. Timeouts are faithful. A call is "failed" only when Rui actually stopped the work (Bash: the process group is killed). An MCP timeout is "may or may not have run", the same unknown outcome a crash produces, with "no reply within N s" added. (source: 11-04 04:40Z; review #3)
D61. Rui sends no call id to MCP servers, and has no `idempotentHint` rerun and no trusted-server list. (source: 11-04 03:51Z, 04:40Z; review #5)
D62. Rui adds `rui_call_description` to each MCP tool's input, keeps it for the conversation line (saved with the call), and sends the server only the fields its own format lists. Tools never see it, and the core never interprets tool arguments for display; callers read calls and notes through the client. Review #6 was rejected (Divyansh: the line is very important). (source: 11-04 04:40Z; #844)
D63. Progress is Session activity plus a short description on each tool call; there is no separate feed. (source: #838 map)
D64. Rui's MCP client targets MCP 2026-07-28, which is stateless: no `initialize`, no `Mcp-Session-Id`, no resumable GET stream. It sends one POST per request with `Accept: application/json, text/event-stream`, the `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers and a static `Authorization: Bearer` header, and puts `protocolVersion`, `clientCapabilities` and `clientInfo` in `_meta`. (source: #842)
D65. The MCP client parses plain JSON and SSE replies (ignoring progress), pages `tools/list` by `nextCursor`, handles the `tools/call` result (`content`, `structuredContent`, `isError`) and JSON-RPC errors, and cancels a call by closing its stream. (source: #842)
D66. Rui needs a small HTTP/1.1 client on the existing Reactor, with no new thread; today it speaks only HTTP/2 (src/h2/h2.zig). (source: #842)
D67. Drift serves its MCP endpoint with `@modelcontextprotocol/server` 2.4.0 `createMcpHandler`, mounted as a Next.js `POST` route (inferred from the API, not tested). (source: #842)

## Provider and models

D68. Marlin facts taken as inputs: a static `sk-ml-…` key sent as `Authorization: Bearer`, no expiry or refresh; base URL `https://marlin.labs.dreamplug.net/v1` (`POST /v1/responses`); `additional_tools` accepted (stage probe 23 Oct); `configuration_update` never sent by Drift, so untested; no 429s in four weeks, the only refusal is `403 "Your budget has been exhausted"`. (source: #839)
D69. Marlin needs no new provider code: it is Rui's existing OpenAI-key Adapter (Responses codec) with a custom base URL, and the catalog treats it as an OpenAI-compatible base URL and key, not its own provider. (source: #847; 11-04 04:40Z)
D70. The key comes through the client API, not a file: the package writes it once to the Rui child's stdin at launch, and Rui keeps it in memory only, never on disk, in argv or in env. Marlin keys are static, so there is no refresh. stdin carries the key once and does not become a message queue (review #9 kept as it is). (source: #847; #849; 11-04 04:40Z; review #9)
D71. One key, no fallback list: Drift removes its backup key (`MARLIN_API_KEY_FALLBACK`). A budget refusal ends the turn with Marlin's own error text, as Rui already does for an unrecognised refusal. (source: #847)
D72. No per-provider in-flight limit. (source: #847)
D73. Rui does not record which model actually answered; add it when something reads it. (source: #847)
D74. Web search is off for Marlin until one probe shows Marlin passes OpenAI's hosted `web_search` through; otherwise Drift exposes its own search tool on its MCP server. (source: #847)
D75. Cache-safe changes need a new codec version: each `configuration_update` or `additional_tools` item for Operation k is placed at k's admission position (after `history_end` in request k, inside the sealed span later), worked out from saved Operation facts. Top-level `reasoning.effort` and `tools` become fixed (effort the catalog default, top-level tools empty, first tool declaration at the head of the span). The codec carry grows to {comma, current effort, declared tool mask}, reset at a compaction anchor. The history view gets an "Operation boundary" element. These items need no Store format change, and the new codec needs a new name (for example `openai-responses/2`) or existing Sessions fail `encoding_drift`. (source: #841)
D76. Item shapes: `{"type":"additional_tools","role":"developer","tools":[…]}` and `{"type":"configuration_update","reasoning":{"effort":…}}`. gpt-5.5 and older do not get `additional_tools`; Rui uses plain function definitions, not Codex's Lite `functions` namespace. The cache proof test extends src/model_adapter.zig:3948, :3976 and :4012. (source: #841)
D77. Effort changes use OpenAI's `configuration_update` item on every model, with no model list. A provider refusal is a faithful "change refused" error and effort stays unchanged. (source: 11-04 03:44Z)
D78. Model facts belong to the model id, in Rui's own catalog, not in core logic and not per provider. Following pi, the catalog is a models.dev snapshot shipped with Rui, refreshed from models.dev and saved in the Store. `model_capability.zig` stops being a hand-copied Codex list. (source: 11-04 04:40Z; review #1 reshaped)
D79. The catalog keeps three facts per model id: effort levels, context window, max output. It refreshes at Host start and whenever someone asks for the model list, together with the provider's live list, using ETag (an unchanged list is a 304), with no timer. The file is parsed once and the rest thrown away. If models.dev is down, Rui uses the last saved copy, then the shipped list. Nothing waits on it, and the fetch rides the Reactor with no new thread. Measured: 5.96 MB raw, 608 KB gzipped, 4,105 unique ids across 235 providers. (source: 11-04 04:50Z)
D80. Whether a model is usable comes only from the provider's live list, so a new model works at once with the preset's values. (source: 11-04 04:40Z)
D81. The UI groups models with the same id across providers. (source: 11-04 04:40Z)

## Store

D82. Rui gets its own database beside the app's on the same MySQL server (for Drift: `drift_rui` beside `drift`), not prefixed tables inside the app's database. Reasons: on MySQL a schema is a database (the "own schema" pattern of DBOS, graphile-worker, Solid Queue), and Prisma's `migrate dev` flags unknown tables and offers to reset the database, with no exclude option. (source: #850)
D83. The approved db-seam plan (a MySQL Store is a whole database) stands unchanged. Drift's only change is one setting, `database: "mysql://rui_user:…@host/drift_rui"`. Rui opens its own connection, and Drift's 10-connection Prisma pool is untouched. (source: #850)
D84. The Store runs on SQLite or MySQL. (source: #851)
D85. Rui has its own MySQL login, granted only on `drift_rui`. This is documentation, not a check. (source: #850)
D86. Refused at open, with one message naming what to fix: MySQL older than 8.4 or MariaDB; a read-only server or replica; relaxed durability (`innodb_flush_log_at_trx_commit`, `sync_binlog`, doublewrite); and, new, statement-format binary logging (`log_bin=ON` with `binlog_format=STATEMENT`). (source: #850; 11-03 16:29Z)
D87. The `store_owner` fence also checks `commit_seq` (`AND commit_seq=?`), so a restore or any foreign write stops a running Host at its next commit instead of mixing in-memory state (next ids read once at open, src/store/Store.zig:1298; in-flight work) into older data. (source: #850; 11-03 16:28Z)
D88. Documented rule: stop Rui before restoring; dump with `mysqldump --single-transaction --routines`. (source: #850)
D89. The Sessions `parent` column lands with whoever builds it, after the db thread's PR 5e-3, through schema.zig and typed rsql. The db thread's plan has no format bump left. (source: 11-03 16:28Z)
D90. Postgres is deferred ("MySQL and SQLite are the first targets"). The wire client from #768 stays merged and unused; only SQLite and MySQL spellings are needed now. (source: 11-03 16:29Z, 16:30Z)
D91. The db thread's plan after 5e-3: PR 6 tests per engine (SQLite and MySQL conformance), PR 7 Store thread, PR 8 MySQL (network ownership, `commit_seq` fence and binlog refusal), PR 9 Host wiring. The MySQL PR comes right after the Store worker thread PR. (source: 11-03 16:29Z, 16:30Z)
D92. Settlement batches grow from 16 to 64 items (two round trips for up to 64 items, about 10 KB more resident for the whole Store), riding PR 5e-2a. (source: 11-03, rui-db-seam-drift-calls.md)
D93. Store fsyncs stay. (source: #838 map)

## Process and removals

D94. Standing rules: no tolerated waste, simple over easy, no new Host threads (network work rides the Reactor), no backward compatibility, prompts get no tests. (source: #838 map)
D95. ARCHITECTURE.md contracts that change: (1) tools saved as records, not a fixed Bash/web-search enum; (4) `ResourceExceeded` renamed "context full"; (5) agents talk through the agent tools and Sessions get `parent`; (6) the provider key may arrive in memory at startup, not only from the key file; (7) Store on SQLite or MySQL, in its own database beside the app's; (9) Seam and Adapter join the term table; (10) one public interface. Items (2), (3) and (8) are replaced, see R entries. (source: #851)
D96. "New since you looked" is removed entirely: `mark-read`, `read_through`, `beyond_unseen`, the rule and overview tracking (#857 merged). (source: 11-03 16:20Z, 17:17Z; #851)
D97. `proposal-page` and `proposal-field` (no product caller) are deleted (#858). (source: #851; 11-03 17:17Z)
D98. `list_agents` is deleted by the deletion test; a parent's own transcript (`read_transcript(self, kinds: start_agent)`) lists its workers. (source: #846)
D99. The `openNamespaceAgent` rewrite moves out of the API ticket into the Drift port plan. (source: #849)

## Out of scope

D100. Out of scope: pi or pi-durable drop-ins; ACP and MCP-server translators (Rui exposing itself over those protocols); network transport, auth tokens, several Hosts sharing one Store; clients in languages other than TypeScript; an in-process native library. (source: #838 map)
D101. Skipped in the MCP client for now: discovery, progress (tolerated, not used), list-change subscriptions, output-schema validation, the Tasks extension, OAuth, falling back to the 2025 protocol. (source: #842)
D102. Deferred: search by meaning in `read_transcript` (#846); a `url` mode for a remote Rui, which would hold its own key (#838 map; #847).
D103. Not yet specified: build PR order; the Drift port plan (rewrite `openNamespaceAgent`, map Drift's hooks `beforeRequest`, `afterResponse`, `beforeTool`, `beforeCompact` onto Rui reads, cut over live map conversations, remove Drift's lane); the memory before/after comparison (#840, open: 249.4 MiB idle and 282.1 MiB with one agent mid-turn, Private_Dirty; 8 and 9 agents still to measure; same harness after the port); live checks of `configuration_update` for effort, `additional_tools`, old calls to a removed tool and hosted web search, each against OpenAI in the build PR that adds it (Marlin is only a gateway in front of OpenAI and other labs; at 04:54Z this was recorded as a proposal, with no Marlin-specific check script). (source: #838; 11-04 04:40Z, 04:54Z)

## Resolved from "Unclear" (11-04 05:20Z, my calls from earlier answers; Divyansh may object)

D104. (U2) `tools` is required in every agent spec, preset or not (`sessions.create`, `start_agent`, presets). `[]` means none. There is no Host default and no default preset. Basis: Divyansh 04:32Z "Let's not allow leaving out tools argument".
D105. (U3) Rui adds `rui_call_description` to MCP tools only. Bash keeps its own `description` argument. The core-owned tools and provider-run tools get a description written by core or the codec, in base-verb form. An MCP server receives exactly the fields its own input schema lists. Basis: 04:19-04:20Z.
D106. (U4) Parallel tool calls are always on. There is no Session or preset switch to turn them off. Basis: 02:52Z "of course models can ask for multiple tools at once".
D107. (U5) `Rui.connect` always starts Rui as a child of the calling process. There is no attach to an already-running Rui, and the `url` remote mode is out of scope. Basis: 03:35-03:40Z.
D108. (U6) Rui gets one launch frame on stdin carrying the Store URL (it contains the MySQL password) and the provider key. Neither touches disk, argv or the environment. The stdin pipe then stays open as the liveness signal (D: exit on close). It is built in the db-seam Host wiring PR (its PR 9), and the DB thread gets this interface.
D109. (U7) The answer is the model's final message in the feed. The feed then gets one "turn ended" entry carrying the ending: `done`, `context_full`, `provider_refused`, `stopped` or `interrupted`, plus the provider's text on a refusal. There is no `TurnFailedError` and no `result()`. Request-level failures stay `RuiRequestError` with Rui's rejection code. The entry does not list message ids (the conversation is linear, 04:28Z).
D110. (U8) Drift's MCP server ships inside Drift, and Rui restarts with every Drift deploy (D107). So Rui fetches each MCP server's tool list at Host start. Before a Session's next model call, Rui compares that list with the Session's saved copies and appends any added, removed or reworded tool to the Session's change list.

D111. (U1) Every agent spec states `effort` and `compactAt` (a token count). Rui never fills either from a model list. The catalog is used only to refuse a `compactAt` larger than the model's known context window. Basis: Divyansh 05:25Z "Yes". Replaces the percentage trigger and the catalog default effort (#841, #845).

## Amendments from the ledger check (11-04 05:40Z, mechanical, following later decisions)

A-D3. Not "auto-start": `Rui.connect` starts Rui as a child process (D5, D107, D108). The detached start-or-attach launch is replaced.
A-D9. The entry is named `turn_ended` (D109).
A-D14. `session.stop()` ends the Session and its attached children (D38). `session.interrupt()` cuts off the current turn only. Cancelling a wait never stops work.
A-D18. There is no `TurnFailedError`. Endings arrive as `turn_ended` entries (D109). Errors are `RuiRequestError`, `RuiStartError` and `RuiUnavailableError` (D116).
A-D28. The agent spec is D113, not "today's settings and nothing new".
A-D51. Replaced by D110 (fetched at Host start, compared per Session before its next model call).
A-D74. No Marlin-specific switch. A preset lists `web_search` only if wanted. If the provider refuses it, that is a faithful error (D47).
A-D75. "Declared tool mask" means the Session's tool records (D48). The top-level effort is the spec's `effort` (D111).
A-D76. No per-model list for `additional_tools`. It is used on every model, and a provider refusal is a faithful error (as D77 for effort).
A-D79. The catalog keeps the context window (used by D111) and the effort levels (used by the model picker). Max output is dropped until something reads it.
A-D108/D110. Their "exit on close" and "restarts with every deploy" refer to D5.
D21 is folded into D104.

## Decided from the ledger check gaps (11-04 05:40Z, my technical calls; the ledger-check.md recommendations unless noted)

D112. (G1) The launch frame is one length-prefixed JSON object on stdin: `{v, store, providerKey, runtimeDir, mcpServers, presets}`. Readiness is today's `/v1/host-info` probe on the socket in `runtimeDir`.
D113. (G6) The agent spec is `{model, provider, workspace, instructions, effort, compactAt, tools, loadedTools, permissionMode, outputSchema, label}`. `model`, `effort`, `compactAt`, `tools` and `permissionMode` are required. Core tools are named in `tools` like any other. `session.update` takes every field except `model`, `provider` and `workspace`.
D114. (G2) Under MySQL the socket, scratch and diagnostics live in `runtimeDir`. Ownership is the MySQL lock. Requests carry an opaque Store id that the Host reports at readiness, never the URL. `RUI_STORE` in Bash is that id (G10).
D115. (G4, G5) Feed kinds are today's rows, with `outcome` renamed to `turn_ended`. Added rows are `approval_requested` (whose Action id is `decide`'s `requestId`) and `session_changed` (one per change-list entry). One name set is used on the wire, in TS and in `read_transcript`. Endings are `done`, `context_full`, `provider_refused`, `provider_unavailable` (retries exhausted), `stopped`, `interrupted` and `failed` (with text). The ending set changes the Store format (D119).
D116. (G9) Typed errors are `RuiRequestError.code` (one list, including the new codes `provider_tool_missing`, `compact_at_too_large`, `effort_change_refused` and `mcp_server_unavailable`), `RuiStartError {code, message}` for refusals at open, and `RuiUnavailableError` when the child is gone. A call to a removed tool returns the tool result "this tool was removed".
D117. (G3) The TS client adds `rui.sessions.list()`, `rui.models()`, `rui.close()` and an `exit` event. `listActivity` inlines entry text up to a fixed bound, with `readContent(entry)` for longer text. It polls with backoff (250 ms rising to 2 s) only while the Session is busy and stops polling when idle. This changes the check's "poll every 250 ms", per the no-waste rule.
D118. (G7) When stdin closes, Rui runs infrastructure shutdown bounded at 10 s, then exits. The TS package restarts a crashed child with capped backoff and retries in-flight calls by their keys once the Host is ready.
D119. (G12) One Store format bump, owned by the tool-records PR (D48), carries parent, tool records, per-request tools, the change list, the saved catalog, saved tool copies, compactAt, the ending set and the read_through removal.
D120. (G8) `mcpServers: [{name, url, bearerToken, callTimeoutMs}]` travel in the launch frame. Tool names stay as the server gives them, and a name that collides with another server's, `bash` or a core tool is refused at Host start with a clear error. This changes the check's `server.tool`, because OpenAI function names allow no dots. An unreachable server keeps its last saved tool copies, and its calls fail as `mcp_server_unavailable`. Loopback plain HTTP only.
D121. (G10) The TS client sends an explicit `env` option on `send`, defaulting to empty. Drift's process environment never reaches Bash.
D122. (G11) A child inherits its parent's workspace and provider, and may only narrow the parent's tools and permission mode. There is no depth or fan-out limit until one is measured. A child's approval requests appear in the parent's feed. A child's ending (not only `done`) reaches the parent as a message.
D123. (G13) `update`, `stop`, `decide` and `interrupt` get a client-generated UUIDv4 key, with an optional `idempotencyKey` override.
D124. (G14) D95's contract-change list is extended with every item in ledger-check.md G14.
D126. The Workflow Runtime (ARCHITECTURE.md:65 and about 110 lines; no code in src/, no consumer) is deleted from the contract. It can return when a real user needs it. Basis: Divyansh 05:32Z "Yes".
D125. (G15) The spec gets one "Drift provides" list. The Rui binary ships in per-platform optional npm packages (Linux x86-64 and macOS arm64).

## Decided from the section writers' MISSING lines (11-04 06:00Z, my technical calls)

A-D14 (corrected). `session.stop()` is today's stop: it cancels the Session's current and queued work and its attached children's, and the Session stays usable, so a later message starts new work (ARCHITECTURE.md:1703, :3745).
A-D117 (corrected). `listActivity({ after })` ends at the current end of the feed. `listActivity({ after, follow: true })` never ends; it polls with backoff from 250 ms to 2 s whether the Session is busy or idle, because an idle Session can be woken by a child's or another agent's message. Each poll is one cheap page read.
A-D116 (corrected). `mcp_server_unavailable` is a tool result to the model when a call is made, and a `RuiRequestError` only when `sessions.create`, `update` or `start_agent` names a tool of a server that has no tools (D140).

Client and launch
D127. The working npm name is `rui` (final name at publish). Per-platform binaries are optional dependencies (`rui-linux-x64`, `rui-darwin-arm64`), found with `require.resolve`. It supports Node 22 LTS and later.
D128. Returns: `sessions.create` gives a Session handle `{ id }`. `sessions.list()` gives `{ id, label, state, parent }[]` from the existing session list route. `rui.models()` gives `{ provider, id, known, effortLevels, contextWindow }[]` from `/v1/model-list`. `update`, `stop`, `decide` and `interrupt` resolve to nothing once the Host accepted the command. Feed entries use the wire row fields in camelCase. `readContent` is a Session method.
D129. `rui.close()` closes the child's stdin and waits for it to exit (bounded by D118's 10 s). The `exit` event fires on every child exit with `{ code, signal, restarting }`. The restart backoff starts at 0.5 s and doubles up to 30 s.
D130. The launch frame is a 4-byte big-endian length followed by UTF-8 JSON. `v` is 1, and any other value is refused with `RuiStartError launch_frame_invalid`. Its provider field is `provider: { kind: "openai_key", baseUrl, key }`, which replaces the bare `providerKey` and `RUI_OPENAI_BASE_URL` for launched Hosts.
D131. The TS package creates `runtimeDir` with `mkdtemp` under the OS temp dir, mode 0700, and deletes it on clean exit.
D132. Connect's `tools` option is exactly the `mcpServers` list. A launched Host offers every built-in tool (Bash and the core tools), and the spec's required `tools` [D104] picks from them.
D133. `provider` in a spec defaults to the Host's single provider and may be left out. `workspace` is required when `tools` includes `bash`, and is unused otherwise.
D134. Entry text is inlined up to 16 KiB per entry. Longer text sets `truncated: true`, and `readContent(entry)` fetches the rest.
D135. A child's `approval_requested` row appears in every ancestor's feed up to the root, carrying `sessionId` (the child) and `requestId`. `decide(requestId, ...)` works on any ancestor's handle, and Rui routes it to the child's Session.
D136. `RuiStartError` codes are one per refusal at open: `launch_frame_invalid`, `store_locked`, `store_fenced`, `mysql_version`, `mariadb`, `read_only_replica`, `durability_<variable>`, `binlog_statement` and `tool_name_collision`.
D137. `update` checks `effort` against the catalog's effort levels when the model is known, and refuses synchronously with `effort_not_supported`. If the provider later refuses the `configuration_update` item, the next model call is retried without it, the effort stays as before, and a `session_changed` row records "effort change refused" with the provider's text. This replaces `effort_change_refused` as a request error.

Core and agents
D138. Every field `update` changes, and every tool `find_tools` loads, is one change-list entry with its own `session_changed` row. D53's four kinds are examples, not the full list.
D139. A child ended by its parent's stop or "context full" delivers nothing to the parent, because delivery would wake a parent that was just stopped. Every other child ending (done, failed, provider_refused, and so on) is delivered as a message [D122].
D140. `start_agent` with a spec wider than the parent's (tools or permission mode), or naming a provider or workspace, is refused as a tool error naming the field. Nothing is silently cut down.
D141. The core tools' exact JSON schemas and result text are written in the build PR that adds each tool. They are prompt text and get no tests [rui-engineering-rules 10].

Tools and provider
D142. A tool-name collision (between servers, with `bash` or a core tool, or with an MCP schema property named `rui_call_description`) fails Host start with `RuiStartError tool_name_collision`, naming both sources.
D143. `rui_call_description` is a required string property of at most 200 bytes. If a model leaves it out anyway, the line shows the tool name and arguments.
D144. An MCP JSON-RPC error or an `isError` result becomes a tool result to the model carrying the server's own text.
D145. D59's 10-minute default applies to MCP calls only. Bash keeps its 5-minute Host default.
D146. A call to a server that cannot be reached before the request is sent is "failed, not run". After the request was sent, it is "outcome unknown".
D147. A server unreachable at Host start that has no saved tool copies contributes no tools. A spec naming its tools is refused with `mcp_server_unavailable`.
D148. With the default empty `env`, Bash gets today's no-saved-environment treatment: the OS default `PATH` and the Host's `HOME` (ARCHITECTURE.md:1622).
D149. A launched Host (via connect) supports only the OpenAI-key Adapter. ChatGPT sign-in stays the CLI/TUI path with its file credential.
D150. Both OpenAI Adapters list `web_search` as a provider-run tool. Any provider-side refusal during a Turn, including Marlin's 403 budget refusal and a refused `web_search`, ends the Turn as `provider_refused` with the provider's text. `failed` is for Rui-side errors.
D151. When several models.dev providers list the same id, the OpenAI Adapters use the entry under models.dev's `openai` provider, and otherwise the first entry in models.dev's order.
D152. For a model the catalog does not know, `compactAt` is not checked. A context overflow ends the Turn `context_full`.
D153. The provider's live list stays in memory as today (ARCHITECTURE.md:3297) and is refreshed at the same triggers as the catalog.
D154. The ChatGPT Adapter's live list is the catalog's `openai` ids. A model ChatGPT does not serve is refused by the provider as a faithful error.

Store
D155. Drift's operator creates `drift_rui` empty and grants Rui's login all privileges on it and nothing else. Rui never creates databases.
D156. Accepted values: `innodb_flush_log_at_trx_commit=1`, `sync_binlog=1` when the binlog is on, and doublewrite ON. Anything else is refused with `durability_<variable>`.
D157. When the `commit_seq` fence fires, the Host exits with code `store_fenced`. The TS package's restart then starts cleanly on the restored data.
D158. The MySQL lock is `GET_LOCK` named after the database, as in the db-seam plan. The opaque Store id is a random id written into the Store at creation, the same across restarts. A SQLite Host keeps today's Store directory and path selector unchanged.
D159. The contract-change list (D95, D124) also covers every ledger decision that contradicts ARCHITECTURE.md text, including `:180` defaults, the `env` at `:1601-1606`, `RUI_STORE` at `:1619`, the percentage compaction trigger, and the outcome set.

D160. `loadedTools` defaults to every tool in `tools`. Only a spec that sets a smaller `loadedTools` uses `find_tools` to load the rest.
D161. The text of the message that carries a child's answer or ending to its parent is prompt text, written in the build PR that adds child delivery, with no tests (same rule as D141).

## Decided from the spec reviews (11-04 06:30Z, my technical calls; verified against origin/main)

D162. The turn's answer is the `assistant` entry marked `final: true`, which is the last assistant message of the Turn. Other `assistant` entries are commentary.
D163. To find its children, a parent uses `read_transcript(self, kinds: ["call"], query: "start_agent")`, built only from D115's name set and the existing word search.
D164. The one format bump [D119] does not carry the `read_through` removal, which already shipped at schema 50 (#857). The bump starts from schema 50.
D165. The effort check keeps today's code `unsupported_reasoning_effort` (src/protocol.zig:315) on create and on update. D137's `effort_not_supported` is dropped, so no new name is added for an existing check.
D166. Every `start_agent` spec refusal is a tool error to the model [D140]. `provider_tool_missing` and `compact_at_too_large` are `RuiRequestError` codes on `sessions.create` and `update`.
D167. `session.interrupt()` is today's Model Interruption (ARCHITECTURE.md "Interrupting one model operation"). It interrupts the Session's current model call. If other messages are queued, the Turn continues with them. Otherwise the Turn ends `interrupted`. It does not interrupt running tool calls; `stop()` does. The client finds the target model Operation from the Session's status.
D168. The `listActivity` cursor is an opaque string encoding `{position, ordinal}`. Entry text is `entry.text`. `turn_ended` carries text for `provider_refused` and `failed` only.
D169. A child Session started by `start_agent` inherits its parent's saved Bash environment, as it inherits the workspace [D122]. Messages delivered by `message_agent` or by a child's ending do not change the receiver's environment.

D170. Each feed entry carries its own cursor as `entry.cursor` [D168]; pass the last one as `after`.
D171. `session.interrupt()` when no model call is current is a no-op that resolves without sending anything.

D172. Rui's Zig request and reply types are the one source of truth. The build emits `openapi.json` from them, the file is checked in, and CI fails when it differs from what the code emits. Clients in every language are generated from that file (Stainless, or openapi-generator as the free fallback), TypeScript first and then Python and Go. A thin hand-written layer per language adds the child launch and stdin frame, `listActivity` follow polling, request-key building and a Unix-socket transport. Basis: Divyansh 06:16Z "Sure".

## Decided while cutting the build plan (11-04, my technical calls; build-plan.md)

D173. Replaces D119 and D164's "one format bump". Every merge to main ships a release, so each PR that changes the Store format bumps `schema_version` itself, and format-changing PRs land one at a time in build-plan.md's format queue.
D174. The change list (D53, D138) is `session_revision` plus each Operation's frozen settings, not a new table. A revision may also be made by the core (`find_tools`, MCP rewording), so `command_key` allows a core-made key.
D175. Replaces D108's owner. The launch frame is built early in its own PR with `store` as a SQLite directory; the DB thread's PR 9 adds the MySQL URL form, `runtimeDir` rules and the Store id. Drift runs only on MySQL (Divyansh 06:46Z), so the DB series is Drift's critical path; the early frame only lets the TS client and MCP work be tested before it lands.
D176. D169's inherited environment is the parent's environment held in Host memory (SessionEnvironments.zig), never stored. D76's cache proof tests are at src/model_adapter.zig:3566, :3594 and :3630.

## Decided from Drift's review of #872 (11-04 07:00Z, my technical calls; drift-review-triage.md)

D177. Every MCP `tools/call` carries the calling Session's id, parent and root in `_meta`. Arguments are unchanged. It is context, not a call id, so D61 stands.
D178. `sessions.create` accepts `parent`, with `start_agent`'s rules (inherit, only narrow). No Session tags: the caller keeps its own mapping keyed by Session id.
D179. Replaces D73. The feed has a `model_call` entry per model call: model, served model, input, output and cached tokens, latency, time to first event, status.
D180. A child's `turn_ended` appears in every ancestor's feed with its `sessionId`, as approvals do (D135).
D181. `activeCapacity` travels in the launch frame (today's `--active-capacity`). Rui adds no priority.
D182. An MCP result follows Bash's model-facing output bound; the full result is kept and read with `read_transcript(full)`.
D183. `Rui.connect` retries `store_locked` until `lockWaitMs` (default 120 s), then fails with `RuiStartError store_locked`.
D184. Within one reply, MCP tools without `readOnlyHint: true` run one at a time in reply order; read-only ones run at once. The hint orders calls only.
D185. The TS package starts Rui with only `PATH`, `HOME` and `TMPDIR`. Docs state `rui.shell` runs as the host's user and is not a sandbox.
D186. `rui-linux-arm64` joins the release platforms.
D187. TS docs: one `Rui.connect` per process (cache on `globalThis` in Next.js).
D188. D82's Prisma reason is removed (Drift uses `migrate deploy`). Drift's pool still carries MCP tool calls; Drift bounds them.
D189. Marlin's `GET /v1/models` is unprobed; Drift probes it before the port, and D80 is revisited only if it fails.
D190. #840 measured: 249.3 MiB idle, 282.1 (1 agent), 285.7 (8), 298.0 (9), 312.8 three minutes after release.

D191. (Divyansh 07:02Z idea, "proceed" 07:03Z) When the compaction request itself would not fit, Rui drops the oldest messages from what it sends to compaction until it fits, then compacts; the feed records how many were dropped. The Session, its ID and its attached children carry on. "Context full" remains only for one item larger than the window. Changes ARCHITECTURE.md:657/:685 ("never truncate"). The card on restart-in-place/adopt was withdrawn.

D192. (Divyansh 07:05Z, card) Replaces D29's "only the model is fixed" and D113's update exclusion of `model`. `session.update({model})` may change a running Session's model within the same provider. The next model request rebuilds from the visible conversation (messages, calls, tool results), dropping the old model's hidden reasoning and compacted items. It costs one cache miss, which a new model cannot avoid. The Session ID and its attached children carry on. The change is a revision with its `session_changed` row.

## Replaced

R-D19. TS types generated from Rui's wire definitions directly (#849) -> replaced by D172.

R1. `idempotentHint: true` means safe to rerun after a crash, and only anything else is "outcome unknown"; the core's never-repeat rule resends a call safe to rerun with the same call id. (source: #838 map; design doc core table) -> replaced by D32
R2. Every MCP call carries a stable Rui call id in `_meta` (for example `dev.rui/callId`), the same on retry, as Drift's dedupe key for its receipts; after a broken stream the client re-issues the call with a new JSON-RPC id. (source: #838 map; #842; #844) -> replaced by D61
R3. Every tool call gets one random id, used inside Rui and sent to MCP servers. (source: 11-04 03:50Z) -> replaced by D61
R4. The Host marks each server trusted or not; only a trusted server's `idempotentHint` or `readOnlyHint` counts, and Drift's server is trusted. (source: #842; #844 point 3) -> replaced by D61
R5. A cut-off call to a trusted safe-to-rerun tool is resent with the same call id; the tool record carries a safe-to-rerun flag; a cap on resends was left for build planning. (source: #844 points 4 and record) -> replaced by D32
R6. A tool timeout is a failed try, and the model is told "timed out after N s"; a timed-out call is cut off and handled like a cut-off call. (source: 11-04 03:11Z; #844 point 8) -> replaced by D60
R7. Web search is not a tool; it moves to the Provider Seam as a setting (ARCHITECTURE.md contract change 2). (source: #844; #847; #851) -> replaced by D47
R8. Agent and transcript tools live on a built-in `rui.agents` server and `find_tools` on `rui.tools`; the Tools Seam's built-in Adapter is "built-in tool servers (shell, agents, find_tools)". (source: #844; #846; #851) -> replaced by D24
R9. Every tool record names its runner: `rui`, `core` or `provider`. (source: 11-04 02:29Z) -> replaced by D46
R10. The call-note field has the working name `rui_note`. (source: #844 point 6) -> replaced by D62
R11. Tools grow only: a Session can add tools but never remove them; for fewer tools, start a new Session. (source: #845) -> replaced by D53
R12. Omitted `tools` means the Host's default set; a new Session's default tools are the Host's set, not "Bash only" (ARCHITECTURE.md contract change 3). (source: #845; #851) -> replaced by D21
R13. Workers are built-in agent tools, not a parent-child concept in the core. (source: #838 map) -> replaced by D27
R14. A preset is a saved, named spec the caller registers. (source: #846) -> replaced by D22
R15. The launch call is `startRui({ provider: { baseUrl, key } })` / `startRui({ database, … })`. (source: #847; #850) -> replaced by D3
R16. `send` returns a waitable `Run` (#849), then a `Turn` (#851 Q2); `run.result({ abortSignal })` / `turn.result()` waits, and the abort ends only the wait. (source: #849; #851) -> replaced by D8
R17. A new Host-side held wait for a Turn's answer, so clients need not poll (ARCHITECTURE.md contract change 8). (source: #849; #851) -> replaced by D8
R18. Drift learns a message is done from `session.status()` and reads the answer from `listActivity()`. (source: 11-04 02:15Z) -> replaced by D9
R19. `idempotencyKey` is Drift's own row id, and without one the client generates a UUID and reuses it for its own retries. (source: #849) -> replaced by D17
R20. The typed turn failure is `RunFailedError.ending`. (source: #849) -> replaced by D18
R21. Rui's tables sit in the app's database with a fixed compile-time `rui_` prefix applied only in MySQL rendering; the `GET_LOCK` name hashes database and prefix; db-seam's "whole empty database" checks narrow to `rui_` objects; extra refusals at open for app triggers or foreign keys on `rui_` tables and unknown `rui_` tables or views; "the app must not write `rui_` tables". (source: #843) -> replaced by D82
R22. The binlog STATEMENT refusal lands in the db thread's PR 9 and the `commit_seq` fence in PR 8. (source: 11-03 16:28Z) -> replaced by D91

## Unclear in the sources

U1. Catalog role in effort and compaction. #841: top-level effort is fixed and "effort is the catalog default". 11-04 catalog refresh: "Rui keeps three facts per model id (effort levels, context window, max output)", with no default effort. Review #1 ("reshaped into the model catalog") proposed "The spec states the effort and an absolute compaction trigger in tokens", while #845 keeps "the existing compaction trigger" (today a percentage of the table's window, src/model_capability.zig:30). The sources do not say where the default effort comes from or whether the trigger becomes absolute tokens.
U2. Host default tools. 11-04 design doc: "tools is required in every preset. [] means none, and there is no Host default." Review #11, recorded as adopted: "tools is always given. The Host default is a named preset Drift can spread in." The sources also do not say whether `tools` is required in a spec given without a preset (`sessions.create`, `start_agent`).
U3. Call-note scope. #844 point 6: Rui adds the field "to every tool's input schema" and "Bash's existing description field becomes this field". 11-04 design doc: "Rui adds rui_call_description to each MCP tool's input, ... and sends the server only the fields its own format lists" (memory file: "stripped before the MCP call"). Whether Bash and the core tools get the field, and whether Rui strips one field or sends only listed fields, is not settled.
U4. Session-level call ordering. #844 point 7: "A Session that needs strict order asks the model for one call per reply (parallel_tool_calls: false)." Design doc body: "A model that wants order waits for results before the next call." 11-04 02:52Z only says parallel is "ON for every model". Whether a Session can still turn parallel calls off is not stated.
U5. Attach and remote mode. #849: `Rui.connect` "starts the Rui process on the given database, or attaches when one is already running for it"; #838 map: "a url mode for a remote Rui comes later". 11-04 03:35Z: "Rui is a child program on the same box, never a separate server; it exits when the Drift process that started it goes away". Whether attach and the later `url` mode survive is not stated.
U6. Launch interface handoff. 11-03 16:28Z: "Send it the Host launch interface (Store URL + stdin key) when settled so its PR 10 builds against it"; rui-db-seam-drift-calls.md: "PR 10 builds against the Host's Store-URL-over-stdin interface", while its 16:29Z plan ends at "9 Host wiring". #849 lists "MySQL URL and stdin key handoff" without saying how the URL travels. Which PR builds it, and whether the Store URL goes over stdin, is not settled.
U7. How Drift reads a turn's answer and failure. 11-04 design doc names only an '"agent finished" entry'. Review #7, recorded as adopted, says "A Turn's ending is an activity entry that names the message ids it consumed and holds its result" and "status() becomes a convenience computed from the log". The design doc still lists `TurnFailedError.ending` though there is no longer a `result()` to throw it. What the entry carries, and where the typed failure surfaces, is not stated.
U8. When Rui learns of a changed MCP tool. #844 point 2: Drift's list is fetched "once at Session start ... refreshed only when the Host is told to reload". 11-04 03:48Z: "when an MCP server's tool changes, top stays as saved and Rui appends the new version ... Running Sessions see it". 11-04 design doc: "A reworded MCP tool is appended automatically." What triggers the re-fetch is not stated.
