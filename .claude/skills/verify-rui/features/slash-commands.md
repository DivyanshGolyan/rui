# Slash commands and skills

Typing `/` in a chat shows commands and loaded skills above the input. Typing more narrows the list. Commands show short descriptions; fixed choices show their words. Long lists show **more · type to narrow**.

## Sub-features

- Up/Down move through suggestions. Tab completes; Enter takes the selected suggestion. Commands needing an argument continue in the draft.
- `/copy`, `/copy code` and `/copy file` copy an answer or its named part. A missing code block shows **No code block**.
- `/rename NAME`, `/effort LEVEL`, `/pin`, `/unpin`, `/reload-skills` and `/setup` act on the named chat or defaults. `/setup` alone shows defaults.
- `/requests` shows saved requests. Select a row with Up/Down then Enter to recover a request or show its saved answer. `/result KEY` shows a saved answer directly.
- A leading skill such as `/review this change` remains a message. Whole-line bracketed paste follows message admission without a suggestion preview.
- A misused known command shows **Usage:** locally. Esc closes a skill suggestion list while keeping its message; Esc on an open choice command consumes that command.

## How to get to it (user POV)

Open a chat and type `/`. Type `/cop` to narrow to `/copy`, or use the arrows. Click a shown suggestion to take it. Press Esc to close the list. For request or saved-answer pages, use PgUp/PgDn, arrows or the wheel to read, then Esc to return.

## Driving it with verify-rui

Run `$V frames FULLSHA --only appcmds-conversation,appcmds-conversation-end,appcmds-skill-escape,appcmds-agent-commands,draft-chat-choice-escape,copy-no-code,slash,slash-hover,slash-filter,misused-command,appcmds-skill-without-preview,appcmds-unknown-name-message,appcmds-hidden-discard-collision,appcmds-hidden-recover-collision,draft-chat-misused,misused-navigation-command`.

Frame states: `appcmds-conversation`, `appcmds-conversation-end`, `appcmds-skill-escape`, `appcmds-agent-commands`, `draft-chat-choice-escape`, `copy-no-code`, `slash`, `slash-hover`, `slash-filter`, `misused-command`, `appcmds-skill-without-preview`, `appcmds-unknown-name-message`, `appcmds-hidden-discard-collision`, `appcmds-hidden-recover-collision`, `draft-chat-misused`, `misused-navigation-command`

Compare the start and end of the suggestion list, filtered copy choices and skill descriptions at both sizes. Check that skill paste becomes a message and that misuse stays local. Requests, saved answers and `/setup` output have no dedicated named frame yet; drive them with `send`, `wait --after GEN` and `screen` as described in the skill.

## Gotchas

Overview ignores printable input. `/help`, `/exit`, `/login` and `/upgrade` are unknown commands; use **Keys**, Ctrl-C, **Sign-in** and **Version** instead. Hidden `/discard` and `/recover` reserve their names even when skills have similar names. A pasted unknown leading name can be message text; do not treat it as proof that a typed unknown command runs.

Source: [command grammar and descriptions](../../../../src/slash_commands.zig), [suggestion input](../../../../src/command_input.zig), [command and request-page handling](../../../../src/SessionFrontend.zig).
