const std = @import("std");
const Clock = @This();

io: std.Io,
stall_ns: u64 = 0,

pub fn init(io: std.Io) Clock {
    return .{ .io = io };
}

pub fn now(self: *const Clock) u64 {
    return self.awake() - self.stall_ns;
}

pub fn awake(self: *const Clock) u64 {
    return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
}

pub fn charge(self: *Clock, started_awake_ns: u64) void {
    self.stall_ns += self.awake() - started_awake_ns;
}

test "now excludes the time charged to sink stalls" {
    var clock = Clock.init(std.testing.io);
    const stall_ns: u64 = 5_000_000;
    clock.charge(clock.awake() - stall_ns);
    try std.testing.expect(clock.stall_ns >= stall_ns);
    try std.testing.expect(clock.now() <= clock.awake() - stall_ns);
}
