//! Live-memory text and the one rule for which form fits: the full figure,
//! then rui alone (tools drops first), then nothing.
const std = @import("std");
const Memory = @import("process_memory.zig").Memory;
const display_text = @import("display_text.zig");
const mib = 1024 * 1024;

/// The widest form of the memory figure that fits `columns`, or "" when none
/// does. Null memory draws nothing before the first read. The result belongs to arena.
pub fn fit(arena: std.mem.Allocator, memory: ?Memory, unicode: bool, columns: u16) error{OutOfMemory}![]const u8 {
    for (try choices(arena, memory, unicode)) |text| {
        if (display_text.width(text, .terminal) <= columns) return text;
    }
    return "";
}

/// Widest first; the last is always empty.
fn choices(arena: std.mem.Allocator, memory: ?Memory, unicode: bool) error{OutOfMemory}![3][]const u8 {
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

test "memory fits its widest form: full, then rui alone, then nothing, at every width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const Case = struct { memory: ?Memory, unicode: bool, full: []const u8, rui: []const u8 };
    const cases = [_]Case{
        .{ .memory = null, .unicode = true, .full = "", .rui = "" },
        .{ .memory = .{ .rui = 38 * mib, .tools = null }, .unicode = true, .full = "rui 38 MB", .rui = "rui 38 MB" },
        .{ .memory = .{ .rui = 38 * mib, .tools = 120 * mib }, .unicode = true, .full = "rui 38 MB · tools 120 MB", .rui = "rui 38 MB" },
        .{ .memory = .{ .rui = 38 * mib, .tools = 120 * mib }, .unicode = false, .full = "rui 38 MB . tools 120 MB", .rui = "rui 38 MB" },
    };
    for (cases) |case| for (0..40) |width| {
        const columns: u16 = @intCast(width);
        // "rui 38 MB · tools 120 MB" is 24 columns in either spelling; rui alone is 9.
        const expected = if (case.full.len > 0 and columns >= 24) case.full else if (case.rui.len > 0 and columns >= 9) case.rui else "";
        try std.testing.expectEqualStrings(expected, try fit(arena.allocator(), case.memory, case.unicode, columns));
    };
    try std.testing.expectEqualStrings("rui 38 MB", try fit(arena.allocator(), .{ .rui = 38 * mib, .tools = null }, true, 9));
    try std.testing.expectEqualStrings("", try fit(arena.allocator(), .{ .rui = 38 * mib, .tools = null }, true, 8));
}
