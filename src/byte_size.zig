//! How a byte count reads on a screen: thousands of bytes, with one decimal below 9.95 KB.
const std = @import("std");

/// Total over u64: a size a Host reported for a part can be any decimal, so rounding saturates.
pub fn kilobytes(bytes: u64, buffer: *[24]u8) []const u8 {
    const tenths = (bytes +| 50) / 100;
    if (tenths < 100) return std.fmt.bufPrint(buffer, "{d}.{d} KB", .{ tenths / 10, tenths % 10 }) catch unreachable;
    return std.fmt.bufPrint(buffer, "{d} KB", .{(bytes +| 500) / 1000}) catch unreachable;
}

test "sizes are thousands of bytes with one decimal below 9.95" {
    var buffer: [24]u8 = undefined;
    for ([_]struct { u64, []const u8 }{ .{ 9, "0.0 KB" }, .{ 1_025, "1.0 KB" }, .{ 1_049, "1.0 KB" }, .{ 1_050, "1.1 KB" }, .{ 9_949, "9.9 KB" }, .{ 9_950, "10 KB" }, .{ 10_499, "10 KB" }, .{ 10_500, "11 KB" }, .{ 65_536, "66 KB" }, .{ std.math.maxInt(u64), "18446744073709551 KB" } }) |case| {
        try std.testing.expectEqualStrings(case[1], kilobytes(case[0], &buffer));
    }
}
