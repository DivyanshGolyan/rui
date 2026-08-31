const std = @import("std");
const binding = @import("binding.zig");
const conversation = @import("conversation.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

pub const request_header_size = 92;
pub const tool_header_size = 20;
pub const entry_header_size = 32;
pub const request_window_size = 4096;
pub const version: u16 = 3;

const request_magic = "ONEREQ3\x00";

pub fn verifyRequestDigest(
    session: *session_store.Session,
    request_ref: u64,
    expected: binding.ModelDescriptor,
) !void {
    var request = try session.viewContent(request_ref);
    var hasher = binding.Hasher(binding.ModelDescriptor).init();
    var window: [request_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < request.length()) {
        const bytes = try request.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedModelRequest;
        hasher.update(bytes);
        offset += bytes.len;
    }
    if (!binding.eql(binding.ModelDescriptor, hasher.final(), expected)) {
        return error.ModelRequestDigestMismatch;
    }
}

pub const Provider = struct {
    context: *anyopaque,
    dispatch: *const fn (
        *anyopaque,
        RequestCursor,
        CandidateWriter,
    ) anyerror!DispatchOutcome,
};

pub const FailureCapture = struct {
    failure: model_protocol.Failure,
    diagnostic_source: model_protocol.DiagnosticSource = .none,
    diagnostic_code_bytes: [model_protocol.max_failure_diagnostic_code_size]u8 = @splat(0),
    diagnostic_code_length: u8 = 0,

    pub fn diagnosticCode(self: *const FailureCapture) []const u8 {
        return self.diagnostic_code_bytes[0..self.diagnostic_code_length];
    }
};

pub const DispatchOutcome = union(enum) {
    candidate,
    failure: FailureCapture,
};

const RequestSource = struct {
    context: *anyopaque,
    length_fn: *const fn (*anyopaque) u64,
    read_fn: *const fn (*anyopaque, u64, []u8) anyerror![]const u8,

    fn length(self: RequestSource) u64 {
        return self.length_fn(self.context);
    }

    fn readWindow(self: RequestSource, offset: u64, out: []u8) ![]const u8 {
        return self.read_fn(self.context, offset, out);
    }
};

pub const EntryKind = enum { user_text, assistant_text, tool_call, tool_result, context_checkpoint };

pub const ContentView = struct {
    source: RequestSource,
    start: u64,
    length_value: u64,

    pub fn length(self: ContentView) u64 {
        return self.length_value;
    }

    /// Fills one caller-owned window, stitching short reads from the immutable
    /// request blob without exposing its offsets or framing.
    pub fn readWindow(self: ContentView, offset: u64, out: []u8) ![]const u8 {
        if (offset > self.length_value) return error.InvalidRequestContentOffset;
        const wanted: usize = @intCast(@min(self.length_value - offset, out.len));
        var filled: usize = 0;
        while (filled < wanted) {
            const bytes = try self.source.readWindow(
                self.start + offset + filled,
                out[filled..wanted],
            );
            if (bytes.len == 0 or bytes.len > wanted - filled) return error.TruncatedModelRequest;
            if (bytes.ptr != out[filled..].ptr) @memcpy(out[filled..][0..bytes.len], bytes);
            filled += bytes.len;
        }
        return out[0..filled];
    }
};

pub const ToolDefinitionBuffer = struct {
    key_bytes: [model_contract.max_tool_key_size]u8 = undefined,
    provider_name_bytes: [model_contract.max_provider_tool_name_size]u8 = undefined,
    description_bytes: [model_contract.max_description_size]u8 = undefined,
    schema_bytes: [model_contract.max_schema_size]u8 = undefined,
    result_contract_bytes: [model_contract.max_result_contract_size]u8 = undefined,
    lengths: [5]u32 = @splat(0),

    pub fn definition(self: *const ToolDefinitionBuffer) model_contract.ToolDefinition {
        return .{
            .key = self.key_bytes[0..self.lengths[0]],
            .provider_tool_name = self.provider_name_bytes[0..self.lengths[1]],
            .description = self.description_bytes[0..self.lengths[2]],
            .input_schema = self.schema_bytes[0..self.lengths[3]],
            .result_contract = self.result_contract_bytes[0..self.lengths[4]],
        };
    }

    fn copyFrom(self: *ToolDefinitionBuffer, source_definition: model_contract.ToolDefinition) void {
        const fields = .{
            &self.key_bytes,
            &self.provider_name_bytes,
            &self.description_bytes,
            &self.schema_bytes,
            &self.result_contract_bytes,
        };
        const source = .{
            source_definition.key,
            source_definition.provider_tool_name,
            source_definition.description,
            source_definition.input_schema,
            source_definition.result_contract,
        };
        inline for (fields, source, 0..) |target, bytes, index| {
            @memcpy(target[0..bytes.len], bytes);
            self.lengths[index] = @intCast(bytes.len);
        }
    }
};

pub const ToolCatalogCursor = struct {
    source: RequestSource,
    cursor: u64,
    remaining: u16,

    pub fn count(self: *const ToolCatalogCursor) u16 {
        return self.remaining;
    }

    pub fn next(
        self: *ToolCatalogCursor,
        buffer: *ToolDefinitionBuffer,
    ) !?model_contract.ToolDefinition {
        if (self.remaining == 0) return null;
        const definition = try decodeToolDefinition(self.source, &self.cursor, buffer);
        self.remaining -= 1;
        return definition;
    }
};

pub const TextEntry = struct {
    entry_id: u64,
    parent_id: u64,
    content: ContentView,
};

pub const ToolCallEntry = struct {
    entry_id: u64,
    parent_id: u64,
    key_bytes: [model_contract.max_tool_key_size]u8,
    key_length: u8,
    arguments: ContentView,

    pub fn key(self: *const ToolCallEntry) []const u8 {
        return self.key_bytes[0..self.key_length];
    }
};

pub const ToolResultEntry = struct {
    entry_id: u64,
    call_entry_id: u64,
    is_error: bool,
    content: ContentView,
};

pub const RequestEntry = union(EntryKind) {
    user_text: TextEntry,
    assistant_text: TextEntry,
    tool_call: ToolCallEntry,
    tool_result: ToolResultEntry,
    context_checkpoint: TextEntry,
};

/// One validated, streaming view of the provider-neutral semantic request.
/// Providers never receive the durable request wire or Conversation envelope.
pub const RequestCursor = struct {
    source: RequestSource,
    model_name: [session_store.model_name_capacity]u8 = undefined,
    model_name_length: u16,
    catalog_start: u64,
    tool_count: u16,
    cursor: u64,
    total_entries: u32,
    remaining_entries: u32,
    previous_entry_id: u64 = 0,
    previous_kind: ?EntryKind = null,

    pub fn modelName(self: *const RequestCursor) []const u8 {
        return self.model_name[0..self.model_name_length];
    }

    pub fn instructions(_: *const RequestCursor) []const u8 {
        return model_contract.default_instructions;
    }

    pub fn modelContract(_: *const RequestCursor) []const u8 {
        return model_contract.model_contract_bytes;
    }

    pub fn toolCatalog(self: *const RequestCursor) ToolCatalogCursor {
        return .{
            .source = self.source,
            .cursor = self.catalog_start,
            .remaining = self.tool_count,
        };
    }

    pub fn entryCount(self: *const RequestCursor) u32 {
        return self.total_entries;
    }

    pub fn next(self: *RequestCursor) !?RequestEntry {
        if (self.remaining_entries == 0) {
            if (self.previous_kind == .tool_call) return error.ContextSplitsToolPair;
            if (self.cursor != self.source.length()) return error.MalformedModelRequest;
            return null;
        }
        var header: [entry_header_size]u8 = undefined;
        if (self.cursor > self.source.length() or
            self.source.length() - self.cursor < entry_header_size)
        {
            return error.TruncatedModelRequest;
        }
        try readExact(self.source, self.cursor, &header);
        if (!allZero(header[1..8])) return error.MalformedModelRequest;
        const kind: EntryKind = switch (header[0]) {
            1 => .user_text,
            2 => .assistant_text,
            3 => .tool_call,
            4 => .tool_result,
            5 => .context_checkpoint,
            else => return error.MalformedModelRequest,
        };
        const entry_id = read(u64, &header, 8);
        const parent_id = read(u64, &header, 16);
        const encoded_length = read(u64, &header, 24);
        if (entry_id == 0 or parent_id == std.math.maxInt(u64) or parent_id + 1 != entry_id or
            encoded_length == 0 or
            encoded_length > self.source.length() - self.cursor - entry_header_size)
        {
            return error.MalformedModelRequest;
        }
        if (self.previous_entry_id != 0 and
            (self.previous_entry_id == std.math.maxInt(u64) or
                entry_id != self.previous_entry_id + 1 or parent_id != self.previous_entry_id))
        {
            return error.MalformedModelRequest;
        }
        if (self.previous_entry_id == 0 and kind == .tool_result) return error.ContextSplitsToolPair;
        if (self.previous_kind == .tool_call and kind != .tool_result) return error.InvalidToolAdjacency;
        if (kind == .tool_result and self.previous_kind != .tool_call) return error.InvalidToolAdjacency;

        const encoded_start = self.cursor + entry_header_size;
        const encoded = ContentView{
            .source = self.source,
            .start = encoded_start,
            .length_value = encoded_length,
        };
        const entry = switch (kind) {
            .user_text, .assistant_text, .context_checkpoint => blk: {
                if (encoded_length > conversation.max_result_content_size) return error.ModelRequestContentTooLarge;
                try validateUtf8(encoded);
                const text: TextEntry = .{ .entry_id = entry_id, .parent_id = parent_id, .content = encoded };
                break :blk switch (kind) {
                    .user_text => RequestEntry{ .user_text = text },
                    .assistant_text => RequestEntry{ .assistant_text = text },
                    .context_checkpoint => RequestEntry{ .context_checkpoint = text },
                    else => unreachable,
                };
            },
            .tool_call => try decodeRequestToolCall(encoded, entry_id, parent_id),
            .tool_result => try decodeRequestToolResult(encoded, entry_id, parent_id),
        };
        self.cursor = encoded_start + encoded_length;
        self.remaining_entries -= 1;
        self.previous_entry_id = entry_id;
        self.previous_kind = kind;
        if (self.remaining_entries == 0 and self.cursor != self.source.length()) {
            return error.MalformedModelRequest;
        }
        return entry;
    }
};

fn openRequest(source: RequestSource, selection: ?*CatalogSelection) !RequestCursor {
    if (source.length() < request_header_size) return error.TruncatedModelRequest;
    var header: [request_header_size]u8 = undefined;
    try readExact(source, 0, &header);
    if (!std.mem.eql(u8, header[0..request_magic.len], request_magic) or
        read(u16, &header, 8) != version or read(u16, &header, 10) != request_header_size)
    {
        return error.UnsupportedModelRequest;
    }
    const entry_count = read(u32, &header, 12);
    const tool_count = read(u16, &header, 16);
    const model_length = read(u16, &header, 18);
    const instructions_length = read(u32, &header, 20);
    const contract_length = read(u32, &header, 24);
    if (entry_count == 0 or entry_count > session_transition.max_transitions or
        tool_count == 0 or tool_count > model_contract.max_tool_count or
        model_length == 0 or model_length > session_store.model_name_capacity or
        instructions_length != model_contract.default_instructions.len or
        contract_length != model_contract.model_contract_bytes.len)
    {
        return error.MalformedModelRequest;
    }
    const contract_digest = binding.hash(binding.ModelContract, model_contract.model_contract_bytes);
    if (!std.mem.eql(u8, header[60..92], &contract_digest.bytes)) {
        return error.MalformedModelRequest;
    }

    var request: RequestCursor = .{
        .source = source,
        .model_name_length = model_length,
        .catalog_start = 0,
        .tool_count = tool_count,
        .cursor = request_header_size,
        .total_entries = entry_count,
        .remaining_entries = entry_count,
    };
    try readExact(source, request.cursor, request.model_name[0..model_length]);
    if (!model_contract.utf8Valid(request.modelName())) return error.MalformedModelRequest;
    request.cursor += model_length;
    try expectBytes(source, request.cursor, model_contract.default_instructions);
    request.cursor += instructions_length;
    try expectBytes(source, request.cursor, model_contract.model_contract_bytes);
    request.cursor += contract_length;

    request.catalog_start = request.cursor;
    const expected_catalog_digest: binding.ToolCatalog = .{ .bytes = header[28..60].* };
    request.cursor = try validateCatalogEncoding(
        source,
        request.cursor,
        tool_count,
        expected_catalog_digest,
        selection,
    );
    if (request.cursor >= source.length()) return error.TruncatedModelRequest;
    return request;
}

const CatalogSelection = struct {
    key: []const u8,
    definition: *ToolDefinitionBuffer,
    found: bool = false,
};

fn validateCatalogEncoding(
    source: RequestSource,
    start: u64,
    tool_count: u16,
    expected_digest: binding.ToolCatalog,
    selection: ?*CatalogSelection,
) !u64 {
    if (selection) |selected| selected.found = false;
    var cursor = start;
    var definition_buffer: ToolDefinitionBuffer = .{};
    var keys: [model_contract.max_tool_count][model_contract.max_tool_key_size]u8 = undefined;
    var key_lengths: [model_contract.max_tool_count]u8 = @splat(0);
    var names: [model_contract.max_tool_count][model_contract.max_provider_tool_name_size]u8 = undefined;
    var name_lengths: [model_contract.max_tool_count]u8 = @splat(0);
    var digest = model_contract.CatalogDigestBuilder.init(tool_count);
    for (0..tool_count) |index| {
        const definition = try decodeToolDefinition(source, &cursor, &definition_buffer);
        model_contract.validateCatalog(&.{definition}) catch return error.MalformedModelRequest;
        for (0..index) |earlier| {
            if (std.mem.eql(u8, keys[earlier][0..key_lengths[earlier]], definition.key)) {
                return error.MalformedModelRequest;
            }
            if (std.mem.eql(u8, names[earlier][0..name_lengths[earlier]], definition.provider_tool_name)) {
                return error.MalformedModelRequest;
            }
        }
        @memcpy(keys[index][0..definition.key.len], definition.key);
        key_lengths[index] = @intCast(definition.key.len);
        @memcpy(names[index][0..definition.provider_tool_name.len], definition.provider_tool_name);
        name_lengths[index] = @intCast(definition.provider_tool_name.len);
        digest.add(definition);
        if (selection) |selected| {
            if (std.mem.eql(u8, selected.key, definition.key)) {
                selected.definition.copyFrom(definition);
                selected.found = true;
            }
        }
    }
    if (!binding.eql(binding.ToolCatalog, digest.final(), expected_digest)) {
        return error.MalformedModelRequest;
    }
    return cursor;
}

fn decodeToolDefinition(
    source: RequestSource,
    cursor: *u64,
    buffer: *ToolDefinitionBuffer,
) !model_contract.ToolDefinition {
    var header: [tool_header_size]u8 = undefined;
    try readExact(source, cursor.*, &header);
    if (!allZero(header[16..20])) return error.MalformedModelRequest;
    const lengths = [_]usize{
        read(u16, &header, 0),
        read(u16, &header, 2),
        read(u32, &header, 4),
        read(u32, &header, 8),
        read(u32, &header, 12),
    };
    const capacities = [_]usize{
        buffer.key_bytes.len,
        buffer.provider_name_bytes.len,
        buffer.description_bytes.len,
        buffer.schema_bytes.len,
        buffer.result_contract_bytes.len,
    };
    for (lengths, capacities) |length, capacity| {
        if (length == 0 or length > capacity) return error.MalformedModelRequest;
    }
    cursor.* += tool_header_size;
    const fields = .{
        buffer.key_bytes[0..lengths[0]],
        buffer.provider_name_bytes[0..lengths[1]],
        buffer.description_bytes[0..lengths[2]],
        buffer.schema_bytes[0..lengths[3]],
        buffer.result_contract_bytes[0..lengths[4]],
    };
    inline for (fields, 0..) |field, index| {
        try readExact(source, cursor.*, field);
        cursor.* += lengths[index];
        buffer.lengths[index] = @intCast(lengths[index]);
    }
    return buffer.definition();
}

fn decodeRequestToolCall(
    encoded: ContentView,
    entry_id: u64,
    parent_id: u64,
) !RequestEntry {
    var header_bytes: [conversation.call_header_size]u8 = undefined;
    try readContentExact(encoded, 0, &header_bytes);
    const header = conversation.decodeToolCallHeader(&header_bytes, encoded.length()) catch
        return error.MalformedModelRequest;
    var call: ToolCallEntry = .{
        .entry_id = entry_id,
        .parent_id = parent_id,
        .key_bytes = undefined,
        .key_length = @intCast(header.key_length),
        .arguments = .{
            .source = encoded.source,
            .start = encoded.start + conversation.call_header_size + header.key_length,
            .length_value = header.arguments_length,
        },
    };
    try readContentExact(encoded, conversation.call_header_size, call.key_bytes[0..header.key_length]);
    model_contract.validateToolKey(call.key()) catch return error.MalformedModelRequest;
    try validateStrictToolJsonIdentity(call.arguments, header.arguments_digest);
    return .{ .tool_call = call };
}

fn validateStrictToolJsonIdentity(
    content: ContentView,
    digest: binding.StrictToolJsonV1,
) !void {
    if (content.length() == 0 or content.length() > model_contract.max_tool_arguments_envelope_size) {
        return error.MalformedModelRequest;
    }
    var hasher = binding.Hasher(binding.StrictToolJsonV1).init();
    var window: [request_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < content.length()) {
        const bytes = try content.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedModelRequest;
        hasher.update(bytes);
        offset += bytes.len;
    }
    if (!binding.eql(
        binding.StrictToolJsonV1,
        hasher.final(),
        digest,
    )) return error.MalformedModelRequest;
}

fn decodeRequestToolResult(
    encoded: ContentView,
    entry_id: u64,
    parent_id: u64,
) !RequestEntry {
    var header_bytes: [conversation.result_header_size]u8 = undefined;
    try readContentExact(encoded, 0, &header_bytes);
    const header = conversation.decodeToolResultHeader(&header_bytes, encoded.length()) catch
        return error.MalformedModelRequest;
    if (header.parent_id != parent_id) return error.InvalidToolAdjacency;
    const content: ContentView = .{
        .source = encoded.source,
        .start = encoded.start + conversation.result_header_size,
        .length_value = header.content_length,
    };
    try validateUtf8(content);
    return .{ .tool_result = .{
        .entry_id = entry_id,
        .call_entry_id = parent_id,
        .is_error = header.is_error,
        .content = content,
    } };
}

fn validateUtf8(content: ContentView) !void {
    var bytes: [request_window_size + 3]u8 = undefined;
    var carry: usize = 0;
    var offset: u64 = 0;
    while (offset < content.length()) {
        const read_bytes = try content.readWindow(offset, bytes[carry..]);
        if (read_bytes.len == 0) return error.TruncatedModelRequest;
        offset += read_bytes.len;
        const total = carry + read_bytes.len;
        if (offset == content.length()) {
            if (!model_contract.utf8Valid(bytes[0..total])) return error.MalformedModelRequest;
            return;
        }
        var suffix: usize = 0;
        while (suffix <= @min(@as(usize, 3), total) and
            !model_contract.utf8Valid(bytes[0 .. total - suffix])) : (suffix += 1)
        {}
        if (suffix > @min(@as(usize, 3), total)) return error.MalformedModelRequest;
        if (suffix != 0) @memcpy(bytes[0..suffix], bytes[total - suffix .. total]);
        carry = suffix;
    }
    return error.TruncatedModelRequest;
}

fn readContentExact(content: ContentView, offset: u64, out: []u8) !void {
    if ((try content.readWindow(offset, out)).len != out.len) return error.TruncatedModelRequest;
}

fn readExact(source: RequestSource, offset: u64, out: []u8) !void {
    const view: ContentView = .{ .source = source, .start = 0, .length_value = source.length() };
    try readContentExact(view, offset, out);
}

fn expectBytes(source: RequestSource, offset: u64, expected: []const u8) !void {
    var window: [request_window_size]u8 = undefined;
    var consumed: usize = 0;
    while (consumed < expected.len) {
        const count = @min(window.len, expected.len - consumed);
        try readExact(source, offset + consumed, window[0..count]);
        if (!std.mem.eql(u8, window[0..count], expected[consumed..][0..count])) {
            return error.MalformedModelRequest;
        }
        consumed += count;
    }
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

pub const CandidateWriter = struct {
    context: *anyopaque,
    append_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn append(self: CandidateWriter, bytes: []const u8) !void {
        try self.append_fn(self.context, bytes);
    }
};

/// Owns the host-side resources behind the deliberately narrow provider
/// capabilities. Providers can read one immutable request and append one
/// predetermined response; they receive no Session or owner authority.
pub const ProviderIo = struct {
    request_blob: session_store.ContentView,
    response: session_store.ContentWriter,
    session: *session_store.Session,
    response_ref: u64,
    response_length: u32 = 0,
    response_prefix: [model_protocol.header_size]u8 = @splat(0),
    response_prefix_length: u8 = 0,

    pub fn open(
        session: *session_store.Session,
        request_ref: u64,
        response_ref: u64,
    ) !ProviderIo {
        const request_blob = try session.viewContent(request_ref);
        const response = try session.beginContent(response_ref);
        return .{
            .request_blob = request_blob,
            .response = response,
            .session = session,
            .response_ref = response_ref,
        };
    }

    pub fn close(self: *ProviderIo) void {
        self.response.abort();
    }

    pub fn request(self: *ProviderIo) !RequestCursor {
        return openRequest(.{
            .context = self,
            .length_fn = requestLength,
            .read_fn = requestRead,
        }, null);
    }

    pub fn candidateCapability(self: *ProviderIo) CandidateWriter {
        return .{ .context = self, .append_fn = responseAppend };
    }

    /// The synchronous provider return is the only settlement point. Providers
    /// can append candidate bytes, but cannot seal or replace Host-owned
    /// captured evidence.
    pub fn settle(self: *ProviderIo, outcome: DispatchOutcome) !void {
        switch (outcome) {
            .candidate => {
                if (self.response_length == 0) return error.EmptyProviderCandidate;
                try model_protocol.validateCandidateEnvelopePrefix(
                    self.response_prefix[0..self.response_prefix_length],
                    self.response_length,
                );
                try self.response.finish();
            },
            .failure => |failure| {
                self.response.abort();
                self.response = try self.session.beginContent(self.response_ref);
                var bytes: [
                    model_protocol.header_size + model_protocol.max_failure_diagnostic_code_size
                ]u8 = undefined;
                const diagnostic_code = failure.diagnosticCode();
                const encoded = if (failure.diagnostic_source == .none and
                    diagnostic_code.len == 0)
                    try model_protocol.encodeFailure(&bytes, failure.failure)
                else
                    try model_protocol.encodeFailureDiagnostic(
                        &bytes,
                        failure.failure,
                        failure.diagnostic_source,
                        diagnostic_code,
                    );
                try self.response.append(encoded);
                try self.response.finish();
            },
        }
    }

    fn requestLength(context: *anyopaque) u64 {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        return self.request_blob.length();
    }

    fn requestRead(context: *anyopaque, offset: u64, out: []u8) anyerror![]const u8 {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        return self.request_blob.readWindow(offset, out);
    }

    fn responseAppend(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        const next_length = try capturedResponseLength(self.response_length, bytes.len);
        try self.response.append(bytes);
        const remaining_prefix = model_protocol.header_size - self.response_prefix_length;
        const copy_length = @min(remaining_prefix, bytes.len);
        if (copy_length != 0) {
            @memcpy(
                self.response_prefix[self.response_prefix_length..][0..copy_length],
                bytes[0..copy_length],
            );
            self.response_prefix_length += @intCast(copy_length);
        }
        self.response_length = next_length;
    }
};

const CatalogContentSource = struct {
    reader: *session_store.ContentView,

    fn length(context: *anyopaque) u64 {
        const self: *CatalogContentSource = @ptrCast(@alignCast(context));
        return self.reader.length();
    }

    fn read(context: *anyopaque, offset: u64, out: []u8) anyerror![]const u8 {
        const self: *CatalogContentSource = @ptrCast(@alignCast(context));
        return self.reader.readWindow(offset, out);
    }
};

pub fn readToolDefinition(
    session: *session_store.Session,
    request_ref: u64,
    key: []const u8,
    buffer: *ToolDefinitionBuffer,
) !?model_contract.ToolDefinition {
    var reader = try session.viewContent(request_ref);
    var blob_source: CatalogContentSource = .{ .reader = &reader };
    var selection: CatalogSelection = .{ .key = key, .definition = buffer };
    _ = try openRequest(.{
        .context = &blob_source,
        .length_fn = CatalogContentSource.length,
        .read_fn = CatalogContentSource.read,
    }, &selection);
    return if (selection.found) buffer.definition() else null;
}

fn capturedResponseLength(current: u32, appended: usize) !u32 {
    if (current > model_protocol.max_response_size or
        appended > model_protocol.max_response_size - @as(usize, current))
    {
        return error.CapturedModelOutputTooLarge;
    }
    return current + @as(u32, @intCast(appended));
}

pub fn publishFailureResult(
    session: *session_store.Session,
    identity: u64,
) !u64 {
    const failure_ref = (@as(u64, 1) << 56) | (identity & ((@as(u64, 1) << 56) - 1));
    var buffer: [model_protocol.header_size]u8 = undefined;
    const encoded = try model_protocol.encodeFailure(&buffer, .provider_error);
    try session.storeContent(failure_ref, encoded);
    return failure_ref;
}

pub fn buildRequest(
    session: *session_store.Session,
    request_ref: u64,
    first_entry: u32,
    entry_count: u32,
) !binding.ModelDescriptor {
    return buildRequestWithCatalog(
        session,
        request_ref,
        first_entry,
        entry_count,
        &model_contract.default_catalog,
    );
}

pub fn buildRequestWithCatalog(
    session: *session_store.Session,
    request_ref: u64,
    first_entry: u32,
    entry_count: u32,
    catalog: []const model_contract.ToolDefinition,
) !binding.ModelDescriptor {
    if (request_ref == 0 or first_entry == 0 or entry_count == 0) {
        return error.InvalidContextSelection;
    }
    try model_contract.validateCatalog(catalog);
    const last = @as(u64, first_entry) + entry_count - 1;
    if (last > session.entryCount()) return error.InvalidContextSelection;
    const first = try session.readEntry(first_entry);
    const last_entry = try session.readEntry(last);
    if (first.kind == .tool_result or last_entry.kind == .tool_call) {
        return error.ContextSplitsToolPair;
    }

    const contract_digest = binding.hash(binding.ModelContract, model_contract.model_contract_bytes);

    var writer = try session.beginContent(request_ref);
    errdefer writer.abort();
    var hasher = binding.Hasher(binding.ModelDescriptor).init();
    var request_header: [request_header_size]u8 = @splat(0);
    @memcpy(request_header[0..request_magic.len], request_magic);
    write(u16, &request_header, 8, version);
    write(u16, &request_header, 10, request_header_size);
    write(u32, &request_header, 12, entry_count);
    write(u16, &request_header, 16, @intCast(catalog.len));
    write(u16, &request_header, 18, @intCast(session.modelName().len));
    write(u32, &request_header, 20, model_contract.default_instructions.len);
    write(u32, &request_header, 24, model_contract.model_contract_bytes.len);
    @memcpy(request_header[28..60], &model_contract.catalogDigest(catalog).bytes);
    @memcpy(request_header[60..92], &contract_digest.bytes);
    try appendHashed(&writer, &hasher, &request_header);
    try appendHashed(&writer, &hasher, session.modelName());
    try appendHashed(&writer, &hasher, model_contract.default_instructions);
    try appendHashed(&writer, &hasher, model_contract.model_contract_bytes);
    for (catalog) |definition| {
        var tool_header: [tool_header_size]u8 = @splat(0);
        write(u16, &tool_header, 0, @intCast(definition.key.len));
        write(u16, &tool_header, 2, @intCast(definition.provider_tool_name.len));
        write(u32, &tool_header, 4, @intCast(definition.description.len));
        write(u32, &tool_header, 8, @intCast(definition.input_schema.len));
        write(u32, &tool_header, 12, @intCast(definition.result_contract.len));
        try appendHashed(&writer, &hasher, &tool_header);
        try appendHashed(&writer, &hasher, definition.key);
        try appendHashed(&writer, &hasher, definition.provider_tool_name);
        try appendHashed(&writer, &hasher, definition.description);
        try appendHashed(&writer, &hasher, definition.input_schema);
        try appendHashed(&writer, &hasher, definition.result_contract);
    }

    var sequence: u64 = first_entry;
    while (sequence <= last) : (sequence += 1) {
        const entry = try session.readEntry(sequence);
        var content = try session.viewContent(entry.content_ref);
        var entry_header: [entry_header_size]u8 = @splat(0);
        entry_header[0] = @intFromEnum(entry.kind);
        write(u64, &entry_header, 8, entry.entry_id);
        write(u64, &entry_header, 16, entry.parent_id);
        write(u64, &entry_header, 24, content.length());
        try appendHashed(&writer, &hasher, &entry_header);

        var window: [request_window_size]u8 = undefined;
        var offset: u64 = 0;
        while (offset < content.length()) {
            const bytes = try content.readWindow(offset, &window);
            if (bytes.len == 0) return error.TruncatedContextContent;
            try appendHashed(&writer, &hasher, bytes);
            offset += bytes.len;
        }
    }
    try writer.finish();

    return hasher.final();
}

fn appendHashed(
    writer: *session_store.ContentWriter,
    hasher: *binding.Hasher(binding.ModelDescriptor),
    bytes: []const u8,
) !void {
    try writer.append(bytes);
    hasher.update(bytes);
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}

fn read(comptime T: type, input: []const u8, offset: usize) T {
    return std.mem.readInt(T, input[offset..][0..@sizeOf(T)], .little);
}

test "semantic content views stitch bounded short reads" {
    const ShortSource = struct {
        bytes: []const u8,

        fn length(context: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.bytes.len;
        }

        fn readWindow(context: *anyopaque, offset: u64, out: []u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (offset >= self.bytes.len) return out[0..0];
            const count = @min(@as(usize, 3), @min(out.len, self.bytes.len - @as(usize, @intCast(offset))));
            @memcpy(out[0..count], self.bytes[@intCast(offset)..][0..count]);
            return out[0..count];
        }
    };
    var short: ShortSource = .{ .bytes = "prefixsemantic-suffix" };
    const view: ContentView = .{
        .source = .{
            .context = &short,
            .length_fn = ShortSource.length,
            .read_fn = ShortSource.readWindow,
        },
        .start = "prefix".len,
        .length_value = "semantic".len,
    };
    var out: ["semantic".len]u8 = undefined;
    try std.testing.expectEqualStrings("semantic", try view.readWindow(0, &out));
}

test "Captured Model Output admits the exact bound and rejects one byte over" {
    try std.testing.expectEqual(
        @as(u32, model_protocol.max_response_size),
        try capturedResponseLength(0, model_protocol.max_response_size),
    );
    try std.testing.expectError(
        error.CapturedModelOutputTooLarge,
        capturedResponseLength(0, model_protocol.max_response_size + 1),
    );
    try std.testing.expectError(
        error.CapturedModelOutputTooLarge,
        capturedResponseLength(model_protocol.max_response_size, 1),
    );
}
