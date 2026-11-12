//! Value decisions for the request-wait shell; no clocks or transport.
const std = @import("std");

pub const Disposition = enum { done, later, absent };

pub const default_timeout_seconds: u32 = 300;
pub const max_timeout_seconds: u32 = 86_400;

pub const first_poll_ms: u32 = 250;
pub const max_poll_ms: u32 = 2_000;

pub fn nextPoll(milliseconds: u32) u32 {
    return @min(milliseconds *| 2, max_poll_ms);
}

/// Reads only supported observation facts. Non-Message commands have no
/// Message lifecycle to follow, including rejected commands without a kind.
pub fn disposition(observation: anytype) ?Disposition {
    if (observation.status == .absent) return .absent;
    if (observation.status == .rejected or observation.kind != .message) return .done;
    const state = observation.state orelse return null;
    return switch (state) {
        .queued, .processing => null,
        .waiting_for_permission, .completed, .failed, .cancelled, .rejected => .done,
    };
}

test "request wait schedule doubles from 250 ms and caps at two seconds" {
    var delay = first_poll_ms;
    for ([_]u32{ 250, 500, 1_000, 2_000, 2_000, 2_000 }) |expected| {
        try std.testing.expectEqual(expected, delay);
        delay = nextPoll(delay);
    }
    try std.testing.expectEqual(max_poll_ms, nextPoll(std.math.maxInt(u32)));
}

test "request wait disposition covers every Message state and observation status" {
    const State = enum { queued, processing, waiting_for_permission, completed, failed, cancelled, rejected };
    const Facts = struct {
        status: enum { absent, accepted, rejected } = .accepted,
        kind: ?enum { message, configure, stop, decision, interrupt } = .message,
        state: ?State = null,
    };
    for ([_]struct { state: State, expected: ?Disposition }{
        .{ .state = .queued, .expected = null },
        .{ .state = .processing, .expected = null },
        .{ .state = .waiting_for_permission, .expected = .done },
        .{ .state = .completed, .expected = .done },
        .{ .state = .failed, .expected = .done },
        .{ .state = .cancelled, .expected = .done },
        .{ .state = .rejected, .expected = .done },
    }) |case| try std.testing.expectEqual(case.expected, disposition(Facts{ .state = case.state }));
    try std.testing.expectEqual(@as(?Disposition, null), disposition(Facts{}));
    try std.testing.expectEqual(@as(?Disposition, .absent), disposition(Facts{ .status = .absent, .kind = null }));
    try std.testing.expectEqual(@as(?Disposition, .done), disposition(Facts{ .status = .rejected, .kind = null }));
    for ([_]@FieldType(Facts, "kind"){ .configure, .stop, .decision, .interrupt }) |kind| {
        try std.testing.expectEqual(@as(?Disposition, .done), disposition(Facts{ .kind = kind }));
    }
}

test "request wait timeout policy is five minutes bounded to one day" {
    try std.testing.expectEqual(@as(u32, 300), default_timeout_seconds);
    try std.testing.expectEqual(@as(u32, 86400), max_timeout_seconds);
}
