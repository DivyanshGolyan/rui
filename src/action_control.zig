const std = @import("std");

pub const Rejection = enum {
    invalid_session_reference,
    invalid_target,
    unknown_session,
    unknown_action,
    target_mismatch,
    source_stopped,
    /// Read-only replay of a refusal committed before capacity ceased to govern promotion.
    background_unavailable,
};

pub const Selection = struct { kind: enum { background, final }, position: u64 };
pub const Observation = struct { action_id: u64, selection: ?Selection };
pub const Facts = struct { background: ?u64, final: ?u64, stopped: ?u64 };
pub const Choice = union(enum) { selected: Selection, background, refused: Rejection };

pub fn choose(facts: Facts) Choice {
    if (facts.background) |position| return .{ .selected = .{ .kind = .background, .position = position } };
    if (facts.final) |position| return .{ .selected = .{ .kind = .final, .position = position } };
    if (facts.stopped != null) return .{ .refused = .source_stopped };
    return .background;
}

pub const Reply = union(enum) {
    accepted: struct { replayed: bool, action_id: u64, selection: Selection },
    rejected: struct { replayed: bool, code: Rejection },
    conflict,
    infrastructure_failure,
};

test "promotion preserves fulfillment and stop without reserving capacity" {
    var facts: Facts = .{ .background = 10, .final = 20, .stopped = 15 };
    try std.testing.expectEqual(Selection{ .kind = .background, .position = 10 }, choose(facts).selected);
    facts.background = null;
    try std.testing.expectEqual(Selection{ .kind = .final, .position = 20 }, choose(facts).selected);
    facts.final = null;
    try std.testing.expectEqual(Rejection.source_stopped, choose(facts).refused);
    facts.stopped = null;
    try std.testing.expect(choose(facts) == .background);
}
