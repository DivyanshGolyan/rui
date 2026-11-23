# Archive and Archived

Archiving removes a chat from the usual list and keeps its conversation available under **Archived**. An open archived chat shows **· Archived** in its footer. Restoring it returns it to the usual list without restarting work.

## Sub-features

- Alt-A on a selected or open chat, `/archive`, or **Archive** in Chat info requests archive.
- **Sessions** and **Archived** sit below the separate **+ New chat** action. Archived remains available even when empty.
- Home then Down selects the tabs. Right selects Archived; Left returns to Sessions; Enter opens the selected view.
- Clicking **Archived** opens that list. Esc returns to the usual list.
- Pressing a chat row and dragging it onto **Archived** archives it; dragging an archived chat onto **Chats** restores it. While carried, the target tab is shaded and the tabs line says **· drop here**. Needs the list beside a chat (100 columns or more).
- `/unarchive` restores an open archived chat. Copy feedback can appear alongside the durable archived state.

## How to get to it (user POV)

Archive a chat, then choose **Archived** in Overview. Open a chat with Enter or a click to read it. Send `/unarchive` to restore it.

## Driving it with verify-rui

Run `$V frames FULLSHA --only archived-row-none,archive-state,archived-row,archived-row-chosen,archived-view,archived-view-click,archived-view-esc,transient-chat,drag-to-archive,drag-dropped`.

Frame states: `archived-row-none`, `archive-state`, `archived-row`, `archived-row-chosen`, `archived-view`, `archived-view-click`, `archived-view-esc`, `transient-chat`, `drag-to-archive`, `drag-dropped`

Check the tab with no archived chats, keyboard and mouse entry, and Esc back to Sessions. The archived list uses plain names without an extra archived marker on each row. The open chat keeps **· Archived** while **Sent to clipboard** is visible.

## Gotchas

Archive may need to stop work first. Treat a pending archive as pending until the saved state confirms it. The **Archive: couldn't archive** recovery layout belongs to [Chat info](./status-navigation.md).

Source: [archive actions and tabs](../../../../src/overview_view.zig), [chat commands](../../../../src/SessionFrontend.zig), [archive state](../../../../src/session_archive.zig).
