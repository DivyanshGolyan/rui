const std = @import("std");
const binding = @import("binding.zig");
const contract = @import("model_contract.zig");

pub const header_size = 24;
pub const max_resident_response_size = 20 * 1024;
pub const max_assistant_text_size = max_resident_response_size - header_size;
pub const max_failure_diagnostic_code_size: usize = 64;
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
    missing_authentication = 9,
    authentication_expired = 10,
    model_unavailable = 11,
    timeout = 12,
    transport_not_started = 13,
    transport_may_have_started = 14,
};

pub const DiagnosticSource = enum(u8) {
    none = 0,
    local_refresh_rejected = 1,
    local_refresh_missing = 2,
    provider_http_401 = 3,
    provider_http_403 = 4,
    provider_http_rejection = 5,
    provider_model_not_found = 6,
    provider_rate_limited = 7,
    provider_quota_exceeded = 8,
    provider_backend_failure = 9,
};

pub const FailureDiagnostic = struct {
    source: DiagnosticSource = .none,
    http_status: ?u16 = null,
    code: []const u8 = "",
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
    arguments_digest: binding.StrictToolJsonV1 = .{ .bytes = @splat(0) },
    input_shape: ?contract.InputShape = null,
    option_count: u8 = 0,
    options_offset: u32 = 0,
    options_length: u32 = 0,
};

/// Compact semantic authority copied out of reconstructible validation
/// scratch before later preparation can wait. It contains no parsed JSON
/// pointers or response bytes.
pub const Admission = struct {
    parsed_value: Parsed,
    result_digest: binding.Result,
    byte_length: u32,

    pub fn verify(self: Admission, expected_digest: binding.Result) !Parsed {
        if (!binding.eql(binding.Result, self.result_digest, expected_digest)) {
            return error.InvalidModelResponseEvidence;
        }
        return self.parsed_value;
    }
};

pub const ValidationScratch = struct {
    json: contract.StrictToolJsonScratch = .{},
};

/// Complete one-pass result. `tool_arguments` borrows the caller-owned
/// validation scratch and is consumed before that scratch is released;
/// `admission` is the compact durable authority that survives it.
pub const CapturedAdmission = struct {
    admission: Admission,
    tool_arguments: ?contract.AdmittedToolArguments = null,

    /// Replace a generically admitted tool call with the capture-bound terminal
    /// failure used when the Host's closed executable mapping rejects it.
    pub fn rejectToolCall(self: *CapturedAdmission) !void {
        if (self.admission.parsed_value.disposition != .tool_call) {
            return error.ExpectedAdmittedToolCall;
        }
        self.admission.parsed_value = failed(.malformed);
        self.tool_arguments = null;
    }
};

