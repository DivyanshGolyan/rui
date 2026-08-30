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
/// JSON string escaping can expand one decoded byte to six wire bytes. This is
/// a counted compatibility and work limit, not a resident buffer size.
pub const max_sse_event_bytes: usize = 6 * model_protocol.max_response_size + 8192;
pub const max_total_sse_bytes: usize = 4 * max_sse_event_bytes;
pub const sse_projection_window_size: usize = 4096;
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
    allocator: std.mem.Allocator = std.heap.page_allocator,
    authorization: Authorization,
    transport: Transport,
    capture_metrics: ?*CaptureMetrics = null,

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

        var capture = Capture.init(self.allocator, candidate);
        defer capture.deinit();
        defer if (self.capture_metrics) |metrics| metrics.observe(&capture);
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

pub const CaptureMetrics = struct {
    dispatch_count: usize = 0,
    decoded_occupied_high_water_bytes: usize = 0,
    decoded_capacity_high_water_bytes: usize = 0,
    assistant_text_occupied_high_water_bytes: usize = 0,
    assistant_text_capacity_high_water_bytes: usize = 0,
    tool_arguments_occupied_high_water_bytes: usize = 0,
    tool_arguments_capacity_high_water_bytes: usize = 0,

    fn observe(self: *CaptureMetrics, capture: *const Capture) void {
        self.dispatch_count +|= 1;
        self.decoded_occupied_high_water_bytes = @max(
            self.decoded_occupied_high_water_bytes,
            capture.decoded_occupied_high_water,
        );
        self.decoded_capacity_high_water_bytes = @max(
            self.decoded_capacity_high_water_bytes,
            capture.decoded_capacity_high_water,
        );
        self.assistant_text_occupied_high_water_bytes = @max(
            self.assistant_text_occupied_high_water_bytes,
            capture.text.high_water_length,
        );
        self.assistant_text_capacity_high_water_bytes = @max(
            self.assistant_text_capacity_high_water_bytes,
            capture.text.high_water_capacity,
        );
        self.tool_arguments_occupied_high_water_bytes = @max(
            self.tool_arguments_occupied_high_water_bytes,
            capture.arguments.high_water_length,
        );
        self.tool_arguments_capacity_high_water_bytes = @max(
            self.tool_arguments_capacity_high_water_bytes,
            capture.arguments.high_water_capacity,
        );
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

const max_json_nesting_depth: usize = 32;

const SseLineState = enum { prefix, after_data_colon, data, discard };
const SelectedCandidate = enum { none, text, tool, input };
const DiscardScalar = enum { none, string, number };
const ContextKind = enum { root_object, response_object, item_object, content_array, content_object };
const JsonField = enum {
    unknown,
    root_type,
    root_response,
    root_item,
    response_status,
    item_type,
    item_role,
    item_content,
    item_name,
    item_arguments,
    content_type,
    content_text,
};
const StringTarget = enum {
    none,
    discard,
    key,
    event_type,
    response_status,
    item_type,
    role,
    name,
    content_type,
    text,
    arguments,
};

const FieldStatus = struct {
    seen: bool = false,
    duplicate: bool = false,
    wrong_type: bool = false,

    fn valid(self: FieldStatus) bool {
        return self.seen and !self.duplicate and !self.wrong_type;
    }

    fn validOptional(self: FieldStatus) bool {
        return !self.duplicate and !self.wrong_type;
    }
};

fn BoundedString(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        length: usize = 0,
        seen: bool = false,
        duplicate: bool = false,
        wrong_type: bool = false,
        overflowed: bool = false,

        fn append(self: *@This(), bytes: []const u8) void {
            if (bytes.len > self.bytes.len -| self.length) {
                self.overflowed = true;
                return;
            }
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }

        fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.length];
        }

        fn valid(self: @This()) bool {
            return self.seen and !self.duplicate and !self.wrong_type and !self.overflowed;
        }

        fn validOptional(self: @This()) bool {
            return !self.duplicate and !self.wrong_type and !self.overflowed;
        }

        fn reset(self: *@This()) void {
            self.* = .{};
        }
    };
}

const CappedBytes = struct {
    items: std.ArrayList(u8) = .empty,
    overflowed: bool = false,
    high_water_length: usize = 0,
    high_water_capacity: usize = 0,

    fn append(
        self: *CappedBytes,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        maximum: usize,
    ) !void {
        if (self.overflowed) return;
        const new_length = std.math.add(usize, self.items.items.len, bytes.len) catch {
            self.overflowed = true;
            return;
        };
        if (new_length > maximum) {
            self.overflowed = true;
            return;
        }
        if (new_length > self.items.capacity) {
            const growth = if (self.items.capacity == 0)
                @as(usize, 64)
            else
                std.math.mul(usize, self.items.capacity, 2) catch maximum;
            const next_capacity = @min(maximum, @max(new_length, growth));
            try self.items.ensureTotalCapacityPrecise(allocator, next_capacity);
            self.high_water_capacity = @max(self.high_water_capacity, self.items.capacity);
        }
        self.items.appendSliceAssumeCapacity(bytes);
        self.high_water_length = @max(self.high_water_length, self.items.items.len);
    }

    fn clearRetainingCapacity(self: *CappedBytes) void {
        self.items.clearRetainingCapacity();
        self.overflowed = false;
    }

    fn deinit(self: *CappedBytes, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }
};

const SemanticContext = struct {
    kind: ContextKind,
    expect_key: bool,
    field: JsonField = .unknown,
};

const EventProjection = struct {
    contexts: [max_json_nesting_depth]SemanticContext = undefined,
    context_count: usize = 0,
    root_seen: bool = false,
    root_closed: bool = false,
    document_finished: bool = false,
    syntax_invalid: bool = false,
    structure_invalid: bool = false,
    capture_values: bool = false,
    parser_steps: usize = 0,
    skip_depth: usize = 0,
    discard_scalar: DiscardScalar = .none,
    string_target: StringTarget = .none,
    key: BoundedString(32) = .{},
    event_type: BoundedString(128) = .{},
    response_field: FieldStatus = .{},
    response_status: BoundedString(32) = .{},
    item_field: FieldStatus = .{},
    item_type: BoundedString(64) = .{},
    role: BoundedString(32) = .{},
    content_field: FieldStatus = .{},
    name: BoundedString(model_contract.max_provider_tool_name_size) = .{},
    arguments_field: FieldStatus = .{},
    content_type: BoundedString(64) = .{},
    content_text_field: FieldStatus = .{},
    output_text_count: u8 = 0,
    content_shape_invalid: bool = false,
    unsupported_content: bool = false,
};

fn classifyField(kind: ContextKind, key: []const u8) JsonField {
    return switch (kind) {
        .root_object => if (std.mem.eql(u8, key, "type"))
            .root_type
        else if (std.mem.eql(u8, key, "response"))
            .root_response
        else if (std.mem.eql(u8, key, "item"))
            .root_item
        else
            .unknown,
        .response_object => if (std.mem.eql(u8, key, "status")) .response_status else .unknown,
        .item_object => if (std.mem.eql(u8, key, "type"))
            .item_type
        else if (std.mem.eql(u8, key, "role"))
            .item_role
        else if (std.mem.eql(u8, key, "content"))
            .item_content
        else if (std.mem.eql(u8, key, "name"))
            .item_name
        else if (std.mem.eql(u8, key, "arguments"))
            .item_arguments
        else
            .unknown,
        .content_object => if (std.mem.eql(u8, key, "type"))
            .content_type
        else if (std.mem.eql(u8, key, "text"))
            .content_text
        else
            .unknown,
        .content_array => .unknown,
    };
}

