//! The one place Zig test code sleeps to wait (CODING_STANDARDS.md#evidence).
//! Every other sleep in a test counts against tests/ci's SLEEP_ORDERED.

const std = @import("std");

/// Re-checks `condition(context)` every millisecond until it holds, or
/// returns `error.Timeout`. A check that finishes at or after `deadline`
/// does not count, as in Python's `wait_for`. `condition` returns `bool` or
/// an error union of `bool`.
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

/// A `waitUntil` condition for a flag another thread sets.
pub fn isSet(flag: *const std.atomic.Value(bool)) bool {
    return flag.load(.acquire);
}

/// A deadline `duration` from now on the awake clock.
pub fn after(io: std.Io, duration: std.Io.Duration) std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = duration, .clock = .awake });
}
