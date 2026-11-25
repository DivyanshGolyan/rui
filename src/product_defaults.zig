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

/// A fresh Session allows and loads every built-in tool (Divyansh, 2026-11-23); only a model
/// known not to take images, or a Host that can't read them, leaves out `read_image`.
pub fn creationTools(accepts_images: bool, can_read_images: bool) []const u8 {
    return if (accepts_images and can_read_images) default_tools else comptime without(default_tools, "read_image");
}

// The Host runner for `watch_github_pr` is not wired yet, so no fresh Session loads it; `--tools` still selects it.
const default_tools = without(tools, "watch_github_pr");

fn without(comptime names: []const u8, comptime excluded: []const u8) []const u8 {
    return comptime blk: {
        var selected: []const u8 = "";
        var parts = std.mem.splitScalar(u8, names, ',');
        while (parts.next()) |name| {
            if (std.mem.eql(u8, name, excluded)) continue;
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
    .{ .provider = "chatgpt", .tokens = 244800 },
};

/// Input size above which the provider charges a higher rate; the default compaction trigger stays under it.
pub const price_steps = [_]struct { model: []const u8, tokens: u64 }{
    .{ .model = "gpt-6.1-sol", .tokens = 272000 },
    .{ .model = "gpt-6.1-terra", .tokens = 272000 },
    .{ .model = "gpt-6.2-sol", .tokens = 272000 },
};

pub const unlisted_context_window: u64 = 128000;

/// The output limit a model the catalog does not state gets: Messages requires one.
pub const unlisted_output_limit: u32 = 32000;

pub const output_reservation: u64 = 0;

test "approved product defaults" {
    try std.testing.expectEqual(@as(usize, 100), active_capacity);
    try std.testing.expectEqual(@as(usize, 100), intake_capacity);
    var allowed = std.mem.splitScalar(u8, tools, ',');
    for (std.meta.fieldNames(@import("built_in_tool.zig").BuiltInTool)) |name| try std.testing.expectEqualStrings(name, allowed.next().?);
    try std.testing.expect(allowed.next() == null);
    try std.testing.expect(std.mem.indexOf(u8, tools, "stop_action") != null);
    try std.testing.expectEqualStrings("bypass", permission_mode);
    try std.testing.expectEqualStrings("codex", provider);
    try std.testing.expectEqualStrings("gpt-6.1-sol", recommended_model);
    try std.testing.expectEqualStrings("low", reasoning_effort);
    try std.testing.expectEqual(@as(u64, 90), compaction_trigger_percent);
    try std.testing.expectEqual(@as(usize, 2), provider_compaction_triggers.len);
    for (provider_compaction_triggers, [_][]const u8{ "codex", "chatgpt" }) |entry, name| {
        try std.testing.expectEqualStrings(name, entry.provider);
        try std.testing.expectEqual(@as(u64, 244800), entry.tokens);
    }
    try std.testing.expectEqual(@as(usize, 3), price_steps.len);
    for (price_steps, [_][]const u8{ "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6.2-sol" }) |entry, model| {
        try std.testing.expectEqualStrings(model, entry.model);
        try std.testing.expectEqual(@as(u64, 272000), entry.tokens);
    }
    try std.testing.expectEqual(@as(u64, 128000), unlisted_context_window);
    try std.testing.expectEqual(@as(u32, 32000), unlisted_output_limit);
    try std.testing.expectEqual(@as(u64, 0), output_reservation);
}

test "creation tool profiles require model image support and an available opener and leave out the unwired watcher" {
    for ([_]bool{ false, true }) |accepts_images| {
        for ([_]bool{ false, true }) |can_read_images| {
            const images = accepts_images and can_read_images;
            const profile = creationTools(accepts_images, can_read_images);
            var allowed = std.mem.splitScalar(u8, profile, ',');
            for (std.meta.fieldNames(@import("built_in_tool.zig").BuiltInTool)) |name| {
                if (!images and std.mem.eql(u8, name, "read_image")) continue;
                if (std.mem.eql(u8, name, "watch_github_pr")) continue;
                try std.testing.expectEqualStrings(name, allowed.next().?);
            }
            try std.testing.expect(allowed.next() == null);
        }
    }
}
