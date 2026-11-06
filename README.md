# Rui

Rui (रुई, Hindi for cotton) runs coding-agent conversations on your machine.
Ask it to investigate a project or run Bash commands, and it saves every message, decision and result in SQLite.
Close the terminal and the work keeps running in the background.
Come back later to the same conversation.

If Rui crashes, it recovers the saved work.
It never reruns a command whose outcome it cannot confirm.

## Status

Rui is in development.
It supports Codex sign-in, interactive conversations, scripts, optional Bash approval and saved-result recovery.
A file-editing tool and structured answers are not available yet.

Rui supports Apple Silicon macOS and x86-64 Linux.
Builds for ARM64 Linux and Intel macOS are experimental.
On both supported platforms, a live `gpt-6-luna` conversation, approved Bash and restart recovery have passed.
Other models, live credential refresh and the full mixed-workload qualification have not.
See [test results and limitations](tests/qualification/README.md#current-checks-and-qualification).

Before you use Rui on a project, know its limits:

- Commands run with your user's full access.
  The project directory is not a sandbox, and a detached subprocess or blocked I/O can outlast a stop request.
- If a crash leaves a command's outcome unknown, Rui reports it as indeterminate and does not rerun it.
  Rui does not promise recovery from an OS crash or power loss.
- Full tool output is temporary.
  Saved results and excerpts remain after Rui drops it.

## Install

You need an Apple Silicon Mac with macOS 15 or newer, or x86-64 Linux with glibc 2.34 or newer, such as Ubuntu 22.04, Debian 12 or RHEL 9.

```sh
curl -fsSL https://github.com/DivyanshGolyan/rui/releases/latest/download/install.sh | sh
```

The installer puts `rui` in `~/.local/bin` and checks the download's SHA-256 digest.
If `~/.local/bin` is not on your `PATH`, it prints the line to add to your shell profile.

Run `rui upgrade --check` to inspect the latest published stable release without installing it or starting a Host.
Run `rui upgrade` to update an eligible released installation under `~/.local` and, only if the selected Store already has a running supported Host, restart that Host.
A selected source build or managed build with unknown release identity is not upgraded automatically; run the standalone release installer above to deliberately switch it to a release.
Package-provided and custom binaries remain their application's responsibility.
The restart affects every Session in that Store and can interrupt work.
For an eligible installation with no running Host, Upgrade only installs.
The terminal's `/upgrade` panel offers Install and Cancel in both the overview and conversation.
Installation and activation are separate: an unsupported or application-owned Host launch is not blindly stopped and is reported as installed but not activated.
The manual release installer above and source installation remain install-only.

Updates keep saved work and sign-in; retained earlier builds are not an unconditional rollback after a Store migration.
The target build's schema determines compatibility, not version punctuation: supported SQLite formats are backed up and migrated at Host startup, while MySQL schema changes are operator-owned.
If target compatibility facts are unavailable, compatibility is unknown until startup validates it.
Run `rui --version` to see what you have.

## Start a conversation

1. Sign in once with your ChatGPT account.
   Rui uses OpenAI's device code login, which you must enable first.
   Turn on device code authorization for Codex in your ChatGPT security settings.
   On a workspace account, an admin allows it in the workspace permissions instead.
   Then run:

	```sh
	rui auth login codex     # or: rui auth login openai, to use an OpenAI API key
	```

	Open the link it prints, sign in and enter the code.
	Never share the code.
	See [OpenAI's Codex sign-in guide](https://learn.chatgpt.com/docs/auth) if the setting is missing.

2. Go to your project and start Rui:

	```sh
	cd /path/to/your/project
	rui
	```

3. Type a request at the `›` prompt, such as `Investigate the failing test`.

Bash runs in your terminal's environment, so the agent finds the tools your shell finds.
A tool you install or a venv you activate reaches the agent with your next message.
The environment stays in memory and is never saved.

By default, Bash runs without asking.
To approve each command, enter `/configure --permission-mode ask` before your first request.
Rui then shows each command above an Allow once / Deny choice: ← and → pick one, and Enter confirms it.

To leave, type `/exit` or press Ctrl+C.
Work continues in the background.
Run `rui` again to see your unarchived conversations and press Enter on one to return to it.

## Archive a conversation

In the overview, select a Session and enter `/archive`.
If it has work, confirm **Stop and archive**.
Rui waits for the stop to complete before it hides the Session.

Use `/sessions archived` to find archived Sessions, or `/sessions all` to show both views.
Enter `/unarchive` to restore a Session without starting work.
Sending a new Message to an archived Session also restores it.
Archive keeps the conversation history and files.

## Build from source

See [Developing Rui](docs/development.md) to build and install from source, run tests, or try Rui without a provider account.

## Learn more

- [Using the terminal conversation](docs/using-rui.md): commands, scrolling, Sessions, models and context compaction.
- [Using Rui from scripts and agents](docs/scripting.md): one-shot commands, results, approvals and recovery.
- [Running the Host](docs/host.md): the background process, its Store and failed-response diagnostics.
- [Start fresh after a Store format change](docs/store-reset.md).
- [Architecture](ARCHITECTURE.md): behavior, ownership and recovery, including the planned V1 contract.
- [Verification](VERIFICATION.md): required checks and what they prove.
- [Research](research/README.md), [contributing rules](AGENTS.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
