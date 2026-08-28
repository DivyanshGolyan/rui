const std = @import("std");
const contract = @import("model_contract.zig");

pub const header_size = 24;
pub const max_resident_response_size = 20 * 1024;
pub const max_assistant_text_size = max_resident_response_size - header_size;
pub const max_response_size = header_size + contract.max_tool_key_size +
    contract.max_tool_arguments_envelope_size;
pub const version: u16 = 2;
const magic = "ONERSP2\x00";

pub const Disposition = enum(u8) { final_answer = 1, tool_call = 2, input_request = 3, failure = 4 };
pub const Failure = enum(u8) {
    none = 0,
    truncated = 1,
    aborted = 2,
    provider_error = 3,
    malformed = 4,
    empty = 5,
    multiple_outputs = 6,
    oversized = 7,
    unknown_tool = 8,
};

pub const Parsed = struct {
    disposition: Disposition,
    failure: Failure = .none,
    text_offset: u32 = 0,
    text_length: u32 = 0,
    tool_key_offset: u32 = 0,
    tool_key_length: u32 = 0,
    arguments_offset: u32 = 0,
    arguments_length: u32 = 0,
    input_shape: ?contract.InputShape = null,
    option_count: u8 = 0,
    options_offset: u32 = 0,
    options_length: u32 = 0,
};

pub const Choice = struct { id: []const u8, label: []const u8 };

pub fn encodeText(out: []u8, text: []const u8) ![]const u8 {
    if (text.len == 0 or text.len > max_assistant_text_size or !contract.utf8Valid(text)) {
        return error.InvalidAssistantText;
    }
    return encode(out, .final_answer, .none, 0, 0, text, "");
}

pub fn encodeTool(out: []u8, tool_key: []const u8, arguments: []const u8) ![]const u8 {
    try contract.validateToolKey(tool_key);
    if (out.len < header_size + tool_key.len) return error.ResponseTooLarge;
    const canonical = contract.canonicalizeJson(
        out[header_size + tool_key.len ..],
        arguments,
    ) catch return error.InvalidToolArguments;
    return encode(out, .tool_call, .none, 0, 0, tool_key, canonical.bytes());
}

pub fn encodeInputText(out: []u8, prompt: []const u8) ![]const u8 {
    try validatePrompt(prompt);
    return encode(out, .input_request, .none, @intFromEnum(contract.InputShape.text), 0, prompt, "");
}

pub fn encodeInputChoice(out: []u8, prompt: []const u8, choices: []const Choice) ![]const u8 {
    try validatePrompt(prompt);
    if (choices.len == 0 or choices.len > contract.max_choice_count) return error.InvalidInputChoices;
    var option_bytes: [
        contract.max_choice_count *
            (4 + contract.max_choice_id_size + contract.max_choice_label_size)
    ]u8 = undefined;
    var cursor: usize = 0;
    for (choices, 0..) |choice, index| {
        if (choice.id.len == 0 or choice.id.len > contract.max_choice_id_size or
            choice.label.len == 0 or choice.label.len > contract.max_choice_label_size or
            !contract.utf8Valid(choice.id) or !contract.utf8Valid(choice.label))
        {
            return error.InvalidInputChoices;
        }
        for (choices[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.id, choice.id)) return error.DuplicateInputChoice;
        }
        write(u16, &option_bytes, cursor, @intCast(choice.id.len));
        write(u16, &option_bytes, cursor + 2, @intCast(choice.label.len));
        cursor += 4;
        @memcpy(option_bytes[cursor..][0..choice.id.len], choice.id);
        cursor += choice.id.len;
        @memcpy(option_bytes[cursor..][0..choice.label.len], choice.label);
        cursor += choice.label.len;
    }
    return encode(
        out,
        .input_request,
        .none,
        @intFromEnum(contract.InputShape.single_choice),
        @intCast(choices.len),
        prompt,
        option_bytes[0..cursor],
    );
}

pub fn encodeFailure(out: []u8, reason: Failure) ![]const u8 {
    if (reason == .none) return error.InvalidProviderFailure;
    return encode(out, .failure, reason, 0, 0, "", "");
}

