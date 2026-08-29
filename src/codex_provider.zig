const std = @import("std");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");

/// OnePage-owned lowering pinned to the observed OpenAI Codex protocol at
/// openai/codex commit 6478a751fde8884b2fdc76486fe23175a8e795d4.
pub const implementation_version = "onepage-codex-responses-v1@6478a751";
pub const endpoint = "https://chatgpt.com/backend-api/codex/responses";
pub const max_access_token_size: usize = 16 * 1024;
pub const max_account_id_size: usize = 128;
pub const max_sse_frame_size: usize = model_protocol.max_response_size + 8192;
pub const max_total_sse_bytes: usize = 4 * max_sse_frame_size;
pub const max_sse_event_count: usize = 128;
pub const request_window_size: usize = model_operation.request_window_size;

pub const Credential = struct {
    access_token: [max_access_token_size]u8 = @splat(0),
    access_token_length: u16 = 0,
    account_id: [max_account_id_size]u8 = @splat(0),
    account_id_length: u8 = 0,

    pub fn token(self: *const Credential) []const u8 {
        return self.access_token[0..self.access_token_length];
    }

    pub fn accountId(self: *const Credential) []const u8 {
        return self.account_id[0..self.account_id_length];
    }

    pub fn scrub(self: *Credential) void {
        std.crypto.secureZero(u8, &self.access_token);
        std.crypto.secureZero(u8, &self.account_id);
        self.access_token_length = 0;
        self.account_id_length = 0;
    }
};

pub const Authorization = struct {
    context: *anyopaque,
    load_fn: *const fn (*anyopaque, *Credential) anyerror!AuthorizationDisposition,

    fn load(self: Authorization, credential: *Credential) !AuthorizationDisposition {
        return self.load_fn(self.context, credential);
    }
};

pub const AuthorizationDisposition = enum {
    ready,
    missing,
    refresh_rejected,
    refresh_missing,
    timed_out,
};

pub const ByteSink = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn write(self: ByteSink, bytes: []const u8) !void {
        try self.write_fn(self.context, bytes);
    }
};

pub const TransportDisposition = enum {
    complete,
    http_unauthorized,
    http_forbidden,
    provider_rejected,
    model_not_found,
    rate_limited,
    quota_exceeded,
    backend_failed,
    timed_out,
    cancelled,
    not_started,
    may_have_started,
};

pub const Transport = struct {
    context: *anyopaque,
    perform_fn: *const fn (
        *anyopaque,
        *const Credential,
        model_operation.RequestCursor,
        *Capture,
    ) anyerror!TransportDisposition,

    fn perform(
        self: Transport,
        credential: *const Credential,
        request: model_operation.RequestCursor,
        capture: *Capture,
    ) !TransportDisposition {
        return self.perform_fn(self.context, credential, request, capture);
    }
};

