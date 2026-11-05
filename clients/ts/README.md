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
The key and tokens never reach the child's argv, environment or disk.
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
