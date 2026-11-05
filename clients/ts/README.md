# rui (TypeScript client)

Starts a Rui Host as a child of your process and talks to it over its local socket.

```ts
import { Rui } from "rui";

const rui = await Rui.connect({
	database: "/var/lib/myapp/rui-store",
	provider: { baseUrl: "https://api.openai.com/v1", key: process.env.OPENAI_API_KEY },
});
rui.on("exit", ({ code, signal, restarting }) => console.warn("rui exited", { code, signal, restarting }));
// ...
await rui.close();
```

## Install

The `rui` package carries the client. The `rui` executable comes from the platform package beside it
(`rui-linux-x64`, `rui-linux-arm64` or `rui-darwin-arm64`, installed as optional dependencies), else from `rui` on `PATH`.
Pass `binary` to `Rui.connect` to name one yourself.

`Rui.connect` writes the Store, the provider key and a private runtime directory to the child's stdin.
The key never reaches the child's argv, environment or disk.
The child gets only `PATH`, `HOME` and `TMPDIR` from your environment.
Shell commands the agent runs execute as your user; Rui is not a sandbox.

The child lives as long as its stdin stays open, so it stops when your process ends.
If it exits on its own, the client restarts it, waiting 0.5 s and doubling up to 30 s, and sends calls in flight again once the new Host is ready.

Errors:

- `RuiStartError { code, message }`: Rui refused to open, for example `store_locked` once `lockWaitMs` (default 120 s) has passed.
- `RuiRequestError { code }`: Rui rejected one request.
- `RuiUnavailableError`: the child is gone.

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

## Session settings

`create` needs `model`, `effort`, `compactAt`, `tools` and `permissionMode`, and `workspace` when `tools` includes `bash`, or a `preset` name with optional overrides.
`provider` may be left out when the Host serves one provider.
`effort: null` sends no effort, so the provider uses its own.
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
