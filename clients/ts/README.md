# rui (TypeScript client)

Starts a Rui Host as a child of your process and talks to it over its local socket.

```ts
import { Rui } from "rui";

const rui = await Rui.connect({
	database: "/var/lib/myapp/rui-store",
	provider: { baseUrl: "https://api.openai.com/v1", key: process.env.OPENAI_API_KEY },
	tools: [{ name: "drift", url: "http://127.0.0.1:3000/mcp", bearerToken: process.env.MCP_TOKEN, callTimeoutMs: 30000 }],
});
rui.on("exit", ({ code, signal, restarting }) => console.warn("rui exited", { code, signal, restarting }));
// ...
await rui.close();
```

## Install

The `rui` package carries the client. The `rui` executable comes from the platform package beside it
(`rui-linux-x64`, `rui-linux-arm64` or `rui-darwin-arm64`, installed as optional dependencies), else from `rui` on `PATH`.
Pass `binary` to `Rui.connect` to name one yourself.

`Rui.connect` writes the Store, the provider key, MCP bearer tokens and a private runtime directory to the child's stdin.
`database` accepts a SQLite directory or a `mysql://USER:PASSWORD@HOST[:PORT]/DATABASE` URL.
For a Unix socket, use its percent-encoded absolute path in place of HOST; TCP verifies TLS.
The MySQL database must already contain the DDL from `rui store schema --engine mysql`.
The key, tokens and MySQL URL never reach the child's argv, environment or disk.
Readiness discovers the MySQL Store's stable opaque id, which the client uses on requests instead of the URL.
MySQL readiness also reports `innodb_doublewrite`, including `OFF`.
The child gets only `PATH`, `HOME` and `TMPDIR` from your environment.
Shell commands the agent runs execute as your user; Rui is not a sandbox.

The child lives as long as its stdin stays open, so it stops when your process ends.
If it exits on its own, the client restarts it, waiting 0.5 s and doubling up to 30 s, and sends calls in flight again once the new Host is ready.

Errors:

- `RuiStartError { code, message }`: Rui refused to open, for example `store_locked` once `lockWaitMs` (default 120 s) has passed.
- `RuiRequestError { code }`: Rui rejected one request.
- `RuiUnavailableError`: the child is gone.

## Session feed

`session.listActivity()` reads to the current end; `{ follow: true }` follows new entries.
Feed entries are a discriminated union: `switch (entry.kind)` narrows to that wire row's fields.
Only top-level field names become camelCase (for example `callOrdinal`); nested objects keep their wire spelling (for example `presentation.publication_position`).
Text-bearing kinds add `text`, or `truncated: true` when the text exceeds 16 KiB; `contentBytes` gives its byte length.
Use `session.readContent(entry)` or `readContentBytes(entry)` for the whole text.

Following polls with backoff from 250 ms to 2 s only while the Session is busy.
An empty page in `idle`, `finished`, `failed`, or `stopped` state with nothing queued puts the iterator to sleep **without a timer**.
It wakes after a successful `send`, `update`, `decide`, `interrupt`, or `stop` through any handle for that Session ID on the same Rui instance, then starts polling again at 250 ms.
Writes from another process to the same Store are **not noticed while idle** (nor are writes through another Rui instance).
Pass an AbortSignal as `signal` to end the iterator immediately even while it sleeps.

## Development

`src/wire.ts` is generated from the repository's `openapi.json`, which the Host build emits from its wire types.

```sh
npm ci
npm run generate   # after openapi.json changes
npm run check      # wire.ts is fresh, and the package type-checks
RUI_BINARY=../../zig-out/bin/rui npm test
```

`node scripts/pack.mjs <version> <outdir> <platform>=<executable> ...` builds the release tarballs (the compiled client and one package per platform).
It publishes nothing; the first npm publish waits for the maintainer.

The repository's `zig build ts-client` runs the tests against the Rui it builds.
The real-Host feed test uses a local HTTPS provider and the `openssl` command to generate its temporary test certificate; no live provider credentials are needed.

## Session settings

`create` needs `model`, `effort`, `compactAt`, `tools` and `permissionMode`, and `workspace` when `tools` includes `bash`, or a `preset` name with optional overrides.
`provider` may be left out when the Host serves one provider.
`effort: null` sends no effort, so the provider uses its own; it is accepted only for a model Rui does not list.
An update may leave out any setting, and an omitted setting stays as it is.

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
```

`await session.status()` reads the Current report: work `state` and `since`, `turn`, `operation`, `pendingMessages`, `parent`, `label`, `model`, `effort`, `tools`, `permissionMode` and `latestOutcome`.
Counts, times and Turn/Operation IDs stay decimal strings; absent targets, parents and outcomes are `null`.
A separate ending is not in the report, so status does not invent one.
`interrupt()` uses this status snapshot to select its exact model target.

Presets are complete agent specs passed at connect and kept only in Host memory.
Creation copies the preset, with every supplied field (including `null`) overriding it.

```ts
const rui = await Rui.connect({
	database: "/var/lib/myapp/rui-store",
	provider: { baseUrl: "https://api.openai.com/v1", key: process.env.OPENAI_API_KEY! },
	presets: {
		review: { model: "gpt-6.1-sol", effort: "low", compactAt: 100000, tools: [], permissionMode: "ask" },
	},
});
const review = await rui.sessions.create({ preset: "review", instructions: "Review this patch" }, { idempotencyKey: "review:1" });
await rui.close();
```
