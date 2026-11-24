const std = @import("std");

/// Queue cutoffs and attached terminal rows share one Session window and Host instance.
const Self = @This();
host: ?[16]u8 = null,
terminal: u64 = 0,
roster: ?u64 = null,

fn bind(self: *Self, host: [16]u8) bool {
    if (self.host) |current| if (std.mem.eql(u8, &current, &host)) return false;
    const changed = self.host != null;
    self.* = .{ .host = host };
    return changed;
}

/// The Store computes a forward partial page's aggregate at its last row;
/// every other full-page aggregate uses the page's end.
pub fn pageCutoff(end: u64, forward: bool, more: bool, last: ?u64) u64 {
    return if (forward and more) last.? else end;
}

/// Call only after the user or Stop row has entered the displayed window.
/// The return value says that the previous queue presentation must be cleared.
pub fn attach(self: *Self, host: [16]u8, position: u64) bool {
    const changed = self.bind(host);
    self.terminal = @max(self.terminal, position);
    if (self.roster) |cutoff| if (cutoff < self.terminal) {
        self.roster = null;
        return true;
    };
    return changed;
}

/// A full Activity page's aggregate is valid only at or beyond the attached
/// terminal floor and the newest aggregate already adopted in this window.
pub fn adopt(self: *Self, host: [16]u8, cutoff: u64) bool {
    _ = self.bind(host);
    if (cutoff < self.terminal) return false;
    if (self.roster) |previous| if (cutoff < previous) return false;
    self.roster = cutoff;
    return true;
}

pub fn matches(self: *const Self, host: [16]u8) bool {
    const current = self.host orelse return false;
    return std.mem.eql(u8, &current, &host);
}

test "SUI-140 queue aggregate follows attached terminal and roster horizons" {
    const a: [16]u8 = @splat(1);
    const b: [16]u8 = @splat(2);
    for ([_]bool{ false, true }) |forward| for ([_]bool{ false, true }) |more| {
        try std.testing.expectEqual(@as(u64, if (forward and more) 20 else 24), pageCutoff(24, forward, more, 20));
    };
    for ([_]u64{ 0, 1, 20, 40 }) |floor| for ([_]u64{ 0, 1, 20, 40 }) |cutoff| {
        var state: Self = .{};
        _ = state.attach(a, floor);
        try std.testing.expectEqual(cutoff >= floor, state.adopt(a, cutoff));
        if (cutoff >= floor) {
            try std.testing.expect(!state.attach(a, floor));
            try std.testing.expectEqual(floor + 1 > cutoff, state.attach(a, floor + 1));
        }
        try std.testing.expect(state.matches(a));
        try std.testing.expect(!state.matches(b));
        // A new Host or a replacement window starts its own horizon.
        state = .{};
        try std.testing.expect(state.adopt(b, cutoff));
        try std.testing.expect(state.matches(b));
    };
    var first_window: Self = .{};
    _ = first_window.attach(a, 100);
    var replacement_window: Self = .{};
    try std.testing.expect(replacement_window.adopt(a, 10));
    var other_session: Self = .{};
    try std.testing.expect(other_session.adopt(a, 10));
    try std.testing.expect(!first_window.adopt(a, 10));
    var state: Self = .{};
    try std.testing.expect(state.adopt(a, 50));
    try std.testing.expect(!state.adopt(a, 49));
    try std.testing.expect(state.adopt(a, 51));
    try std.testing.expect(!state.attach(a, 50));
    try std.testing.expect(state.attach(a, 52));
    try std.testing.expect(!state.adopt(a, 51));
    try std.testing.expect(state.adopt(a, 52));
    try std.testing.expect(state.attach(b, 1));
    try std.testing.expect(state.adopt(b, 1));
}
