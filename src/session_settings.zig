const std = @import("std");

pub const Kind = union(enum) { text: usize, choice: usize, content, tools, decimal_policy, app_tools };
pub const Create = enum { optional, must_value };
pub const Cli = struct {
    name: []const u8,
    group: enum { binding, settings } = .settings,
    on_start: bool = true,
};
pub const Entry = struct {
    field: []const u8,
    spec: []const u8,
    kind: Kind,
    nullable: bool = false,
    json_object: bool = false,
    create: Create = .optional,
    changeable: bool = true,
    cli: ?Cli,
    digest: enum { always, unless_omitted } = .always,
    column: []const u8,
    /// Added after the refused marker: its revision tag follows `reasoning_effort_refused`, so the tags before it
    /// never move (revision tags are append-only).
    since_refused: bool = false,
};

pub const entries = [_]Entry{
    .{ .field = "workspace", .spec = "workspace", .kind = .{ .text = 4096 }, .changeable = false, .cli = .{ .name = "workspace" }, .column = "workspace" },
    .{ .field = "provider", .spec = "connection", .kind = .{ .choice = 16 }, .changeable = true, .cli = .{ .name = "connection", .group = .binding }, .column = "provider" },
    .{ .field = "model", .spec = "model", .kind = .{ .text = 256 }, .create = .must_value, .changeable = true, .cli = .{ .name = "model", .group = .binding }, .column = "model" },
    .{ .field = "instructions", .spec = "instructions", .kind = .content, .cli = .{ .name = "instructions", .on_start = false }, .column = "instructions_content_id" },
    .{ .field = "tools", .spec = "tools", .kind = .tools, .cli = .{ .name = "tools" }, .column = "tool_set_id" },
    .{ .field = "loaded_tools", .spec = "loadedTools", .kind = .tools, .cli = .{ .name = "loaded-tools" }, .digest = .unless_omitted, .column = "loaded_tool_set_id" },
    .{ .field = "permission_mode", .spec = "permissionMode", .kind = .{ .choice = 16 }, .cli = .{ .name = "permission-mode" }, .column = "permission_mode" },
    .{ .field = "output_schema", .spec = "outputSchema", .kind = .content, .json_object = true, .nullable = true, .cli = .{ .name = "output-schema", .on_start = false }, .column = "output_schema_content_id" },
    .{ .field = "compaction_trigger", .spec = "compactAt", .kind = .decimal_policy, .nullable = true, .cli = .{ .name = "compaction-trigger" }, .column = "compaction_trigger" },
    .{ .field = "output_reservation", .spec = "outputReservation", .kind = .decimal_policy, .nullable = true, .cli = .{ .name = "output-reservation" }, .column = "output_reservation" },
    .{ .field = "reasoning_effort", .spec = "effort", .kind = .{ .choice = 16 }, .nullable = true, .cli = .{ .name = "reasoning-effort" }, .column = "reasoning_effort" },
    .{ .field = "label", .spec = "label", .kind = .{ .text = 100 }, .nullable = true, .cli = .{ .name = "label" }, .column = "label" },
    // The declared app tools of a lane root: the document is validated by tool_record.app_tools, saved as a tool set
    // and read back as the declared list. Only a lane root may declare them (a child refuses by name).
    .{ .field = "app_tools", .spec = "appTools", .kind = .app_tools, .nullable = true, .cli = null, .digest = .unless_omitted, .column = "app_tool_set_id", .since_refused = true },
};

/// The CLI spelling of a Session setting: every grammar, requirement and
/// repair line names the option through this, never a literal.
pub fn cliName(comptime field: []const u8) []const u8 {
    for (entries) |entry| if (std.mem.eql(u8, entry.field, field)) {
        return (entry.cli orelse @compileError("setting has no CLI option: " ++ field)).name;
    };
    @compileError("unknown Session setting: " ++ field);
}

pub const relations = [_]Entry{
    .{ .field = "parent", .spec = "parent", .kind = .{ .text = 6 }, .changeable = false, .cli = null, .digest = .unless_omitted, .column = "parent_ref" },
};
pub const spec_entries = entries ++ relations;

/// Revision tags in order: the settings before the refused marker, the marker, then the settings added after it.
/// A tag's ordinal is its position here, so new settings only append after the marker.
pub const revision_fields = blk: {
    var names: []const []const u8 = &.{};
    for (entries) |entry| if (!entry.since_refused and !std.mem.eql(u8, entry.field, "workspace")) {
        names = names ++ .{entry.field};
    };
    names = names ++ .{"reasoning_effort_refused"};
    for (entries) |entry| if (entry.since_refused) {
        names = names ++ .{entry.field};
    };
    break :blk names;
};

pub const SessionField = blk: {
    const Tag = std.math.IntFittingRange(0, revision_fields.len - 1);
    var values: [revision_fields.len]Tag = undefined;
    for (&values, 0..) |*value, i| value.* = @intCast(i);
    break :blk @Enum(Tag, .exhaustive, revision_fields, &values);
};

test "Session settings revision tags retain persisted names ordinals and backing type" {
    const Before = enum { provider, model, instructions, tools, loaded_tools, permission_mode, output_schema, compaction_trigger, output_reservation, reasoning_effort, label };
    const expected = @typeInfo(Before).@"enum";
    const actual = @typeInfo(SessionField).@"enum";
    try std.testing.expect(expected.tag_type == actual.tag_type);
    // The marker takes the ordinal after the eleven settings it followed, and app_tools the next: later settings append.
    try std.testing.expectEqual(expected.field_names.len + 2, actual.field_names.len);
    inline for (expected.field_names, actual.field_names[0..expected.field_names.len], expected.field_values, actual.field_values[0..expected.field_names.len]) |old, new, old_value, new_value| {
        try std.testing.expectEqualStrings(old, new);
        try std.testing.expectEqual(old_value, new_value);
    }
    try std.testing.expectEqualStrings("reasoning_effort_refused", actual.field_names[expected.field_names.len]);
    try std.testing.expectEqual(expected.field_names.len, @backingInt(SessionField.reasoning_effort_refused));
    try std.testing.expectEqualStrings("app_tools", actual.field_names[expected.field_names.len + 1]);
    try std.testing.expectEqual(expected.field_names.len + 1, @backingInt(SessionField.app_tools));
    inline for (entries) |entry| try std.testing.expect(!std.mem.eql(u8, entry.field, "reasoning_effort_refused"));
}

test "creation metadata requires only model and keeps Host defaults optional" {
    inline for (entries) |entry| {
        try std.testing.expectEqual(if (std.mem.eql(u8, entry.field, "model")) Create.must_value else Create.optional, entry.create);
    }
}
