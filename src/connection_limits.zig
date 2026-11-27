//! Which served connections are at a usage limit right now, from the readings `host_info` carries.
//! A reading is a fact about when it was seen: a window at its limit whose reset time has passed no longer limits anything.
const std = @import("std");
const connection_names = @import("connection_names.zig");
const protocol = @import("protocol.zig");

/// Whether `reading` shows a window at its limit that has not yet reset at Unix second `now`.
/// A window that gives no reset time stays limiting until a newer reading replaces it.
pub fn limited(reading: ?protocol.UsageReading, now: u64) bool {
    const seen = reading orelse return false;
    inline for (.{ seen.primary, seen.secondary }) |maybe| if (maybe) |window| {
        if (window.used_percent >= 100 and (window.reset_at orelse std.math.maxInt(u64)) > now) return true;
    };
    return false;
}

/// The names in `facts` that are limited at `now`.
pub fn limitedNames(facts: []const protocol.ConnectionFact, now: u64) connection_names.NameSet {
    var names: connection_names.NameSet = .{};
    for (facts) |fact| if (limited(fact.usage, now)) names.insert(fact.name) catch unreachable;
    return names;
}

fn full(reset_at: ?u64) protocol.UsageWindow {
    return .{ .used_percent = 100, .minutes = 300, .reset_at = reset_at };
}

test "SUI-184 a connection is limited only while a window at its limit has not reset" {
    const now: u64 = 1_800_000_000;
    const open: protocol.UsageWindow = .{ .used_percent = 99.9, .minutes = 10080, .reset_at = now + 100 };
    try std.testing.expect(!limited(null, now));
    try std.testing.expect(!limited(.{ .observed_at = now, .primary = open, .secondary = null }, now));
    try std.testing.expect(limited(.{ .observed_at = now, .primary = full(now + 1), .secondary = null }, now));
    try std.testing.expect(limited(.{ .observed_at = now, .primary = open, .secondary = full(now + 60) }, now));
    try std.testing.expect(limited(.{ .observed_at = now, .primary = full(null), .secondary = null }, now));
    try std.testing.expect(!limited(.{ .observed_at = now - 9, .primary = full(now), .secondary = null }, now));
    try std.testing.expect(!limited(.{ .observed_at = now - 9, .primary = full(now - 1), .secondary = open }, now));
}