fn encode(
    out: []u8,
    disposition: Disposition,
    reason: Failure,
    shape: u8,
    option_count: u8,
    first: []const u8,
    second: []const u8,
) ![]const u8 {
    const total = header_size + first.len + second.len;
    if (total > out.len or total > max_response_size) return error.ResponseTooLarge;
    @memset(out[0..header_size], 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, 8, version);
    write(u16, out, 10, header_size);
    out[12] = @intFromEnum(disposition);
    out[13] = @intFromEnum(reason);
    out[14] = shape;
    out[15] = option_count;
    write(u32, out, 16, @intCast(first.len));
    write(u32, out, 20, @intCast(second.len));
    @memcpy(out[header_size..][0..first.len], first);
    if (second.ptr != out[header_size + first.len ..].ptr) {
        @memcpy(out[header_size + first.len .. total], second);
    }
    return out[0..total];
}

pub fn parse(bytes: []const u8) Parsed {
    return decode(bytes) catch failed(.malformed);
}

pub fn decode(bytes: []const u8) !Parsed {
    if (bytes.len < header_size or bytes.len > max_response_size or
        !std.mem.eql(u8, bytes[0..magic.len], magic) or read(u16, bytes, 8) != version or
        read(u16, bytes, 10) != header_size)
    {
        return error.MalformedModelResponse;
    }
    const disposition = std.enums.fromInt(Disposition, bytes[12]) orelse return error.MalformedModelResponse;
    const reason = std.enums.fromInt(Failure, bytes[13]) orelse return error.MalformedModelResponse;
    const first_length: usize = read(u32, bytes, 16);
    const second_length: usize = read(u32, bytes, 20);
    if (first_length > bytes.len - header_size or
        second_length > bytes.len - header_size - first_length or
        header_size + first_length + second_length != bytes.len)
    {
        return error.MalformedModelResponse;
    }
    const first = bytes[header_size..][0..first_length];
    const second = bytes[header_size + first_length ..];
    switch (disposition) {
        .final_answer => {
            if (reason != .none or bytes[14] != 0 or bytes[15] != 0 or first.len == 0 or
                first.len > max_assistant_text_size or
                second.len != 0 or !contract.utf8Valid(first)) return error.MalformedModelResponse;
            return .{ .disposition = .final_answer, .text_offset = header_size, .text_length = @intCast(first.len) };
        },
        .tool_call => {
            if (reason != .none or bytes[14] != 0 or bytes[15] != 0 or second.len == 0) {
                return error.MalformedModelResponse;
            }
            contract.validateToolKey(first) catch return error.MalformedModelResponse;
            if (!contract.canonicalJson(second)) return error.MalformedModelResponse;
            return .{
                .disposition = .tool_call,
                .tool_key_offset = header_size,
                .tool_key_length = @intCast(first.len),
                .arguments_offset = @intCast(header_size + first.len),
                .arguments_length = @intCast(second.len),
            };
        },
        .input_request => return try decodeInput(bytes, first, second, reason),
        .failure => {
            if (reason == .none or bytes[14] != 0 or bytes[15] != 0 or first.len != 0 or second.len != 0) {
                return error.MalformedModelResponse;
            }
            return failed(reason);
        },
    }
}

fn decodeInput(bytes: []const u8, prompt: []const u8, options: []const u8, reason: Failure) !Parsed {
    if (reason != .none or prompt.len == 0 or prompt.len > contract.max_prompt_size or
        !contract.utf8Valid(prompt)) return error.MalformedModelResponse;
    const shape = std.enums.fromInt(contract.InputShape, bytes[14]) orelse return error.MalformedModelResponse;
    const count = bytes[15];
    switch (shape) {
        .text => if (count != 0 or options.len != 0) return error.MalformedModelResponse,
        .single_choice => {
            if (count == 0 or count > contract.max_choice_count) return error.MalformedModelResponse;
            var cursor: usize = 0;
            var ids: [contract.max_choice_count][]const u8 = undefined;
            for (0..count) |index| {
                if (cursor > options.len or options.len - cursor < 4) return error.MalformedModelResponse;
                const id_length: usize = read(u16, options, cursor);
                const label_length: usize = read(u16, options, cursor + 2);
                cursor += 4;
                if (id_length == 0 or id_length > contract.max_choice_id_size or
                    label_length == 0 or label_length > contract.max_choice_label_size or
                    id_length > options.len - cursor or label_length > options.len - cursor - id_length)
                {
                    return error.MalformedModelResponse;
                }
                const id = options[cursor..][0..id_length];
                const label = options[cursor + id_length ..][0..label_length];
                if (!contract.utf8Valid(id) or !contract.utf8Valid(label)) return error.MalformedModelResponse;
                for (ids[0..index]) |earlier| if (std.mem.eql(u8, earlier, id)) return error.MalformedModelResponse;
                ids[index] = id;
                cursor += id_length + label_length;
            }
            if (cursor != options.len) return error.MalformedModelResponse;
        },
    }
    return .{
        .disposition = .input_request,
        .text_offset = header_size,
        .text_length = @intCast(prompt.len),
        .input_shape = shape,
        .option_count = count,
        .options_offset = if (options.len == 0) 0 else @intCast(header_size + prompt.len),
        .options_length = @intCast(options.len),
    };
}

