//! Canonical Session ID grammar, shared by wire and invocation validators.
const std = @import("std");

pub const bytes = 6;
pub const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";

pub fn valid(value: []const u8) bool {
    if (value.len != bytes) return false;
    for (value) |byte| if (std.mem.indexOfScalar(u8, alphabet, byte) == null) return false;
    return true;
}

test "Session ID grammar preserves the six-character Crockford domain" {
    try std.testing.expect(valid("v948er"));
    try std.testing.expect(valid("k7m2qx"));
    try std.testing.expect(!valid("v948e") and !valid("v948err"));
    for (0..256) |byte| {
        var id: [bytes]u8 = @splat('0');
        id[0] = @intCast(byte);
        const expected = std.mem.indexOfScalar(u8, "0123456789abcdefghjkmnpqrstvwxyz", @intCast(byte)) != null;
        try std.testing.expectEqual(expected, valid(&id));
    }
}
