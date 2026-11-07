# Rui

**100 waiting agents. 2.5 MB of private memory.**

Published Linux benchmark with 100 agents waiting on a fake model.

Rui (रुई, Hindi for cotton) is a memory-efficient coding-agent harness built for agents that start other agents.
Use it to split an investigation among several agents, keep their conversations separate, and bring their findings back to one conversation.

[Install Rui](#install), then [run your first swarm](#run-your-first-swarm).

![Private memory at 0, 1, 10, and 100 waiting agents for Rui, pi, fx, Codex app-server, and OpenCode, from the published Linux benchmark.](docs/assets/waiting-agent-memory.svg)

Source: [Rui: a hundred agents in 2.5 MB](https://divyanshgolyan.com/posts/hundred-agents/), measured on 30 October 2026 at [Rui revision 5014980](https://github.com/DivyanshGolyan/rui/commit/50149807908283e044e3573f1b251d6a2f21e854).
The fake model accepted requests and never answered.
The figures sum private memory across harness processes, not RSS.
They are not memory budgets for arbitrary active workloads.
These are medians of three runs with unequal tool sets, not measurements of the current release.
See the [data and method](docs/waiting-agent-memory.md) before comparing workloads.

## Install

You need an Apple Silicon Mac with macOS 15 or newer, or x86-64 Linux with glibc 2.34 or newer.
Builds for ARM64 Linux and Intel macOS are experimental.

```sh
curl -fsSL https://github.com/DivyanshGolyan/rui/releases/latest/download/install.sh | sh
```

The installer puts `rui` in `~/.local/bin` and checks the download's SHA-256 digest.
If that directory is not on your `PATH`, follow the installer's shell-profile instructions.
For the current shell, run `export PATH="$HOME/.local/bin:$PATH"`.

Run `rui --version` to see your build or `rui upgrade --check` to check for a stable release without installing or starting a Host.
See [upgrade and activation](docs/host.md#upgrade-and-activation) before updating a Store with saved work.

## Start a conversation

Bash commands run with your user's full access and do not ask for approval by default (`bypass`).
Your project directory is not a sandbox.
Approval settings apply to each Session separately, not automatically to agents it starts.
See [Approve Bash commands](docs/using-rui.md#approve-bash-commands) to use `ask` mode.

1. Enable device code authorization for Codex in your ChatGPT security settings.
   On a workspace account, an admin allows it in the workspace permissions instead.
   Then sign in:

	```sh
	rui auth login codex
	```

	Open the link Rui prints, sign in, and enter the code.
	Never share the code.
	See [OpenAI's Codex sign-in guide](https://learn.chatgpt.com/docs/auth) if the setting is missing.
	Alternatively, `rui auth login openai` reads an OpenAI API key from stdin.
	See [API-key setup](docs/host.md#run-in-the-foreground) for Host startup requirements.

2. Go to your project and start Rui:

	```sh
	cd /path/to/your/project
	rui
	```

3. Type a request at the `›` prompt, or use the swarm prompt below.

Bash uses your terminal's environment.
A tool you install or a venv you activate reaches the agent with your next message.
The environment stays in memory and is never saved.

## Run your first swarm

This example uses the default `bypass` mode described above.
The read-only request is an instruction to the agents, not an enforced restriction.
Delegation can incur additional provider usage.

Paste this prompt into Rui:

```text
Split this repository into at most three disjoint areas.
Start one read-only investigator per area and ask each not to start more agents.
Do not install dependencies, run tests, or edit files.
Consolidate their reports into one deduplicated correctness-bug list with file and line references, separating confirmed findings from uncertainty.
```

Success looks like several Sessions in the overview and one consolidated answer in the coordinating conversation.
See [agent messaging](docs/scripting.md#agents-calling-rui) for the command protocol.

## How Rui shares resources

One shared Host runs the Sessions in a Store instead of starting a process for each Session.
The Host shares networking, persists conversation state in SQLite by default, and streams model output through bounded buffers.
Bash commands still run as separate processes with their own memory costs.

The default 100 execution slots are shared by model calls and Bash commands, not 100 arbitrary active tasks.
Work beyond that capacity waits for a slot.
All Sessions in the Store share the Host's failure boundary.
A Host crash interrupts them together, and a restart recovers saved state without replaying commands whose outcomes are unknown.
See [Host capacity and lifetime](docs/host.md) and the [architecture](ARCHITECTURE.md).

To leave the terminal without stopping work, type `/exit` or press Ctrl+C.
Run `rui` again to return to an unarchived conversation.

## Status

Rui is in development.
It supports Codex sign-in, interactive conversations, scripts, optional Bash approval, and saved-result recovery.
A file-editing tool and structured answers are not available yet.

On both supported platforms, a live `gpt-6-luna` conversation, approved Bash, and restart recovery have passed.
Other models, live credential refresh, and the full mixed-workload qualification have not.
See [test results and limitations](tests/qualification/README.md#current-checks-and-qualification).
The published waiting-agent benchmark does not qualify those workloads, models, or providers.

Keep these limits in mind:

- A detached subprocess or blocked I/O can outlast a stop request.
- Rui reports unknown command outcomes as indeterminate and never reruns those commands automatically.
  Rui does not promise recovery from an OS crash or power loss.
- Full tool output is temporary.
  Saved results and excerpts remain after Rui drops it.

## Archive a conversation

In the overview, select a Session and enter `/archive`.
If it has work, confirm **Stop and archive**.
Rui waits for the stop to complete before it hides the Session.
Use `/sessions archived` to find it and `/unarchive` to restore it without starting work.
Archive keeps history and files.
See [archive controls](docs/using-rui.md#archive-sessions) for all views and shortcuts.

## Skills

Rui discovers `SKILL.md` skills in your repository's `.agents/skills` and the Host user's `~/.agents/skills`.
Repository names win collisions.
Use `/skill NAME` to read one into the conversation and `/reload-skills` to refresh the advertised catalog without starting a model turn.
Skills grant no permissions and execute nothing on load.
See [terminal commands](docs/using-rui.md#skills) or [scripted invocation](docs/scripting.md#invoke-and-reload-skills).

## Troubleshooting

- If your shell cannot find `rui`, check the [installation path](#install).
- If device login is unavailable, check the authorization prerequisite in [Start a conversation](#start-a-conversation).
- If your platform is unsupported, check the [Install requirements](#install).
  ARM64 Linux and Intel macOS builds remain experimental, including [source builds](#build-from-source).
- To review Bash commands before execution, see [approvals](docs/using-rui.md#approve-bash-commands).

## Build from source

See [Developing Rui](docs/development.md) to build and install from source, run tests, or try Rui without a provider account.

## Learn more

- [Using the terminal conversation](docs/using-rui.md): commands, scrolling, Sessions, models, and context compaction.
- [Using Rui from scripts and agents](docs/scripting.md): one-shot commands, results, approvals, and recovery.
- [Running the Host](docs/host.md): the background process, its Store, and failed-response diagnostics.
- [Start fresh after a Store format change](docs/store-reset.md).
- [Architecture](ARCHITECTURE.md): behavior, ownership, and recovery, including the planned V1 contract.
- [Verification](VERIFICATION.md): required checks and what they prove.
- [Research](research/README.md), [contributing rules](AGENTS.md), and [third-party notices](THIRD_PARTY_NOTICES.md).
