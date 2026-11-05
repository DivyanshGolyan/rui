//! Model facts only, not account availability or per-Adapter limits.
const std = @import("std");
const model_capability = @import("model_capability.zig");

/// Six effort flags packed into one byte. No default effort is inferred.
pub const Efforts = std.enums.EnumSet(model_capability.ReasoningEffort);

pub const Entry = struct {
    id: []const u8,
    context_window: ?u32,
    efforts: Efforts,
    openai: bool,
};

pub const shipped = @import("model_catalog_snapshot.zig").entries(Entry);

/// Exact, case-sensitive lookup in a bytewise-sorted catalog.
pub fn find(entries: []const Entry, id: []const u8) ?*const Entry {
    var start: usize = 0;
    var end = entries.len;
    while (start < end) {
        const mid = start + (end - start) / 2;
        switch (std.mem.order(u8, entries[mid].id, id)) {
            .eq => return &entries[mid],
            .lt => start = mid + 1,
            .gt => end = mid,
        }
    }
    return null;
}

test "model catalog lookup is exact and case sensitive" {
    const entries: []const Entry = &.{
        .{ .id = "a", .context_window = null, .efforts = .{}, .openai = false },
        .{ .id = "c", .context_window = 42, .efforts = .init(.{ .high = true }), .openai = true },
    };
    try std.testing.expect(find(&.{}, "a") == null);
    try std.testing.expectEqualStrings("a", find(entries, "a").?.id);
    try std.testing.expectEqual(@as(?u32, 42), find(entries, "c").?.context_window);
    for ([_][]const u8{ "", "A", "b", "cc", "z" }) |id|
        try std.testing.expect(find(entries, id) == null);
}

test "model catalog shipped facts are sorted unique and valid" {
    for (shipped, 0..) |entry, i| {
        try std.testing.expect(model_capability.validModelSyntax(entry.id));
        if (i != 0) try std.testing.expect(std.mem.order(u8, shipped[i - 1].id, entry.id) == .lt);
    }
    const recommended = find(shipped, @import("product_defaults.zig").recommended_model).?;
    try std.testing.expect(recommended.openai);
    const sol = find(shipped, "gpt-6.1-sol").?;
    try std.testing.expectEqual(@as(?u32, 1050000), sol.context_window);
    try std.testing.expectEqual(Efforts.init(.{ .low = true, .medium = true, .high = true, .xhigh = true, .max = true }), sol.efforts);
    const terra = find(shipped, "gpt-6.1-terra").?;
    try std.testing.expect(terra.efforts.contains(.none));
}
