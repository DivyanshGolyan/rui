//! Shared live-memory text, widest first; drop tools before rui.
const std = @import("std");
const Memory = @import("process_memory.zig").Memory;
const mib = 1024 * 1024;

/// Returned strings belong to arena. Null memory draws nothing before the first read.
pub fn choices(arena: std.mem.Allocator, memory: ?Memory, unicode: bool) error{OutOfMemory}![3][]const u8 {
    const live = memory orelse return .{ "", "", "" };
    var buffer: [16]u8 = undefined;
    const rui = try std.fmt.allocPrint(arena, "rui {s}", .{sizeText(&buffer, live.rui)});
    const bytes = live.tools orelse return .{ rui, "", "" };
    const tools = try std.fmt.allocPrint(arena, "tools {s}", .{sizeText(&buffer, bytes)});
    return .{ try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ rui, if (unicode) "·" else ".", tools }), rui, "" };
}

/// Memory in whole mebibytes, or gibibytes to a tenth, as `42 MB` or `1.8 GB`.
fn sizeText(buffer: *[16]u8, bytes: u64) []const u8 {
    const gib = 1024 * mib;
    if (bytes >= gib) {
        const tenths = (bytes / (gib / 10)) + @intFromBool(bytes % (gib / 10) >= gib / 20);
        return std.fmt.bufPrint(buffer, "{d}.{d} GB", .{ tenths / 10, tenths % 10 }) catch unreachable;
    }
    return std.fmt.bufPrint(buffer, "{d} MB", .{(bytes + mib / 2) / mib}) catch unreachable;
}

test "live memory text covers absent tools rounding and the GiB boundary" {
    const Case = struct { memory: ?Memory, full: []const u8, reduced: []const u8 = "" };
    const gib = 1024 * mib;
    const cases = [_]Case{
        .{ .memory = null, .full = "" },
        .{ .memory = .{ .rui = 0, .tools = null }, .full = "rui 0 MB" },
        .{ .memory = .{ .rui = 38 * mib, .tools = null }, .full = "rui 38 MB" },
        .{ .memory = .{ .rui = 9 * mib, .tools = mib }, .full = "rui 9 MB · tools 1 MB", .reduced = "rui 9 MB" },
        .{ .memory = .{ .rui = 38 * mib, .tools = 120 * mib }, .full = "rui 38 MB · tools 120 MB", .reduced = "rui 38 MB" },
        .{ .memory = .{ .rui = mib / 2 - 1, .tools = mib / 2 }, .full = "rui 0 MB · tools 1 MB", .reduced = "rui 0 MB" },
        .{ .memory = .{ .rui = gib - 1, .tools = gib }, .full = "rui 1024 MB · tools 1.0 GB", .reduced = "rui 1024 MB" },
        .{ .memory = .{ .rui = gib + gib / 2, .tools = 0 }, .full = "rui 1.5 GB · tools 0 MB", .reduced = "rui 1.5 GB" },
        .{ .memory = .{ .rui = std.math.maxInt(u64), .tools = null }, .full = "rui 17179869248.0 GB" },
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        const text = try choices(arena.allocator(), case.memory, true);
        try std.testing.expectEqualStrings(case.full, text[0]);
        try std.testing.expectEqualStrings(case.reduced, text[1]);
        try std.testing.expectEqualStrings("", text[2]);
    }
    const ascii = try choices(arena.allocator(), .{ .rui = 38 * mib, .tools = 120 * mib }, false);
    try std.testing.expectEqualStrings("rui 38 MB . tools 120 MB", ascii[0]);
    try std.testing.expectEqualStrings("rui 38 MB", ascii[1]);
}
