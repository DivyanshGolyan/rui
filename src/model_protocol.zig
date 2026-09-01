const std = @import("std");
const binding = @import("binding.zig");
const contract = @import("model_contract.zig");

pub const header_size = 24;
pub const max_resident_response_size = 20 * 1024;
pub const max_assistant_text_size = max_resident_response_size - header_size;
pub const max_failure_diagnostic_code_size: usize = 64;
pub const tool_call_record_header_size: usize = 12;
/// One complete captured response has one aggregate byte budget. A Tool Call
/// batch shares this budget; the per-call bound does not multiply residency.
pub const max_response_size = header_size + tool_call_record_header_size +
    contract.max_tool_key_size + contract.max_tool_arguments_envelope_size;
pub const version: u16 = 4;
const magic = "ONERSP4\x00";

pub const Disposition = enum(u8) { final_answer = 1, tool_calls = 2, input_request = 3, failure = 4 };
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
    unsupported_provider_output = 15,
};

pub const DiagnosticSource = enum(u8) {
    none = 0,
    local_credentials = 1,
    provider = 2,
};

pub const FailureDiagnostic = struct {
    source: DiagnosticSource = .none,
    code: []const u8 = "",
};

pub const ToolCallSpan = struct {
    key_offset: u32 = 0,
    key_length: u32 = 0,
    arguments_offset: u32 = 0,
    arguments_length: u32 = 0,
    arguments_digest: binding.StrictToolJsonV1 = .{ .bytes = @splat(0) },
};

