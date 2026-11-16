const std = @import("std");

pub const Sha256 = std.crypto.hash.sha2.Sha256;

pub const encoded_bytes = 56;

pub const PrefixSeal = struct {
    anchor: ?u64,
    admission_position: u64,
    span_length: u64,
    digest: [Sha256.digest_length]u8,

    pub fn binds(self: *const PrefixSeal, anchor: ?u64, admission: u64) bool {
        return self.anchor == anchor and self.admission_position <= admission;
    }

    pub fn encode(self: *const PrefixSeal) [encoded_bytes]u8 {
        var bytes: [encoded_bytes]u8 = undefined;
        std.debug.assert(self.anchor != 0 and self.admission_position != 0);
        std.mem.writeInt(u64, bytes[0..8], self.anchor orelse 0, .little);
        std.mem.writeInt(u64, bytes[8..16], self.admission_position, .little);
        std.mem.writeInt(u64, bytes[16..24], self.span_length, .little);
        bytes[24..56].* = self.digest;
        return bytes;
    }

    pub fn decode(bytes: []const u8) !PrefixSeal {
        if (bytes.len != encoded_bytes) return error.CorruptStore;
        const anchor = std.mem.readInt(u64, bytes[0..8], .little);
        const admission = std.mem.readInt(u64, bytes[8..16], .little);
        if (admission == 0) return error.CorruptStore;
        return .{
            .anchor = if (anchor == 0) null else anchor,
            .admission_position = admission,
            .span_length = std.mem.readInt(u64, bytes[16..24], .little),
            .digest = bytes[24..56].*,
        };
    }
};

test "a prefix seal round-trips and binds only its anchor and later views" {
    const seal: PrefixSeal = .{ .anchor = 7, .admission_position = 12, .span_length = 300, .digest = @splat(0xab) };
    const decoded = try PrefixSeal.decode(&seal.encode());
    try std.testing.expectEqual(seal, decoded);
    try std.testing.expect(decoded.binds(7, 12));
    try std.testing.expect(decoded.binds(7, 40));
    try std.testing.expect(!decoded.binds(7, 11));
    try std.testing.expect(!decoded.binds(null, 40));
    try std.testing.expect(!decoded.binds(8, 40));
    const unanchored: PrefixSeal = .{ .anchor = null, .admission_position = 1, .span_length = 0, .digest = @splat(0) };
    try std.testing.expectEqual(unanchored, try PrefixSeal.decode(&unanchored.encode()));
    try std.testing.expectError(error.CorruptStore, PrefixSeal.decode(&@as([encoded_bytes]u8, @splat(0))));
    try std.testing.expectError(error.CorruptStore, PrefixSeal.decode(&@as([55]u8, @splat(1))));
}