fn isStringToken(token: std.json.Token) bool {
    return switch (token) {
        .string, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => true,
        else => false,
    };
}

fn ignoredEventType(event_type: []const u8) bool {
    const ignored = [_][]const u8{
        "response.created",
        "response.in_progress",
        "response.output_item.added",
        "response.content_part.added",
        "response.output_text.delta",
        "response.output_text.done",
        "response.content_part.done",
        "response.function_call_arguments.delta",
        "response.function_call_arguments.done",
        "response.reasoning_summary_text.delta",
        "response.reasoning_summary_text.done",
        "response.reasoning_summary_part.added",
        "response.reasoning_summary_part.done",
        "response.reasoning_text.delta",
        "response.reasoning_text.done",
        "response.refusal.delta",
        "response.refusal.done",
    };
    for (ignored) |known| if (std.mem.eql(u8, event_type, known)) return true;
    return false;
}

pub const Capture = struct {
    allocator: std.mem.Allocator,
    candidate: ?model_operation.CandidateWriter,
    scanner: std.json.Scanner = undefined,
    scanner_initialized: bool = false,
    parser_dead: bool = false,
    projection_window: [sse_projection_window_size]u8 = undefined,
    projection_length: usize = 0,
    marker_probe: ["[DONE]".len]u8 = undefined,
    marker_probe_length: usize = 0,
    marker_diverged: bool = false,
    line_state: SseLineState = .prefix,
    line_prefix_length: u8 = 0,
    line_nonempty: bool = false,
    data_line_started: bool = false,
    data_seen: bool = false,
    pending_cr: bool = false,
    event_wire_bytes: usize = 0,
    event: EventProjection = .{},
    text: CappedBytes = .{},
    arguments: CappedBytes = .{},
    selected: SelectedCandidate = .none,
    selected_tool_key: [model_contract.max_tool_key_size]u8 = undefined,
    selected_tool_key_length: u8 = 0,
    candidate_failure: model_protocol.Failure = .none,
    mapping: ToolMapping = .{},
    candidate_count: u8 = 0,
    terminal_count: u8 = 0,
    terminal_status: TerminalStatus = .none,
    completed: bool = false,
    malformed: bool = false,
    resource_exceeded: bool = false,
    total_sse_bytes: usize = 0,
    projected_json_bytes: usize = 0,
    parser_steps: usize = 0,
    decoded_occupied_high_water: usize = 0,
    decoded_capacity_high_water: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        candidate: ?model_operation.CandidateWriter,
    ) Capture {
        return .{ .allocator = allocator, .candidate = candidate };
    }

    pub fn deinit(self: *Capture) void {
        if (self.scanner_initialized) self.scanner.deinit();
        self.text.deinit(self.allocator);
        self.arguments.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn requestSink(self: *Capture) ByteSink {
        return .{ .context = self, .write_fn = discardRequestBytes };
    }

    fn discardRequestBytes(_: *anyopaque, _: []const u8) anyerror!void {}

    pub fn appendSse(self: *Capture, bytes: []const u8) !void {
        if (self.completed) return;
        for (bytes) |byte| {
            try self.chargeWireByte();
            if (self.pending_cr) {
                self.pending_cr = false;
                try self.finishLine();
                if (self.completed) return;
                if (byte == '\n') continue;
            }
            if (byte == '\r') {
                self.pending_cr = true;
            } else if (byte == '\n') {
                try self.finishLine();
                if (self.completed) return;
            } else {
                try self.consumeLineByte(byte);
            }
        }
    }

    fn chargeWireByte(self: *Capture) !void {
        self.total_sse_bytes = std.math.add(usize, self.total_sse_bytes, 1) catch
            return self.exceeded(error.SseStreamTooLarge);
        if (self.total_sse_bytes > max_total_sse_bytes) {
            return self.exceeded(error.SseStreamTooLarge);
        }
        self.event_wire_bytes = std.math.add(usize, self.event_wire_bytes, 1) catch
            return self.exceeded(error.SseEventTooLarge);
        if (self.event_wire_bytes > max_sse_event_bytes) {
            return self.exceeded(error.SseEventTooLarge);
        }
    }

    fn consumeLineByte(self: *Capture, byte: u8) !void {
        self.line_nonempty = true;
        switch (self.line_state) {
            .prefix => {
                const prefix = "data:";
                if (self.line_prefix_length < prefix.len and
                    byte == prefix[self.line_prefix_length])
                {
                    self.line_prefix_length += 1;
                    if (self.line_prefix_length == prefix.len) self.line_state = .after_data_colon;
                } else {
                    self.line_state = .discard;
                }
            },
            .after_data_colon => {
                try self.beginDataLine();
                self.line_state = .data;
                if (byte != ' ') try self.projectByte(byte);
            },
            .data => try self.projectByte(byte),
            .discard => {},
        }
    }

    fn beginDataLine(self: *Capture) !void {
        if (self.data_line_started) return;
        if (!self.scanner_initialized and !self.marker_diverged and self.marker_probe_length == 0) {
            self.startEventParser() catch |err| return err;
        }
        if (self.data_seen) try self.projectByte('\n');
        self.data_seen = true;
        self.data_line_started = true;
    }

    fn finishLine(self: *Capture) !void {
        if (!self.line_nonempty) {
            if (self.data_seen) try self.finishEvent();
            self.resetLine();
            self.event_wire_bytes = 0;
            return;
        }
        if (self.line_state == .after_data_colon) try self.beginDataLine();
        self.resetLine();
    }

    fn resetLine(self: *Capture) void {
        self.line_state = .prefix;
        self.line_prefix_length = 0;
        self.line_nonempty = false;
        self.data_line_started = false;
    }

    fn startEventParser(self: *Capture) !void {
        std.debug.assert(!self.scanner_initialized);
        self.event = .{ .capture_values = self.candidate_count == 0 };
        if (self.event.capture_values) {
            self.text.clearRetainingCapacity();
            self.arguments.clearRetainingCapacity();
        }
        self.scanner = std.json.Scanner.initStreaming(self.allocator);
        errdefer self.scanner.deinit();
        try self.scanner.ensureTotalStackCapacity(max_json_nesting_depth);
        self.scanner_initialized = true;
        self.parser_dead = false;
    }

    fn projectByte(self: *Capture, byte: u8) !void {
        const marker = "[DONE]";
        if (!self.marker_diverged) {
            if (self.marker_probe_length < marker.len and
                byte == marker[self.marker_probe_length])
            {
                self.marker_probe[self.marker_probe_length] = byte;
                self.marker_probe_length += 1;
                return;
            }
            self.marker_diverged = true;
            try self.appendProjection(self.marker_probe[0..self.marker_probe_length]);
        }
        try self.appendProjection(&.{byte});
    }

    fn appendProjection(self: *Capture, bytes: []const u8) !void {
        if (self.parser_dead) return;
        self.projected_json_bytes = std.math.add(
            usize,
            self.projected_json_bytes,
            bytes.len,
        ) catch return self.exceeded(error.SseStreamTooLarge);
        var remaining = bytes;
        while (remaining.len != 0) {
            const count = @min(remaining.len, self.projection_window.len - self.projection_length);
            @memcpy(self.projection_window[self.projection_length..][0..count], remaining[0..count]);
            self.projection_length += count;
            remaining = remaining[count..];
            if (self.projection_length == self.projection_window.len) try self.flushProjection();
        }
    }

    fn flushProjection(self: *Capture) !void {
        if (self.projection_length == 0 or self.parser_dead) {
            self.projection_length = 0;
            return;
        }
        self.scanner.feedInput(self.projection_window[0..self.projection_length]);
        self.projection_length = 0;
        try self.drainScanner(false);
    }

    fn finishEvent(self: *Capture) !void {
        const is_done_marker = !self.marker_diverged and
            self.marker_probe_length == "[DONE]".len;
        if (!is_done_marker) {
            if (!self.marker_diverged) {
                self.marker_diverged = true;
                try self.appendProjection(self.marker_probe[0..self.marker_probe_length]);
            }
            try self.flushProjection();
            if (!self.parser_dead) {
                self.scanner.endInput();
                try self.drainScanner(true);
            }
            if (!self.event.document_finished) self.event.syntax_invalid = true;
            try self.finalizeEvent();
        }
        self.resetEventParser();
    }

    fn resetEventParser(self: *Capture) void {
        if (self.scanner_initialized) self.scanner.deinit();
        self.scanner_initialized = false;
        self.parser_dead = false;
        self.projection_length = 0;
        self.marker_probe_length = 0;
        self.marker_diverged = false;
        self.data_seen = false;
        self.event = .{};
    }

    fn drainScanner(self: *Capture, end_of_input: bool) !void {
        while (!self.parser_dead) {
            const token = self.scanner.next() catch |err| switch (err) {
                error.BufferUnderrun => {
                    if (end_of_input) {
                        self.event.syntax_invalid = true;
                        self.parser_dead = true;
                    }
                    return;
                },
                error.OutOfMemory => return err,
                else => {
                    self.event.syntax_invalid = true;
                    self.parser_dead = true;
                    return;
                },
            };
            self.event.parser_steps +|= 1;
            self.parser_steps +|= 1;
            if (self.scanner.stackHeight() > max_json_nesting_depth) {
                self.resource_exceeded = true;
                self.parser_dead = true;
                return;
            }
            try self.consumeJsonToken(token);
            if (token == .end_of_document) {
                self.event.document_finished = true;
                return;
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
        if (self.pending_cr) {
            self.pending_cr = false;
            self.finishLine() catch {
                self.malformed = true;
            };
        }
        if (self.line_nonempty or self.data_seen or self.scanner_initialized or
            !self.completed or self.terminal_count != 1)
        {
            self.malformed = true;
        }
    }

    fn consumeJsonToken(self: *Capture, token: std.json.Token) !void {
        if (self.event.string_target != .none) {
            return self.consumeStringToken(token);
        }
        if (self.event.discard_scalar != .none) {
            return self.consumeDiscardScalar(token);
        }
        if (self.event.skip_depth != 0) {
            switch (token) {
                .object_begin, .array_begin => self.event.skip_depth += 1,
                .object_end, .array_end => {
                    self.event.skip_depth -= 1;
                    if (self.event.skip_depth == 0) self.completeParentValue();
                },
                else => {},
            }
            return;
        }
        if (self.event.context_count == 0) {
            if (token == .object_begin and !self.event.root_seen) {
                self.event.root_seen = true;
                self.pushContext(.root_object);
            } else if (token != .end_of_document) {
                self.event.structure_invalid = true;
                try self.skipTokenValue(token);
            }
            return;
        }

        const context = &self.event.contexts[self.event.context_count - 1];
        switch (context.kind) {
            .root_object, .response_object, .item_object, .content_object => {
                if (context.expect_key) {
                    if (token == .object_end) return self.closeContext();
                    return self.beginStringToken(token, .key);
                }
                try self.consumeFieldValue(context.field, token);
            },
            .content_array => {
                if (token == .array_end) return self.closeContext();
                if (token == .object_begin) {
                    self.beginContentObject();
                    self.pushContext(.content_object);
                } else {
                    self.event.content_shape_invalid = true;
                    try self.skipTokenValue(token);
                }
            },
        }
    }

    fn skipTokenValue(self: *Capture, token: std.json.Token) !void {
        switch (token) {
            .object_begin, .array_begin => self.event.skip_depth = 1,
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => self.event.discard_scalar = .string,
            .partial_number => self.event.discard_scalar = .number,
            .string, .number, .true, .false, .null => self.completeParentValue(),
            else => self.event.structure_invalid = true,
        }
    }

    fn consumeDiscardScalar(self: *Capture, token: std.json.Token) void {
        switch (self.event.discard_scalar) {
            .string => switch (token) {
                .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
                .string => {
                    self.event.discard_scalar = .none;
                    self.completeParentValue();
                },
                else => self.event.syntax_invalid = true,
            },
            .number => switch (token) {
                .partial_number => {},
                .number => {
                    self.event.discard_scalar = .none;
                    self.completeParentValue();
                },
                else => self.event.syntax_invalid = true,
            },
            .none => unreachable,
        }
    }

    fn beginStringToken(self: *Capture, token: std.json.Token, target: StringTarget) !void {
        self.event.string_target = target;
        if (target == .key) self.event.key.reset();
        try self.consumeStringToken(token);
    }

    fn consumeStringToken(self: *Capture, token: std.json.Token) !void {
        const final = switch (token) {
            .string => true,
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => false,
            else => {
                self.event.syntax_invalid = true;
                self.event.string_target = .none;
                return;
            },
        };
        const bytes: []const u8 = switch (token) {
            .string, .partial_string => |value| value,
            .partial_string_escaped_1 => |value| value[0..],
            .partial_string_escaped_2 => |value| value[0..],
            .partial_string_escaped_3 => |value| value[0..],
            .partial_string_escaped_4 => |value| value[0..],
            else => unreachable,
        };
        switch (self.event.string_target) {
            .key => self.event.key.append(bytes),
            .event_type => self.event.event_type.append(bytes),
            .response_status => self.event.response_status.append(bytes),
            .item_type => self.event.item_type.append(bytes),
            .role => self.event.role.append(bytes),
            .name => self.event.name.append(bytes),
            .content_type => self.event.content_type.append(bytes),
            .text => try self.text.append(self.allocator, bytes, model_protocol.max_assistant_text_size),
            .arguments => try self.arguments.append(
                self.allocator,
                bytes,
                model_contract.max_tool_arguments_envelope_size,
            ),
            .discard => {},
            .none => unreachable,
        }
        self.noteDecodedBuffers();
        if (!final) return;
        const target = self.event.string_target;
        self.event.string_target = .none;
        if (target == .key) {
            const context = &self.event.contexts[self.event.context_count - 1];
            context.field = classifyField(context.kind, self.event.key.slice());
            context.expect_key = false;
        } else {
            self.completeParentValue();
        }
    }

    fn noteDecodedBuffers(self: *Capture) void {
        self.decoded_occupied_high_water = @max(
            self.decoded_occupied_high_water,
            self.text.items.items.len + self.arguments.items.items.len,
        );
        self.decoded_capacity_high_water = @max(
            self.decoded_capacity_high_water,
            self.text.items.capacity + self.arguments.items.capacity,
        );
    }

    fn consumeFieldValue(self: *Capture, field: JsonField, token: std.json.Token) !void {
        switch (field) {
            .root_type => try self.consumeBoundedString(token, .event_type, &self.event.event_type),
            .response_status => try self.consumeBoundedString(
                token,
                .response_status,
                &self.event.response_status,
            ),
            .item_type => try self.consumeBoundedString(token, .item_type, &self.event.item_type),
            .item_role => try self.consumeBoundedString(token, .role, &self.event.role),
            .item_name => try self.consumeBoundedString(token, .name, &self.event.name),
            .content_type => try self.consumeBoundedString(
                token,
                .content_type,
                &self.event.content_type,
            ),
            .item_arguments => try self.consumeDynamicString(
                token,
                .arguments,
                &self.event.arguments_field,
                self.event.capture_values,
            ),
            .content_text => try self.consumeDynamicString(
                token,
                .text,
                &self.event.content_text_field,
                self.event.capture_values and self.event.output_text_count == 0 and
                    (!self.event.content_type.seen or
                        std.mem.eql(u8, self.event.content_type.slice(), "output_text")),
            ),
            .root_response => try self.consumeContainerField(
                token,
                .object_begin,
                .response_object,
                &self.event.response_field,
            ),
            .root_item => try self.consumeContainerField(
                token,
                .object_begin,
                .item_object,
                &self.event.item_field,
            ),
            .item_content => try self.consumeContainerField(
                token,
                .array_begin,
                .content_array,
                &self.event.content_field,
            ),
            .unknown => try self.skipTokenValue(token),
        }
    }

    fn consumeBoundedString(
        self: *Capture,
        token: std.json.Token,
        target: StringTarget,
        field: anytype,
    ) !void {
        if (field.seen) {
            field.duplicate = true;
            self.event.string_target = .discard;
            return self.consumeStringToken(token);
        }
        field.seen = true;
        if (!isStringToken(token)) {
            field.wrong_type = true;
            return self.skipTokenValue(token);
        }
        field.length = 0;
        try self.beginStringToken(token, target);
    }

    fn consumeDynamicString(
        self: *Capture,
        token: std.json.Token,
        target: StringTarget,
        field: *FieldStatus,
        retain: bool,
    ) !void {
        if (field.seen) {
            field.duplicate = true;
            self.event.string_target = .discard;
            return self.consumeStringToken(token);
        }
        field.seen = true;
        if (!isStringToken(token)) {
            field.wrong_type = true;
            return self.skipTokenValue(token);
        }
        try self.beginStringToken(token, if (retain) target else .discard);
    }

    fn consumeContainerField(
        self: *Capture,
        token: std.json.Token,
        expected: std.meta.Tag(std.json.Token),
        child: ContextKind,
        field: *FieldStatus,
    ) !void {
        if (field.seen) {
            field.duplicate = true;
            return self.skipTokenValue(token);
        }
        field.seen = true;
        if (std.meta.activeTag(token) != expected) {
            field.wrong_type = true;
            return self.skipTokenValue(token);
        }
        self.pushContext(child);
    }

    fn pushContext(self: *Capture, kind: ContextKind) void {
        if (self.event.context_count == self.event.contexts.len) {
            self.resource_exceeded = true;
            self.parser_dead = true;
            return;
        }
        self.event.contexts[self.event.context_count] = .{
            .kind = kind,
            .expect_key = kind != .content_array,
        };
        self.event.context_count += 1;
    }

    fn closeContext(self: *Capture) void {
        const kind = self.event.contexts[self.event.context_count - 1].kind;
        if (kind == .content_object) self.finishContentObject();
        self.event.context_count -= 1;
        if (self.event.context_count == 0) {
            self.event.root_closed = true;
        } else {
            self.completeParentValue();
        }
    }

    fn completeParentValue(self: *Capture) void {
        if (self.event.context_count == 0) return;
        const context = &self.event.contexts[self.event.context_count - 1];
        switch (context.kind) {
            .root_object, .response_object, .item_object, .content_object => {
                context.expect_key = true;
                context.field = .unknown;
            },
            .content_array => {},
        }
    }

    fn beginContentObject(self: *Capture) void {
        self.event.content_type = .{};
        self.event.content_text_field = .{};
        if (self.event.output_text_count == 0 and self.event.capture_values) {
            self.text.clearRetainingCapacity();
        }
    }

    fn finishContentObject(self: *Capture) void {
        if (!self.event.content_type.valid()) {
            self.event.content_shape_invalid = true;
            return;
        }
        if (std.mem.eql(u8, self.event.content_type.slice(), "output_text")) {
            self.event.output_text_count +|= 1;
            if (!self.event.content_text_field.valid() or
                (self.event.output_text_count == 1 and self.text.items.items.len == 0))
            {
                self.event.content_shape_invalid = true;
            }
        } else {
            self.event.unsupported_content = true;
            if (self.event.output_text_count == 0 and self.event.capture_values) {
                self.text.clearRetainingCapacity();
            }
        }
    }

    fn finalizeEvent(self: *Capture) !void {
        if (self.event.syntax_invalid or self.event.structure_invalid or
            !self.event.root_seen or !self.event.root_closed or
            !self.event.event_type.valid())
        {
            self.malformed = true;
            return;
        }
        const event_type = self.event.event_type.slice();
        if ((terminalStatus(event_type, null) catch unreachable) != null) {
            if ((self.event.response_field.seen and !self.event.response_field.valid()) or
                !self.event.response_status.validOptional())
            {
                self.malformed = true;
                return;
            }
            const status = (terminalStatus(
                event_type,
                if (self.event.response_status.seen) self.event.response_status.slice() else null,
            ) catch |err| switch (err) {
                error.UnsupportedTerminalStatus => {
                    self.candidate_failure = .unsupported_provider_output;
                    return;
                },
                else => {
                    self.malformed = true;
                    return;
                },
            }).?;
            return self.captureTerminal(status);
        }
        if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            return self.finalizeOutputItem();
        }
        if (ignoredEventType(event_type)) {
            if (self.event.capture_values) {
                self.text.clearRetainingCapacity();
                self.arguments.clearRetainingCapacity();
            }
            return;
        }
        self.candidate_failure = .unsupported_provider_output;
    }

    fn finalizeOutputItem(self: *Capture) !void {
        if (!self.event.item_field.valid() or !self.event.item_type.valid()) {
            self.malformed = true;
            return;
        }
        const item_type = self.event.item_type.slice();
        if (std.mem.eql(u8, item_type, "reasoning")) {
            if (self.event.capture_values) {
                self.text.clearRetainingCapacity();
                self.arguments.clearRetainingCapacity();
            }
            return;
        }
        if (!std.mem.eql(u8, item_type, "message") and
            !std.mem.eql(u8, item_type, "function_call"))
        {
            self.candidate_failure = .unsupported_provider_output;
            return;
        }
        self.candidate_count +|= 1;
        if (self.candidate_count != 1) {
            self.candidate_failure = .multiple_outputs;
            return;
        }
        if (std.mem.eql(u8, item_type, "message")) {
            if (!self.event.role.valid() or
                !std.mem.eql(u8, self.event.role.slice(), "assistant") or
                !self.event.content_field.valid() or self.event.content_shape_invalid or
                self.event.unsupported_content)
            {
                self.candidate_failure = if (self.event.unsupported_content)
                    .unsupported_provider_output
                else
                    .malformed;
                return;
            }
            if (self.event.output_text_count != 1 or self.text.overflowed or
                self.text.items.items.len == 0)
            {
                self.candidate_failure = if (self.text.overflowed) .oversized else .malformed;
                return;
            }
            self.arguments.clearRetainingCapacity();
            self.selected = .text;
            return;
        }

        if (!self.event.name.valid() or !self.event.arguments_field.valid() or
            self.arguments.items.items.len == 0)
        {
            self.candidate_failure = .malformed;
            return;
        }
        if (self.arguments.overflowed) {
            self.candidate_failure = .oversized;
            return;
        }
        const name = self.event.name.slice();
        if (std.mem.eql(u8, name, "onepage_input_request")) {
            self.selected = .input;
        } else if (self.mapping.keyForName(name)) |key| {
            @memcpy(self.selected_tool_key[0..key.len], key);
            self.selected_tool_key_length = @intCast(key.len);
            self.selected = .tool;
        } else {
            self.candidate_failure = .unknown_tool;
        }
        self.text.clearRetainingCapacity();
    }

    fn emitSelected(self: *Capture) !void {
        const writer = self.candidate orelse return error.CandidateWriterMissing;
        switch (self.selected) {
            .none => return error.CandidateMissing,
            .text => try model_protocol.writeText(writer, self.text.items.items),
            .tool => try model_protocol.writeTool(
                writer,
                self.selected_tool_key[0..self.selected_tool_key_length],
                self.arguments.items.items,
            ),
            .input => try self.captureInputRequest(self.arguments.items.items),
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

    fn captureInputRequest(self: *Capture, arguments: []const u8) !void {
        var input = InputRequestProjection.parse(arguments) catch |err| {
            switch (err) {
                error.InputRequestTooLarge, error.JsonNestingTooDeep => {
                    self.resource_exceeded = true;
                },
                else => self.malformed = true,
            }
            return;
        };
        self.parser_steps +|= input.parser_steps;
        if (std.mem.eql(u8, input.response_type.slice(), "text")) {
            if (input.choice_count != 0) {
                self.malformed = true;
                return;
            }
            try model_protocol.writeInputText(
                self.candidate orelse return error.CandidateWriterMissing,
                input.prompt.slice(),
            );
            return;
        }
        if (!std.mem.eql(u8, input.response_type.slice(), "single_choice")) {
            self.malformed = true;
            return;
        }
        if (input.choice_count == 0) {
            self.malformed = true;
            return;
        }
        var choices: [model_contract.max_choice_count]model_protocol.Choice = undefined;
        for (input.choices[0..input.choice_count], 0..) |choice, index| {
            for (choices[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.id, choice.id.slice())) {
                    self.malformed = true;
                    return;
                }
            }
            choices[index] = .{ .id = choice.id.slice(), .label = choice.label.slice() };
        }
        try model_protocol.writeInputChoice(
            self.candidate orelse return error.CandidateWriterMissing,
            input.prompt.slice(),
            choices[0..input.choice_count],
        );
    }

    fn publish(self: *Capture) !model_operation.DispatchOutcome {
        self.finishSse();
        if (self.resource_exceeded) return failureOutcome(.oversized);
        switch (self.terminal_status) {
            .none => return failureOutcome(.truncated),
            .incomplete => return failureOutcome(.truncated),
            .failed => return failureOutcome(.provider_error),
            .cancelled => return failureOutcome(.aborted),
            .completed => {},
        }
        if (self.malformed) return failureOutcome(.malformed);
        if (self.candidate_failure != .none) return failureOutcome(self.candidate_failure);
        if (self.candidate_count != 1) return failureOutcome(.malformed);
        try self.emitSelected();
        if (self.resource_exceeded) return failureOutcome(.oversized);
        if (self.malformed) return failureOutcome(.malformed);
        if (self.candidate_failure != .none) return failureOutcome(self.candidate_failure);
        return .candidate;
    }
};

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
        return error.UnsupportedTerminalStatus;
    if (nested != fallback) return error.ContradictoryTerminalStatus;
    return nested;
}

const InputContextKind = enum { root_object, choices_array, choice_object };
const InputField = enum { unknown, prompt, response_type, choices, choice_id, choice_label };
const InputStringTarget = enum { none, discard, key, prompt, response_type, choice_id, choice_label };

const InputContext = struct {
    kind: InputContextKind,
    expect_key: bool,
    field: InputField = .unknown,
};

const InputChoiceProjection = struct {
    id: BoundedString(model_contract.max_choice_id_size) = .{},
    label: BoundedString(model_contract.max_choice_label_size) = .{},
};

/// Closed semantic projection of the provider-owned input-request argument.
/// The standard scanner validates the complete JSON grammar while only the
/// bounded fields that OnePage consumes are copied into this stack value.
const InputRequestProjection = struct {
    contexts: [max_json_nesting_depth]InputContext = undefined,
    context_count: usize = 0,
    root_seen: bool = false,
    root_closed: bool = false,
    document_finished: bool = false,
    invalid: bool = false,
    too_large: bool = false,
    skip_depth: usize = 0,
    discard_scalar: DiscardScalar = .none,
    string_target: InputStringTarget = .none,
    key: BoundedString(32) = .{},
    prompt: BoundedString(model_contract.max_prompt_size) = .{},
    response_type: BoundedString(32) = .{},
    choices_field: FieldStatus = .{},
    choices: [model_contract.max_choice_count]InputChoiceProjection = undefined,
    choice_count: usize = 0,
    active_choice: ?usize = null,
    parser_steps: usize = 0,

    fn parse(bytes: []const u8) !InputRequestProjection {
        var result: InputRequestProjection = .{};
        var stack_bytes: [256]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&stack_bytes);
        var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
        defer scanner.deinit();
        scanner.ensureTotalStackCapacity(max_json_nesting_depth) catch {
            return error.JsonNestingTooDeep;
        };
        while (true) {
            const token = scanner.next() catch return error.InvalidInputRequest;
            result.parser_steps +|= 1;
            if (scanner.stackHeight() > max_json_nesting_depth) {
                return error.JsonNestingTooDeep;
            }
            try result.consume(token);
            if (token == .end_of_document) break;
        }
        if (!result.document_finished or !result.root_seen or !result.root_closed or
            result.context_count != 0 or result.string_target != .none or
            result.skip_depth != 0 or result.discard_scalar != .none)
        {
            return error.InvalidInputRequest;
        }
        if (result.too_large or result.prompt.overflowed or result.response_type.overflowed) {
            return error.InputRequestTooLarge;
        }
        for (result.choices[0..result.choice_count]) |choice| {
            if (choice.id.overflowed or choice.label.overflowed) {
                return error.InputRequestTooLarge;
            }
        }
        if (result.invalid or !result.prompt.valid() or result.prompt.length == 0 or
            !result.response_type.valid() or !result.choices_field.valid())
        {
            return error.InvalidInputRequest;
        }
        for (result.choices[0..result.choice_count]) |choice| {
            if (!choice.id.valid() or choice.id.length == 0 or
                !choice.label.valid() or choice.label.length == 0)
            {
                return error.InvalidInputRequest;
            }
        }
        return result;
    }

    fn consume(self: *InputRequestProjection, token: std.json.Token) !void {
        if (self.string_target != .none) return self.consumeString(token);
        if (self.discard_scalar != .none) return self.consumeDiscard(token);
        if (self.skip_depth != 0) {
            switch (token) {
                .object_begin, .array_begin => self.skip_depth += 1,
                .object_end, .array_end => {
                    self.skip_depth -= 1;
                    if (self.skip_depth == 0) self.completeParentValue();
                },
                else => {},
            }
            return;
        }
        if (self.context_count == 0) {
            if (token == .object_begin and !self.root_seen) {
                self.root_seen = true;
                self.pushContext(.root_object);
            } else if (token == .end_of_document and self.root_closed) {
                self.document_finished = true;
            } else {
                self.invalid = true;
                try self.skipToken(token);
            }
            return;
        }
        const context = &self.contexts[self.context_count - 1];
        switch (context.kind) {
            .root_object, .choice_object => {
                if (context.expect_key) {
                    if (token == .object_end) return self.closeContext();
                    return self.beginString(token, .key);
                }
                try self.consumeField(context.field, token);
            },
            .choices_array => {
                if (token == .array_end) return self.closeContext();
                if (token != .object_begin) {
                    self.invalid = true;
                    return self.skipToken(token);
                }
                if (self.choice_count == self.choices.len) {
                    self.too_large = true;
                    self.active_choice = null;
                } else {
                    self.choices[self.choice_count] = .{};
                    self.active_choice = self.choice_count;
                    self.choice_count += 1;
                }
                self.pushContext(.choice_object);
            },
        }
    }

    fn consumeField(self: *InputRequestProjection, field: InputField, token: std.json.Token) !void {
        switch (field) {
            .prompt => try self.consumeUniqueString(token, .prompt, &self.prompt),
            .response_type => try self.consumeUniqueString(
                token,
                .response_type,
                &self.response_type,
            ),
            .choices => {
                if (self.choices_field.seen) {
                    self.choices_field.duplicate = true;
                    self.invalid = true;
                    return self.skipToken(token);
                }
                self.choices_field.seen = true;
                if (token != .array_begin) {
                    self.choices_field.wrong_type = true;
                    self.invalid = true;
                    return self.skipToken(token);
                }
                self.pushContext(.choices_array);
            },
            .choice_id => try self.consumeChoiceString(token, .choice_id),
            .choice_label => try self.consumeChoiceString(token, .choice_label),
            .unknown => {
                self.invalid = true;
                try self.skipToken(token);
            },
        }
    }

    fn consumeUniqueString(
        self: *InputRequestProjection,
        token: std.json.Token,
        target: InputStringTarget,
        field: anytype,
    ) !void {
        if (field.seen) {
            field.duplicate = true;
            self.invalid = true;
            return self.skipToken(token);
        }
        field.seen = true;
        if (!isStringToken(token)) {
            field.wrong_type = true;
            self.invalid = true;
            return self.skipToken(token);
        }
        try self.beginString(token, target);
    }

    fn consumeChoiceString(
        self: *InputRequestProjection,
        token: std.json.Token,
        target: InputStringTarget,
    ) !void {
        const index = self.active_choice orelse {
            return self.beginString(token, .discard);
        };
        switch (target) {
            .choice_id => try self.consumeUniqueString(
                token,
                target,
                &self.choices[index].id,
            ),
            .choice_label => try self.consumeUniqueString(
                token,
                target,
                &self.choices[index].label,
            ),
            else => unreachable,
        }
    }

    fn beginString(
        self: *InputRequestProjection,
        token: std.json.Token,
        target: InputStringTarget,
    ) !void {
        if (!isStringToken(token)) {
            self.invalid = true;
            return self.skipToken(token);
        }
        self.string_target = target;
        if (target == .key) self.key.reset();
        try self.consumeString(token);
    }

    fn consumeString(self: *InputRequestProjection, token: std.json.Token) !void {
        const final = switch (token) {
            .string => true,
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => false,
            else => {
                self.invalid = true;
                self.string_target = .none;
                return;
            },
        };
        const bytes: []const u8 = switch (token) {
            .string, .partial_string => |value| value,
            .partial_string_escaped_1 => |value| value[0..],
            .partial_string_escaped_2 => |value| value[0..],
            .partial_string_escaped_3 => |value| value[0..],
            .partial_string_escaped_4 => |value| value[0..],
            else => unreachable,
        };
        switch (self.string_target) {
            .key => self.key.append(bytes),
            .prompt => self.prompt.append(bytes),
            .response_type => self.response_type.append(bytes),
            .choice_id => self.choices[self.active_choice.?].id.append(bytes),
            .choice_label => self.choices[self.active_choice.?].label.append(bytes),
            .discard => {},
            .none => unreachable,
        }
        if (!final) return;
        const target = self.string_target;
        self.string_target = .none;
        if (target == .key) {
            if (self.key.overflowed) self.invalid = true;
            const context = &self.contexts[self.context_count - 1];
            context.field = classifyInputField(context.kind, self.key.slice());
            context.expect_key = false;
        } else {
            self.completeParentValue();
        }
    }

    fn skipToken(self: *InputRequestProjection, token: std.json.Token) !void {
        switch (token) {
            .object_begin, .array_begin => self.skip_depth = 1,
            .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => self.discard_scalar = .string,
            .partial_number => self.discard_scalar = .number,
            .string, .number, .true, .false, .null => self.completeParentValue(),
            else => self.invalid = true,
        }
    }

    fn consumeDiscard(self: *InputRequestProjection, token: std.json.Token) void {
        switch (self.discard_scalar) {
            .string => switch (token) {
                .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => {},
                .string => {
                    self.discard_scalar = .none;
                    self.completeParentValue();
                },
                else => self.invalid = true,
            },
            .number => switch (token) {
                .partial_number => {},
                .number => {
                    self.discard_scalar = .none;
                    self.completeParentValue();
                },
                else => self.invalid = true,
            },
            .none => unreachable,
        }
    }

    fn pushContext(self: *InputRequestProjection, kind: InputContextKind) void {
        if (self.context_count == self.contexts.len) {
            self.too_large = true;
            return;
        }
        self.contexts[self.context_count] = .{
            .kind = kind,
            .expect_key = kind != .choices_array,
        };
        self.context_count += 1;
    }

    fn closeContext(self: *InputRequestProjection) void {
        const kind = self.contexts[self.context_count - 1].kind;
        if (kind == .choice_object) self.active_choice = null;
        self.context_count -= 1;
        if (self.context_count == 0) {
            self.root_closed = true;
        } else {
            self.completeParentValue();
        }
    }

    fn completeParentValue(self: *InputRequestProjection) void {
        if (self.context_count == 0) return;
        const context = &self.contexts[self.context_count - 1];
        switch (context.kind) {
            .root_object, .choice_object => {
                context.expect_key = true;
                context.field = .unknown;
            },
            .choices_array => {},
        }
    }
};

