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
/// JSON string escaping can expand one decoded byte to six wire bytes.
pub const max_sse_frame_size: usize = 6 * model_protocol.max_response_size + 8192;
pub const max_total_sse_bytes: usize = 4 * max_sse_frame_size;
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
    failed,
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
    invalid_encoding,
    timed_out,
    cancelled,
    not_started,
    may_have_started,
};

pub const TransportResult = struct {
    disposition: TransportDisposition,
    http_status: u16 = 0,
    diagnostic_code_bytes: [model_protocol.max_failure_diagnostic_code_size]u8 = @splat(0),
    diagnostic_code_length: u8 = 0,

    pub fn setHttpStatus(self: *TransportResult, status: u16) !void {
        if (status < 100 or status > 599) return error.InvalidHttpStatus;
        self.http_status = status;
    }

    pub fn httpStatus(self: *const TransportResult) ?u16 {
        return if (self.http_status == 0) null else self.http_status;
    }

    pub fn setDiagnosticCode(self: *TransportResult, code: []const u8) !void {
        if (code.len > self.diagnostic_code_bytes.len) return error.FailureDiagnosticCodeTooLong;
        for (code) |byte| if (!std.ascii.isAlphanumeric(byte) and
            byte != '_' and byte != '-' and byte != '.')
        {
            return error.InvalidFailureDiagnosticCode;
        };
        @memset(&self.diagnostic_code_bytes, 0);
        @memcpy(self.diagnostic_code_bytes[0..code.len], code);
        self.diagnostic_code_length = @intCast(code.len);
    }

    pub fn diagnosticCode(self: *const TransportResult) []const u8 {
        return self.diagnostic_code_bytes[0..self.diagnostic_code_length];
    }
};

