const std = @import("std");
const model_capability = @import("model_capability.zig");

pub const PermissionMode = enum { ask, bypass };
pub const Notification = enum { on, off };
pub const ReportProfile = enum { current, full };
pub const FailedResponsePart = enum { body, metadata };

pub const ReasoningChoice = blk: {
    const tags = @typeInfo(model_capability.ReasoningEffort).@"enum".field_names ++ .{"default"};
    var values: [tags.len]u8 = undefined;
    for (&values, 0..) |*value, i| value.* = @intCast(i);
    break :blk @Enum(u8, .exhaustive, tags, &values);
};

pub const CommandKind = @import("command_spec.zig").CommandKind;

pub const RecoveryKind = blk: {
    const source = @typeInfo(CommandKind).@"enum";
    var tags: [source.field_names.len][]const u8 = undefined;
    var values: [source.field_names.len]u8 = undefined;
    for (source.field_names, 0..) |tag, i| {
        var text = tag[0..tag.len].*;
        std.mem.replaceScalar(u8, &text, '_', '-');
        const name = text;
        tags[i] = &name;
        values[i] = @intCast(i);
    }
    break :blk @Enum(u8, .exhaustive, &tags, &values);
};

pub fn commandKind(kind: RecoveryKind) CommandKind {
    return @fromBackingInt(@intCast(@backingInt(kind)));
}

test "CLI choice enums preserve protocol tags and derive reset and recovery spellings" {
    const effort = @typeInfo(model_capability.ReasoningEffort).@"enum".field_names;
    const choice = @typeInfo(ReasoningChoice).@"enum".field_names;
    try std.testing.expectEqual(effort.len + 1, choice.len);
    for (effort, choice[0..effort.len]) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqualStrings("default", choice[effort.len]);
    const expected = [_][]const u8{ "configure", "message", "session-stop", "session-archive", "model-interruption", "permission-decision", "session-pin", "action-background" };
    inline for (comptime std.meta.tags(RecoveryKind), expected) |kind, name| {
        try std.testing.expectEqualStrings(name, @tagName(kind));
        const command = commandKind(kind);
        try std.testing.expectEqualStrings(@tagName(command), @tagName(@as(CommandKind, @fromBackingInt(@intCast(@backingInt(kind))))));
    }
}
