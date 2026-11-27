//! The latest usage a served connection reported, by connection name.
//! A reading is the primary and secondary window a signed-in route sent with a reply (used percent, window length, reset time) and when it was seen.
//! It is a cache, not a record: it lives in Host memory, a reply without readable numbers leaves the previous reading in place, and a name never read has none.
const std = @import("std");
const connection = @import("connection.zig");
const connection_names = @import("connection_names.zig");
const protocol = @import("protocol.zig");
const provider = @import("provider.zig");
const Self = @This();

pub const Window = protocol.UsageWindow;
pub const Reading = protocol.UsageReading;

fn any(reading: Reading) bool {
    return reading.primary != null or reading.secondary != null;
}

io: std.Io,
mutex: std.Io.Mutex = .init,
latest: connection_names.NameArray(Reading) = .{},

pub fn init(io: std.Io) Self {
    return .{ .io = io };
}

/// The reading an observation carries: a window counts only when its used percent and length are both numbers.
pub fn readingOf(observation: provider.AllowanceObservation) Reading {
    return .{ .observed_at = @intCast(@max(observation.observed_at, 0)), .primary = windowOf(observation.primary), .secondary = windowOf(observation.secondary) };
}

fn windowOf(window: provider.AllowanceWindow) ?Window {
    const used = switch (window.used) {
        .value => |value| value,
        .missing, .invalid => return null,
    };
    const minutes = switch (window.minutes) {
        .value => |value| value,
        .missing, .invalid => return null,
    };
    return .{ .used_percent = used, .minutes = minutes, .reset_at = switch (window.reset_at) {
        .value => |value| value,
        .missing, .invalid => null,
    } };
}

/// Keeps what the observation says for its connection; one with no readable window changes nothing.
pub fn record(self: *Self, observation: provider.AllowanceObservation) void {
    const reading = readingOf(observation);
    if (!any(reading)) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.latest.set(observation.provider, reading) catch {};
}

pub fn get(self: *Self, name: connection.Name) ?Reading {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.latest.get(name);
}

fn observed(name: []const u8, at: i64, primary: provider.AllowanceWindow, secondary: provider.AllowanceWindow) provider.AllowanceObservation {
    return .{ .binding = std.mem.zeroes(@FieldType(provider.AllowanceObservation, "binding")), .provider = connection.Name.parse(name).?, .status = 200, .observed_at = at, .primary = primary, .secondary = secondary };
}

test "CM-67 a connection's reading keeps the last readable windows and ignores a reply without numbers" {
    var usage: Self = .init(std.testing.io);
    const week: provider.AllowanceWindow = .{ .used = .{ .value = 25.5 }, .minutes = .{ .value = 10080 }, .reset_at = .{ .value = 1700000000 } };
    const bare: provider.AllowanceWindow = .{ .used = .{ .value = 3 }, .minutes = .invalid };
    const work = connection.Name.parse("work").?;
    try std.testing.expectEqual(@as(?Reading, null), usage.get(work));
    usage.record(observed("work", 10, bare, .{}));
    try std.testing.expectEqual(@as(?Reading, null), usage.get(work));
    usage.record(observed("work", 20, week, bare));
    const first = usage.get(work).?;
    try std.testing.expectEqual(@as(u64, 20), first.observed_at);
    try std.testing.expectEqual(@as(?Window, .{ .used_percent = 25.5, .minutes = 10080, .reset_at = 1700000000 }), first.primary);
    try std.testing.expectEqual(@as(?Window, null), first.secondary);
    usage.record(observed("work", 30, .{}, .{}));
    try std.testing.expectEqual(@as(u64, 20), usage.get(work).?.observed_at);
    usage.record(observed("work", 40, .{}, .{ .used = .{ .value = 100 }, .minutes = .{ .value = 300 } }));
    const later = usage.get(work).?;
    try std.testing.expectEqual(@as(u64, 40), later.observed_at);
    try std.testing.expectEqual(@as(?Window, null), later.primary);
    try std.testing.expectEqual(@as(?Window, .{ .used_percent = 100, .minutes = 300, .reset_at = null }), later.secondary);
    try std.testing.expectEqual(@as(?Reading, null), usage.get(connection.Name.parse("codex").?));
}