fn classifyInputField(kind: InputContextKind, key: []const u8) InputField {
    return switch (kind) {
        .root_object => if (std.mem.eql(u8, key, "prompt"))
            .prompt
        else if (std.mem.eql(u8, key, "response_type"))
            .response_type
        else if (std.mem.eql(u8, key, "choices"))
            .choices
        else
            .unknown,
        .choice_object => if (std.mem.eql(u8, key, "id"))
            .choice_id
        else if (std.mem.eql(u8, key, "label"))
            .choice_label
        else
            .unknown,
        .choices_array => .unknown,
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
        return Capture.init(std.testing.allocator, .{
            .context = self,
            .append_fn = append,
        });
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
    defer capture.deinit();
    for (model_contract.default_catalog) |definition| try capture.mapping.add(definition);
    try capture.appendSse("event: response.output_item.done\ndata: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"true\\\",\\\"timeout_ms\\\":1000}\",\"call_id\":\"call_1\"}}\n\n");
    try capture.appendSse("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\"}}\n\n");
    capture.finishSse();
    try std.testing.expect(!capture.malformed);
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try capture.publish());
    var scratch: model_protocol.ValidationScratch = .{};
    const parsed = try model_protocol.decode(&scratch, output.bytes[0..output.length]);
    try std.testing.expectEqual(model_protocol.Disposition.tool_call, parsed.disposition);

    var repeated_output: TestCandidate = .{};
    var repeated = repeated_output.capture();
    defer repeated.deinit();
    const final_frame = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n";
    try repeated.appendSse(final_frame);
    try repeated.appendSse(final_frame);
    try repeated.appendSse("data: {\"type\":\"response.completed\"}\n\n");
    repeated.finishSse();
    try std.testing.expectEqual(
        model_protocol.Failure.multiple_outputs,
        (try repeated.publish()).failure.failure,
    );
}

