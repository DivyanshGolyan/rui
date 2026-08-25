const std = @import("std");
const core_state = @import("core_state.zig");

pub const state_size = core_state.encoded_size;
pub const header_size = 64;
pub const encoded_size = header_size + state_size;
pub const version: u16 = 4;

const magic = "ONECKPT\x00";
const offset_version = 8;
const offset_header_size = 10;
const offset_flags = 12;
const offset_agent_id = 16;
const offset_generation = 24;
const offset_state_length = 32;
const offset_state_crc = 36;
const offset_header_crc = 40;
const offset_ledger_sequence = 44;
const offset_reserved = 52;

pub const Decoded = struct {
    agent_id: u64,
    generation: u32,
    ledger_sequence: u64,
    state: []const u8,
};

pub fn encode(
    out: []u8,
    agent_id: u64,
    generation: u32,
    ledger_sequence: u64,
    state: []const u8,
) !void {
    if (out.len != encoded_size) return error.InvalidOutputLength;
    if (state.len != state_size) return error.InvalidCoreStateLength;
    const decoded_state = try core_state.decode(state);
    if (decoded_state.agent_id != agent_id) return error.AgentIdentityMismatch;
    if (decoded_state.agent_generation != generation) return error.GenerationMismatch;

    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, offset_version, version);
    write(u16, out, offset_header_size, header_size);
    write(u32, out, offset_flags, 0);
    write(u64, out, offset_agent_id, agent_id);
    write(u64, out, offset_generation, generation);
    write(u32, out, offset_state_length, state_size);
    write(u32, out, offset_state_crc, std.hash.Crc32.hash(state));
    write(u64, out, offset_ledger_sequence, ledger_sequence);
    write(u32, out, offset_header_crc, headerChecksum(out[0..header_size]));
    @memcpy(out[header_size..], state);
}

pub fn decode(record: []const u8, expected_agent_id: u64, expected_generation: u32) !Decoded {
    if (record.len != encoded_size) return error.InvalidRecordLength;
    if (!std.mem.eql(u8, record[0..magic.len], magic)) return error.InvalidMagic;
    if (read(u16, record, offset_version) != version) return error.UnsupportedVersion;
    if (read(u16, record, offset_header_size) != header_size) return error.InvalidHeaderLength;
    if (read(u32, record, offset_flags) != 0) return error.UnsupportedFlags;
    if (read(u32, record, offset_state_length) != state_size) return error.InvalidCoreStateLength;

    for (record[offset_reserved..header_size]) |byte| {
        if (byte != 0) return error.NonzeroReservedByte;
    }
    if (read(u32, record, offset_header_crc) != headerChecksum(record[0..header_size])) {
        return error.HeaderChecksumMismatch;
    }

    const agent_id = read(u64, record, offset_agent_id);
    if (agent_id != expected_agent_id) return error.AgentIdentityMismatch;
    const encoded_generation = read(u64, record, offset_generation);
    if (encoded_generation > std.math.maxInt(u32)) return error.InvalidGeneration;
    const generation: u32 = @intCast(encoded_generation);
    if (generation != expected_generation) return error.GenerationMismatch;

    const state = record[header_size..];
    if (read(u32, record, offset_state_crc) != std.hash.Crc32.hash(state)) {
        return error.CoreStateChecksumMismatch;
    }
    const decoded_state = try core_state.decode(state);
    if (decoded_state.agent_id != agent_id) return error.AgentIdentityMismatch;
    if (decoded_state.agent_generation != generation) return error.GenerationMismatch;
    return .{
        .agent_id = agent_id,
        .generation = generation,
        .ledger_sequence = read(u64, record, offset_ledger_sequence),
        .state = state,
    };
}

fn headerChecksum(header: []const u8) u32 {
    var canonical: [header_size]u8 = undefined;
    @memcpy(&canonical, header);
    @memset(canonical[offset_header_crc .. offset_header_crc + @sizeOf(u32)], 0);
    return std.hash.Crc32.hash(&canonical);
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

fn encodedState(agent_id: u64, generation: u32, accumulator: u64) ![state_size]u8 {
    var state: [state_size]u8 = undefined;
    try core_state.encode(&state, .{
        .agent_id = agent_id,
        .agent_generation = generation,
        .accumulator = accumulator,
    });
    return state;
}

test "checkpoint contains compact canonical Core State" {
    const state = try encodedState(42, 7, 99);
    var encoded: [encoded_size]u8 = undefined;
    try encode(&encoded, 42, 7, 9, &state);
    const decoded = try decode(&encoded, 42, 7);
    try std.testing.expectEqualSlices(u8, &state, decoded.state);
    try std.testing.expectEqual(@as(u64, 9), decoded.ledger_sequence);
    try std.testing.expectEqual(@as(usize, header_size + core_state.encoded_size), encoded.len);
}

test "checkpoint rejects truncation corruption stale identity and generation" {
    const state = try encodedState(42, 7, 99);
    var encoded: [encoded_size]u8 = undefined;
    try encode(&encoded, 42, 7, 9, &state);
    try std.testing.expectError(
        error.InvalidRecordLength,
        decode(encoded[0 .. encoded.len - 1], 42, 7),
    );
    encoded[header_size + 12] ^= 1;
    try std.testing.expectError(error.CoreStateChecksumMismatch, decode(&encoded, 42, 7));
    encoded[header_size + 12] ^= 1;
    try std.testing.expectError(error.AgentIdentityMismatch, decode(&encoded, 43, 7));
    try std.testing.expectError(error.GenerationMismatch, decode(&encoded, 42, 8));
}

test "checkpoint rejects unsupported envelope metadata" {
    const state = try encodedState(42, 7, 99);
    var encoded: [encoded_size]u8 = undefined;
    try encode(&encoded, 42, 7, 9, &state);

    write(u32, &encoded, offset_flags, 1);
    try std.testing.expectError(error.UnsupportedFlags, decode(&encoded, 42, 7));
    write(u32, &encoded, offset_flags, 0);
    encoded[offset_reserved] = 1;
    try std.testing.expectError(error.NonzeroReservedByte, decode(&encoded, 42, 7));
    encoded[offset_reserved] = 0;
    write(u64, &encoded, offset_generation, @as(u64, std.math.maxInt(u32)) + 1);
    write(u32, &encoded, offset_header_crc, headerChecksum(encoded[0..header_size]));
    try std.testing.expectError(error.InvalidGeneration, decode(&encoded, 42, 7));
}
