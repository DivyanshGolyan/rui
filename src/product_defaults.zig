const std = @import("std");

pub const active_capacity: usize = 100;

pub const intake_capacity: usize = 100;

pub const host_shutdown_seconds = 10;

pub const tools = blk: {
    var names: []const u8 = "";
    for (std.meta.fieldNames(@import("built_in_tool.zig").BuiltInTool), 0..) |field, index| {
        names = names ++ (if (index == 0) "" else ",") ++ field;
    }
    break :blk names;
};

pub const loaded_tools = "bash,find_tools,skill,web_search";

pub const permission_mode = "bypass";

pub const provider = "codex";

pub const recommended_model = "gpt-6.1-sol";

pub const reasoning_effort = "low";

pub const compaction_trigger_percent: u64 = 90;

pub const provider_compaction_triggers = [_]struct { provider: []const u8, tokens: u64 }{
    .{ .provider = "codex", .tokens = 244800 },
};

pub const unlisted_context_window: u64 = 128000;

pub const output_reservation: u64 = 0;

test "approved product defaults" {
    try std.testing.expectEqual(@as(usize, 100), active_capacity);
    try std.testing.expectEqual(@as(usize, 100), intake_capacity);
    var allowed = std.mem.splitScalar(u8, tools, ',');
    for (std.meta.fieldNames(@import("built_in_tool.zig").BuiltInTool)) |name| try std.testing.expectEqualStrings(name, allowed.next().?);
    try std.testing.expect(allowed.next() == null);
    try std.testing.expectEqualStrings("bash,find_tools,skill,web_search", loaded_tools);
    try std.testing.expectEqualStrings("bypass", permission_mode);
    try std.testing.expectEqualStrings("codex", provider);
    try std.testing.expectEqualStrings("gpt-6.1-sol", recommended_model);
    try std.testing.expectEqualStrings("low", reasoning_effort);
    try std.testing.expectEqual(@as(u64, 90), compaction_trigger_percent);
    try std.testing.expectEqual(@as(usize, 1), provider_compaction_triggers.len);
    try std.testing.expectEqualStrings("codex", provider_compaction_triggers[0].provider);
    try std.testing.expectEqual(@as(u64, 244800), provider_compaction_triggers[0].tokens);
    try std.testing.expectEqual(@as(u64, 128000), unlisted_context_window);
    try std.testing.expectEqual(@as(u64, 0), output_reservation);
}