test "SSE capture distinguishes truncated and malformed terminal streams" {
    var truncated_output: TestCandidate = .{};
    var truncated = truncated_output.capture();
    defer truncated.deinit();
    try truncated.appendSse("data: {\"type\":\"response.output_item.done\"");
    truncated.finishSse();
    try std.testing.expect(truncated.malformed);

    var unknown_output: TestCandidate = .{};
    var unknown = unknown_output.capture();
    defer unknown.deinit();
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
    defer capture.deinit();
    try capture.appendSse("data: {\"type\":\"response.output_item.done\",\r\n");
    try capture.appendSse("data: \"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\r\n\r");
    try capture.appendSse("\ndata: {\"type\":\"response.done\"}\r\n\r\n");
    capture.finishSse();
    try std.testing.expect(!capture.malformed);
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try capture.publish());
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
        defer capture.deinit();
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
    defer capture.deinit();
    try capture.appendSse(candidate ++ terminal ++
        "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\"}}\n\n");
    capture.finishSse();
    try std.testing.expect(!capture.malformed);

    var split_output: TestCandidate = .{};
    var split = split_output.capture();
    defer split.deinit();
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
    defer contradictory.deinit();
    try contradictory.appendSse(candidate);
    try contradictory.appendSse(
        "data: {\"type\":\"response.failed\",\"response\":{\"status\":\"completed\"}}\n\n",
    );
    contradictory.finishSse();
    try std.testing.expect(contradictory.malformed);

    var coalesced_output: TestCandidate = .{};
    var coalesced = coalesced_output.capture();
    defer coalesced.deinit();
    coalesced.total_sse_bytes = max_total_sse_bytes - terminal.len;
    try coalesced.appendSse(terminal ++ "trailing bytes beyond the stream budget");
    try std.testing.expect(coalesced.completed);
    try std.testing.expectEqual(max_total_sse_bytes, coalesced.total_sse_bytes);

    var partitioned_output: TestCandidate = .{};
    var partitioned = partitioned_output.capture();
    defer partitioned.deinit();
    partitioned.total_sse_bytes = max_total_sse_bytes - terminal.len;
    try partitioned.appendSse(terminal);
    try partitioned.appendSse("trailing bytes beyond the stream budget");
    try std.testing.expect(partitioned.completed);
    try std.testing.expectEqual(coalesced.total_sse_bytes, partitioned.total_sse_bytes);
}

