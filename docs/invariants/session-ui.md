# Session UI invariants

These promises are derived from the [Session UI contract](../contracts/session-ui.md).

| Id | Level | Invariant | Seam | Owner test | Source |
| --- | --- | --- | --- | --- | --- |
| TUI-1 | Surface | An observed empty chat displays a centred welcome with a quiet line until its first Message is pending or observed, including with a draft and in Unicode and ASCII. | Rendered chat screen from Session state | `TUI-1 empty chat welcome is centred until the first message` | [Chat input and user message bands](../contracts/session-ui.md#chat-input-and-user-message-bands) |
| TUI-2 | Surface | The Chats and Archived tabs are separated by two spaces and only their visible cells accept their respective clicks, including when clipped. | Rendered list controls and mouse events | `TUI-2 chat tabs paint and accept only their visible cells` | [Overview](../contracts/session-ui.md#human-entry-and-authentication) |
