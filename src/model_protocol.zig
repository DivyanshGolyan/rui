const std = @import("std");
const binding = @import("binding.zig");
const contract = @import("model_contract.zig");

pub const header_size = 24;
pub const max_resident_response_size = 20 * 1024;
pub const max_assistant_text_size = max_resident_response_size - header_size;
pub const max_response_size = header_size + contract.max_tool_key_size +
    contract.max_tool_arguments_envelope_size;
pub const version: u16 = 3;
const magic = "ONERSP3\x00";

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
    arguments_evidence: contract.StrictToolJsonEvidence = .{},
    input_shape: ?contract.InputShape = null,
    option_count: u8 = 0,
    options_offset: u32 = 0,
    options_length: u32 = 0,
};

const ValidationRecord = struct {
    parsed: Parsed,
    tool_arguments: ?contract.AdmittedToolArguments,
    result_digest: binding.Result,
    byte_length: u32,
};

pub const ValidationScratch = struct {
    json: contract.StrictToolJsonScratch = .{},
    record_bytes: [@sizeOf(ValidationRecord)]u8 align(@alignOf(ValidationRecord)) = undefined,

    fn record(self: *ValidationScratch) *ValidationRecord {
        return @ptrCast(&self.record_bytes);
    }
};

/// Borrowed opaque evidence that the exact response bytes and every semantic
/// field passed the complete validator. The record lives in caller-reserved
/// ValidationScratch and remains valid only until that scratch is reused.
pub const Validated = opaque {
    pub fn verify(self: *const Validated, bytes: []const u8) !Parsed {
        const record: *const ValidationRecord = @ptrCast(@alignCast(self));
        if (bytes.len != record.byte_length or
            !binding.eql(binding.Result, binding.hash(binding.Result, bytes), record.result_digest))
        {
            return error.InvalidModelResponseEvidence;
        }
        return record.parsed;
    }

    pub fn admittedToolArguments(
        self: *const Validated,
        bytes: []const u8,
    ) !?contract.AdmittedToolArguments {
        _ = try self.verify(bytes);
        const record: *const ValidationRecord = @ptrCast(@alignCast(self));
        return record.tool_arguments;
    }
};

pub const Choice = struct { id: []const u8, label: []const u8 };

pub fn encodeText(out: []u8, text: []const u8) ![]const u8 {
    if (text.len == 0 or text.len > max_assistant_text_size or !contract.utf8Valid(text)) {
        return error.InvalidAssistantText;
    }
    return encode(out, .final_answer, .none, 0, 0, text, "");
}

