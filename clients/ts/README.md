# ruicode (TypeScript client for Rui)

Starts a Rui Host as a child of your process and talks to it over its local socket.

```ts
import { Rui } from "ruicode";

const rui = await Rui.connect({
	store: { sqlite: { dir: "/var/lib/myapp/rui-store" } },
	providers: { openai: { endpoint: "https://api.openai.com/v1/responses", key: process.env.OPENAI_API_KEY! } },
	tools: {
		bash: { timeoutMs: 60000 },
		mcp: { drift: { url: "http://127.0.0.1:3000/mcp", bearerToken: process.env.MCP_TOKEN!, callTimeoutMs: 30000 } },
	},
}, { binary: "/path/to/rui" });
rui.on("exit", ({ code, signal, restarting }) => console.warn("rui exited", { code, signal, restarting }));
// ...
await rui.close();
```

## Install

Run `npm install ruicode`.
The `ruicode` package carries the client.
The `rui` executable comes from the platform package beside it
(`ruicode-linux-x64`, `ruicode-linux-arm64` or `ruicode-darwin-arm64`, installed as optional dependencies), else from `rui` on `PATH`.
Pass `binary` in the second argument to `Rui.connect` to name one yourself.

Bundled and custom binaries and their child Host launch are application-owned.
Standalone client Upgrade does not mutate npm packages or blindly stop an application-owned Host, and reports installation separately from activation.
There is no HTTP installer endpoint or background update polling; update the application's dependencies and lifecycle explicitly.

## Host settings and migration

The breaking signature is `Rui.connect(settings: HostSettings, options?: ClientOptions)`.
`HostSettings` is derived recursively from the generated settings schema, not a second list of supported Host options.
Every configured Adapter is available, including `providers.codex`, `providers.chatgpt`, `tools.bash`, `network`, `execution` and either Store.
For example, `providers: { codex: {} }` uses the Codex Adapter's saved sign-in.
The client defaults omitted or null `interface.dir` to its private temporary directory and omitted `interface.lifetime` to `"stdin"`; an explicit non-null directory or `"stdin"`/`"detached"` lifetime wins.
It sends the document to `rui host serve --settings -` using a four-byte big-endian byte length followed by UTF-8 JSON, not argv or environment flags.

Before:

```ts
await Rui.connect({
	database: "/data/store",
	provider: { baseUrl: "https://api.openai.com/v1", key: "secret", caFile: "/trust.pem" },
	tools: [{ name: "drift", url: "http://127.0.0.1:3000/mcp", bearerToken: "token", callTimeoutMs: 30000 }],
	activeCapacity: 2, paused: true, presets: {}, binary: "/path/to/rui", lockWaitMs: 5000,
});
```

After:

```ts
await Rui.connect({
	store: { sqlite: { dir: "/data/store" } },
	providers: { openai: { endpoint: "https://api.openai.com/v1/responses", key: "secret" } },
	network: { caFile: "/trust.pem" },
	tools: { mcp: { drift: { url: "http://127.0.0.1:3000/mcp", bearerToken: "token", callTimeoutMs: 30000 } } },
	execution: { activeCapacity: 2, paused: true }, presets: {},
}, { binary: "/path/to/rui", lockWaitMs: 5000 });
```

Every former `ConnectOptions` field moves as follows:

| Before | After |
| --- | --- |
| `database` (directory) | `settings.store.sqlite.dir` |
| `database` (MySQL URL) | `settings.store.mysql.url` (a secret source or pipe-only string) |
| `provider.baseUrl` | `settings.providers.openai.endpoint`: append `/responses` to the former base URL (trim trailing `/` first) |
| `provider.key` | `settings.providers.openai.key` (a secret source or pipe-only string) |
| `provider.caFile` | `settings.network.caFile` (Host-wide, for all providers) |
| `tools[].name` | The key in `settings.tools.mcp[name]` |
| `tools[].url` | `settings.tools.mcp[name].url` |
| `tools[].bearerToken` | `settings.tools.mcp[name].bearerToken` (a secret source or pipe-only string) |
| `tools[].callTimeoutMs` | `settings.tools.mcp[name].callTimeoutMs` |
| `activeCapacity` | `settings.execution.activeCapacity` |
| `paused` | `settings.execution.paused` |
| `presets` | `settings.presets`, using the existing `AgentSpec` writer |
| `binary` | `options.binary` |
| `lockWaitMs` | `options.lockWaitMs` (still defaults to 120000 ms) |

