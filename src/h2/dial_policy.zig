const std = @import("std");
const policy = @import("policy.zig");

const Cause = policy.Cause;

/// How a proxy's answer to CONNECT ends the setup, or null when the tunnel
/// is open: any 2xx (RFC 9110 section 9.3.6).
pub fn tunnelRefusal(status: u16) ?Cause {
    return switch (status) {
        200...299 => null,
        407 => .proxy_auth_required,
        403 => .proxy_refused,
        else => .proxy_failed,
    };
}

pub const max_attempts = 2;

/// How long an attempt runs before the next address's starts (RFC 8305
/// section 5).
pub const attempt_delay_ns = 250_000_000;

pub const AttemptFacts = struct {
    in_flight: u8,
    more_addresses: bool,
    failed: bool,
    delay_passed: bool,
};

pub fn nextAttempt(facts: AttemptFacts) enum { wait, start, replace_oldest, fail } {
    std.debug.assert(facts.in_flight <= max_attempts);
    if (!facts.more_addresses) return if (facts.in_flight == 0) .fail else .wait;
    if (facts.in_flight == 0 or facts.failed) return .start;
    if (!facts.delay_passed) return .wait;
    return if (facts.in_flight < max_attempts) .start else .replace_oldest;
}

fn with(base: anytype, comptime field: []const u8, value: anytype) @TypeOf(base) {
    var facts = base;
    @field(facts, field) = value;
    return facts;
}

test "any 2xx opens the tunnel; 407 and 403 are their own causes" {
    for ([_]u16{ 200, 204, 299 }) |status| try std.testing.expectEqual(@as(?Cause, null), tunnelRefusal(status));
    try std.testing.expectEqual(@as(?Cause, .proxy_auth_required), tunnelRefusal(407));
    try std.testing.expectEqual(@as(?Cause, .proxy_refused), tunnelRefusal(403));
    for ([_]u16{ 100, 301, 400, 404, 502, 503 }) |status| try std.testing.expectEqual(@as(?Cause, .proxy_failed), tunnelRefusal(status));
}

test "the next address starts on a failure or after the delay, the oldest of two giving way" {
    const Case = struct { in_flight: u8, more: bool, failed: bool, delay_passed: bool, step: @TypeOf(nextAttempt(undefined)) };
    const cases = [_]Case{
        .{ .in_flight = 0, .more = false, .failed = true, .delay_passed = true, .step = .fail },
        .{ .in_flight = 1, .more = false, .failed = true, .delay_passed = true, .step = .wait },
        .{ .in_flight = 2, .more = false, .failed = false, .delay_passed = true, .step = .wait },
        .{ .in_flight = 0, .more = true, .failed = false, .delay_passed = false, .step = .start },
        .{ .in_flight = 1, .more = true, .failed = true, .delay_passed = false, .step = .start },
        .{ .in_flight = 1, .more = true, .failed = false, .delay_passed = false, .step = .wait },
        .{ .in_flight = 1, .more = true, .failed = false, .delay_passed = true, .step = .start },
        .{ .in_flight = 2, .more = true, .failed = false, .delay_passed = false, .step = .wait },
        .{ .in_flight = 2, .more = true, .failed = false, .delay_passed = true, .step = .replace_oldest },
    };
    for (cases) |case| try std.testing.expectEqual(case.step, nextAttempt(.{
        .in_flight = case.in_flight,
        .more_addresses = case.more,
        .failed = case.failed,
        .delay_passed = case.delay_passed,
    }));
}
