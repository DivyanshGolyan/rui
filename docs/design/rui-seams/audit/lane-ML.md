# Lane M + L design audit (2026-11-05)

Scope: landed M #877 #880 #883 #895 #906 #909 #913 #919 #925 #931 #941 #955; open M #944 (m3b1-settle), #960 (m3b2b). Landed L #874 #878 #882 #888 #889 #891 #893 #898 #900 #901 #902 #930; open L #969 (S2). Read against origin/main at fetch time and the open heads. Line numbers are on main unless a branch is named.

## Findings

1. **The MCP call line is the tool name, not `rui_call_description`.** #944 `src/store/domain/model_settlement.zig:1731` (branch) saves the call's description as the tool name ("the richer 200-byte projection is deferred"). D62, D63, D143.
   - Code: the feed and the TS client get only `fetch_page`. The TUI gets the real line by re-parsing the raw arguments itself (`src/session_view.zig:846` `mcpRequest`, `:703`, using `mcp/arguments.zig` `descriptionRange`). The wire presentation is still capped at Bash's 100 bytes, against D143's 200.
   - Intended: Rui pulls the line out once, saves it with the call, and every caller reads it through the client (D62). Progress is the per-call description (D63), and Divyansh called the line "very important".
   - Severity: **blocks Drift**. Drift's progress view would show tool names only.
   - Fix: at settlement, when the runner is `.mcp`, take the description with `arguments.descriptionRange` and store it as the call's description. Widen the stored and wire description to 200 bytes for MCP (or for all tools). Delete the TUI's re-parse so `session_view` reads `presentation.description` the same way it does for Bash.

2. **The TS client cannot pass MCP servers.** `clients/ts/src/client.ts:22-35` `ConnectOptions` has no `tools`, and `launchFor` (`:296`) never writes `mcpServers`. This holds on main and on #969. D3, D45, D120, D132.
   - Code: the Host side landed in #906 and #925, but `Rui.connect` can only start a Host with no MCP servers.
   - Intended: connect's `tools` option is exactly the `mcpServers` list (D132).
   - Severity: **blocks Drift**. Drift exposes its tools only through MCP (D45).
   - Fix: add `tools: {name, url, bearerToken, callTimeoutMs?}[]` to `ConnectOptions` and map it to `mcpServers` in the frame. Map `tool_name_collision` into `RuiStartError`, which already passes codes through.

3. **The Tools Seam has no runner interface: MCP gets its own entry points through the Store and core.** Seen in #944 and #960. D44, D46. Codebase-design: hypothetical seam, leaked abstraction.
   - #960 adds `Store.admitMcpActionAttempt` and `readMcpExecutionInput` (`src/store/Store.zig:774`, `:785`), plus `nextMcpAction` and `resolveMcpAction`. It puts MCP-only texts in the Store's action domain (`action.zig:548` `mcp_stop_*_text`, `mcp_indeterminate_text`), and an `if (found.mcp)` branch in settlement (`action.zig:496`). `execution_turn` and `server_execution` gain `mcp` slots beside the Bash slots.
   - #944 adds MCP-specific SQL to core settlement (`model_settlement.zig:879` `historical_mcp`, `owner='mcp'`).
   - Intended: core sees a Rui-run Action, and `rui.shell` and MCP are its two adapters. Two adapters would make this a real seam. Today each runner is a separate path through the Store, so a third runner means another set.
   - Severity: design debt.
   - Fix: one `RunnerAction` interface in the Store (admit attempt, read input, settle with a resolution code and text) and one runner-agnostic attempt row. The MCP result and stop texts move behind `src/mcp/` (see 5). `server_mcp.Calls` becomes the MCP adapter beside the Bash slot owner.

4. **"Offered tools" exists in two shapes.** #944 `src/tools.zig:251` (branch) adds `mcp_names`/`mcp_offered` slices beside the fixed `records: [Tool]` array. `:630` builds an MCP `Record` with only a name and owner. D48, D49. Lens: special case; one concept in two shapes.
   - Code: built-ins are matched from records and MCP tools from a name list filled by a SQL batch lookup. Yet M3a's `tools.Catalog` already holds MCP records with their schemas.
   - Intended: every tool has one record, and each request saves exactly the records it offered (D48, D49).
   - Severity: design debt.
   - Fix: `Offered` becomes the Operation's frozen record list (a slice of `Record`), whatever the owner. `inspectCall` looks up one list, and the record keeps its schema and server for the runner.

