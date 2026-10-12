# Rui

Rui (रुई, Hindi for cotton) runs coding-agent conversations on your machine. Ask it to investigate a project, run Bash commands, and save the answer. Close the terminal and work continues; return later to the same conversation.

Rui is written in Zig and saves messages, decisions and results in SQLite. After a Rui process crash, it recovers saved work without blindly repeating commands that may already have run.

## Status

Rui is in development. It supports Codex sign-in, interactive conversations, scripts, optional Bash approval and saved-result recovery. JavaScript workflows, a dedicated file-editing tool and structured answers are not available yet.

Supported platforms are Linux x86-64 and Apple Silicon macOS. Linux ARM64 and Intel macOS cross-builds are experimental. The live `gpt-6-luna` conversation, approved Bash and restart-recovery checks have passed on both supported platforms. Other models, live credential refresh and the complete mixed-workload qualification remain outstanding. See [test results and limitations](tests/qualification/README.md#current-checks-and-qualification).

Before using Rui on a project:

- Bash runs without approval by default. Enable approval as shown below if you want to review commands first.
- The project directory is not a sandbox. Commands have your user's access. Detached subprocesses and blocked I/O can outlast a stop request.
- If a crash leaves a command's outcome unknown, Rui reports it as indeterminate and does not automatically repeat it. OS-crash and power-loss recovery are not guaranteed.
- Full tool output is temporary. Saved results and excerpts remain available after that output is evicted or removed on restart.

## Build

Install Zig 0.16.0, Python 3, Perl, `patch`, a C toolchain and Make. From this repository:

```sh
zig build
zig build test-logic
```

The executable is `zig-out/bin/rui`. Use `rui --help` for command usage. The examples below use its absolute path so you can run it from your project directory.

## Start a conversation

From the Rui repository, sign in once:

```sh
RUI="$PWD/zig-out/bin/rui"
"$RUI" login codex
```

Follow the device-code instructions. Your account must have Codex access. Rui stores its credentials privately under `~/.config/rui/codex.json`.

Then move to the project you want to work on and start Rui:

```sh
cd /path/to/your/project
"$RUI"
```

This creates a fresh conversation in the current directory and starts or connects to Rui's background process. To review Bash commands before they run, enter this before your first request:

```text
/configure --permission-mode ask
```

Type a request at `›`, such as `Investigate the failing test`. In approval mode, Rui shows the proposed command and its working directory. Type `a` and Enter to allow it once, or `d` and Enter to deny it. Pasted choices do not grant approval.

| Command | What it does |
| --- | --- |
| `/help` | Lists available commands. |
| `/history` | Shows older conversation. |
| `/details` | Shows recent conversation with full saved tool output. |
| `/status` | Shows settings and current work. |
| `/requests` | Lists saved requests for recovery. |
| `/exit` or Ctrl+C | Closes the client without stopping background work. Unsent draft text is lost. |

You can edit and paste multiline text at the prompt. There is no input history or completion. For input longer than 64 KiB, use `message --text FILE`. If a submission is uncertain, Ctrl-R retries that same request rather than creating a new one.

## Return to your work

Rui calls a saved conversation a **Session**. To return to the newest Session created in your current project:

```sh
"$RUI" resume --last
```

Use `"$RUI" sessions` to list this project's Sessions, or `sessions --all` to include other projects. `"$RUI" resume SESSION_REF` opens an exact Session. Rui also prints an exact resume command when you leave.

Bare `rui` always creates a new Session. Existing Sessions keep their saved settings, including approval mode. `/setup` changes defaults for future Sessions, not the current one.

## Use Rui from scripts

For a fresh conversation that waits for an answer:

```sh
"$RUI" exec "Explain the build"
printf '%s' 'Explain the build' | "$RUI" exec -
```

`exec` writes answer text to stdout and recovery handles to stderr. It returns nonzero on failure, uncertainty or a permission block. It uses the same new-Session defaults, including Bash without approval. Use `--` before flag-like prompts or text equal to a command name.

For repeated work in an explicitly named Session with approval enabled:

```sh
STORE="$HOME/.local/share/rui/store"
"$RUI" host start --store "$STORE"
"$RUI" configure --store "$STORE" --session my/project --workspace "$PWD" \
  --provider codex --model gpt-6-luna --permission-mode ask
"$RUI" message --store "$STORE" --session my/project "Investigate the failing test"
"$RUI" follow SAVED_MESSAGE_HANDLE
"$RUI" result SAVED_MESSAGE_HANDLE
```

Replace `SAVED_MESSAGE_HANDLE` with the handle printed by `message`. Unlike `exec`, `message` returns after acceptance, not completion. `follow` and `result` stay attached to that message even after the Session does newer work. Add `--json` for machine-readable output where supported.

If approval is needed, inspect the reported Action ID before allowing it:

```sh
"$RUI" inspect-action --store "$STORE" --session my/project --action ACTION_ID
```

After reviewing the command, approve it once:

```sh
"$RUI" allow-action --store "$STORE" --session my/project --action ACTION_ID
```

Use `deny-action` instead to reject it, then `follow` the original message again. If a command loses its reply, use `requests` and `recover HANDLE` to retry the saved request. Do not submit a new message to guess whether the first arrived.

## Manage the background process

The **Host** runs work in the background. The **Store** is its private directory of saved state. Commands use an explicit `--store`, then your saved preference, then `$HOME/.local/share/rui/store`. Pin `--store` in scripts for a predictable destination.

```sh
"$RUI" host status
```

`host start` starts a Host with capacity for eight active executions, or connects to an existing one without changing its settings. It prints the diagnostic-log location. Rui does not install an OS service or restart a crashed Host automatically. If startup times out, inspect status and diagnostics; a timeout does not prove the Host stopped.

To shut down the Host and interrupt **all work in the selected Store**:

```sh
"$RUI" host stop
```

If the reply is lost, use the printed retry command. It targets the same Host instance so it cannot stop a replacement. An acknowledgment means shutdown was requested, not that cleanup has finished.

For foreground operation and explicit capacity, use `serve --store PATH --active-capacity 8 --codex`. Without `--codex` or a development endpoint, `serve` makes no model requests. See the [Host reference](ARCHITECTURE.md#platforms-and-server-lifetime) for startup and shutdown guarantees.

<a id="try-the-implemented-development-path"></a>

## Try Rui without a provider account

```sh
zig build bash-walkthrough
```

The walkthrough prints real CLI commands, approves one Bash action, saves its answer, crashes its own Host and recovers the same result. It uses a deterministic local provider and removes its temporary project and Store on success.

The crash occurs after the result and cleanup are saved. This checks saved-result recovery, not an interrupted command or power loss. See the [walkthrough's checks](VERIFICATION.md#runnable-bash-caller-acceptance-audit).

## Development direction

[Durable JavaScript workflows](https://github.com/DivyanshGolyan/rui/issues/273) remain in development. The private evaluator exists, but the production Host does not yet invoke it. The [delivery plan](https://github.com/DivyanshGolyan/rui/issues/164) tracks feature work separately from [full qualification](https://github.com/DivyanshGolyan/rui/issues/231).

Use [the subsystem test selector](VERIFICATION.md#canonical-gates) to choose checks for a change. Build/dependency changes and release qualification require additional evidence; a historical test result is not a pass for new code.

## Read next

- [Architecture](ARCHITECTURE.md): behavior, ownership and recovery, including the planned V1 contract.
- [Verification](VERIFICATION.md): required checks and what they prove.
- [Research](research/README.md): experiments and design sources.
- [Contributing rules](AGENTS.md) and [third-party notices](THIRD_PARTY_NOTICES.md).