/// Resolves only the Tool Definition selected by the already-inspected capture.
/// The decoder remains private; callers provide the Operation-bound catalog
/// ownership seam without receiving a reusable parser object.
pub const DefinitionResolver = struct {
    context: *anyopaque,
    resolve_fn: *const fn (*anyopaque, []const u8) anyerror!?contract.ToolDefinition,

    fn resolve(self: DefinitionResolver, key: []const u8) !?contract.ToolDefinition {
        return self.resolve_fn(self.context, key);
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

pub fn encodeFailureDiagnostic(
    out: []u8,
    reason: Failure,
    source: DiagnosticSource,
    http_status: ?u16,
    code: []const u8,
) ![]const u8 {
    try validateFailureDiagnostic(reason, source, http_status, code);
    var status_bytes: [2]u8 = undefined;
    const encoded_status = if (http_status) |status| blk: {
        write(u16, &status_bytes, 0, status);
        break :blk status_bytes[0..];
    } else "";
    return encode(out, .failure, reason, @intFromEnum(source), 0, code, encoded_status);
}

pub fn inspectFailureDiagnostic(bytes: []const u8) !FailureDiagnostic {
    const inspected = try inspect(bytes);
    if (inspected.disposition != .failure) return error.ExpectedFailureResponse;
    const source = std.enums.fromInt(DiagnosticSource, inspected.shape) orelse
        return error.MalformedModelResponse;
    const http_status = try decodeFailureDiagnosticStatus(inspected.second);
    try validateFailureDiagnostic(inspected.reason, source, http_status, inspected.first);
    return .{ .source = source, .http_status = http_status, .code = inspected.first };
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
    return (try decodeWithCatalog(&scratch.json, bytes, &contract.default_catalog)).parsed;
}

/// Admit one bounded capture against the built-in catalog. The capture digest
/// and envelope framing are each computed once.
pub fn admit(
    scratch: *ValidationScratch,
    bytes: []const u8,
) CapturedAdmission {
    return admitWithCatalog(scratch, bytes, &contract.default_catalog);
}

pub fn admitWithCatalog(
    scratch: *ValidationScratch,
    bytes: []const u8,
    catalog: []const contract.ToolDefinition,
) CapturedAdmission {
    const result_digest = binding.hash(binding.Result, bytes);
    return admitWithCatalogDigest(scratch, bytes, catalog, result_digest);
}

/// Admit immutable captured evidence against the selected Operation-bound Tool
/// Catalog. Exact capture identity is consumed once before any inspected field
/// is authoritative; invalid provider output becomes a typed terminal failure.
pub fn admitCaptured(
    scratch: *ValidationScratch,
    bytes: []const u8,
    expected_digest: binding.Result,
    resolver: DefinitionResolver,
) !CapturedAdmission {
    const actual_digest = binding.hash(binding.Result, bytes);
    if (!binding.eql(binding.Result, actual_digest, expected_digest)) {
        return error.InvalidModelResponseEvidence;
    }
    const inspected = inspect(bytes) catch |err| return typedFailure(bytes, expected_digest, err);
    const decoded = finishWithResolver(&scratch.json, inspected, resolver) catch |err|
        return switch (err) {
            error.UnknownModelTool => typedFailure(bytes, expected_digest, err),
            error.MalformedModelResponse => typedFailure(bytes, expected_digest, err),
            else => err,
        };
    return completeAdmission(decoded, expected_digest, bytes.len);
}

const Decoded = struct {
    parsed: Parsed,
    tool_arguments: ?contract.AdmittedToolArguments = null,
};

const Inspected = struct {
    disposition: Disposition,
    reason: Failure,
    shape: u8,
    option_count: u8,
    first: []const u8,
    second: []const u8,
};

fn inspect(bytes: []const u8) !Inspected {
    if (bytes.len < header_size or bytes.len > max_response_size or
        !std.mem.eql(u8, bytes[0..magic.len], magic) or read(u16, bytes, 8) != version or
        read(u16, bytes, 10) != header_size)
    {
        return error.MalformedModelResponse;
    }
    const disposition = std.enums.fromInt(Disposition, bytes[12]) orelse
        return error.MalformedModelResponse;
    const reason = std.enums.fromInt(Failure, bytes[13]) orelse
        return error.MalformedModelResponse;
    const first_length: usize = read(u32, bytes, 16);
    const second_length: usize = read(u32, bytes, 20);
    if (first_length > bytes.len - header_size or
        second_length > bytes.len - header_size - first_length or
        header_size + first_length + second_length != bytes.len)
    {
        return error.MalformedModelResponse;
    }
    return .{
        .disposition = disposition,
        .reason = reason,
        .shape = bytes[14],
        .option_count = bytes[15],
        .first = bytes[header_size..][0..first_length],
        .second = bytes[header_size + first_length ..],
    };
}

fn decodeWithCatalog(
    scratch: *contract.StrictToolJsonScratch,
    bytes: []const u8,
    catalog: []const contract.ToolDefinition,
) !Decoded {
    const inspected = try inspect(bytes);
    return finishWithCatalog(scratch, inspected, catalog);
}

fn finishWithCatalog(
    scratch: *contract.StrictToolJsonScratch,
    inspected: Inspected,
    catalog: []const contract.ToolDefinition,
) !Decoded {
    const definition = if (inspected.disposition == .tool_call)
        contract.definitionForKey(catalog, inspected.first)
    else
        null;
    return finish(scratch, inspected, definition);
}

fn finishWithResolver(
    scratch: *contract.StrictToolJsonScratch,
    inspected: Inspected,
    resolver: DefinitionResolver,
) !Decoded {
    const definition = if (inspected.disposition == .tool_call)
        try resolver.resolve(inspected.first)
    else
        null;
    return finish(scratch, inspected, definition);
}

fn finish(
    scratch: *contract.StrictToolJsonScratch,
    inspected: Inspected,
    definition: ?contract.ToolDefinition,
) !Decoded {
    const first = inspected.first;
    const second = inspected.second;
    switch (inspected.disposition) {
        .final_answer => {
            if (inspected.reason != .none or inspected.shape != 0 or inspected.option_count != 0 or first.len == 0 or
                first.len > max_assistant_text_size or
                second.len != 0 or !contract.utf8Valid(first)) return error.MalformedModelResponse;
            return .{ .parsed = .{ .disposition = .final_answer, .text_offset = header_size, .text_length = @intCast(first.len) } };
        },
        .tool_call => {
            if (inspected.reason != .none or inspected.shape != 0 or inspected.option_count != 0 or second.len == 0) {
                return error.MalformedModelResponse;
            }
            contract.validateToolKey(first) catch return error.MalformedModelResponse;
            const selected = definition orelse return error.UnknownModelTool;
            if (!std.mem.eql(u8, selected.key, first)) return error.UnknownModelTool;
            const admitted = contract.admitToolArguments(scratch, selected, second) catch
                return error.MalformedModelResponse;
            const evidence = admitted.json.evidence();
            return .{ .parsed = .{
                .disposition = .tool_call,
                .tool_key_offset = header_size,
                .tool_key_length = @intCast(first.len),
                .arguments_offset = @intCast(header_size + first.len),
                .arguments_length = @intCast(second.len),
                .arguments_digest = evidence,
            }, .tool_arguments = admitted };
        },
        .input_request => return .{ .parsed = try decodeInput(
            first,
            second,
            inspected.reason,
            inspected.shape,
            inspected.option_count,
        ) },
        .failure => {
            const source = std.enums.fromInt(DiagnosticSource, inspected.shape) orelse
                return error.MalformedModelResponse;
            const http_status = decodeFailureDiagnosticStatus(second) catch
                return error.MalformedModelResponse;
            validateFailureDiagnostic(inspected.reason, source, http_status, first) catch
                return error.MalformedModelResponse;
            if (inspected.option_count != 0) {
                return error.MalformedModelResponse;
            }
            return .{ .parsed = failed(inspected.reason) };
        },
    }
}

fn admitWithCatalogDigest(
    scratch: *ValidationScratch,
    bytes: []const u8,
    catalog: []const contract.ToolDefinition,
    result_digest: binding.Result,
) CapturedAdmission {
    const decoded = decodeWithCatalog(&scratch.json, bytes, catalog) catch |err|
        return typedFailure(bytes, result_digest, err);
    return completeAdmission(decoded, result_digest, bytes.len);
}

fn completeAdmission(decoded: Decoded, result_digest: binding.Result, byte_length: usize) CapturedAdmission {
    return .{
        .admission = .{
            .parsed_value = decoded.parsed,
            .result_digest = result_digest,
            .byte_length = @intCast(byte_length),
        },
        .tool_arguments = decoded.tool_arguments,
    };
}

fn typedFailure(bytes: []const u8, result_digest: binding.Result, err: anyerror) CapturedAdmission {
    return completeAdmission(.{ .parsed = failed(switch (err) {
        error.UnknownModelTool => .unknown_tool,
        else => if (bytes.len == 0) .empty else .malformed,
    }) }, result_digest, bytes.len);
}

const TestCatalogResolver = struct {
    catalog: []const contract.ToolDefinition,
    calls: u8 = 0,

    fn resolve(context: *anyopaque, key: []const u8) anyerror!?contract.ToolDefinition {
        const self: *TestCatalogResolver = @ptrCast(@alignCast(context));
        self.calls += 1;
        return contract.definitionForKey(self.catalog, key);
    }

    fn capability(self: *TestCatalogResolver) DefinitionResolver {
        return .{ .context = self, .resolve_fn = resolve };
    }
};

fn decodeInput(
    prompt: []const u8,
    options: []const u8,
    reason: Failure,
    shape_byte: u8,
    count: u8,
) !Parsed {
    if (reason != .none or prompt.len == 0 or prompt.len > contract.max_prompt_size or
        !contract.utf8Valid(prompt)) return error.MalformedModelResponse;
    const shape = std.enums.fromInt(contract.InputShape, shape_byte) orelse return error.MalformedModelResponse;
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

fn decodeFailureDiagnosticStatus(bytes: []const u8) !?u16 {
    if (bytes.len == 0) return null;
    if (bytes.len != 2) return error.InvalidFailureDiagnosticStatus;
    return read(u16, bytes, 0);
}

fn validateFailureDiagnostic(
    reason: Failure,
    source: DiagnosticSource,
    http_status: ?u16,
    code: []const u8,
) !void {
    if (reason == .none) return error.InvalidProviderFailure;
    if (source == .none) {
        if (http_status != null) return error.InvalidFailureDiagnosticStatus;
        if (code.len != 0) return error.InvalidFailureDiagnosticCode;
        return;
    }
    if (http_status) |status| {
        if (status < 100 or status > 599) return error.InvalidFailureDiagnosticStatus;
    }
    switch (source) {
        .local_refresh_rejected, .local_refresh_missing => {
            if (reason != .authentication_expired) return error.InvalidFailureDiagnosticSource;
            if (http_status != null) return error.InvalidFailureDiagnosticStatus;
            if (code.len != 0) return error.InvalidFailureDiagnosticCode;
        },
        .provider_http_401, .provider_http_403 => {
            if (reason != .authentication_expired) return error.InvalidFailureDiagnosticSource;
            if (http_status) |status| {
                const expected: u16 = if (source == .provider_http_401) 401 else 403;
                if (status != expected) return error.InvalidFailureDiagnosticStatus;
            }
            try validateFailureDiagnosticCode(code);
        },
        .provider_http_rejection,
        .provider_rate_limited,
        .provider_quota_exceeded,
        .provider_backend_failure,
        => {
            if (reason != .provider_error) return error.InvalidFailureDiagnosticSource;
            try validateFailureDiagnosticCode(code);
        },
        .provider_model_not_found => {
            if (reason != .model_unavailable) return error.InvalidFailureDiagnosticSource;
            try validateFailureDiagnosticCode(code);
        },
        .none => unreachable,
    }
}

fn validateFailureDiagnosticCode(code: []const u8) !void {
    if (code.len > max_failure_diagnostic_code_size) {
        return error.InvalidFailureDiagnosticCode;
    }
    for (code) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '_' and byte != '-' and byte != '.')
    {
        return error.InvalidFailureDiagnosticCode;
    };
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
    inline for (std.meta.fields(Failure)) |field| {
        const failure = @field(Failure, field.name);
        if (failure != .none) {
            try std.testing.expectEqual(failure, parse(&scratch, try encodeFailure(&bytes, failure)).failure);
        }
    }
}

test "provider failure diagnostics retain bounded status and code" {
    var bytes: [max_response_size]u8 = undefined;
    var scratch: ValidationScratch = undefined;
    const encoded = try encodeFailureDiagnostic(
        &bytes,
        .authentication_expired,
        .provider_http_403,
        403,
        "originator_not_allowed",
    );
    try std.testing.expectEqual(
        Failure.authentication_expired,
        parse(&scratch, encoded).failure,
    );
    const diagnostic = try inspectFailureDiagnostic(encoded);
    try std.testing.expectEqual(DiagnosticSource.provider_http_403, diagnostic.source);
    try std.testing.expectEqual(@as(?u16, 403), diagnostic.http_status);
    try std.testing.expectEqualStrings("originator_not_allowed", diagnostic.code);
    const legacy = try encodeFailureDiagnostic(
        &bytes,
        .authentication_expired,
        .provider_http_403,
        null,
        "originator_not_allowed",
    );
    try std.testing.expectEqual(@as(?u16, null), (try inspectFailureDiagnostic(legacy)).http_status);
    try std.testing.expectError(
        error.InvalidFailureDiagnosticCode,
        encodeFailureDiagnostic(
            &bytes,
            .authentication_expired,
            .provider_http_403,
            403,
            "unbounded provider message with spaces",
        ),
    );
}

test "captured admission consumes exact response identity once" {
    var first_buffer: [128]u8 = undefined;
    var second_buffer: [128]u8 = undefined;
    var scratch: ValidationScratch = undefined;
    const first = try encodeTool(&first_buffer, contract.bash_key, "{\"command\":\"true\",\"timeout_ms\":1000}");
    const second = try encodeTool(&second_buffer, contract.bash_key, "{\"command\":\"false\",\"timeout_ms\":1000}");
    var resolver: TestCatalogResolver = .{ .catalog = &contract.default_catalog };
    const expected = binding.hash(binding.Result, first);
    const admitted = try admitCaptured(&scratch, first, expected, resolver.capability());
    try std.testing.expectEqual(Disposition.tool_call, admitted.admission.parsed_value.disposition);
    try std.testing.expectEqual(@as(u8, 1), resolver.calls);
    try std.testing.expectError(
        error.InvalidModelResponseEvidence,
        admitCaptured(&scratch, second, expected, resolver.capability()),
    );
    first_buffer[first.len - 1] ^= 1;
    try std.testing.expectError(
        error.InvalidModelResponseEvidence,
        admitCaptured(&scratch, first, expected, resolver.capability()),
    );
    try std.testing.expectEqual(@as(u8, 1), resolver.calls);
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
    const malformed_result = admit(&scratch, malformed).admission.parsed_value;
    try std.testing.expectEqual(Disposition.failure, malformed_result.disposition);
    try std.testing.expectEqual(Failure.malformed, malformed_result.failure);

    var response: [max_response_size]u8 = undefined;
    const unknown = try encodeTool(&response, "fixture.unknown.v1", "{}");
    const unknown_proof = admit(&scratch, unknown);
    const unknown_result = unknown_proof.admission.parsed_value;
    try std.testing.expectEqual(Disposition.failure, unknown_result.disposition);
    try std.testing.expectEqual(Failure.unknown_tool, unknown_result.failure);
    try std.testing.expectError(error.InvalidModelResponseEvidence, unknown_proof.admission.verify(
        binding.hash(binding.Result, "substituted"),
    ));
}

test "host rejection preserves exact capture identity as a typed failure" {
    var response: [max_response_size]u8 = undefined;
    const capture = try encodeTool(
        &response,
        contract.bash_key,
        "{\"command\":\"true\",\"timeout_ms\":1000}",
    );
    var scratch: ValidationScratch = .{};
    var admitted = admit(&scratch, capture);
    try std.testing.expectEqual(Disposition.tool_call, admitted.admission.parsed_value.disposition);
    try admitted.rejectToolCall();
    const failure = admitted.admission.parsed_value;
    try std.testing.expectEqual(Disposition.failure, failure.disposition);
    try std.testing.expectEqual(Failure.malformed, failure.failure);
    try std.testing.expectError(error.InvalidModelResponseEvidence, admitted.admission.verify(
        binding.hash(binding.Result, "substituted"),
    ));
    try std.testing.expectError(error.ExpectedAdmittedToolCall, admitted.rejectToolCall());
}

test "compact admission survives validation scratch reuse" {
    var first_buffer: [max_response_size]u8 = undefined;
    var second_buffer: [max_response_size]u8 = undefined;
    const first = try encodeText(&first_buffer, "first");
    const second = try encodeText(&second_buffer, "second");
    var scratch: ValidationScratch = .{};
    const admission_value = admit(&scratch, first).admission;
    _ = admit(&scratch, second);

    try std.testing.expectEqual(
        Disposition.final_answer,
        (try admission_value.verify(binding.hash(binding.Result, first))).disposition,
    );
    try std.testing.expectError(
        error.InvalidModelResponseEvidence,
        admission_value.verify(binding.hash(binding.Result, second)),
    );
    try std.testing.expect(@sizeOf(Admission) < @sizeOf(ValidationScratch));
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
    const first_digest = first_admitted.arguments_digest;
    const second_admitted = try decode(&scratch, second_encoded);
    try std.testing.expect(!binding.eql(binding.StrictToolJsonV1, first_digest, second_admitted.arguments_digest));
    const malformed = try encodeTool(&first, contract.bash_key, "{\"command\":\"true\",\"command\":\"false\",\"timeout_ms\":1000}");
    try std.testing.expectError(error.MalformedModelResponse, decode(&scratch, malformed));
}
