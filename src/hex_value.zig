//! Hex bytes, shared by argv identities and byte-valued settings. Policy such
//! as UTF-8 identities or non-NUL paths belongs to the caller, not this codec.
const std = @import("std");

pub const Case = enum { either, lower };
pub fn decodeInto(buffer: []u8, encoded: []const u8, letter_case: Case) error{InvalidHexIdentity}![]u8 {
    if (encoded.len % 2 != 0 or encoded.len / 2 > buffer.len) return error.InvalidHexIdentity;
    if (letter_case == .lower) for (encoded) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidHexIdentity;
    };
    return std.fmt.hexToBytes(buffer[0 .. encoded.len / 2], encoded) catch error.InvalidHexIdentity;
}

/// Compatibility API for the existing argv identity grammar.
pub fn decodeIdentity(allocator: std.mem.Allocator, encoded: []const u8, limit: usize) error{ InvalidHexIdentity, OutOfMemory }![]u8 {
    if (encoded.len == 0 or encoded.len % 2 != 0 or encoded.len / 2 > limit) return error.InvalidHexIdentity;
    const bytes = try allocator.alloc(u8, encoded.len / 2);
    errdefer allocator.free(bytes);
    const decoded = try decodeInto(bytes, encoded, .either);
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidHexIdentity;
    return decoded;
}

pub fn write(bytes: []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    for (bytes) |byte| try out.writeAll(&std.fmt.bytesToHex([_]u8{byte}, .lower));
}

test "hex value shares the identity codec and covers every byte" {
    var storage: [256]u8 = undefined;
    for (&storage, 0..) |*byte, index| byte.* = @intCast(index);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try write(&storage, &output.writer);
    var decoded: [256]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &storage, try decodeInto(&decoded, output.written(), .lower));
    for ([_][]const u8{ "f", "FF", "gg" }) |bad| try std.testing.expectError(error.InvalidHexIdentity, decodeInto(&decoded, bad, .lower));
    try std.testing.expectEqualSlices(u8, &.{255}, try decodeInto(&decoded, "FF", .either));
    try std.testing.expectEqual(@as(usize, 0), (try decodeInto(&decoded, "", .lower)).len);
}
