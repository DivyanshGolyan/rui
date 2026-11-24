const std = @import("std");

/// Recognizes one unmodified click on the same semantic target in the same view.
/// The caller supplies freshness values that identify the drawn content and view.
pub fn Click(comptime Target: type, comptime Cell: type, comptime Freshness: type) type {
    return struct {
        const Self = @This();
        pub const Hit = struct { target: Target, freshness: Freshness };
        pub const Contact = struct { plain: bool, cell: Cell, hit: ?Hit };
        pub const Input = union(enum) { press: Contact, release: Contact, drag, cancel };
        const Press = struct { cell: Cell, hit: Hit };

        held: ?Press = null,

        pub fn pending(self: Self) bool {
            return self.held != null;
        }

        pub fn step(self: *Self, input: Input) ?Target {
            switch (input) {
                .press => |contact| {
                    self.held = if (contact.plain) (if (contact.hit) |hit| Press{ .cell = contact.cell, .hit = hit } else null) else null;
                    return null;
                },
                .drag, .cancel => {
                    self.held = null;
                    return null;
                },
                .release => |contact| {
                    const held = self.held orelse return null;
                    self.held = null;
                    const current = contact.hit orelse return null;
                    if (!contact.plain or !std.meta.eql(contact.cell, held.cell) or !std.meta.eql(current, held.hit)) return null;
                    return current.target;
                },
            }
        }
    };
}

test "SUI-116 link click transitions require one plain fresh matching press and release" {
    const Core = Click(u8, u8, u8);
    const Hit = Core.Hit;
    const hits = [_]?Hit{ null, .{ .target = 0, .freshness = 0 }, .{ .target = 0, .freshness = 1 }, .{ .target = 1, .freshness = 0 }, .{ .target = 1, .freshness = 1 } };
    // Cross all press and release values, including replacing an earlier press.
    for ([_]bool{ false, true }) |press_plain| for ([_]u8{ 0, 1 }) |press_cell| for (hits) |press_hit| {
        for ([_]bool{ false, true }) |release_plain| for ([_]u8{ 0, 1 }) |release_cell| for (hits) |release_hit| {
            var core: Core = .{};
            try std.testing.expectEqual(@as(?u8, null), core.step(.{ .press = .{ .plain = true, .cell = 1, .hit = hits[4] } }));
            try std.testing.expectEqual(@as(?u8, null), core.step(.{ .press = .{ .plain = press_plain, .cell = press_cell, .hit = press_hit } }));
            const want: ?u8 = if (press_plain and release_plain and press_cell == release_cell and press_hit != null and release_hit != null and
                press_hit.?.target == release_hit.?.target and press_hit.?.freshness == release_hit.?.freshness) press_hit.?.target else null;
            try std.testing.expectEqual(want, core.step(.{ .release = .{ .plain = release_plain, .cell = release_cell, .hit = release_hit } }));
            try std.testing.expectEqual(@as(?u8, null), core.step(.{ .release = .{ .plain = release_plain, .cell = release_cell, .hit = release_hit } }));
        };
    };

    // Every sequence of four events over the finite representative domain.
    const Event = enum { press_a, press_b, modified_press, empty_press, drag, cancel, release_a, release_b, modified_release, empty_release };
    const events = std.enums.values(Event);
    const count = events.len * events.len * events.len * events.len;
    for (0..count) |sequence| {
        var code = sequence;
        var core: Core = .{};
        var expected: ?u8 = null;
        for (0..4) |_| {
            const event = events[code % events.len];
            code /= events.len;
            switch (event) {
                .press_a => {
                    try std.testing.expectEqual(@as(?u8, null), core.step(.{ .press = .{ .plain = true, .cell = 0, .hit = hits[1] } }));
                    expected = 0;
                },
                .press_b => {
                    try std.testing.expectEqual(@as(?u8, null), core.step(.{ .press = .{ .plain = true, .cell = 1, .hit = hits[4] } }));
                    expected = 1;
                },
                .modified_press => {
                    try std.testing.expectEqual(@as(?u8, null), core.step(.{ .press = .{ .plain = false, .cell = 0, .hit = hits[1] } }));
                    expected = null;
                },
                .empty_press => {
                    try std.testing.expectEqual(@as(?u8, null), core.step(.{ .press = .{ .plain = true, .cell = 0, .hit = null } }));
                    expected = null;
                },
                .drag => {
                    try std.testing.expectEqual(@as(?u8, null), core.step(.drag));
                    expected = null;
                },
                .cancel => {
                    try std.testing.expectEqual(@as(?u8, null), core.step(.cancel));
                    expected = null;
                },
                .release_a => {
                    try std.testing.expectEqual(if (expected == 0) @as(?u8, 0) else null, core.step(.{ .release = .{ .plain = true, .cell = 0, .hit = hits[1] } }));
                    expected = null;
                },
                .release_b => {
                    try std.testing.expectEqual(if (expected == 1) @as(?u8, 1) else null, core.step(.{ .release = .{ .plain = true, .cell = 1, .hit = hits[4] } }));
                    expected = null;
                },
                .modified_release => {
                    try std.testing.expectEqual(@as(?u8, null), core.step(.{ .release = .{ .plain = false, .cell = 0, .hit = hits[1] } }));
                    expected = null;
                },
                .empty_release => {
                    try std.testing.expectEqual(@as(?u8, null), core.step(.{ .release = .{ .plain = true, .cell = 0, .hit = null } }));
                    expected = null;
                },
            }
        }
    }
}