pub fn encodeTool(
    out: []u8,
    tool_key: []const u8,
    arguments: []const u8,
) ![]const u8 {
    try contract.validateToolKey(tool_key);
    if (arguments.len == 0 or arguments.len > contract.max_tool_arguments_envelope_size) {
        return error.InvalidToolArguments;
    }
    return encode(out, .tool_call, .none, 0, 0, tool_key, arguments);
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

pub fn parse(scratch: *ValidationScratch, bytes: []const u8) Parsed {
    return decode(scratch, bytes) catch failed(.malformed);
}

pub fn decode(scratch: *ValidationScratch, bytes: []const u8) !Parsed {
    return (try validate(scratch, bytes)).verify(bytes);
}

pub fn validate(
    scratch: *ValidationScratch,
    bytes: []const u8,
) !*const Validated {
    const decoded = try decodeWithScratch(&scratch.json, bytes);
    const result_digest = binding.hash(binding.Result, bytes);
    const byte_length: u32 = @intCast(bytes.len);
    const record = scratch.record();
    record.* = .{
        .parsed = decoded.parsed,
        .tool_arguments = decoded.tool_arguments,
        .result_digest = result_digest,
        .byte_length = byte_length,
    };
    return @ptrCast(record);
}

/// Admit one bounded immutable capture. Syntactically or semantically invalid
/// provider output becomes a typed terminal failure bound to the exact capture
/// bytes; callers do not retry parsing the same evidence on recovery.
pub fn admit(
    scratch: *ValidationScratch,
    bytes: []const u8,
) *const Validated {
    const decoded = decodeWithScratch(&scratch.json, bytes) catch |err| Decoded{
        .parsed = failed(switch (err) {
            error.UnknownModelTool => .unknown_tool,
            else => if (bytes.len == 0) .empty else .malformed,
        }),
    };
    const record = scratch.record();
    record.* = .{
        .parsed = decoded.parsed,
        .tool_arguments = decoded.tool_arguments,
        .result_digest = binding.hash(binding.Result, bytes),
        .byte_length = @intCast(bytes.len),
    };
    return @ptrCast(record);
}

const Decoded = struct {
    parsed: Parsed,
    tool_arguments: ?contract.AdmittedToolArguments = null,
};

fn decodeWithScratch(
    scratch: *contract.StrictToolJsonScratch,
    bytes: []const u8,
) !Decoded {
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
            return .{ .parsed = .{ .disposition = .final_answer, .text_offset = header_size, .text_length = @intCast(first.len) } };
        },
        .tool_call => {
            if (reason != .none or bytes[14] != 0 or bytes[15] != 0 or second.len == 0) {
                return error.MalformedModelResponse;
            }
            contract.validateToolKey(first) catch return error.MalformedModelResponse;
            const admitted = contract.admitToolArguments(scratch, first, second) catch |err| switch (err) {
                error.UnknownModelTool => return error.UnknownModelTool,
                else => return error.MalformedModelResponse,
            };
            const evidence = switch (admitted) {
                inline else => |value| value.json.evidence(),
            };
            return .{ .parsed = .{
                .disposition = .tool_call,
                .tool_key_offset = header_size,
                .tool_key_length = @intCast(first.len),
                .arguments_offset = @intCast(header_size + first.len),
                .arguments_length = @intCast(second.len),
                .arguments_evidence = evidence,
            }, .tool_arguments = admitted };
        },
        .input_request => return .{ .parsed = try decodeInput(bytes, first, second, reason) },
        .failure => {
            if (reason == .none or bytes[14] != 0 or bytes[15] != 0 or first.len != 0 or second.len != 0) {
                return error.MalformedModelResponse;
            }
            return .{ .parsed = failed(reason) };
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

test "complete captured responses cover every V1 disposition" {
    var bytes: [max_response_size]u8 = undefined;
    var scratch: ValidationScratch = undefined;
    try std.testing.expectEqual(Disposition.final_answer, parse(&scratch, try encodeText(&bytes, "done")).disposition);
    const tool = parse(&scratch, try encodeTool(&bytes, contract.bash_key, "{\"command\":\"true\",\"timeout_ms\":1000}"));
    try std.testing.expectEqual(Disposition.tool_call, tool.disposition);
    try std.testing.expectEqualStrings(contract.bash_key, bytes[tool.tool_key_offset..][0..tool.tool_key_length]);
    const text_input = parse(&scratch, try encodeInputText(&bytes, "Which migration should I use?"));
    try std.testing.expectEqual(Disposition.input_request, text_input.disposition);
    try std.testing.expectEqual(@as(u32, 0), text_input.options_offset);
    try std.testing.expectEqual(@as(u32, 0), text_input.options_length);
    const choices = [_]Choice{
        .{ .id = "existing", .label = "Use the existing migration" },
        .{ .id = "new", .label = "Create a new migration" },
    };
    const input = parse(&scratch, try encodeInputChoice(&bytes, "Choose one", &choices));
    try std.testing.expectEqual(contract.InputShape.single_choice, input.input_shape.?);
    try std.testing.expectEqual(@as(u8, 2), input.option_count);
    try std.testing.expectEqual(Failure.provider_error, parse(&scratch, try encodeFailure(&bytes, .provider_error)).failure);
}

test "validated response evidence is compact and byte exact" {
    const is_opaque = switch (@typeInfo(Validated)) {
        .@"opaque" => true,
        else => false,
    };
    try std.testing.expect(is_opaque);
    var first_buffer: [128]u8 = undefined;
    var second_buffer: [128]u8 = undefined;
    var scratch: ValidationScratch = undefined;
    const first = try encodeTool(&first_buffer, contract.bash_key, "{\"command\":\"true\",\"timeout_ms\":1000}");
    const second = try encodeTool(&second_buffer, contract.bash_key, "{\"command\":\"false\",\"timeout_ms\":1000}");
    const proof = try validate(&scratch, first);
    try std.testing.expectEqual(Disposition.tool_call, (try proof.verify(first)).disposition);
    try std.testing.expectError(error.InvalidModelResponseEvidence, proof.verify(second));
    try std.testing.expectEqual(@sizeOf(*const anyopaque), @sizeOf(@TypeOf(proof)));
}

test "hostile captured responses fail before authorizing effects" {
    var bytes: [max_response_size]u8 = undefined;
    var scratch: ValidationScratch = undefined;
    const encoded = try encodeTool(&bytes, contract.bash_key, "{\"command\":\"true\",\"timeout_ms\":1000}");
    bytes[20] = 0xff;
    try std.testing.expectEqual(Failure.malformed, parse(&scratch, encoded).failure);
    try std.testing.expectError(error.MalformedModelResponse, decode(&scratch, encoded));
    const current = try encodeTool(&bytes, contract.bash_key, "{\"command\":\"true\",\"timeout_ms\":1000}");
    std.mem.writeInt(u16, bytes[8..10], version - 1, .little);
    try std.testing.expectEqual(Failure.malformed, parse(&scratch, current).failure);
    try std.testing.expectEqual(Failure.truncated, parse(&scratch, try encodeFailure(&bytes, .truncated)).failure);
    const choices = [_]Choice{
        .{ .id = "same", .label = "First" },
        .{ .id = "same", .label = "Second" },
    };
    try std.testing.expectError(error.DuplicateInputChoice, encodeInputChoice(&bytes, "Choose", &choices));
}

test "semantic admission binds malformed and unknown captures as typed failures" {
    var scratch: ValidationScratch = .{};
    const malformed = "not a response";
    const malformed_proof = admit(&scratch, malformed);
    const malformed_result = try malformed_proof.verify(malformed);
    try std.testing.expectEqual(Disposition.failure, malformed_result.disposition);
    try std.testing.expectEqual(Failure.malformed, malformed_result.failure);

    var response: [max_response_size]u8 = undefined;
    const unknown = try encodeTool(&response, "fixture.unknown.v1", "{}");
    const unknown_proof = admit(&scratch, unknown);
    const unknown_result = try unknown_proof.verify(unknown);
    try std.testing.expectEqual(Disposition.failure, unknown_result.disposition);
    try std.testing.expectEqual(Failure.unknown_tool, unknown_result.failure);
    try std.testing.expectError(
        error.InvalidModelResponseEvidence,
        unknown_proof.verify("substituted"),
    );
}

test "tool response identity preserves exact noncanonical arguments" {
    var first: [max_response_size]u8 = undefined;
    var second: [max_response_size]u8 = undefined;
    const first_encoded = try encodeTool(
        &first,
        contract.bash_key,
        " { \"timeout_ms\" : 1000, \"command\" : \"true\" } ",
    );
    const second_encoded = try encodeTool(
        &second,
        contract.bash_key,
        "{\"command\":\"true\",\"timeout_ms\":1000}",
    );
    try std.testing.expect(!std.mem.eql(u8, first_encoded, second_encoded));
    var scratch: ValidationScratch = undefined;
    const first_admitted = try decode(&scratch, first_encoded);
    const first_digest = first_admitted.arguments_evidence.digest;
    const second_admitted = try decode(&scratch, second_encoded);
    try std.testing.expect(!std.mem.eql(u8, &first_digest, &second_admitted.arguments_evidence.digest));
    const malformed = try encodeTool(&first, contract.bash_key, "{\"command\":\"true\",\"command\":\"false\",\"timeout_ms\":1000}");
    try std.testing.expectError(error.MalformedModelResponse, decode(&scratch, malformed));
}
