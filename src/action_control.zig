const std = @import("std");
const cli_value = @import("cli_value.zig");

pub const Kind = enum {
    background,
    stop,

    pub fn commandKind(kind: Kind) cli_value.CommandKind {
        return switch (kind) {
            .background => .action_background,
            .stop => .action_stop,
        };
    }
};

pub const Rejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_action,
    target_mismatch,
    source_stopped,
    background_unavailable,
};

pub const Selection = struct {
    kind: enum { background, final, stop },
    position: u64,
};

pub const Source = union(enum) {
    owner: Kind,
    core_stop: @import("attempt.zig").ActionAttemptBinding,

    pub fn kind(source: Source) Kind {
        return switch (source) {
            .owner => |value| value,
            .core_stop => .stop,
        };
    }
};

pub const Observation = struct { action_id: u64, selection: ?Selection };

pub const Facts = struct {
    background: ?u64,
    final: ?u64,
    stopped: ?u64,
    attempted: bool,
};

pub const Capacity = struct { total: usize, free: usize };
pub const Choice = union(enum) { selected: Selection, background, stop, refused: Rejection };

/// Replays are classified before this policy. Existing fulfillment wins
/// without renewing capacity, permission, Attempt, deadline, or launch.
pub fn choose(kind: Kind, facts: Facts, capacity: Capacity) Choice {
    if (kind == .background) {
        if (facts.background) |position| return .{ .selected = .{ .kind = .background, .position = position } };
        if (facts.final) |position| return .{ .selected = .{ .kind = .final, .position = position } };
        if (facts.stopped != null) return .{ .refused = .source_stopped };
        if (capacity.total < 2 or (facts.attempted and capacity.free == 0)) return .{ .refused = .background_unavailable };
        return .background;
    }
    if (facts.final) |position| return .{ .selected = .{ .kind = .final, .position = position } };
    if (facts.stopped) |position| return .{ .selected = .{ .kind = .stop, .position = position } };
    return .stop;
}

pub const Reply = union(enum) {
    accepted: struct { replayed: bool, action_id: u64, selection: Selection },
    rejected: struct { replayed: bool, code: Rejection },
    conflict,
    infrastructure_failure,
};

test "Action promotion selection does not reinterpret already fulfilled or stopped calls" {
    const no_capacity: Capacity = .{ .total = 1, .free = 0 };
    const facts: Facts = .{ .background = 10, .final = 20, .stopped = 15, .attempted = true };
    try std.testing.expectEqual(Selection{ .kind = .background, .position = 10 }, choose(.background, facts, no_capacity).selected);
    var changed = facts;
    changed.background = null;
    try std.testing.expectEqual(Selection{ .kind = .final, .position = 20 }, choose(.background, changed, no_capacity).selected);
    changed.final = null;
    try std.testing.expectEqual(Rejection.source_stopped, choose(.background, changed, no_capacity).refused);
    changed.stopped = null;
    try std.testing.expectEqual(Rejection.background_unavailable, choose(.background, changed, no_capacity).refused);
    try std.testing.expect(choose(.background, changed, .{ .total = 2, .free = 1 }) == .background);
    changed.attempted = false;
    try std.testing.expect(choose(.background, changed, .{ .total = 2, .free = 0 }) == .background);
    try std.testing.expectEqual(Rejection.background_unavailable, choose(.background, changed, no_capacity).refused);
    try std.testing.expect(choose(.stop, changed, no_capacity) == .stop);
}

pub fn toolResult(reply: Reply, action: u64, buffer: *[512]u8) []const u8 {
    return switch (reply) {
        .accepted => |value| std.fmt.bufPrint(buffer, "{{\"action\":\"{d}\",\"accepted\":true,\"selection\":\"{s}\",\"position\":\"{d}\"}}", .{ action, @tagName(value.selection.kind), value.selection.position }) catch unreachable,
        .rejected => |value| std.fmt.bufPrint(buffer, "{{\"action\":\"{d}\",\"accepted\":false,\"code\":\"{s}\"}}", .{ action, @tagName(value.code) }) catch unreachable,
        .conflict => "{\"accepted\":false,\"code\":\"idempotency_key_conflict\"}",
        .infrastructure_failure => unreachable,
    };
}