fn validatePrompt(prompt: []const u8) !void {
    if (prompt.len == 0 or prompt.len > contract.max_prompt_size or !contract.utf8Valid(prompt)) {
        return error.InvalidInputPrompt;
    }
}

fn failed(reason: Failure) Parsed {
    return .{ .disposition = .failure, .failure = reason };
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "complete normalized responses cover every V1 disposition" {
    var bytes: [max_response_size]u8 = undefined;
    try std.testing.expectEqual(Disposition.final_answer, parse(try encodeText(&bytes, "done")).disposition);
    const tool = parse(try encodeTool(&bytes, "fixture.tool", "{\"value\":1}"));
    try std.testing.expectEqual(Disposition.tool_call, tool.disposition);
    try std.testing.expectEqualStrings("fixture.tool", bytes[tool.tool_key_offset..][0..tool.tool_key_length]);
    const text_input = parse(try encodeInputText(&bytes, "Which migration should I use?"));
    try std.testing.expectEqual(Disposition.input_request, text_input.disposition);
    try std.testing.expectEqual(@as(u32, 0), text_input.options_offset);
    try std.testing.expectEqual(@as(u32, 0), text_input.options_length);
    const choices = [_]Choice{
        .{ .id = "existing", .label = "Use the existing migration" },
        .{ .id = "new", .label = "Create a new migration" },
    };
    const input = parse(try encodeInputChoice(&bytes, "Choose one", &choices));
    try std.testing.expectEqual(contract.InputShape.single_choice, input.input_shape.?);
    try std.testing.expectEqual(@as(u8, 2), input.option_count);
    try std.testing.expectEqual(Failure.provider_error, parse(try encodeFailure(&bytes, .provider_error)).failure);
}

test "hostile normalized responses fail before authorizing effects" {
    var bytes: [max_response_size]u8 = undefined;
    const encoded = try encodeTool(&bytes, "fixture.tool", "{}");
    bytes[20] = 0xff;
    try std.testing.expectEqual(Failure.malformed, parse(encoded).failure);
    try std.testing.expectError(error.MalformedModelResponse, decode(encoded));
    const current = try encodeTool(&bytes, "fixture.tool", "{}");
    std.mem.writeInt(u16, bytes[8..10], version - 1, .little);
    try std.testing.expectEqual(Failure.malformed, parse(current).failure);
    try std.testing.expectEqual(Failure.truncated, parse(try encodeFailure(&bytes, .truncated)).failure);
    const choices = [_]Choice{
        .{ .id = "same", .label = "First" },
        .{ .id = "same", .label = "Second" },
    };
    try std.testing.expectError(error.DuplicateInputChoice, encodeInputChoice(&bytes, "Choose", &choices));
}

test "tool response identity uses canonical arguments" {
    var first: [max_response_size]u8 = undefined;
    var second: [max_response_size]u8 = undefined;
    const first_encoded = try encodeTool(
        &first,
        "fixture.tool",
        "{\"z\":-0.0,\"a\":{\"text\":\"\\u0061\",\"number\":1e0}}",
    );
    const second_encoded = try encodeTool(
        &second,
        "fixture.tool",
        "{\"a\":{\"number\":1,\"text\":\"a\"},\"z\":0}",
    );
    try std.testing.expectEqualSlices(u8, first_encoded, second_encoded);
    try std.testing.expectError(
        error.InvalidToolArguments,
        encodeTool(&first, "fixture.tool", "{\"a\":1,\"a\":2}"),
    );
}
