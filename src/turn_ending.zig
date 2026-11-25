const std = @import("std");

/// What a Turn's ending means to a person.
pub const Sign = enum { finished, stopped, failed };

pub const TurnEnding = enum {
    done,
    context_full,
    provider_refused,
    out_of_quota,
    provider_unavailable,
    stopped,
    interrupted,
    failed,

    /// A finished Turn, one a person stopped or that was interrupted, or any failure.
    pub fn sign(self: TurnEnding) Sign {
        return switch (self) {
            .done => .finished,
            .stopped, .interrupted => .stopped,
            .context_full, .provider_refused, .out_of_quota, .provider_unavailable, .failed => .failed,
        };
    }

    /// The words of an ending that needs no failure code: "Finished" and "Stopped". Null for a failure, whose words come from its saved code (marks.cause).
    pub fn words(self: TurnEnding) ?[]const u8 {
        return switch (self.sign()) {
            .finished => "Finished",
            .stopped => "Stopped",
            .failed => null,
        };
    }
};

test "MRK-5 an ending says once whether it finished, stopped or failed, and its words" {
    const Case = struct { ending: TurnEnding, sign: Sign, words: ?[]const u8 };
    const cases = [_]Case{
        .{ .ending = .done, .sign = .finished, .words = "Finished" },
        .{ .ending = .stopped, .sign = .stopped, .words = "Stopped" },
        .{ .ending = .interrupted, .sign = .stopped, .words = "Stopped" },
        .{ .ending = .context_full, .sign = .failed, .words = null },
        .{ .ending = .provider_refused, .sign = .failed, .words = null },
        .{ .ending = .out_of_quota, .sign = .failed, .words = null },
        .{ .ending = .provider_unavailable, .sign = .failed, .words = null },
        .{ .ending = .failed, .sign = .failed, .words = null },
    };

    try std.testing.expectEqual(std.enums.values(TurnEnding).len, cases.len);
    for (cases) |case| {
        try std.testing.expectEqual(case.sign, case.ending.sign());
        if (case.words) |expected| {
            try std.testing.expectEqualStrings(expected, case.ending.words().?);
        } else {
            try std.testing.expect(case.ending.words() == null);
        }
    }
}
