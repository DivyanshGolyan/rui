const std = @import("std");

pub const State = enum {
    active,
    archiving,
    archived,

    /// The words that name this state to a person; null while the Session is active.
    pub fn badge(self: State) ?[]const u8 {
        return switch (self) {
            .active => null,
            .archiving => "Stopping and archiving",
            .archived => "Archived",
        };
    }

    pub const longest_badge = longest: {
        var longest: usize = 0;
        for (std.enums.values(State)) |state| {
            if (state.badge()) |words| longest = @max(longest, words.len);
        }
        break :longest longest;
    };
};

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
