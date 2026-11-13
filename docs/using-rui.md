# Using the terminal conversation

This page covers the interactive `rui` client: its commands, input, screen, Sessions, models and context compaction.
For a first conversation, see [Start a conversation](../README.md#start-a-conversation).

## Keys

Open **Settings › Keys** for the full key list. In the overview, End then Enter opens the pinned Settings row; select the last **Keys** row and press Enter.
In a wide conversation, click the pinned Settings row without leaving the chat.
Esc returns to Settings; another Esc returns to the conversation or overview.
The footer shows the keys available in the current state. In a chat, a typed `?` is ordinary draft text, not a shortcut; on the overview, printable keys and paste do nothing.
There is no `/help` command.

## Commands

Enter these at the chat’s `›` prompt. The overview has no input or slash commands. Typing `/` lists chat commands with their descriptions beside loaded skills. Choice and option rows show their admitted names. `/discard` and `/recover KEY` stay unlisted behind the failed-send line.

| Command | What it does |
| --- | --- |
| `/archive` | Stops active work and archives this Session, confirming when required. |
| `/unarchive` | Restores this chat without restarting work. |
| `/rename NAME` | Names this Session. |
| `/copy [code\|file]` | Copies the last answer; `code` copies its last code block; `file` saves the answer here. |
| `/effort LEVEL` | Changes this chat’s effort and also sets the default for new chats. |
| `/model` | Opens this Session’s model picker, the same one as the footer model button and chat info. Choose a model to save it. |
| `/setup` | Shows or changes defaults for future Sessions, not the current one. |
| `/requests` | Lists saved requests for recovery. |
| `/result KEY` | Reads a saved answer. |
| `/reload-skills` | Rescans skills and appends catalog changes without model work. |
| `/new` | Starts a new empty chat; keeps the old chat unchanged. |
| `/clear` | Same as `/new`: starts a new empty chat, not deletion of history. |

Both `/new` and `/clear` use **+ New Session**’s creation owner. They send no Message until you type and send one in the new chat. Extra text, such as `/new foo`, is misuse. Loaded skill rows insert their names into the Message; they do not run an app command.

While the model works on a reply, the work line says `Thinking` with elapsed time.
Rate-limited retries keep their countdown, and running tools show their descriptions.

Tool outcomes start folded, showing their description and outcome, with a numeric failed exit when available.
Click a tool heading to open or close its saved output in place.
Ctrl-O toggles the lowest tool heading or opens the lowest collapsed Message or Session name in view, whichever is lower.
Several tools can stay open; new live output does not close them and the view keeps following it.
Output is safely escaped and indented, with at most 20 rows followed by `… N more lines` when needed.
Long lines end in `…`; the display prefix is also bounded to 8,192 bytes before invisible-cluster escaping.
Opened output uses the selvedge band; with NO_COLOR it keeps its indent without a band.
Folds belong only to the open conversation and are not saved.

Ctrl+C closes the client without stopping background work; unsent draft text is lost. Ctrl+D also leaves where the current input accepts it.

Select **Settings**, then **Version**, to check for and install a stable release. The same run is available with a conversation open; its status stays on the status row, and Esc cancels until publishing starts.

Upgrade installs the latest published stable release and uses the same restart-all owner as `rui host restart --all` for every eligible running same-user Host.
The check names the discovered Host count, Stores and unsupported reasons. Restart may interrupt all Sessions across those Stores; `--store` selects the client context, not the restart scope. No running Hosts means install only; absent Stores are not started.
The panel retains your draft, selected Session and unresolved capture handles without replaying uncertain effects.
It reports installation separately from activation, including when an application-owned or unsupported Host cannot be restarted safely.

## Chat info

Press **Alt+I** in a conversation, or click its Session/model/effort line or **alt+i info**, to open the same info panel above the input.
Clicking that line again while info is open leaves the panel and any open choice alone.
The panel has its own ground and never becomes part of the feed; your draft stays below it unchanged.
It uses only the height it needs, leaving recent messages visible above it.
Opening Model grows the panel into that feed space, and filtering gives space back; the input and bottom footer stay in place.
Its one footer replaces the usual chat footer below the input’s lower divider, on the physical last row; there is no second footer inside the panel or blank notice row below it.
Up and Down select Effort, Permissions, Tools or Model, and Enter opens the field's choices.
Folder is read-only: HOME is shown as `~`, and a long path keeps its right edge with a leading ellipsis.
It prefers whole trailing directory components; if the basename itself is too wide, it shows the longest grapheme-aligned basename suffix that fits, never an arbitrary right-side cut or an ellipsis hiding the whole name.
Context is read-only and appears only when a context estimate is available; a missing estimate is not shown as unknown or zero, while a known zero is shown as zero.
A blank row separates the fields from Rename, Archive and Copy last answer, including when those actions stack.
Model changes stay within the Session's provider.
Its filter is the Model field’s editable value, with indented matches below it and no separate `Filter:` row.
The list shrinks as matches narrow; a quiet `↓ N more` only reports models below the viewport.
Esc closes an open choice first, then the panel.
The panel contains no Session IDs, Store paths or request-recovery records; use `/requests` for recovery handles.
While an original submission is held unresolved or rejected, **Alt+D** or the footer’s **alt+d details** opens its separate repair and identity page, not chat info.
An environment-too-large notice also has clickable **details**.

## Approve Bash commands

By default, Bash runs without asking (`bypass`).
To review each command first, open chat info with **Alt+I**, select **Permissions**, press Enter and choose **ask first** before your first request in each new Session.

Rui then shows each proposed command above an Allow once / Deny choice, with Allow once highlighted. ← and → move the highlight and Enter confirms it.
Enter confirms only the option on screen.
An arrow or Enter pressed before the choice is ready decides nothing: Rui says `! Not ready; nothing authorized.` and the choice counts keys again once it is redrawn.
Every key spends that readiness, an arrow included, so after ← or → Enter counts once the moved highlight is drawn.
Typing or pasting never decides: it goes to your draft, where slash commands still run, and Esc or Ctrl-G returns to the choice.
A command that arrives while you are writing a message leaves your draft in place, so the Enter meant for it approves nothing; Esc or Ctrl-G shows the choice.

## Input

You can edit and paste multiline text at the prompt.
On an empty prompt, Ctrl-P brings back the last message you sent, for editing, and Ctrl-P again goes further back; Ctrl-N goes forward, and past your newest message the prompt is empty again.
Messages from other Sessions never come back this way.
There is no completion.
For input longer than 64 KiB, redirect a file into `rui session send --to ID < FILE`.
If a submission is uncertain, Ctrl-R retries that same request instead of creating a new one.

## Screen and scrolling

The conversation uses the full terminal screen.
When you exit, your shell's screen returns as it was, and conversation text does not stay in your terminal's scrollback.

Scroll with PgUp, PgDn, the arrow keys or the mouse wheel.
Keep scrolling up to read older conversation in the same feed.
While you are scrolled up, `↓ N new` counts arriving rows; click it to return to the end.
Esc or Ctrl-G returns to the latest messages, and from there to the overview.
Ctrl-End, or End on an empty draft, returns to the latest messages and stays in the conversation.

Normal exit, Ctrl-C and SIGTERM restore the previous screen.
SIGKILL and native crashes cannot run cleanup.
If that happens, run your terminal's reset command.

## Sessions

Rui calls a saved conversation a **Session**.
Bare `rui` opens the overview of unarchived Sessions in this Store; each row shows its project.
Select the pinned **+ New Session** at the top with Home, then Enter, or click it, to create an empty Session and open its focused chat input.
Creating it sends configuration only: it has no Messages until you type and send one in the chat.
Sessions without a first Message are omitted from the list, except for the currently open chat’s selected row in a wide sidebar.
That row is named **New Session**, never its raw reference; after the first Message is admitted it uses the normal conversation name.
Leaving an empty chat hides its row even after changing its model or effort; the configured Session stays stored and remains available to CLI list, inspect and resume.
The empty chat footer shows its model, effort and folder; model and effort are buttons for changing that Session’s settings.
An existing populated chat keeps its usual footer.
Enter on a Session row opens it, and Esc returns to the overview.
**Settings** stays on the penultimate row, immediately above the list footer; there is no composer, hidden draft, model/effort footer or footer buttons on the overview.
The overview list uses the full width at every terminal size, with no empty chat pane. A wide chat or its settings keeps the list sidebar’s existing navigation, without an input of its own.
`rui session resume` still opens one Session directly, inside the overview.

| Key in the overview | What it does |
| --- | --- |
| Up, Down, Home, End | Move through the whole list, including pinned **+ New Session** and **Settings**. |
| Shift-Up, Shift-Down | Select the row above or below. |
| Enter | Opens the selected Session, creates an empty chat from **+ New Session**, or opens **Settings**. In Settings, open **Model** to pick the default for future Sessions. |
| Esc, Ctrl-G | Closes the topmost choice or panel; no draft or per-start settings exist to clear. |
| Ctrl-X | Stops the selected Session’s work through the same request owner as the CLI. |
| Ctrl-D, Ctrl-C | Leaves. |

Printable keys, including `/` and `?`, and bracketed paste are ignored on the list: they cannot start work or create a draft.
While empty-Session creation awaits its answer, another Enter or click cannot create it again.
A rejected creation shows its failure; an unconfirmed creation retains its original recovery key rather than fabricating a Message receipt.

A stop works like `rui session stop`: if its reply is lost, the overview says it is not sure the Session stopped, and prints the `rui request recover` command when you leave.
To stop every Session that Ctrl-X could stop at once, run `rui session stop --all`.
A stop still waiting to be sent when you leave is reported as not sent.
The overview holds at most eight creation and stop requests awaiting answers, and refuses more until one is answered.
Sessions the stopped Session messaged keep running.

The overview paints its own colours, in khadi: an indigo ground with cotton text on a dark terminal, a cotton ground with indigo ink on a light one.
It asks the terminal for its background as it opens and uses night when the terminal does not say.
It uses 24-bit colour when `COLORTERM` is `truecolor` or `24bit`, and the nearest 256 colours otherwise.
`NO_COLOR` keeps the terminal's own colours, with bold and reverse only.
A conversation you open shows your terminal's own colours, and so does the shell after you leave.

The top of the overview says whether anything works and what failed, the Host's uptime and slots in use, and how many Sessions are in each state.
Counts are grouped the Indian way (1,00,000).

The title reads रुई rui.
Set your terminal's font to IBM Plex Mono if you can: the overview was drawn in it, and रुई takes the two cells there that Rui measures.
Under an ASCII locale (`LANG=C`) the title reads `rui` alone.

```sh
rui session resume SESSION_REF     # an exact Session
rui session list                   # this project's Sessions, as JSON
rui session list --all             # Sessions from every project
```

Existing Sessions keep their saved settings, including approval mode and model.

### Archive Sessions

Select a Session in the overview and press **Alt+A**.
If it has work, confirm **Stop and archive**.
The Session stays visible until the stop completes.
You can also press **Alt+A** or enter `/archive` inside its conversation.
Alt+A keeps your draft intact.
For **Stop and archive**, press Enter to confirm or Esc to cancel; neither sends or clears your draft.

The overview shows unarchived Sessions; its former `/sessions`, `/archive`, `/unarchive` and other overview slash commands are gone.
Use the shell commands below to list archived Sessions or restore one without starting work.
Inside an open chat, `/archive` and `/unarchive` still act on that Session.

Archive keeps history, saved results, settings, and files.
Opening an archived Session does not restore it.
Sending a new Message restores it, but a Message sent while it is still archiving is rejected.

From a script, use these commands.

```sh
rui session archive --session SESSION_REF
rui session list --archived
rui session list --include-archived
rui session unarchive --session SESSION_REF
```

`--all` still means every Workspace, not archived Sessions.

## Models

To list the model IDs this release knows, run `rui session configure --help`.
The list is compiled into Rui and needs no Host or credentials.
It does not mean that your account can use every listed model.

Rui also takes a model it does not list, such as one your provider's model list offers.
It says `Rui does not list ID; it uses default limits`, and runs that model with a 128,000-token context.
If the provider does not know the ID, the Session's first request fails and says to pick another in the overview’s app settings **Model** field.

Without `--model`, a new Session uses your saved default.
With no saved default, it uses `gpt-6.1-sol`.
To pick the default from a list, open **Settings** in the overview and press Enter on **Model**.

To switch an existing Session within its provider, select **Model** in chat info, or run `rui session configure --session SESSION --model ID`.
The next model request replays visible conversation without the old model’s private reasoning or compacted state.
This preserves the Session and its attached agents, but costs one cache miss.

To change the saved default from the shell, run `rui defaults configure --model ID`.
To remove it, run `rui defaults configure --clear-model`.

## Defaults for future Sessions

App settings changes saved defaults without changing existing Sessions.
The Permissions row, between Effort and Notifications, offers **run without asking** and **ask first**.
Press Enter to open the choices, then Enter to save one.

From the shell, use `rui defaults configure`; in a chat’s composer, use `/setup`.
Both accept `--store PATH`, `--provider PROVIDER`, `--model ID`, `--clear-model`,
`--reasoning-effort LEVEL|default`, `--permission-mode ask|bypass`, and `--notifications on|off`.
`--clear-model` cannot be combined with `--model`.
For example, `/setup --permission-mode ask` makes new Sessions ask before running Bash.
An explicit `--permission-mode` on a new Session wins over the saved choice; without either, Rui runs without asking.
`rui defaults inspect` reads the saved defaults without changing them.

Signing in with `rui auth login PROVIDER` saves that provider as the default when none is saved.
`rui auth login chatgpt` also replaces a saved `codex` default, since both sign in to the same ChatGPT account, and clears a model saved for Codex.
Any other saved provider stays; the sign-in says so and names the command that changes it, such as `rui defaults configure --provider chatgpt`.
Existing Sessions keep their provider.

## Notifications

When the terminal running Rui is out of focus, the overview or an open conversation sends a desktop notification when a Session finishes, fails or needs approval. iTerm2, kitty, WezTerm and Ghostty show it as a desktop notification and foot through its notify command.
Other terminals, and tmux, get a bell.
Rui learns about focus only from the terminal's focus reports, so a terminal or multiplexer that sends none gets no notifications.
In tmux, set `focus-events on` to get them.
To turn them off, run `rui defaults configure --notifications off`, or enter `/setup --notifications off`.

## Context compaction

When model context grows too large, Rui compacts it.
Compaction never deletes saved conversation history.
The release-supported Codex model IDs start compaction at an estimated 244,800 tokens, except `gpt-6.1-terra`, which starts at 450,000.
A model Rui does not list is assumed to have a 128,000-token context, so it starts compaction at an estimated 115,200 tokens unless you set a threshold.
A context-overflow error from the provider can still start compaction.

To change the threshold for the current Session, use the shell:

```sh
rui session configure --session SESSION --compaction-trigger 200000 --output-reservation 8000
rui session inspect --session SESSION
```

The trigger is an estimate, not a limit on message size.
The output reservation adds headroom to that estimate.
It does not guarantee an output budget.
Rui never truncates messages to fit.

To return to the provider and model defaults:

```sh
rui session configure --session SESSION --compaction-trigger default --output-reservation default
```

Omitting either flag keeps its current setting.
Changes apply to new model requests, not to requests already admitted.
Scripts use the same flags with `rui session configure`, and `rui session inspect` reports the effective values and overrides.

If the retained input still cannot fit after compaction, the request fails with an error.
Rui does not compact unchanged input again.

### Loading tools on demand

The built-in catalog, in name order, is `bash`, `find_tools`, `message_agent`, `read_transcript`, `skill`, `start_agent`, `web_search`.
Fresh Sessions default to `bash`, `skill` and `web_search`.

Set `--tools` to the tools a Session may use and `--loaded-tools` to the subset
initially offered to its model.
A strict subset must include `find_tools`, so the model can discover the remaining tools.
For example:

```sh
rui session configure --store "$RUI_STORE" --session "$RUI_ADDRESS" \
  --tools bash,find_tools,message_agent,read_transcript,skill,start_agent,web_search \
  --loaded-tools bash,find_tools
```

The model calls `find_tools({"words":"transcript message"})` to load up to eight
available tools whose saved names or descriptions contain either search word,
ignoring ASCII case.
Words are split on ASCII spaces; supply one to eight, at most 64 bytes each.
The result lists loaded names and description previews.
They become callable on the next request.
Searches that find nothing report how many tools remain unloaded.

## Skills

Rui advertises valid skills from your repository's `.agents/skills` and the Host user's `~/.agents/skills` when a Session is created.
A repository skill wins a same-name home skill; other roots, including `.claude`, are not scanned.
Each skill directory contains a `SKILL.md` with required YAML `name` and `description`.
Optional metadata cannot grant permissions or tools; `disable-model-invocation` is ignored.

Write `/NAME` anywhere in a Message to invoke that skill: the model reads its full current `SKILL.md` and absolute path right after your text, which stays as you typed it. A `/word` that names no skill, such as a path, stays text; see [scripting](scripting.md#invoke-and-reload-skills).
The model can invoke the `skill` tool when your chosen tool set includes it.
Skills run nothing on load and do not bypass approvals.
Use `/reload-skills` to refresh this Session's advertised names, descriptions and paths without starting a model turn.
Only changes append a new catalog instruction; editing only a body needs no reload before the next invocation.
Earlier catalog instructions and invocation results stay unchanged, and skills receive no special retention during compaction.
