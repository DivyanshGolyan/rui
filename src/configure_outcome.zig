const std = @import("std");

/// The answer to one captured Configure, independent of any later Current read.
pub const Outcome = union(enum) {
    accepted,
    rejected,
    not_sent,
    unconfirmed: [36]u8,
};

/// Once a send may have reached the Host, failure retains the original key.
pub fn failed(key: [36]u8, may_have_reached_host: bool, recovering: bool) Outcome {
    return if (may_have_reached_host or recovering) .{ .unconfirmed = key } else .not_sent;
}

test "SUI-135 configure failure retains the original key exactly when the outcome is uncertain" {
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    for ([_]bool{ false, true }) |may_have_reached_host| for ([_]bool{ false, true }) |recovering| {
        const actual = failed(key, may_have_reached_host, recovering);
        if (may_have_reached_host or recovering) {
            try std.testing.expectEqual(key, actual.unconfirmed);
        } else try std.testing.expect(actual == .not_sent);
    };
}
