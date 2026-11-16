# New Session and empty chats

**+ New Session** opens a chat with **Type a task** at its input. You can choose its model and effort before sending. Leaving without sending keeps the saved Session but removes its unpinned empty row from Overview.

## Sub-features

- Home then Enter on Overview opens **New Session**. A click on **+ New Session** does the same.
- `/new` and `/clear` open an empty chat. The old conversation remains saved.
- The empty chat has its own input, folder, model and effort.
- Changing the model without sending still leaves no unpinned empty row after Esc.

## How to get to it (user POV)

Choose **+ New Session** from the list, or send `/new` or `/clear` in a chat. Type your task and press Enter to start the conversation. Press Esc to leave the empty chat.

## Driving it with verify-rui

Run `$V frames FULLSHA --only appcmds-new,appcmds-clear,chat-empty,empty-chat-left,empty-chat-model-left,empty-chat-two-left,start-draft`.

Frame states: `appcmds-new`, `appcmds-clear`, `chat-empty`, `empty-chat-left`, `empty-chat-model-left`, `empty-chat-two-left`, `start-draft`

Check **Type a task** and the model/effort line before typing. After leaving one or two empty chats, existing conversations must remain visible without extra empty rows or raw IDs. Use [Model choice and Effort](./model-choice.md) for the choices before sending.

## Gotchas

Leaving an empty chat does not delete it. Only a sent message makes an ordinary unpinned chat row persist in Overview. New Session is an action above the **Sessions** and **Archived** tabs.

Source: [creation and list visibility](../../../../src/overview_view.zig), [new-chat commands](../../../../src/SessionFrontend.zig).