pub const Transport = struct {
    context: *anyopaque,
    perform_fn: *const fn (
        *anyopaque,
        *const Credential,
        model_operation.RequestCursor,
        *Capture,
    ) anyerror!TransportResult,

    fn perform(
        self: Transport,
        credential: *const Credential,
        request: model_operation.RequestCursor,
        capture: *Capture,
    ) !TransportResult {
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
        const authorization = try self.authorization.load(&credential);
        switch (authorization) {
            .missing => return failureOutcome(.missing_authentication),
            .refresh_rejected => return failureDiagnosticOutcome(
                .authentication_expired,
                .local_credentials,
                "codex.refresh.rejected",
            ),
            .refresh_missing => return failureDiagnosticOutcome(
                .authentication_expired,
                .local_credentials,
                "codex.refresh.missing",
            ),
            .failed => return failureOutcome(.provider_error),
            .timed_out => return failureOutcome(.timeout),
            .ready => {},
        }
        if (credential.token().len == 0) return failureOutcome(.provider_error);

        var capture: Capture = .{ .candidate = candidate };
        const transport_result = try self.transport.perform(&credential, request, &capture);
        return switch (transport_result.disposition) {
            .complete => capture.publish(),
            .http_unauthorized => transportFailureOutcome(
                .authentication_expired,
                "unauthorized",
                &transport_result,
            ),
            .http_forbidden => transportFailureOutcome(
                .authentication_expired,
                "forbidden",
                &transport_result,
            ),
            .provider_rejected => transportFailureOutcome(
                .provider_error,
                "rejected",
                &transport_result,
            ),
            .model_not_found => transportFailureOutcome(
                .model_unavailable,
                "model",
                &transport_result,
            ),
            .rate_limited => transportFailureOutcome(
                .provider_error,
                "rate",
                &transport_result,
            ),
            .quota_exceeded => transportFailureOutcome(
                .provider_error,
                "quota",
                &transport_result,
            ),
            .backend_failed => transportFailureOutcome(
                .provider_error,
                "backend",
                &transport_result,
            ),
            .invalid_encoding => failureOutcome(.malformed),
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
    code: []const u8,
) model_operation.DispatchOutcome {
    var capture: model_operation.FailureCapture = .{
        .failure = failure,
        .diagnostic_source = source,
    };
    std.debug.assert(code.len <= capture.diagnostic_code_bytes.len);
    @memcpy(capture.diagnostic_code_bytes[0..code.len], code);
    capture.diagnostic_code_length = @intCast(code.len);
    return .{ .failure = capture };
}

/// Codex owns this opaque code grammar. Shared protocol code only validates
/// its generic bounded ASCII representation and never interprets its parts.
fn transportFailureOutcome(
    failure: model_protocol.Failure,
    class: []const u8,
    transport_result: *const TransportResult,
) model_operation.DispatchOutcome {
    var code_buffer: [model_protocol.max_failure_diagnostic_code_size]u8 = undefined;
    const code = if (transport_result.httpStatus()) |status|
        std.fmt.bufPrint(&code_buffer, "codex.http.{s}.{d}", .{ class, status }) catch unreachable
    else
        std.fmt.bufPrint(&code_buffer, "codex.http.{s}", .{class}) catch unreachable;
    return failureDiagnosticOutcome(failure, .provider, code);
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
    resource_exceeded: bool = false,
    total_sse_bytes: usize = 0,

    pub fn requestSink(self: *Capture) ByteSink {
        return .{ .context = self, .write_fn = discardRequestBytes };
    }

    fn discardRequestBytes(_: *anyopaque, _: []const u8) anyerror!void {}

    pub fn appendSse(self: *Capture, bytes: []const u8) !void {
        if (self.completed) return;
        var remaining = bytes;
        while (remaining.len != 0) {
            const available = self.frame.len - self.frame_length;
            if (available == 0) return self.exceeded(error.SseFrameTooLarge);
            // Stop each copy at the next line ending so a terminal boundary is
            // observed before any coalesced trailing bytes are charged.
            const through_next_lf = if (std.mem.indexOfScalar(u8, remaining, '\n')) |index|
                index + 1
            else
                remaining.len;
            const count = @min(available, through_next_lf);
            self.total_sse_bytes = std.math.add(usize, self.total_sse_bytes, count) catch
                return self.exceeded(error.SseStreamTooLarge);
            if (self.total_sse_bytes > max_total_sse_bytes) {
                return self.exceeded(error.SseStreamTooLarge);
            }
            @memcpy(self.frame[self.frame_length..][0..count], remaining[0..count]);
            self.frame_length += count;
            remaining = remaining[count..];
            while (frameBoundary(self.frame[0..self.frame_length])) |boundary| {
                try self.consumeFrame(self.frame[0..boundary.end]);
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

    fn exceeded(self: *Capture, err: anyerror) anyerror {
        self.resource_exceeded = true;
        return err;
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

    // Model-controlled candidate semantics are classified before encoder entry.
    // Encoder errors remain uncaught because CandidateWriter failures are Host-owned.
    fn consumeFrame(self: *Capture, frame: []u8) !void {
        const payload = compactSseData(frame) catch |err| return self.exceeded(err);
        if (payload.len == 0) return;
        if (std.mem.eql(u8, payload, "[DONE]")) return;
        const parsed = parseEvent(payload) catch |err| {
            switch (err) {
                error.JsonNestingTooDeep => self.resource_exceeded = true,
                else => self.malformed = true,
            }
            return;
        };
        if (terminalStatus(parsed.event_type, parsed.response_status) catch {
            self.malformed = true;
            return;
        }) |status| {
            return self.captureTerminal(status);
        }
        if (!std.mem.eql(u8, parsed.event_type, "response.output_item.done")) return;
        const item = parsed.item orelse {
            self.malformed = true;
            return;
        };
        const item_type = item.item_type orelse {
            self.malformed = true;
            return;
        };
        if (!std.mem.eql(u8, item_type, "message") and !std.mem.eql(u8, item_type, "function_call")) {
            return;
        }
        self.candidate_count +|= 1;
        if (self.candidate_count != 1) return;
        if (std.mem.eql(u8, item_type, "message")) {
            const text = validateMessage(item) catch {
                self.malformed = true;
                return;
            };
            if (text.len > model_protocol.max_assistant_text_size) {
                self.candidate_failure = .oversized;
                return;
            }
            try model_protocol.writeText(
                self.candidate orelse return error.CandidateWriterMissing,
                text,
            );
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

    fn captureFunction(self: *Capture, item: ParsedItem) !void {
        const name = item.name orelse {
            self.malformed = true;
            return;
        };
        const arguments = item.arguments orelse {
            self.malformed = true;
            return;
        };
        if (arguments.len == 0) {
            self.malformed = true;
            return;
        }
        if (arguments.len > model_contract.max_tool_arguments_envelope_size) {
            self.candidate_failure = .oversized;
            return;
        }
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

    fn captureInputRequest(self: *Capture, arguments: []u8) !void {
        const parsed = parseInputRequest(arguments) catch |err| {
            switch (err) {
                error.JsonNestingTooDeep, error.TooManyInputChoices => self.resource_exceeded = true,
                else => self.malformed = true,
            }
            return;
        };
        if (std.mem.eql(u8, parsed.shape, "text")) {
            if (parsed.choice_count != 0 or parsed.prompt.len == 0) {
                self.malformed = true;
                return;
            }
            if (parsed.prompt.len > model_contract.max_prompt_size) {
                self.candidate_failure = .oversized;
                return;
            }
            try model_protocol.writeInputText(
                self.candidate orelse return error.CandidateWriterMissing,
                parsed.prompt,
            );
            return;
        }
        if (!std.mem.eql(u8, parsed.shape, "single_choice")) {
            self.malformed = true;
            return;
        }
        if (parsed.choice_count == 0) {
            self.malformed = true;
            return;
        }
        if (parsed.prompt.len == 0) {
            self.malformed = true;
            return;
        }
        if (parsed.prompt.len > model_contract.max_prompt_size) {
            self.candidate_failure = .oversized;
            return;
        }
        for (parsed.choices[0..parsed.choice_count]) |choice| {
            if (choice.id.len == 0 or choice.label.len == 0) {
                self.malformed = true;
                return;
            }
            if (choice.id.len > model_contract.max_choice_id_size or
                choice.label.len > model_contract.max_choice_label_size)
            {
                self.candidate_failure = .oversized;
                return;
            }
        }
        try model_protocol.writeInputChoice(
            self.candidate orelse return error.CandidateWriterMissing,
            parsed.prompt,
            parsed.choices[0..parsed.choice_count],
        );
    }

    fn publish(self: *Capture) !model_operation.DispatchOutcome {
        self.finishSse();
        if (self.resource_exceeded) return failureOutcome(.oversized);
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

fn terminalStatus(event_type: []const u8, response_status: ?[]const u8) !?TerminalStatus {
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
    const status_text = response_status orelse return fallback;
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

const max_json_nesting_depth: usize = 32;

const ParsedEvent = struct {
    event_type: []const u8,
    response_status: ?[]const u8 = null,
    item: ?ParsedItem = null,
};

const ParsedItem = struct {
    item_type: ?[]const u8 = null,
    role: ?[]const u8 = null,
    content_seen: bool = false,
    output_text_count: u8 = 0,
    text: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]u8 = null,
};

fn validateMessage(item: ParsedItem) ![]const u8 {
    const role = item.role orelse return error.MalformedCodexMessage;
    if (!std.mem.eql(u8, role, "assistant") or !item.content_seen or
        item.output_text_count != 1)
    {
        return error.MalformedCodexMessage;
    }
    const text = item.text orelse return error.MalformedCodexMessage;
    if (text.len == 0) return error.MalformedCodexMessage;
    return text;
}

const ParsedInputRequest = struct {
    prompt: []const u8,
    shape: []const u8,
    choices: [model_contract.max_choice_count]model_protocol.Choice,
    choice_count: usize,
};

const RawJsonField = struct {
    value: ?[]u8 = null,
    duplicate: bool = false,

    fn capture(self: *RawJsonField, cursor: *JsonCursor) !void {
        if (self.value == null) {
            self.value = try cursor.rawValue();
        } else {
            self.duplicate = true;
            try cursor.skipValue();
        }
    }

    fn single(self: RawJsonField) !?[]u8 {
        if (self.duplicate) return error.DuplicateJsonField;
        return self.value;
    }
};

/// A Codex-private, allocation-free cursor over one compacted SSE JSON payload.
/// Strings are decoded in place; decoding cannot expand JSON source bytes.
const JsonCursor = struct {
    bytes: []u8,
    cursor: usize = 0,
    depth: usize = 0,

    fn document(bytes: []u8) JsonCursor {
        return .{ .bytes = bytes };
    }

    fn finish(self: *JsonCursor) !void {
        self.skipWhitespace();
        if (self.cursor != self.bytes.len) return error.TrailingJsonValue;
    }

    fn skipWhitespace(self: *JsonCursor) void {
        while (self.cursor < self.bytes.len and switch (self.bytes[self.cursor]) {
            ' ', '\t', '\r', '\n' => true,
            else => false,
        }) self.cursor += 1;
    }

    fn take(self: *JsonCursor, expected: u8) !void {
        self.skipWhitespace();
        if (self.cursor == self.bytes.len or self.bytes[self.cursor] != expected) {
            return error.InvalidJsonShape;
        }
        self.cursor += 1;
    }

    fn enter(self: *JsonCursor, delimiter: u8) !void {
        if (self.depth == max_json_nesting_depth) return error.JsonNestingTooDeep;
        try self.take(delimiter);
        self.depth += 1;
    }

    fn maybeTake(self: *JsonCursor, expected: u8) bool {
        self.skipWhitespace();
        if (self.cursor == self.bytes.len or self.bytes[self.cursor] != expected) return false;
        self.cursor += 1;
        return true;
    }

    fn string(self: *JsonCursor) ![]u8 {
        self.skipWhitespace();
        if (self.cursor == self.bytes.len or self.bytes[self.cursor] != '"') {
            return error.ExpectedJsonString;
        }
        const start = self.cursor + 1;
        var read = start;
        var write = start;
        while (read < self.bytes.len) {
            const byte = self.bytes[read];
            if (byte == '"') {
                self.cursor = read + 1;
                const decoded = self.bytes[start..write];
                if (!model_contract.utf8Valid(decoded)) return error.InvalidJsonUtf8;
                return decoded;
            }
            if (byte < 0x20) return error.InvalidJsonControl;
            if (byte != '\\') {
                self.bytes[write] = byte;
                write += 1;
                read += 1;
                continue;
            }
            read += 1;
            if (read == self.bytes.len) return error.IncompleteJsonEscape;
            switch (self.bytes[read]) {
                '"', '\\', '/' => |escaped| {
                    self.bytes[write] = escaped;
                    write += 1;
                    read += 1;
                },
                'b' => {
                    self.bytes[write] = 0x08;
                    write += 1;
                    read += 1;
                },
                'f' => {
                    self.bytes[write] = 0x0c;
                    write += 1;
                    read += 1;
                },
                'n' => {
                    self.bytes[write] = '\n';
                    write += 1;
                    read += 1;
                },
                'r' => {
                    self.bytes[write] = '\r';
                    write += 1;
                    read += 1;
                },
                't' => {
                    self.bytes[write] = '\t';
                    write += 1;
                    read += 1;
                },
                'u' => {
                    const first = try hexCodeUnit(self.bytes, read + 1);
                    read += 5;
                    var code_point: u21 = first;
                    if (first >= 0xd800 and first <= 0xdbff) {
                        if (read + 6 > self.bytes.len or self.bytes[read] != '\\' or
                            self.bytes[read + 1] != 'u') return error.UnpairedJsonSurrogate;
                        const second = try hexCodeUnit(self.bytes, read + 2);
                        if (second < 0xdc00 or second > 0xdfff) return error.UnpairedJsonSurrogate;
                        code_point = @intCast(0x10000 +
                            ((@as(u32, first) - 0xd800) << 10) +
                            (@as(u32, second) - 0xdc00));
                        read += 6;
                    } else if (first >= 0xdc00 and first <= 0xdfff) {
                        return error.UnpairedJsonSurrogate;
                    }
                    write += try std.unicode.utf8Encode(code_point, self.bytes[write..]);
                },
                else => return error.InvalidJsonEscape,
            }
        }
        return error.UnterminatedJsonString;
    }

    fn rawValue(self: *JsonCursor) ![]u8 {
        self.skipWhitespace();
        const start = self.cursor;
        try self.skipValue();
        return self.bytes[start..self.cursor];
    }

    fn skipString(self: *JsonCursor) !void {
        self.skipWhitespace();
        if (self.cursor == self.bytes.len or self.bytes[self.cursor] != '"') {
            return error.ExpectedJsonString;
        }
        self.cursor += 1;
        var segment_start = self.cursor;
        while (self.cursor < self.bytes.len) {
            const byte = self.bytes[self.cursor];
            if (byte == '"') {
                if (!model_contract.utf8Valid(self.bytes[segment_start..self.cursor])) {
                    return error.InvalidJsonUtf8;
                }
                self.cursor += 1;
                return;
            }
            if (byte < 0x20) return error.InvalidJsonControl;
            if (byte != '\\') {
                self.cursor += 1;
                continue;
            }
            if (!model_contract.utf8Valid(self.bytes[segment_start..self.cursor])) {
                return error.InvalidJsonUtf8;
            }
            self.cursor += 1;
            if (self.cursor == self.bytes.len) return error.IncompleteJsonEscape;
            switch (self.bytes[self.cursor]) {
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => self.cursor += 1,
                'u' => {
                    const first = try hexCodeUnit(self.bytes, self.cursor + 1);
                    self.cursor += 5;
                    if (first >= 0xd800 and first <= 0xdbff) {
                        if (self.cursor + 6 > self.bytes.len or
                            self.bytes[self.cursor] != '\\' or self.bytes[self.cursor + 1] != 'u')
                        {
                            return error.UnpairedJsonSurrogate;
                        }
                        const second = try hexCodeUnit(self.bytes, self.cursor + 2);
                        if (second < 0xdc00 or second > 0xdfff) {
                            return error.UnpairedJsonSurrogate;
                        }
                        self.cursor += 6;
                    } else if (first >= 0xdc00 and first <= 0xdfff) {
                        return error.UnpairedJsonSurrogate;
                    }
                },
                else => return error.InvalidJsonEscape,
            }
            segment_start = self.cursor;
        }
        return error.UnterminatedJsonString;
    }

    fn skipValue(self: *JsonCursor) !void {
        self.skipWhitespace();
        if (self.cursor == self.bytes.len) return error.MissingJsonValue;
        switch (self.bytes[self.cursor]) {
            '"' => try self.skipString(),
            '{' => {
                try self.enter('{');
                if (!self.maybeTake('}')) {
                    while (true) {
                        try self.skipString();
                        try self.take(':');
                        try self.skipValue();
                        if (self.maybeTake('}')) break;
                        try self.take(',');
                    }
                }
                self.depth -= 1;
            },
            '[' => {
                try self.enter('[');
                if (!self.maybeTake(']')) {
                    while (true) {
                        try self.skipValue();
                        if (self.maybeTake(']')) break;
                        try self.take(',');
                    }
                }
                self.depth -= 1;
            },
            't' => try self.literal("true"),
            'f' => try self.literal("false"),
            'n' => try self.literal("null"),
            '-', '0'...'9' => try self.number(),
            else => return error.InvalidJsonValue,
        }
    }

    fn literal(self: *JsonCursor, value: []const u8) !void {
        if (!std.mem.startsWith(u8, self.bytes[self.cursor..], value)) return error.InvalidJsonLiteral;
        self.cursor += value.len;
    }

    fn number(self: *JsonCursor) !void {
        if (self.maybeRaw('-') and self.cursor == self.bytes.len) return error.InvalidJsonNumber;
        if (self.maybeRaw('0')) {
            if (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) {
                return error.InvalidJsonNumber;
            }
        } else {
            if (self.cursor == self.bytes.len or self.bytes[self.cursor] < '1' or
                self.bytes[self.cursor] > '9') return error.InvalidJsonNumber;
            while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) {
                self.cursor += 1;
            }
        }
        if (self.maybeRaw('.')) {
            if (self.cursor == self.bytes.len or !std.ascii.isDigit(self.bytes[self.cursor])) {
                return error.InvalidJsonNumber;
            }
            while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) {
                self.cursor += 1;
            }
        }
        if (self.cursor < self.bytes.len and (self.bytes[self.cursor] == 'e' or self.bytes[self.cursor] == 'E')) {
            self.cursor += 1;
            _ = self.maybeRaw('+') or self.maybeRaw('-');
            if (self.cursor == self.bytes.len or !std.ascii.isDigit(self.bytes[self.cursor])) {
                return error.InvalidJsonNumber;
            }
            while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) {
                self.cursor += 1;
            }
        }
    }

    fn maybeRaw(self: *JsonCursor, byte: u8) bool {
        if (self.cursor == self.bytes.len or self.bytes[self.cursor] != byte) return false;
        self.cursor += 1;
        return true;
    }
};

fn hexCodeUnit(bytes: []const u8, start: usize) !u16 {
    if (start + 4 > bytes.len) return error.IncompleteJsonEscape;
    var value: u16 = 0;
    for (bytes[start .. start + 4]) |byte| {
        value = std.math.mul(u16, value, 16) catch unreachable;
        value += switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return error.InvalidJsonEscape,
        };
    }
    return value;
}

fn parseEvent(payload: []u8) !ParsedEvent {
    var cursor = JsonCursor.document(payload);
    try cursor.enter('{');
    var event_type_field: RawJsonField = .{};
    var response_field: RawJsonField = .{};
    var item_field: RawJsonField = .{};
    if (!cursor.maybeTake('}')) {
        while (true) {
            const key = try cursor.string();
            try cursor.take(':');
            if (std.mem.eql(u8, key, "type")) {
                try event_type_field.capture(&cursor);
            } else if (std.mem.eql(u8, key, "response")) {
                try response_field.capture(&cursor);
            } else if (std.mem.eql(u8, key, "item")) {
                try item_field.capture(&cursor);
            } else {
                try cursor.skipValue();
            }
            if (cursor.maybeTake('}')) break;
            try cursor.take(',');
        }
    }
    cursor.depth -= 1;
    try cursor.finish();

    const event_type = try parseStringValue(
        (try event_type_field.single()) orelse return error.MissingEventType,
    );
    var response_status: ?[]const u8 = null;
    var item: ?ParsedItem = null;
    if ((try terminalStatus(event_type, null)) != null) {
        if (try response_field.single()) |response_bytes| {
            var response_cursor = JsonCursor.document(response_bytes);
            response_status = try parseResponse(&response_cursor);
            try response_cursor.finish();
        }
    } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        if (try item_field.single()) |item_bytes| {
            var item_cursor = JsonCursor.document(item_bytes);
            item = try parseItem(&item_cursor);
            try item_cursor.finish();
        }
    }
    return .{
        .event_type = event_type,
        .response_status = response_status,
        .item = item,
    };
}

fn parseStringValue(bytes: []u8) ![]u8 {
    var cursor = JsonCursor.document(bytes);
    const value = try cursor.string();
    try cursor.finish();
    return value;
}

fn parseResponse(cursor: *JsonCursor) !?[]const u8 {
    try cursor.enter('{');
    var status: ?[]const u8 = null;
    if (!cursor.maybeTake('}')) {
        while (true) {
            const key = try cursor.string();
            try cursor.take(':');
            if (std.mem.eql(u8, key, "status")) {
                if (status != null) return error.DuplicateJsonField;
                status = try cursor.string();
            } else {
                try cursor.skipValue();
            }
            if (cursor.maybeTake('}')) break;
            try cursor.take(',');
        }
    }
    cursor.depth -= 1;
    return status;
}

fn parseItem(cursor: *JsonCursor) !ParsedItem {
    try cursor.enter('{');
    var type_field: RawJsonField = .{};
    var role_field: RawJsonField = .{};
    var content_field: RawJsonField = .{};
    var name_field: RawJsonField = .{};
    var arguments_field: RawJsonField = .{};
    if (!cursor.maybeTake('}')) {
        while (true) {
            const key = try cursor.string();
            try cursor.take(':');
            if (std.mem.eql(u8, key, "type")) {
                try type_field.capture(cursor);
            } else if (std.mem.eql(u8, key, "role")) {
                try role_field.capture(cursor);
            } else if (std.mem.eql(u8, key, "content")) {
                try content_field.capture(cursor);
            } else if (std.mem.eql(u8, key, "name")) {
                try name_field.capture(cursor);
            } else if (std.mem.eql(u8, key, "arguments")) {
                try arguments_field.capture(cursor);
            } else {
                try cursor.skipValue();
            }
            if (cursor.maybeTake('}')) break;
            try cursor.take(',');
        }
    }
    cursor.depth -= 1;

    var item: ParsedItem = .{};
    const type_bytes = (try type_field.single()) orelse return item;
    item.item_type = try parseStringValue(type_bytes);
    if (std.mem.eql(u8, item.item_type.?, "message")) {
        if (try role_field.single()) |role_bytes| {
            item.role = try parseStringValue(role_bytes);
        }
        if (try content_field.single()) |content_bytes| {
            item.content_seen = true;
            var content_cursor = JsonCursor.document(content_bytes);
            try parseContent(&content_cursor, &item);
            try content_cursor.finish();
        }
    } else if (std.mem.eql(u8, item.item_type.?, "function_call")) {
        if (try name_field.single()) |name_bytes| {
            item.name = try parseStringValue(name_bytes);
        }
        if (try arguments_field.single()) |arguments_bytes| {
            item.arguments = try parseStringValue(arguments_bytes);
        }
    }
    return item;
}

fn parseContent(cursor: *JsonCursor, item: *ParsedItem) !void {
    try cursor.enter('[');
    if (!cursor.maybeTake(']')) {
        while (true) {
            try cursor.enter('{');
            var type_field: RawJsonField = .{};
            var text_field: RawJsonField = .{};
            if (!cursor.maybeTake('}')) {
                while (true) {
                    const key = try cursor.string();
                    try cursor.take(':');
                    if (std.mem.eql(u8, key, "type")) {
                        try type_field.capture(cursor);
                    } else if (std.mem.eql(u8, key, "text")) {
                        try text_field.capture(cursor);
                    } else {
                        try cursor.skipValue();
                    }
                    if (cursor.maybeTake('}')) break;
                    try cursor.take(',');
                }
            }
            cursor.depth -= 1;
            const kind = try parseStringValue(
                (try type_field.single()) orelse return error.MalformedCodexMessage,
            );
            if (std.mem.eql(u8, kind, "output_text")) {
                item.output_text_count +|= 1;
                item.text = try parseStringValue(
                    (try text_field.single()) orelse return error.MalformedCodexMessage,
                );
            }
            if (cursor.maybeTake(']')) break;
            try cursor.take(',');
        }
    }
    cursor.depth -= 1;
}

fn parseInputRequest(arguments: []u8) !ParsedInputRequest {
    var cursor = JsonCursor.document(arguments);
    try cursor.enter('{');
    var prompt: ?[]const u8 = null;
    var shape: ?[]const u8 = null;
    var choices_seen = false;
    var choices: [model_contract.max_choice_count]model_protocol.Choice = undefined;
    var choice_count: usize = 0;
    if (!cursor.maybeTake('}')) {
        while (true) {
            const key = try cursor.string();
            try cursor.take(':');
            if (std.mem.eql(u8, key, "prompt")) {
                if (prompt != null) return error.DuplicateJsonField;
                prompt = try cursor.string();
            } else if (std.mem.eql(u8, key, "response_type")) {
                if (shape != null) return error.DuplicateJsonField;
                shape = try cursor.string();
            } else if (std.mem.eql(u8, key, "choices")) {
                if (choices_seen) return error.DuplicateJsonField;
                choices_seen = true;
                choice_count = try parseChoices(&cursor, &choices);
            } else {
                return error.UnknownInputRequestField;
            }
            if (cursor.maybeTake('}')) break;
            try cursor.take(',');
        }
    }
    cursor.depth -= 1;
    try cursor.finish();
    if (!choices_seen) return error.MissingInputRequestField;
    return .{
        .prompt = prompt orelse return error.MissingInputRequestField,
        .shape = shape orelse return error.MissingInputRequestField,
        .choices = choices,
        .choice_count = choice_count,
    };
}

fn parseChoices(
    cursor: *JsonCursor,
    choices: *[model_contract.max_choice_count]model_protocol.Choice,
) !usize {
    try cursor.enter('[');
    var count: usize = 0;
    if (!cursor.maybeTake(']')) {
        while (true) {
            if (count == choices.len) return error.TooManyInputChoices;
            try cursor.enter('{');
            var id: ?[]const u8 = null;
            var label: ?[]const u8 = null;
            if (!cursor.maybeTake('}')) {
                while (true) {
                    const key = try cursor.string();
                    try cursor.take(':');
                    if (std.mem.eql(u8, key, "id")) {
                        if (id != null) return error.DuplicateJsonField;
                        id = try cursor.string();
                    } else if (std.mem.eql(u8, key, "label")) {
                        if (label != null) return error.DuplicateJsonField;
                        label = try cursor.string();
                    } else {
                        return error.UnknownInputChoiceField;
                    }
                    if (cursor.maybeTake('}')) break;
                    try cursor.take(',');
                }
            }
            cursor.depth -= 1;
            const choice_id = id orelse return error.MissingInputChoiceField;
            for (choices[0..count]) |earlier| {
                if (std.mem.eql(u8, earlier.id, choice_id)) return error.DuplicateInputChoice;
            }
            choices[count] = .{
                .id = choice_id,
                .label = label orelse return error.MissingInputChoiceField,
            };
            count += 1;
            if (cursor.maybeTake(']')) break;
            try cursor.take(',');
        }
    }
    cursor.depth -= 1;
    return count;
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
    try sink.write("],\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,\"store\":false,\"stream\":true,\"include\":[]}");
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

test "Codex dispatch preserves Host errors and captures declared external failures" {
    const AuthorizationFixture = struct {
        disposition: ?AuthorizationDisposition = null,

        fn load(
            context: *anyopaque,
            credential: *Credential,
        ) anyerror!AuthorizationDisposition {
            const self: *@This() = @ptrCast(@alignCast(context));
            const disposition = self.disposition orelse return error.InjectedHostAuthorizationFailure;
            if (disposition == .ready) {
                @memcpy(credential.access_token[0..5], "token");
                credential.access_token_length = 5;
            }
            return disposition;
        }
    };
    const TransportFixture = struct {
        fn perform(
            _: *anyopaque,
            _: *const Credential,
            _: model_operation.RequestCursor,
            _: *Capture,
        ) anyerror!TransportResult {
            return error.InjectedHostCandidateFailure;
        }
    };
    var output: TestCandidate = .{};
    var authorization: AuthorizationFixture = .{};
    var transport: u8 = 0;
    var provider: CodexProvider = .{
        .authorization = .{ .context = &authorization, .load_fn = AuthorizationFixture.load },
        .transport = .{ .context = &transport, .perform_fn = TransportFixture.perform },
    };
    try std.testing.expectError(
        error.InjectedHostAuthorizationFailure,
        CodexProvider.dispatch(&provider, undefined, output.capture().candidate.?),
    );

    authorization.disposition = .ready;
    try std.testing.expectError(
        error.InjectedHostCandidateFailure,
        CodexProvider.dispatch(&provider, undefined, output.capture().candidate.?),
    );

    authorization.disposition = .failed;
    const captured = try CodexProvider.dispatch(&provider, undefined, output.capture().candidate.?);
    try std.testing.expectEqual(model_protocol.Failure.provider_error, captured.failure.failure);
}

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
        (try unknown.publish()).failure.failure,
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
        try std.testing.expectEqual(case.expected, (try capture.publish()).failure.failure);
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

    var coalesced_output: TestCandidate = .{};
    var coalesced = coalesced_output.capture();
    coalesced.total_sse_bytes = max_total_sse_bytes - terminal.len;
    try coalesced.appendSse(terminal ++ "trailing bytes beyond the stream budget");
    try std.testing.expect(coalesced.completed);
    try std.testing.expectEqual(max_total_sse_bytes, coalesced.total_sse_bytes);

    var partitioned_output: TestCandidate = .{};
    var partitioned = partitioned_output.capture();
    partitioned.total_sse_bytes = max_total_sse_bytes - terminal.len;
    try partitioned.appendSse(terminal);
    try partitioned.appendSse("trailing bytes beyond the stream budget");
    try std.testing.expect(partitioned.completed);
    try std.testing.expectEqual(coalesced.total_sse_bytes, partitioned.total_sse_bytes);
}

test "every two-chunk partition produces byte-identical captured evidence" {
    const stream = "data: {\"future_event\":{\"nested\":[1,true,null]},\"type\":\"response.output_item.done\",\"item\":{\"future_item\":42,\"content\":[{\"text\":{\"future\":true},\"type\":\"future_annotation\"},{\"future_part\":[\"ignored\"],\"text\":\"quote\\\" slash\\\\ emoji \\uD83D\\uDE00\",\"type\":\"output_text\"}],\"role\":\"assistant\",\"type\":\"message\"}}\n\n" ++
        "data: {\"future_terminal\":false,\"response\":{\"future_response\":{},\"status\":\"completed\"},\"type\":\"response.completed\"}\n\n";
    var expected_output: TestCandidate = .{};
    var expected = expected_output.capture();
    try expected.appendSse(stream);
    expected.finishSse();
    try std.testing.expect(!expected.malformed);
    for (0..stream.len + 1) |split_at| {
        var actual_output: TestCandidate = .{};
        var actual = actual_output.capture();
        try actual.appendSse(stream[0..split_at]);
        try actual.appendSse(stream[split_at..]);
        actual.finishSse();
        try std.testing.expect(!actual.malformed);
        try std.testing.expectEqualSlices(
            u8,
            expected_output.bytes[0..expected_output.length],
            actual_output.bytes[0..actual_output.length],
        );
    }
    var canonical: [model_protocol.max_response_size]u8 = undefined;
    const encoded = try model_protocol.encodeText(&canonical, "quote\" slash\\ emoji 😀");
    try std.testing.expectEqualSlices(
        u8,
        encoded,
        expected_output.bytes[0..expected_output.length],
    );
}

test "capture accepts the exact decoded text bound and types one byte over as oversized" {
    const prefix = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"";
    const suffix = "\"}]}}\n\ndata: {\"type\":\"response.completed\"}\n\n";
    var wire: [max_sse_frame_size + 256]u8 = undefined;
    for ([_]usize{ model_protocol.max_assistant_text_size, model_protocol.max_assistant_text_size + 1 }) |length| {
        var writer = std.Io.Writer.fixed(&wire);
        try writer.writeAll(prefix);
        for (0..length) |_| try writer.writeByte('a');
        try writer.writeAll(suffix);
        var output: TestCandidate = .{};
        var capture = output.capture();
        try capture.appendSse(writer.buffered());
        capture.finishSse();
        const outcome = try capture.publish();
        if (length == model_protocol.max_assistant_text_size) {
            try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, outcome);
        } else {
            try std.testing.expectEqual(model_protocol.Failure.oversized, outcome.failure.failure);
        }
    }
}

test "escape amplification is bounded by wire frame rather than decoded result size" {
    const prefix = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"";
    const suffix = "\"}]}}\n\ndata: {\"type\":\"response.completed\"}\n\n";
    var wire: [max_sse_frame_size]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wire);
    try writer.writeAll(prefix);
    for (0..model_protocol.max_assistant_text_size) |_| try writer.writeAll("\\u0061");
    try writer.writeAll(suffix);
    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse(writer.buffered());
    capture.finishSse();
    try std.testing.expect(!capture.malformed);
    var scratch: model_protocol.ValidationScratch = .{};
    const parsed = try model_protocol.decode(&scratch, output.bytes[0..output.length]);
    try std.testing.expectEqual(model_protocol.max_assistant_text_size, parsed.text_length);
}

test "capture rejects malformed escapes surrogates and excessive nesting" {
    const malformed = [_][]const u8{
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"bad\\x\"}]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"bad\\uD800\"}]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"bad\\u12\"}]}}\n\n",
    };
    for (malformed) |stream| {
        var output: TestCandidate = .{};
        var capture = output.capture();
        try capture.appendSse(stream);
        try std.testing.expect(capture.malformed);
    }
    var deep: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&deep);
    try writer.writeAll("data: {\"type\":\"ignored\",\"extra\":");
    for (0..max_json_nesting_depth) |_| try writer.writeByte('[');
    try writer.writeAll("0");
    for (0..max_json_nesting_depth) |_| try writer.writeByte(']');
    try writer.writeAll("}\n\n");
    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse(writer.buffered());
    try std.testing.expect(capture.resource_exceeded);

    var invalid_utf8 = [_]u8{
        'd',  'a', 't', 'a',  ':',  ' ', '{', '"', 't', 'y', 'p', 'e', '"', ':', '"',
        'i',  'g', 'n', 'o',  'r',  'e', 'd', '"', ',', '"', 'x', '"', ':', '"', 0xc3,
        0x28, '"', '}', '\n', '\n',
    };
    var utf8_output: TestCandidate = .{};
    var utf8_capture = utf8_output.capture();
    try utf8_capture.appendSse(&invalid_utf8);
    try std.testing.expect(utf8_capture.malformed);
}

test "open provider envelopes ignore bounded unknown metadata without a schema-member cap" {
    var event: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&event);
    try writer.writeAll("data: {\"type\":\"response.created\"");
    for (0..model_contract.max_json_members + 32) |index| {
        try writer.print(",\"metadata_{d}\":null", .{index});
    }
    try writer.writeAll("}\n\n");

    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse(writer.buffered());
    try std.testing.expect(!capture.malformed);
    try std.testing.expect(!capture.resource_exceeded);
    try std.testing.expect(!capture.terminalObserved());
}

test "open provider envelopes ignore colliding fields on unknown events and unsupported items" {
    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse(
        "data: {\"item\":42,\"response\":false,\"type\":\"future.lifecycle\"}\n\n",
    );
    try capture.appendSse(
        "data: {\"item\":{\"content\":{\"future\":true},\"type\":\"reasoning\"},\"type\":\"response.output_item.done\"}\n\n",
    );
    try std.testing.expect(!capture.malformed);
    try std.testing.expect(!capture.resource_exceeded);
    try std.testing.expectEqual(@as(u8, 0), capture.candidate_count);
}

test "recognized provider conversions reject ambiguous consumed fields" {
    const malformed = [_][]const u8{
        "data: {}\n\n",
        "data: {\"type\":\"response.created\",\"type\":\"response.created\"}\n\n",
        "data: {\"type\":\"response.output_item.done\"}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{},\"item\":{}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"type\":\"message\"}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"content\":[]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":42,\"content\":[]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\"}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":{}}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"role\":\"assistant\",\"content\":[]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"content\":[]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\"}]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"type\":\"output_text\",\"text\":\"x\"}]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"x\",\"text\":\"y\"}]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":{}}]}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"arguments\":\"{}\"}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":42,\"arguments\":\"{}\"}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"bash\"}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":{}}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"bash\",\"name\":\"bash\",\"arguments\":\"{}\"}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{}\",\"arguments\":\"{}\"}}\n\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":42}}\n\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"status\":\"completed\"}}\n\n",
    };
    for (malformed) |event| {
        var output: TestCandidate = .{};
        var capture = output.capture();
        try capture.appendSse(event);
        try std.testing.expect(capture.malformed);
        try std.testing.expectEqual(@as(usize, 0), output.length);
    }
}

