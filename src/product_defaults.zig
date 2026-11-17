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

// Approved by the accepted #1469 design-review comment on 2026-11-16.
pub const loaded_tools = "bash,find_tools,read_image,skill,web_search";

pub fn creationTools(accepts_images: bool, can_read_images: bool) struct { allowed: []const u8, loaded: []const u8 } {
    const images = accepts_images and can_read_images;
    return .{
        .allowed = if (images) tools else comptime withoutImages(tools),
        .loaded = if (images) loaded_tools else comptime withoutImages(loaded_tools),
    };
}

fn withoutImages(comptime names: []const u8) []const u8 {
    return comptime blk: {
        var selected: []const u8 = "";
        var parts = std.mem.splitScalar(u8, names, ',');
        while (parts.next()) |name| {
            if (std.mem.eql(u8, name, "read_image")) continue;
            selected = selected ++ (if (selected.len == 0) "" else ",") ++ name;
        }
        break :blk selected;
    };
}

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
    try std.testing.expect(std.mem.indexOf(u8, tools, "stop_action") != null);
    try std.testing.expectEqualStrings("bash,find_tools,read_image,skill,web_search", loaded_tools);
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

test "creation tool profiles require model image support and an available opener" {
    for ([_]bool{ false, true }) |accepts_images| {
        for ([_]bool{ false, true }) |can_read_images| {
            const images = accepts_images and can_read_images;
            const profile = creationTools(accepts_images, can_read_images);
            var allowed = std.mem.splitScalar(u8, profile.allowed, ',');
            for (std.meta.fieldNames(@import("built_in_tool.zig").BuiltInTool)) |name| {
                if (!images and std.mem.eql(u8, name, "read_image")) continue;
                try std.testing.expectEqualStrings(name, allowed.next().?);
            }
            try std.testing.expect(allowed.next() == null);
            try std.testing.expectEqualStrings(if (images) "bash,find_tools,read_image,skill,web_search" else "bash,find_tools,skill,web_search", profile.loaded);
        }
    }
}