Secret strings are a TypeScript input convenience: the pipe serializer wraps each as `{ value: "secret" }`.
Explicit `{ value: "secret" }`, `{ file: "/private/key" }`, `{ env: "NAME" }`, and the generated owner/default forms are also accepted where the schema allows them.
Literal values are permitted only for pipe-origin documents, never settings files.
The child inherits `PATH`, `HOME` and `TMPDIR`, plus only the environment variables explicitly named by secret `{ env: ... }` sources in the document.
Unreferenced application, proxy and provider-override environment variables are not inherited.
Node can pass environment names only as Unicode strings: a non-UTF-8 byte name is refused with `settings_invalid` and its leaf path rather than silently selecting another key; use a file source instead.
Literal keys, tokens and MySQL URLs travel only in stdin, never argv, environment or disk; an explicitly selected environment source is inherited instead.
The client erases its mutable serialized buffers after writes and on close or failed connect; JavaScript strings, including caller-owned inputs and temporary JSON strings, cannot be reliably erased.
Do not log settings or enable process dumps around secrets.

OS-byte paths and secret-source environment names accept `string`, `Uint8Array` (including Node `Buffer`), or the generated closed `{ hex: "2fff" }` form.
Strings keep their UTF-8 encoding; byte arrays become lowercase hexadecimal objects without lossy decoding.
The client uses a private symlink alias for socket transport when a caller chooses an interface directory, so non-UTF-8 interface bytes do not pass through Node's string-only socket path API.
The Host still applies each Adapter's path restrictions: byte-capable transport does not make a non-UTF-8 SQLite canonical Store identity valid.

`network.caFile` names a PEM file to trust exclusively instead of system CAs, on macOS as on Linux.
Omit it or use `null` for system trust; an empty string is not a reset and is refused by provider transport validation.
Relative paths use the Host's working directory, and a file that cannot be loaded or a peer that cannot be verified fails without falling back to system trust.
MySQL URLs have the form `mysql://USER:PASSWORD@HOST[:PORT]/DATABASE`.
For a Unix socket, use its percent-encoded absolute path in place of HOST; TCP verifies TLS.
For MySQL TCP URLs, the only query option is `ssl-ca=/absolute/path/to/ca.pem` (the path may be percent-encoded), which replaces system trust with that PEM bundle alone; socket URLs and verification-disabling options are refused.
The MySQL database must already contain the DDL from `rui store schema --engine mysql`.
The client waits for its own child's readiness instance and verifies that exact instance over the socket before adopting a Host; an existing Host in a caller-supplied interface directory is never substituted.
Readiness discovers the Host's canonical Store identity, which the client uses on subsequent requests; MySQL uses its stable opaque id, never the URL.
MySQL readiness also reports `innodb_doublewrite`, including `OFF`.
Shell commands the agent runs execute as your user; Rui is not a sandbox.

With the default `interface.lifetime: "stdin"`, the Host stops when your process ends.
An explicit `"detached"` lifetime does not stop on stdin closure; `rui.close()` still explicitly disposes its child and removes only the client-owned temporary directory, not a caller-supplied interface directory.
If it exits on its own, the client restarts it, waiting 0.5 s and doubling up to 30 s, and sends calls in flight again once the new Host is ready.
Automatic restarts retry `store_locked` and `mysql_unreachable`; calls waiting on a failed attempt receive `RuiUnavailableError`.
Initial connect still rejects `mysql_unreachable` immediately.

Errors:

- `RuiStartError { code, message }`: Rui refused to open, for example `store_locked` once `lockWaitMs` (default 120 s) has passed.
- `RuiRequestError { code }`: Rui rejected one request.
- `RuiUnavailableError`: the child is gone.

For `sessions.create` and `session.update`, `mcp_server_unavailable` means a requested tool is unknown and at least one configured MCP server has no tools, including no saved copies.
The error's `message` names the unavailable server(s) that may provide the name; it does not assert ownership.
If every configured server has tools, an unknown name gets `unknown_tool` instead.
Saved tool copies remain usable in specs even when their server is unreachable; calling such a tool can still fail with `mcp_server_unavailable` as a tool result.
A creating Message uses the same request rule, and `start_agent` reports it as a tool error naming `spec.tools` rather than starting an agent.

## Session feed

`session.listActivity()` reads to the current end; `{ follow: true }` follows new entries.
Feed entries are a discriminated union: `switch (entry.kind)` narrows to that wire row's fields.
A `model_call` entry is one resolved model Operation at its admission position: `model`, nullable `servedModel`, nullable `inputTokens`, `outputTokens`, `cachedTokens`, `latencyMs`, `firstEventMs`, plus `status` and `attempts`.
Counts and durations remain decimal strings (or null); both timings describe the **final attempt**, and `firstEventMs` measures the first HTTP response event, not the first token.
The requested model comes from the immutable admitted revision; served model uses stored body evidence before header evidence, never the requested model as fallback.
A late resolution can reveal this row inside a previously captured end (D219); following from a later cursor does not replay it, so reread that range to observe it.
Only top-level field names become camelCase (for example `callOrdinal`); nested objects keep their wire spelling (for example `presentation.publication_position`).
Text-bearing kinds add `text`, or `truncated: true` when the text exceeds 16 KiB; `contentBytes` gives its byte length.
Use `session.readContent(entry)` or `readContentBytes(entry)` for the whole text.

