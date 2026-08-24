const std = @import("std");

pub const max_response_size = 16 * 1024;
pub const header_size = 8;
pub const item_header_size = 8;
pub const version: u8 = 1;

const magic: u32 = 0x5352504f;

pub const Status = enum(u8) {
    complete = 1,
    length_truncated = 2,
    aborted = 3,
    provider_error = 4,
};

pub const ItemKind = enum(u8) {
    text = 1,
    tool_call = 2,
};

pub const Tool = enum(u8) {
    none = 0,
    bash = 1,
    apply_patch = 2,
};

pub const Disposition = enum(u8) {
    final_answer = 1,
    tool_call = 2,
    failure = 3,
};

pub const Failure = enum(u8) {
    none = 0,
    truncated = 1,
    aborted = 2,
    provider_error = 3,
    malformed = 4,
    empty = 5,
    multiple_tools = 6,
};

pub const Parsed = struct {
    disposition: Disposition,
    failure: Failure = .none,
    text_offset: u32 = 0,
    text_length: u32 = 0,
    tool: Tool = .none,
    arguments_offset: u32 = 0,
    arguments_length: u32 = 0,
};

pub fn encodeText(out: []u8, status: Status, text: []const u8) ![]const u8 {
    const total = if (text.len == 0) header_size else header_size + item_header_size + text.len;
    if (total > out.len or total > max_response_size) return error.ResponseTooLarge;
    @memset(out[0..total], 0);
    write(u32, out, 0, magic);
    out[4] = version;
    out[5] = @intFromEnum(status);
    out[6] = if (text.len == 0) 0 else 1;
    if (text.len == 0) return out[0..total];
    out[header_size] = @intFromEnum(ItemKind.text);
    out[header_size + 1] = @intFromEnum(Tool.none);
    write(u32, out, header_size + 4, @intCast(text.len));
    @memcpy(out[header_size + item_header_size .. total], text);
    return out[0..total];
}

pub fn encodeTool(out: []u8, tool: Tool, arguments: []const u8) ![]const u8 {
    if (tool == .none or arguments.len == 0) return error.InvalidToolCall;
    const total = header_size + item_header_size + arguments.len;
    if (total > out.len or total > max_response_size) return error.ResponseTooLarge;
    @memset(out[0..total], 0);
    write(u32, out, 0, magic);
    out[4] = version;
    out[5] = @intFromEnum(Status.complete);
    out[6] = 1;
    out[header_size] = @intFromEnum(ItemKind.tool_call);
    out[header_size + 1] = @intFromEnum(tool);
    write(u32, out, header_size + 4, @intCast(arguments.len));
    @memcpy(out[header_size + item_header_size .. total], arguments);
    return out[0..total];
}

pub fn parse(bytes: []const u8) Parsed {
    if (bytes.len < header_size or bytes.len > max_response_size) return malformed();
    if (read(u32, bytes, 0) != magic or bytes[4] != version or bytes[7] != 0) {
        return malformed();
    }
    const status: Status = switch (bytes[5]) {
        1 => .complete,
        2 => .length_truncated,
        3 => .aborted,
        4 => .provider_error,
        else => return malformed(),
    };
    switch (status) {
        .length_truncated => return failure(.truncated),
        .aborted => return failure(.aborted),
        .provider_error => return failure(.provider_error),
        .complete => {},
    }

    const item_count = bytes[6];
    if (item_count == 0) return failure(.empty);
    var cursor: usize = header_size;
    var text_offset: u32 = 0;
    var text_length: u32 = 0;
    var text_count: u8 = 0;
    var tool_count: u8 = 0;
    var tool: Tool = .none;
    var arguments_offset: u32 = 0;
    var arguments_length: u32 = 0;
    for (0..item_count) |_| {
        if (cursor > bytes.len or item_header_size > bytes.len - cursor) return malformed();
        const kind: ItemKind = switch (bytes[cursor]) {
            1 => .text,
            2 => .tool_call,
            else => return malformed(),
        };
        const item_tool: Tool = switch (bytes[cursor + 1]) {
            0 => .none,
            1 => .bash,
            2 => .apply_patch,
            else => return malformed(),
        };
        if (read(u16, bytes, cursor + 2) != 0) return malformed();
        const payload_length: usize = read(u32, bytes, cursor + 4);
        cursor += item_header_size;
        if (payload_length == 0 or payload_length > bytes.len - cursor) return malformed();
        const payload = bytes[cursor .. cursor + payload_length];
        switch (kind) {
            .text => {
                if (!utf8Valid(payload)) return malformed();
                if (item_tool != .none or text_count != 0) return malformed();
                text_count = 1;
                text_offset = @intCast(cursor);
                text_length = @intCast(payload_length);
            },
            .tool_call => {
                if (item_tool == .none) return malformed();
                tool_count += 1;
                if (tool_count > 1) return failure(.multiple_tools);
                tool = item_tool;
                arguments_offset = @intCast(cursor);
                arguments_length = @intCast(payload_length);
            },
        }
        cursor += payload_length;
    }
    if (cursor != bytes.len) return malformed();
    if (tool_count == 1) return .{
        .disposition = .tool_call,
        .text_offset = text_offset,
        .text_length = text_length,
        .tool = tool,
        .arguments_offset = arguments_offset,
        .arguments_length = arguments_length,
    };
    if (text_count == 1) return .{
        .disposition = .final_answer,
        .text_offset = text_offset,
        .text_length = text_length,
    };
    return failure(.empty);
}

