//! Publish only an already verified source; never stream a failed read to the
//! requested destination. The destination is a new, user-directed export, not
//! a Store or a persistent cache. A crash may leave the private staging file.
const std = @import("std");
const protocol = @import("protocol.zig");

pub fn parseDigest(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidArguments;
    var digest: [32]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&digest, text) catch return error.InvalidArguments;
    if (decoded.len != digest.len) return error.InvalidArguments;
    return digest;
}

/// `source` must already have passed the complete length, v1 digest and EOF
/// checks. Fixed-size reads avoid making a second resident Message. The final
/// name is created atomically and is never overwritten, even on collision.
pub fn publish(io: std.Io, dir: std.Io.Dir, name: []const u8, source: anytype, length: u64) !void {
    var random: [16]u8 = undefined;
    try std.Io.randomSecure(io, &random);
    var buffer: [64]u8 = undefined;
    const staging = try std.fmt.bufPrint(&buffer, ".rui-export-{s}.tmp", .{std.fmt.bytesToHex(random, .lower)});
    const file = try dir.createFile(io, staging, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    var published = false;
    defer if (!published) dir.deleteFile(io, staging) catch {};
    {
        defer file.close(io);
        var bytes: [protocol.content_window_bytes]u8 = undefined;
        var offset: u64 = 0;
        while (offset < length) {
            const count = try source.readAt(offset, &bytes);
            if (count == 0 or count > length - offset) return error.TruncatedResponse;
            try file.writeStreamingAll(io, bytes[0..count]);
            offset += count;
        }
        try file.sync(io);
    }
    try dir.renamePreserve(staging, dir, name, io);
    published = true;
}

test "native source export checks digest spelling and publishes atomically" {
    try std.testing.expectError(error.InvalidArguments, parseDigest("00"));
    try std.testing.expectError(error.InvalidArguments, parseDigest("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    try std.testing.expectEqual(@as(u8, 0xab), (try parseDigest("abababababababababababababababababababababababababababababababab"))[0]);
    const Source = struct {
        fail: bool,
        fn readAt(self: @This(), offset: u64, out: []u8) !usize {
            if (self.fail and offset != 0) return error.InjectedFailure;
            const n: usize = @intCast(@min(out.len, 5000 - offset));
            @memset(out[0..n], 0xa5);
            return n;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expectError(error.InjectedFailure, publish(io, tmp.dir, "failed", Source{ .fail = true }, 5000));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "failed", .{}));
    try publish(io, tmp.dir, "ok", Source{ .fail = false }, 5000);
    try std.testing.expectError(error.PathAlreadyExists, publish(io, tmp.dir, "ok", Source{ .fail = false }, 5000));
    const file = try tmp.dir.openFile(io, "ok", .{});
    defer file.close(io);
    var result: [5000]u8 = undefined;
    try std.testing.expectEqual(result.len, try file.readPositionalAll(io, &result, 0));
    for (result) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
}