test "every two-chunk partition produces byte-identical captured evidence" {
    const stream = "data: {\"future_event\":{\"nested\":[1,true,null]},\"type\":\"response.output_item.done\",\"item\":{\"future_item\":42,\"content\":[{\"future_part\":[\"ignored\"],\"text\":\"quote\\\" slash\\\\ emoji \\uD83D\\uDE00\",\"type\":\"output_text\"}],\"role\":\"assistant\",\"type\":\"message\"}}\n\n" ++
        "data: {\"future_terminal\":false,\"response\":{\"future_response\":{},\"status\":\"completed\"},\"type\":\"response.completed\"}\n\n";
    var expected_output: TestCandidate = .{};
    var expected = expected_output.capture();
    defer expected.deinit();
    try expected.appendSse(stream);
    expected.finishSse();
    try std.testing.expect(!expected.malformed);
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try expected.publish());
    for (0..stream.len + 1) |split_at| {
        var actual_output: TestCandidate = .{};
        var actual = actual_output.capture();
        defer actual.deinit();
        try actual.appendSse(stream[0..split_at]);
        try actual.appendSse(stream[split_at..]);
        actual.finishSse();
        try std.testing.expect(!actual.malformed);
        try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try actual.publish());
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

test "windowed parser work is invariant under byte-at-a-time transport" {
    const stream =
        "data: {\"metadata\":{\"nested\":[1,true,null]},\"type\":\"response.output_item.done\",\"item\":{\"content\":[{\"text\":\"done\",\"type\":\"output_text\"}],\"role\":\"assistant\",\"type\":\"message\"}}\n\n" ++
        "data: {\"type\":\"response.completed\"}\n\n";
    var whole_output: TestCandidate = .{};
    var whole = whole_output.capture();
    defer whole.deinit();
    try whole.appendSse(stream);
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try whole.publish());

    var split_output: TestCandidate = .{};
    var split = split_output.capture();
    defer split.deinit();
    for (stream) |byte| try split.appendSse(&.{byte});
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try split.publish());
    try std.testing.expectEqual(whole.projected_json_bytes, split.projected_json_bytes);
    try std.testing.expectEqual(whole.parser_steps, split.parser_steps);
    try std.testing.expect(split.projected_json_bytes <= stream.len);
    try std.testing.expect(split.parser_steps <= 2 * stream.len);
}

