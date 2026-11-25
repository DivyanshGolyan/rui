const std = @import("std");

/// The answer to one captured Configure, independent of any later Current read.
pub const Original = struct {
    key: [36]u8,
    store: @import("bounded.zig").Bounded(@import("store_path.zig").max_bytes),
};

pub const Outcome = union(enum) {
    accepted,
    rejected,
    not_sent,
    unconfirmed: Original,
};

/// Once a send may have reached the Host, failure retains the original key.
pub fn failed(original: Original, may_have_reached_host: bool) Outcome {
    return if (may_have_reached_host) .{ .unconfirmed = original } else .not_sent;
}

test "SUI-135 configure failure retains the original key exactly when the outcome is uncertain" {
    const key: [36]u8 = "01234567-89ab-4cde-8012-0123456789ab".*;
    const original: Original = .{ .key = key, .store = try .from("/store-a") };
    for ([_]bool{ false, true }) |may_have_reached_host| {
        const actual = failed(original, may_have_reached_host);
        if (may_have_reached_host) {
            try std.testing.expectEqual(key, actual.unconfirmed.key);
            try std.testing.expect(actual.unconfirmed.store.eql("/store-a"));
        } else try std.testing.expect(actual == .not_sent);
    }
}