pub const CodexProvider = struct {
    authorization: Authorization,
    transport: Transport,

    pub fn provider(self: *CodexProvider) model_operation.Provider {
        return .{ .context = self, .dispatch = dispatch };
    }

    fn dispatch(
        context: *anyopaque,
        request: model_operation.RequestCursor,
        candidate: model_operation.CandidateWriter,
    ) anyerror!model_operation.DispatchOutcome {
        const self: *CodexProvider = @ptrCast(@alignCast(context));
        var credential: Credential = .{};
        defer credential.scrub();
        const authorization = self.authorization.load(&credential) catch
            return failureOutcome(.provider_error);
        switch (authorization) {
            .missing => return failureOutcome(.missing_authentication),
            .refresh_rejected => return failureDiagnosticOutcome(
                .authentication_expired,
                .local_refresh_rejected,
                null,
                "",
            ),
            .refresh_missing => return failureDiagnosticOutcome(
                .authentication_expired,
                .local_refresh_missing,
                null,
                "",
            ),
            .timed_out => return failureOutcome(.timeout),
            .ready => {},
        }
        if (credential.token().len == 0) return failureOutcome(.provider_error);

        var capture: Capture = .{ .candidate = candidate };
        const disposition = self.transport.perform(&credential, request, &capture) catch
            return failureOutcome(.transport_may_have_started);
        return switch (disposition) {
            .complete => capture.publish(candidate),
            .http_unauthorized => failureDiagnosticOutcome(
                .authentication_expired,
                .provider_http_401,
                capture.failureHttpStatus(),
                capture.failureDiagnosticCode(),
            ),
            .http_forbidden => failureDiagnosticOutcome(
                .authentication_expired,
                .provider_http_403,
                capture.failureHttpStatus(),
                capture.failureDiagnosticCode(),
            ),
            .provider_rejected => failureDiagnosticOutcome(
                .provider_error,
                .provider_http_rejection,
                capture.failureHttpStatus(),
                capture.failureDiagnosticCode(),
            ),
            .model_not_found => failureDiagnosticOutcome(
                .model_unavailable,
                .provider_model_not_found,
                capture.failureHttpStatus(),
                capture.failureDiagnosticCode(),
            ),
            .rate_limited => failureDiagnosticOutcome(
                .provider_error,
                .provider_rate_limited,
                capture.failureHttpStatus(),
                capture.failureDiagnosticCode(),
            ),
            .quota_exceeded => failureDiagnosticOutcome(
                .provider_error,
                .provider_quota_exceeded,
                capture.failureHttpStatus(),
                capture.failureDiagnosticCode(),
            ),
            .backend_failed => failureDiagnosticOutcome(
                .provider_error,
                .provider_backend_failure,
                capture.failureHttpStatus(),
                capture.failureDiagnosticCode(),
            ),
            .timed_out => failureOutcome(.timeout),
            .cancelled => failureOutcome(.aborted),
            .not_started => failureOutcome(.transport_not_started),
            .may_have_started => failureOutcome(.transport_may_have_started),
        };
    }
};

fn failureOutcome(failure: model_protocol.Failure) model_operation.DispatchOutcome {
    return .{ .failure = .{ .failure = failure } };
}

fn failureDiagnosticOutcome(
    failure: model_protocol.Failure,
    source: model_protocol.DiagnosticSource,
    http_status: ?u16,
    code: []const u8,
) model_operation.DispatchOutcome {
    var capture: model_operation.FailureCapture = .{
        .failure = failure,
        .diagnostic_source = source,
        .http_status = http_status,
    };
    std.debug.assert(code.len <= capture.diagnostic_code_bytes.len);
    @memcpy(capture.diagnostic_code_bytes[0..code.len], code);
    capture.diagnostic_code_length = @intCast(code.len);
    return .{ .failure = capture };
}

pub const ToolMapping = struct {
    count: u8 = 0,
    keys: [model_contract.max_tool_count][model_contract.max_tool_key_size]u8 = undefined,
    key_lengths: [model_contract.max_tool_count]u8 = @splat(0),
    names: [model_contract.max_tool_count][model_contract.max_provider_tool_name_size]u8 = undefined,
    name_lengths: [model_contract.max_tool_count]u8 = @splat(0),

    fn add(self: *ToolMapping, definition: model_contract.ToolDefinition) !void {
        if (self.count == model_contract.max_tool_count) return error.ToolMappingCapacityExceeded;
        const index = self.count;
        @memcpy(self.keys[index][0..definition.key.len], definition.key);
        self.key_lengths[index] = @intCast(definition.key.len);
        @memcpy(self.names[index][0..definition.provider_tool_name.len], definition.provider_tool_name);
        self.name_lengths[index] = @intCast(definition.provider_tool_name.len);
        self.count += 1;
    }

    fn keyForName(self: *const ToolMapping, name: []const u8) ?[]const u8 {
        for (0..self.count) |index| {
            if (std.mem.eql(u8, self.names[index][0..self.name_lengths[index]], name)) {
                return self.keys[index][0..self.key_lengths[index]];
            }
        }
        return null;
    }

    fn nameForKey(self: *const ToolMapping, key: []const u8) ?[]const u8 {
        for (0..self.count) |index| {
            if (std.mem.eql(u8, self.keys[index][0..self.key_lengths[index]], key)) {
                return self.names[index][0..self.name_lengths[index]];
            }
        }
        return null;
    }
};