test "wire and stream bounds are exact" {
    var exact: [max_sse_frame_size]u8 = @splat('x');
    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse(&exact);
    try std.testing.expectEqual(max_sse_frame_size, capture.frame_length);
    try std.testing.expectError(error.SseFrameTooLarge, capture.appendSse("x"));

    var total_output: TestCandidate = .{};
    var total = total_output.capture();
    var ignored: [max_sse_frame_size]u8 = @splat('x');
    ignored[ignored.len - 2] = '\n';
    ignored[ignored.len - 1] = '\n';
    for (0..max_total_sse_bytes / max_sse_frame_size) |_| {
        try total.appendSse(&ignored);
    }
    try std.testing.expectEqual(max_total_sse_bytes, total.total_sse_bytes);
    try std.testing.expectError(error.SseStreamTooLarge, total.appendSse("x"));
}

test "many small reasoning and lifecycle events remain bounded by total wire bytes" {
    const reasoning =
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"x\"}\n\n";
    const lifecycle =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\"}}\n\n";
    var output: TestCandidate = .{};
    var capture = output.capture();
    for (0..256) |index| {
        try capture.appendSse(if (index % 2 == 0) reasoning else lifecycle);
    }
    try capture.appendSse(
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n" ++
            "data: {\"type\":\"response.completed\"}\n\n",
    );
    capture.finishSse();
    try std.testing.expect(capture.total_sse_bytes < max_total_sse_bytes);
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try capture.publish());
    var scratch: model_protocol.ValidationScratch = .{};
    const parsed = try model_protocol.decode(&scratch, output.bytes[0..output.length]);
    try std.testing.expectEqualStrings(
        "done",
        output.bytes[parsed.text_offset..][0..parsed.text_length],
    );
}

