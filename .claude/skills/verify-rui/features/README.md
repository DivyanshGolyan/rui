# Rui renderer verification map

The maintained source for verifying Rui's full-screen interactive terminal. Read [../SKILL.md](../SKILL.md) for launch, doctor, evidence and cleanup, then use the matching feature file as the recipe.

## Screens

Use these names when describing a change or a screenshot. Panels and notices count here when they give the user a distinct set of actions.

| Screen | How to get there | Main actions (keyboard and mouse) | Feature |
| --- | --- | --- | --- |
| Overview | Run `rui`; Esc back from a chat | Up/Down, Home/End select; Enter or click opens; Right opens a chat; Alt-Up/Down switch; Ctrl-X stops; Alt-A archives | [Overview and session list](./overview.md) |
| Chat | Open a list row or **+ New Session** | Type and Enter send; Shift-Enter adds a line; Ctrl-P/Ctrl-N recall messages; PgUp/PgDn, arrows or wheel scroll; click **↓**, Esc, End (empty draft) or Ctrl-G return to latest; Left/Right or clicks move between list and chat | [Compose and submit](./compose-submit.md), [New Session](./new-chat.md), [navigation](./status-navigation.md) |
| App settings | End then Enter on Overview, or click **Settings** | Up/Down then Enter, or click a field/choice; **Version** starts Upgrade; Esc goes back | [App settings and Keys](./app-settings.md) |
| Keys | Open **Keys** in Settings | Read the key reference; Esc returns to Settings | [App settings and Keys](./app-settings.md) |
| Model choice | Click a chat's model, Tab then Enter, `/model`, or open **Model** in Settings/Chat info | Type to filter; Up/Down then Enter, or click a match; Esc closes | [Model choice and Effort](./model-choice.md) |
| Effort | Click chat effort, Tab twice then Enter, or open **Effort** in Settings/Chat info | Arrows then Enter, or click a level; Esc closes | [Model choice and Effort](./model-choice.md) |
| Sign-in | First run without credentials, or **Sign-in** in Settings | Tab/Shift-Tab then Enter, or click account/method/controls; edit API fields; **Copy code**, **Open browser**, **Back**, **Close** | [Sign-in and first run](./sign-in.md) |
| Approval | A chat using **ask first** needs a tool decision | PgUp/PgDn or wheel reads; Left/Right selects **Allow once**/**Deny**, Enter confirms; click a choice; typing moves to draft; Esc restores the choice | [Consent](./consent.md) |
| Chat info | Alt-I or click **alt+i info** | Arrows and Enter, or click fields/actions; **Rename**, **Archive**, **Copy last answer**; Esc closes | [Chat info and navigation](./status-navigation.md) |
| Tool output | Ctrl-O on a tool or click its heading | Ctrl-O or another click folds it; arrows, PgUp/PgDn or wheel scroll | [Chat info and navigation](./status-navigation.md) |
| Message | Ctrl-O on a collapsed message | Read its full text; arrows, PgUp/PgDn or wheel scroll; Ctrl-O or Esc returns | [Chat info and navigation](./status-navigation.md) |
| Archived | Home, Down, Right, Enter on Overview, or click **Archived** | Up/Down then Enter or click opens a chat; Esc returns; `/unarchive` in the chat restores it | [Archive and Archived](./archive.md) |
| Slash commands | Type `/` in Chat | Type to narrow; Up/Down select; Tab completes; Enter or click takes a suggestion; Esc closes | [Slash commands and skills](./slash-commands.md) |
| Requests | Send `/requests` in Chat | Up/Down then Enter takes a recovery or saved-answer row; PgUp/PgDn or wheel reads; Esc returns | [Slash commands and skills](./slash-commands.md) |
| Saved answer | Send `/result KEY`, or take its Requests row | Arrows, PgUp/PgDn or wheel reads; Esc returns | [Slash commands and skills](./slash-commands.md) |
| Defaults for new chats | Send `/setup` in Chat | Read the defaults; scroll a long page with arrows, PgUp/PgDn or wheel; Esc returns | [Slash commands and skills](./slash-commands.md) |
| Submission details | Alt-D or click **alt+d details** for a held or rejected submission; click **details** on an environment refusal | Read repair instructions; arrows, PgUp/PgDn or wheel scroll; Esc returns | [Chat info and navigation](./status-navigation.md) |
| Host stopped | The connected Host stops | Use the shown start/retry control; `r` starts from Chat when offered; Ctrl-C leaves | [Working, queued and stopped](./work-stop.md) |
| Exit | Ctrl-C or a termination signal | Read **Detached. Host work continues.** and the resume command; mouse actions end with the client | [Exit and terminal restoration](./exit-restore.md) |

Working, queued, stopped and failed messages are Chat states; [work and stop](./work-stop.md) covers them. [Terminal themes and input focus](./appearance.md) covers night, day, mist and no-color views across screens.

## Baseline preconditions

- A pinned build exists: `$V build FULLSHA --source CLEAN_WORKTREE` (`V=.claude/skills/verify-rui/scripts/verify-rui`).
- Each experiment has its own `RUN=$($V new FULLSHA --seed 3 --label NAME)`, and `$V doctor "$RUN" --expect-sha FULLSHA` prints `PASS`.
- Session `demo` is bypass with three seeded answers. Session `approve` is ask with no history.
- Never drive a Store, Host or tmux server this run did not start.

## Driving conventions

- Every step pairs one `send` with one `wait --after GEN` on a committed frame. Record the generation each step returns.
- Use `screen --label NN-what` before and after every state change you claim.
- Name the surface (`pty`, `tmux-detached`, `tmux-attached`, `gui`) and the input layer (L1 FIFO, L2 send-keys, L3 attached-client bytes, L4 physical) with every result.

## Proof and skip reporting

- Visible proof is a committed frame. Side-effect proof is `provider.jsonl`, plus `request list` and `request inspect`, plus `exit.json`.
- Temporal claims need `frames.jsonl` timestamps, or the `timeline.txt` from `$V evidence`, not a still.
- Report an unreachable path with the command tried and the unmet precondition. A skipped surface is not verified through another.

## Features

- [Compose and submit](./compose-submit.md): draft entry, multiline paste, a single submission, the answer, capture correlation, and the input matrix every editor-hosting surface must pass.
- [Consent](./consent.md): approval prompt reading, **Allow once**, **Deny**, retained drafts and pasted input.
- [Chat info and navigation](./status-navigation.md): Alt-I or **alt+i info**, panels above visible feed, tool output (Ctrl-O), PgUp/PgDn, arrows, wheel, Ctrl-G and Esc.
- [Exit and terminal restoration](./exit-restore.md): Ctrl-C and SIGTERM restore termios and the screen.
- [tmux attached and detached](./tmux.md): the same journeys through a private tmux server, with or without a client.
- [Hardware input](./hardware-input.md): physical keys and wheel in a GUI terminal (L4, needs a human).
- [Overview and session list](./overview.md): list rows, pinned actions, scrolling and focus between list and chat.
- [New Session and empty chats](./new-chat.md): create, choose settings, type a first task or leave without sending.
- [App settings and Keys](./app-settings.md): defaults, notifications, sign-in, Version and the key reference.
- [Sign-in and first run](./sign-in.md): account chooser, browser, device code and API key forms.
- [Slash commands and skills](./slash-commands.md): suggestions, filtering, copy, misuse, Requests and saved answers.
- [Model choice and Effort](./model-choice.md): shared model filtering and effort choices in settings and chat.
- [Archive and Archived](./archive.md): archive state, the Archived tab and restore.
- [Working, queued and stopped](./work-stop.md): running tools, queued messages, stop, failed replies and Host recovery.
- [Terminal themes and input focus](./appearance.md): night, day, mist, no-color, input tint and focus.
- [Named frames](./frames.md): scenario format, capture selection and evidence limits.
