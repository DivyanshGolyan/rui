const std = @import("std");
const contract = @import("model_contract.zig");

pub const call_header_size: usize = 48;
pub const result_header_size: usize = 24;
pub const max_result_content_size: usize = 180 * 1024;
pub const call_version: u16 = 2;
pub const result_version: u16 = 1;
const call_magic = "ONETCL3\x00";
const result_magic = "ONETRS2\x00";

pub const ToolCall = struct {
    key: []const u8,
    arguments: []const u8,
};

pub const AdmittedToolCall = struct {
    key: []const u8,
    arguments: contract.StrictToolJson,
};

pub const ToolResult = struct {
    parent_id: u64,
    is_error: bool,
    content: []const u8,
};

pub const ToolCallHeader = struct {
    key_length: u16,
    arguments_length: u32,
    arguments_evidence: contract.StrictToolJsonEvidence,
};

pub const ToolResultHeader = struct {
    parent_id: u64,
    is_error: bool,
    content_length: u32,
};

pub fn encodeToolCall(
    out: []u8,
    call: AdmittedToolCall,
) ![]const u8 {
    try contract.validateToolKey(call.key);
    const arguments = call.arguments.bytes();
    const total = call_header_size + call.key.len + arguments.len;
    if (total > out.len) return error.ToolCallTooLarge;
    _ = try encodeToolCallHeader(
        out[0..call_header_size],
        call.key.len,
        arguments.len,
        call.arguments.evidence(),
    );
    @memcpy(out[call_header_size..][0..call.key.len], call.key);
    @memcpy(out[call_header_size + call.key.len .. total], arguments);
    return out[0..total];
}

pub fn encodeToolCallHeader(
    out: []u8,
    key_length: usize,
    arguments_length: usize,
    arguments_evidence: contract.StrictToolJsonEvidence,
) ![]const u8 {
    if (out.len < call_header_size or key_length == 0 or key_length > contract.max_tool_key_size or
        arguments_length == 0 or arguments_length > contract.max_tool_arguments_envelope_size or
        !arguments_evidence.validForLength(@intCast(arguments_length)))
    {
        return error.InvalidToolCall;
    }
    @memset(out[0..call_header_size], 0);
    @memcpy(out[0..call_magic.len], call_magic);
    write(u16, out, 8, call_version);
    write(u16, out, 10, @intCast(key_length));
    write(u32, out, 12, @intCast(arguments_length));
    @memcpy(out[16..48], &arguments_evidence.digest);
    return out[0..call_header_size];
}

pub fn decodeToolCallHeader(bytes: []const u8, total_length: u64) !ToolCallHeader {
    if (bytes.len < call_header_size or
        !std.mem.eql(u8, bytes[0..call_magic.len], call_magic) or
        read(u16, bytes, 8) != call_version)
    {
        return error.InvalidToolCall;
    }
    const header: ToolCallHeader = .{
        .key_length = read(u16, bytes, 10),
        .arguments_length = read(u32, bytes, 12),
        .arguments_evidence = .{
            .digest = bytes[16..48].*,
            .length = read(u32, bytes, 12),
        },
    };
    if (header.key_length == 0 or header.key_length > contract.max_tool_key_size or
        header.arguments_length == 0 or
        header.arguments_length > contract.max_tool_arguments_envelope_size or
        !header.arguments_evidence.validForLength(header.arguments_length) or
        call_header_size + @as(u64, header.key_length) + header.arguments_length != total_length)
    {
        return error.InvalidToolCall;
    }
    return header;
}

pub fn decodeToolCall(bytes: []const u8) !ToolCall {
    const header = try decodeToolCallHeader(bytes, bytes.len);
    const key_length: usize = header.key_length;
    const arguments = bytes[call_header_size + key_length ..];
    _ = try contract.strictToolJsonFromEvidence(arguments, header.arguments_evidence);
    const call: ToolCall = .{
        .key = bytes[call_header_size..][0..key_length],
        .arguments = arguments,
    };
    try contract.validateToolKey(call.key);
    return call;
}

pub fn encodeToolResult(out: []u8, result: ToolResult) ![]const u8 {
    if (result.parent_id == 0 or result.content.len == 0 or
        result.content.len > max_result_content_size or !contract.utf8Valid(result.content))
    {
        return error.InvalidToolResult;
    }
    const total = result_header_size + result.content.len;
    if (total > out.len) return error.ToolResultTooLarge;
    @memcpy(out[result_header_size..total], result.content);
    return finishToolResult(out, result.parent_id, result.is_error, result.content.len);
}

