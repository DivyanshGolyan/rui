//! Opaque model observations shared by the adapter writer and feed reader.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const max_model_bytes = @import("model_capability.zig").max_model_bytes;

pub const max_bytes = 1 + 3 * (2 + max_model_bytes);
pub const Certificate = Bounded(max_bytes);

/// Certificate v1 preserves body, OpenAI header and alternate header separately,
/// including absence and disagreement. Inputs are adapter-validated model names.
pub fn encode(out: *Certificate, body: []const u8, openai: []const u8, alternate: []const u8) void {
    out.bytes[0] = 1;
    out.len = 1;
    for ([_][]const u8{ body, openai, alternate }) |value| {
        std.debug.assert(value.len <= max_model_bytes and std.unicode.utf8ValidateSlice(value));
        std.mem.writeInt(u16, out.bytes[out.len..][0..2], @intCast(value.len), .little);
        out.len += 2;
        @memcpy(out.bytes[out.len..][0..value.len], value);
        out.len += value.len;
    }
}

/// Prefer the body, then the headers in order. Absence never substitutes the
/// requested model. Validate the entire certificate, including unused sources.
pub fn servedModel(evidence: ?[]const u8) error{InvalidModelEvidence}!?Bounded(max_model_bytes) {
    const bytes = evidence orelse return null;
    if (bytes.len == 0 or bytes[0] != 1) return error.InvalidModelEvidence;
    var offset: usize = 1;
    var result: ?Bounded(max_model_bytes) = null;
    for (0..3) |_| {
        if (bytes.len - offset < 2) return error.InvalidModelEvidence;
        const length = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        offset += 2;
        if (length > max_model_bytes or length > bytes.len - offset) return error.InvalidModelEvidence;
        const value = bytes[offset..][0..length];
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidModelEvidence;
        if (length != 0 and result == null) {
            result = .{ .len = 0 };
            result.?.set(value) catch return error.InvalidModelEvidence;
        }
        offset += length;
    }
    if (offset != bytes.len) return error.InvalidModelEvidence;
    return result;
}

test "model evidence preserves sources and selects body then headers across every presence combination" {
    try std.testing.expectEqual(@as(?Bounded(max_model_bytes), null), try servedModel(null));
    for (0..8) |mask| {
        const body = if (mask & 1 != 0) "body" else "";
        const openai = if (mask & 2 != 0) "openai" else "";
        const alternate = if (mask & 4 != 0) "alternate" else "";
        var evidence: Certificate = undefined;
        encode(&evidence, body, openai, alternate);
        const served = try servedModel(evidence.slice());
        const expected = if (mask & 1 != 0) "body" else if (mask & 2 != 0) "openai" else if (mask & 4 != 0) "alternate" else "";
        if (expected.len == 0) try std.testing.expect(served == null) else try std.testing.expectEqualStrings(expected, served.?.slice());
    }
    var evidence: Certificate = undefined;
    encode(&evidence, "body", "header", "other");
    // Independent v1 bytes pin preservation of disagreement, not just roundtrip.
    try std.testing.expectEqualSlices(u8, "\x01\x04\x00body\x06\x00header\x05\x00other", evidence.slice());
    const maximum: [max_model_bytes]u8 = @splat('m');
    encode(&evidence, &maximum, &maximum, &maximum);
    try std.testing.expectEqual(max_bytes, evidence.len);
    try std.testing.expectEqualStrings(&maximum, (try servedModel(evidence.slice())).?.slice());
}

test "model evidence rejects malformed version lengths UTF-8 and trailing bytes even after a selected body" {
    const malformed = [_][]const u8{
        "",             "\x02\x00\x00\x00\x00\x00\x00",     "\x01",                          "\x01\x00",                          "\x01\x01\x00",
        "\x01\x01\x01", "\x01\x01\x00\xff\x00\x00\x00\x00", "\x01\x00\x00\x00\x00\x00\x00x", "\x01\x01\x00b\x01\x00\xff\x00\x00", "\x01\x01\x00b\x00\x00\x01\x00",
    };
    for (malformed) |bytes| try std.testing.expectError(error.InvalidModelEvidence, servedModel(bytes));
}
