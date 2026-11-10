//! What a key does in a conversation, decided over values
//! `SessionFrontend` read: the conversation's one key table, which inputs
//! clear the overview's notice, and what an input does at an Action's
//! Allow once / Deny choice. The shell decodes the key, spends the
//! offer and carries out what these return.
const std = @import("std");
const keymap = @import("keymap.zig");
const ConsentPolicy = @import("session_consent.zig");

/// What a key does in a conversation, beside the draft or an Action's choice.
pub const Action = enum {
    page_up,
    page_down,
    /// Up and Down: the shown list's highlight, the /status page's row,
    /// else a line of scrolling.
    previous,
    next,
    /// Shift-Up and Shift-Down: the shown list's highlight, else a line of
    /// scrolling, also on the /status page.
    scroll_up,
    scroll_down,
    /// On an empty or recalled draft, the Message sent before the one it
    /// shows.
    older,
    /// On a recalled draft, the Message sent after it, or past the newest
    /// an empty draft.
    newer,
    /// The latest view, which is the pending Action if there is one.
    latest,
    /// Out of a Message page, else to the latest view. It never leaves the
    /// conversation.
    back,
    /// As `back`, and from the settled latest view, once nothing would be
    /// lost, to the overview.
    close,
    /// Opens the lowest collapsed Message, or leaves a Message page.
    expand,
    /// Leaves the conversation; Host work continues.
    detach,
    /// Retries the uncertain original.
    recover,
    /// Stops the Session at once.
    stop,
    archive,
};

/// The conversation's one key table.
pub const keys: keymap.Keymap(Action) = .init(.{
    .escape = .close,
    // A lone ESC acts only once it expires; Ctrl-G acts at once.
    .ctrl_g = .close,
    .ctrl_c = .detach,
    .ctrl_d = .detach,
    .ctrl_n = .newer,
    .ctrl_o = .expand,
    .ctrl_p = .older,
    .ctrl_r = .recover,
    .ctrl_x = .stop,
    .alt_a = .archive,
    .up = .previous,
    .down = .next,
    .shift_up = .scroll_up,
    .shift_down = .scroll_down,
    .page_up = .page_up,
    .page_down = .page_down,
    .home = null,
    .end = .back,
    .ctrl_end = .latest,
});

/// One input as the conversation's table classifies it.
pub const Selection = keymap.Selection(Action);

/// Whether an input clears the overview's notice: every input but Ctrl-X
/// and Alt-A, which step the overview themselves once the Session opens.
/// Until the opening read they do nothing there, so they clear it too.
pub fn clearsOverviewNotice(selected: Selection, opening: bool) bool {
    const steps_overview = selected == .action and (selected.action == .stop or selected.action == .archive);
    return opening or !steps_overview;
}

/// What an input does at the choice. Only the arrows and Enter act on it.
pub const AtChoice = union(enum) {
    nothing,
    say: []const u8,
    perform: Action,
    pick: ConsentPolicy.Choice,
    confirm,
    /// Typing moves to the draft beside the Action, which takes this key.
    draft,
};

/// `command_holds`: a running command holds the choice, so neither a
/// Message nor a command could go.
pub fn atChoice(selected: Selection, command_holds: bool) AtChoice {
    return switch (selected) {
        .none => .nothing,
        .action => |action| switch (action) {
            // While an Action waits there is no original to retry.
            .recover => .{ .say = "! Action needs a decision; nothing to retry." },
            // The draft is not the choice's; its sent Messages wait.
            .older, .newer => .nothing,
            else => .{ .perform = action },
        },
        .left => .{ .pick = .allow_once },
        .right => .{ .pick = .deny },
        .enter => .confirm,
        .text => if (command_holds) .{ .say = "! Command still running. Input ignored." } else .draft,
        .refused => .{ .say = "! Key combination not recognized; nothing authorized." },
    };
}

test "Ctrl-X and Alt-A keep the overview's notice once the Session opens; every other input clears it" {
    try std.testing.expect(!clearsOverviewNotice(.{ .action = .stop }, false));
    try std.testing.expect(!clearsOverviewNotice(.{ .action = .archive }, false));
    for ([_]Selection{ .enter, .text, .{ .action = .close }, .{ .action = .page_up } }) |selected| {
        try std.testing.expect(clearsOverviewNotice(selected, false));
    }
    // Before the opening read, Ctrl-X and Alt-A step nothing.
    try std.testing.expect(clearsOverviewNotice(.{ .action = .stop }, true));
}

test "at the choice only the arrows and Enter act; typing moves to the draft unless a command holds the choice" {
    try std.testing.expectEqual(AtChoice{ .pick = .allow_once }, atChoice(.left, false));
    try std.testing.expectEqual(AtChoice{ .pick = .deny }, atChoice(.right, false));
    try std.testing.expectEqual(AtChoice.confirm, atChoice(.enter, true));
    try std.testing.expectEqual(AtChoice.draft, atChoice(.text, false));
    try std.testing.expectEqualStrings("! Command still running. Input ignored.", atChoice(.text, true).say);
    try std.testing.expectEqualStrings("! Key combination not recognized; nothing authorized.", atChoice(.refused, false).say);
    try std.testing.expectEqualStrings("! Action needs a decision; nothing to retry.", atChoice(.{ .action = .recover }, false).say);
    try std.testing.expectEqual(AtChoice.nothing, atChoice(.none, false));
    try std.testing.expectEqual(AtChoice.nothing, atChoice(.{ .action = .older }, false));
    try std.testing.expectEqual(AtChoice.nothing, atChoice(.{ .action = .newer }, false));
    // Every other action is the conversation's own, Ctrl-D leaving it.
    for ([_]Action{ .stop, .detach, .close, .page_up, .expand }) |action| {
        try std.testing.expectEqual(AtChoice{ .perform = action }, atChoice(.{ .action = action }, false));
    }
}

test "the conversation binds Ctrl-X to stop, Alt-A to archive and Esc and Ctrl-G to close, and leaves Home unbound" {
    try std.testing.expectEqual(@as(?Action, .stop), keys.get(.ctrl_x));
    try std.testing.expectEqual(@as(?Action, .archive), keys.get(.alt_a));
    try std.testing.expectEqual(@as(?Action, .close), keys.get(.escape));
    try std.testing.expectEqual(@as(?Action, .close), keys.get(.ctrl_g));
    try std.testing.expectEqual(@as(?Action, null), keys.get(.home));
}
