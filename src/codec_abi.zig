//! The provider codec contract: the values a codec and the Host exchange.
//! Std only, so every codec shares this one layout.
const std = @import("std");

/// Response headers a codec reads as input. The Host captures only these
/// (plus what it needs itself, such as Retry-After). An empty name is not
/// observed.
pub const ObservedHeaders = struct {
    /// Recorded as the Attempt's request id.
    request_id: []const u8 = "",
    /// The model the provider reports serving, and its alternate header.
    model: []const u8 = "",
    alternate_model: []const u8 = "",
    /// A per-Turn routing value echoed on the Turn's later requests.
    turn_state: []const u8 = "",
};

pub const max_carry_bytes = 16;

/// A codec's encoder state at a history-item boundary, opaque to the Host.
/// A request that reuses an earlier request's history span resumes from
/// the carry that span ended in, so the bytes after it match a rebuild.
pub const Carry = struct {
    len: u8 = 0,
    bytes: [max_carry_bytes]u8 = @splat(0),

    pub fn of(state: []const u8) Carry {
        std.debug.assert(state.len <= max_carry_bytes);
        var carry: Carry = .{ .len = @intCast(state.len) };
        @memcpy(carry.bytes[0..state.len], state);
        return carry;
    }

    pub fn slice(self: *const Carry) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Carry, other: *const Carry) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// A tool as the model is told about it; each codec writes its own envelope.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    /// A JSON Schema object, as JSON text.
    parameters_json: []const u8,
};

/// What a codec declares about itself, read without running it.
pub const Manifest = struct {
    observe: ObservedHeaders,

    /// HTTP/2 field names arrive lowercase (RFC 9113 8.2.1, enforced by
    /// nghttp2), so a name with an uppercase byte could never match.
    pub fn valid(self: *const Manifest) bool {
        inline for (@typeInfo(ObservedHeaders).@"struct".field_names) |name| {
            for (@field(self.observe, name)) |byte| if (!lowercaseTokenByte(byte)) return false;
        }
        return true;
    }
};

fn lowercaseTokenByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', '0'...'9', '-', '_', '.', '!', '#', '$', '%', '&', '\'', '*', '+', '^', '`', '|', '~' => true,
        else => false,
    };
}

test "a manifest names its observed headers as lowercase tokens" {
    // RFC 9110 5.6.2: tchar is ALPHA, DIGIT and these marks; HTTP/2 drops the uppercase.
    const marks = "!#$%&'*+-.^_`|~";
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const tchar = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or std.mem.indexOfScalar(u8, marks, byte) != null;
        const name = [_]u8{ 'x', byte };
        const manifest: Manifest = .{ .observe = .{ .model = &name } };
        try std.testing.expectEqual(tchar, manifest.valid());
    }
    const unnamed: Manifest = .{ .observe = .{} };
    try std.testing.expect(unnamed.valid());
}