pub const Parsed = struct {
    disposition: Disposition,
    failure: Failure = .none,
    text_offset: u32 = 0,
    text_length: u32 = 0,
    tool_call_count: u8 = 0,
    tool_calls: [contract.max_tool_count]ToolCallSpan = @splat(.{}),
    // First-call projection retained for the narrow single-call consumers.
    tool_key_offset: u32 = 0,
    tool_key_length: u32 = 0,
    arguments_offset: u32 = 0,
    arguments_length: u32 = 0,
    arguments_digest: binding.StrictToolJsonV1 = .{ .bytes = @splat(0) },
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

    /// Replace a generically admitted tool call with the capture-bound terminal
    /// failure used when the Host's closed executable mapping rejects it.
    pub fn rejectToolCall(self: *CapturedAdmission) !void {
        if (self.admission.parsed_value.disposition != .tool_calls) {
            return error.ExpectedAdmittedToolCall;
        }
        self.admission.parsed_value = failed(.malformed);
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

pub fn writeText(writer: anytype, text: []const u8) !void {
    try validateText(text);
    try writeEnvelopeHeader(writer, .final_answer, .none, 0, 0, text.len, 0);
    try writer.append(text);
}

pub fn writeTool(writer: anytype, tool_key: []const u8, arguments: []const u8) !void {
    try validateTool(tool_key, arguments);
    const record_length = tool_call_record_header_size + tool_key.len + arguments.len;
    try writeEnvelopeHeader(writer, .tool_calls, .none, 0, 1, record_length, 0);
    var record: [tool_call_record_header_size]u8 = @splat(0);
    write(u32, &record, 0, @intCast(record_length));
    write(u16, &record, 4, @intCast(tool_key.len));
    write(u32, &record, 8, @intCast(arguments.len));
    try writer.append(&record);
    try writer.append(tool_key);
    try writer.append(arguments);
}

pub const ToolCall = struct { key: []const u8, arguments: []const u8 };

pub fn writeToolCalls(writer: anytype, calls: []const ToolCall) !void {
    if (calls.len == 0 or calls.len > contract.max_tool_count) return error.InvalidToolCallCount;
    var body_length: usize = 0;
    for (calls) |call| {
        try validateTool(call.key, call.arguments);
        body_length = std.math.add(usize, body_length,
            tool_call_record_header_size + call.key.len + call.arguments.len) catch
            return error.ResponseTooLarge;
    }
    try writeEnvelopeHeader(writer, .tool_calls, .none, 0, @intCast(calls.len), body_length, 0);
    for (calls) |call| {
        const record_length = tool_call_record_header_size + call.key.len + call.arguments.len;
        var record: [tool_call_record_header_size]u8 = @splat(0);
        write(u32, &record, 0, @intCast(record_length));
        write(u16, &record, 4, @intCast(call.key.len));
        write(u32, &record, 8, @intCast(call.arguments.len));
        try writer.append(&record);
        try writer.append(call.key);
        try writer.append(call.arguments);
    }
}

pub fn writeCapturedToolCalls(
    writer: anytype,
    call_count: u8,
    framed_body: []const u8,
) !void {
    if (call_count == 0 or call_count > contract.max_tool_count or
        framed_body.len == 0 or framed_body.len > max_response_size - header_size)
    {
        return error.InvalidToolCallBatch;
    }
    try writeEnvelopeHeader(writer, .tool_calls, .none, 0, call_count, framed_body.len, 0);
    try writer.append(framed_body);
}

pub fn writeInputText(writer: anytype, prompt: []const u8) !void {
    try validatePrompt(prompt);
    try writeEnvelopeHeader(
        writer,
        .input_request,
        .none,
        0,
        0,
        prompt.len,
        0,
    );
    try writer.append(prompt);
}

fn writeEnvelopeHeader(
    writer: anytype,
    disposition: Disposition,
    reason: Failure,
    shape: u8,
    option_count: u8,
    first_length: usize,
    second_length: usize,
) !void {
    var header: [header_size]u8 = undefined;
    try buildEnvelopeHeader(&header, disposition, reason, shape, option_count, first_length, second_length);
    try writer.append(&header);
}

pub fn encodeText(out: []u8, text: []const u8) ![]const u8 {
    try validateText(text);
    return encode(out, .final_answer, .none, 0, 0, text, "");
}

pub fn encodeTool(
    out: []u8,
    tool_key: []const u8,
    arguments: []const u8,
) ![]const u8 {
    const calls = [_]ToolCall{.{ .key = tool_key, .arguments = arguments }};
    return encodeToolCalls(out, &calls);
}

pub fn encodeToolCalls(out: []u8, calls: []const ToolCall) ![]const u8 {
    var writer = SliceWriter{ .out = out };
    try writeToolCalls(&writer, calls);
    return out[0..writer.length];
}

const SliceWriter = struct {
    out: []u8,
    length: usize = 0,

    fn append(self: *SliceWriter, bytes: []const u8) !void {
        if (bytes.len > self.out.len - self.length) return error.ResponseTooLarge;
        @memcpy(self.out[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }
};

pub fn encodeInputText(out: []u8, prompt: []const u8) ![]const u8 {
    try validatePrompt(prompt);
    return encode(out, .input_request, .none, 0, 0, prompt, "");
}

pub fn encodeFailure(out: []u8, reason: Failure) ![]const u8 {
    if (reason == .none) return error.InvalidProviderFailure;
    return encode(out, .failure, reason, 0, 0, "", "");
}

pub fn encodeFailureDiagnostic(
    out: []u8,
    reason: Failure,
    source: DiagnosticSource,
    code: []const u8,
) ![]const u8 {
    try validateFailureDiagnostic(reason, source, code);
    return encode(out, .failure, reason, @intFromEnum(source), 0, code, "");
}

pub fn inspectFailureDiagnostic(bytes: []const u8) !FailureDiagnostic {
    const inspected = try inspect(bytes);
    if (inspected.disposition != .failure) return error.ExpectedFailureResponse;
    const source = std.enums.fromInt(DiagnosticSource, inspected.shape) orelse
        return error.MalformedModelResponse;
    if (inspected.second.len != 0) return error.MalformedModelResponse;
    try validateFailureDiagnostic(inspected.reason, source, inspected.first);
    return .{ .source = source, .code = inspected.first };
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
    try buildEnvelopeHeader(out[0..header_size], disposition, reason, shape, option_count, first.len, second.len);
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

/// Settlement-time framing check for an append-only candidate. Full semantic
/// validation remains the later relational command admission step.
pub fn validateCandidateEnvelopePrefix(prefix: []const u8, total_length: u32) !void {
    if (prefix.len != header_size or total_length < header_size or
        total_length > max_response_size or
        !std.mem.eql(u8, prefix[0..magic.len], magic) or
        read(u16, prefix, 8) != version or read(u16, prefix, 10) != header_size)
    {
        return error.InvalidProviderCandidate;
    }
    const disposition = std.enums.fromInt(Disposition, prefix[12]) orelse
        return error.InvalidProviderCandidate;
    if (disposition == .failure) return error.ProviderFailureAsCandidate;
    const first_length: u32 = read(u32, prefix, 16);
    const second_length: u32 = read(u32, prefix, 20);
    if (@as(u64, header_size) + first_length + second_length != total_length) {
        return error.InvalidProviderCandidate;
    }
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
    var context: CatalogResolverContext = .{ .catalog = catalog };
    return finishWithResolver(scratch, inspected, .{
        .context = &context,
        .resolve_fn = CatalogResolverContext.resolve,
    });
}

const CatalogResolverContext = struct {
    catalog: []const contract.ToolDefinition,

    fn resolve(context: *anyopaque, key: []const u8) anyerror!?contract.ToolDefinition {
        const self: *CatalogResolverContext = @ptrCast(@alignCast(context));
        return contract.definitionForKey(self.catalog, key);
    }
};

fn finishWithResolver(
    scratch: *contract.StrictToolJsonScratch,
    inspected: Inspected,
    resolver: DefinitionResolver,
) !Decoded {
    if (inspected.disposition == .tool_calls) {
        return .{ .parsed = try decodeToolCalls(scratch, inspected, resolver) };
    }
    return finish(inspected);
}

fn finish(inspected: Inspected) !Decoded {
    const first = inspected.first;
    const second = inspected.second;
    switch (inspected.disposition) {
        .final_answer => {
            if (inspected.reason != .none or inspected.shape != 0 or inspected.option_count != 0 or first.len == 0 or
                first.len > max_assistant_text_size or
                second.len != 0 or !contract.utf8Valid(first)) return error.MalformedModelResponse;
            return .{ .parsed = .{ .disposition = .final_answer, .text_offset = header_size, .text_length = @intCast(first.len) } };
        },
        .tool_calls => unreachable,
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
            if (second.len != 0) return error.MalformedModelResponse;
            validateFailureDiagnostic(inspected.reason, source, first) catch
                return error.MalformedModelResponse;
            if (inspected.option_count != 0) {
                return error.MalformedModelResponse;
            }
            return .{ .parsed = failed(inspected.reason) };
        },
    }
}

fn decodeToolCalls(
    scratch: *contract.StrictToolJsonScratch,
    inspected: Inspected,
    resolver: DefinitionResolver,
) !Parsed {
    if (inspected.reason != .none or inspected.shape != 0 or
        inspected.option_count == 0 or inspected.option_count > contract.max_tool_count or
        inspected.first.len == 0 or inspected.second.len != 0)
    {
        return error.MalformedModelResponse;
    }
    var parsed: Parsed = .{
        .disposition = .tool_calls,
        .tool_call_count = inspected.option_count,
    };
    var cursor: usize = 0;
    for (0..inspected.option_count) |index| {
        if (inspected.first.len - cursor < tool_call_record_header_size) {
            return error.MalformedModelResponse;
        }
        const record = inspected.first[cursor..][0..tool_call_record_header_size];
        const record_length: usize = read(u32, record, 0);
        const key_length: usize = read(u16, record, 4);
        const arguments_length: usize = read(u32, record, 8);
        if (read(u16, record, 6) != 0 or
            record_length != tool_call_record_header_size + key_length + arguments_length or
            record_length > inspected.first.len - cursor)
        {
            return error.MalformedModelResponse;
        }
        const key_offset = header_size + cursor + tool_call_record_header_size;
        const arguments_offset = key_offset + key_length;
        const key = inspected.first[cursor + tool_call_record_header_size ..][0..key_length];
        const arguments = inspected.first[cursor + tool_call_record_header_size + key_length ..][0..arguments_length];
        contract.validateToolKey(key) catch return error.MalformedModelResponse;
        const selected = try resolver.resolve(key) orelse return error.UnknownModelTool;
        if (!std.mem.eql(u8, selected.key, key)) return error.UnknownModelTool;
        const admitted = contract.admitToolArguments(scratch, selected, arguments) catch
            return error.MalformedModelResponse;
        parsed.tool_calls[index] = .{
            .key_offset = @intCast(key_offset),
            .key_length = @intCast(key_length),
            .arguments_offset = @intCast(arguments_offset),
            .arguments_length = @intCast(arguments_length),
            .arguments_digest = admitted.json.evidence(),
        };
        cursor += record_length;
    }
    if (cursor != inspected.first.len) return error.MalformedModelResponse;
    const first_call = parsed.tool_calls[0];
    parsed.tool_key_offset = first_call.key_offset;
    parsed.tool_key_length = first_call.key_length;
    parsed.arguments_offset = first_call.arguments_offset;
    parsed.arguments_length = first_call.arguments_length;
    parsed.arguments_digest = first_call.arguments_digest;
    return parsed;
}

pub fn admitToolCallArguments(
    scratch: *ValidationScratch,
    bytes: []const u8,
    parsed: Parsed,
    index: usize,
) !contract.AdmittedToolArguments {
    if (parsed.disposition != .tool_calls or index >= parsed.tool_call_count) {
        return error.InvalidToolCallIndex;
    }
    const span = parsed.tool_calls[index];
    const key = bytes[span.key_offset..][0..span.key_length];
    const arguments = bytes[span.arguments_offset..][0..span.arguments_length];
    const definition = contract.definitionForKey(&contract.default_catalog, key) orelse
        return error.UnknownModelTool;
    return contract.admitToolArguments(&scratch.json, definition, arguments);
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
    if (shape_byte != 0 or count != 0 or options.len != 0) return error.MalformedModelResponse;
    return .{
        .disposition = .input_request,
        .text_offset = header_size,
        .text_length = @intCast(prompt.len),
    };
}

fn validatePrompt(prompt: []const u8) !void {
    if (prompt.len == 0 or prompt.len > contract.max_prompt_size or !contract.utf8Valid(prompt)) {
        return error.InvalidInputPrompt;
    }
}

fn validateText(text: []const u8) !void {
    if (text.len == 0 or text.len > max_assistant_text_size or !contract.utf8Valid(text)) {
        return error.InvalidAssistantText;
    }
}

fn validateTool(tool_key: []const u8, arguments: []const u8) !void {
    try contract.validateToolKey(tool_key);
    if (arguments.len == 0 or arguments.len > contract.max_tool_arguments_envelope_size) {
        return error.InvalidToolArguments;
    }
}

fn buildEnvelopeHeader(
    out: []u8,
    disposition: Disposition,
    reason: Failure,
    shape: u8,
    option_count: u8,
    first_length: usize,
    second_length: usize,
) !void {
    if (out.len < header_size or header_size + first_length + second_length > max_response_size) {
        return error.ResponseTooLarge;
    }
    @memset(out[0..header_size], 0);
    @memcpy(out[0..magic.len], magic);
    write(u16, out, 8, version);
    write(u16, out, 10, header_size);
    out[12] = @intFromEnum(disposition);
    out[13] = @intFromEnum(reason);
    out[14] = shape;
    out[15] = option_count;
    write(u32, out, 16, @intCast(first_length));
    write(u32, out, 20, @intCast(second_length));
}

fn validateFailureDiagnostic(
    reason: Failure,
    source: DiagnosticSource,
    code: []const u8,
) !void {
    if (reason == .none) return error.InvalidProviderFailure;
    if (source == .none) {
        if (code.len != 0) return error.InvalidFailureDiagnosticCode;
        return;
    }
    switch (source) {
        .local_credentials => {
            if (reason != .authentication_expired) return error.InvalidFailureDiagnosticSource;
            try validateFailureDiagnosticCode(code);
        },
        .provider => {
            if (reason != .authentication_expired and reason != .provider_error and
                reason != .model_unavailable)
            {
                return error.InvalidFailureDiagnosticSource;
            }
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
    try std.testing.expectEqual(Disposition.tool_calls, tool.disposition);
    try std.testing.expectEqual(@as(u8, 1), tool.tool_call_count);
    try std.testing.expectEqualStrings(contract.bash_key, bytes[tool.tool_key_offset..][0..tool.tool_key_length]);
    const text_input = parse(&scratch, try encodeInputText(&bytes, "Which migration should I use?"));
    try std.testing.expectEqual(Disposition.input_request, text_input.disposition);
    inline for (std.meta.fields(Failure)) |field| {
        const failure = @field(Failure, field.name);
        if (failure != .none) {
            try std.testing.expectEqual(failure, parse(&scratch, try encodeFailure(&bytes, failure)).failure);
        }
    }
}

test "writer encoders are byte-identical to complete-buffer encoders" {
    const BufferWriter = struct {
        bytes: *[max_response_size]u8,
        length: usize = 0,

        fn append(self: *@This(), chunk: []const u8) !void {
            if (chunk.len > self.bytes.len - self.length) return error.NoSpaceLeft;
            @memcpy(self.bytes[self.length..][0..chunk.len], chunk);
            self.length += chunk.len;
        }
    };
    const Case = enum { text, tool, input_text };
    inline for (std.meta.fields(Case)) |field| {
        const case: Case = @enumFromInt(field.value);
        var expected_buffer: [max_response_size]u8 = undefined;
        const expected = switch (case) {
            .text => try encodeText(&expected_buffer, "done"),
            .tool => try encodeTool(&expected_buffer, contract.bash_key, "{\"command\":\"true\",\"timeout_ms\":1000}"),
            .input_text => try encodeInputText(&expected_buffer, "What next?"),
        };
        var actual_buffer: [max_response_size]u8 = undefined;
        var writer: BufferWriter = .{ .bytes = &actual_buffer };
        switch (case) {
            .text => try writeText(&writer, "done"),
            .tool => try writeTool(&writer, contract.bash_key, "{\"command\":\"true\",\"timeout_ms\":1000}"),
            .input_text => try writeInputText(&writer, "What next?"),
        }
        try std.testing.expectEqualSlices(u8, expected, actual_buffer[0..writer.length]);
    }
}

test "provider-neutral failure diagnostics retain bounded source and code" {
    var bytes: [max_response_size]u8 = undefined;
    var scratch: ValidationScratch = undefined;
    const encoded = try encodeFailureDiagnostic(
        &bytes,
        .authentication_expired,
        .provider,
        "originator_not_allowed",
    );
    try std.testing.expectEqual(
        Failure.authentication_expired,
        parse(&scratch, encoded).failure,
    );
    const diagnostic = try inspectFailureDiagnostic(encoded);
    try std.testing.expectEqual(DiagnosticSource.provider, diagnostic.source);
    try std.testing.expectEqualStrings("originator_not_allowed", diagnostic.code);
    const local = try encodeFailureDiagnostic(
        &bytes,
        .authentication_expired,
        .local_credentials,
        "adapter.local.code",
    );
    const local_diagnostic = try inspectFailureDiagnostic(local);
    try std.testing.expectEqual(DiagnosticSource.local_credentials, local_diagnostic.source);
    try std.testing.expectEqualStrings("adapter.local.code", local_diagnostic.code);
    try std.testing.expectError(
        error.InvalidFailureDiagnosticCode,
        encodeFailureDiagnostic(
            &bytes,
            .authentication_expired,
            .provider,
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
    try std.testing.expectEqual(Disposition.tool_calls, admitted.admission.parsed_value.disposition);
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
    try std.testing.expectEqual(Disposition.tool_calls, admitted.admission.parsed_value.disposition);
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
