const std = @import("std");

pub const Rejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_action,
    target_mismatch,
    source_stopped,
    background_unavailable,
};

pub const Selection = struct { kind: enum { background, final }, position: u64 };
pub const Observation = struct { action_id: u64, selection: ?Selection };
pub const Facts = struct { background: ?u64, final: ?u64, stopped: ?u64, attempted: bool };
pub const Capacity = struct { total: usize, free: usize };
pub const Choice = union(enum) { selected: Selection, background, refused: Rejection };

pub fn choose(facts: Facts, capacity: Capacity) Choice {
    if (facts.background) |position| return .{ .selected = .{ .kind = .background, .position = position } };
    if (facts.final) |position| return .{ .selected = .{ .kind = .final, .position = position } };
    if (facts.stopped != null) return .{ .refused = .source_stopped };
    if (capacity.total < 2 or (facts.attempted and capacity.free == 0)) return .{ .refused = .background_unavailable };
    return .background;
}

pub const Reply = union(enum) {
    accepted: struct { replayed: bool, action_id: u64, selection: Selection },
    rejected: struct { replayed: bool, code: Rejection },
    conflict,
    infrastructure_failure,
};

test "promotion preserves original fulfillment before stop or capacity refusal" {
    const no_credit: Capacity = .{ .total = 1, .free = 0 };
    var facts: Facts = .{ .background = 10, .final = 20, .stopped = 15, .attempted = true };
    try std.testing.expectEqual(Selection{ .kind = .background, .position = 10 }, choose(facts, no_credit).selected);
    facts.background = null;
    try std.testing.expectEqual(Selection{ .kind = .final, .position = 20 }, choose(facts, no_credit).selected);
    facts.final = null;
    try std.testing.expectEqual(Rejection.source_stopped, choose(facts, no_credit).refused);
    facts.stopped = null;
    try std.testing.expectEqual(Rejection.background_unavailable, choose(facts, no_credit).refused);
    try std.testing.expect(choose(facts, .{ .total = 2, .free = 1 }) == .background);
    facts.attempted = false;
    try std.testing.expect(choose(facts, .{ .total = 2, .free = 0 }) == .background);
    try std.testing.expectEqual(Rejection.background_unavailable, choose(facts, no_credit).refused);
}
