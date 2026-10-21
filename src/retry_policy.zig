//! Model retry policy: the wait before each retry and the Attempt maximum.
const std = @import("std");

/// Waits before Attempts 2, 3 and 4. The maximum follows from their count.
pub const default_waits_ms = Waits{ 2_000, 4_000, 8_000 };
pub const Waits = [3]u64;
pub const maximum_attempts: u64 = default_waits_ms.len + 1;

pub const Input = struct {
    waits_ms: Waits,
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
};

pub const Decision = union(enum) {
    schedule_at_ms: i64,
    exhausted,
};

/// Every wait must name a deadline from `now_ms`.
pub fn validateWaits(waits_ms: Waits, now_ms: i64) error{InvalidRetryWait}!void {
    for (waits_ms) |wait_ms| {
        if (wait_ms == 0 or wait_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
        _ = std.math.add(i64, now_ms, @intCast(wait_ms)) catch return error.InvalidRetryWait;
    }
}

pub fn decide(attempt_ordinal: u64, input: Input, now_ms: i64) !Decision {
    if (attempt_ordinal == 0 or attempt_ordinal > maximum_attempts) {
        return error.InvalidAttemptOrdinal;
    }
    for (input.waits_ms) |wait_ms| {
        if (wait_ms == 0 or wait_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
    }
    if (input.retry_after_ms) |retry_after_ms| {
        if (retry_after_ms > std.math.maxInt(i64)) return error.InvalidRetryWait;
    }
    if (attempt_ordinal == maximum_attempts) return .exhausted;
    const index: usize = @intCast(attempt_ordinal - 1);
    var due_at_ms = try std.math.add(i64, now_ms, @intCast(input.waits_ms[index]));
    if (input.retry_after_ms) |delay_ms| {
        // An external constraint that cannot name a deadline is invalid, not
        // an infrastructure failure. Preserve normal backoff and valid dates.
        const provider_due = std.math.add(i64, now_ms, @intCast(delay_ms)) catch due_at_ms;
        due_at_ms = @max(due_at_ms, provider_due);
    }
    return .{ .schedule_at_ms = @max(due_at_ms, input.retry_after_deadline_ms orelse 0) };
}

test "model retry decision applies configured waits Retry-After and exhaustion" {
    const defaults = Input{ .waits_ms = default_waits_ms };
    try std.testing.expectEqual(Decision{ .schedule_at_ms = 2_000 }, try decide(1, defaults, 0));
    try std.testing.expectEqual(Decision{ .schedule_at_ms = 4_000 }, try decide(2, defaults, 0));
    try std.testing.expectEqual(Decision{ .schedule_at_ms = 8_000 }, try decide(3, defaults, 0));
    try std.testing.expectEqual(Decision.exhausted, try decide(4, defaults, 0));

    try std.testing.expectEqual(Decision{ .schedule_at_ms = 6_000 }, try decide(2, .{
        .waits_ms = defaults.waits_ms,
        .retry_after_ms = 6_000,
    }, 0));
    try std.testing.expectEqual(Decision{ .schedule_at_ms = 8_000 }, try decide(3, .{
        .waits_ms = defaults.waits_ms,
        .retry_after_ms = 6_000,
    }, 0));

    try std.testing.expectError(error.InvalidAttemptOrdinal, decide(0, defaults, 0));
    try std.testing.expectError(error.InvalidAttemptOrdinal, decide(5, defaults, 0));
    try std.testing.expectError(error.InvalidRetryWait, decide(1, .{
        .waits_ms = .{ 0, 4_000, 8_000 },
    }, 0));
    try std.testing.expectError(error.InvalidRetryWait, decide(1, .{
        .waits_ms = .{ @as(u64, @intCast(std.math.maxInt(i64))) + 1, 4_000, 8_000 },
    }, 0));
    try std.testing.expectError(error.InvalidRetryWait, decide(1, .{
        .waits_ms = defaults.waits_ms,
        .retry_after_ms = @as(u64, @intCast(std.math.maxInt(i64))) + 1,
    }, 0));
}

test "retry dates stay absolute across body transfer and checked settlement arithmetic" {
    const now_ms: i64 = 1_700_000_015_000;
    const waits = default_waits_ms;
    // Headers arrived fifteen seconds ago with a date ten seconds ahead.
    // A progressing body crossed that deadline: only normal backoff remains.
    for ([_]i64{ now_ms - 5_000, now_ms, now_ms + 1_000 }) |deadline| {
        try std.testing.expectEqual(Decision{ .schedule_at_ms = now_ms + 2_000 }, try decide(1, .{
            .waits_ms = waits,
            .retry_after_deadline_ms = deadline,
        }, now_ms));
    }
    try std.testing.expectEqual(Decision{ .schedule_at_ms = now_ms + 10_000 }, try decide(1, .{
        .waits_ms = waits,
        .retry_after_deadline_ms = now_ms + 10_000,
        .retry_after_ms = 6_000,
    }, now_ms));
    try std.testing.expectEqual(Decision{ .schedule_at_ms = now_ms + 6_000 }, try decide(1, .{
        .waits_ms = waits,
        .retry_after_deadline_ms = now_ms + 3_000,
        .retry_after_ms = 6_000,
    }, now_ms));
    try std.testing.expectEqual(Decision.exhausted, try decide(4, .{
        .waits_ms = waits,
        .retry_after_deadline_ms = std.math.maxInt(i64),
    }, now_ms));
    const extreme_delay: u64 = 9_223_372_036_854_775_000;
    try std.testing.expectEqual(Decision{ .schedule_at_ms = now_ms + 2_000 }, try decide(1, .{
        .waits_ms = waits,
        .retry_after_ms = extreme_delay,
    }, now_ms));
    try std.testing.expectEqual(Decision{ .schedule_at_ms = now_ms + 10_000 }, try decide(1, .{
        .waits_ms = waits,
        .retry_after_ms = extreme_delay,
        .retry_after_deadline_ms = now_ms + 10_000,
    }, now_ms));
    try std.testing.expectError(error.Overflow, decide(1, .{ .waits_ms = waits }, std.math.maxInt(i64) - 1));
}

test "configured waits must name a deadline from now" {
    try validateWaits(default_waits_ms, 0);
    try std.testing.expectError(error.InvalidRetryWait, validateWaits(.{ 2_000, 0, 8_000 }, 0));
    try std.testing.expectError(error.InvalidRetryWait, validateWaits(.{ 2_000, 4_000, 8_000 }, std.math.maxInt(i64) - 4_000));
}
