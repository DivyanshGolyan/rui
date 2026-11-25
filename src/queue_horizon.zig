const std = @import("std");

/// Where the queued strip's facts stand in one Session window.
///
/// Two kinds of read feed the window: an Activity page that carries the queue aggregate (a scan or
/// the opening read) and a visible fill that does not. A fill can attach a Message's applied row, or
/// a Stop, after a scan that is still in flight was already read, so that scan's aggregate would
/// repaint the Message as waiting. The Store takes an aggregate as of its cutoff position, so it is
/// stale exactly when a row that took a Message is attached beyond that cutoff.
/// `through` is the newest position the window's queue facts are known to cover: the cutoff of the
/// aggregate held, or the position of the newest taking row attached, whichever is later.
const Self = @This();
through: u64 = 0,

/// Call after a person-Message's applied row or a Stop row enters the window.
/// True says the held aggregate predates it and the queued strip must be cleared.
pub fn attach(self: *Self, position: u64) bool {
    if (position <= self.through) return false;
    self.through = position;
    return true;
}

/// An aggregate taken at `cutoff` is current only at or beyond `through`. True says to adopt it.
pub fn adopt(self: *Self, cutoff: u64) bool {
    if (cutoff < self.through) return false;
    self.through = cutoff;
    return true;
}

test "SUI-166 an aggregate is adopted only at or beyond what the attached rows and the held aggregate cover" {
    for ([_]u64{ 0, 1, 20, 40 }) |floor| for ([_]u64{ 0, 1, 20, 40 }) |cutoff| {
        var state: Self = .{};
        _ = state.attach(floor);
        try std.testing.expectEqual(cutoff >= floor, state.adopt(cutoff));
        if (cutoff >= floor) {
            try std.testing.expect(!state.attach(floor));
            try std.testing.expectEqual(floor + 1 > cutoff, state.attach(floor + 1));
        }
    };
    var state: Self = .{};
    try std.testing.expect(state.adopt(50));
    try std.testing.expect(!state.adopt(49));
    try std.testing.expect(state.adopt(51));
    try std.testing.expect(!state.attach(50));
    try std.testing.expect(state.attach(52));
    try std.testing.expect(!state.adopt(51));
    try std.testing.expect(state.adopt(52));
}
