const std = @import("std");

pub const Id = struct {
    bytes: [32]u8,

    pub fn parse(text: []const u8) !Id {
        if (text.len != 32) return error.InvalidId;
        for (text) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return error.InvalidId;
        return .{ .bytes = text[0..32].* };
    }

    pub fn generate(random_io: std.Io) !Id {
        var random: [16]u8 = undefined;
        try std.Io.randomSecure(random_io, &random);
        return .{ .bytes = std.fmt.bytesToHex(random, .lower) };
    }

    pub fn slice(self: *const Id) []const u8 {
        return &self.bytes;
    }
};
