# Rui core and Seams: design spec

Date: 2026-11-04.

## Contents

1. [Purpose and reader](#purpose-and-reader)
2. [Summary](#summary)
3. [How Drift uses Rui](#how-drift-uses-rui) (example, calls, launch, lifetime, feed, request keys, errors)
4. [Core](#core) (concepts, never-repeat, compaction, Turn endings, scheduler, agent spec, change list, cache-safe requests)
5. [Agents](#agents)
6. [Tools Seam](#tools-seam)
7. [Provider Seam and model catalog](#provider-seam-and-model-catalog)
8. [Store Seam](#store-seam)
9. [ARCHITECTURE.md contract changes](#architecturemd-contract-changes)
10. [Removals](#removals)
11. [What Drift provides](#what-drift-provides)
12. [Questions for the Drift agent](#questions-for-the-drift-agent)
13. [Not yet specified, deferred and out of scope](#not-yet-specified-deferred-and-out-of-scope)
14. [Late details](#late-details)

## Purpose and reader

This spec describes Rui after the Seams work, with Drift as its first user. Drift is an internal Node and MySQL app that runs as a single instance [D4]. Rui ships its own revised interface, and Drift is ported to it. There is no pi or pi-durable drop-in package [D1].

The reader is the agent that owns Drift. You should be able to review this spec without asking anything. Check these points against Drift's code:

- Every call in "How Drift uses Rui" exists, and Drift has the inputs it takes.
- The feed entry kinds and the Turn endings cover every case Drift's code branches on.
- Every error type and code that Drift must handle is in the error tables.
- "Questions for the Drift agent" lists what we assumed about Drift and need confirmed.

Every design statement ends with its ledger reference in brackets, such as [D17] or [D14, A-D14]. The numbers point into the decision ledger, [ledger.md](ledger.md). A `Dn` line is a live decision. An `A-Dn` line amends the `Dn` line it names and wins over it. Where the ledger has a corrected amendment, such as A-D14 (corrected), this spec follows the corrected one. The `Rn` lines are replaced decisions, and this spec does not describe them. A statement about today's behaviour cites a file and line in the Rui repository at commit `120f73c`, such as (ARCHITECTURE.md:209). This spec makes no decision of its own.

Each fact lives in the one section that owns it. Other sections point to it by section name.

## Summary

Rui is a core plus four Seams. A Seam is a plug-in point of the core, and an Adapter is one thing that fits it [D36]. "Adapter" replaces "Plug", and the words "Socket" and "port" are avoided [D36]. Each Seam needs two real Adapters [D35].

The standing rules are no tolerated waste, simple over easy, no new Host threads (network work rides the Reactor), no backward compatibility, and no tests for prompts [D94].

| Seam | What it connects | Adapter 1 | Adapter 2 | Ledger |
| --- | --- | --- | --- | --- |
| Client | Callers of Rui's one public interface | CLI and TUI | TypeScript package | D20, D35 |
| Tools | Tools a model can call | `rui.shell` (Bash) | MCP servers | D35, D44, D45 |
| Provider | Model APIs | ChatGPT sign-in | OpenAI key, or a gateway such as Marlin | D35, D69 |
| Store | Saved state | SQLite | MySQL | D35, D84 |

The core owns Session (with a first-class `parent`), Message, Turn, Operation, Attempt, Resolution, the never-repeat rules ("outcome unknown"), compaction, the scheduler, and agent specs and presets [D23]. The tools `start_agent`, `message_agent`, `read_transcript` and `find_tools` belong to the core and run as core commands, not through the Tools Seam [D24]. A provider-run tool such as web search comes back finished inside the model's reply [D47].

Drift uses the TypeScript Adapter of the Client Seam, the MCP Adapter of the Tools Seam, the OpenAI-key Adapter of the Provider Seam with Marlin's base URL, and the MySQL Adapter of the Store Seam [D45, D69, D83]. The TUI and CLI use the same routes as the TypeScript package and get nothing it cannot call. The TUI is a plain consumer of that interface [D20]. The word for one unit of agent work is Turn everywhere, and the client never says "Run" [D26].

## How Drift uses Rui

Drift's npm package starts Rui as a child program on the same machine, pointed at Drift's MySQL server [D4]. Rui keeps its tables in its own database, `drift_rui`, beside Drift's `drift` database [D82]. Drift's only Store setting is the `database` URL, and Rui opens its own connection, so Drift's 10-connection Prisma pool is untouched [D83]. Drift exposes its own tools as an MCP server, and Rui is the MCP client [D45]. Drift talks to Rui through one small TypeScript package [D2].

### Complete example

The sample uses the names the ledger fixes. Comments mark the names that are placeholders.

```ts
import { readFile } from "node:fs/promises";
import { Rui, RuiRequestError, RuiUnavailableError } from "rui"; // working npm name, final at publish [D127]

// Presets are agent specs in Drift's code. They are passed at connect and never stored.
const presets = {
	triage: {
		model: "gpt-5.5",
		// provider is left out. It defaults to the Host's single provider [D133].
		// workspace is left out. It is required only when tools includes "bash" [D133].
		instructions: await readFile("doctrine/triage.md", "utf8"),
		effort: "medium",
		compactAt: 200_000,
		tools: ["read_transcript", "find_tools", "lookup_ticket", "run_sql"],
		loadedTools: ["lookup_ticket", "find_tools"],
		permissionMode: "ask",
		label: "triage",
	},
};

const rui = await Rui.connect({
	database: "mysql://rui_user:…@127.0.0.1/drift_rui",
	provider: { baseUrl: "https://marlin.labs.dreamplug.net/v1", key: marlinKey },
	tools: [
		{ name: "drift", url: "http://127.0.0.1:3000/api/mcp", bearerToken: mcpToken, callTimeoutMs: 600_000 },
	],
	presets,
});

rui.on("exit", ({ code, signal, restarting }) => log.warn("rui child exited", { code, signal, restarting }));

// One Session per Drift chat. The key comes from Drift's own row id. The result is a Session handle { id }.
const session = await rui.sessions.create(
	{ preset: "triage", instructions: ticketBrief },
	{ idempotencyKey: `chat:${chat.id}` },
);

try {
	const { messageId } = await session.send(userText, { idempotencyKey: `msg:${message.id}` });
	await saveReceipt(message.id, messageId);
} catch (err) {
	if (err instanceof RuiRequestError && err.code === "idempotency_key_conflict") throw new Error("key reused with new text");
	if (err instanceof RuiUnavailableError) return retryLater(message.id);
	throw err;
}

// Drift follows one feed, in order. With follow: true the iterator never ends.
// Entry fields are the wire row fields in camelCase. Inlined text is `entry.text` [D168].
// `after` is the opaque cursor string, encoding {position, ordinal}, where Drift last stopped reading [D168].
async function followChat(session, savedCursor) {
	for await (const entry of session.listActivity({
		after: savedCursor,
		follow: true,
		kinds: ["assistant", "approval_requested", "turn_ended"],
	})) {
		switch (entry.kind) {
			case "assistant":
				// Only the entry marked final is the Turn's answer. Other assistant entries are commentary [D162].
				if (entry.final) await saveAnswer(chat.id, entry.truncated ? await session.readContent(entry) : entry.text);
				break;
			case "approval_requested":
				// entry.sessionId names the child when a worker asks. decide works on this handle.
				await session.decide(entry.requestId, (await askReviewer(entry)) ? "allow" : "deny");
				break;
			case "turn_ended":
				// entry.text is set for provider_refused and failed only [D168].
				if (entry.ending !== "done") await markTurnFailed(chat.id, entry.ending, entry.text);
				break;
		}
	}
}
void followChat(session, savedCursor);

// Later, from Drift's UI. Each resolves to nothing once the Host accepted the command.
await session.update({ effort: "high" });
await session.interrupt();
await session.stop(); // the Session stays usable, and a later send starts new work

process.on("SIGTERM", () => rui.close());
```

### Call reference

Rui's Zig request and reply types are the one source of truth. The build emits `openapi.json` from them, the file is checked in, and CI fails when it differs. Clients in every language are generated from that file, TypeScript first, then Python and Go. A thin hand-written layer per language adds the child launch and stdin frame, `listActivity` follow polling, request-key building and the Unix-socket transport. The package exports no transport types [D19, D172]. The package shape follows the Azure TypeScript SDK guidelines, Temporal's client, Stripe's idempotency rules and the Codex SDK. The notes are in the project notes [D2]. The working npm name is `rui`, and the final name is set at publish [D127].

| Call | Route | Returns | Request key | Ledger |
| --- | --- | --- | --- | --- |
| `Rui.connect(options)` | Starts the child, writes the launch frame, then probes `/v1/host-info` | The `rui` client | None | D3, A-D3, D107, D112, D130 |
| `rui.sessions.create(spec, { idempotencyKey })` | `/v1/configure` | A Session handle `{ id }` | Required, `kind:driftId` | D7, D17, D128 |
| `rui.sessions.list()` | The existing session list route (today `/v1/list-sessions`, ARCHITECTURE.md:2183) | `{ id, label, state, parent }[]` | None (read) | D117, D128 |
| `rui.getSession(id)` | None. It does no I/O | A Session handle | None | D16 |
| `rui.models()` | `/v1/model-list` | `{ provider, id, known, effortLevels, contextWindow }[]` | None (read) | D117, D128 |
| `rui.close()` | None. It closes the child's stdin | Resolves when the child has exited | None | D117, D129 |
| `rui.on("exit", …)` | None | Fires with `{ code, signal, restarting }` | None | D117, D129 |
| `session.send(text, { idempotencyKey, env })` | `/v1/message` | `{ messageId }` | Required, `kind:driftId` | D8, D17, D121 |
| `session.listActivity({ after, follow?, kinds? })` | `/v1/activity-page` | An async iterator of feed entries | None (read) | D10, D11, A-D117, D168 |
| `session.readContent(entry)` | Not named | The entry's full text | None (read) | D117, D128, D134 |
| `session.status()` | `/v1/inspect-session` | Session state | None (read) | D12 |
| `session.update(fields, { idempotencyKey? })` | `/v1/configure` | Nothing, once the Host accepted it | Generated UUIDv4, optional override | D7, D113, D123, D128 |
| `session.stop({ idempotencyKey? })` | `/v1/control/session-stop` | Nothing, once the Host accepted it | Generated UUIDv4, optional override | D14, D123, D128 |
| `session.interrupt({ idempotencyKey? })` | `/v1/control/model-interruption` | Nothing, once the Host accepted it | Generated UUIDv4, optional override | D15, D123, D128, D167 |
| `session.decide(requestId, "allow" \| "deny", { idempotencyKey? })` | `/v1/control/permission-decision` | Nothing, once the Host accepted it | Generated UUIDv4, optional override | D15, D123, D128 |

The route names for `interrupt` and `decide` are today's routes (src/protocol.zig:361-362). D15 says both use calls the Host already has (ARCHITECTURE.md:210) [D15]. `readContent` is a Session method [D128]. Feed entries use the wire row fields in camelCase [D128]. The client also has ergonomic reads such as `status()` and `activity({ last })` [D12]. Rui's tables are private, and the client API is the contract [D12].

#### `Rui.connect(options)`

`Rui.connect` always starts Rui as a child process of the calling process [D107, A-D3]. The detached start-or-attach launch is replaced [A-D3]. It never attaches to an already-running Rui, and a `url` mode for a remote Rui is out of scope [D107]. There is no settings fingerprint on connect [D6]. Connect uses the existing `/v1/host-info` route and adds two Host pieces, the MySQL URL and the stdin handoff [D3, A-D3].

| Input | Meaning | Ledger |
| --- | --- | --- |
| `database` | The Store URL, for Drift `mysql://rui_user:…@host/drift_rui`. It holds the MySQL password. | D3, D83, D108 |
| `provider.baseUrl` | The provider's base URL. For Marlin it is `https://marlin.labs.dreamplug.net/v1`. | D3, D68, D69 |
| `provider.key` | The provider key. See "Key handling" in the Provider Seam. | D3, D70 |
| `tools` | Exactly the `mcpServers` list of the launch frame. Each entry is `{name, url, bearerToken, callTimeoutMs}`. See "MCP server config" in the Tools Seam. | D3, D120, D132 |
| `presets` | Named agent specs from Drift's code. See "Presets" in the Core. | D3, D22 |

| Result | Meaning | Ledger |
| --- | --- | --- |
| Resolves | The child read the launch frame and answered the `/v1/host-info` probe. | D112 |
| `RuiStartError {code, message}` | Rui refused to open. The codes are in "Errors". | D116, D136 |

Connect's `tools` option does not select built-in tools. A launched Host offers every built-in tool, which is Bash and the core tools, and each spec's required `tools` picks from them [D132, D104]. A launched Host supports only the OpenAI-key Adapter [D149].

#### Launch frame on stdin

`Rui.connect` writes one launch frame to the child's stdin [D108]. The frame is one length-prefixed JSON object [D112]. The prefix is a 4-byte big-endian length, followed by UTF-8 JSON [D130].

| Field | Content | Ledger |
| --- | --- | --- |
| `v` | The frame version. It is 1, and any other value is refused with `RuiStartError launch_frame_invalid`. | D112, D130 |
| `store` | The Store URL, with the MySQL password. | D108, D112 |
| `provider` | `{ kind: "openai_key", baseUrl, key }`. It replaces the bare `providerKey` and `RUI_OPENAI_BASE_URL` for launched Hosts. | D108, D112, D130 |
| `runtimeDir` | A private directory for the Host socket, scratch and diagnostics under MySQL. See "Runtime directory and the opaque Store id" in the Store Seam. | D112, D114, D131 |
| `mcpServers` | `[{name, url, bearerToken, callTimeoutMs}]`, exactly connect's `tools` option. | D112, D120, D132 |
| `presets` | The named agent specs. | D22, D112 |

The Store URL and the key never touch disk, argv or the environment [D108]. stdin carries the frame once and does not become a message queue [D70]. Review #9 was kept as it is [D70]. Today the provider key comes from one Rui-owned file (ARCHITECTURE.md:3608). The db-seam Host wiring PR (its PR 9) builds the frame, and the DB thread gets this interface [D108].

#### Readiness, lifetime, restart and shutdown

| Phase | Behaviour | Ledger |
| --- | --- | --- |
| Readiness | The client probes today's `/v1/host-info` route on the socket in `runtimeDir`. The Host reports the opaque Store id at readiness (see the Store Seam). | D112, D114 |
| Lifetime | Rui lives exactly as long as the Drift process. The stdin pipe stays open as the liveness signal, and Rui exits when it closes. A crashed Drift never leaves an orphan holding the Store. | D5, D108, A-D108/D110 |
| Shutdown | When stdin closes, Rui runs infrastructure shutdown bounded at 10 s, then exits. | D118 |
| `rui.close()` | Closes the child's stdin and waits for it to exit, bounded by the 10 s shutdown. | D129 |
| `exit` event | Fires on every child exit, including one the package restarts from, with `{ code, signal, restarting }`. | D129 |
| Crash of Rui alone | Drift owns starting and restarting Rui. The TS package restarts the child with capped backoff and retries in-flight calls by their keys once the Host is ready. The backoff starts at 0.5 s and doubles up to 30 s. State is in the database. | D5, D118, D129 |
| Store fenced | The Host exits with code `store_fenced`, and the package's restart starts cleanly on the restored data. See "The `commit_seq` fence". | D157 |
| Restart of Drift | A Drift restart, which includes every deploy, always restarts Rui with fresh settings. | D6, D110, A-D108/D110 |
| Child gone | Calls fail with `RuiUnavailableError`. | D116 |

Today's `/v1/host-info` reply reports the canonical Store selector, wire version, Active Capacity, slots in use, the Host start time, the Bash capability and each provider's route (ARCHITECTURE.md:3630). Today's infrastructure shutdown cancels provider streams and asks launched Bash to stop, and it does not wait for model work to finish (ARCHITECTURE.md:3715, :3717). Today a restarted Host runs ordinary recovery and may resume saved eligible work (ARCHITECTURE.md:3748).

#### `rui.sessions.create(spec, { idempotencyKey })`

`create` uses the existing `/v1/configure` route [D7]. Its first argument is an agent spec, or a preset name with fields that override the preset [D22]. The spec's fields and rules are in "Agent spec" in the Core. Rui copies the resolved spec into the Session at start, so editing a preset never changes a running agent [D22]. Today an accepted creation returns the allocated six-character Session ID, and a matching replay returns the same ID (ARCHITECTURE.md:173).

| Result | Meaning | Ledger |
| --- | --- | --- |
| A Session handle `{ id }` | The Session exists. | D7, D128 |
| `RuiRequestError` | Rejected. Codes include `provider_tool_missing`, `compact_at_too_large`, `mcp_server_unavailable` and `idempotency_key_conflict`, plus today's configuration rejections. | D17, D116, A-D116 |
| `RuiUnavailableError` | The child is gone. | D116 |

#### `rui.sessions.list()`

`rui.sessions.list()` returns `{ id, label, state, parent }[]` from the existing session list route [D117, D128]. Today `/v1/list-sessions` enumerates the Store's accepted, configured Sessions (ARCHITECTURE.md:2183). A parent's own transcript lists its workers, because `list_agents` is deleted [D98]. The call is in "Attached and standalone" under "Agents" [D163].

#### `rui.getSession(id)`

`getSession` returns a handle and does no I/O [D16]. It therefore cannot fail. Today an unknown Session ID is rejected as `unknown_session` by the first call that reaches the Host (src/protocol.zig:311).

#### `rui.models()`

`rui.models()` returns `{ provider, id, known, effortLevels, contextWindow }[]` from `/v1/model-list` [D117, D128]. Asking for the model list refreshes the catalog and the provider's live list [D79, D153]. The catalog and usable models are described in "Provider Seam and model catalog".

#### `rui.close()` and the `exit` event

`rui.close()` closes the child's stdin and waits for it to exit, bounded by the 10 s shutdown [D129, D118]. The `exit` event fires on every child exit with `{ code, signal, restarting }` [D129]. Once the child is gone, calls fail with `RuiUnavailableError` [D116].

#### `session.send(text, { idempotencyKey, env })`

`send` uses the existing `/v1/message` route [D8]. Batching of messages that arrive while the agent works is described in "Batching" in the Core [D8].

| Input | Meaning | Ledger |
| --- | --- | --- |
| `text` | The message. | D8 |
| `idempotencyKey` | Required, built as `msg:driftId`. | D8, D17 |
| `env` | The environment Bash runs in. It defaults to empty. See "Bash environment and RUI_STORE" in the Tools Seam. | D121, D148 |

| Result | Meaning | Ledger |
| --- | --- | --- |
| `{ messageId }` | A receipt only. There is no Turn handle, no `result()` and no held wait. | D8 |
| `RuiRequestError` | Rejected. Codes include `idempotency_key_conflict` and today's message rejections. | D17, D116 |
| `RuiUnavailableError` | The child is gone. | D116 |

#### `session.listActivity({ after, follow?, kinds? })`

Drift follows one feed, `session.listActivity`, in order [D9]. The feed has a `turn_ended` entry, so Drift never polls `status()` to learn that the agent is done [D9, A-D9]. Review #7 was adopted [D9]. `listActivity` uses the existing `/v1/activity-page` route [D10].

| Behaviour | Rule | Ledger |
| --- | --- | --- |
| Shape | An async iterator over `continuationToken` pages. Polling stays inside the client. | D10 |
| Cursor | `after` takes an opaque string that encodes `{position, ordinal}`. | D168 |
| Bounded read | `listActivity({ after })` ends at the current end of the feed. | A-D117 |
| Follow | `listActivity({ after, follow: true })` never ends. It polls with backoff from 250 ms to 2 s whether the Session is busy or idle, because an idle Session can be woken by a child's or another agent's message. Each poll is one cheap page read. | A-D117 |
| Filter | `kinds`, with the same names as `read_transcript`'s `kinds` and the wire. | D11, D115 |
| Fields | The wire row fields in camelCase. | D128 |
| Text | Entry text is `entry.text`. It is inline up to 16 KiB per entry. Longer text sets `truncated: true`, and the Session method `readContent(entry)` fetches the rest. | D117, D128, D134, D168 |
| Recall | Ctrl-P recall is a `kinds` read with page size 1. `/v1/person-message` is deleted. | D11 |

Today an activity row carries only a `{bytes, sha256}` reference to its text (src/protocol.zig:639-642), and the text comes from `/v1/activity-content` (ARCHITECTURE.md:3323). Today a page holds at most 16 rows (ARCHITECTURE.md:3285). The client's transcript read uses the existing `/v1/conversation-page` route plus a new word search, shared with `read_transcript` [D13].

##### Feed entry kinds

The wire, the TS client and `read_transcript` use one set of names [D115]. The kinds are today's rows, with `outcome` renamed to `turn_ended`, plus two new rows [D115].

| Kind | Today (src/protocol.zig:638) | What the entry is | Ledger |
| --- | --- | --- | --- |
| `admission` | Same | A Message admitted to the Session's queue, with its key, its Turn once applied, its state (`queued`, `applied` or `excluded`) and its sender. A null sender means a person or script (src/protocol.zig:649-650). | D115 |
| `user` | Same | A Message as a User entry in the conversation. | D115 |
| `assistant` | Same | Model text. The entry marked `final: true` is the Turn's answer, which is the last assistant message of the Turn. Other `assistant` entries are commentary. | D109, D115, D162 |
| `call` | Same | A tool call with its call note. See "rui_call_description" in the Tools Seam. | D62, D115 |
| `tool_result` | Same | A tool's result. | D115 |
| `hosted_call` | Same | A provider-run call, finished inside the model's reply. | D47, D115 |
| `turn_ended` | `outcome` | The Turn's ending. It carries `text` for `provider_refused` and `failed` only. It does not list message ids. The endings are in "Turn endings" in the Core. | D109, D115, A-D9, D168 |
| `stop` | Same | A Session stop, with its cutoff and its completion. | D115 |
| `sent` | Same | A Message this Session sent to another Session. | D115 |
| `send_failed` | Same | A Message the target Session refused. | D115 |
| `approval_requested` | New | A pending approval, carrying `sessionId` (the Session that asks) and `requestId`. Its Action id is the `requestId` for `decide`. A child's row appears in every ancestor's feed up to the root. | D115, D135 |
| `session_changed` | New | One entry per change-list entry. It also records "effort change refused" with the provider's text. See "Session change list" in the Core. | D115, D137, D138 |

A child's final answer and its other endings reach its parent as messages. "Agents" describes when they are delivered [D39, D122, D139].

#### `session.update(fields, { idempotencyKey? })`

`update` uses the existing `/v1/configure` route [D7]. It takes every spec field except `model`, `provider` and `workspace` [D113]. Every field it changes is one change-list entry with its own `session_changed` row [D138]. The change list and the effort check are in the Core, under "Session change list" and "Requests that keep the cache". Today omitted fields stay unchanged (ARCHITECTURE.md:191), and a different provider or model rejects the whole update (ARCHITECTURE.md:183).

| Result | Meaning | Ledger |
| --- | --- | --- |
| Resolves to nothing | The Host accepted the change. | D7, D128 |
| `RuiRequestError` | Rejected. Codes include `unsupported_reasoning_effort`, `provider_tool_missing`, `compact_at_too_large`, `mcp_server_unavailable`, `idempotency_key_conflict` and today's configuration rejections. | D116, D137, A-D116, D165, D166 |
| `RuiUnavailableError` | The child is gone. | D116 |

#### `session.stop({ idempotencyKey? })`

`stop` uses the existing `/v1/control/session-stop` route and is the only way to stop work [D14]. It is today's stop. It cancels the Session's current and queued work and its attached children's work, and the Session stays usable, so a later message starts new work (ARCHITECTURE.md:1703, :3745) [A-D14, D38]. Cancelling a wait never stops work [D14]. The cascade to children is in "Stop and context-full cascade" under "Agents".

Today the reply confirms that Rui saved the stop, not that the work finished (ARCHITECTURE.md:1709). The stop completes when the selected Turn ends, or at once with no active Turn (ARCHITECTURE.md:1710-1711). Input after the stop's cutoff is not selected (ARCHITECTURE.md:1706). The stopped Turn's `turn_ended` entry carries `stopped` [D109].

| Result | Meaning | Ledger |
| --- | --- | --- |
| Resolves to nothing | The Host accepted the stop. | D14, D128 |
| `RuiRequestError` | Rejected with today's stop rejections or `idempotency_key_conflict`. | D116 |
| `RuiUnavailableError` | The child is gone. | D116 |

#### `session.interrupt({ idempotencyKey? })`

`interrupt` is today's Model Interruption (ARCHITECTURE.md:1723) [D167]. It interrupts the Session's current model call, and the Session keeps going [D15, A-D14, D167]. If other messages are queued, the Turn continues with them [D167]. Otherwise the Turn ends, and its `turn_ended` entry carries `interrupted` [D109, D167]. It does not interrupt running tool calls, and `stop()` does [D167]. Today a Model Interruption names one exact unresolved model Operation (ARCHITECTURE.md:1725). The client finds that target model Operation from the Session's status [D167]. `/v1/inspect-session` reports the current Turn and Operation (src/protocol.zig:855), and the client reads `status()` from that route [D12]. Today a race with the Operation's end is rejected as `operation_resolved` or `target_mismatch` (src/protocol.zig:369-376).

| Result | Meaning | Ledger |
| --- | --- | --- |
| Resolves to nothing | The Host accepted the interruption. | D15, D128 |
| `RuiRequestError` | Rejected with today's interruption rejections or `idempotency_key_conflict`. | D116 |
| `RuiUnavailableError` | The child is gone. | D116 |

#### `session.decide(requestId, "allow" | "deny", { idempotencyKey? })`

`decide` answers an approval [D15]. `requestId` is the Action id on an `approval_requested` entry [D115]. `decide` works on any ancestor's handle, and Rui routes it to the child's Session [D135]. Approvals, and how they reach the root's feed, are in "Approvals in the parent feed" under "Agents". Today the Host's decision values are `allow_once` and `deny` (src/protocol.zig:305), and a permission decision targets a Session and an Action id together (src/protocol.zig:389-394).

| Result | Meaning | Ledger |
| --- | --- | --- |
| Resolves to nothing | The Host accepted the decision. | D15, D128 |
| `RuiRequestError` | Rejected with today's decision rejections or `idempotency_key_conflict`. | D116 |
| `RuiUnavailableError` | The child is gone. | D116 |

### Request keys

Request keys are required on every write [D17]. The core is unchanged, because keys are already required today (ARCHITECTURE.md:209) [D17].

| Call | Key | Ledger |
| --- | --- | --- |
| `sessions.create` | `kind:driftId`, such as `chat:42` | D7, D17 |
| `send` | `kind:driftId`, such as `msg:42` | D8, D17 |
| `update`, `stop`, `interrupt`, `decide` | A client-generated UUIDv4, with an optional `idempotencyKey` override | D123 |

A resend after a crash returns the original answer [D17]. A reused key with different inputs is rejected with `idempotency_key_conflict`, judged by Rui's semantic digest [D17]. Drift's `drift` and `drift_rui` databases sit on one MySQL server and restore together, so a key built from a Drift row id stays bound to the same Rui answer [D17]. Review #4, a UUIDv4 stored in Drift's row, was dropped [D17]. After a crash of Rui alone, the TS package retries in-flight calls by their keys [D118].

Today a key is any UTF-8 string of at most 128 bytes (ARCHITECTURE.md:220). All callers share one Store-wide key domain (ARCHITECTURE.md:215), and every new command needs a fresh key (ARCHITECTURE.md:226). Reads carry no key (ARCHITECTURE.md:212).

### Errors

Errors are faithful. They say what Rui can know [D33]. There is no `TurnFailedError` [A-D18]. Request-level failures are `RuiRequestError`, and Turn endings arrive as `turn_ended` entries, not errors [D109, A-D18].

| Type | When | Fields | Ledger |
| --- | --- | --- | --- |
| `RuiRequestError` | Rui rejected one request. | `code`, Rui's rejection enum, from one generated list | D18, D116, A-D18 |
| `RuiStartError` | Rui refused to open. | `code`, `message` | D116, D136 |
| `RuiUnavailableError` | The child process is gone. | None stated | D116 |

| `RuiStartError.code` | When | Ledger |
| --- | --- | --- |
| `launch_frame_invalid` | The launch frame is refused, for example because `v` is not 1. | D130, D136 |
| `store_locked` | The Store's lock is held. See "Runtime directory and the opaque Store id" in the Store Seam. | D136, D158 |
| `store_fenced` | The `commit_seq` fence fired. A running Host also exits with this code. | D136, D157 |
| `mysql_version`, `mariadb`, `read_only_replica`, `durability_<variable>`, `binlog_statement` | A MySQL refusal at open. See "Refusals at open" in the Store Seam. | D86, D136, D156 |
| `tool_name_collision` | A tool name collides at Host start. See "Name collisions" in the Tools Seam. | D136, D142 |

There is one `RuiStartError` code per refusal at open [D136].

| `RuiRequestError.code` | Raised by | Meaning | Ledger or source |
| --- | --- | --- | --- |
| `idempotency_key_conflict` | Every write | The key was used before with different inputs. | D17 |
| `provider_tool_missing` | `sessions.create`, `update` | The spec asks for a provider-run tool the provider lacks. | D47, D116, D166 |
| `compact_at_too_large` | `sessions.create`, `update` | `compactAt` is larger than the model's known context window. | D111, D116, D166 |
| `unsupported_reasoning_effort` | `sessions.create`, `update` | The model is known, and the catalog's effort levels do not include the requested effort. It is today's code (src/protocol.zig:315). It replaces `effort_change_refused` as a request error. | D137, D165 |
| `mcp_server_unavailable` | `sessions.create`, `update` | The spec names a tool of a server that has no tools. During a Turn the same name is a tool result to the model, not a request error. | A-D116, D147, D166 |
| Today's configuration rejections | `sessions.create`, `update` | `invalid_session_reference`, `unknown_session`, `unsupported_permission_mode`, `unsupported_provider`, `invalid_model`, `model_capability_unavailable`, `invalid_output_schema`, `invalid_compaction_trigger`, `invalid_output_reservation`, `invalid_label`, `incomplete_initial_configuration`, `invalid_workspace`, `workspace_is_immutable`, `provider_is_immutable`, `model_is_immutable`, `revision_exhausted` | src/protocol.zig:309-327 |
| Today's message rejections | `send` | The configuration list plus `invalid_sender_handle` | src/protocol.zig:328-347 |
| Today's environment refusals | `send` | `environment_required`, `environment_too_large`, `invalid_environment` (ARCHITECTURE.md:1605). Today the Host refuses a Message whose environment is missing, over 64 KiB or malformed. | ARCHITECTURE.md:1605 |
| Today's stop rejections | `stop` | `invalid_session_reference`, `unknown_session` | src/protocol.zig:368 |
| Today's interruption rejections | `interrupt` | `invalid_session_reference`, `invalid_target`, `unknown_session`, `unknown_operation`, `target_mismatch`, `operation_resolved` | src/protocol.zig:369-376 |
| Today's decision rejections | `decide` | `invalid_session_reference`, `invalid_target`, `unknown_session`, `unknown_action`, `target_mismatch`, `action_not_pending` | src/protocol.zig:377-384 |

`start_agent` raises no `RuiRequestError`. Every spec refusal inside `start_agent` is a tool error to the model [D140, D166].

A refused effort change at the provider is not an error to Drift. It is a `session_changed` row that records "effort change refused" with the provider's text [D137].

The model, not Drift, sees tool-level failures as tool results. A call to a removed tool returns "this tool was removed" [D54, D116]. A bad tool input gets an error tool result [D57]. An MCP JSON-RPC error or an `isError` result carries the server's own text [D144]. A call to an unavailable MCP server returns `mcp_server_unavailable` as a tool result [A-D116]. An MCP timeout is "may or may not have run", with "no reply within N s" added [D60]. Rui never reruns a tool call, and when an outcome is unknown the model is told and checks for itself [D32].

## Core

The core owns Session (with a first-class `parent`), Message, Turn, Operation, Attempt, Resolution, the never-repeat rules, compaction, the scheduler, and agent specs and presets [D23]. The core also runs four tools of its own as core commands, `start_agent`, `message_agent`, `read_transcript` and `find_tools` [D24]. The "Agents" section describes them.

Today the Host has a second owner, the Workflow Runtime (ARCHITECTURE.md:65). It is deleted from the contract, and it can return when a real user needs it [D126].

### Concepts

| Concept | Meaning | Reference |
| --- | --- | --- |
| Session | One reusable linear conversation with its Workspace and settings, addressed by a six-character id (ARCHITECTURE.md:105). An attached child's Session has `parent`. | [D23, D27] |
| Message | An immutable admission, ordered within its Session (ARCHITECTURE.md:355). It comes from `session.send`, from `message_agent`, or from a child's answer or ending. | [D8, D39, D41, D122] |
| Turn | The work from picking up waiting messages to a final answer or a named ending. At most one Turn is open per Session (ARCHITECTURE.md:107). | [D25] |
| Operation | One model call or one tool call. | [D25] |
| Attempt | One physical try of an Operation. | [D25] |
| Resolution | An Operation's saved, final result. | [D25] |

The word is Turn everywhere. The client never says "Run" [D26].

### Never repeat a tool call

Rui never reruns a tool call [D32]. When a call's outcome is unknown, Rui tells the model, and the model checks for itself [D32]. Retries are Rui's alone, and Rui's internal ids do not change [D32]. Rui sends no call id to MCP servers. It has no `idempotentHint` rerun and no list of trusted servers [D61]. Review #5 was adopted [D32, D61].

Timeouts are faithful. A call is "failed" only when Rui actually stopped the work [D60]. Review #3 was adopted [D60]. Errors say what Rui can know, and nothing needs a human except approvals [D33].

| Runner | Outcome unknown when | What the model gets |
| --- | --- | --- |
| Bash (`rui.shell`) | Rui lost custody of the process, for example in a crash. A timeout kills the process group, so a timed-out call is "failed" [D60]. | Today, an indeterminate tool result with no automatic replay (ARCHITECTURE.md:1489) [D32]. |
| MCP | The request was sent and the server sent no reply within the per-call time limit, or Rui crashed during the call. A server that cannot be reached before the request is sent gives "failed, not run" [D146]. | "May or may not have run", the same unknown outcome a crash produces, with "no reply within N s" added for a timeout [D60]. |
| Provider (for example `web_search`) | Does not apply. The call comes back finished inside the model's reply. | The provider's result. There is no never-repeat handling and no separate timeout or stop [D47]. |

The time limits themselves are in "Time limits" in the Tools Seam. A model call is not a tool call. Today an uncertain model Attempt may get a replacement Attempt with the same frozen request (ARCHITECTURE.md:1488). Those retries are Rui's alone [D32].

### Compaction and context full

There is no separate context limit. The compaction trigger is the one setting [D30]. Every agent spec states it as `compactAt`, a token count [D111]. Rui never fills `compactAt` from a model list [D111]. The catalog is used only to refuse a `compactAt` larger than the model's known context window [D111], and the refusal code is `compact_at_too_large` [D116]. The catalog keeps the context window for this check [A-D79]. For a model the catalog does not know, `compactAt` is not checked, and a context overflow ends the Turn `context_full` [D152].

Today the trigger defaults to 90% of the model's context window (src/product_defaults.zig:32, src/model_capability.zig:114), and a token-count override already exists (src/model_capability.zig:116). Today an unlisted model is assumed to have a 128,000-token window (ARCHITECTURE.md:651, src/product_defaults.zig:37). `compactAt` replaces the percentage trigger and the catalog default effort (#841, #845) [D111].

When compaction cannot shrink the conversation enough, the Turn ends with the `context_full` ending, visible in `status()` [D30, D115]. Today this ending is `ResourceExceeded` (src/store/domain/turn.zig:39, ARCHITECTURE.md:656). "Context full" on a parent also stops its attached children [D38].

After "context full", the caller starts a new Session with a brief [D31]. The brief points at the old Session in plain text, for example "you're continuing session X; read it with read_transcript" [D31]. No Session has a `continues` field until something reads one [D31].

### Turn endings

A Turn is the work from picking up waiting messages to a final answer or a named ending [D25]. A Turn's answer is the `assistant` entry marked `final: true`, which is the last assistant message of the Turn [D109, D162]. Other `assistant` entries are commentary [D162]. The feed then gets one `turn_ended` entry that carries the ending [D109, A-D9]. There is no `TurnFailedError` and no `result()` [D109, A-D18]. The entry does not list message ids, because the conversation is linear [D109].

| Ending | When | Closest outcome today (src/store/domain/turn.zig:21) | Reference |
| --- | --- | --- | --- |
| `done` | The model gave its final answer. | `completed` | [D109, D115] |
| `context_full` | Compaction could not shrink the conversation enough, or the context overflowed on a model the catalog does not know. | `resource_exceeded` | [D30, D109, D115, D152] |
| `provider_refused` | Any provider-side refusal during the Turn, including Marlin's `403 "Your budget has been exhausted"` and a refused `web_search`. The entry carries the provider's text. | `failed` with the provider's report | [D68, D71, D109, D115, D150] |
| `provider_unavailable` | Retries are exhausted. | `retry_exhausted` | [D115] |
| `stopped` | `session.stop()` cancelled the Turn, or the parent's stop or "context full" stopped this child. | `cancelled` | [D38, D109, D115, A-D14] |
| `interrupted` | `session.interrupt()` interrupted the model call, and no other message was queued. | `cancelled` | [D109, D115, A-D14, D167] |
| `failed` | A Rui-side error. The entry carries its text. | `failed` | [D115, D150] |

`failed` is for Rui-side errors, and every provider-side refusal is `provider_refused` [D150]. Today's outcomes are `completed`, `cancelled`, `retry_exhausted`, `resource_exceeded` and `failed` with a code (src/store/domain/turn.zig:21). The ending set changes the Store format [D115], and that change rides the one format bump [D119].

### Scheduler

Rui adds no priority, no line-jumping and no per-kind caps. There are no priority classes [D34]. Rui allows 100 executions by default [D34]. Drift's 9-turn cap protected its own 10-connection MySQL pool, which Rui's Turns do not hold [D34]. Databricks keeps its 3-statement queue inside Drift's `run_sql` tool [D34]. The scheduler changes only after measured waits [D34].

Today 100 is the default Active Capacity, shared by model, Bash and Edit executions and their cleanup (ARCHITECTURE.md:3842). Session work follows one fixed order of four kinds, and the kind that wins an admission moves to the back (ARCHITECTURE.md:3784, :3786). No cross-Session winner order is public (ARCHITECTURE.md:3769). Parallel tool calls within one model reply are in "Parallel calls" in the Tools Seam [D56, D106].

### Batching

`session.send` returns a receipt `{ messageId }` and nothing else [D8]. Messages that arrive while the agent works are batched into its next Turn, as today [D8].

Today, at each input boundary, the core takes every eligible pending message up to the admission cutoff and binds them to the Turn in one transaction (ARCHITECTURE.md:361). A message admitted during active work waits for the next input boundary (ARCHITECTURE.md:359). One Turn can therefore answer several messages. Its `turn_ended` entry lists no message ids, because the conversation is linear [D109].

### Agent spec

One agent spec value is used by Session start, `start_agent` and presets [D28, A-D28]. The spec is D113, not "today's settings and nothing new" [A-D28]. Its fields are listed below [D113]. Core tools are named in `tools` like any other tool [D113]. `session.update` takes every field except `model`, `provider` and `workspace` [D113]. The model is fixed for the Session's life [D29]. Instructions, effort and the other settings change mid-Session with the provider cache kept [D29, D53].

| Field | Required | `update` can change | Meaning | Reference |
| --- | --- | --- | --- | --- |
| `model` | Yes | No | One model per Session. | [D29, D113] |
| `provider` | No. It defaults to the Host's single provider and may be left out. | No | The Provider Adapter the Session uses. A child inherits its parent's. | [D113, D122, D133] |
| `workspace` | Only when `tools` includes `bash`. It is unused otherwise. | No | The working directory for relative tool paths, not a sandbox (ARCHITECTURE.md:106). A child inherits its parent's. | [D113, D122, D133] |
| `instructions` | No | Yes | A change is rendered as a later `developer` message. Drift reads its own doctrine files for this text. | [D28, D29, D113] |
| `effort` | Yes | Yes | Reasoning effort. Rui never fills it from a model list. `sessions.create` and `update` check it against the catalog's effort levels when the model is known, with today's code `unsupported_reasoning_effort`. | [D111, D113, D137, D165] |
| `compactAt` | Yes | Yes | The compaction trigger, in tokens. | [D111, D113] |
| `tools` | Yes | Yes | The tools the Session may use. `[]` means none. There is no Host default and no default preset. The Session can only narrow the Host's set, by name. A launched Host offers every built-in tool and the MCP servers' tools. | [D50, D104, D113, D132] |
| `loadedTools` | No | Yes | The tools loaded from the start. The rest of `tools` wait behind `find_tools`. Left out, it is every tool in `tools`, and only a smaller `loadedTools` uses `find_tools` [D160]. | [D52, D113, D160] |
| `permissionMode` | Yes | Yes | `ask` or `bypass`, as today (ARCHITECTURE.md:422). MCP calls use the same mode as Bash. | [D58, D113] |
| `outputSchema` | No | Yes | A structured final answer. Today, absence selects text answers (ARCHITECTURE.md:423). | [D113] |
| `label` | No | Yes | Display text only. | [D113] |

`tools` is required in every agent spec, preset or not, in `sessions.create`, `start_agent` and presets [D104]. D21 is folded into D104 [D21]. Review #11 was adopted [D21]. Every agent spec states `effort` and `compactAt` [D111]. Today a creating configuration requires a provider, a model and a Workspace together (ARCHITECTURE.md:178). That contract text changes [D159].

A spec that names a provider-run tool the provider lacks is refused at Session start [D47]. On `sessions.create` and `update` the refusal is `provider_tool_missing` [D116, D166]. A preset lists `web_search` only if it wants it [A-D74]. A spec that names a tool of an MCP server that has no tools is refused with `mcp_server_unavailable` [D147, A-D116]. Inside `start_agent` every spec refusal is a tool error to the model [D140, D166].

### Presets

Presets are named agent specs in Drift's code, for example one per Drift ticket type [D22]. Drift passes them to Rui at connect [D22], in the launch frame's `presets` field [D112]. Rui does not store them in the database [D22]. A Drift restart restarts Rui with fresh settings [D6].

A caller can name a preset and override fields [D22], for example `rui.sessions.create({ preset, instructions }, { idempotencyKey })` [D7]. Every preset states `tools` [D104]. There is no default preset [D104]. Rui copies the resolved spec into the Session at start, so editing a preset never changes a running agent [D22].

### Session change list

Nothing costs a cache miss [D53]. Each Session keeps one append-only list of changes [D53]. Review #2 was adopted [D53]. Rui builds every request from the original top plus those entries [D53]. Rui works out the allowed tool set and the current effort from the same list [D53]. Each entry gets one `session_changed` row in the feed [D115, D138].

D53 names four kinds of entry, which are tool added, tool removed, tool reworded and effort changed. They are examples, not the full list [D138]. Entries come from these sources:

- Every field that `session.update` changes is one entry [D138, D113].
- Every tool that `find_tools` loads is one entry. The tool joins from the next request through `additional_tools` [D138, D52].
- Rui fetches each MCP server's tool list at Host start. Before a Session's next model call, Rui compares that list with the Session's saved copies and appends any added, removed or reworded tool [D110, A-D51]. "Fetch at Host start, compare per Session" in the Tools Seam has the details.

A removed tool keeps its description in the request [D54]. The Tools Seam owns tool records, rewording and removed tools. The change list and the tool records ride one Store format bump, owned by the tool-records PR [D119].

### Requests that keep the cache

A cache-safe change needs a new codec version [D75]. The codec builds each request as follows:

1. The top-level `reasoning.effort` is fixed at the spec's `effort` [D75, A-D75, D111].
2. The top-level `tools` is empty, and the first tool declaration sits at the head of the history span [D75].
3. Each `configuration_update` or `additional_tools` item for Operation k sits at k's admission position. In request k that is after `history_end`. In later requests it is inside the sealed span [D75].
4. Rui works out every placement from saved Operation facts [D75].
5. The codec carry grows to {comma, current effort, declared tools}, where "declared tools" means the Session's tool records [D75, A-D75, D48]. The carry resets at a compaction anchor [D75].
6. The history view gets an "Operation boundary" element [D75].

Today the carry of `openai-responses/1` is one byte, whether the next input item takes a comma (ARCHITECTURE.md:834). Today's prefix seal covers the history span and not the settings and instructions before it (ARCHITECTURE.md:868).

The items need no Store format change [D75]. The new codec needs a new name, for example `openai-responses/2`, or existing Sessions fail with `encoding_drift` [D75]. The item shapes are [D76]:

```
{"type":"additional_tools","role":"developer","tools":[…]}
{"type":"configuration_update","reasoning":{"effort":…}}
```

Rui sends `additional_tools` on every model, with no per-model list, and a provider refusal is a faithful error [A-D76]. Rui uses plain function definitions, not the Lite `functions` namespace of Codex [D76].

Effort changes use OpenAI's `configuration_update` item on every model, with no model list [D77]. `update` first checks `effort` against the catalog's effort levels when the model is known, and it refuses synchronously with today's code `unsupported_reasoning_effort` (src/protocol.zig:315) [D137, D165]. `sessions.create` uses the same code [D165]. Today configuration checks effort the same way (ARCHITECTURE.md:438). If the provider later refuses the `configuration_update` item, the next model call is retried without it, and the effort stays as before [D137, D77]. A `session_changed` row then records "effort change refused" with the provider's text [D137]. This replaces `effort_change_refused` as a request error [D137]. Any other provider-side refusal during a Turn ends the Turn `provider_refused` [D150].

Instruction changes are rendered as later `developer` messages [D29]. Today every instruction update appends a System Instruction entry to the Conversation (ARCHITECTURE.md:473).

The cache proof test extends src/model_adapter.zig:3948, :3976 and :4012 [D76]. Live checks against OpenAI are not yet specified (a proposal). See "Not yet specified" [D103].

## Agents

`start_agent(task, spec | preset, attached)` starts a worker [D37]. One switch, `attached`, covers both the worker's lifetime and its reply address [D40]. There are no separate `reply_to` and `stops_with` fields, and review #8 was kept as it is [D40].

### Attached and standalone

| | Attached child | Standalone agent |
| --- | --- | --- |
| Parent link | Its Session has `parent`. [D27, D38] | No parent. [D38] |
| Lifetime | Its work stops when its parent is stopped or hits "context full". [D38, A-D14] | Its own. [D38] |
| Final answer | Delivered to the parent as a message, which wakes the parent. [D39] | Nothing comes back automatically. [D38] |
| Other endings | Delivered to the parent as a message, except an ending caused by the parent's stop or "context full". [D122, D139] | Nothing comes back automatically. [D38] |
| Replies to `message_agent` | Arrive automatically. [D41] | Arrive only when the agent chooses to send one. [D41] |

The parent link is a core concept [D27]. It replaces "no ... parent-child ownership" at ARCHITECTURE.md:568 [D27]. Keeping the link in a tool-owned table was rejected, because Tools would reach into the Store and a core stop would call back into a tool [D27]. The Sessions `parent` column lands with whoever builds it, after the db thread's PR 5e-3, through schema.zig and typed rsql [D89]. It rides the one Store format bump [D119].

`list_agents` is deleted by the deletion test. A parent lists its workers with `read_transcript(self, kinds: ["call"], query: "start_agent")`, built only from D115's kind names and the existing word search [D98, D163].

### Stop and context-full cascade

`session.stop()` cancels the Session's current and queued work and its attached children's work. The Sessions stay usable, so a later message starts new work [A-D14, D38]. "Context full" on the parent stops the attached children too [D38]. Each stopped child is itself a Session, so the same rule stops its own attached children [D38]. `session.interrupt()` interrupts the current model call only, and it does not interrupt running tool calls [A-D14, D167]. Cancelling a wait never stops work [D14].

A child ended by its parent's stop or "context full" delivers nothing to the parent, because delivery would wake a parent that was just stopped [D139].

Today a stop is acknowledged once Rui saves the stop intent, and it completes when the selected Turn ends (ARCHITECTURE.md:1709).

### Child answers and endings

A child's final answer reaches the parent as an ordinary message [D39]. It takes the same path as a message from any other agent, through `message_agent` and peer admission, and it wakes the parent [D39]. Rui delivers it. The parent does not read it on demand [D39]. Every other child ending (`done`, `failed`, `provider_refused` and so on) is delivered as a message too [D122, D139]. The one exception is an ending caused by the parent's stop or "context full" [D139].

Today a peer message is rendered with the sender's bare id as a separate leading input part, with the note that the answer is not delivered to the sender (ARCHITECTURE.md:564). Today's peer context text shrinks to pointing at the agent tools [D43].

### Inheritance and narrowing

A child inherits its parent's workspace and provider [D122]. It also inherits its parent's saved Bash environment [D169]. A child may only narrow its parent's tools and permission mode [D122]. The Host decides which built-in tools and MCP servers exist, and a Session can only narrow them by name [D50]. There is no depth or fan-out limit until one is measured [D122].

`start_agent` with a spec wider than the parent's, in tools or permission mode, is refused as a tool error that names the field [D140]. A spec that names a provider or a workspace is refused the same way [D140]. Every other spec refusal inside `start_agent` is a tool error to the model too, including `provider_tool_missing`, `compact_at_too_large`, `mcp_server_unavailable` and the effort check [D166]. Nothing is silently cut down [D140].

### Approvals in the parent feed

Nothing needs a human except approvals [D33]. MCP calls use the same `ask` or `bypass` permission as Bash [D58]. Today `ask` creates one saved Permission Request (ARCHITECTURE.md:1162).

A child's approval requests appear in its parent's feed [D122]. Each one is an `approval_requested` row, whose Action id is the `requestId` that `session.decide` takes [D115]. The row appears in every ancestor's feed up to the root, so a grandchild's request reaches the root's feed [D135]. The row carries `sessionId` (the child) and `requestId` [D135]. `session.decide(requestId, "allow" | "deny")` answers it [D15]. `decide` works on any ancestor's handle, and Rui routes it to the child's Session [D135]. Today these values map to `allow_once` and `deny` (src/protocol.zig:305).

### Core-owned tools

`start_agent`, `message_agent`, `read_transcript` and `find_tools` are core-owned tools that run as core commands [D24]. The runner is derived from the tool, not stored [D46]. A Session names these tools in `tools` like any other tool [D113]. A launched Host always offers them [D132]. They take no `rui_call_description` argument. The core writes their call note in base-verb form [D105]. An MCP tool whose name collides with a core tool fails Host start [D120, D142].

| Tool | Inputs | Output | Reference |
| --- | --- | --- | --- |
| `start_agent` | `task`, `spec` or `preset`, `attached` | The worker's Session id, at once. A refused spec is a tool error naming the field. | [D37, D140, D166] |
| `message_agent` | `id`, `text` | Returns once the Message is delivered. Replies arrive later as Messages. | [D41] |
| `read_transcript` | `id`, `query?`, `kinds?`, `before?`, `limit?`, `full?` | An outline, snippets or one entry. See below. | [D42] |
| `find_tools` | Words to match | Matching tools, which join from the next request. | [D52] |

The core tools' exact JSON schemas and result text are written in the build PR that adds each tool [D141]. That covers `find_tools`'s argument name and result format, how `start_agent` spells a spec versus a preset with overrides, whether `attached` has a default, and `read_transcript`'s default `limit` and chunk size [D141]. They are prompt text and get no tests [D141, D94].

#### start_agent

`start_agent` is async [D37]. It creates the worker's Session, admits `task` as its first Message, and returns the worker's id at once [D37]. It is one saved step keyed by the call id, like today's idempotent `session start`, so a resend never creates a second worker [D37]. Today a committed request keeps its original answer, and a retry recovers that answer (ARCHITECTURE.md:210). No call is held open while the worker runs [D37]. The spec or preset follows the agent spec rules above [D28, D113], and `tools` is required [D104].

#### message_agent

`message_agent(id, text)` delivers a Message and returns [D41]. The agent tools are the primary way agents talk to each other [D43]. `rui session send` stays for people and scripts [D43]. "Agent identity and peer composition" in ARCHITECTURE.md changes [D43].

#### read_transcript

`read_transcript` reads any Session in the Store, with no extra access rule [D42].

| Input | Effect | Reference |
| --- | --- | --- |
| (none) | An outline, one line per entry, with position, author or tool, call note and size. | [D42] |
| `query` | Plain word search with snippets. The client's transcript read shares this search. | [D13, D42] |
| `kinds` | Filters entries by kind. It takes only the feed kind names, one set across the wire, TS and `read_transcript`. Calls to a named tool are `kinds: ["call"]` with that name as `query`. | [D11, D42, D115, D163] |
| `before`, `limit` | Page newest first. | [D42] |
| `full` | Opens one entry, chunked if large. | [D42] |

Search by meaning is deferred [D102].

#### find_tools

A Session lists which tools are loaded from the start, in `loadedTools`. The rest of its `tools` wait behind `find_tools` [D52, D113]. Left out, `loadedTools` is every tool in `tools`, and only a smaller `loadedTools` uses `find_tools` [D160]. `find_tools` matches words against tool names and descriptions [D52]. A found tool joins from the next request through `additional_tools` [D52], and each load is one change-list entry with its own `session_changed` row [D138]. Drift's own `find_tools` goes away [D52].

## Tools Seam

The Tools Seam has two Adapters, `rui.shell` and MCP [D35, D44]. `rui.shell` is Rui's Bash. Bash keeps its process custody and capture machinery inside `rui.shell` [D44]. "Where tools run" belongs to this Seam, and Bash is one built-in tool [D35]. Drift exposes its tools as an MCP server, and Rui is an MCP client [D45].

Today V1 excludes dynamic tools and MCP (ARCHITECTURE.md:4195), and that contract line changes [D124].

### Adapters

| Adapter | What it runs | Reference |
| --- | --- | --- |
| `rui.shell` | Bash, with Rui's process custody and output capture. | [D35, D44] |
| MCP | Tools on MCP servers that the Host names, such as Drift's. | [D35, D45, D120] |

Rui's MCP client targets MCP 2026-07-28, which is stateless [D64]. It sends no `initialize`, keeps no `Mcp-Session-Id` and opens no resumable GET stream [D64]. Each request is one POST with these headers [D64]:

- `Accept: application/json, text/event-stream`
- `MCP-Protocol-Version`
- `Mcp-Method`
- `Mcp-Name`
- a static `Authorization: Bearer`

The client puts `protocolVersion`, `clientCapabilities` and `clientInfo` in `_meta` [D64]. It parses plain JSON and SSE replies, and it ignores progress [D65]. It pages `tools/list` by `nextCursor` [D65]. It handles the `tools/call` result (`content`, `structuredContent`, `isError`) and JSON-RPC errors [D65]. It cancels a call by closing the call's stream [D65]. The MCP features it skips for now are listed under "Out of scope" [D101].

Rui needs a small HTTP/1.1 client on the existing Reactor, with no new thread [D66, D94]. Today Rui speaks only HTTP/2 (src/h2/h2.zig), and loopback `http://` uses h2c with no HTTP/1.1 route (ARCHITECTURE.md:798). MCP servers are reached over plain HTTP on loopback only [D120].

Drift serves its MCP endpoint with `@modelcontextprotocol/server` 2.4.0 `createMcpHandler`, mounted as a Next.js `POST` route [D67]. That choice is inferred from the API and not tested [D67].

### Tool records

Every tool has one record with its name, description, input schema and owning server [D48]. Rui saves each record once by content and references it [D48]. The records replace today's `tools_mask` byte and its fixed Bash and web-search bits (src/tools.zig:243, :247) [D48]. Today's Tool Catalog holds only `bash` and `web_search` (ARCHITECTURE.md:1140).

Each model request saves exactly which tool records it offered [D49]. A call to any other tool gets the existing rejected-call result and never runs [D49]. The Host decides which built-in tools and MCP servers exist, and a Session can only narrow them by name [D50]. A launched Host offers every built-in tool, which is Bash and the core tools, plus the tools of its `mcpServers` [D132].

The tool records, the per-request tool lists and the saved tool copies ride one Store format bump, owned by the tool-records PR [D119].

### Who runs a tool

Who runs a tool is derived from the tool, not stored [D46]. Review #10 is derived, not stored [D46].

| Runner | Tools | Reference |
| --- | --- | --- |
| Rui | Bash (`rui.shell`) and MCP tools. | [D46] |
| Core | `start_agent`, `message_agent`, `read_transcript` and `find_tools`, run as core commands. | [D24, D46] |
| Provider | Provider-run tools such as `web_search`. | [D46, D47] |

### MCP server config

Connect's `tools` option is exactly the launch frame's `mcpServers` list [D132]. The TS package adds no server of its own, so Drift names its own MCP server in that list [D132]. Each entry has these fields [D120]:

| Field | Meaning | Reference |
| --- | --- | --- |
| `name` | The server's name. | [D120] |
| `url` | The server's endpoint. Plain HTTP on loopback only. | [D120] |
| `bearerToken` | The static token Rui sends as `Authorization: Bearer`. | [D64, D120] |
| `callTimeoutMs` | The server's per-call time limit. The default is 10 minutes. | [D59, D120, D145] |

The launch frame keeps the bearer token off disk, argv and the environment, as it does for the Store URL and the provider key [D108, D112].

### Fetch at Host start, compare per Session

Drift's MCP server ships inside Drift, and Rui restarts with every Drift deploy [D110, A-D108/D110, D5]. Rui fetches each MCP server's tool list at Host start [D110]. Before a Session's next model call, Rui compares that list with the Session's saved copies [D110]. Rui appends any added, removed or reworded tool to the Session's change list [D110, D53]. The Session-start fetch and the "told to reload" trigger of D51 are replaced [A-D51].

Rui saves the exact tool text it sent [D55]. When a server rewords a tool, the top of the request stays as saved, and Rui appends the new version further down by the same route as an added tool [D55]. Running Sessions see the new version, the provider cache holds, and there is no `encoding_drift` stop [D55]. The change list itself is in "Session change list" in the Core [D53, D138]. Tool loading through `find_tools` is in "find_tools" under "Agents" [D52].

### Name collisions

Tool names stay as the server gives them [D120]. Rui does not prefix them with the server name, because OpenAI function names allow no dots [D120]. That changes the ledger check's `server.tool` [D120].

A tool-name collision fails Host start with `RuiStartError tool_name_collision`, naming both sources [D142, D136]. A collision is any of these [D142, D120]:

- a tool name that two servers share
- a server tool named `bash` or named like a core tool
- an MCP tool schema with a property named `rui_call_description`

### rui_call_description

Rui adds `rui_call_description` to the input schema of MCP tools only [D105]. It is a required string property of at most 200 bytes [D143]. Rui keeps the value for the conversation line and saves it with the call [D62]. If a model leaves it out anyway, the line shows the tool name and arguments [D143]. An MCP server receives exactly the fields its own input schema lists, so tools never see `rui_call_description` [D62, D105]. The core never interprets tool arguments for display [D62]. Callers read calls and their notes through the client [D62]. Review #6 was rejected, because the line is very important [D62].

| Tool | Where its call note comes from | Reference |
| --- | --- | --- |
| MCP tools | The model fills `rui_call_description`. | [D62, D105, D143] |
| Bash | The model fills Bash's own `description` argument (src/tools.zig:237). | [D105] |
| Core tools | The core writes the note, in base-verb form. | [D105] |
| Provider-run tools | The codec writes the note, in base-verb form. | [D105] |

Today Rui saves a call's description bounded to 100 UTF-8 bytes at admission (ARCHITECTURE.md:3253, src/protocol.zig:29). Today Rui writes a web search's line from the provider's action, for example `Search "query"` (ARCHITECTURE.md:3257).

Progress is Session activity plus the short description on each tool call. There is no separate progress feed [D63].

### Validation and error results

There is no strict mode [D57]. Rui sends tools without `strict` [D57]. Each tool checks its own input, and a bad call gets an error tool result [D57]. Today every function tool goes out with `"strict":true` (src/codecs/responses.zig:164). The change lands as a follow-up PR from the same build thread as the parallel-calls fix (src/codecs/responses.zig) [D57].

The MCP client handles a `tools/call` result with `isError` and a JSON-RPC error [D65]. Either one becomes a tool result to the model that carries the server's own text [D144]. Output-schema validation is skipped [D101].

### Parallel calls

All tool calls in one model reply run at once, for every model [D56]. There is no model list and no model favourites [D56]. On `origin/main` this merged as #868 (`eadbfa9e`). Parallel calls are always on, and there is no Session or preset switch to turn them off [D106]. There is no per-tool "don't run alongside" flag until a tool needs it [D56]. Today only `gpt-5.5` gets `parallel_tool_calls: true` (src/codecs/responses.zig:21).

### Time limits

Each MCP server has a per-call time limit, 10 minutes by default [D59]. That default applies to MCP calls only. Bash keeps its 5-minute Host default [D145]. Today Bash's Host default timeout is 5 minutes (src/server_host.zig:22), and `timeout_ms: null` selects it (ARCHITECTURE.md:1593). Today a `timed_out` result reports the effective budget and the output excerpt (ARCHITECTURE.md:1595).

| Tool | On timeout | Result | Reference |
| --- | --- | --- | --- |
| Bash | Rui kills the process group. | "Failed". | [D60] |
| MCP | Rui got no reply within the limit. | "May or may not have run", with "no reply within N s" added. | [D60] |
| Provider-run | No separate timeout or stop. | The call comes back finished inside the model's reply. | [D47] |

The never-repeat rule that governs these results is in "Never repeat a tool call" in the Core [D32]. MCP calls use the same `ask` or `bypass` permission as Bash [D58].

### Removed tools

A removed tool keeps its description in the request [D54]. A call to it gets the tool result "this tool was removed", and the model is told [D54, D116]. A tool leaves a Session through the change list, either by `session.update` or by the Host-start comparison [D53, D110, D138].

### Unreachable servers

| Case | Result | Reference |
| --- | --- | --- |
| Unreachable at Host start, with saved tool copies | The server keeps its last saved tool copies. | [D120] |
| Unreachable at Host start, with no saved tool copies | The server contributes no tools. A spec naming its tools is refused with `mcp_server_unavailable`. | [D147] |
| A call to an unavailable server | The model gets `mcp_server_unavailable` as a tool result. | [D120, A-D116] |
| Cannot be reached before the request is sent | The call is "failed, not run". | [D146] |
| Fails after the request was sent | The call is "outcome unknown". | [D146] |

`mcp_server_unavailable` is a `RuiRequestError` only when `sessions.create` or `update` names a tool of a server that has no tools [A-D116, D147, D166]. Inside `start_agent` it is a tool error to the model [D166]. The error tables are in "Errors" under "How Drift uses Rui".

### Bash environment and RUI_STORE

The TS client sends an explicit `env` option on `send`, and it defaults to empty [D121]. Drift's process environment never reaches Bash [D121]. With the default empty `env`, Bash gets today's no-saved-environment treatment, which is the OS default `PATH` and the Host's `HOME` (ARCHITECTURE.md:1622) [D148]. A child Session started by `start_agent` inherits its parent's saved Bash environment, as it inherits the workspace [D122, D169]. Messages delivered by `message_agent` or by a child's ending do not change the receiver's environment [D169]. `RUI_STORE` in Bash is the opaque Store id that the Host reports at readiness, never the Store URL [D114].

Today every `/v1/message` exchange carries the sending process's environment (ARCHITECTURE.md:1602), and Bash runs in the environment of the client that last brought the Session work (ARCHITECTURE.md:1601). Today the Host sets `RUI_ADDRESS`, `RUI_STORE` and `RUI_SENDER_HANDLE` in Bash's environment (src/environment.zig:137-138, ARCHITECTURE.md:1619), and `RUI_STORE` is the canonical Store selector (ARCHITECTURE.md:535). Under MySQL that selector would be the URL with its password, which D108 forbids in the environment [D108, D114].

## Provider Seam and model catalog

The Provider Seam has two Adapters [D35]:

| Adapter | Today | Reference |
| --- | --- | --- |
| ChatGPT sign-in | Provider `codex`. `rui auth login codex` runs a device-code flow and saves an owner-only `~/.config/rui/codex.json` (ARCHITECTURE.md:972). Requests go to `POST /backend-api/codex/responses` (ARCHITECTURE.md:879). | [D35] |
| OpenAI key, with an optional base URL | Provider `openai`. Rui sends the key as `authorization: Bearer` to `https://api.openai.com/v1/responses`, or to `BASE/responses` when `RUI_OPENAI_BASE_URL` names an `https://` base URL (ARCHITECTURE.md:981, src/providers.zig:20). | [D35, D69] |

Both Adapters speak the same Responses codec today (ARCHITECTURE.md:982).

A launched Host, started through connect, supports only the OpenAI-key Adapter [D149]. ChatGPT sign-in stays the CLI and TUI path, with its file credential [D149].

### Marlin is a gateway

Marlin needs no new provider code [D69]. It is the existing OpenAI-key Adapter, with its Responses codec and a custom base URL [D69]. The catalog treats Marlin as an OpenAI-compatible base URL and key, not as its own provider [D69]. Marlin is a gateway in front of OpenAI and other labs [D103].

Rui takes these Marlin facts as inputs [D68]:

| Fact | Value | Reference |
| --- | --- | --- |
| Key | A static `sk-ml-…` key, sent as `Authorization: Bearer`, with no expiry or refresh. | [D68] |
| Base URL | `https://marlin.labs.dreamplug.net/v1`, with `POST /v1/responses`. | [D68] |
| `additional_tools` | Accepted (stage probe, 23 Oct). | [D68] |
| `configuration_update` | Never sent by Drift, so untested. | [D68] |
| Refusals | No 429s in four weeks. The only refusal is `403 "Your budget has been exhausted"`. | [D68] |

The base URL reaches the Host in the launch frame's `provider` field, `{ kind: "openai_key", baseUrl, key }` [D130]. For launched Hosts that field replaces `RUI_OPENAI_BASE_URL` [D130].

### Key handling

The key comes through the client API, not a file [D70]. Drift passes it in `Rui.connect({ provider: { baseUrl, key } })` [D3]. The TS package writes it once to the Rui child's stdin at launch, in the launch frame's `provider` field [D70, D108, D130]. Rui keeps the key in memory only, never on disk, in argv or in the environment [D70, D108]. Marlin keys are static, so there is no refresh [D70]. After the frame, the open stdin pipe is only the liveness signal [D108, D5].

ARCHITECTURE.md's contract changes so that the provider key may arrive in memory at startup, not only from the key file [D95]. Today `--provider openai` reads the key file once at startup (ARCHITECTURE.md:981), and a 401 on the key is final as `provider_api_key_rejected`, with no refresh or resend (ARCHITECTURE.md:984).

There is one key and no fallback list [D71]. Drift removes its backup key, `MARLIN_API_KEY_FALLBACK` [D71]. There is no per-provider in-flight limit [D72]. Rui does not record which model actually answered, until something reads it [D73].

### Provider-run tools

Provider-run tools, such as web search, are first-class tools, and Drift writes one tool list [D47]. The Provider Adapter lists the tools it offers [D47]. Both OpenAI Adapters list `web_search` as a provider-run tool [D150]. Session start refuses a spec that asks for a provider-run tool the provider lacks [D47], with `provider_tool_missing` [D116]. A provider-run call comes back finished inside the model's reply [D47]. It gets no never-repeat handling and no separate timeout or stop [D47].

There is no Marlin-specific switch for web search [A-D74]. A preset lists `web_search` only if it wants it [A-D74]. If the provider refuses it, that is a faithful error [A-D74, D47]. A refused `web_search` during a Turn ends the Turn `provider_refused` with the provider's text [D150]. Drift can instead expose its own search tool on its MCP server [D74].

Today `web_search` is a provider-hosted tool and not a Tool Call. Rui creates no Action for it and replays its item in later requests (ARCHITECTURE.md:941, :3258). The contract line that calls it "not a Tool Call" changes [D124].

`configuration_update` and `additional_tools`, with their placement, the effort check and refusals, are in "Requests that keep the cache" in the Core [D75, D76, D77, A-D76, D137].

### Model catalog

Model facts belong to the model id, in Rui's own catalog [D78]. They are not in core logic and not per provider [D78]. Following pi, the catalog is a models.dev snapshot shipped with Rui, refreshed from models.dev and saved in the Store [D78]. Review #1 was reshaped into this catalog [D78]. `model_capability.zig` stops being a hand-copied Codex list [D78]. Today `model_capability.models` is a compiled-in table of eight Codex ids (src/model_capability.zig:39, ARCHITECTURE.md:2614). The ARCHITECTURE.md line that rules out network discovery and a cache across Host runs (ARCHITECTURE.md:2627) changes [D124].

The catalog keeps two facts per model id [A-D79]:

| Fact | Reader | Reference |
| --- | --- | --- |
| Context window | The `compactAt` check. See "Compaction and context full" in the Core. | [A-D79, D111, D116] |
| Effort levels | The model picker, and the `unsupported_reasoning_effort` check on `sessions.create` and `update`. | [A-D79, D137, D165] |

Max output is dropped until something reads it [A-D79]. Rui never fills `effort` or `compactAt` from the catalog [D111].

When several models.dev providers list the same id, the OpenAI Adapters use the entry under models.dev's `openai` provider, and otherwise the first entry in models.dev's order [D151].

The catalog refreshes at these two times, together with the provider's live list [D79]:

- at Host start
- whenever someone asks for the model list

There is no timer [D79]. The refresh uses ETag, so an unchanged list returns 304 [D79]. Rui parses the file once and throws the rest away [D79]. Nothing waits on the fetch, and the fetch runs on the Reactor with no new thread [D79, D94]. The models.dev file measured 5.96 MB raw and 608 KB gzipped, with 4,105 unique ids across 235 providers [D79].

If models.dev is down, Rui uses the last saved copy, then the shipped list [D79]. The saved catalog rides the one Store format bump [D119].

### Usable models

Whether a model is usable comes only from the provider's live list [D80]. A new model therefore works at once with the preset's values [D80]. The model list is `rui.models()` in the TS client [D117, D128].

The provider's live list stays in memory as today (ARCHITECTURE.md:3297), and it is refreshed at the same triggers as the catalog [D153]. The ChatGPT Adapter's live list is the catalog's `openai` ids [D154]. A model ChatGPT does not serve is refused by the provider as a faithful error [D154].

Today the OpenAI-key Adapter fetches `GET BASE/models` once at Host start and never again (ARCHITECTURE.md:3297). Today ChatGPT has no public list, so its source is always the compiled table (ARCHITECTURE.md:3296).

### UI grouping

The UI groups models with the same id across providers [D81]. Today the picker names the sign-ins "ChatGPT" and "API key", and a model both offer asks `Use ChatGPT / API key` (ARCHITECTURE.md:2355, :2356).

### Budget refusals

A budget refusal ends the Turn with Marlin's own error text, as Rui already does for an unrecognised refusal [D71]. Marlin's budget refusal is `403 "Your budget has been exhausted"` [D68]. It ends the Turn as `provider_refused` with the provider's text [D150]. There is no fallback key to try [D71].

Today Rui maps a provider error code through the closed `transport_policy.Refusal` set (src/transport_policy.zig:42). A code Rui does not know narrows nothing, and the HTTP status decides (ARCHITECTURE.md:1406, :1408). A terminal model failure keeps the provider's report, `code: message`, as the failed outcome's public content (ARCHITECTURE.md:1523).

## Store Seam

The Store runs on SQLite or MySQL [D84]. These are the Store Seam's two Adapters [D35]. Drift uses the MySQL Adapter [D83]. Today the only Store is SQLite with WAL and `synchronous=FULL` (ARCHITECTURE.md:11, :3606; src/store/Store.zig:232-235).

### Rui gets its own database, `drift_rui`

Rui keeps its tables in its own database beside the app's, on the same MySQL server. For Drift that is `drift_rui` beside `drift`. Rui does not put prefixed tables inside the app's database [D82]. The approved db-seam plan stands unchanged, and a MySQL Store is a whole database [D83].

There are two reasons [D82]:

- On MySQL a schema is a database. DBOS, graphile-worker and Solid Queue use the same "own schema" pattern.
- Prisma's `migrate dev` flags tables it does not know and offers to reset the database. It has no option to exclude tables.

Drift's only change is one setting, `database: "mysql://rui_user:…@host/drift_rui"` [D83]. Rui opens its own connection, so Drift's 10-connection Prisma pool is untouched [D83]. Because `drift` and `drift_rui` sit on one server, they restore together. "Request keys" explains why that matters [D17].

Drift's operator creates `drift_rui` empty before the first start. Rui never creates databases [D155].

### Rui has its own MySQL login

Rui logs in as its own MySQL user, granted only on `drift_rui` [D85]. Drift's operator grants that login all privileges on `drift_rui` and nothing else [D155]. This rule is documentation. Rui does not check it [D85].

### Refusals at open

Rui refuses to open a MySQL Store in the cases below. Each refusal is one message that names what to fix [D86]. The refusal reaches Drift as `RuiStartError {code, message}`, with one code per refusal [D116, D136].

| Refused | Setting that triggers it | `RuiStartError.code` | Reference |
| --- | --- | --- | --- |
| MySQL older than 8.4 | Server version | `mysql_version` | D86, D136 |
| MariaDB | Server version | `mariadb` | D86, D136 |
| A read-only server or a replica | Server role | `read_only_replica` | D86, D136 |
| Relaxed durability | Any value other than `innodb_flush_log_at_trx_commit=1`, `sync_binlog=1` when the binlog is on, and doublewrite ON | `durability_<variable>` | D86, D136, D156 |
| Statement-format binary logging | `log_bin=ON` with `binlog_format=STATEMENT` | `binlog_statement` | D86, D136 |

Today the MySQL wire client already refuses MariaDB and MySQL before 8.4 at the handshake (src/store/wire/mysql.zig:1-3). The binlog refusal is new [D86]. It lands in the db thread's MySQL PR, PR 8 [D91].

### The `commit_seq` fence

The `store_owner` fence also checks `commit_seq` (`AND commit_seq=?`) [D87]. A restore or any foreign write then stops a running Host at its next commit [D87]. Without the check, the Host would mix in-memory state into older data [D87]. That state includes the next ids, which the Store reads once at open (src/store/Store.zig:1298-1301), and in-flight work [D87]. The fence lands in PR 8 [D91]. Today `src/` at `120f73c` has no `store_owner` fence and no `commit_seq` column (no match in `src/`).

When the fence fires, the Host exits with code `store_fenced` [D157]. The TS package's restart then starts cleanly on the restored data [D157]. Drift sees the `exit` event, and calls fail with `RuiUnavailableError` until the child is back (see "Readiness, lifetime, restart and shutdown") [D129, D116]. Today a fenced Store stays up and answers 503 (ARCHITECTURE.md:3634).

The documented backup rule is to stop Rui before a restore, and to dump with `mysqldump --single-transaction --routines` [D88]. Rui lives exactly as long as the Drift process, so stopping Rui means stopping Drift [D5].

### Runtime directory and the opaque Store id

Under MySQL the Host socket, scratch and diagnostics live in `runtimeDir` [D114]. The launch frame names `runtimeDir` [D112]. The TS package creates `runtimeDir` with `mkdtemp` under the OS temp dir, mode 0700, and deletes it on clean exit [D131]. Readiness is today's `/v1/host-info` probe on the socket in `runtimeDir` [D112].

Store ownership is the MySQL lock [D114]. The lock is `GET_LOCK` named after the database, as in the db-seam plan [D158]. Requests carry an opaque Store id that the Host reports at readiness, never the Store URL [D114]. The opaque Store id is a random id written into the Store at creation, and it stays the same across restarts [D158]. `RUI_STORE` in Bash is that id [D114].

A SQLite Host keeps today's Store directory and path selector unchanged [D158]. The table below is for MySQL.

| Piece | Today, in the SQLite Store directory | After, under MySQL |
| --- | --- | --- |
| Ownership | An OS-held `host.lock` in the Store directory (ARCHITECTURE.md:3613; src/platform.zig:43, :74) | `GET_LOCK` named after the database [D114, D158] |
| Socket | A pathname Unix socket found from the Store selector (ARCHITECTURE.md:3614; src/platform.zig:12) | In `runtimeDir` [D114] |
| Scratch | `scratch` in the Store directory (src/platform.zig:97) | In `runtimeDir` [D114] |
| Store selector on requests | A path of at most 492 bytes on every request (src/protocol.zig:18, :190) | The opaque Store id [D114, D158] |
| `RUI_STORE` in Bash | The canonical Store selector (ARCHITECTURE.md:535, :1619) | The opaque Store id [D114] |

The Store URL holds the MySQL password, so it travels only in the launch frame and never touches disk, argv or the environment [D108].

### One Store format bump

One Store format bump carries every schema change in this spec. The tool-records PR owns it [D119, D48]. The bump starts from schema 50 [D164].

| Change | Reference |
| --- | --- |
| The Sessions `parent` column, through `schema.zig` and typed rsql | D27, D89, D119 |
| Tool records, replacing the `tools_mask` byte and the fixed Bash and web-search bit list (src/tools.zig:243) | D48, D119 |
| The tool records each model request offered | D49, D119 |
| The Session change list | D53, D119 |
| The saved model catalog | D78, A-D79, D119 |
| Saved MCP tool copies | D110, D119 |
| `compactAt` | D111, D119 |
| The ending set | D115, D119 |

The db thread's own plan has no format bump left [D89]. There is no backward compatibility [D94]. Today a Store at any earlier format is refused and must be reset, with no migration (ARCHITECTURE.md:1257). The schema writes each closed value set as fixed literals, so changing the ending set is a format change (ARCHITECTURE.md:1258).

Two facts about today's code bear on this list. `src/store/schema.zig:19` at `120f73c` is schema 49, while ARCHITECTURE.md:1257 still says 47. On `origin/main`, #857 (`b748038f`) already removed `read_through` and moved the schema to 50. The bump therefore does not carry the `read_through` removal [D164, D96].

### Other Store changes

| Change | Reference |
| --- | --- |
| Settlement batches grow from 16 to 64 items. That is two round trips for up to 64 items and about 10 KB more resident memory for the whole Store. The change rides PR 5e-2a. On `origin/main` it merged as #861 (`2e8e8353`). | D92 |
| Store fsyncs stay. | D93 |

### SQLite stays

SQLite stays one of the two Adapters [D84, D35]. Store fsyncs stay [D93]. The decisions on the database, the login, the refusals at open, the `commit_seq` fence and the binlog refusal are all MySQL decisions [D82, D85, D86, D87]. The format bump changes the one schema that both Adapters render [D119]. Today that schema is already written to be expressible on SQLite, Postgres and MySQL (ARCHITECTURE.md:1257).

### Postgres is deferred

MySQL and SQLite are the first targets [D90]. The Postgres wire client from #768 stays merged and unused (src/store/wire/pg.zig). Only the SQLite and MySQL spellings are needed now [D90].

### The db thread's remaining PRs

The db thread's plan after PR 5e-3 is below [D91]. The MySQL PR comes right after the Store worker thread PR [D91].

| PR | Content | Reference |
| --- | --- | --- |
| 6 | Tests per engine (SQLite and MySQL conformance) | D91 |
| 7 | Store thread | D91 |
| 8 | MySQL (network ownership, the `commit_seq` fence and the binlog refusal) | D91 |
| 9 | Host wiring, including the stdin launch frame | D91, D108 |

## ARCHITECTURE.md contract changes

The table merges D95's items, the G14 items that D124 adds, the Workflow Runtime removal, and the items D159 adds [D95, D124, D126, D159]. D95's items 2, 3 and 8 were replaced by later decisions and are not changes [D95]. Line numbers are at commit `120f73c`.

| # | Change | ARCHITECTURE.md lines it touches | Ledger |
| --- | --- | --- | --- |
| 1 | Tools are saved as records, not as a fixed Bash and web-search enum. | :1139-1141 (the Tool Catalog holds `bash` and `web_search`, and a fresh Session gets both) | D95 (1), D48 |
| 2 | `ResourceExceeded` is renamed "context full" (`context_full`). | :656, :684 | D95 (4), D30, D115 |
| 3 | Agents talk through the agent tools, and Sessions get `parent`. | :524 ("Agent identity and peer composition"), :568 ("no ... parent-child ownership") | D95 (5), D27, D43 |
| 4 | The provider key may arrive in memory at startup, not only from the key file. | :3608 (Credentials, "One Rui-owned file"), :980 | D95 (6), D70, D108 |
| 5 | The Store runs on SQLite or MySQL, in its own database beside the app's. | :3606 (Storage, SQLite only), :11, :1501 | D95 (7), D82, D84 |
| 6 | Seam and Adapter join the term table. | :101 | D95 (9), D36 |
| 7 | There is one public interface. The TUI and CLI use the same routes as the TS package. | :2105 (Public operations) | D95 (10), D20 |
| 8 | Rui starts as a child of the caller, lives while its stdin pipe stays open, and gets the Store URL over stdin. There is no detached launch and no attach for this path. | :3624 ("Clients never auto-start"), :3644-3657 (`host start` attaches, detached launch) | D124, D5, D107, D108, A-D3 |
| 9 | MCP tools are in. The contract no longer excludes dynamic tools and MCP. | :4195 | D124, D45, D64 |
| 10 | A peer's answer is delivered. A child's final answer reaches the parent as a message and wakes it. | :564 ("not delivered to the sender"), :568 | D124, D39, D41 |
| 11 | Model facts come from a models.dev catalog that Rui refreshes and saves in the Store. | :2627 ("no ... other network discovery or cache across Host runs"), :3297 | D124, D78, D79, A-D79 |
| 12 | Hosted web search is a provider-run tool, listed with the other tools. | :3258 ("not a Tool Call"), :1139-1140 | D124, D47 |
| 13 | A Session can remove a tool mid-Session through its change list. A removed tool keeps its description in the request. | :1145-1146 | D124, D53, D54 |
| 14 | All tool calls in one model reply run at once, for every model. | :872-874 (`true` only for `gpt-5.5`) | D124, D56, D106 |
| 15 | Timeouts are faithful, and Rui never reruns a tool call. An MCP timeout is "may or may not have run". | :1489 (indeterminate result, no automatic replay), :1507 (Retries and timeouts), :1634 | D124, D60, D61, D32 |
| 16 | The routes `/v1/person-message`, `/v1/proposal-page`, `/v1/proposal-field` and `/v1/mark-read` are deleted. | :2466, :3301 (`person-message`), :3218, :3229 (`proposal-*`), :3331-3367 and :3339 (`mark-read` and "New since you looked"), :1334, :3344 (wire version notes) | D124, D11, D96, D97 |
| 17 | The Workflow Runtime is deleted from the contract. | :65 (owner row), :48, :53, :78-92 (diagram), :114, :152-155, :1150, :1155, :1483, :1786-2100 ("Workflow evaluation and cancellation" through "Evaluator containment"), :2105, :3607 (Evaluator row) | D126 |
| 18 | Every agent spec states `tools` and `permissionMode`, and `provider` and `workspace` follow the spec rules. | :180 (defaults) | D159, D104, D113, D133 |
| 19 | Bash gets the explicit `env` from `send`, empty by default, and never the caller's process environment. A child inherits its parent's saved environment, and a Message the core delivers leaves the receiver's environment unchanged. | :1601-1606 | D159, D121, D148, D169 |
| 20 | `RUI_STORE` in Bash is the opaque Store id. | :1619 | D159, D114 |
| 21 | `compactAt`, a token count, replaces the percentage compaction trigger. | The percentage trigger text | D159, D111 |
| 22 | The ending set replaces today's outcome set. | The outcome set text | D159, D115 |
| 23 | Every other ledger decision that contradicts ARCHITECTURE.md text. | Wherever that text is | D159 |

## Removals

Everything below is deleted. Where a removal has already merged, the table names the commit on `origin/main`.

| Removed | What replaces it | Status today | Reference |
| --- | --- | --- | --- |
| "New since you looked": `mark-read`, `read_through`, `beyond_unseen`, the rule and overview tracking | Nothing | Merged as #857 (`b748038f`), schema 50 | D96 |
| `/v1/proposal-page` and `/v1/proposal-field`, which have no product caller | Nothing | Merged as #858 (`72db6de9`) | D97 |
| `/v1/person-message` (Ctrl-P recall) | A `kinds` read of `/v1/activity-page` with page size 1 | Merged as #860 (`3b3d941a`) | D11 |
| `list_agents` | A parent reads its own transcript, `read_transcript(self, kinds: ["call"], query: "start_agent")` | Not in `src/` at `120f73c` | D98, D163 |
| The `tools_mask` byte and the fixed Bash and web-search bit list (src/tools.zig:243) | One record per tool | Open | D48 |
| The hand-copied Codex model list in `model_capability.zig` | The models.dev catalog | Open | D78 |
| Max output in the catalog | Nothing, until something reads it | Open | A-D79 |
| The percentage compaction trigger and the catalog default effort | `compactAt` and `effort`, stated in every spec | Open | D111 |
| The per-model parallel-calls list (src/codecs/responses.zig:21) | Parallel calls on every model | Merged as #868 (`eadbfa9e`) | D56, D106 |
| `effort_change_refused` as a request error | Today's `unsupported_reasoning_effort` on `sessions.create` and `update`, and a `session_changed` row for a provider refusal | Open | D137, D165 |
| `providerKey` in the launch frame and `RUI_OPENAI_BASE_URL` for launched Hosts | The frame's `provider` object | Open | D130 |
| The Workflow Runtime (ARCHITECTURE.md:65 and its sections) | Nothing. It can return when a real user needs it. | No code in `src/` and no QuickJS in the build | D126 |
| Drift's own `find_tools` | Rui's core `find_tools` | Drift's code | D52 |
| Drift's backup key, `MARLIN_API_KEY_FALLBACK` | One key, with no fallback list | Drift's code | D71 |
| Today's peer context text | A pointer to the agent tools | Open | D43 |

## What Drift provides

The spec has one "Drift provides" list [D125]. Drift supplies every item below.

**MCP server**

- [ ] Drift exposes its tools as an MCP server, and Rui is the MCP client [D45].
- [ ] The server ships inside Drift [D110].
- [ ] The server speaks MCP 2026-07-28 statelessly. Rui sends one POST per request with a static `Authorization: Bearer` header and no `initialize` [D64].
- [ ] The planned implementation is `@modelcontextprotocol/server` 2.4.0 `createMcpHandler`, mounted as a Next.js `POST` route. This is inferred from the API and not tested [D67].
- [ ] The server listens on loopback plain HTTP [D120].
- [ ] Drift names the server in connect's `tools` as `{name, url, bearerToken, callTimeoutMs}` [D120, D132]. The per-call time limit defaults to 10 minutes [D59, D145].
- [ ] No tool name collides with another server's tool, with `bash` or with a core tool, and no tool schema has a property named `rui_call_description`. Rui fails Host start with `tool_name_collision` otherwise [D120, D142].
- [ ] Each tool checks its own input, because Rui sends tools without `strict` [D57].
- [ ] No tool relies on a call id from Rui. Rui sends none [D61].
- [ ] If Drift wants web search on Marlin, a preset lists `web_search`, or Drift exposes its own search tool [A-D74, D74, D150].

**Presets**

- [ ] Presets are named agent specs in Drift's code, passed at connect and not stored in the database [D22].
- [ ] Every preset states `model`, `effort`, `compactAt`, `tools` and `permissionMode` [D113, D104, D111].
- [ ] A preset whose `tools` includes `bash` states `workspace` [D133].
- [ ] `tools` names the core tools like any other tool. `[]` means no tools [D113, D104].
- [ ] `compactAt` is a token count no larger than the model's known context window [D111].
- [ ] Drift reads its own doctrine files for `instructions` [D28].

**MySQL**

- [ ] A MySQL 8.4 or later server, not MariaDB, that is writable and not a replica [D86].
- [ ] Durable settings, `innodb_flush_log_at_trx_commit=1`, `sync_binlog=1` when the binlog is on, and doublewrite ON [D86, D156].
- [ ] No statement-format binary logging [D86].
- [ ] A database `drift_rui` on the same server as `drift`, created empty by Drift's operator. Rui never creates databases [D82, D155].
- [ ] A MySQL login for Rui with all privileges on `drift_rui` and nothing else [D85, D155].
- [ ] The `database` setting `mysql://rui_user:…@host/drift_rui` [D83].
- [ ] A backup procedure that stops Rui before a restore and dumps with `mysqldump --single-transaction --routines` [D88].

**npm package and platforms**

- [ ] Drift's npm package starts Rui as a child program on the same machine [D4, D107].
- [ ] Node 22 LTS or later [D127].
- [ ] The main package `rui` (working name, final at publish). The Rui binary comes from per-platform optional dependencies, `rui-linux-x64` and `rui-darwin-arm64`, found with `require.resolve` [D125, D127].
- [ ] Drift runs as a single instance [D4].

**stdin**

- [ ] Drift keeps the stdin pipe to Rui open for its whole life. Rui exits when the pipe closes [D5, D108].
- [ ] Drift starts Rui again if Rui alone crashes [D5]. The TS package does this with capped backoff from 0.5 s, doubling up to 30 s [D118, D129].
- [ ] Drift calls `rui.close()` on shutdown, which closes stdin and waits for the child [D129].

**Keys and env**

- [ ] The Marlin key and base URL, passed as `provider: { baseUrl, key }` to `Rui.connect` [D3, D70, D130].
- [ ] One key, with `MARLIN_API_KEY_FALLBACK` removed [D71].
- [ ] A bearer token for Drift's MCP server [D120].
- [ ] A request key `kind:driftId` on every write that has a Drift row, such as `chat:42` and `msg:42` [D17].
- [ ] An explicit `env` on `send` when Bash needs one. It defaults to empty, and Drift's process environment never reaches Bash [D121, D148].

## Questions for the Drift agent

We could not read Drift's code. Each question below names what the spec assumed.

| # | Question | What we assumed | Ledger |
| --- | --- | --- | --- |
| 1 | What types are Drift's chat and message ids? Does every `kind:driftId` key fit in 128 UTF-8 bytes (ARCHITECTURE.md:220)? Does the row exist before Drift calls `create` or `send`? | Ids are short, like `42`, and each write has a row whose id makes the key. | D17 |
| 2 | What do the hooks `beforeRequest`, `afterResponse`, `beforeTool` and `beforeCompact` do today? Can each one become a read of the feed? | Each hook only observes, so each maps onto a Rui read. | D103 |
| 3 | Is Drift a Next.js app on the same machine as Rui? Can it serve MCP 2026-07-28 statelessly through `createMcpHandler` on a loopback `POST` route? How would it issue the bearer token? | Yes, with one static token. | D64, D67, D120 |
| 4 | Did Drift's 9-turn cap protect anything besides its 10-connection MySQL pool? | Only the pool. Databricks keeps its 3-statement queue inside `run_sql`. | D34 |
| 5 | Which Node version does Drift run? | Node 22 LTS or later, the package's floor. | D127 |
| 6 | Do any of Drift's presets use Bash? If so, which Workspace and environment do they need? | Not checked. A preset with `bash` must state `workspace`, and Bash gets only the `env` Drift sends. A worker inherits its parent's saved environment. | D121, D133, D148, D169 |
| 7 | Does Drift's MySQL meet the refusals at open (version 8.4 or later, writable primary, durable settings, row or mixed binlog)? Can Drift's operator create a second database and a login on it? | Yes to both. | D82, D85, D86, D155, D156 |
| 8 | Does Drift run `prisma migrate dev` against `drift`? | Yes. That is one reason for a separate database. | D82 |
| 9 | Does any Drift tool dedupe on a call id today? | None does. Rui sends no call id, and after an unknown outcome the model checks for itself. | D32, D61 |
| 10 | Does any Drift tool call take longer than 10 minutes? | None does. | D59, D145 |
| 11 | Does Drift use web search through Marlin? | Not checked. A preset lists `web_search` only if it wants it. | A-D74 |
| 12 | What is Drift's "lane", which the port plan removes? | Not checked. | D103 |
| 13 | How is Drift's MySQL backed up and restored today? | It can follow the rule to stop Rui first and dump with `--single-transaction --routines`. | D88 |

## Not yet specified, deferred and out of scope

### Not yet specified

| Item | Reference |
| --- | --- |
| The build PR order. It is cut from this spec. | D103 |
| The Drift port plan. It covers rewriting `openNamespaceAgent`, mapping Drift's hooks onto Rui reads, cutting over live map conversations, and removing Drift's lane. The `openNamespaceAgent` rewrite moved out of the API ticket into this plan. | D99, D103 |
| The memory before and after comparison (#840). It measured 249.4 MiB idle and 282.1 MiB with one agent mid-turn (Private_Dirty). 8 and 9 agents are still to measure, with the same harness after the port. | D103 |
| Live checks against OpenAI, each in the build PR that adds it. They cover `configuration_update` for effort, `additional_tools`, old calls to a removed tool, and hosted web search. Marlin is only a gateway in front of OpenAI and other labs. At 04:54Z this was a proposal, with no Marlin-specific check script. | D103 |
| The core tools' exact JSON schemas and result text. They are written in the build PR that adds each tool. | D141 |

### Deferred

| Item | Reference |
| --- | --- |
| Postgres. The #768 wire client stays merged and unused. | D90 |
| Search by meaning in `read_transcript`. | D102 |

### Out of scope

| Item | Reference |
| --- | --- |
| pi or pi-durable drop-ins. | D100 |
| ACP and MCP-server translators, with Rui exposing itself over those protocols. | D100 |
| Network transport, auth tokens, and several Hosts sharing one Store. | D100 |
| Clients in languages other than TypeScript. | D100 |
| An in-process native library. | D100 |
| A `url` mode for a remote Rui, which would hold its own key. `Rui.connect` always starts a child. | D107 |
| These MCP client features are skipped for now. They are discovery, progress (tolerated, not used), list-change subscriptions, output-schema validation, the Tasks extension, OAuth, and falling back to the 2025 protocol. | D101 |

## Late details

This was settled after the sections were written.

- The text of the message that carries a child's answer or ending to its parent is prompt text, written in the build PR that adds child delivery, with no tests [D161].
- Each feed entry carries its own cursor as `entry.cursor`; pass the last one as `after` [D170].
- `session.interrupt()` with no current model call is a no-op that resolves without sending anything [D171].
