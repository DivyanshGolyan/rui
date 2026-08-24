const std = @import("std");

pub const page_size = 64 * 1024;
pub const header_size = 64;
pub const encoded_size = header_size + page_size;
pub const version: u16 = 1;

const magic = "ONEPAGE\x00";
const offset_version = 8;
const offset_header_size = 10;
const offset_flags = 12;
const offset_agent_id = 16;
const offset_generation = 24;
const offset_payload_length = 32;
const offset_payload_crc = 36;
const offset_header_crc = 40;
const offset_reserved = 44;

pub const Decoded = struct {
    agent_id: u64,
    generation: u64,
    page: []const u8,
};

pub fn encode(out: []u8, agent_id: u64, generation: u64, page: []const u8) !void {
    if (out.len != encoded_size) return error.InvalidOutputLength;
    if (page.len != page_size) return error.InvalidPageLength;

    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, offset_version, version);
    write(u16, out, offset_header_size, header_size);
    write(u32, out, offset_flags, 0);
    write(u64, out, offset_agent_id, agent_id);
    write(u64, out, offset_generation, generation);
    write(u32, out, offset_payload_length, page_size);
    write(u32, out, offset_payload_crc, std.hash.Crc32.hash(page));
    write(u32, out, offset_header_crc, std.hash.Crc32.hash(out[0..offset_header_crc]));
    @memcpy(out[header_size..], page);
}

pub fn decode(record: []const u8, expected_agent_id: u64, expected_generation: u64) !Decoded {
    if (record.len != encoded_size) return error.InvalidRecordLength;
    if (!std.mem.eql(u8, record[0..magic.len], magic)) return error.InvalidMagic;
    if (read(u16, record, offset_version) != version) return error.UnsupportedVersion;
    if (read(u16, record, offset_header_size) != header_size) return error.InvalidHeaderLength;
    if (read(u32, record, offset_flags) != 0) return error.UnsupportedFlags;
    if (read(u32, record, offset_payload_length) != page_size) return error.InvalidPageLength;

    for (record[offset_reserved..header_size]) |byte| {
        if (byte != 0) return error.NonzeroReservedByte;
    }

    const stored_header_crc = read(u32, record, offset_header_crc);
    const actual_header_crc = std.hash.Crc32.hash(record[0..offset_header_crc]);
    if (stored_header_crc != actual_header_crc) return error.HeaderChecksumMismatch;

    const agent_id = read(u64, record, offset_agent_id);
    if (agent_id != expected_agent_id) return error.AgentIdentityMismatch;
    const generation = read(u64, record, offset_generation);
    if (generation != expected_generation) return error.GenerationMismatch;

    const page = record[header_size..];
    const stored_payload_crc = read(u32, record, offset_payload_crc);
    if (stored_payload_crc != std.hash.Crc32.hash(page)) return error.PayloadChecksumMismatch;

    return .{ .agent_id = agent_id, .generation = generation, .page = page };
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "checkpoint round trip" {
    const allocator = std.testing.allocator;
    const page = try allocator.alloc(u8, page_size);
    defer allocator.free(page);
    for (page, 0..) |*byte, index| byte.* = @truncate(index);

    const encoded = try allocator.alloc(u8, encoded_size);
    defer allocator.free(encoded);
    try encode(encoded, 42, 7, page);

    const decoded = try decode(encoded, 42, 7);
    try std.testing.expectEqual(@as(u64, 42), decoded.agent_id);
    try std.testing.expectEqual(@as(u64, 7), decoded.generation);
    try std.testing.expectEqualSlices(u8, page, decoded.page);
}

test "checkpoint rejects truncation and corruption" {
    const allocator = std.testing.allocator;
    const page = try allocator.alloc(u8, page_size);
    defer allocator.free(page);
    @memset(page, 0x5a);

    const encoded = try allocator.alloc(u8, encoded_size);
    defer allocator.free(encoded);
    try encode(encoded, 42, 7, page);

    try std.testing.expectError(error.InvalidRecordLength, decode(encoded[0 .. encoded.len - 1], 42, 7));
    encoded[header_size + 123] ^= 1;
    try std.testing.expectError(error.PayloadChecksumMismatch, decode(encoded, 42, 7));
    encoded[header_size + 123] ^= 1;
    encoded[offset_agent_id] ^= 1;
    try std.testing.expectError(error.HeaderChecksumMismatch, decode(encoded, 42, 7));
}

test "checkpoint rejects stale identity and generation" {
    const allocator = std.testing.allocator;
    const page = try allocator.alloc(u8, page_size);
    defer allocator.free(page);
    @memset(page, 0);

    const encoded = try allocator.alloc(u8, encoded_size);
    defer allocator.free(encoded);
    try encode(encoded, 42, 7, page);

    try std.testing.expectError(error.AgentIdentityMismatch, decode(encoded, 43, 7));
    try std.testing.expectError(error.GenerationMismatch, decode(encoded, 42, 8));
}

test "checkpoint rejects unsupported metadata" {
    const allocator = std.testing.allocator;
    const page = try allocator.alloc(u8, page_size);
    defer allocator.free(page);
    @memset(page, 0);

    const encoded = try allocator.alloc(u8, encoded_size);
    defer allocator.free(encoded);
    try encode(encoded, 42, 7, page);

    write(u32, encoded, offset_flags, 1);
    try std.testing.expectError(error.UnsupportedFlags, decode(encoded, 42, 7));
    write(u32, encoded, offset_flags, 0);
    encoded[offset_reserved] = 1;
    try std.testing.expectError(error.NonzeroReservedByte, decode(encoded, 42, 7));
}