pub const Capture = struct {
    frame: [max_sse_frame_size]u8 = undefined,
    frame_length: usize = 0,
    candidate: ?model_operation.CandidateWriter = null,
    candidate_failure: model_protocol.Failure = .none,
    mapping: ToolMapping = .{},
    candidate_count: u8 = 0,
    terminal_count: u8 = 0,
    terminal_status: TerminalStatus = .none,
    completed: bool = false,
    malformed: bool = false,
    failure_diagnostic_code: [model_protocol.max_failure_diagnostic_code_size]u8 = @splat(0),
    failure_diagnostic_code_length: u8 = 0,
    failure_http_status: u16 = 0,
    total_sse_bytes: usize = 0,
    event_count: u16 = 0,

    pub fn setFailureHttpStatus(self: *Capture, status: u16) !void {
        if (status < 100 or status > 599) return error.InvalidHttpStatus;
        self.failure_http_status = status;
    }

    pub fn failureHttpStatus(self: *const Capture) ?u16 {
        return if (self.failure_http_status == 0) null else self.failure_http_status;
    }

    pub fn setFailureDiagnosticCode(self: *Capture, code: []const u8) !void {
        if (code.len > self.failure_diagnostic_code.len) return error.FailureDiagnosticCodeTooLong;
        for (code) |byte| if (!std.ascii.isAlphanumeric(byte) and
            byte != '_' and byte != '-' and byte != '.')
        {
            return error.InvalidFailureDiagnosticCode;
        };
        @memset(&self.failure_diagnostic_code, 0);
        @memcpy(self.failure_diagnostic_code[0..code.len], code);
        self.failure_diagnostic_code_length = @intCast(code.len);
    }

    pub fn failureDiagnosticCode(self: *const Capture) []const u8 {
        return self.failure_diagnostic_code[0..self.failure_diagnostic_code_length];
    }

    pub fn requestSink(self: *Capture) ByteSink {
        return .{ .context = self, .write_fn = discardRequestBytes };
    }

    fn discardRequestBytes(_: *anyopaque, _: []const u8) anyerror!void {}

    pub fn appendSse(self: *Capture, bytes: []const u8) !void {
        if (self.completed) return;
        self.total_sse_bytes = std.math.add(usize, self.total_sse_bytes, bytes.len) catch
            return error.SseStreamTooLarge;
        if (self.total_sse_bytes > max_total_sse_bytes) return error.SseStreamTooLarge;
        var remaining = bytes;
        while (remaining.len != 0) {
            const available = self.frame.len - self.frame_length;
            if (available == 0) return error.SseFrameTooLarge;
            const count = @min(available, remaining.len);
            @memcpy(self.frame[self.frame_length..][0..count], remaining[0..count]);
            self.frame_length += count;
            remaining = remaining[count..];
            while (frameBoundary(self.frame[0..self.frame_length])) |boundary| {
                if (self.event_count == max_sse_event_count) return error.TooManySseEvents;
                self.event_count += 1;
                self.consumeFrame(self.frame[0..boundary.end]) catch {
                    self.malformed = true;
                };
                const consumed = boundary.end + boundary.length;
                std.mem.copyForwards(u8, self.frame[0 .. self.frame_length - consumed], self.frame[consumed..self.frame_length]);
                self.frame_length -= consumed;
                if (self.completed) {
                    self.frame_length = 0;
                    return;
                }
            }
        }
    }

    pub fn terminalObserved(self: *const Capture) bool {
        return self.completed;
    }

    pub fn finishSse(self: *Capture) void {
        if (self.frame_length != 0 or !self.completed or self.terminal_count != 1 or
            (self.terminal_status == .completed and self.candidate_count != 1))
        {
            self.malformed = true;
        }
    }

    fn consumeFrame(self: *Capture, frame: []u8) !void {
        const payload = try compactSseData(frame);
        if (payload.len == 0) return;
        if (std.mem.eql(u8, payload, "[DONE]")) return;
        var arena_bytes: [max_sse_frame_size * 2]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), payload, .{
            .max_value_len = max_sse_frame_size,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        }) catch {
            self.malformed = true;
            return;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => {
                self.malformed = true;
                return;
            },
        };
        const event_type = jsonString(object.get("type")) orelse {
            self.malformed = true;
            return;
        };
        if (try terminalStatus(event_type, object)) |status| return self.captureTerminal(status);
        if (!std.mem.eql(u8, event_type, "response.output_item.done")) return;
        const item = jsonObject(object.get("item")) orelse {
            self.malformed = true;
            return;
        };
        const item_type = jsonString(item.get("type")) orelse {
            self.malformed = true;
            return;
        };
        if (!std.mem.eql(u8, item_type, "message") and !std.mem.eql(u8, item_type, "function_call")) {
            return;
        }
        self.candidate_count +|= 1;
        if (self.candidate_count != 1) return;
        if (std.mem.eql(u8, item_type, "message")) {
            try self.captureMessage(item);
        } else if (std.mem.eql(u8, item_type, "function_call")) {
            try self.captureFunction(item);
        } else {
            self.malformed = true;
        }
    }

    fn captureTerminal(self: *Capture, status: TerminalStatus) !void {
        if (self.completed) {
            self.malformed = true;
            return;
        }
        self.completed = true;
        self.terminal_count +|= 1;
        self.terminal_status = status;
    }

    fn captureMessage(self: *Capture, item: std.json.ObjectMap) !void {
        const role = jsonString(item.get("role")) orelse return error.MalformedCodexMessage;
        if (!std.mem.eql(u8, role, "assistant")) return error.MalformedCodexMessage;
        const content = jsonArray(item.get("content")) orelse return error.MalformedCodexMessage;
        var text: ?[]const u8 = null;
        for (content.items) |part_value| {
            const part = jsonObject(part_value) orelse return error.MalformedCodexMessage;
            const part_type = jsonString(part.get("type")) orelse return error.MalformedCodexMessage;
            if (!std.mem.eql(u8, part_type, "output_text")) continue;
            if (text != null) return error.MultipleCodexTextOutputs;
            text = jsonString(part.get("text")) orelse return error.MalformedCodexMessage;
        }
        try model_protocol.writeText(
            self.candidate orelse return error.CandidateWriterMissing,
            text orelse "",
        );
    }

    fn captureFunction(self: *Capture, item: std.json.ObjectMap) !void {
        const name = jsonString(item.get("name")) orelse return error.MalformedCodexFunction;
        const arguments = jsonString(item.get("arguments")) orelse return error.MalformedCodexFunction;
        if (std.mem.eql(u8, name, "onepage_input_request")) {
            try self.captureInputRequest(arguments);
            return;
        }
        const key = self.mapping.keyForName(name) orelse {
            self.candidate_failure = .unknown_tool;
            return;
        };
        try model_protocol.writeTool(
            self.candidate orelse return error.CandidateWriterMissing,
            key,
            arguments,
        );
    }

    fn captureInputRequest(self: *Capture, arguments: []const u8) !void {
        var arena_bytes: [16 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
        var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), arguments, .{
            .max_value_len = 16 * 1024,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        }) catch return error.MalformedInputRequest;
        defer parsed.deinit();
        const object = jsonObject(parsed.value) orelse return error.MalformedInputRequest;
        if (object.count() != 3) return error.MalformedInputRequest;
        const prompt = jsonString(object.get("prompt")) orelse return error.MalformedInputRequest;
        const shape = jsonString(object.get("response_type")) orelse return error.MalformedInputRequest;
        const choices = jsonArray(object.get("choices")) orelse return error.MalformedInputRequest;
        if (std.mem.eql(u8, shape, "text")) {
            if (choices.items.len != 0) return error.MalformedInputRequest;
            model_protocol.writeInputText(
                self.candidate orelse return error.CandidateWriterMissing,
                prompt,
            ) catch return error.MalformedInputRequest;
            return;
        }
        if (!std.mem.eql(u8, shape, "single_choice")) return error.MalformedInputRequest;
        if (choices.items.len == 0 or choices.items.len > model_contract.max_choice_count) {
            return error.MalformedInputRequest;
        }
        var decoded: [model_contract.max_choice_count]model_protocol.Choice = undefined;
        for (choices.items, 0..) |choice_value, index| {
            const choice = jsonObject(choice_value) orelse return error.MalformedInputRequest;
            if (choice.count() != 2) return error.MalformedInputRequest;
            decoded[index] = .{
                .id = jsonString(choice.get("id")) orelse return error.MalformedInputRequest,
                .label = jsonString(choice.get("label")) orelse return error.MalformedInputRequest,
            };
        }
        model_protocol.writeInputChoice(
            self.candidate orelse return error.CandidateWriterMissing,
            prompt,
            decoded[0..choices.items.len],
        ) catch return error.MalformedInputRequest;
    }

    fn publish(
        self: *Capture,
        candidate: model_operation.CandidateWriter,
    ) !model_operation.DispatchOutcome {
        _ = candidate;
        self.finishSse();
        if (self.malformed) {
            return failureOutcome(if (!self.completed) .truncated else .malformed);
        }
        switch (self.terminal_status) {
            .none => return failureOutcome(.truncated),
            .incomplete => return failureOutcome(.truncated),
            .failed => return failureOutcome(.provider_error),
            .cancelled => return failureOutcome(.aborted),
            .completed => {},
        }
        if (self.candidate_failure != .none) return failureOutcome(self.candidate_failure);
        if (self.candidate_count != 1) return failureOutcome(.malformed);
        return .candidate;
    }
};

