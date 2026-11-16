const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const tool_presentation = @import("tool_presentation.zig");

pub const Id = u64;
pub const Name = Bounded(100);
pub const Brief = struct { id: Id, name: Name, collapsed: bool, revision: u64 };
pub const Action = union(enum) {
    assign: Name,
    leave,
    automatic,
    rename: struct { group: Id, name: Name },
    collapse: struct { group: Id, collapsed: bool },
};
pub const Placement = struct { group: ?Id = null, manual: bool = false };
pub const Automatic = union(enum) { keep, ungrouped, inherit: Id, family, topic };

pub fn validName(name: []const u8) bool {
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return name.len <= 100 and tool_presentation.validLabel(name);
}

pub fn validId(id: Id) bool {
    return id != 0 and id <= std.math.maxInt(i64);
}

pub fn automatic(current: Placement, evaluated: bool, creator: ?Placement) Automatic {
    if (current.manual or current.group != null or evaluated) return .keep;
    if (creator) |parent| {
        if (parent.group) |id| return .{ .inherit = id };
        return if (parent.manual) .ungrouped else .family;
    }
    return .topic;
}

test "session group automatic placement preserves every manual choice" {
    for ([_]bool{ false, true }) |manual| for ([_]?Id{ null, 7 }) |group| for ([_]bool{ false, true }) |evaluated| {
        const current: Placement = .{ .group = group, .manual = manual };
        const parents = [_]?Placement{ null, .{}, .{ .manual = true }, .{ .group = 9 }, .{ .group = 9, .manual = true } };
        for (parents, 0..) |creator, index| {
            const actual = automatic(current, evaluated, creator);
            if (manual or group != null or evaluated) {
                try std.testing.expect(actual == .keep);
            } else switch (index) {
                0 => try std.testing.expect(actual == .topic),
                1 => try std.testing.expect(actual == .family),
                2 => try std.testing.expect(actual == .ungrouped),
                3, 4 => try std.testing.expectEqual(@as(Id, 9), actual.inherit),
                else => unreachable,
            }
        }
    };
}

test "session group names and identities validate their boundaries" {
    for ([_][]const u8{ "Storage", "代码", "two words" }) |name| try std.testing.expect(validName(name));
    for ([_][]const u8{ "", " ", "bad\nname", "bad\x00name", &@as([101]u8, @splat('x')) }) |name| try std.testing.expect(!validName(name));
    try std.testing.expect(!validId(0));
    try std.testing.expect(validId(1));
    try std.testing.expect(validId(std.math.maxInt(i64)));
    try std.testing.expect(!validId(std.math.maxInt(u64)));
}
