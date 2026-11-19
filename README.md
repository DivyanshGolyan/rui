# Rui

Rui runs many agents from your application in one small process.
Work picks up where it left off when Rui restarts after a crash.
Your application starts agents, gives them tools and reads their answers through a TypeScript client.
The same runtime also gives you an agent in your terminal.

**100 waiting agents.
2.5 MB of private memory.**

![Private memory at 0, 1, 10, and 100 waiting agents for Rui, pi, fx, Codex app-server, and OpenCode, from the published Linux benchmark.](docs/assets/waiting-agent-memory.svg)

Source: the [published Linux model-wait benchmark](https://divyanshgolyan.com/posts/hundred-agents/) at [Rui revision 5014980](https://github.com/DivyanshGolyan/rui/commit/50149807908283e044e3573f1b251d6a2f21e854).
See the [data and method](docs/waiting-agent-memory.md) for measurement scope and versions.

## Why Rui

- **Many agents, one process.**
  Agents spend most of their time waiting on the model.
  In Rui a waiting agent is saved state in one shared process, so in the [published benchmark](docs/waiting-agent-memory.md) a hundred waiting agents used about as much memory as one.
- **Safe across crashes.**
  Every step is saved before Rui moves on.
  If Rui stops in the middle of a command, it reports that the command may have run and never runs it again by itself.
- **Your tools.**
  Connect MCP servers or use the built-in Bash and agent tools.
  Agents can start other agents and collect their reports.

## Get started with TypeScript

[Follow the TypeScript quickstart](docs/integrating-rui.md) to run a Session and read its answer.

```ts
import { Rui } from "ruicode";
const rui = await Rui.connect({
	store: { sqlite: { dir: "./app-rui-store" } },
	providers: {
		openai: {
			endpoint: "https://api.openai.com/v1/responses",
			key: { value: process.env.OPENAI_API_KEY! },
		},
	},
});
```

Install with `npm install ruicode` on Node.js 22.6+; the package brings the matching `rui` executable for your platform.
The client starts a Host for you.
This example uses an OpenAI-compatible Responses API key; Host settings can also select the Codex or ChatGPT sign-in providers.
Provider usage may incur charges.

## How it works

Your application talks over a local socket to one shared Host that runs every Session.
The Host shares networking and execution capacity across Sessions and saves their state in SQLite or MySQL.
See the [Host guide](docs/host.md) for [settings](docs/host.md#save-host-settings), capacity and lifecycle.

## Try it in your terminal

<a id="install"></a>

The standalone binary supports Apple Silicon macOS 15+ and x86-64 Linux with glibc 2.34+.
ARM64 Linux and Intel macOS builds are experimental.

```sh
curl -fsSL https://ruicode.com/install | sh
```

The installer checks SHA-256 and installs in `~/.local/bin`.
If `~/.local/bin` is not on your `PATH`, it adds it to your shell profile; open a new terminal afterwards.
Set `RUI_NO_MODIFY_PATH=1` to leave your profile alone and follow its `PATH` instructions instead.
See [upgrade and activation](docs/host.md#upgrade-and-activation) before updating saved work, and [update recovery](#update-recovery) if an older Rui cannot download its update.

<a id="start-a-conversation"></a>

Run `rui` in your project directory.
The first run asks you to choose a ChatGPT account or an API key; [Sign in](docs/using-rui.md#sign-in) covers each method.

Bash runs with your full privileges, without a sandbox, and defaults to running without approval (`bypass`).
[Approval settings](docs/using-rui.md#approve-bash-commands) apply per Session and do not automatically propagate to agents it starts.
See the [terminal guide](docs/using-rui.md) or [scripting guide](docs/scripting.md) for your next step.

## Documentation

<a id="status"></a>
Rui is in development.

- [TypeScript integration](docs/integrating-rui.md), [terminal guide](docs/using-rui.md), and [scripting guide](docs/scripting.md).
- <a id="run-your-first-swarm"></a>[Agent coordination](docs/scripting.md#agents-calling-rui) to start investigators and collect their reports.
- <a id="skills"></a>[Skills](docs/using-rui.md#skills) and <a id="archive-a-conversation"></a>[archive controls](docs/using-rui.md#archive-sessions).
- <a id="build-from-source"></a>[Development and source builds](docs/development.md), including contribution setup and provider-free examples.
- <a id="learn-more"></a>[Architecture](ARCHITECTURE.md), [Verification](VERIFICATION.md), and [Research](research/README.md).
- [Store format reset](docs/store-reset.md), [contributing rules](AGENTS.md), and [third-party notices](THIRD_PARTY_NOTICES.md).

## Update recovery

If an older Rui cannot download its update because DNS resolution stalls, it needs an initial installer download to receive the fix.
This recovery path requires a published installer with IPv4 fallback for its archive download.
Run this command as the same user who installed Rui.
The installer preserves Stores, credentials and earlier builds, and attempts to restart all running Hosts belonging to that user on the selected version.
Save or finish work before proceeding.

```sh
(
  set -eu
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl --disable --ipv4 -fsSL --connect-timeout 10 --max-time 300 https://ruicode.com/install -o "$installer"
  sh "$installer"
)
```

This recovery command downloads the current installer over IPv4 without changing your curl configuration or system DNS.
The installer verifies the archive's SHA-256 digest and version before publishing it.
