# Using the terminal conversation

This page covers the interactive `rui` client: its commands, input, screen, Sessions, models and context compaction.
For a first conversation, see [Start a conversation](../README.md#start-a-conversation).

## Keys

Open **Settings › Keys** for the full key list. In the overview, End then Enter opens the pinned Settings row; select the last **Keys** row and press Enter.
In a wide conversation, click the pinned Settings row without leaving the chat.
Esc returns to Settings; another Esc returns to the conversation or overview.
The footer shows the keys available in the current state. A typed `?` is ordinary draft text, not a shortcut.
There is no `/help` command.

## Commands

Typing `/` lists loaded skills and `/reload-skills` only. A skill row fills its name into the Message; `/reload-skills` refreshes skills. App actions are clicks and keys on the screen: chat info contains Rename, Archive and Copy last answer, and Settings contains defaults and Version.

Unlisted fallbacks remain until those screens have equivalent controls: `/requests` in a conversation; `/configure` and `/sessions` in the overview. They are not offered by `/`. Failed-send retry and discard remain on the failed-send line.

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

Upgrade installs the latest published stable release and restarts the selected Store's Host only if it is already running and its launch is supported.
Restart affects all Sessions in that Store and may interrupt work; no running Host means install only.
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
Type in its composer to start a new Session; Enter on a row opens one, and Esc returns.
Ctrl-X stops the selected Session, and Ctrl-D leaves.
`rui session resume` still opens one Session directly, inside the overview.

| Key in the overview | What it does |
| --- | --- |
| Up, Down, Home, End | Select a Session while the composer is empty. In a draft, Home and End move the caret, and Up and Down select a Session once past its first or last line. While a start waits for its answer, all four select. |
| Shift-Up, Shift-Down | Select the Session above or below, whatever the composer holds. |
| Enter | Sends the composer's text: a task starts a new Session, and `/configure` sets the next start's settings. Select **Settings** in the overview, then its **Model** field, to pick the default for new Sessions; type to filter, use ↑ and ↓ to move, and Enter to save. Esc closes the choice before settings. On a blank composer, opens the selected Session. |
| Esc, Ctrl-G | Clears the composer's draft. On an empty composer, clears the settings `/configure` held. A start already sent keeps its own text and settings. In a conversation's latest view, returns to the overview. |
| Ctrl-X | Asks to stop the selected Session while it works, waits or needs approval. Press Ctrl-X again to stop it; any other key cancels. The row reads `stopping` until the Host answers, then `■ stopped`; if the stop fails, a message says why and the row keeps its state. On any other row a message says why nothing was stopped. |
| Ctrl-D | Leaves, when the composer is empty or a start waits for its answer. |
| Ctrl-C | Leaves. |

While a start waits for its answer, its text stays in the composer and typing does not change it; if the start fails, Enter sends the text again.
A key not in this table does nothing in the overview.

A stop works like `rui session stop`: if its reply is lost, the overview says it is not sure the Session stopped, and prints the `rui request recover` command when you leave.
To stop every Session that Ctrl-X could stop at once, run `rui session stop --all`.
A stop still waiting to be sent when you leave is reported as not sent.
The overview holds at most eight starts and stops awaiting answers, and refuses more until one is answered.
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

Select a Session in the overview and press **Alt+A**, or use **Archive** in its chat info panel. Alt+A also works inside a conversation and keeps your draft intact. A busy Session stops and archives immediately, without confirmation; it stays visible until the stop completes.

Use `/sessions archived` to show archived Sessions, `/sessions all` to show both views, or `/sessions unarchived` to return.
Open the archived Session, then click **Restore** in its footer.

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

From the shell, `rui defaults configure` accepts `--store PATH`, `--provider PROVIDER`, `--model ID`, `--clear-model`,
`--reasoning-effort LEVEL|default`, `--permission-mode ask|bypass`, and `--notifications on|off`.
`--clear-model` cannot be combined with `--model`.
For example, `rui defaults configure --permission-mode ask` makes new Sessions ask before running Bash.
An explicit `--permission-mode` on a new Session wins over the saved choice; without either, Rui runs without asking.
`rui defaults inspect` reads the saved defaults without changing them.

## Notifications

When the terminal running Rui is out of focus, the overview or an open conversation sends a desktop notification when a Session finishes, fails or needs approval. iTerm2, kitty, WezTerm and Ghostty show it as a desktop notification and foot through its notify command.
Other terminals, and tmux, get a bell.
Rui learns about focus only from the terminal's focus reports, so a terminal or multiplexer that sends none gets no notifications.
In tmux, set `focus-events on` to get them.
To turn them off, run `rui defaults configure --notifications off`, or select **Notifications** in Settings.

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
