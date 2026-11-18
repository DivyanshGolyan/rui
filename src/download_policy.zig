const std = @import("std");

pub const Family = enum { automatic, ipv4 };

// Release generation reads these single-line literal declarations from the
// pinned release source. The strict reader accepts positive second values up
// to 86400 with connect <= download and distinct exit codes from 1 through 255.
pub const connect_timeout_seconds: u32 = 10;
pub const download_timeout_seconds: u32 = 300;
pub const retry_exit_codes = [_]u8{ 6, 28 };

pub const connect_timeout_ns: i96 = secondsToNs(connect_timeout_seconds);
pub const download_timeout_ns: i96 = secondsToNs(download_timeout_seconds);

fn secondsToNs(seconds: u32) i96 {
    return @as(i96, seconds) * 1_000_000_000;
}

/// The transport owns both curl timeouts and disables curl's config file.
/// With a full connection budget left on the same download deadline, exit 28
/// cannot be the total-transfer timeout; it is a connection-phase timeout,
/// including a resolver stall on a redirect. No stderr text is interpreted.
pub fn retry(family: Family, exit_code: ?u8, remaining_ns: i96) bool {
    return retryWith(family, exit_code, remaining_ns, connect_timeout_ns, &retry_exit_codes);
}

fn retryWith(family: Family, exit_code: ?u8, remaining_ns: i96, connect_ns: i96, codes: []const u8) bool {
    const code = exit_code orelse return false;
    return family == .automatic and remaining_ns >= connect_ns and
        std.mem.indexOfScalar(u8, codes, code) != null;
}

test "SH-44 release download retries only resolution and early connection timeouts once" {
    try std.testing.expectEqual(@as(i96, 10_000_000_000), connect_timeout_ns);
    try std.testing.expectEqual(@as(i96, 300_000_000_000), download_timeout_ns);
    const budgets = [_]i96{ -1, 0, 9_999_999_999, 10_000_000_000, 10_000_000_001, 300_000_000_000 };
    for ([_]Family{ .automatic, .ipv4 }) |family| {
        for (budgets) |remaining_ns| {
            for (0..256) |code| {
                const expected = family == .automatic and remaining_ns >= 10_000_000_000 and (code == 6 or code == 28);
                try std.testing.expectEqual(expected, retry(family, @intCast(code), remaining_ns));
            }
            try std.testing.expect(!retry(family, null, remaining_ns));
        }
    }
    // The same native decision also follows an independently chosen policy.
    try std.testing.expectEqual(@as(i96, 7_000_000_000), secondsToNs(7));
    try std.testing.expectEqual(@as(i96, 80_000_000_000), secondsToNs(80));
    const alternate = [_]u8{ 7, 35 };
    for ([_]Family{ .automatic, .ipv4 }) |family| {
        for ([_]i96{ 6_999_999_999, 7_000_000_000, 80_000_000_000 }) |remaining_ns| {
            for (0..256) |code| {
                const expected = family == .automatic and remaining_ns >= 7_000_000_000 and (code == 7 or code == 35);
                try std.testing.expectEqual(expected, retryWith(family, @intCast(code), remaining_ns, secondsToNs(7), &alternate));
            }
        }
    }
}