fn compactSseData(frame: []u8) ![]u8 {
    var read_cursor: usize = 0;
    var write_cursor: usize = 0;
    var found_data = false;
    while (read_cursor <= frame.len) {
        const relative_end = std.mem.indexOfScalar(u8, frame[read_cursor..], '\n');
        const raw_end = if (relative_end) |offset| read_cursor + offset else frame.len;
        var line_end = raw_end;
        if (line_end > read_cursor and frame[line_end - 1] == '\r') line_end -= 1;
        const line = frame[read_cursor..line_end];
        if (std.mem.startsWith(u8, line, "data:")) {
            const prefix_length: usize = if (line.len > 5 and line[5] == ' ') 6 else 5;
            const data_start = read_cursor + prefix_length;
            if (found_data) {
                if (write_cursor == frame.len) return error.SseFrameTooLarge;
                frame[write_cursor] = '\n';
                write_cursor += 1;
            }
            const data_length = line_end - data_start;
            std.mem.copyForwards(
                u8,
                frame[write_cursor .. write_cursor + data_length],
                frame[data_start..line_end],
            );
            write_cursor += data_length;
            found_data = true;
        }
        if (raw_end == frame.len) break;
        read_cursor = raw_end + 1;
    }
    return frame[0..write_cursor];
}

