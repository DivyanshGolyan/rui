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

Rui then shows each proposed command above an Allow once / Deny choice, with Allow once highlighted. ← and → move the highlight and Enter confirms it. Enter confirms only the option on screen. An arrow or Enter pressed before the choice is ready decides nothing: Rui says `! Not ready; nothing authorized.` and the choice counts keys again once it is redrawn. Every key spends that readiness, an arrow included, so after ← or → Enter counts once the moved highlight is drawn. Typing or pasting never decides: it goes to your draft, where slash commands still run, and Esc or Ctrl-G returns to the choice. A command that arrives while you are writing a message leaves your draft in place, so the Enter meant for it approves nothing; Esc or Ctrl-G shows the choice.

## Input

You can edit and paste multiline text at the prompt. There is no input history or completion. For input longer than 64 KiB, redirect a file into `rui session send --to ID < FILE`. If a submission is uncertain, Ctrl-R retries that same request instead of creating a new one.

## Screen and scrolling

The conversation uses the full terminal screen. When you exit, your shell's screen returns as it was, and conversation text does not stay in your terminal's scrollback.

Scroll with PgUp, PgDn, the arrow keys or the mouse wheel. Keep scrolling up to read older conversation. Esc or Ctrl-G returns to the latest messages, and from there to the overview. Ctrl-End, or End on an empty draft, returns to the latest messages and stays in the conversation.

Normal exit, Ctrl-C and SIGTERM restore the previous screen. SIGKILL and native crashes cannot run cleanup. If that happens, run your terminal's reset command.

## Sessions

Rui calls a saved conversation a **Session**. Bare `rui` opens the overview of every Session in this Store; each row shows its project. Type in its composer to start a new Session; Enter on a row opens one, and Esc returns. Ctrl-X stops the selected Session, and Ctrl-D leaves. `rui session resume` still opens one Session directly, inside the overview.

| Key in the overview | What it does |
| --- | --- |
| Up, Down, Home, End | Select a Session while the composer is empty. In a draft, Home and End move the caret, and Up and Down select a Session once past its first or last line. While a start waits for its answer, all four select. |
| Shift-Up, Shift-Down | Select the Session above or below, whatever the composer holds. |
| Enter | Sends the composer's text: a task starts a new Session, and `/configure` sets the next start's settings. On a blank composer, opens the selected Session. |
| Esc, Ctrl-G | Clears the composer's draft. On an empty composer, clears the settings `/configure` held. A start already sent keeps its own text and settings. In a conversation's latest view, returns to the overview. |
| Ctrl-X | Asks to stop the selected Session while it works, waits or needs approval. Press Ctrl-X again to stop it; any other key cancels. The row reads `stopping` until the Host answers, then `■ stopped`; if the stop fails, a message says why and the row keeps its state. On any other row a message says why nothing was stopped. |
| Ctrl-D | Leaves, when the composer is empty or a start waits for its answer. |
| Ctrl-C | Leaves. |

While a start waits for its answer, its text stays in the composer and typing does not change it; if the start fails, Enter sends the text again. A key not in this table does nothing in the overview.

A stop works like `rui session stop`: if its reply is lost, the overview says it is not sure the Session stopped, and prints the `rui request recover` command when you leave. A stop still waiting to be sent when you leave is reported as not sent. The overview holds at most eight starts and stops awaiting answers, and refuses more until one is answered. Sessions the stopped Session messaged keep running.

The overview paints its own colours, in khadi: an indigo ground with cotton text on a dark terminal, a cotton ground with indigo ink on a light one. It asks the terminal for its background as it opens and uses night when the terminal does not say. It uses 24-bit colour when `COLORTERM` is `truecolor` or `24bit`, and the nearest 256 colours otherwise. `NO_COLOR` keeps the terminal's own colours, with bold and reverse only. A conversation you open shows your terminal's own colours, and so does the shell after you leave.

The top of the overview says whether anything works and what failed, the Host's uptime and slots in use, and how many Sessions are in each state. When a Session fails or the Host restarts while you are not touching the keyboard, a "Since you looked" line says so until your next key. Counts are grouped the Indian way (1,00,000).

The title reads रुई rui. Set your terminal's font to IBM Plex Mono if you can: the overview was drawn in it, and रुई takes the two cells there that Rui measures. Under an ASCII locale (`LANG=C`) the title reads `rui` alone.

```sh
rui session resume SESSION_REF     # an exact Session
rui session list                   # this project's Sessions, as JSON
rui session list --all             # Sessions from every project
```

Existing Sessions keep their saved settings, including approval mode and model.

## Models

To list this release's supported model IDs, run `rui session configure --help`. The list is compiled into Rui and needs no Host or credentials. It does not mean that your account can use every listed model.

Without `--model`, a new Session uses your saved default. With no saved default, it uses `gpt-6.1-sol`.

If Host startup warns that a saved model default is unsupported, pick a listed ID:

```sh
rui defaults configure --model ID
```

To remove the saved default instead, run `rui defaults configure --clear-model`. Rui keeps the old default until you change it.

## Notifications

When the terminal running Rui is out of focus, the overview or an open conversation sends a desktop notification when a Session finishes, fails or needs approval. iTerm2, kitty, WezTerm and Ghostty show it as a desktop notification and foot through its notify command. Other terminals, and tmux, get a bell. Rui learns about focus only from the terminal's focus reports, so a terminal or multiplexer that sends none gets no notifications. In tmux, set `focus-events on` to get them. To turn them off, run `rui defaults configure --notifications off`, or enter `/setup --notifications off`.

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
