//! Where leaving a Session goes when Session links are followed: one step
//! back, never a history. Values only; the overview opens what it says.
const std = @import("std");
const Reference = [@import("session_id.zig").bytes]u8;

pub const Follow = struct {
    /// The Session a followed link left, which leaving the linked one
    /// reopens.
    return_to: ?Reference = null,
    /// A link click asked to open this Session once the current one is left.
    pending: ?Reference = null,

    /// The Session `from` has been left for the overview: the Session to
    /// open now, or null for the overview. Following a link remembers
    /// `from`, replacing any earlier way back; leaving otherwise takes the
    /// way back once.
    pub fn next(self: *Follow, from: Reference) ?Reference {
        if (self.pending) |target| {
            self.pending = null;
            self.return_to = from;
            return target;
        }
        defer self.return_to = null;
        return self.return_to;
    }
};

test "a followed link returns one step, then to the overview, and a second link replaces the way back" {
    var follow: Follow = .{};
    // Opened from the overview, leaving reaches the overview.
    try std.testing.expectEqual(@as(?Reference, null), follow.next("aaaaaa".*));
    follow.pending = "bbbbbb".*;
    try std.testing.expectEqualStrings("bbbbbb", &follow.next("aaaaaa".*).?);
    // From the linked Session, a second link replaces the way back.
    follow.pending = "cccccc".*;
    try std.testing.expectEqualStrings("cccccc", &follow.next("bbbbbb".*).?);
    try std.testing.expectEqualStrings("bbbbbb", &follow.return_to.?);
    // Esc: back one step, then the overview.
    try std.testing.expectEqualStrings("bbbbbb", &follow.next("cccccc".*).?);
    try std.testing.expectEqual(@as(?Reference, null), follow.next("bbbbbb".*));
    try std.testing.expectEqual(Follow{}, follow);
}
