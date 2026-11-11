//! Session setting facts shared by the wire, Store and caller adapters.
//! Representation and setting-specific behavior stay with those adapters.
const std = @import("std");

pub const Kind = union(enum) { text: usize, choice: usize, content, tools, decimal_policy };
pub const Create = enum { optional, must_value, must_state };
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
    /// A streamed JSON object rather than a streamed text string.
    json_object: bool = false,
    create: Create = .optional,
    changeable: bool = true,
    cli: ?Cli,
    digest: enum { always, unless_omitted } = .always,
    column: []const u8,
};

/// Configuration declaration order is also the legacy digest order, except
/// loaded_tools: its compatibility extension is hashed after require_model.
pub const entries = [_]Entry{
    .{ .field = "workspace", .spec = "workspace", .kind = .{ .text = 4096 }, .changeable = false, .cli = .{ .name = "workspace" }, .column = "workspace" },
    .{ .field = "provider", .spec = "provider", .kind = .{ .choice = 16 }, .changeable = false, .cli = .{ .name = "provider", .group = .binding }, .column = "provider" },
    .{ .field = "model", .spec = "model", .kind = .{ .text = 256 }, .create = .must_value, .changeable = true, .cli = .{ .name = "model", .group = .binding }, .column = "model" },
    .{ .field = "instructions", .spec = "instructions", .kind = .content, .cli = .{ .name = "instructions", .on_start = false }, .column = "instructions_content_id" },
    .{ .field = "tools", .spec = "tools", .kind = .tools, .create = .must_value, .cli = .{ .name = "tools" }, .column = "tool_set_id" },
    .{ .field = "loaded_tools", .spec = "loadedTools", .kind = .tools, .cli = .{ .name = "loaded-tools" }, .digest = .unless_omitted, .column = "loaded_tool_set_id" },
    .{ .field = "permission_mode", .spec = "permissionMode", .kind = .{ .choice = 16 }, .create = .must_value, .cli = .{ .name = "permission-mode" }, .column = "permission_mode" },
    .{ .field = "output_schema", .spec = "outputSchema", .kind = .content, .json_object = true, .nullable = true, .cli = .{ .name = "output-schema", .on_start = false }, .column = "output_schema_content_id" },
    .{ .field = "compaction_trigger", .spec = "compactAt", .kind = .decimal_policy, .nullable = true, .create = .must_value, .cli = .{ .name = "compaction-trigger" }, .column = "compaction_trigger" },
    .{ .field = "output_reservation", .spec = "outputReservation", .kind = .decimal_policy, .nullable = true, .cli = .{ .name = "output-reservation" }, .column = "output_reservation" },
    .{ .field = "reasoning_effort", .spec = "effort", .kind = .{ .choice = 16 }, .nullable = true, .create = .must_state, .cli = .{ .name = "reasoning-effort" }, .column = "reasoning_effort" },
    .{ .field = "label", .spec = "label", .kind = .{ .text = 100 }, .nullable = true, .cli = .{ .name = "label" }, .column = "label" },
};

/// Create-only relations share the spec grammar, not settings/revision tags.
pub const relations = [_]Entry{
    .{ .field = "parent", .spec = "parent", .kind = .{ .text = 6 }, .changeable = false, .cli = null, .digest = .unless_omitted, .column = "parent_ref" },
};
pub const spec_entries = entries ++ relations;

/// Workspace is not revisioned. Provider remains in the persisted tag domain
/// even though changing it is refused; removing it would change Store format.
pub const revision_fields = blk: {
    var names: []const []const u8 = &.{};
    for (entries) |entry| if (!std.mem.eql(u8, entry.field, "workspace")) {
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
    try std.testing.expectEqual(expected.field_names.len, actual.field_names.len);
    inline for (expected.field_names, actual.field_names, expected.field_values, actual.field_values) |old, new, old_value, new_value| {
        try std.testing.expectEqualStrings(old, new);
        try std.testing.expectEqual(old_value, new_value);
    }
}
