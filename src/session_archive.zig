//! Organization is independent of a Session's work state. A pending archive
//! remains unarchived until the Host has fully settled its work.
const std = @import("std");

pub const State = enum { active, archiving, archived };

pub const Filter = enum {
    active,
    archived,
    all,

    pub fn includes(self: Filter, state: State) bool {
        return switch (self) {
            .active => state != .archived,
            .archived => state == .archived,
            .all => true,
        };
    }
};

test "archive filters keep pending archive visible until settlement" {
    const states = [_]State{ .active, .archiving, .archived };
    const cases = [_]struct { filter: Filter, expected: [3]bool }{
        .{ .filter = .active, .expected = .{ true, true, false } },
        .{ .filter = .archived, .expected = .{ false, false, true } },
        .{ .filter = .all, .expected = .{ true, true, true } },
    };
    for (cases) |case| for (states, case.expected) |state, expected|
        try std.testing.expectEqual(expected, case.filter.includes(state));
}