test "capture accepts the exact decoded text bound and types one byte over as oversized" {
    const prefix = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"";
    const suffix = "\"}]}}\n\ndata: {\"type\":\"response.completed\"}\n\n";
    var wire: [max_sse_event_bytes + 256]u8 = undefined;
    for ([_]usize{ model_protocol.max_assistant_text_size, model_protocol.max_assistant_text_size + 1 }) |length| {
        var writer = std.Io.Writer.fixed(&wire);
        try writer.writeAll(prefix);
        for (0..length) |_| try writer.writeByte('a');
        try writer.writeAll(suffix);
        var output: TestCandidate = .{};
        var capture = output.capture();
        defer capture.deinit();
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

test "tool argument allocation admits the exact semantic maximum and rejects over" {
    var wire: [max_sse_event_bytes]u8 = undefined;
    for ([_]usize{ model_contract.max_patch_input_bytes, model_contract.max_patch_input_bytes + 1 }) |patch_length| {
        var writer = std.Io.Writer.fixed(&wire);
        try writer.writeAll(
            "data: {\"type\":\"response.output_item.done\",\"item\":{\"arguments\":\"{\\\"patch\\\":\\\"",
        );
        for (0..patch_length) |_| try writer.writeAll("\\\\u0061");
        try writer.writeAll(
            "\\\"}\",\"name\":\"apply_patch\",\"type\":\"function_call\"}}\n\n" ++
                "data: {\"type\":\"response.completed\"}\n\n",
        );
        var output: TestCandidate = .{};
        var capture = output.capture();
        defer capture.deinit();
        for (model_contract.default_catalog) |definition| try capture.mapping.add(definition);
        try capture.appendSse(writer.buffered());
        const outcome = try capture.publish();
        if (patch_length == model_contract.max_patch_input_bytes) {
            try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, outcome);
            try std.testing.expectEqual(
                model_contract.max_tool_arguments_envelope_size,
                capture.arguments.high_water_length,
            );
        } else {
            try std.testing.expectEqual(model_protocol.Failure.oversized, outcome.failure.failure);
        }
    }
}

test "arbitrary item field order retains only potentially authoritative decoded values" {
    var output: TestCandidate = .{};
    var capture = output.capture();
    defer capture.deinit();
    try capture.appendSse(
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"arguments\":\"{\\\"ignored\\\":true}\",\"content\":[{\"text\":\"selected\",\"type\":\"output_text\"}],\"role\":\"assistant\",\"type\":\"message\"}}\n\n" ++
            "data: {\"type\":\"response.completed\"}\n\n",
    );
    try std.testing.expect(capture.text.high_water_length != 0);
    try std.testing.expect(capture.arguments.high_water_length != 0);
    try std.testing.expectEqual(@as(usize, 0), capture.arguments.items.items.len);
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try capture.publish());
}

