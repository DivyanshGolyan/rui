const std = @import("std");

pub const Family = enum { automatic, ipv4 };
pub const connect_timeout: std.Io.Duration = .fromSeconds(10);
pub const download_timeout: std.Io.Duration = .fromSeconds(300);

/// The transport owns both curl timeouts and disables curl's config file.
/// With a full connection budget left on the same download deadline, exit 28
/// cannot be the total-transfer timeout; it is a connection-phase timeout,
/// including a resolver stall on a redirect. No stderr text is interpreted.
pub fn retry(family: Family, exit_code: ?u8, remaining: std.Io.Duration) bool {
    return family == .automatic and
        remaining.nanoseconds >= connect_timeout.nanoseconds and
        (exit_code == 6 or exit_code == 28);
}

test "release download retries only resolution and early connection timeouts once" {
    const budgets = [_]std.Io.Duration{
        .fromNanoseconds(-1),                              .zero,
        .fromNanoseconds(connect_timeout.nanoseconds - 1), connect_timeout,
        .fromNanoseconds(connect_timeout.nanoseconds + 1), download_timeout,
    };
    for ([_]Family{ .automatic, .ipv4 }) |family| {
        for (budgets) |remaining| {
            for (0..256) |code| {
                const expected = family == .automatic and
                    remaining.nanoseconds >= 10 * std.time.ns_per_s and
                    (code == 6 or code == 28);
                try std.testing.expectEqual(expected, retry(family, @intCast(code), remaining));
            }
            try std.testing.expect(!retry(family, null, remaining));
        }
    }
}