test "duplicate response objects are malformed even without nested status" {
    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse(
        "data: {\"type\":\"response.completed\",\"response\":{},\"response\":{}}\n\n",
    );
    try std.testing.expect(capture.malformed);
}

test "candidate writer failures escape capture as Host errors" {
    const FailingCandidate = struct {
        fn append(_: *anyopaque, _: []const u8) anyerror!void {
            return error.InjectedHostStorageFailure;
        }
    };
    var context: u8 = 0;
    var capture: Capture = .{ .candidate = .{
        .context = &context,
        .append_fn = FailingCandidate.append,
    } };
    try std.testing.expectError(
        error.InjectedHostStorageFailure,
        capture.appendSse(
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n",
        ),
    );
    try std.testing.expect(!capture.malformed);
    try std.testing.expect(!capture.resource_exceeded);
}

test "input request arguments require the exact closed shape" {
    const valid = [_][]const u8{
        "{\"prompt\":\"Explain\",\"response_type\":\"text\",\"choices\":[]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"Alpha\"}]}",
        "{\"choices\":[{\"label\":\"Caf\\u00e9 \\uD83D\\uDE00\",\"id\":\"a\\\"b\"}],\"response_type\":\"single_choice\",\"prompt\":\"Say \\\"hi\\\"\"}",
    };
    for (valid) |arguments| {
        var output: TestCandidate = .{};
        var capture = output.capture();
        var mutable: [16 * 1024]u8 = undefined;
        @memcpy(mutable[0..arguments.len], arguments);
        try capture.captureInputRequest(mutable[0..arguments.len]);
        try std.testing.expect(output.length != 0);
    }
    const invalid = [_][]const u8{
        "{\"prompt\":\"Explain\",\"response_type\":\"text\"}",
        "{\"prompt\":\"Explain\",\"response_type\":\"text\",\"choices\":[],\"extra\":true}",
        "{\"prompt\":\"Explain\",\"prompt\":\"Again\",\"response_type\":\"text\",\"choices\":[]}",
        "{\"prompt\":42,\"response_type\":\"text\",\"choices\":[]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"\",\"label\":\"Alpha\"}]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"\"}]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\"}]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"Alpha\",\"extra\":true}]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"Alpha\"},{\"id\":\"a\",\"label\":\"Again\"}]}",
        "{\"prompt\":\"Choose\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"a\",\"label\":\"\\uD800\"}]}",
        "{\"prompt\":\"Explain\",\"response_type\":\"text\",\"choices\":[]} trailing",
    };
    for (invalid) |arguments| {
        var output: TestCandidate = .{};
        var capture = output.capture();
        var mutable: [16 * 1024]u8 = undefined;
        @memcpy(mutable[0..arguments.len], arguments);
        try capture.captureInputRequest(mutable[0..arguments.len]);
        try std.testing.expect(capture.malformed or capture.resource_exceeded);
        try std.testing.expectEqual(@as(usize, 0), output.length);
        capture.completed = true;
        capture.terminal_count = 1;
        capture.terminal_status = .completed;
        capture.candidate_count = 1;
        const outcome = try capture.publish();
        try std.testing.expectEqual(
            if (capture.resource_exceeded) model_protocol.Failure.oversized else .malformed,
            outcome.failure.failure,
        );
    }
}