5. **A call that was sent is still reported as "failed" or "cancelled".** `src/mcp/result_text.zig:103` and `:113`; #960 `src/server_mcp.zig:239`. D60, D146.
   - Code: an HTTP non-2xx answer after the request was sent is `failed`, and so is an answer over 4 MiB. A Session stop after the request was sent settles with code `.cancelled`, although its text says "outcome unknown".
   - Intended: "failed" only when Rui actually stopped the work. After the request was sent, the outcome is unknown.
   - Severity: design debt. Drift reads the code, not the prose.
   - Fix: map 5xx and stop-after-send to `indeterminate`. Keep `failed` for 4xx and JSON-RPC errors, which say the work did not happen. An oversized answer is succeeded/failed by `isError`, with the excerpt cut (see 6).

6. **The full MCP result is not kept.** `src/mcp/result_text.zig:1` ("bounded without retaining a copy") and `:113`. D182.
   - Code: the model gets a 10,000-byte excerpt, nothing else is saved, and an answer over 4 MiB becomes an error.
   - Intended: the result follows Bash's model-facing bound, the full result is kept, and `read_transcript(full)` reads it.
   - Severity: design debt.
   - Fix: stream the whole answer into content storage, the way Bash retention does, and render the excerpt from that content.

7. **`readOnlyHint` is dropped before it is used.** `src/mcp/offered.zig:64-70`; `tools.Record` has no `read_only` field. #960 `action.zig:610` `mcp_serial_sql` runs every MCP call in a Session one at a time. D184.
   - Code: `Listing.Entry.read_only` is parsed and then lost at merge, so read-only tools never run at once.
   - Intended: non-read-only calls run one at a time in reply order, and read-only calls run at once.
   - Severity: design debt. It is slower, not wrong.
   - Fix: carry `read_only` on `Record` and in its digest (a format change, so it goes in the queue), then add `AND NOT read_only` to the serial predicate.

8. **There is no `mcp_server_unavailable` request code.** `src/protocol.zig:387-409` (`ConfigurationRejection`). D116, D120, D147.
   - Code: a spec that names tools from a server that was down at start, with no saved copies, is refused as `unknown_tool`. So a typo and a server outage look the same.
   - Severity: design debt.
   - Fix: keep the configured server names in the catalog. Refuse a name owned by a configured server with no records as `mcp_server_unavailable`, then regenerate `openapi.json`.