const TerminalStatus = enum { none, completed, incomplete, failed, cancelled };

fn terminalStatus(event_type: []const u8, object: std.json.ObjectMap) !?TerminalStatus {
    const fallback: TerminalStatus = if (std.mem.eql(u8, event_type, "response.completed") or
        std.mem.eql(u8, event_type, "response.done"))
        .completed
    else if (std.mem.eql(u8, event_type, "response.incomplete"))
        .incomplete
    else if (std.mem.eql(u8, event_type, "response.failed") or std.mem.eql(u8, event_type, "error"))
        .failed
    else if (std.mem.eql(u8, event_type, "response.cancelled") or
        std.mem.eql(u8, event_type, "response.canceled"))
        .cancelled
    else
        return null;
    const response = jsonObject(object.get("response")) orelse return fallback;
    const status_text = jsonString(response.get("status")) orelse return fallback;
    const nested: TerminalStatus = if (std.mem.eql(u8, status_text, "completed"))
        .completed
    else if (std.mem.eql(u8, status_text, "incomplete"))
        .incomplete
    else if (std.mem.eql(u8, status_text, "failed"))
        .failed
    else if (std.mem.eql(u8, status_text, "cancelled") or std.mem.eql(u8, status_text, "canceled"))
        .cancelled
    else
        return error.MalformedTerminalStatus;
    if (nested != fallback) return error.ContradictoryTerminalStatus;
    return nested;
}

const FrameBoundary = struct { end: usize, length: usize };

fn frameBoundary(bytes: []const u8) ?FrameBoundary {
    const lf = std.mem.indexOf(u8, bytes, "\n\n");
    const crlf = std.mem.indexOf(u8, bytes, "\r\n\r\n");
    if (lf == null and crlf == null) return null;
    if (crlf) |index| {
        if (lf == null or index <= lf.?) return .{ .end = index, .length = 4 };
    }
    return .{ .end = lf.?, .length = 2 };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |string| string,
        else => null,
    };
}

fn jsonObject(value: ?std.json.Value) ?std.json.ObjectMap {
    return switch (value orelse return null) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: ?std.json.Value) ?std.json.Array {
    return switch (value orelse return null) {
        .array => |array| array,
        else => null,
    };
}

