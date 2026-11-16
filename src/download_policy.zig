const std = @import("std");

pub const Family = enum { automatic, ipv4 };
pub const connect_timeout_ns: i96 = 10_000_000_000;
pub const download_timeout_ns: i96 = 300_000_000_000;

/// The transport owns both curl timeouts and disables curl's config file.
/// With a full connection budget left on the same download deadline, exit 28
/// cannot be the total-transfer timeout; it is a connection-phase timeout,
/// including a resolver stall on a redirect. No stderr text is interpreted.
pub fn retry(family: Family, exit_code: ?u8, remaining_ns: i96) bool {
    return family == .automatic and
        remaining_ns >= connect_timeout_ns and
        (exit_code == 6 or exit_code == 28);
}

test "release download retries only resolution and early connection timeouts once" {
    const budgets = [_]i96{
        -1,                     0,
        connect_timeout_ns - 1, connect_timeout_ns,
        connect_timeout_ns + 1, download_timeout_ns,
    };
    for ([_]Family{ .automatic, .ipv4 }) |family| {
        for (budgets) |remaining_ns| {
            for (0..256) |code| {
                const expected = family == .automatic and
                    remaining_ns >= 10_000_000_000 and
                    (code == 6 or code == 28);
                try std.testing.expectEqual(expected, retry(family, @intCast(code), remaining_ns));
            }
            try std.testing.expect(!retry(family, null, remaining_ns));
        }
    }
}
