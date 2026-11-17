pub const active_capacity: usize = 100;

pub const intake_capacity: usize = 100;

pub const host_shutdown_seconds = 10;

pub const tools = "bash,skill,web_search";

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
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 100), active_capacity);
    try std.testing.expectEqual(@as(usize, 100), intake_capacity);
    try std.testing.expectEqualStrings("bash,skill,web_search", tools);
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