/// Streams the provider-neutral request into Responses JSON. The caller chooses
/// a bounded memory sink for tests or a file/socket sink for production.
pub fn encodeRequest(
    request_value: model_operation.RequestCursor,
    sink: ByteSink,
    mapping: *ToolMapping,
) !void {
    var request = request_value;
    var catalog = request.toolCatalog();
    var definition_buffer: model_operation.ToolDefinitionBuffer = .{};
    while (try catalog.next(&definition_buffer)) |definition| try mapping.add(definition);

    try sink.write("{\"model\":");
    const model_name = request.modelName();
    if (!std.mem.startsWith(u8, model_name, "codex:") or model_name.len == "codex:".len) {
        return error.InvalidCodexModel;
    }
    try writeJsonString(sink, model_name["codex:".len..]);
    try sink.write(",\"instructions\":");
    try writeJsonString(sink, request.instructions());
    try sink.write(",\"input\":[");
    var first = true;
    while (try request.next()) |entry| {
        if (!first) try sink.write(",");
        first = false;
        try writeEntry(sink, mapping, entry);
    }
    try sink.write("],\"tools\":[");
    var tools = request.toolCatalog();
    first = true;
    while (try tools.next(&definition_buffer)) |definition| {
        if (!first) try sink.write(",");
        first = false;
        try sink.write("{\"type\":\"function\",\"name\":");
        try writeJsonString(sink, definition.provider_tool_name);
        try sink.write(",\"description\":");
        try writeJsonString(sink, definition.description);
        try sink.write(",\"parameters\":");
        try sink.write(definition.input_schema);
        try sink.write(",\"strict\":true}");
    }
    if (!first) try sink.write(",");
    try sink.write("{\"type\":\"function\",\"name\":\"onepage_input_request\",\"description\":\"Request bounded non-secret user input only when the task cannot continue without it.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"prompt\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":2048},\"response_type\":{\"type\":\"string\",\"enum\":[\"text\",\"single_choice\"]},\"choices\":{\"type\":\"array\",\"maxItems\":8,\"items\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":64},\"label\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":256}},\"required\":[\"id\",\"label\"],\"additionalProperties\":false}}},\"required\":[\"prompt\",\"response_type\",\"choices\"],\"additionalProperties\":false},\"strict\":true}],\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,\"store\":false,\"stream\":true,\"include\":[]}");
}

fn writeEntry(sink: ByteSink, mapping: *const ToolMapping, entry: model_operation.RequestEntry) !void {
    switch (entry) {
        .user_text => |text| try writeMessage(sink, "user", "input_text", text.content),
        .assistant_text => |text| try writeMessage(sink, "assistant", "output_text", text.content),
        .context_checkpoint => |text| try writeMessage(sink, "developer", "input_text", text.content),
        .tool_call => |call| {
            try sink.write("{\"type\":\"function_call\",\"name\":");
            try writeJsonString(sink, mapping.nameForKey(call.key()) orelse return error.UnknownRequestTool);
            try sink.write(",\"arguments\":");
            try writeJsonContent(sink, call.arguments);
            try sink.write(",\"call_id\":");
            try writeCallId(sink, call.entry_id);
            try sink.write("}");
        },
        .tool_result => |result| {
            try sink.write("{\"type\":\"function_call_output\",\"call_id\":");
            try writeCallId(sink, result.call_entry_id);
            try sink.write(",\"output\":");
            try writeJsonContent(sink, result.content);
            try sink.write("}");
        },
    }
}

fn writeMessage(
    sink: ByteSink,
    role: []const u8,
    content_type: []const u8,
    content: model_operation.ContentView,
) !void {
    try sink.write("{\"role\":");
    try writeJsonString(sink, role);
    try sink.write(",\"content\":[{\"type\":");
    try writeJsonString(sink, content_type);
    try sink.write(",\"text\":");
    try writeJsonContent(sink, content);
    try sink.write("}]}");
}

fn writeCallId(sink: ByteSink, id: u64) !void {
    var buffer: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&buffer, "onepage_{d}", .{id});
    try writeJsonString(sink, value);
}

