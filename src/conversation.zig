const std = @import("std");
const contract = @import("model_contract.zig");

pub const call_header_size: usize = 16;
pub const result_header_size: usize = 24;
pub const max_result_content_size: usize = 180 * 1024;
pub const call_version: u16 = 1;
pub const result_version: u16 = 1;
const call_magic = "ONETCL2\x00";
const result_magic = "ONETRS2\x00";

pub const ToolCall = struct {
    key: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    parent_id: u64,
    is_error: bool,
    content: []const u8,
};

pub fn encodeToolCall(out: []u8, call: ToolCall) ![]const u8 {
    try contract.validateToolKey(call.key);
    if (!contract.canonicalJson(call.arguments)) return error.InvalidToolArguments;
    const total = call_header_size + call.key.len + call.arguments.len;
    if (total > out.len) return error.ToolCallTooLarge;
    @memset(out[0..total], 0);
    @memcpy(out[0..call_magic.len], call_magic);
    write(u16, out, 8, call_version);
    write(u16, out, 10, @intCast(call.key.len));
    write(u32, out, 12, @intCast(call.arguments.len));
    @memcpy(out[call_header_size..][0..call.key.len], call.key);
    @memcpy(out[call_header_size + call.key.len .. total], call.arguments);
    return out[0..total];
}

pub fn decodeToolCall(bytes: []const u8) !ToolCall {
    if (bytes.len < call_header_size or
        !std.mem.eql(u8, bytes[0..call_magic.len], call_magic) or
        read(u16, bytes, 8) != call_version)
    {
        return error.InvalidToolCall;
    }
    const key_length: usize = read(u16, bytes, 10);
    const arguments_length: usize = read(u32, bytes, 12);
    if (key_length > bytes.len - call_header_size or
        arguments_length > bytes.len - call_header_size - key_length or
        call_header_size + key_length + arguments_length != bytes.len)
    {
        return error.InvalidToolCall;
    }
    const call: ToolCall = .{
        .key = bytes[call_header_size..][0..key_length],
        .arguments = bytes[call_header_size + key_length ..],
    };
    try contract.validateToolKey(call.key);
    if (!contract.canonicalJson(call.arguments)) return error.InvalidToolCall;
    var canonical: [call_header_size + contract.max_tool_key_size + contract.max_arguments_size]u8 = undefined;
    if (!std.mem.eql(u8, try encodeToolCall(&canonical, call), bytes)) return error.InvalidToolCall;
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
    @memset(out[0..result_header_size], 0);
    @memcpy(out[0..result_magic.len], result_magic);
    write(u16, out, 8, result_version);
    out[10] = @intFromBool(is_error);
    write(u64, out, 12, parent_id);
    write(u32, out, 20, @intCast(content_length));
    return out[0..total];
}

pub fn decodeToolResult(bytes: []const u8) !ToolResult {
    if (bytes.len < result_header_size or
        !std.mem.eql(u8, bytes[0..result_magic.len], result_magic) or
        read(u16, bytes, 8) != result_version or bytes[11] != 0 or bytes[10] > 1)
    {
        return error.InvalidToolResult;
    }
    const content_length: usize = read(u32, bytes, 20);
    if (content_length == 0 or content_length > max_result_content_size or
        result_header_size + content_length != bytes.len)
    {
        return error.InvalidToolResult;
    }
    const result: ToolResult = .{
        .parent_id = read(u64, bytes, 12),
        .is_error = bytes[10] == 1,
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
    const encoded = try encodeToolCall(&bytes, .{ .key = "fixture.inspect.v1", .arguments = "{\"path\":\"README.md\"}" });
    const decoded = try decodeToolCall(encoded);
    try std.testing.expectEqualStrings("fixture.inspect.v1", decoded.key);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", decoded.arguments);
    std.mem.writeInt(u16, bytes[8..10], call_version - 1, .little);
    try std.testing.expectError(error.InvalidToolCall, decodeToolCall(encoded));
}

test "tool results bind their immediate parent call" {
    var bytes: [128]u8 = undefined;
    const encoded = try encodeToolResult(&bytes, .{ .parent_id = 41, .is_error = false, .content = "status=success" });
    const decoded = try decodeToolResult(encoded);
    try std.testing.expectEqual(@as(u64, 41), decoded.parent_id);
}
