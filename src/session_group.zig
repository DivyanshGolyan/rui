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
    rename_current: Name,

    pub const Fields = struct { name: ?Name = null, group: ?Id = null, collapsed: ?bool = null };

    pub fn fromFields(kind: std.meta.Tag(Action), fields: Fields) error{InvalidGroupOptions}!Action {
        const supplied = [_]bool{ fields.name != null, fields.group != null, fields.collapsed != null };
        const required: [3]bool = switch (kind) {
            .assign, .rename_current => .{ true, false, false },
            .leave, .automatic => .{ false, false, false },
            .rename => .{ true, true, false },
            .collapse => .{ false, true, true },
        };
        if (!std.mem.eql(bool, &supplied, &required)) return error.InvalidGroupOptions;
        return switch (kind) {
            .assign => .{ .assign = fields.name.? },
            .rename_current => .{ .rename_current = fields.name.? },
            .leave => .leave,
            .automatic => .automatic,
            .rename => .{ .rename = .{ .group = fields.group.?, .name = fields.name.? } },
            .collapse => .{ .collapse = .{ .group = fields.group.?, .collapsed = fields.collapsed.? } },
        };
    }

    pub fn validate(action: Action) error{ InvalidGroupName, InvalidGroupId }!void {
        switch (action) {
            .assign, .rename_current => |name| if (!validName(name.slice())) return error.InvalidGroupName,
            .rename => |value| {
                if (!validName(value.name.slice())) return error.InvalidGroupName;
                if (!validId(value.group)) return error.InvalidGroupId;
            },
            .collapse => |value| if (!validId(value.group)) return error.InvalidGroupId,
            .leave, .automatic => {},
        }
    }
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

test "session group action construction owns every action and field-presence combination" {
    const name = try Name.from("Work");
    const Case = struct { fields: u3, action: Action };
    const expected = .{
        .assign = Case{ .fields = 1, .action = .{ .assign = name } },
        .rename_current = Case{ .fields = 1, .action = .{ .rename_current = name } },
        .leave = Case{ .fields = 0, .action = .leave },
        .automatic = Case{ .fields = 0, .action = .automatic },
        .rename = Case{ .fields = 3, .action = .{ .rename = .{ .group = 7, .name = name } } },
        .collapse = Case{ .fields = 6, .action = .{ .collapse = .{ .group = 7, .collapsed = false } } },
    };
    inline for (comptime std.enums.values(std.meta.Tag(Action))) |kind| {
        for (0..8) |mask| for ([_]bool{ false, true }) |collapsed| {
            const fields: Action.Fields = .{
                .name = if (mask & 1 != 0) name else null,
                .group = if (mask & 2 != 0) 7 else null,
                .collapsed = if (mask & 4 != 0) collapsed else null,
            };
            const field_name = @tagName(kind);
            const case = @field(expected, field_name);
            if (mask != case.fields) {
                try std.testing.expectError(error.InvalidGroupOptions, Action.fromFields(kind, fields));
            } else {
                var action = case.action;
                if (kind == .collapse) action.collapse.collapsed = collapsed;
                try std.testing.expectEqualDeep(action, try Action.fromFields(kind, fields));
            }
        };
    }
}

test "session group action construction preserves semantic refusals for the Store" {
    const name = try Name.from("Work");
    for ([_]Id{ 0, 1, std.math.maxInt(i64), @as(u64, std.math.maxInt(i64)) + 1, std.math.maxInt(u64) }) |id| {
        const rename = try Action.fromFields(.rename, .{ .name = name, .group = id });
        const collapse = try Action.fromFields(.collapse, .{ .group = id, .collapsed = false });
        try std.testing.expectEqual(id, rename.rename.group);
        try std.testing.expectEqual(id, collapse.collapse.group);
        if (id == 1 or id == std.math.maxInt(i64)) {
            try rename.validate();
            try collapse.validate();
        } else {
            try std.testing.expectError(error.InvalidGroupId, rename.validate());
            try std.testing.expectError(error.InvalidGroupId, collapse.validate());
        }
    }
    for ([_][]const u8{ "Work", "代码", "", " ", "bad\tname", "bad\nname" }) |text| {
        const assign = try Action.fromFields(.assign, .{ .name = try Name.from(text) });
        const rename_current = try Action.fromFields(.rename_current, .{ .name = try Name.from(text) });
        const rename = try Action.fromFields(.rename, .{ .name = try Name.from(text), .group = 7 });
        try std.testing.expectEqualStrings(text, assign.assign.slice());
        try std.testing.expectEqualStrings(text, rename_current.rename_current.slice());
        try std.testing.expectEqualStrings(text, rename.rename.name.slice());
        if (std.mem.eql(u8, text, "Work") or std.mem.eql(u8, text, "代码")) {
            try assign.validate();
            try rename_current.validate();
            try rename.validate();
        } else {
            try std.testing.expectError(error.InvalidGroupName, assign.validate());
            try std.testing.expectError(error.InvalidGroupName, rename_current.validate());
            try std.testing.expectError(error.InvalidGroupName, rename.validate());
        }
    }
    try (try Action.fromFields(.leave, .{})).validate();
    try (try Action.fromFields(.automatic, .{})).validate();
}
