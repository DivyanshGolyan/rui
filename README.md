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

## Install from source

Requires Zig 0.17.0, Python 3.11 or newer, Git, curl, Perl, `patch`, a C toolchain and Make. On macOS, install the Xcode command-line tools with `xcode-select --install` if needed. Ensure `python3` on PATH selects the newer interpreter, not Apple's Python 3.9. The build pins native dependencies.

From the checkout you want to install, run:

```sh
./install.sh
export PATH="$HOME/.local/bin:$PATH"
```

To use `rui` in future shells, add the PATH line to your shell profile if `~/.local/bin` is not already on PATH. Then [start a conversation](#start-a-conversation).

Run `./install.sh` again to update. It builds the current checkout, including local changes; it does not fetch or switch branches. It prepares the selected Zig cache, validates the built command, and replaces `~/.local/bin/rui` and its evaluator with links to a complete build under `~/.local/lib/rui`. Failed builds leave the previous installation unchanged. Earlier installed builds remain available because running processes may still use them.

Installation preserves Stores, credentials and shell profiles. It reports the selected Store's Host status without starting or stopping anything. A running Host retains its old executable. After its work finishes, run `rui host stop`, wait for `rui host status` to report unavailable, then start `rui` again. If your shell still runs an older command, inspect `type -a rui` and run `rehash` in Zsh or `hash -r` in Bash.

## Build

After [installation](#install-from-source) has prepared the dependencies, build a development binary and run portable checks from this repository. For build-only dependency preparation, use the [empty-cache steps](VERIFICATION.md#canonical-gates).

```sh
zig build
zig build test-logic
```

The build uses stock Zig 0.17.0 and the pinned official `translate-c` package for C bindings. Compiler objects use `ZIG_GLOBAL_CACHE_DIR`; extracted dependencies use `zig-pkg` or `ZIG_LOCAL_PKG_DIR`. Zig 0.17 removed `--global-cache-dir` from `zig build` and `zig fetch`.

ZLS project integration is not supported for this toolchain yet. As of October 14, 2026, upstream master targets Zig 0.17 but disables build-configuration loading with a compile error tracked in [ZLS #3208](https://github.com/zigtools/zls/issues/3208). The latest ZLS release targets Zig 0.16. Use `zig fmt`, `zig build` and the selected test targets for compiler-backed feedback. The experimental ZLS workaround requires a forked compiler and is not part of Rui's supported setup.

The development executable is `zig-out/bin/rui`. Use `rui --help` for command usage. The examples below use the installed command; set `RUI="$PWD/zig-out/bin/rui"` instead to try a development build.

## Start a conversation

Sign in once, unless you already signed in with Rui:

```sh
RUI="$HOME/.local/bin/rui"
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

Rui opens an alternate-screen conversation with a multiline composer. Type a request at `›`, such as `Investigate the failing test`. In approval mode, Rui shows the proposed command and its working directory. After the complete eligible Action frame is rendered, type a fresh `a` and Enter to allow it once, or `d` and Enter to deny it. Pasted or queued choices do not grant approval. Approval pauses while an inspection hides the Action.

Actions whose display exceeds 256 KiB have a bounded preview and cannot be approved in-app. `/help` supplies exact-target shell commands to inspect the complete Action, allow it once, or deny it. Detach before running those commands. Saved arguments and results remain unchanged.

| Command | What it does |
| --- | --- |
| `/help` | Lists available commands. |
| `/history` | Shows older conversation. |
| `/details` | Shows recent conversation with full saved tool output. |
| `/status` | Shows settings and current work. |
| `/requests` | Lists saved requests for recovery. |
| `/exit` or Ctrl+C | Closes the client without stopping background work. Unsent draft text is lost. |

Enter sends; Shift-Enter or Alt-J adds a line. You can edit and paste multiline text at the prompt. PgUp and PgDn browse the bounded conversation or inspection, and Ctrl-G returns to the latest conversation or pending Action. Resize may reset browsing but preserves draft bytes and caret. There is no input history or completion. For input longer than 64 KiB, use `message --text FILE`. If a submission is uncertain, Ctrl-R retries that exact original request, independently of the next draft.

Rui asks the terminal whether it measures joined Unicode characters, such as emoji, as one cluster. This terminal feature is called mode 2027. Rui uses the answer to choose matching character widths; if the feature is disabled or the terminal does not answer, it uses conventional character widths. Rui does not change the setting, and you do not need to choose a Rui option. Some terminal emulators remain unqualified. Characters that cannot fit safely are rejected rather than assigned invented widths. Drawing errors end the client after terminal restoration; Rui does not retry a partial frame. Normal CLI and script output and exact saved-content exports do not use this display bound.

The alternate-screen renderer is work in progress. Native PTY checks have run on Linux and macOS, but final cross-platform qualification remains incomplete. These checks do not qualify physical terminal display behavior.

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