test "malformed payload length cannot overflow the parser" {
    var bytes: [header_size + item_header_size]u8 = @splat(0);
    write(u32, &bytes, 0, magic);
    bytes[4] = version;
    bytes[5] = @intFromEnum(Status.complete);
    bytes[6] = 1;
    bytes[header_size] = @intFromEnum(ItemKind.text);
    write(u32, &bytes, header_size + 4, std.math.maxInt(u32));
    try std.testing.expectEqual(Failure.malformed, parse(&bytes).failure);
}

test "one binary tool call is accepted without becoming final text" {
    var bytes: [128]u8 = undefined;
    const encoded = try encodeTool(&bytes, .bash, "\x01\x00\xff");
    const parsed = parse(encoded);
    try std.testing.expectEqual(Disposition.tool_call, parsed.disposition);
    try std.testing.expectEqual(Tool.bash, parsed.tool);
    try std.testing.expectEqual(@as(u32, 3), parsed.arguments_length);
}

fn malformed() Parsed {
    return failure(.malformed);
}

fn failure(reason: Failure) Parsed {
    return .{ .disposition = .failure, .failure = reason };
}

inline fn utf8Valid(bytes: []const u8) bool {
    var index: usize = 0;
    while (index < bytes.len) {
        const first = bytes[index];
        if (first < 0x80) {
            index += 1;
            continue;
        }
        const length: usize = if (first >= 0xc2 and first <= 0xdf)
            2
        else if (first >= 0xe0 and first <= 0xef)
            3
        else if (first >= 0xf0 and first <= 0xf4)
            4
        else
            return false;
        if (index + length > bytes.len) return false;
        const second = bytes[index + 1];
        if (second & 0xc0 != 0x80) return false;
        if (length >= 3) {
            const third = bytes[index + 2];
            if (third & 0xc0 != 0x80) return false;
            if (first == 0xe0 and second < 0xa0) return false;
            if (first == 0xed and second >= 0xa0) return false;
        }
        if (length == 4) {
            const fourth = bytes[index + 3];
            if (fourth & 0xc0 != 0x80) return false;
            if (first == 0xf0 and second < 0x90) return false;
            if (first == 0xf4 and second >= 0x90) return false;
        }
        index += length;
    }
    return true;
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "a complete text item is a Final Answer" {
    var bytes: [128]u8 = undefined;
    const encoded = try encodeText(&bytes, .complete, "The parser is fixed.");
    const parsed = parse(encoded);
    try std.testing.expectEqual(Disposition.final_answer, parsed.disposition);
    try std.testing.expectEqualStrings(
        "The parser is fixed.",
        encoded[parsed.text_offset..][0..parsed.text_length],
    );
}

test "incomplete and empty responses are typed failures" {
    var bytes: [128]u8 = undefined;
    const truncated = try encodeText(&bytes, .length_truncated, "partial");
    try std.testing.expectEqual(Failure.truncated, parse(truncated).failure);
    const empty = try encodeText(&bytes, .complete, "");
    try std.testing.expectEqual(Failure.empty, parse(empty).failure);
}

test "malformed and multiple tool responses cannot become Final Answers" {
    var bytes: [128]u8 = undefined;
    const encoded = try encodeText(&bytes, .complete, "answer");
    bytes[4] = 9;
    try std.testing.expectEqual(Failure.malformed, parse(encoded).failure);

    @memset(&bytes, 0);
    write(u32, &bytes, 0, magic);
    bytes[4] = version;
    bytes[5] = @intFromEnum(Status.complete);
    bytes[6] = 2;
    var cursor: usize = header_size;
    for (0..2) |_| {
        bytes[cursor] = @intFromEnum(ItemKind.tool_call);
        bytes[cursor + 1] = @intFromEnum(Tool.bash);
        write(u32, &bytes, cursor + 4, 2);
        cursor += item_header_size;
        @memcpy(bytes[cursor..][0..2], "{}");
        cursor += 2;
    }
    try std.testing.expectEqual(Failure.multiple_tools, parse(bytes[0..cursor]).failure);
}
