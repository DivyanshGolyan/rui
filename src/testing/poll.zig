const std = @import("std");

pub fn waitUntil(io: std.Io, deadline: std.Io.Clock.Timestamp, context: anytype, comptime condition: anytype) !void {
    while (true) {
        const result = condition(context);
        const ready = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
        const remaining = deadline.durationFromNow(io).raw.nanoseconds;
        if (remaining <= 0) return error.Timeout;
        if (ready) return;
        try io.sleep(.fromNanoseconds(@min(remaining, std.time.ns_per_ms)), deadline.clock);
    }
}

pub fn isSet(flag: *const std.atomic.Value(bool)) bool {
    return flag.load(.acquire);
}

pub fn after(io: std.Io, duration: std.Io.Duration) std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = duration, .clock = .awake });
}
