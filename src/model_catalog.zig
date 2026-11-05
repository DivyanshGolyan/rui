//! Model facts only, not account availability or per-Adapter limits.
const std = @import("std");
/// Local identifier syntax admits 1 to this many printable ASCII bytes.
pub const max_model_bytes = 256;

/// Rui's closed effort grammar, ordered from lowest to highest.
pub const ReasoningEffort = enum { none, low, medium, high, xhigh, max };

/// Syntax only, not catalog membership or account entitlement.
pub fn validModelSyntax(model: []const u8) bool {
    if (model.len == 0 or model.len > max_model_bytes) return false;
    for (model) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

/// Six effort flags packed into one byte. No default effort is inferred.
/// Their tag order (none, low, medium, high, xhigh, max) is part of the
/// Store format: bits 0..5 are persisted in model_fact.efforts. Changing
/// this order or set requires a new schema version and migration.
pub const Efforts = std.enums.EnumSet(ReasoningEffort);

pub const Entry = struct {
    id: []const u8,
    context_window: ?u32,
    efforts: Efforts,
    openai_listed: bool,
};

pub const shipped = @import("model_catalog_snapshot.zig").entries(Entry);

/// OpenAI IDs in catalog order: the list for ChatGPT, which has no public list.
pub const openai_ids = blk: {
    @setEvalBranchQuota(20000);
    var count: usize = 0;
    for (shipped) |entry| if (entry.openai_listed) {
        count += 1;
    };
    var ids: [count][]const u8 = undefined;
    var at: usize = 0;
    for (shipped) |entry| if (entry.openai_listed) {
        ids[at] = entry.id;
        at += 1;
    };
    break :blk ids;
};

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
        .{ .id = "a", .context_window = null, .efforts = .{}, .openai_listed = false },
        .{ .id = "c", .context_window = 42, .efforts = .init(.{ .high = true }), .openai_listed = true },
    };
    try std.testing.expect(find(&.{}, "a") == null);
    try std.testing.expectEqualStrings("a", find(entries, "a").?.id);
    try std.testing.expectEqual(@as(?u32, 42), find(entries, "c").?.context_window);
    for ([_][]const u8{ "", "A", "b", "cc", "z" }) |id|
        try std.testing.expect(find(entries, id) == null);
}

test "model catalog shipped facts are sorted unique and valid" {
    for (shipped, 0..) |entry, i| {
        try std.testing.expect(validModelSyntax(entry.id));
        if (i != 0) try std.testing.expect(std.mem.order(u8, shipped[i - 1].id, entry.id) == .lt);
    }
    const recommended = find(shipped, @import("product_defaults.zig").recommended_model).?;
    try std.testing.expect(recommended.openai_listed);
    const sol = find(shipped, "gpt-6.1-sol").?;
    try std.testing.expectEqual(@as(?u32, 1050000), sol.context_window);
    try std.testing.expectEqual(Efforts.init(.{ .low = true, .medium = true, .high = true, .xhigh = true, .max = true }), sol.efforts);
    const terra = find(shipped, "gpt-6.1-terra").?;
    try std.testing.expect(terra.efforts.contains(.none));
}

test "model catalog effort bits are part of the Store format" {
    const cases = .{
        .{ .none, 1 },
        .{ .low, 2 },
        .{ .medium, 4 },
        .{ .high, 8 },
        .{ .xhigh, 16 },
        .{ .max, 32 },
    };
    try std.testing.expectEqual(@as(usize, 6), std.enums.values(ReasoningEffort).len);
    inline for (cases) |case| {
        try std.testing.expectEqual(@as(u8, case[1]), @as(u8, @intCast(Efforts.initOne(case[0]).bits.mask)));
    }
}
