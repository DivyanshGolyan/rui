const std = @import("std");
const Reference = [@import("session_id.zig").bytes]u8;

pub const Follow = struct {
    return_to: ?Reference = null,
    pending: ?Reference = null,

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
    try std.testing.expectEqual(@as(?Reference, null), follow.next("aaaaaa".*));
    follow.pending = "bbbbbb".*;
    try std.testing.expectEqualStrings("bbbbbb", &follow.next("aaaaaa".*).?);
    follow.pending = "cccccc".*;
    try std.testing.expectEqualStrings("cccccc", &follow.next("bbbbbb".*).?);
    try std.testing.expectEqualStrings("bbbbbb", &follow.return_to.?);
    try std.testing.expectEqualStrings("bbbbbb", &follow.next("cccccc".*).?);
    try std.testing.expectEqual(@as(?Reference, null), follow.next("bbbbbb".*));
    try std.testing.expectEqual(Follow{}, follow);
}
