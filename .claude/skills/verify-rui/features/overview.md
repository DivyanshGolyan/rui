# Overview and session list

Overview lists saved chats under **Chats**, with **+ New chat**, **Archived** and **Settings** always within reach. At wide launch the list sits beside a focused empty chat; at narrow launch the full overview opens. A wide chat keeps the same list beside its messages. The list shows names, work marks and elapsed times.

## Sub-features

- Up/Down select rows. Home selects **+ New chat**; End selects **Settings**. Enter opens the selection. Left collapses a selected Session's descendants and Right expands them.
- Creator Sessions contain their attached and detached descendants. Left and Right fold and expand locally; hidden questions appear in the collapsed badge. Pointer presence or a list key holds ordering briefly while marks update and new siblings append; release highlights moved rows. Edge pills and Alt-? reach questions outside the viewport.
- Long lists show **↑**, **↓** and **more**. Long names fit within their row.
- Finished and working chats without a message from you appear dimmer. Chats needing approval stay prominent.
- Left from an empty draft focuses the list beside a wide chat. Enter on the open row returns to its input. Clicking the list or chat also moves focus.
- At wide widths, keyboard list selection opens the selected chat in the main pane. At narrow widths, selection stays in the list until Enter opens it.
- Alt-Up/Alt-Down switch chats. Alt-? opens the next Session needing a decision, including one inside a collapsed tree. Ctrl-X stops work on the selected chat; Alt-A archives it.

## How to get to it (user POV)

Run `rui` in a project. Press Esc from a chat at its latest messages to return to Overview. Select a chat and press Enter, or click its row. At narrow widths the list and chat take turns using the screen.

## Driving it with verify-rui

Capture the states listed below with `$V frames FULLSHA --only wide-launch,narrow-launch,quiet-person,quiet-overview,quiet-sidebar,start-empty,start,list-hover,settings-hover,start-busy,overview-printable-ignored,long-labels,many-sessions,many-sessions-middle,many-sessions-end,many-sessions-pinned-end,chat-no-new-session,chat-sidebar-rows,focus-chat,left-to-list,focus-list-A,list-to-chat`.

Frame states: `wide-launch`, `narrow-launch`, `quiet-person`, `quiet-overview`, `quiet-sidebar`, `start-empty`, `start`, `list-hover`, `settings-hover`, `start-busy`, `overview-printable-ignored`, `long-labels`, `many-sessions`, `many-sessions-middle`, `many-sessions-end`, `many-sessions-pinned-end`, `chat-no-new-session`, `chat-sidebar-rows`, `focus-chat`, `left-to-list`, `focus-list-A`, `list-to-chat`

Compare 140×40 with 46×30. Check pinned actions at the middle and end of a long list. Compare the caret and selected row before Left and after Enter; the open chat's messages must stay in place. Hover must leave the selected row unchanged.

Run the ordered browsing fixture with `$V frames FULLSHA --only focus-seed-earlier,focus-browse-wide,focus-browse-narrow`. The seed finishes the alternate chat earlier so newest-first ordering is deterministic. Wide Down settles on the alternate chat's feed; narrow Down shows its selected list row, with neither chat's feed nor an **enter open** hint visible.

Frame states: `focus-seed-earlier`, `focus-browse-wide`, `focus-browse-narrow`

Capture creator nesting with `$V frames FULLSHA --scenario .claude/skills/verify-rui/scripts/creator-tree.json --only tree-unicode,tree-ascii,hidden-question-unicode,hidden-question-ascii,held-arrival-unicode,release-unicode,held-arrival-ascii,sidebar-unicode,sidebar-ascii --sizes 140x40,46x30 --record`. Capture the `edge-below`, `edge-above` and `edge-open` states in Unicode and ASCII separately. Review the recorded frames as well as stills for the release flash.

This scenario creates descendants through the real StartAgent provider and verifies their public creator and lifecycle parent. Its `creator` label refers to an earlier cast Session; `attached` selects the lifecycle relationship and `birth` creates a child during the terminal run. The sender fixture remains separate. The full-overview and row-selection helpers wait for the committed list and verify the selected row; scenario-specific active capacity defaults to two when omitted.

## Gotchas

Overview has no input. Typing text or `/` there does nothing. Left from an empty draft only moves to a list when that list is visible; Esc leaves the chat at either width.

Source: [Overview](../../../../src/Overview.zig), [list rules](../../../../src/overview_view.zig), [pane focus](../../../../src/Root.zig).
