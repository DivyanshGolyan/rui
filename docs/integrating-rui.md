# Run your first Session from an application

Create a Session, send a request, and read its answer with the TypeScript client.
This example enables no tools, so the model can answer but cannot inspect your files or execute commands.
Provider usage may incur charges.

## Install the client

Use Node.js 22.6 or newer on a [supported platform](../README.md#install).
In your application project:

```sh
npm install ruicode
```

The `ruicode` package installs the matching `rui` executable for your platform as an optional dependency (`ruicode-linux-x64`, `ruicode-darwin-arm64`, or `ruicode-linux-arm64` with experimental platform support).
Each [GitHub release](https://github.com/DivyanshGolyan/rui/releases) also attaches the same packages as `rui-VERSION.tgz` and `rui-PLATFORM-VERSION.tgz` tarballs for offline installs.

Alternatively, install the client with `--omit=optional` and put a matching standalone `rui` binary on `PATH`.
The client looks for its platform package first, then `rui` on `PATH`.
Pass `binary` to `Rui.connect` to choose an executable explicitly.
Keep the client and binary versions matched.
See [client installation](../clients/ts/README.md#install) for application-owned updates and custom binary options.

## Configure the provider

A TypeScript-launched Host uses the OpenAI-compatible key provider.
It does not reuse a ChatGPT sign-in from `rui auth login codex`.
Set `OPENAI_API_KEY` and `RUI_MODEL` in your application's environment.
Choose a model your provider offers that accepts `low` reasoning effort for this example.
Change `effort` if your selected model needs a different supported value.

The example uses OpenAI's Responses API URL.
For another compatible provider, change `provider.baseUrl` to that provider's HTTPS base URL and supply its key.
Set `compactAt` below the selected model's context window with room for the response.
It is a compaction trigger, not a guarantee that every input fits.

## Send work and wait for an answer

Save this example as `example.mts` in your application project:

```ts
import { randomUUID } from "node:crypto";
import { Rui } from "ruicode";

function required(name: string): string {
	const value = process.env[name];
	if (!value) throw new Error(`Set ${name} before running this example`);
	return value;
}

const model = required("RUI_MODEL");
const key = required("OPENAI_API_KEY");
const rui = await Rui.connect({
	database: "./app-rui-store",
	provider: { baseUrl: "https://api.openai.com/v1", key },
});

try {
	const session = await rui.sessions.create({
		model,
		effort: "low",
		compactAt: 100000,
		tools: [],
		permissionMode: "ask",
	}, { idempotencyKey: randomUUID() });

	await session.send("Suggest a checklist for a read-only repository review.", {
		idempotencyKey: randomUUID(),
	});
	for await (const entry of session.listActivity({ follow: true })) {
		if (entry.kind === "assistant") console.log(await session.readContent(entry));
		if (entry.kind === "turn_ended" && entry.sessionId === session.id) {
			if (entry.ending !== "done") throw new Error(entry.code);
			break;
		}
	}
} finally {
	await rui.close();
}
```

Run the example with Node's TypeScript stripping enabled:

```sh
node --experimental-strip-types example.mts
```

You should see the assistant's checklist before the program closes the Host.
`send` resolves after admission, not after the model answers.
The example keeps the Host alive until its Session's `turn_ended` entry and reports non-success endings as errors.
The feed yields saved activity entries, not token-by-token text.
`readContent` retrieves the whole entry rather than only its inline excerpt.

The random keys create a fresh Session and Message each time this example runs.
For an application retrying the same logical write, retain and reuse that write's idempotency key instead.

## Connect your application's tools and storage

Supply a SQLite directory as `database`, as above, or an existing MySQL database URL with the [required schema](../clients/ts/README.md#install).
For MySQL TCP URLs, the only query option is `ssl-ca=/absolute/path/to/ca.pem` (the path may be percent-encoded), which replaces system trust with that PEM bundle alone; socket URLs and verification-disabling options are refused.
`Rui.connect` starts an application-owned child Host and communicates over its local socket.
The child lives while the application keeps the child's stdin pipe open.
Calling `rui.close()` shuts it down, so do not close immediately after admitting work that you still want to run.

Each Session needs `model`, `effort`, `compactAt`, `tools`, and `permissionMode`, or a complete named preset.
If you enable `bash`, also supply the Session's `workspace`.
Bash runs with your user's full privileges, not in a sandbox.
Approval settings are per Session.
An `ask` Session needs your application to review `approval_requested` entries and call `session.decide` before the command can run.

Use `ConnectOptions.tools` to register MCP servers and choose their discovered tool names in the Session's `tools`.
The API also accepts Session output schemas and connect-time presets.
See the [client guide](../clients/ts/README.md), [connection options](../clients/ts/src/client.ts), [Session API](../clients/ts/src/sessions.ts), and [activity feed](../clients/ts/src/feed.ts) for those interfaces.

For a terminal conversation, return to [Start a conversation](../README.md#start-a-conversation).
For agent coordination through the CLI, see [Using Rui from scripts and agents](scripting.md).
