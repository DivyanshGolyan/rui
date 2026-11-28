const std = @import("std");

/// Something that happens to the viewer, not asked for by the person, while a
/// gesture is held. Every surface asks this table, so one interruption has
/// one outcome in the terminal, in a window and on a phone.
pub const Interruption = enum {
    /// The window or terminal lost keyboard focus.
    focus_lost,
    /// The pointer left the surface that holds the gesture, with no release coming.
    pointer_left,
};

/// What a held selection is for, on the surface that holds it.
pub const Held = enum {
    /// A selection in a document view, copied on release.
    document_copy,
    /// A selection in the feed, copied on release.
    feed_copy,
    /// A selection in the feed that only quotes into the draft.
    feed_quote,
};

/// Whether the interruption ends the held selection. A cancelled selection
/// copies and quotes nothing.
pub fn cancels(interruption: Interruption, held: Held) bool {
    return switch (interruption) {
        .focus_lost => true,
        // The feed keeps a copy drag whose pointer left the pane, so the drag can
        // scroll the feed from outside it; every other held selection has no release coming.
        .pointer_left => held != .feed_copy,
    };
}

test "SUI-201 an interruption ends every held selection except a feed copy whose pointer left" {
    // Expected outcomes are the behaviour before this table: DocumentView and FeedView
    // each handled the two events by hand.
    const expected = [_]struct { Interruption, Held, bool }{
        .{ .focus_lost, .document_copy, true },
        .{ .focus_lost, .feed_copy, true },
        .{ .focus_lost, .feed_quote, true },
        .{ .pointer_left, .document_copy, true },
        .{ .pointer_left, .feed_copy, false },
        .{ .pointer_left, .feed_quote, true },
    };
    try std.testing.expectEqual(std.enums.values(Interruption).len * std.enums.values(Held).len, expected.len);
    for (expected) |row| try std.testing.expectEqual(row[2], cancels(row[0], row[1]));
}