/// Finalize a tool-result envelope whose content has already been written at
/// `out[result_header_size..]`. This lets lifecycle conversion produce the
/// canonical durable value once instead of retaining a second complete copy.
pub fn finishToolResult(
    out: []u8,
    parent_id: u64,
    is_error: bool,
    content_length: usize,
) ![]const u8 {
    if (parent_id == 0 or content_length == 0 or content_length > max_result_content_size or
        result_header_size + content_length > out.len or
        !contract.utf8Valid(out[result_header_size..][0..content_length]))
    {
        return error.InvalidToolResult;
    }
    const total = result_header_size + content_length;
    _ = try encodeToolResultHeader(out[0..result_header_size], parent_id, is_error, content_length);
    return out[0..total];
}

pub fn encodeToolResultHeader(
    out: []u8,
    parent_id: u64,
    is_error: bool,
    content_length: usize,
) ![]const u8 {
    if (out.len < result_header_size or parent_id == 0 or content_length == 0 or
        content_length > max_result_content_size)
    {
        return error.InvalidToolResult;
    }
    @memset(out[0..result_header_size], 0);
    @memcpy(out[0..result_magic.len], result_magic);
    write(u16, out, 8, result_version);
    out[10] = @intFromBool(is_error);
    write(u64, out, 12, parent_id);
    write(u32, out, 20, @intCast(content_length));
    return out[0..result_header_size];
}

pub fn decodeToolResultHeader(bytes: []const u8, total_length: u64) !ToolResultHeader {
    if (bytes.len < result_header_size or
        !std.mem.eql(u8, bytes[0..result_magic.len], result_magic) or
        read(u16, bytes, 8) != result_version or bytes[11] != 0 or bytes[10] > 1)
    {
        return error.InvalidToolResult;
    }
    const header: ToolResultHeader = .{
        .parent_id = read(u64, bytes, 12),
        .is_error = bytes[10] == 1,
        .content_length = read(u32, bytes, 20),
    };
    if (header.parent_id == 0 or header.content_length == 0 or
        header.content_length > max_result_content_size or
        result_header_size + @as(u64, header.content_length) != total_length)
    {
        return error.InvalidToolResult;
    }
    return header;
}

pub fn decodeToolResult(bytes: []const u8) !ToolResult {
    const header = try decodeToolResultHeader(bytes, bytes.len);
    const result: ToolResult = .{
        .parent_id = header.parent_id,
        .is_error = header.is_error,
        .content = bytes[result_header_size..],
    };
    if (result.parent_id == 0 or !contract.utf8Valid(result.content)) return error.InvalidToolResult;
    return result;
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "arbitrary Tool Keys round trip without execution meaning" {
    var bytes: [128]u8 = undefined;
    var scratch: contract.StrictToolJsonScratch = undefined;
    const arguments = try contract.validateStrictToolJson(&scratch, " { \"path\" : \"README.md\" } ");
    const encoded = try encodeToolCall(&bytes, .{ .key = "fixture.inspect.v1", .arguments = arguments });
    const decoded = try decodeToolCall(encoded);
    try std.testing.expectEqualStrings("fixture.inspect.v1", decoded.key);
    try std.testing.expectEqualStrings(" { \"path\" : \"README.md\" } ", decoded.arguments);
    const last = encoded.len - 1;
    const original_last = bytes[last];
    bytes[last] = if (original_last == ' ') '\n' else ' ';
    try std.testing.expectError(error.InvalidStrictToolJsonEvidence, decodeToolCall(encoded));
    bytes[last] = original_last;
    std.mem.writeInt(u16, bytes[8..10], call_version - 1, .little);
    try std.testing.expectError(error.InvalidToolCall, decodeToolCall(encoded));
}

test "tool calls persist exact admitted argument bytes" {
    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    var scratch: contract.StrictToolJsonScratch = undefined;
    const first_arguments = try contract.validateStrictToolJson(&scratch, " { \"z\" : -0.0, \"a\" : { \"text\" : \"\\u0061\", \"number\" : 1e0 } } ");
    const second_arguments = try contract.validateStrictToolJson(&scratch, "{\"a\":{\"number\":1,\"text\":\"a\"},\"z\":0}");
    const first_encoded = try encodeToolCall(&first, .{
        .key = "fixture.inspect.v1",
        .arguments = first_arguments,
    });
    const second_encoded = try encodeToolCall(&second, .{
        .key = "fixture.inspect.v1",
        .arguments = second_arguments,
    });
    try std.testing.expect(!std.mem.eql(u8, first_encoded, second_encoded));
}

test "tool results bind their immediate parent call" {
    var bytes: [128]u8 = undefined;
    const encoded = try encodeToolResult(&bytes, .{ .parent_id = 41, .is_error = false, .content = "status=success" });
    const decoded = try decodeToolResult(encoded);
    try std.testing.expectEqual(@as(u64, 41), decoded.parent_id);
}