9. **Wire changes to the Session report bypass D172's check.** `src/openapi.zig:61` `.report` and `:185`: the `/v1/inspect-session` reply is "schema not described yet". #944 `src/protocol_reply.zig:683` (branch) adds `server` and widens `tool` without touching `openapi.json`. D172, D213, D12.
   - D213 required this schema before A3b used it for `status()`. A3b (#889) shipped without `status()`, against D12. Meanwhile the TUI keeps depending on this undescribed reply.
   - Severity: design debt.
   - Fix: describe `Current` and `Full` in the emitter, then add `session.status()` over it. Unresolved Action rows then carry `server` in a schema that CI checks.

10. **The agent spec has two wire spellings.** #969 `src/core_tools.zig:152` (branch) `parseAgentSpec` reads camelCase `{model, effort, compactAt, tools, permissionMode, ...}` for presets and `start_agent`. `/v1/configure` takes snake_case `Configuration` with `{state: omitted|null|value}` wrappers. The TS client keeps both: `client.ts:304` sends the spec raw into the frame, and `sessions.ts:88` translates it for configure. D22, D172. Lens: one fact in two places.
    - Severity: design debt.
    - Fix: give presets the `Configuration` shape (or move configure to the spec shape once K8 lands) with one parser. Emit the launch-frame schema, presets included, into `openapi.json` as a component.

11. **The launch frame is outside the single source.** `clients/ts/src/client.ts:81` and `:385` type the frame as `object`, written by hand. The Zig `Wire` struct in `src/launch_frame.zig:116` is the only definition. D112, D130, D172.
    - Code: a field renamed on one side breaks only at runtime. `RuiStartError.code` and `RuiRequestError.code` are `string` (`errors.ts:8`, `:22`), although `wire.ts` already has the enums. D18 and D116 ask for typed codes.
    - Severity: design debt.
    - Fix: emit `LaunchFrame` and `StartError` into `openapi.json` and type `launchFor` with `satisfies Schemas["LaunchFrame"]`. Type `code` as the generated unions.

12. **Feed entries drop the generated row types.** `clients/ts/src/feed.ts:61-74` `FeedEntry` is a bag with `[field: string]: unknown`, and `camelCase()` renames keys recursively at runtime. D128, D172. The lens question is whether the TS client is a thin layer over generated types: for the feed it is not.
    - Severity: design debt. The feed is Drift's main surface (D9).
    - Fix: derive `FeedEntry` as a mapped camelCase type over `Schemas["ActivityItem"]["value"]` (a discriminated union on `kind`). Rename only the top-level keys of a row.

13. **Feed polling never stops while the Session is idle.** `clients/ts/src/feed.ts:221-223`: `follow` polls at 2 s forever and ignores `page.work.state`. D117.
    - Severity: nit.
    - Fix: when `work.state.kind` is `idle` and the page is empty, poll at a long interval (or none until the next write from this client). Log the chosen interval if it is not "stop".

14. **The OpenAPI request model multiplies variants.** `src/openapi.zig:103-104` gives each optional field (`require_model`) a whole request variant, and #969 doubles `ConfigureRequest` to 4 variants for `preset`. D172, D212.
    - Code: the request is positional head++tail, so N optional fields give 2^N variants and generated clients get unions instead of optional properties.
    - Severity: design debt. It grows with every optional field.
    - Fix: after K8 (D212), emit one object schema with optional properties, and parse examples with fields in random order.

15. **Unlogged decisions** (nits unless noted):
    - StartError `runtime_dir_unusable` (#882, `launch_frame.zig:26`) and `invalid_preset` (#969), and configure codes `unknown_preset` and `preset_on_update` (#969 `protocol.zig:417-418`). D136 and D116 list neither.
    - A server listing over 1,024 tools is refused as `launch_frame_invalid` (`server.zig:879`); this is not a frame problem, so it wants its own code.
    - Host-wide MCP concurrency is 16 calls (64 MiB of answer buffers), and descriptors are reserved for them (#960 `server_mcp.zig:16`). Up to 8 servers are listed serially at 10 s each before readiness (`offered.zig:21`, `launch_frame.zig:44`).
    - The MCP timeout is stored in the column `bash_timeout_ms` (#960 `action.zig:698`). Rename it `attempt_timeout_ms` with the seam work in 3.
    - `RETRYABLE_START_CODES` restarts after `store_fenced` (`client.ts:62`). A fenced Store usually means another Host took over, so restarting needs a ledger call.
    - `ModelSummary` lacks `effortLevels` and `contextWindow` (D128, `sessions.ts:60`). It waits on C1, but D128 should note that.

## Cross-PR coherence

- There are three derivations of who runs a tool: `tools.Owner {rui, provider, mcp}` stored (T lane), `tools.Runner` derived by name comparisons (#944), and the TUI's `ActionTool.runner()` derived from whether a wire `server` field is present (#944 `session_view.zig`). D46 says derived, not stored. One `Runner.of(record)` on the frozen record, exposed on the wire as one `runner` field, would remove the other two.
- There are two enums for one resolution: `mcp/result_text.Code` and the Store's `ActionResolutionCode`, mapped by a switch in #960. Return the Store code directly.
- The resolution code `spawn_failed` (a Bash process word) now also means "MCP request not sent". It is acceptable as "failed, not run", but give it a neutral name if 3 is done.

## Match the design cleanly

#877 M1 (HTTP/1.1, loopback only, on the Reactor) · #880 M2 (stateless 2026-07-28 headers and `_meta`, D64/D65) · #883 · #909 (paging) · #913 (no call id, D61) · #919 · #941 (real server library) · #955 · #895 (`rui_call_description` shaping and the D142 collision; `arguments.zig` sends only the listed fields, D105) · #906 frame side (the TS side is missing, see 2) · #874 P0 · #893 · #898 · #900/#901 A4 (linux-arm64, D186) · #902 D196 · #930 (typed request bodies, the D212 interim). `_meta` keys and id strings match D205 (`post.zig:131-142`; the Turn id is a decimal like the feed's `turn_ended.turn`).
