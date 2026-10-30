# Using the terminal conversation

This page covers the interactive `rui` client: its commands, input, screen, Sessions, models and context compaction. For a first conversation, see [Start a conversation](../README.md#start-a-conversation).

## Commands

Enter these at the `›` prompt.

| Command | What it does |
| --- | --- |
| `/help` | Lists available commands. |
| `/history` | Shows older conversation. |
| `/details` | Shows recent conversation with full saved tool output. |
| `/status` | Shows settings, including the Bash permission mode, and current work. |
| `/requests` | Lists saved requests for recovery. |
| `/configure` | Changes settings for the current Session only. |
| `/setup` | Changes defaults for future Sessions, not the current one. |
| `/exit` or Ctrl+C | Closes the client without stopping background work. Unsent draft text is lost. |

## Approve Bash commands

By default, Bash runs without asking (`bypass`). To review each command first, enter this before your first request in each new Session:

```text
/configure --permission-mode ask
```

Rui then shows each proposed command and its working directory. Type `a` and Enter to allow it once, or `d` and Enter to deny it. Pasted choices do not grant approval.

## Input

You can edit and paste multiline text at the prompt. There is no input history or completion. For input longer than 64 KiB, redirect a file into `rui session send --to ID < FILE`. If a submission is uncertain, Ctrl-R retries that same request instead of creating a new one.

## Screen and scrolling

The conversation uses the full terminal screen. When you exit, your shell's screen returns as it was, and conversation text does not stay in your terminal's scrollback.

Scroll with PgUp, PgDn, the arrow keys or the mouse wheel. Keep scrolling up to read older conversation. Esc returns to the latest messages, and from there to the overview.

Normal exit, Ctrl-C and SIGTERM restore the previous screen. SIGKILL and native crashes cannot run cleanup. If that happens, run your terminal's reset command.

## Sessions

Rui calls a saved conversation a **Session**. Bare `rui` opens the overview of every Session in this Store; each row shows its project. Type in its composer to start a new Session; Enter on a row opens one, and Esc returns. Ctrl-X stops the selected Session, and Ctrl-D leaves. `rui session resume` still opens one Session directly, inside the overview.

```sh
rui session resume SESSION_REF     # an exact Session
rui session list                   # this project's Sessions, as JSON
rui session list --all             # Sessions from every project
```

Existing Sessions keep their saved settings, including approval mode and model.

## Models

To list this release's supported model IDs, run `rui session configure --help`. The list is compiled into Rui and needs no Host or credentials. It does not mean that your account can use every listed model.

Without `--model`, a new Session uses your saved default. With no saved default, it uses `gpt-6-luna`.

If Host startup warns that a saved model default is unsupported, pick a listed ID:

```sh
rui defaults configure --model ID
```

To remove the saved default instead, run `rui defaults configure --clear-model`. Rui keeps the old default until you change it.

## Context compaction

When model context grows too large, Rui compacts it. Compaction never deletes saved conversation history. All eight release-supported Codex model IDs start compaction at an estimated 244,800 tokens. Unknown model names have no automatic threshold unless you set one. A context-overflow error from the provider can still start compaction.

To change the threshold for the current Session, enter:

```text
/configure --compaction-trigger 200000 --output-reservation 8000
/status
```

The trigger is an estimate, not a limit on message size. The output reservation adds headroom to that estimate. It does not guarantee an output budget. Rui never truncates messages to fit.

To return to the provider and model defaults, enter:

```text
/configure --compaction-trigger default --output-reservation default
```

Omitting either flag keeps its current setting. Changes apply to new model requests, not to requests already admitted. Scripts use the same flags with `rui session configure`, and `rui session inspect` reports the effective values and overrides.

If the retained input still cannot fit after compaction, the request fails with an error. Rui does not compact unchanged input again.