test "escape amplification is bounded by wire work rather than decoded allocation" {
    const prefix = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"";
    const suffix = "\"}]}}\n\ndata: {\"type\":\"response.completed\"}\n\n";
    var wire: [max_sse_event_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&wire);
    try writer.writeAll(prefix);
    for (0..model_protocol.max_assistant_text_size) |_| try writer.writeAll("\\u0061");
    try writer.writeAll(suffix);
    var output: TestCandidate = .{};
    var capture = output.capture();
    defer capture.deinit();
    try capture.appendSse(writer.buffered());
    capture.finishSse();
    try std.testing.expect(!capture.malformed);
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try capture.publish());
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
        defer capture.deinit();
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
    defer capture.deinit();
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
    defer capture.deinit();
    try capture.appendSse(writer.buffered());
    try std.testing.expect(!capture.malformed);
    try std.testing.expect(!capture.resource_exceeded);
    try std.testing.expect(!capture.terminalObserved());
}

test "open provider envelopes ignore metadata and explicitly ignorable reasoning items" {
    var output: TestCandidate = .{};
    var capture = output.capture();
    defer capture.deinit();
    try capture.appendSse(
        "data: {\"item\":42,\"response\":false,\"type\":\"response.created\"}\n\n",
    );
    try capture.appendSse(
        "data: {\"item\":{\"content\":{\"future\":true},\"type\":\"reasoning\"},\"type\":\"response.output_item.done\"}\n\n",
    );
    try std.testing.expect(!capture.malformed);
    try std.testing.expect(!capture.resource_exceeded);
    try std.testing.expectEqual(@as(u8, 0), capture.candidate_count);
}

