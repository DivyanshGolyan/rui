//! What a key does in a conversation, decided over values
//! `SessionFrontend` read: the conversation's one key table, whether the
//! overview's open ask takes an input, and what an input does at an
//! Action's Allow once / Deny choice. The shell decodes the key, spends the
//! offer and carries out what these return.
const std = @import("std");
const keymap = @import("keymap.zig");
const overview_view = @import("overview_view.zig");
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
    /// Asks to stop the Session, and stops it at a second press.
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

/// Who takes an input: the overview's open ask, which it confirms or
/// cancels, or the conversation, which first cancels any ask unless the key
/// is one that asks.
pub const Route = union(enum) {
    ask: overview_view.ConversationInput,
    conversation: struct { cancel_ask: bool },
};

/// An archive ask takes Enter, confirming only an unpasted plain Enter; any
/// ask takes Esc and Ctrl-G as a cancel. Until the opening read, Ctrl-X and
/// Alt-A ask nothing, so they cancel an ask as any other key does.
pub fn route(asking: ?overview_view.Prompt.Action, selected: Selection, plain_enter: bool, opening: bool) Route {
    if (asking == .archive and selected == .enter) return .{ .ask = if (plain_enter) .confirm_archive else .other };
    if (asking != null and selected == .action and selected.action == .close) return .{ .ask = .other };
    const asks = !opening and selected == .action and (selected.action == .stop or selected.action == .archive);
    return .{ .conversation = .{ .cancel_ask = !asks } };
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

test "an archive ask is confirmed only by a plain Enter; any ask is cancelled by Esc or by an ordinary key" {
    try std.testing.expectEqual(Route{ .ask = .confirm_archive }, route(.archive, .enter, true, false));
    // A pasted or modified Enter cancels the archive ask instead.
    try std.testing.expectEqual(Route{ .ask = .other }, route(.archive, .enter, false, false));
    // A stop ask takes Enter as ordinary input, which cancels it.
    try std.testing.expectEqual(Route{ .conversation = .{ .cancel_ask = true } }, route(.stop, .enter, true, false));
    for ([_]?overview_view.Prompt.Action{ .stop, .archive }) |asking| {
        try std.testing.expectEqual(Route{ .ask = .other }, route(asking, .{ .action = .close }, false, false));
        // The asking keys step the overview themselves, so they do not cancel first.
        try std.testing.expectEqual(Route{ .conversation = .{ .cancel_ask = false } }, route(asking, .{ .action = .stop }, false, false));
        try std.testing.expectEqual(Route{ .conversation = .{ .cancel_ask = false } }, route(asking, .{ .action = .archive }, false, false));
        try std.testing.expectEqual(Route{ .conversation = .{ .cancel_ask = true } }, route(asking, .text, false, false));
    }
    // Without an ask, Esc is the conversation's own.
    try std.testing.expectEqual(Route{ .conversation = .{ .cancel_ask = true } }, route(null, .{ .action = .close }, false, false));
    // Before the opening read, Ctrl-X and Alt-A ask nothing.
    try std.testing.expectEqual(Route{ .conversation = .{ .cancel_ask = true } }, route(.stop, .{ .action = .stop }, false, true));
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