test "input request semantic bounds publish one typed oversized outcome" {
    const Field = enum { prompt, choice_id, choice_label };
    const cases = [_]struct { field: Field, length: usize }{
        .{ .field = .prompt, .length = model_contract.max_prompt_size + 1 },
        .{ .field = .choice_id, .length = model_contract.max_choice_id_size + 1 },
        .{ .field = .choice_label, .length = model_contract.max_choice_label_size + 1 },
    };
    for (cases) |case| {
        var arguments: [16 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&arguments);
        try writer.writeAll("{\"prompt\":\"");
        if (case.field == .prompt) {
            for (0..case.length) |_| try writer.writeByte('p');
        } else try writer.writeAll("Choose");
        try writer.writeAll("\",\"response_type\":\"single_choice\",\"choices\":[{\"id\":\"");
        if (case.field == .choice_id) {
            for (0..case.length) |_| try writer.writeByte('i');
        } else try writer.writeAll("a");
        try writer.writeAll("\",\"label\":\"");
        if (case.field == .choice_label) {
            for (0..case.length) |_| try writer.writeByte('l');
        } else try writer.writeAll("Alpha");
        try writer.writeAll("\"}]}");

        var output: TestCandidate = .{};
        var capture = output.capture();
        try capture.captureInputRequest(writer.buffered());
        capture.completed = true;
        capture.terminal_count = 1;
        capture.terminal_status = .completed;
        capture.candidate_count = 1;
        const outcome = try capture.publish();
        try std.testing.expectEqual(model_protocol.Failure.oversized, outcome.failure.failure);
        try std.testing.expectEqual(@as(usize, 0), output.length);
    }
}

test "duplicate input choice IDs publish one typed malformed provider outcome" {
    var output: TestCandidate = .{};
    var capture = output.capture();
    try capture.appendSse(
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"onepage_input_request\",\"arguments\":\"{\\\"prompt\\\":\\\"Choose\\\",\\\"response_type\\\":\\\"single_choice\\\",\\\"choices\\\":[{\\\"id\\\":\\\"same\\\",\\\"label\\\":\\\"First\\\"},{\\\"id\\\":\\\"same\\\",\\\"label\\\":\\\"Second\\\"}]}\"}}\n\n" ++
            "data: {\"type\":\"response.completed\"}\n\n",
    );

    const outcome = try capture.publish();
    try std.testing.expectEqual(model_protocol.Failure.malformed, outcome.failure.failure);
    try std.testing.expectEqual(@as(usize, 0), output.length);
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
