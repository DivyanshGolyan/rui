//! Paths as a person reads them: under HOME with `~`.
const std = @import("std");

/// A home-relative path: `~` for the home directory itself.
pub fn shortPath(home: []const u8, path: []const u8) struct { prefix: []const u8, rest: []const u8 } {
    if (home.len > 1 and std.mem.startsWith(u8, path, home)) {
        const rest = path[home.len..];
        if (rest.len == 0 or rest[0] == '/') return .{ .prefix = "~", .rest = rest };
    }
    return .{ .prefix = "", .rest = path };
}

test "only a path at or under HOME starts with `~`" {
    try std.testing.expectEqualStrings("/code", shortPath("/home/d", "/home/d/code").rest);
    try std.testing.expectEqualStrings("~", shortPath("/home/d", "/home/d").prefix);
    try std.testing.expectEqualStrings("", shortPath("/home/d", "/home/dx").prefix);
    try std.testing.expectEqualStrings("", shortPath("/", "/srv").prefix);
}
