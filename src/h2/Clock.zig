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
