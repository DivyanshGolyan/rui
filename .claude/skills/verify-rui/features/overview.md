# Overview and session list

Overview lists saved chats under **Sessions**, with **+ New Session**, **Archived** and **Settings** always within reach. At wide launch the list sits beside a focused empty chat; at narrow launch the full overview opens. A wide chat keeps the same list beside its messages. The list shows names, work marks and elapsed times.

## Sub-features

- Up/Down select rows. Home selects **+ New Session**; End selects **Settings**. Enter opens the selection. Right opens a selected chat.
- Long lists show **↑**, **↓** and **more**. Long names fit within their row.
- Finished and working chats without a message from you appear dimmer. Chats needing approval stay prominent.
- Left from an empty draft focuses the list beside a wide chat. Right on the open row returns to its input. Clicking the list or chat also moves focus.
- At wide widths, keyboard list selection opens the selected chat in the main pane. At narrow widths, selection stays in the list until Enter or Right opens it.
- Alt-Up/Alt-Down switch chats. Ctrl-X stops work on the selected chat; Alt-A archives it.

## How to get to it (user POV)

Run `rui` in a project. Press Esc from a chat at its latest messages to return to Overview. Select a chat and press Enter, or click its row. At narrow widths the list and chat take turns using the screen.

## Driving it with verify-rui

Capture the states listed below with `$V frames FULLSHA --only wide-launch,quiet-person,quiet-overview,quiet-sidebar,start-empty,start,list-hover,settings-hover,start-busy,overview-printable-ignored,long-labels,many-sessions,many-sessions-middle,many-sessions-end,many-sessions-pinned-end,chat-no-new-session,chat-sidebar-rows,focus-chat,left-to-list,focus-list-A,list-to-chat`.

Frame states: `wide-launch`, `quiet-person`, `quiet-overview`, `quiet-sidebar`, `start-empty`, `start`, `list-hover`, `settings-hover`, `start-busy`, `overview-printable-ignored`, `long-labels`, `many-sessions`, `many-sessions-middle`, `many-sessions-end`, `many-sessions-pinned-end`, `chat-no-new-session`, `chat-sidebar-rows`, `focus-chat`, `left-to-list`, `focus-list-A`, `list-to-chat`

Compare 140×40 with 46×30. Check pinned actions at the middle and end of a long list. Compare the caret and selected row before Left and after Right; the open chat's messages must stay in place. Hover must leave the selected row unchanged.

Run the ordered browsing fixture with `$V frames FULLSHA --only focus-seed-earlier,focus-browse-wide,focus-browse-narrow`. The seed finishes the alternate chat earlier so newest-first ordering is deterministic. Wide Down settles on the alternate chat's feed; narrow Down shows its selected list row and **enter open**, with neither chat's feed visible.

Frame states: `focus-seed-earlier`, `focus-browse-wide`, `focus-browse-narrow`

## Gotchas

Overview has no input. Typing text or `/` there does nothing. Left from an empty draft only moves to a list when that list is visible; Esc leaves the chat at either width.

Source: [Overview](../../../../src/Overview.zig), [list rules](../../../../src/overview_view.zig), [pane focus](../../../../src/Root.zig).
