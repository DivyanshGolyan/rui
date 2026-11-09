//! Local v2 envelope for a native submitted original. The embedded request is
//! the original wire JSON, not a re-serialization. This is not a wire format.
const std = @import("std");
const protocol = @import("protocol.zig");

pub const magic = "\x89RUILG2\n";
pub const header_bytes = 116;

pub const Original = union(enum) {
    message,
    decision: struct { action: u64, instance: protocol.InstanceId },
    reason_then_deny: struct { action: u64, instance: protocol.InstanceId, denial_key: [36]u8 },
};

/// A persisted attempt marker is written before transmission. It means that
/// transmission may have happened, not that Host admission was confirmed.
pub const Phase = enum(u8) {
    captured = 0,
    may_have_transmitted = 1,
    reason_accepted = 2,
    denial_may_have_transmitted = 3,
    complete = 4,
    rejected = 5,
    denial_rejected = 6,
};

pub const Header = struct {
    original: Original,
    phase: Phase,
    wire_bytes: u64,
    digest: [32]u8,

    pub fn encode(self: Header) ![header_bytes]u8 {
        try self.validate();
        var out: [header_bytes]u8 = @splat(0);
        @memcpy(out[0..8], magic);
        out[8] = switch (self.original) { .message => 0, .decision => 1, .reason_then_deny => 2 };
        out[9] = @intFromEnum(self.phase);
        switch (self.original) {
            .message => {},
            .decision => |value| {
                std.mem.writeInt(u64, out[16..24], value.action, .big);
                @memcpy(out[24..40], &value.instance);
            },
            .reason_then_deny => |value| {
                std.mem.writeInt(u64, out[16..24], value.action, .big);
                @memcpy(out[24..40], &value.instance);
                @memcpy(out[40..76], &value.denial_key);
            },
        }
        std.mem.writeInt(u64, out[76..84], self.wire_bytes, .big);
        @memcpy(out[84..116], &self.digest);
        return out;
    }

    pub fn decode(bytes: *const [header_bytes]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidRequestRecord;
        if (!std.mem.allEqual(u8, bytes[10..16], 0)) return error.InvalidRequestRecord;
        const action = std.mem.readInt(u64, bytes[16..24], .big);
        const instance = bytes[24..40].*;
        const original: Original = switch (bytes[8]) {
            0 => blk: {
                if (!std.mem.allEqual(u8, bytes[16..76], 0)) return error.InvalidRequestRecord;
                break :blk .message;
            },
            1 => blk: {
                if (!std.mem.allEqual(u8, bytes[40..76], 0)) return error.InvalidRequestRecord;
                break :blk .{ .decision = .{ .action = action, .instance = instance } };
            },
            2 => .{ .reason_then_deny = .{ .action = action, .instance = instance, .denial_key = bytes[40..76].* } },
            else => return error.InvalidRequestRecord,
        };
        const header: Header = .{
            .original = original,
            .phase = std.meta.intToEnum(Phase, bytes[9]) catch return error.InvalidRequestRecord,
            .wire_bytes = std.mem.readInt(u64, bytes[76..84], .big),
            .digest = bytes[84..116].*,
        };
        try header.validate();
        return header;
    }

    /// The digest binds the complete typed header and exact wire bytes. The
    /// caller streams exactly wire_bytes before comparing the final digest.
    pub fn hasher(self: Header) !std.crypto.hash.sha2.Sha256 {
        var canonical = self;
        canonical.digest = @splat(0);
        const bytes = try canonical.encode();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("rui native request ledger v2\x00");
        hash.update(bytes[0..84]);
        return hash;
    }

    fn validate(self: Header) !void {
        if (self.wire_bytes == 0) return error.InvalidRequestRecord;
        switch (self.original) {
            .message => if (self.phase == .reason_accepted or self.phase == .denial_may_have_transmitted or self.phase == .denial_rejected) return error.InvalidRequestRecord,
            .decision => |value| {
                if (value.action == 0 or self.phase == .reason_accepted or self.phase == .denial_may_have_transmitted or self.phase == .denial_rejected) return error.InvalidRequestRecord;
            },
            .reason_then_deny => |value| {
                if (value.action == 0 or !validKey(&value.denial_key)) return error.InvalidRequestRecord;
            },
        }
    }
};

fn validKey(key: *const [36]u8) bool {
    for (key, 0..) |byte, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

test "native ledger header preserves original authority and continuation" {
    const original: Header = .{
        .original = .{ .reason_then_deny = .{ .action = 42, .instance = @splat(0xa7), .denial_key = "00000000-0000-4000-8000-000000000001".* } },
        .phase = .reason_accepted,
        .wire_bytes = 123,
        .digest = @splat(0x42),
    };
    const encoded = try original.encode();
    try std.testing.expectEqualDeep(original, try Header.decode(&encoded));
    var invalid = encoded;
    invalid[10] = 1;
    try std.testing.expectError(error.InvalidRequestRecord, Header.decode(&invalid));
    invalid = encoded;
    invalid[8] = 0;
    try std.testing.expectError(error.InvalidRequestRecord, Header.decode(&invalid));
}