test "unknown semantic variants are typed as unsupported provider output" {
    const cases = [_][]const u8{
        "data: {\"type\":\"future.lifecycle\"}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"hosted_tool_call\"}}\n\n",
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"future_content\",\"text\":\"x\"}]}}\n\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"future_terminal\"}}\n\n",
    };
    for (cases) |event| {
        var output: TestCandidate = .{};
        var capture = output.capture();
        defer capture.deinit();
        try capture.appendSse(event);
        if (!capture.completed) try capture.appendSse(
            "data: {\"type\":\"response.completed\"}\n\n",
        );
        try std.testing.expectEqual(
            model_protocol.Failure.unsupported_provider_output,
            (try capture.publish()).failure.failure,
        );
        try std.testing.expectEqual(@as(usize, 0), output.length);
    }
}

test "candidate conversion is independent of provider object field order" {
    const stream =
        "data: {\"item\":{\"arguments\":\"{\\\"command\\\":\\\"true\\\",\\\"timeout_ms\\\":1000}\",\"name\":\"bash\",\"type\":\"function_call\"},\"type\":\"response.output_item.done\"}\n\n" ++
        "data: {\"response\":{\"status\":\"completed\"},\"type\":\"response.completed\"}\n\n";
    var output: TestCandidate = .{};
    var capture = output.capture();
    defer capture.deinit();
    for (model_contract.default_catalog) |definition| try capture.mapping.add(definition);
    for (stream) |byte| try capture.appendSse(&.{byte});
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try capture.publish());
    var scratch: model_protocol.ValidationScratch = .{};
    const parsed = try model_protocol.decode(&scratch, output.bytes[0..output.length]);
    try std.testing.expectEqual(model_protocol.Disposition.tool_call, parsed.disposition);
}

test "capture owns only a small fixed window and releases growable candidate buffers" {
    try std.testing.expect(@sizeOf(Capture) < max_sse_event_bytes / 16);
    var output: TestCandidate = .{};
    var capture = Capture.init(std.testing.allocator, .{
        .context = &output,
        .append_fn = TestCandidate.append,
    });
    defer capture.deinit();
    try capture.appendSse(
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"actual content\"}]}}\n\n" ++
            "data: {\"type\":\"response.completed\"}\n\n",
    );
    try std.testing.expect(capture.text.high_water_length < 32);
    try std.testing.expect(capture.text.high_water_capacity < model_protocol.max_assistant_text_size);
    try std.testing.expectEqual(@as(usize, 0), capture.arguments.high_water_capacity);
    try std.testing.expectEqual(model_operation.DispatchOutcome.candidate, try capture.publish());
    var metrics: CaptureMetrics = .{};
    metrics.observe(&capture);
    try std.testing.expectEqual(@as(usize, 1), metrics.dispatch_count);
    try std.testing.expectEqual(capture.text.high_water_length, metrics.decoded_occupied_high_water_bytes);
    try std.testing.expectEqual(capture.text.high_water_capacity, metrics.decoded_capacity_high_water_bytes);
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
        defer capture.deinit();
        try capture.appendSse(event);
        if (!capture.completed) try capture.appendSse(
            "data: {\"type\":\"response.completed\"}\n\n",
        );
        const outcome = try capture.publish();
        try std.testing.expectEqual(model_protocol.Failure.malformed, outcome.failure.failure);
        try std.testing.expectEqual(@as(usize, 0), output.length);
    }
}

test "wire and stream bounds are exact" {
    var exact: [max_sse_event_bytes]u8 = @splat('x');
    var output: TestCandidate = .{};
    var capture = output.capture();
    defer capture.deinit();
    try capture.appendSse(&exact);
    try std.testing.expectEqual(max_sse_event_bytes, capture.event_wire_bytes);
    try std.testing.expectError(error.SseEventTooLarge, capture.appendSse("x"));

    var total_output: TestCandidate = .{};
    var total = total_output.capture();
    defer total.deinit();
    var ignored: [max_sse_event_bytes]u8 = @splat('x');
    ignored[ignored.len - 2] = '\n';
    ignored[ignored.len - 1] = '\n';
    for (0..max_total_sse_bytes / max_sse_event_bytes) |_| {
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
    defer capture.deinit();
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
    defer capture.deinit();
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
    var capture = Capture.init(std.heap.page_allocator, .{
        .context = &context,
        .append_fn = FailingCandidate.append,
    });
    defer capture.deinit();
    try capture.appendSse(
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n" ++
            "data: {\"type\":\"response.completed\"}\n\n",
    );
    try std.testing.expectError(
        error.InjectedHostStorageFailure,
        capture.publish(),
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
        defer capture.deinit();
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
        defer capture.deinit();
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
        defer capture.deinit();
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
    defer capture.deinit();
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