Following polls with backoff from 250 ms to 2 s only while the Session is busy.
An empty page in `idle`, `finished`, `failed`, or `stopped` state with nothing queued puts the iterator to sleep **without a timer**.
It wakes after a successful `send`, `update`, `decide`, `interrupt`, `stop`, `archive`, or `unarchive` through any handle for that Session ID on the same Rui instance, then starts polling again at 250 ms.
Writes from another process to the same Store are **not noticed while idle** (nor are writes through another Rui instance).
Pass an AbortSignal as `signal` to end the iterator immediately even while it sleeps.

## Development

`src/wire.ts` and the runtime input-codec descriptor `src/settings-kinds.ts` are generated from the repository's `openapi.json`, which the Host build emits from its types.

```sh
npm ci
npm run generate   # after openapi.json changes
npm run check      # both generated files are fresh, and the package type-checks
RUI_BINARY=../../zig-out/bin/rui npm test
```

`node scripts/pack.mjs <version> <outdir> <platform>=<executable> ...` builds the release tarballs (the compiled client and one package per platform).
It publishes nothing. `node scripts/publish.mjs <dir>` publishes them, dependencies first, skipping versions npm already has; each release runs it in the `npm_publish` job.

The repository's `zig build ts-client` runs the tests against the Rui it builds.
The real-Host feed and settings tests use local HTTPS providers and `openssl` for temporary certificates; no live provider credentials are needed.
The settings process test also runs on MySQL when `RUI_TEST_MYSQL_SOCKET`, `RUI_TEST_MYSQL_ROOT_PASSWORD` and `RUI_TEST_MYSQL_ADMIN` are supplied by the existing live-engine suite.

## Session settings

`create` needs `model`, `effort`, `compactAt`, `tools` and `permissionMode`, and `workspace` when `tools` includes `bash`, or a `preset` name with optional overrides.
`provider` may be left out when the Host serves one provider.
`effort: null` sends no effort, so the provider uses its own; it is accepted only for a model Rui does not list.
Updates may change the model within the Session's fixed provider; the Workspace also remains fixed.
An omitted setting stays as it is.

```ts
const session = await rui.sessions.create({
	model: "gpt-6.1-sol",
	effort: "high",
	compactAt: 244800,
	tools: ["bash"],
	permissionMode: "ask",
	workspace: "/work/project",
}, { idempotencyKey: "project:1" });
await session.update({ compactAt: 200000 });
await session.update({ model: "gpt-5.5" });
```

`await session.status()` reads the Current report: work `state` and `since`, `turn`, `operation`, `pendingMessages`, `parent`, `label`, `model`, `effort`, `tools`, `permissionMode`, `latestOutcome` and `archiveState`.
Counts, times and Turn/Operation IDs stay decimal strings; absent targets, parents and outcomes are `null`.
A separate ending is not in the report, so status does not invent one.
`interrupt()` uses this status snapshot to select its exact model target.

Presets are complete agent specs passed at connect and kept only in Host memory.
Creation copies the preset, with every supplied field (including `null`) overriding it.

```ts
const rui = await Rui.connect({
	store: { sqlite: { dir: "/var/lib/myapp/rui-store" } },
	providers: { openai: { endpoint: "https://api.openai.com/v1/responses", key: process.env.OPENAI_API_KEY! } },
	presets: {
		review: { model: "gpt-6.1-sol", effort: "low", compactAt: 100000, tools: [], permissionMode: "ask" },
	},
});
const review = await rui.sessions.create({ preset: "review", instructions: "Review this patch" }, { idempotencyKey: "review:1" });
await rui.close();
```

## Archive and restore

Archive metadata is independent of work state. `archiveState` is `active`, `archiving` or `archived` in Session summaries and status.

```ts
const result = await session.archive({ idempotencyKey: "archive:1" });
// result: { archived: true, completion: "pending" | "completed" }
await session.unarchive({ idempotencyKey: "restore:1" });

await rui.sessions.list();                       // active, including archiving
await rui.sessions.list({ archive: "archived" }); // archived only
await rui.sessions.list({ archive: "all" });      // all Sessions
```

`archive()` submits one durable intent that stops running and queued work, then archives after real settlement.
An accepted intent can return `completion: "pending"`; acceptance does not mean stopped processes have retired.
New Messages are rejected with `session_archiving` during settlement, and `unarchive()` is rejected with `archive_pending`.
A later Message to an archived Session restores it transactionally before admitting new work.
`unarchive()` restores only organization and never resumes stopped work.
Replaying an archive request with its original key does not archive again after a later restore.
Both methods notify local activity followers without submitting a Message or starting work.