fn writeJsonContent(sink: ByteSink, content: model_operation.ContentView) !void {
    try sink.write("\"");
    var window: [request_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < content.length()) {
        const bytes = try content.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedSemanticContent;
        try writeJsonEscaped(sink, bytes);
        offset += bytes.len;
    }
    try sink.write("\"");
}

fn writeJsonString(sink: ByteSink, bytes: []const u8) !void {
    if (!model_contract.utf8Valid(bytes)) return error.InvalidJsonString;
    try sink.write("\"");
    try writeJsonEscaped(sink, bytes);
    try sink.write("\"");
}

fn writeJsonEscaped(sink: ByteSink, bytes: []const u8) !void {
    var encoded: [6 * request_window_size]u8 = undefined;
    var cursor: usize = 0;
    for (bytes) |byte| {
        const replacement: []const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...7 => &[_]u8{ '\\', 'u', '0', '0', '0', "0123456789abcdef"[byte] },
            8 => "\\b",
            11 => &[_]u8{ '\\', 'u', '0', '0', '0', "0123456789abcdef"[byte] },
            12 => "\\f",
            14...31 => &[_]u8{ '\\', 'u', '0', '0', "0123456789abcdef"[byte >> 4], "0123456789abcdef"[byte & 0xf] },
            else => &[_]u8{byte},
        };
        @memcpy(encoded[cursor..][0..replacement.len], replacement);
        cursor += replacement.len;
    }
    try sink.write(encoded[0..cursor]);
}

const TestCandidate = struct {
    bytes: [model_protocol.max_response_size]u8 = undefined,
    length: usize = 0,

    fn capture(self: *TestCandidate) Capture {
        return .{ .candidate = .{ .context = self, .append_fn = append } };
    }

    fn append(context: *anyopaque, bytes: []const u8) !void {
        const self: *TestCandidate = @ptrCast(@alignCast(context));
        if (bytes.len > self.bytes.len - self.length) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }
};

test "SSE capture maps final text, tools, input, and repeated terminals" {
    var output: TestCandidate = .{};
    var capture = output.capture();
    for (model_contract.default_catalog) |definition| try capture.mapping.add(definition);
    try capture.appendSse("event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"true\\\",\\\"timeout_ms\\\":1000}\",\"call_id\":\"call_1\"}}\n\n");
    try capture.appendSse("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\"}}\n\n");
    capture.finishSse();
    try std.testing.expect(!capture.malformed);
    var scratch: model_protocol.ValidationScratch = .{};
    const parsed = try model_protocol.decode(&scratch, output.bytes[0..output.length]);
    try std.testing.expectEqual(model_protocol.Disposition.tool_call, parsed.disposition);

    var repeated_output: TestCandidate = .{};
    var repeated = repeated_output.capture();
    const final_frame = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n";
    try repeated.appendSse(final_frame);
    try repeated.appendSse(final_frame);
    try repeated.appendSse("data: {\"type\":\"response.completed\"}\n\n");
    repeated.finishSse();
    try std.testing.expect(repeated.malformed);
}

test "SSE capture distinguishes truncated and malformed terminal streams" {
    var truncated_output: TestCandidate = .{};
    var truncated = truncated_output.capture();
    try truncated.appendSse("data: {\"type\":\"response.output_item.done\"");
    truncated.finishSse();
    try std.testing.expect(truncated.malformed);

    var unknown_output: TestCandidate = .{};
    var unknown = unknown_output.capture();
    try unknown.appendSse("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"not_offered\",\"arguments\":\"{}\",\"call_id\":\"x\"}}\n\n");
    try unknown.appendSse("data: {\"type\":\"response.completed\"}\n\n");
    unknown.finishSse();
    try std.testing.expectEqual(
        model_protocol.Failure.unknown_tool,
        (try unknown.publish(unknown.candidate.?)).failure.failure,
    );
}

test "SSE capture accepts fragmented CRLF and multi-line data" {
    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse("data: {\"type\":\"response.output_item.done\",\r\n");
    try capture.appendSse("data: \"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\r\n\r");
    try capture.appendSse("\ndata: {\"type\":\"response.done\"}\r\n\r\n");
    capture.finishSse();
    try std.testing.expect(!capture.malformed);
    var scratch: model_protocol.ValidationScratch = .{};
    try std.testing.expectEqual(
        model_protocol.Disposition.final_answer,
        (try model_protocol.decode(&scratch, output.bytes[0..output.length])).disposition,
    );
}

