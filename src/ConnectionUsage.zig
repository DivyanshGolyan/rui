//! The latest usage a served connection reported, by connection name.
//! A reading is the primary and secondary window a signed-in route sent with a reply (used percent, window length, reset time) and when it was seen.
//! A reading belongs to the owner whose request it answered (a sign-in's account); the first request of another owner on the name drops it, and a reply of the old owner arriving later is ignored.
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
latest: connection_names.NameArray(Kept) = .{},

const Kept = struct { reading: ?Reading = null, seen: i64 = 0, owner: provider.RoutingOwner };

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

/// A request starts under this owner: the reading of any other owner on this name is dropped, since its numbers belong to an account that no longer serves it.
pub fn begin(self: *Self, name: connection.Name, owner: provider.RoutingOwner) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.latest.find(name)) |kept| if (std.mem.eql(u8, &kept.owner, &owner)) return;
    self.latest.set(name, .{ .owner = owner }) catch {};
}

/// Keeps what the observation says for its connection; one with no readable window, or one that answers another owner's request than the connection now has, changes nothing.
pub fn record(self: *Self, observation: provider.AllowanceObservation) void {
    const reading = readingOf(observation);
    if (!any(reading)) return;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.latest.find(observation.provider)) |kept| {
        if (!std.mem.eql(u8, &kept.owner, &observation.owner)) return;
        // Two Turns of one connection can complete out of order; the reading seen earlier never replaces one seen later, whatever the wall clock says.
        if (kept.reading != null and kept.seen > observation.seen) return;
    }
    self.latest.set(observation.provider, .{ .reading = reading, .seen = observation.seen, .owner = observation.owner }) catch {};
}

pub fn get(self: *Self, name: connection.Name) ?Reading {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return (self.latest.get(name) orelse return null).reading;
}

fn observed(name: []const u8, at: i64, seen: i64, primary: provider.AllowanceWindow, secondary: provider.AllowanceWindow) provider.AllowanceObservation {
    return .{ .binding = std.mem.zeroes(@FieldType(provider.AllowanceObservation, "binding")), .provider = connection.Name.parse(name).?, .status = 200, .observed_at = at, .seen = seen, .primary = primary, .secondary = secondary };
}

test "CM-67 a connection's reading keeps the last readable windows and ignores a reply without numbers" {
    var usage: Self = .init(std.testing.io);
    const week: provider.AllowanceWindow = .{ .used = .{ .value = 25.5 }, .minutes = .{ .value = 10080 }, .reset_at = .{ .value = 1700000000 } };
    const bare: provider.AllowanceWindow = .{ .used = .{ .value = 3 }, .minutes = .invalid };
    const work = connection.Name.parse("work").?;
    try std.testing.expectEqual(@as(?Reading, null), usage.get(work));
    usage.record(observed("work", 10, 10, bare, .{}));
    try std.testing.expectEqual(@as(?Reading, null), usage.get(work));
    usage.record(observed("work", 20, 20, week, bare));
    const first = usage.get(work).?;
    try std.testing.expectEqual(@as(u64, 20), first.observed_at);
    try std.testing.expectEqual(@as(?Window, .{ .used_percent = 25.5, .minutes = 10080, .reset_at = 1700000000 }), first.primary);
    try std.testing.expectEqual(@as(?Window, null), first.secondary);
    usage.record(observed("work", 30, 30, .{}, .{}));
    try std.testing.expectEqual(@as(u64, 20), usage.get(work).?.observed_at);
    usage.record(observed("work", 40, 40, .{}, .{ .used = .{ .value = 100 }, .minutes = .{ .value = 300 } }));
    const later = usage.get(work).?;
    try std.testing.expectEqual(@as(u64, 40), later.observed_at);
    try std.testing.expectEqual(@as(?Window, null), later.primary);
    try std.testing.expectEqual(@as(?Window, .{ .used_percent = 100, .minutes = 300, .reset_at = null }), later.secondary);
    try std.testing.expectEqual(@as(?Reading, null), usage.get(connection.Name.parse("codex").?));
    // A Turn that completes late carries an older reading; the newer one stays.
    usage.record(observed("work", 20, 20, week, .{}));
    try std.testing.expectEqual(@as(u64, 40), usage.get(work).?.observed_at);
    usage.record(observed("work", 40, 40, week, .{}));
    try std.testing.expectEqual(@as(?Window, null), usage.get(work).?.secondary);
}

test "CM-71 a connection's reading belongs to its sign-in: another owner's first request drops it and the old owner's late reply cannot restore it" {
    var usage: Self = .init(std.testing.io);
    const week: provider.AllowanceWindow = .{ .used = .{ .value = 40 }, .minutes = .{ .value = 10080 }, .reset_at = .{ .value = 1700000000 } };
    const work = connection.Name.parse("work").?;
    const first: provider.RoutingOwner = @splat(1);
    const second: provider.RoutingOwner = @splat(2);
    var read = observed("work", 10, 10, week, .{});
    read.owner = first;
    usage.begin(work, first);
    usage.record(read);
    try std.testing.expectEqual(@as(u64, 10), usage.get(work).?.observed_at);
    // The same owner starting again keeps its reading.
    usage.begin(work, first);
    try std.testing.expectEqual(@as(u64, 10), usage.get(work).?.observed_at);
    // Another account's first request: nothing is shown until it reports its own.
    usage.begin(work, second);
    try std.testing.expectEqual(@as(?Reading, null), usage.get(work));
    // The first account's reply finishing late is not attributed to the second.
    read.observed_at = 20;
    read.seen = 20;
    usage.record(read);
    try std.testing.expectEqual(@as(?Reading, null), usage.get(work));
    // The second account's own reply is kept, even though it was seen earlier than the late one.
    var own = observed("work", 15, 5, week, .{});
    own.owner = second;
    usage.record(own);
    try std.testing.expectEqual(@as(u64, 15), usage.get(work).?.observed_at);
    // Another connection is untouched.
    try std.testing.expectEqual(@as(?Reading, null), usage.get(connection.Name.parse("home").?));
    // Switching back to the first account drops the second's reading too.
    usage.begin(work, first);
    try std.testing.expectEqual(@as(?Reading, null), usage.get(work));
}