test "authoritative non-success terminals replace a partial candidate" {
    const candidate = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial\"}]}}\n\n";
    const cases = [_]struct {
        terminal: []const u8,
        expected: model_protocol.Failure,
    }{
        .{
            .terminal = "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\"}}\n\n",
            .expected = .truncated,
        },
        .{
            .terminal = "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\"}}\n\n",
            .expected = .provider_error,
        },
        .{
            .terminal = "data: {\"type\":\"response.cancelled\",\"response\":{\"status\":\"cancelled\"}}\n\n",
            .expected = .aborted,
        },
    };
    for (cases) |case| {
        var output: TestCandidate = .{};
        var capture = output.capture();
        try capture.appendSse(candidate);
        try capture.appendSse(case.terminal);
        capture.finishSse();
        try std.testing.expect(!capture.malformed);
        try std.testing.expectEqual(case.expected, (try capture.publish(capture.candidate.?)).failure.failure);
    }
}

test "terminal status agreement and first-terminal-wins are chunk independent" {
    const candidate = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n";
    const terminal = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse(candidate ++ terminal ++
        "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\"}}\n\n");
    capture.finishSse();
    try std.testing.expect(!capture.malformed);

    var split_output: TestCandidate = .{};
    var split = split_output.capture();
    try split.appendSse(candidate);
    try split.appendSse(terminal);
    try split.appendSse("data: malformed trailing bytes\n\n");
    split.finishSse();
    try std.testing.expect(!split.malformed);
    try std.testing.expectEqualSlices(
        u8,
        output.bytes[0..output.length],
        split_output.bytes[0..split_output.length],
    );

    var contradictory_output: TestCandidate = .{};
    var contradictory = contradictory_output.capture();
    try contradictory.appendSse(candidate);
    try contradictory.appendSse(
        "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"completed\"}}\n\n",
    );
    contradictory.finishSse();
    try std.testing.expect(contradictory.malformed);
}

test "input request arguments require the exact closed shape" {
    const valid = [_][]const u8{
        "{\"prompt\":\"Explain\",\"response_type\":\"text\",\"choices\":[]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"Alpha\"}]}",
    };
    for (valid) |arguments| {
        var output: TestCandidate = .{};
        var capture = output.capture();
        try capture.captureInputRequest(arguments);
        try std.testing.expect(output.length != 0);
    }
    const invalid = [_][]const u8{
        "{\"prompt\":\"Explain\",\"response_type\":\"text\"}",
        "{\"prompt\":\"Explain\",\"response_type\":\"text\",\"choices\":[],\"extra\":true}",
        "{\"prompt\":\"Explain\",\"prompt\":\"Again\",\"response_type\":\"text\",\"choices\":[]}",
        "{\"prompt\":42,\"response_type\":\"text\",\"choices\":[]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"Alpha\",\"extra\":true}]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"Alpha\"},{\"id\":\"a\",\"label\":\"Again\"}]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"\\uD800\"}]}",
        "{\"prompt\":\"Explain\",\"response_type\":\"text\",\"choices\":[]} trailing",
    };
    for (invalid) |arguments| {
        var output: TestCandidate = .{};
        var capture = output.capture();
        try std.testing.expectError(error.MalformedInputRequest, capture.captureInputRequest(arguments));
    }
}

test "JSON strings escape every control and reject malformed UTF-8" {
    const Sink = struct {
        bytes: [128]u8 = undefined,
        length: usize = 0,
        fn sink(self: *@This()) ByteSink {
            return .{ .context = self, .write_fn = write };
        }
        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (bytes.len > self.bytes.len - self.length) return error.NoSpaceLeft;
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    var sink: Sink = .{};
    try writeJsonString(sink.sink(), "quote\" slash\\\x00\x01\x08\x09\x0a\x0b\x0c\x0d\x1f é");
    try std.testing.expectEqualStrings(
        "\"quote\\\" slash\\\\\\u0000\\u0001\\b\\t\\n\\u000b\\f\\r\\u001f é\"",
        sink.bytes[0..sink.length],
    );
    const malformed = [_]u8{ 0xc3, 0x28 };
    try std.testing.expectError(error.InvalidJsonString, writeJsonString(sink.sink(), &malformed));
}
