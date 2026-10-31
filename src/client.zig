const std = @import("std");
const socket_os = @import("os/socket.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const ResponseTiming = @import("ResponseTiming.zig");
const test_poll = @import("test_poll");
/// Reply grammar; public for callers built against this module alone.
pub const protocol_reply = @import("protocol_reply.zig");

/// A step of capturing or sending one mutation. A failure before `upload`
/// leaves the Host without the request; from `upload` on, the Host may hold
/// an admission this caller never saw.
pub const Step = enum {
    store,
    capture,
    stdin_read,
    input_file_read,
    input_parse,
    endpoint,
    connect,
    upload,
    admission_response,

    pub fn mayHaveReachedHost(self: Step) bool {
        return self == .upload or self == .admission_response;
    }
};

/// A capture or send result that names the step a failure stopped in. A
/// cancellation seen before any step begins names none.
pub fn Stepped(comptime E: type, comptime T: type) type {
    return union(enum) {
        done: T,
        failed: struct { step: ?Step, err: E },

        fn fail(step: ?Step, err: E) @This() {
            return .{ .failed = .{ .step = step, .err = err } };
        }

        /// For callers that report only the error.
        pub fn get(self: @This()) E!T {
            return switch (self) {
                .done => |value| value,
                .failed => |failure| failure.err,
            };
        }
    };
}

/// Pin before spawning a borrower; reset or destroy only after return/join.
/// Stop is local transport intent, never cancellation of admitted Host work.
pub const Cancellation = struct {
    stopped: std.atomic.Value(bool) = .init(false),

    pub fn requestStop(self: *Cancellation) void {
        self.stopped.store(true, .release);
    }
};

/// Borrows io, token, inputs, captures, sinks and reply storage through return.
/// A worker owns each socket; no socket escapes or closes from another thread.
pub const Requests = struct {
    io: std.Io,
    cancellation: ?*const Cancellation = null,
    /// One borrower writes; the caller reads/resets only after return or join.
    read_failure: ?*?protocol_reply.ReadFailure = null,
    /// Test hook for mutation sends only: asks the Host to drop its reply at
    /// this point.
    drop_reply: ?[]const u8 = null,

    pub fn failRead(self: Requests, failure: protocol_reply.ReadFailure) error{ CanonicalStoreFailure, HostInvocationFailed } {
        if (self.read_failure) |slot| if (slot.* == null) {
            slot.* = failure;
        };
        return failure.err();
    }

    pub fn captureReadFailure(self: Requests, reply: protocol_reply.CommandReply) !protocol_reply.ReadFailure {
        const failure = try protocol_reply.decodeReadFailure(reply, false);
        if (self.read_failure) |slot| if (slot.* == null) {
            slot.* = failure;
        };
        return failure;
    }

    fn check(self: Requests) error{Cancelled}!void {
        if (self.cancellation) |token| if (token.stopped.load(.acquire)) return error.Cancelled;
    }

    pub fn sendCaptured(self: Requests, captured: *CapturedRecord, reply_buffer: *ReplyBuffer) Stepped(MutationSendError, protocol_reply.MutationReply) {
        reply_buffer.len = 0;
        self.check() catch |err| return .fail(null, err);
        const paths = platform.resolveClientPaths(self.io, captured.saved.store.slice()) catch |err| return .fail(.store, err);
        const reply = switch (sendSource(self, &paths, std.meta.activeTag(captured.target).route(), ResponseTiming.mutation, captured.length, &captured.file, null, null, reply_buffer, null)) {
            .done => |reply| reply,
            .failed => |failure| return .fail(failure.step, failure.err),
        };
        var result = protocol_reply.decodeMutationReply(reply, captured.saved.session.slice(), captured.target);
        result.context.store = captured.saved.store;
        result.context.key = captured.saved.key;
        result.context.kind = captured.saved.kind;
        return .{ .done = result };
    }

    pub fn observeCommand(self: Requests, store_path: []const u8, key: []const u8, reply_buffer: *ReplyBuffer) !protocol_reply.ObservationReply {
        reply_buffer.len = 0;
        try self.check();
        if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.observe_command_request, .{ paths.store.slice(), key });
        const reply = try sendSource(self, &paths, "/v1/observe-command", .{}, body.len, null, body.slice(), null, reply_buffer, null).get();
        if (reply.status != 200) return .{ .failure = try protocol_reply.decodeReadFailure(reply, false) };
        return .{ .observation = try protocol_reply.CommandObservation.parse(reply, key) };
    }

    pub fn observeMessage(self: Requests, address: *const protocol_reply.MessageAddress) !protocol_reply.ObservationReply {
        var buffer: ReplyBuffer = .{};
        const reply = try self.observeCommand(address.store.slice(), address.key.slice(), &buffer);
        return switch (reply) {
            .observation => |observation| .{ .observation = try observation.forMessage(address) },
            .failure => reply,
        };
    }

    pub fn readResult(self: Requests, store_path: []const u8, key: []const u8, destination: std.Io.File, reply_buffer: *ReplyBuffer) !protocol_reply.ResultReadReply {
        return readResultWithSink(self, store_path, key, destination, reply_buffer);
    }

    pub fn readResultStream(self: Requests, store_path: []const u8, key: []const u8, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ResultReadReply {
        return readResultWithSink(self, store_path, key, sink, reply_buffer);
    }

    /// File or synchronous feed([]const u8) sink; windows expire on feed return.
    /// Sink lifetime/close belongs to the caller. Sink work is not preemptible.
    pub fn inspectSession(self: Requests, store_path: []const u8, session: []const u8, profile: protocol.ReportProfile, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        reply_buffer.len = 0;
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        switch (profile) {
            .current => try body.appendShape(protocol.inspect_session_request.current, .{ paths.store.slice(), session }),
            .full => try body.appendShape(protocol.inspect_session_request.full, .{ paths.store.slice(), session }),
        }
        const fd = try openRead(self, &paths, "/v1/inspect-session", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    pub fn exportFailedResponse(self: Requests, store_path: []const u8, session: []const u8, selection: protocol.FailedResponseExport, destination: std.Io.File, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (selection.operation == 0 or selection.operation > std.math.maxInt(i64) or selection.attempt == 0 or selection.attempt > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.inspect_session_request.failed_response, .{ paths.store.slice(), session, selection.part, selection.operation, selection.attempt });
        const fd = try openRead(self, &paths, "/v1/inspect-session", body.slice());
        defer closeSocket(self.io, fd);
        const head = try readResponseHeadUntil(self, fd, .{}, null);
        if (head.status != 200) {
            if (head.kind != .command_json) return error.InvalidResponse;
            return .{ .command = try readCommandBodyUntil(self, fd, head, reply_buffer, .{}, null) };
        }
        if (head.kind != .content_bytes) return error.InvalidResponse;
        try readResponseBody(self, fd, head.content_length, destination, .withhold_final_window);
        return .{ .report = .{ .bytes = head.content_length } };
    }

    /// Same synchronous sink contract as inspectSession; no complete page copy.
    pub fn listSessions(self: Requests, store_path: []const u8, workspace: ?[]const u8, cursor: protocol_reply.SessionListCursor, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        reply_buffer.len = 0;
        try self.check();
        if (workspace) |value| {
            if (value.len == 0 or value.len > protocol.max_workspace_bytes or
                !std.unicode.utf8ValidateSlice(value)) return error.InvalidWorkspace;
        }
        try cursor.validate();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try appendListSessions(&body, paths.store.slice(), workspace, cursor);
        const fd = try openRead(self, &paths, "/v1/list-sessions", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    pub fn readActionArguments(self: Requests, store_path: []const u8, session: []const u8, action_id: u64, destination: std.Io.File, reply_buffer: *ReplyBuffer) !protocol_reply.ResultReply {
        return readActionContent(self, store_path, session, action_id, protocol.read_action_arguments_request, "/v1/read-action-arguments", destination, reply_buffer);
    }

    pub fn readActionCallId(self: Requests, store_path: []const u8, session: []const u8, action_id: u64, destination: std.Io.File, reply_buffer: *ReplyBuffer) !protocol_reply.ResultReply {
        return readActionContent(self, store_path, session, action_id, protocol.read_action_call_id_request, "/v1/read-action-call-id", destination, reply_buffer);
    }

    pub fn conversationPage(self: Requests, store_path: []const u8, session: []const u8, cursor: protocol_reply.ConversationCursor) !protocol_reply.ConversationPageReply {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        try cursor.validate();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.conversation_page_request, .{ paths.store.slice(), session, cursor.end, cursor.before_position, cursor.before_ordinal });
        const fd = try openRead(self, &paths, "/v1/conversation-page", body.slice());
        defer closeSocket(self.io, fd);
        const Sink = struct {
            buffer: protocol.FixedJsonBuffer(protocol.max_conversation_page_response_bytes) = .{},
            pub fn feed(s: *@This(), bytes: []const u8) !void {
                try s.buffer.append(bytes);
            }
        };
        var sink: Sink = .{};
        var reply: ReplyBuffer = .{};
        return switch (try readReportResponse(self, fd, &sink, &reply)) {
            .report => .{ .page = try protocol_reply.ConversationPage.parse(sink.buffer.slice(), cursor) },
            .command => |value| .{ .failure = try protocol_reply.decodeReadFailure(value, false) },
        };
    }

    /// Stream prefix bytes; bind length, digest and EOF before the final window.
    /// Null selects raw export, still requiring framing and physical EOF.
    pub fn readConversationContent(self: Requests, store_path: []const u8, session: []const u8, position: u64, ordinal: u64, expected: ?protocol_reply.CommandObservation.ContentReference, sink: anytype) !?protocol_reply.ReadFailure {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64) or ordinal > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.conversation_content_request, .{ paths.store.slice(), session, position, ordinal });
        const fd = try openRead(self, &paths, "/v1/conversation-content", body.slice());
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, expected, sink);
    }

    /// Returns owned metadata only; no scratch, payload or traversal escapes.
    pub fn proposalPage(self: Requests, store_path: []const u8, session: []const u8, cursor: protocol_reply.ProposalCursor) !protocol_reply.ProposalPageReply {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        try (protocol.ProposalPage{ .end = cursor.end, .after = cursor.after }).validate();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.proposal_page_request, .{ paths.store.slice(), session, cursor.end, cursor.after });
        const fd = try openRead(self, &paths, "/v1/proposal-page", body.slice());
        defer closeSocket(self.io, fd);
        const Sink = struct {
            buffer: protocol.FixedJsonBuffer(protocol.max_proposal_page_response_bytes) = .{},
            pub fn feed(s: *@This(), bytes: []const u8) !void {
                try s.buffer.append(bytes);
            }
        };
        var sink: Sink = .{};
        var reply_buffer: ReplyBuffer = .{};
        return switch (try readReportResponse(self, fd, &sink, &reply_buffer)) {
            .report => .{ .page = try protocol_reply.ProposalPage.parse(sink.buffer.slice(), cursor) },
            .command => |reply| .{ .failure = try protocol_reply.decodeReadFailure(reply, false) },
        };
    }

    /// Complete bytes once, through the ordinary synchronous sink contract.
    /// Failure may follow delivered prefix bytes; it never returns success then.
    pub fn readProposalField(self: Requests, store_path: []const u8, session: []const u8, position: u64, field: ProposalField, expected: ?protocol_reply.CommandObservation.ContentReference, sink: anytype) !?protocol_reply.ReadFailure {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.proposal_field_request, .{ paths.store.slice(), session, position, field });
        const fd = try openRead(self, &paths, "/v1/proposal-field", body.slice());
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, expected, sink);
    }

    pub fn activityPage(self: Requests, store_path: []const u8, session: []const u8, cursor: protocol_reply.ActivityCursor) !protocol_reply.ActivityPageReply {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        try cursor.validate();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.activity_page_request, .{ paths.store.slice(), session, cursor.end, cursor.position, cursor.ordinal, cursor.direction });
        const fd = try openRead(self, &paths, "/v1/activity-page", body.slice());
        defer closeSocket(self.io, fd);
        const Sink = struct {
            buffer: protocol.FixedJsonBuffer(protocol.max_activity_page_response_bytes) = .{},
            pub fn feed(s: *@This(), bytes: []const u8) !void {
                try s.buffer.append(bytes);
            }
        };
        var sink: Sink = .{};
        var buffer: ReplyBuffer = .{};
        return switch (try readReportResponse(self, fd, &sink, &buffer)) {
            .report => .{ .page = try protocol_reply.ActivityPage.parse(sink.buffer.slice(), cursor) },
            .command => |reply| .{ .failure = try protocol_reply.decodeReadFailure(reply, false) },
        };
    }

    /// Complete scoped bytes once; callers still use readProposalField for calls.
    pub fn readActivityContent(self: Requests, store_path: []const u8, session: []const u8, position: u64, ordinal: u64, expected: ?protocol_reply.CommandObservation.ContentReference, sink: anytype) !?protocol_reply.ReadFailure {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64) or ordinal > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.activity_content_request, .{ paths.store.slice(), session, position, ordinal });
        const fd = try openRead(self, &paths, "/v1/activity-content", body.slice());
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, expected, sink);
    }

    /// The first line of a Message admission row (ordinal 0), read into
    /// `buffer`, whose length is the limit. Closing the connection early ends
    /// the Host's exchange as an ordinary disconnect. The bytes are
    /// unverified, because the digest is checked only at EOF: show them as a
    /// hint, never store, compare or address by them.
    pub fn readActivityPrefix(self: Requests, store_path: []const u8, session: []const u8, position: u64, buffer: []u8) !protocol_reply.ActivityPrefixReply {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.activity_content_request, .{ paths.store.slice(), session, position, 0 });
        const fd = try openRead(self, &paths, "/v1/activity-content", body.slice());
        defer closeSocket(self.io, fd);
        return readFirstLine(self, fd, buffer);
    }
};

/// Returns at the first line break, or once `buffer` is full, without reading
/// the rest of the content.
fn readFirstLine(requests: Requests, fd: std.posix.fd_t, buffer: []u8) !protocol_reply.ActivityPrefixReply {
    const head = try readResponseHeadUntil(requests, fd, .{}, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        var reply_buffer: ReplyBuffer = .{};
        return .{ .failure = try protocol_reply.decodeReadFailure(try readCommandBodyUntil(requests, fd, head, &reply_buffer, .{}, null), false) };
    }
    if (head.kind != .content_bytes or head.total != head.content_length or head.next != head.content_length) return error.InvalidResponse;
    const wanted: usize = @intCast(@min(head.content_length, buffer.len));
    var filled: usize = 0;
    const line = while (filled != wanted) {
        const count = try readRequest(requests, fd, buffer[filled..wanted], ResponseTiming.transfer.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, null, true));
        if (count == 0) return error.TruncatedResponse;
        if (std.mem.indexOfScalar(u8, buffer[filled..][0..count], '\n')) |index| break buffer[0 .. filled + index];
        filled += count;
    } else if (wanted < head.content_length) wholeScalars(buffer[0..wanted]) else buffer[0..wanted];
    const text = std.mem.trimEnd(u8, line, "\r");
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidResponse;
    return .{ .line = text };
}

/// Drops a scalar the limit cut, so the line ends on a whole character.
fn wholeScalars(bytes: []const u8) []const u8 {
    var start = bytes.len;
    while (start != 0 and bytes.len - start < 4) {
        start -= 1;
        if (bytes[start] & 0xc0 != 0x80) break;
    }
    if (start == bytes.len) return bytes;
    const length = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes;
    return if (start + length > bytes.len) bytes[0..start] else bytes;
}

fn readPublicContentResponse(requests: Requests, fd: std.posix.fd_t, expected: ?protocol_reply.CommandObservation.ContentReference, sink: anytype) !?protocol_reply.ReadFailure {
    const head = try readResponseHeadUntil(requests, fd, .{}, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        var reply_buffer: ReplyBuffer = .{};
        return try protocol_reply.decodeReadFailure(try readCommandBodyUntil(requests, fd, head, &reply_buffer, .{}, null), false);
    }
    if (head.kind != .content_bytes or head.total != head.content_length or head.next != head.content_length) return error.InvalidResponse;
    if (expected) |reference| if (head.content_length != reference.bytes) return error.ContentBindingMismatch;
    var hash = protocol.contentHasher();
    var remaining = head.content_length;
    var window: [protocol.content_window_bytes]u8 = undefined;
    while (remaining != 0) {
        const wanted: usize = @intCast(@min(remaining, window.len));
        var filled: usize = 0;
        while (filled != wanted) {
            const count = try readRequest(requests, fd, window[filled..wanted], ResponseTiming.transfer.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, null, true));
            if (count == 0) return error.TruncatedResponse;
            filled += count;
        }
        hash.update(window[0..wanted]);
        remaining -= wanted;
        if (remaining == 0) try completeContentEOF(requests, fd, hash.finalResult(), expected);
        if (@TypeOf(sink) == std.Io.File) try sink.writeStreamingAll(requests.io, window[0..wanted]) else try sink.feed(window[0..wanted]);
    }
    if (head.content_length == 0) try completeContentEOF(requests, fd, hash.finalResult(), expected);
    return null;
}

fn completeContentEOF(requests: Requests, fd: std.posix.fd_t, actual: [32]u8, expected: ?protocol_reply.CommandObservation.ContentReference) !void {
    if (expected) |reference| if (!std.mem.eql(u8, &actual, &reference.digest)) return error.ContentBindingMismatch;
    var tail: [1]u8 = undefined;
    if (try readRequest(requests, fd, &tail, ResponseTiming.transfer.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, null, true)) != 0) return error.InvalidResponse;
}

pub const ProposalField = protocol.ProposalField;

pub const OptionalText = struct {
    present: bool = false,
    value: []const u8 = "",
};

pub const OptionalPolicy = struct {
    present: bool = false,
    value: ?[]const u8 = null,
};

pub const OptionalFile = struct {
    state: enum { omitted, value, explicit_null } = .omitted,
    path: []const u8 = "",
};

pub const ConfigureInput = struct {
    store: []const u8,
    session: union(enum) {
        named: []const u8,
        create,
    },
    require_model: bool = false,
    workspace: OptionalText = .{},
    provider: OptionalText = .{},
    model: OptionalText = .{},
    instructions: OptionalFile = .{},
    tools: ?[]const u8 = null,
    permission_mode: OptionalText = .{},
    output_schema: OptionalFile = .{},
    compaction_trigger: OptionalPolicy = .{},
    output_reservation: OptionalPolicy = .{},
    reasoning_effort: OptionalPolicy = .{},
    /// A null value clears the Label.
    label: OptionalPolicy = .{},
};

pub const MessageInput = struct {
    store: []const u8,
    session: []const u8,
    text_path: []const u8,
    text: ?[]const u8 = null,
    configuration: ?ConfigureInput = null,
    // The full sending address from the tool process, retained for recovery.
    sender: ?Address = null,
    sender_handle: ?[]const u8 = null,
};

/// Internal sender binding. Public addresses are bare Session IDs; the
/// trusted tool environment supplies the Store separately.
pub const Address = struct {
    store: ?[]const u8,
    session: []const u8,
};

test "Session addresses are exactly six lowercase Crockford characters" {
    try std.testing.expect(protocol.validSessionId("k7m2qx"));
    try std.testing.expect(protocol.validSessionId("09azvw"));
    for ([_][]const u8{
        "",           "k7m2q",                    "k7m2qxx", "K7m2qx", "k7m2qi", "k7m2ql", "k7m2qo", "k7m2qu",
        "rui/k7m2qx", "{\"session\":\"k7m2qx\"}",
        "k7\x00雪",
    }) |invalid| try std.testing.expect(!protocol.validSessionId(invalid));
}

pub const SessionStopInput = struct {
    store: []const u8,
    session: []const u8,
};

pub const ModelInterruptionInput = struct {
    store: []const u8,
    session: []const u8,
    turn_id: u64,
    operation_id: u64,
};

pub const PermissionDecisionInput = struct {
    store: []const u8,
    session: []const u8,
    action_id: u64,
    decision: protocol.PermissionDecision = .deny,
};

pub const ReplyBuffer = protocol.ResponseBuffer;

pub const HostStopInput = struct {
    store: []const u8,
    // Retain the instance from the original observation across every retry.
    instance: protocol.InstanceId,
    drop_reply: ?[]const u8 = null,
};

pub const HostStopResult = enum { acknowledged, instance_changed, unavailable };

/// Acknowledgement means the matching Host fenced dispatch, not that it drained.
/// Retry with the same input after a lost reply; never rediscover a new target.
pub fn stopHost(io: std.Io, input: HostStopInput, reply_buffer: *ReplyBuffer) !HostStopResult {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, input.store);
    var body: protocol.RequestBuffer = .{};
    try body.appendShape(protocol.host_stop_request, .{paths.store.slice()});
    const reply = sendSource(.{ .io = io, .drop_reply = input.drop_reply }, &paths, "/v1/control/host-stop", ResponseTiming.mutation, body.len, null, body.slice(), &input.instance, reply_buffer, null).get();
    const result = reply catch |err| return if (err == error.FileNotFound or err == error.ConnectionRefused)
        .unavailable
    else
        err;
    if (result.status == 200 and std.mem.eql(u8, result.body, protocol.host_stop_ack)) return .acknowledged;
    if (result.status == 409) {
        const Failure = struct { version: []const u8, type: []const u8, code: []const u8 };
        var parse_storage: [protocol.max_control_error_response_bytes * 2]u8 = undefined;
        var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
        const failure = std.json.parseFromSliceLeaky(Failure, arena.allocator(), result.body, .{ .ignore_unknown_fields = false }) catch return error.InvalidHostStopResponse;
        if (std.mem.eql(u8, failure.version, protocol.wire_version) and
            std.mem.eql(u8, failure.type, "invocation_error") and
            std.mem.eql(u8, failure.code, "host_instance_changed")) return .instance_changed;
    }
    if (result.status == 503) return .unavailable;
    return error.InvalidHostStopResponse;
}

/// Observation only: never creates a Store, acquires ownership or reads SQLite.
pub fn hostStatus(io: std.Io, store_path: []const u8) protocol_reply.HostStatus {
    return hostStatusUntil(io, store_path, null);
}

/// Startup callers can bound the entire readiness loop, including each probe.
pub fn hostStatusUntil(io: std.Io, store_path: []const u8, deadline: ?i128) protocol_reply.HostStatus {
    const paths = platform.resolveClientPaths(io, store_path) catch |err| return switch (err) {
        error.FileNotFound => .unavailable,
        else => .access_failure,
    };
    var store_dir = std.Io.Dir.cwd().openDir(io, paths.store.slice(), .{}) catch return .access_failure;
    defer store_dir.close(io);
    // A replaced lock node may be a FIFO: open must not wait for a writer
    // before the nonblocking lock probe can classify the selected Store.
    const fd = std.posix.openat(store_dir.handle, "host.lock", .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| return switch (err) {
        error.FileNotFound => .unavailable,
        else => .access_failure,
    };
    const lock_file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer lock_file.close(io);
    const stat = lock_file.stat(io) catch return .access_failure;
    if (stat.kind != .file) return .access_failure;
    return switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB))) {
        .SUCCESS => .unavailable,
        .AGAIN => readHostInfo(io, &paths, deadline),
        else => .access_failure,
    };
}

fn readHostInfo(io: std.Io, paths: *const platform.Paths, deadline: ?i128) protocol_reply.HostStatus {
    var body: protocol.RequestBuffer = .{};
    body.appendShape(protocol.host_info_request, .{paths.store.slice()}) catch unreachable;
    var reply_buffer: ReplyBuffer = .{};
    const probe_end = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
    const until = @min(probe_end, deadline orelse probe_end);
    const reply = sendSource(.{ .io = io }, paths, "/v1/host-info", .{}, body.len, null, body.slice(), null, &reply_buffer, until).get() catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_failure,
        error.WrongWireVersion, error.InvalidResponse, error.ResponseHeaderTooLarge, error.ResponseTooLarge, error.InvalidCharacter, error.Overflow => .incompatible,
        else => .owned_unavailable,
    };
    if (reply.status == 503) return if (protocol_reply.validHostUnavailable(reply.body)) .owned_unavailable else .incompatible;
    if (reply.status != 200) return .incompatible;
    return protocol_reply.parseHostInfo(reply.body, paths.store.slice()) catch .incompatible;
}

pub fn captureSessionStop(io: std.Io, input: SessionStopInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    return writeSessionStopCapture(io, &paths, input, location);
}

pub fn captureModelInterruption(io: std.Io, input: ModelInterruptionInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    if (input.turn_id == 0 or input.operation_id == 0) return error.InvalidTarget;
    return writeModelInterruptionCapture(io, &paths, input, location);
}

pub fn observeCommand(
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ObservationReply {
    return (Requests{ .io = io }).observeCommand(store_path, key, reply_buffer);
}

pub fn observeMessage(io: std.Io, address: *const protocol_reply.MessageAddress) !protocol_reply.ObservationReply {
    return (Requests{ .io = io }).observeMessage(address);
}

pub fn readResult(
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ResultReadReply {
    return (Requests{ .io = io }).readResult(store_path, key, destination, reply_buffer);
}

/// Streams answer windows to the caller without retaining a complete copy.
/// The sink receives borrowed windows valid only during each feed call.
pub fn readResultStream(
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ResultReadReply {
    return (Requests{ .io = io }).readResultStream(store_path, key, sink, reply_buffer);
}

fn readResultWithSink(
    requests: Requests,
    store_path: []const u8,
    key: []const u8,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ResultReadReply {
    const io = requests.io;
    reply_buffer.len = 0;
    try requests.check();
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try body.appendShape(protocol.read_result_request, .{ paths.store.slice(), key });
    const fd = try openRead(requests, &paths, "/v1/read-result", body.slice());
    defer closeSocket(io, fd);
    return switch (try readResultResponseSink(requests, fd, sink, reply_buffer)) {
        .answer => |answer| .{ .answer = .{ .bytes = answer.bytes } },
        .command => |reply| .{ .failure = try protocol_reply.decodeReadFailure(reply, true) },
    };
}

pub fn inspectSession(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    profile: protocol.ReportProfile,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ReportReply {
    return (Requests{ .io = io }).inspectSession(store_path, session, profile, destination, reply_buffer);
}

/// Streams one complete JSON page into destination. A non-200 reply borrows
/// reply_buffer; a partial destination after an I/O error is not a valid page.
/// Pass the response's next cursor and the same workspace for continuation.
/// File writes begin at the caller's current offset, without rewind/truncation.
pub fn listSessions(
    io: std.Io,
    store_path: []const u8,
    workspace: ?[]const u8,
    cursor: protocol_reply.SessionListCursor,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ReportReply {
    return (Requests{ .io = io }).listSessions(store_path, workspace, cursor, destination, reply_buffer);
}

/// The request a list cursor names: a full traversal's keyset, a token's
/// first page, or a changed continuation.
fn appendListSessions(body: anytype, store: []const u8, workspace: ?[]const u8, cursor: protocol_reply.SessionListCursor) !void {
    const head = .{ store, workspace, cursor.after, cursor.ceiling };
    var token: [protocol.SinceToken.max_bytes]u8 = undefined;
    const since = cursor.since orelse return body.appendShape(protocol.list_sessions_request, head);
    if (cursor.changed) |*changed|
        try body.appendShape(protocol.list_sessions_changed_request, head ++ .{ since.format(&token), changed.through, @as([]const u8, &changed.after_reference) })
    else
        try body.appendShape(protocol.list_sessions_since_request, head ++ .{since.format(&token)});
}

pub fn readActionArguments(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ResultReply {
    return (Requests{ .io = io }).readActionArguments(store_path, session, action_id, destination, reply_buffer);
}

pub fn readActionCallId(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ResultReply {
    return (Requests{ .io = io }).readActionCallId(store_path, session, action_id, destination, reply_buffer);
}

fn readActionContent(
    requests: Requests,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    comptime shape: anytype,
    comptime route: []const u8,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ResultReply {
    const io = requests.io;
    reply_buffer.len = 0;
    try requests.check();
    if (!protocol.validSessionId(session) or action_id == 0) return error.InvalidTarget;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try body.appendShape(shape, .{ paths.store.slice(), session, action_id });
    const fd = try openRead(requests, &paths, route, body.slice());
    defer closeSocket(io, fd);
    return readResultResponseSink(requests, fd, destination, reply_buffer);
}

/// The facts a captured record must carry before it is published or resent.
/// A null field is not part of the expectation.
pub const Binding = struct {
    store: ?[]const u8 = null,
    session: ?[]const u8 = null,
    key: ?[]const u8 = null,
    kind: ?protocol.CommandKind = null,
    /// The exact target, payload included.
    target: ?protocol_reply.MutationTarget = null,

    pub fn matches(self: Binding, saved: *const protocol_reply.MutationIdentity, target: protocol_reply.MutationTarget) bool {
        if (self.store) |store| if (!saved.store.eql(store)) return false;
        if (self.session) |session| if (!saved.session.eql(session)) return false;
        if (self.key) |key| if (!saved.key.eql(key)) return false;
        if (self.kind) |kind| if (target != kind) return false;
        if (self.target) |expected| if (!std.meta.eql(expected, target)) return false;
        return true;
    }
};

pub const CaptureTarget = union(enum) {
    generated: []const u8, // Caller-selected private directory, not HOME policy.
    explicit: struct { record: []const u8, key: []const u8 },
    // An identity a caller resolved ahead of capture, keeping its route.
    reserved: Location,

    /// Where a capture writes, the key it binds, and how it is replayed.
    pub const Location = struct { record: []const u8, key: []const u8, replay: Replay };

    /// Reserve identity before asynchronous capture; returned slices borrow
    /// caller storage through capture return. This does not publish a record.
    pub fn resolve(self: CaptureTarget, io: std.Io, path: []u8, key: *[36]u8) !Location {
        return switch (self) {
            .explicit => |value| .{ .record = value.record, .key = value.key, .replay = .{ .explicit = value.record } },
            .reserved => |location| location,
            .generated => |directory| blk: {
                var bytes: [16]u8 = undefined;
                try std.Io.randomSecure(io, &bytes);
                bytes[6] = (bytes[6] & 0x0f) | 0x40;
                bytes[8] = (bytes[8] & 0x3f) | 0x80;
                const id = try std.fmt.bufPrint(key, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
                    std.mem.readInt(u32, bytes[0..4], .big),
                    std.mem.readInt(u16, bytes[4..6], .big),
                    std.mem.readInt(u16, bytes[6..8], .big),
                    std.mem.readInt(u16, bytes[8..10], .big),
                    std.mem.readInt(u48, bytes[10..16], .big),
                });
                break :blk .{ .record = try requestPath(directory, id, path), .key = id, .replay = .generated };
            },
        };
    }
};

/// How a caller replays a saved request: by its generated handle, which is
/// the record's key, or by the explicit record path it was captured to or
/// opened from. That path is borrowed from the caller, which keeps it alive
/// as long as any copy of this value (the CLI passes argv).
pub const Replay = union(enum) {
    generated,
    explicit: []const u8,
};

// Owns one read-only descriptor, never the saved name's deletion. Identity
// borrows this value and remains available after any send failure. Do not copy
// the live owner; close once after the last send/identity/replay consumer.
pub const CapturedRecord = struct {
    file: std.Io.File,
    length: u64,
    saved: protocol_reply.MutationIdentity,
    target: protocol_reply.MutationTarget,
    replay: Replay,

    pub fn identity(self: *const CapturedRecord) *const protocol_reply.MutationIdentity {
        return &self.saved;
    }

    pub fn close(self: *CapturedRecord, io: std.Io) void {
        self.file.close(io);
        self.* = undefined;
    }
};

pub fn validRequestHandle(handle: []const u8) bool {
    if (handle.len != 36) return false;
    for (handle, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn requestPath(directory: []const u8, handle: []const u8, buffer: []u8) ![]const u8 {
    if (!validRequestHandle(handle)) return error.InvalidRequestHandle;
    return std.fmt.bufPrint(buffer, "{s}/{s}.json", .{ directory, handle });
}

/// A saved record to resend: a generated handle in its request directory,
/// or an explicit record that must belong to `store` and carry `kind`.
pub const SavedRecord = union(enum) {
    generated: struct { directory: []const u8, handle: []const u8 },
    explicit: struct { store: []const u8, record: []const u8, kind: protocol.CommandKind },
};

/// Reopens a saved record to resend its original bytes. A generated record
/// whose key is not its handle is malformed; an explicit record of another
/// Store or kind is the wrong record.
pub fn openCaptured(io: std.Io, saved: SavedRecord) !CapturedRecord {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var paths: platform.Paths = undefined;
    var expected: Binding = .{};
    const path = switch (saved) {
        .generated => |generated| blk: {
            expected.key = generated.handle;
            break :blk try requestPath(generated.directory, generated.handle, &path_buffer);
        },
        .explicit => |explicit| blk: {
            paths = try platform.resolveClientPaths(io, explicit.store);
            expected.store = paths.store.slice();
            expected.kind = explicit.kind;
            break :blk explicit.record;
        },
    };
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    const binding = try readCapturedBinding(io, &file);
    if (!expected.matches(&binding.saved, binding.target)) return switch (saved) {
        .generated => error.InvalidRequestRecord,
        .explicit => error.RequestBindingMismatch,
    };
    const replay: Replay = switch (saved) {
        .generated => .generated,
        .explicit => |explicit| .{ .explicit = explicit.record },
    };
    return .{ .file = file, .length = try file.length(io), .saved = binding.saved, .target = binding.target, .replay = replay };
}

/// Metadata-only projection for listing/inspection; cannot authorize a send or
/// an admission. Historical payloads are not traversed by these callers.
pub fn inspectCaptured(io: std.Io, directory: []const u8, handle: []const u8) !protocol_reply.MutationIdentity {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, try requestPath(directory, handle, &path_buffer), .{});
    defer file.close(io);
    return readCapturedIdentity(io, &file, handle);
}

const CapturedText = struct {
    bytes: u64 = 0,
    digest: [32]u8 = undefined,

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !CapturedText {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        var result: CapturedText = .{};
        var hash = protocol.contentHasher();
        var utf8: Utf8Validator = .{};
        while (true) {
            const token = try source.next();
            const bytes: []const u8 = switch (token) {
                .string, .partial_string => |bytes| bytes,
                .partial_string_escaped_1 => |*bytes| bytes,
                .partial_string_escaped_2 => |*bytes| bytes,
                .partial_string_escaped_3 => |*bytes| bytes,
                .partial_string_escaped_4 => |*bytes| bytes,
                else => return error.UnexpectedToken,
            };
            if (bytes.len > protocol.max_sqlite_content_bytes - result.bytes) return error.ValueTooLong;
            result.bytes += bytes.len;
            utf8.feed(bytes) catch return error.InvalidCharacter;
            hash.update(bytes);
            if (token == .string) break;
        }
        if (!utf8.complete()) return error.InvalidCharacter;
        hash.final(&result.digest);
        return result;
    }
};

const CapturedConfiguration = struct {
    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !CapturedConfiguration {
        if (try source.peekNextTokenType() != .object_begin) return error.UnexpectedToken;
        // Configuration/domain meaning belongs to Store. Validate syntax only;
        // large instructions/schema strings stay in the record, not memory.
        try source.skipValue();
        return .{};
    }
};

fn readCapturedBinding(io: std.Io, file: *std.Io.File) !struct { saved: protocol_reply.MutationIdentity, target: protocol_reply.MutationTarget } {
    const Fields = struct {
        version: protocol_reply.JsonString(8),
        kind: protocol_reply.JsonString(32),
        store: protocol_reply.JsonString(protocol.max_store_bytes),
        key: protocol_reply.JsonString(protocol.max_key_bytes),
        session: ?protocol_reply.JsonString(protocol.max_session_bytes) = null,
        configuration: ?CapturedConfiguration = null,
        require_model: ?bool = null,
        sender: ?protocol_reply.JsonAddress = null,
        sender_handle: ?protocol_reply.JsonString(32) = null,
        text: ?struct { state: protocol_reply.JsonString(8), value: CapturedText } = null,
        action: ?protocol_reply.JsonString(20) = null,
        decision: ?protocol_reply.JsonString(16) = null,
        target: ?struct { session: protocol_reply.JsonString(protocol.max_session_bytes), turn: protocol_reply.JsonString(20), operation: protocol_reply.JsonString(20) } = null,
    };
    var input: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.reader(io, &input);
    // Producer grammar nests at most four levels. Bounded metadata/name scratch
    // also covers escaped names; exhaustion rejects the record, never truncates.
    var storage: [2048]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var reader = std.json.Reader.init(fixed.allocator(), &file_reader.interface);
    defer reader.deinit();
    const fields = std.json.parseFromTokenSourceLeaky(Fields, fixed.allocator(), &reader, .{ .allocate = .alloc_if_needed, .max_value_len = protocol.max_store_bytes }) catch return file_reader.err orelse error.InvalidRequestRecord;
    if (!fields.version.eql(protocol.wire_version)) return error.InvalidRequestRecord;
    const kind = std.meta.stringToEnum(protocol.CommandKind, fields.kind.slice()) orelse return error.InvalidRequestRecord;
    var saved: protocol_reply.MutationIdentity = .{ .store = fields.store.value, .key = fields.key.value, .kind = kind };
    if (kind == .model_interruption) {
        if (fields.session != null) return error.InvalidRequestRecord;
        saved.session = (fields.target orelse return error.InvalidRequestRecord).session.value;
    } else saved.session = (fields.session orelse return error.InvalidRequestRecord).value;
    if (!((kind == .configure or kind == .message and fields.configuration != null) and saved.session.len == 0) and !protocol.validSessionId(saved.session.slice())) return error.InvalidRequestRecord;
    const target: protocol_reply.MutationTarget = switch (kind) {
        .configure => blk: {
            if (fields.configuration == null) return error.InvalidRequestRecord;
            break :blk .configure;
        },
        .message => blk: {
            const text = fields.text orelse return error.InvalidRequestRecord;
            if (!text.state.eql("value")) return error.InvalidRequestRecord;
            if (fields.sender) |sender| _ = sender.address() catch return error.InvalidRequestRecord;
            if (fields.configuration != null and saved.session.len != 0) return error.InvalidRequestRecord;
            break :blk .{ .message = .{ .bytes = text.value.bytes, .digest = text.value.digest, .creates_session = fields.configuration != null } };
        },
        .session_stop => .session_stop,
        .model_interruption => .{ .model_interruption = .{
            .turn = protocol_reply.mutationId(fields.target.?.turn, true) catch return error.InvalidRequestRecord,
            .operation = protocol_reply.mutationId(fields.target.?.operation, true) catch return error.InvalidRequestRecord,
        } },
        .permission_decision => .{ .permission_decision = .{
            .action = protocol_reply.mutationId(fields.action orelse return error.InvalidRequestRecord, true) catch return error.InvalidRequestRecord,
            .decision = std.meta.stringToEnum(protocol.PermissionDecision, (fields.decision orelse return error.InvalidRequestRecord).slice()) orelse return error.InvalidRequestRecord,
        } },
    };
    // Configuration, and its capability condition, belong to a configure or
    // a creating Message.
    if ((kind != .configure and kind != .message and fields.configuration != null) or
        (fields.require_model != null and !(kind == .configure or kind == .message and fields.configuration != null)) or
        (kind != .message and (fields.text != null or fields.sender != null or fields.sender_handle != null)) or (kind != .model_interruption and fields.target != null) or
        (kind != .permission_decision and (fields.action != null or fields.decision != null))) return error.InvalidRequestRecord;
    return .{ .saved = saved, .target = target };
}

// Capture writes identity first, before variable content. Recover the bounded
// prefix without loading or copying the potentially large captured payload.
fn readCapturedIdentity(io: std.Io, file: *std.Io.File, handle: []const u8) !protocol_reply.MutationIdentity {
    const header_bytes = 6 * (protocol.max_store_bytes + protocol.max_key_bytes + protocol.max_session_bytes) + 256;
    var buffer: [header_bytes]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    const prefix = buffer[0..count];
    const kind_marker = std.mem.indexOf(u8, prefix, ",\"configuration\"") orelse
        std.mem.indexOf(u8, prefix, ",\"text\"") orelse
        std.mem.indexOf(u8, prefix, ",\"decision\"") orelse
        // Stop/interruption records contain only bounded identities. There is
        // no variable payload to exclude from their complete metadata object.
        if (count > 0 and prefix[count - 1] == '}') count - 1 else return error.InvalidRequestRecord;
    var head: [header_bytes]u8 = undefined;
    if (kind_marker + 1 > head.len) return error.InvalidRequestRecord;
    @memcpy(head[0..kind_marker], prefix[0..kind_marker]);
    head[kind_marker] = '}';
    const Fields = struct {
        version: []const u8,
        kind: []const u8,
        store: []const u8,
        key: []const u8,
        session: ?[]const u8 = null,
        target: ?struct { session: []const u8 } = null,
    };
    const parsed = try std.json.parseFromSlice(Fields, std.heap.c_allocator, head[0 .. kind_marker + 1], .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.version, protocol.wire_version) or !std.mem.eql(u8, parsed.value.key, handle)) return error.InvalidRequestRecord;
    var store: @FieldType(protocol_reply.MutationIdentity, "store") = .{};
    try store.set(parsed.value.store);
    var key: @FieldType(protocol_reply.MutationIdentity, "key") = .{};
    try key.set(parsed.value.key);
    const session = parsed.value.session orelse if (parsed.value.target) |target| target.session else return error.InvalidRequestRecord;
    const kind = std.meta.stringToEnum(protocol.CommandKind, parsed.value.kind) orelse return error.InvalidRequestRecord;
    var identity: protocol_reply.MutationIdentity = .{ .store = store, .key = key, .kind = kind };
    const creation = session.len == 0 and (kind == .configure or
        kind == .message and std.mem.startsWith(u8, prefix[kind_marker..], ",\"configuration\":"));
    if (!creation and !protocol.validSessionId(session)) return error.InvalidRequestRecord;
    try identity.session.set(session);
    return identity;
}

/// The error set a function returns.
fn ErrorOf(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.error_set;
}

pub const CaptureError = ErrorOf(platform.resolveClientPaths) || ErrorOf(writeConfigureCapture) || ErrorOf(writeMessageCapture);

pub fn captureConfigure(io: std.Io, input: ConfigureInput, target: CaptureTarget) Stepped(CaptureError, CapturedRecord) {
    return stepCapture(io, input, target, writeConfigureCapture);
}

/// Resolves the Store, then writes the capture, naming where either stopped.
fn stepCapture(io: std.Io, input: anytype, target: CaptureTarget, comptime write: anytype) Stepped(CaptureError, CapturedRecord) {
    const paths = platform.resolveClientPaths(io, input.store) catch |err| return .fail(.store, err);
    var input_failure: ?Step = null;
    const record = write(io, &paths, input, target, &input_failure) catch |err| return .fail(input_failure orelse .capture, err);
    return .{ .done = record };
}

fn writeConfigureCapture(io: std.Io, paths: *const platform.Paths, input: ConfigureInput, target: CaptureTarget, input_failure: *?Step) !CapturedRecord {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    const session = switch (input.session) {
        .named => |name| name,
        .create => "",
    };
    if (location.key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(location.key)) return error.InvalidKey;
    if (input.session == .named and !protocol.validSessionId(session)) return error.InvalidSession;
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    capture.input_failure = input_failure;
    errdefer capture.abort();
    try capture.writeRequest(protocol.configure_request.head, .{ paths.store.slice(), location.key, session });
    try capture.writeConfiguration(input);
    if (input.require_model)
        try capture.writeRequest(protocol.configure_request.require_model_tail, .{})
    else
        try capture.writeRequest(protocol.configure_request.tail, .{});
    return finishCapture(io, &capture, &location, paths.store.slice(), session, .configure);
}

pub fn captureMessage(io: std.Io, input: MessageInput, target: CaptureTarget) Stepped(CaptureError, CapturedRecord) {
    return stepCapture(io, input, target, writeMessageCapture);
}

fn writeMessageCapture(io: std.Io, paths: *const platform.Paths, input: MessageInput, target: CaptureTarget, input_failure: *?Step) !CapturedRecord {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    if (input.sender_handle) |handle| if (handle.len > protocol.max_sender_handle_bytes) return error.InvalidSenderHandle;
    // Validate the full sender before resolving or opening any capture.
    // The Host authenticates admission, including legitimate self-sends.
    if (input.sender) |sender| {
        var address: protocol.Address = .{};
        try address.store.set(sender.store orelse return error.InvalidRuiAddress);
        try address.session.set(sender.session);
        try address.validate();
    }
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    if (input.configuration != null) {
        if (input.session.len != 0 or location.key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(location.key)) return error.InvalidSession;
    } else try protocol_reply.validateIdentityInputs(location.key, input.session);
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    capture.input_failure = input_failure;
    errdefer capture.abort();
    if (input.sender) |sender| {
        try capture.writeRequest(protocol.message_request.sender_head, .{ paths.store.slice(), location.key, input.session, sender.store.?, sender.session, input.sender_handle });
    } else try capture.writeRequest(protocol.message_request.head, .{ paths.store.slice(), location.key, input.session, input.sender_handle });
    if (input.configuration) |configuration| {
        // Creation intent is visible in the bounded metadata prefix, before
        // either variable payload. Inspection never scans Message content.
        try capture.writeRequest(protocol.message_request.configuration, .{});
        try capture.writeConfiguration(configuration);
    }
    try capture.writeRequest(protocol.message_request.text, .{});
    if (input.text) |value| {
        if (value.len > protocol.max_sqlite_content_bytes) return error.ContentTooLarge;
        try capture.writeJsonString(value);
    } else if (std.mem.eql(u8, input.text_path, "-")) {
        try capture.writeJsonFileBounded(input.text_path, protocol.max_sqlite_content_bytes, true);
    } else try capture.writeJsonFile(input.text_path);
    if (input.configuration != null and input.configuration.?.require_model)
        try capture.writeRequest(protocol.message_request.require_model_tail, .{})
    else
        try capture.writeRequest(protocol.message_request.tail, .{});
    return finishCapture(io, &capture, &location, paths.store.slice(), input.session, .message);
}

fn writeSessionStopCapture(io: std.Io, paths: *const platform.Paths, input: SessionStopInput, location: CaptureTarget.Location) !CapturedRecord {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writeRequest(protocol.session_stop_request, .{ paths.store.slice(), location.key, input.session });
    return finishCapture(io, &capture, &location, paths.store.slice(), input.session, .session_stop);
}

fn writeModelInterruptionCapture(
    io: std.Io,
    paths: *const platform.Paths,
    input: ModelInterruptionInput,
    location: CaptureTarget.Location,
) !CapturedRecord {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writeRequest(protocol.model_interruption_request, .{ paths.store.slice(), location.key, input.session, input.turn_id, input.operation_id });
    return finishCapture(io, &capture, &location, paths.store.slice(), input.session, .model_interruption);
}

pub fn capturePermissionDecision(io: std.Io, input: PermissionDecisionInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    if (input.action_id == 0) return error.InvalidTarget;
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writePermissionDecision(paths.store.slice(), location.key, input);
    return finishCapture(io, &capture, &location, paths.store.slice(), input.session, .permission_decision);
}

fn finishCapture(io: std.Io, capture: *Capture, location: *const CaptureTarget.Location, store: []const u8, session: []const u8, kind: protocol.CommandKind) !CapturedRecord {
    // Pin the temporary inode under capture custody, before exposing its name.
    // This reader observes the final flush, not a later public-path replacement.
    var file = try capture.parent.openFile(io, capture.temporary_name.slice(), .{});
    errdefer file.close(io);
    // A post-publication directory-sync failure returns no transmissible owner,
    // but abort preserves the published name for later explicit recovery.
    try capture.commit();
    const length = try file.length(io);
    const binding = try readCapturedBinding(io, &file);
    if (!(Binding{ .store = store, .key = location.key, .session = session, .kind = kind }).matches(&binding.saved, binding.target)) return error.InvalidRequestRecord;
    return .{ .file = file, .length = length, .saved = binding.saved, .target = binding.target, .replay = location.replay };
}

const Capture = struct {
    io: std.Io,
    // Names the input step that failed; any other failure is the capture's.
    input_failure: ?*?Step = null,
    file: std.Io.File,
    lock_file: std.Io.File,
    parent: std.Io.Dir,
    writer: std.Io.File.Writer,
    final_name: protocol.Bounded(std.Io.Dir.max_name_bytes) = .{},
    temporary_name: protocol.Bounded(std.Io.Dir.max_name_bytes) = .{},
    active: bool = true,
    file_open: bool = true,
    published: bool = false,

    // The caller owns buffer through commit/abort and keeps Capture pointer-stable.
    fn open(io: std.Io, record_path: []const u8, buffer: []u8) !Capture {
        const parent_path = std.fs.path.dirname(record_path) orelse ".";
        const final_name = std.fs.path.basename(record_path);
        if (final_name.len == 0) return error.InvalidRecordPath;
        var parent = try std.Io.Dir.cwd().createDirPathOpen(io, parent_path, .{
            // Linux opens non-iterable directories with O_PATH, which cannot
            // be fsynced after publishing the record.
            .open_options = .{ .iterate = true },
            .permissions = .fromMode(0o700),
        });
        errdefer parent.close(io);
        const stat = try parent.stat(io);
        if (stat.permissions.toMode() & 0o077 != 0) return error.InsecureRecordDirectory;
        var lock_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const lock_name = try std.fmt.bufPrint(&lock_buffer, ".{s}.capture.lock", .{final_name});
        const lock_file = parent.createFile(io, lock_name, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock => return error.RecordCaptureBusy,
            else => return err,
        };
        errdefer lock_file.close(io);
        if (parent.statFile(io, final_name, .{})) |_| return error.RecordAlreadyExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        var temporary_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const temporary = try std.fmt.bufPrint(&temporary_buffer, ".{s}.capture.tmp", .{final_name});
        // This stable lock also owns recovery. Never unlink its inode: another
        // opener could otherwise acquire an unrelated lock for the same record.
        parent.deleteFile(io, temporary) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const file = try parent.createFile(io, temporary, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        var capture = Capture{ .io = io, .file = file, .lock_file = lock_file, .parent = parent, .writer = file.writerStreaming(io, buffer) };
        try capture.final_name.set(final_name);
        try capture.temporary_name.set(temporary);
        return capture;
    }

    fn abort(self: *Capture) void {
        if (!self.active) return;
        if (self.file_open) self.file.close(self.io);
        if (!self.published) self.parent.deleteFile(self.io, self.temporary_name.slice()) catch |err| {
            @import("TerminalText.zig").diagnostic("rui: retained caller capture after cleanup failure: {s}\n", .{@errorName(err)});
        };
        self.lock_file.close(self.io);
        self.parent.close(self.io);
        self.active = false;
    }

    fn commit(self: *Capture) !void {
        try self.writer.flush();
        try self.file.sync(self.io);
        self.file.close(self.io);
        self.file_open = false;
        try self.parent.renamePreserve(
            self.temporary_name.slice(),
            self.parent,
            self.final_name.slice(),
            self.io,
        );
        self.published = true;
        if (std.c.fsync(self.parent.handle) != 0) return error.RecordDirectorySyncFailed;
        self.lock_file.close(self.io);
        self.parent.close(self.io);
        self.active = false;
    }

    fn write(self: *Capture, bytes: []const u8) !void {
        self.writer.interface.writeAll(bytes) catch return self.writer.err orelse error.WriteFailed;
    }

    fn writeJsonString(self: *Capture, value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        std.json.Stringify.encodeJsonString(value, .{}, &self.writer.interface) catch
            return self.writer.err orelse error.WriteFailed;
    }

    /// Writes request JSON from its shape. Every string argument must be UTF-8.
    fn writeRequest(self: *Capture, comptime shape: anytype, args: anytype) !void {
        inline for (args) |argument| {
            const T = @TypeOf(argument);
            if (comptime isByteString(T)) {
                if (!std.unicode.utf8ValidateSlice(argument)) return error.InvalidUtf8;
            } else if (comptime @typeInfo(T) == .optional and isByteString(@typeInfo(T).optional.child)) {
                if (argument) |value| if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
            } else switch (@typeInfo(T)) {
                .int, .comptime_int, .bool, .@"enum", .null => {},
                else => @compileError("writeRequest cannot check a " ++ @typeName(T) ++ " argument"),
            }
        }
        protocol.writeShape(&self.writer.interface, shape, args) catch return self.writer.err orelse error.WriteFailed;
    }

    fn isByteString(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .pointer => |pointer| switch (pointer.size) {
                .slice => pointer.child == u8,
                .one => @typeInfo(pointer.child) == .array and @typeInfo(pointer.child).array.child == u8,
                else => false,
            },
            else => false,
        };
    }

    fn writePermissionDecision(self: *Capture, store: []const u8, key: []const u8, input: PermissionDecisionInput) !void {
        try self.writeRequest(protocol.permission_decision_request, .{ store, key, input.session, input.action_id, input.decision });
    }

    fn writeOptionalPolicy(self: *Capture, value: OptionalPolicy) !void {
        if (!value.present) return self.write("{\"state\":\"omitted\"}");
        const text = value.value orelse return self.write("{\"state\":\"null\"}");
        try self.writeOptionalText(.{ .present = true, .value = text });
    }

    fn writeOptionalText(self: *Capture, value: OptionalText) !void {
        if (!value.present) return self.write("{\"state\":\"omitted\"}");
        try self.write("{\"state\":\"value\",\"value\":");
        try self.writeJsonString(value.value);
        try self.write("}");
    }

    fn writeOptionalFile(self: *Capture, value: OptionalFile, allow_null: bool) !void {
        switch (value.state) {
            .omitted => try self.write("{\"state\":\"omitted\"}"),
            .explicit_null => {
                if (!allow_null) return error.NullNotAllowed;
                try self.write("{\"state\":\"null\"}");
            },
            .value => {
                try self.write("{\"state\":\"value\",\"value\":");
                try self.writeJsonFile(value.path);
                try self.write("}");
            },
        }
    }

    fn writeConfiguration(self: *Capture, input: ConfigureInput) !void {
        try self.write("{\"workspace\":");
        try self.writeOptionalText(input.workspace);
        try self.write(",\"provider\":");
        try self.writeOptionalText(input.provider);
        try self.write(",\"model\":");
        try self.writeOptionalText(input.model);
        try self.write(",\"instructions\":");
        try self.writeOptionalFile(input.instructions, false);
        try self.write(",\"tools\":");
        try self.writeTools(input.tools);
        try self.write(",\"permission_mode\":");
        try self.writeOptionalText(input.permission_mode);
        try self.write(",\"output_schema\":");
        try self.writeOptionalFile(input.output_schema, true);
        try self.write(",\"compaction_trigger\":");
        try self.writeOptionalPolicy(input.compaction_trigger);
        try self.write(",\"output_reservation\":");
        try self.writeOptionalPolicy(input.output_reservation);
        try self.write(",\"reasoning_effort\":");
        try self.writeOptionalPolicy(input.reasoning_effort);
        try self.write(",\"label\":");
        try self.writeOptionalPolicy(input.label);
        try self.write("}");
    }

    fn writeJsonFile(self: *Capture, path: []const u8) !void {
        return self.writeJsonFileBounded(path, protocol.max_sqlite_content_bytes, false);
    }

    fn writeJsonFileBounded(self: *Capture, path: []const u8, limit: u64, require_text: bool) !void {
        const stdin = std.mem.eql(u8, path, "-");
        const read: Step = if (stdin) .stdin_read else .input_file_read;
        var file = if (stdin)
            std.Io.File.stdin()
        else
            std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| return self.failInput(read, err);
        defer if (!stdin) file.close(self.io);
        self.write("\"") catch |err| return self.failInput(read, err);
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var validator = Utf8Validator{};
        var decoded_bytes: u64 = 0;
        while (true) {
            const count = file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return self.failInput(read, err),
            };
            if (count == 0) break;
            const next = std.math.add(u64, decoded_bytes, count) catch return self.failInput(.input_parse, error.ContentTooLarge);
            if (next > limit) return self.failInput(.input_parse, error.ContentTooLarge);
            decoded_bytes = next;
            validator.feed(buffer[0..count]) catch |err| return self.failInput(.input_parse, err);
            // Default encoding copies non-ASCII bytes unchanged, including a UTF-8
            // sequence split across reads; the streaming validator owns validity.
            std.json.Stringify.encodeJsonStringChars(buffer[0..count], .{}, &self.writer.interface) catch
                return self.writer.err orelse error.WriteFailed;
        }
        if (!validator.complete()) return self.failInput(.input_parse, error.InvalidUtf8);
        if (require_text and decoded_bytes == 0) return self.failInput(.input_parse, error.EmptyMessageInput);
        try self.write("\"");
    }

    fn failInput(self: *Capture, step: Step, err: anytype) @TypeOf(err) {
        if (self.input_failure) |slot| slot.* = step;
        return err;
    }

    fn writeTools(self: *Capture, tools: ?[]const u8) !void {
        const value = tools orelse return self.write("{\"state\":\"omitted\"}");
        try self.write("{\"state\":\"value\",\"value\":[");
        if (!std.mem.eql(u8, value, "none")) {
            if (!std.mem.eql(u8, value, "bash")) return error.UnknownTool;
            try self.writeJsonString(value);
        }
        try self.write("]}");
    }
};

const Utf8Validator = struct {
    bytes: [4]u8 = undefined,
    used: u3 = 0,
    expected: u3 = 0,

    fn feed(self: *Utf8Validator, input: []const u8) !void {
        for (input) |byte| {
            if (self.used == 0) {
                if (byte < 0x80) continue;
                self.expected = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidUtf8;
            }
            self.bytes[self.used] = byte;
            self.used += 1;
            if (self.used == self.expected) {
                _ = std.unicode.utf8Decode(self.bytes[0..self.expected]) catch return error.InvalidUtf8;
                self.used = 0;
                self.expected = 0;
            }
        }
    }

    fn complete(self: *const Utf8Validator) bool {
        return self.used == 0;
    }
};

// Transfers this one socket to the response reader; every failure closes here.
fn openRead(requests: Requests, paths: *const platform.Paths, comptime route: []const u8, body: []const u8) !std.posix.fd_t {
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(requests, address, null);
    errdefer closeSocket(requests.io, fd);
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST " ++ route ++ " HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 2\r\n\r\n", .{body.len});
    try writeAllRequest(requests, fd, header, null);
    try writeAllRequest(requests, fd, body, null);
    return fd;
}

pub const SendError = ErrorOf(std.Io.net.UnixAddress.init) || ErrorOf(connectRequest) || ErrorOf(uploadRequest) || ErrorOf(readCommandResponseRequest);
pub const MutationSendError = SendError || ErrorOf(platform.resolveClientPaths) || error{Cancelled};

fn sendSource(
    requests: Requests,
    paths: *const platform.Paths,
    route: []const u8,
    timing: ResponseTiming,
    length: u64,
    file: ?*std.Io.File,
    bytes: ?[]const u8,
    instance: ?*const protocol.InstanceId,
    reply_buffer: *ReplyBuffer,
    until: ?i128,
) Stepped(SendError, protocol_reply.CommandReply) {
    const address = std.Io.net.UnixAddress.init(paths.socket.slice()) catch |err| return .fail(.endpoint, err);
    const fd = connectRequest(requests, address, until) catch |err| return .fail(.connect, err);
    defer closeSocket(requests.io, fd);
    uploadRequest(requests, fd, route, timing, length, file, bytes, instance, until) catch |err| return .fail(.upload, err);
    const reply = readCommandResponseRequest(requests, fd, reply_buffer, timing, until) catch |err| return .fail(.admission_response, err);
    return .{ .done = reply };
}

fn uploadRequest(
    requests: Requests,
    fd: std.posix.fd_t,
    route: []const u8,
    timing: ResponseTiming,
    length: u64,
    file: ?*std.Io.File,
    bytes: ?[]const u8,
    instance: ?*const protocol.InstanceId,
    until: ?i128,
) !void {
    var header_buffer: [512]u8 = undefined;
    var used = (try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 2\r\n", .{ route, length })).len;
    if (instance) |id| {
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Host-Instance: {s}\r\n", .{std.fmt.bytesToHex(id.*, .lower)})).len;
    }
    if (requests.drop_reply) |drop| {
        std.debug.assert(std.meta.eql(timing, ResponseTiming.mutation));
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Test-Drop-Reply: {s}\r\n", .{drop})).len;
    }
    used += (try std.fmt.bufPrint(header_buffer[used..], "\r\n", .{})).len;
    try writeAllRequest(requests, fd, header_buffer[0..used], until);
    const source = file orelse return writeAllRequest(requests, fd, bytes.?, until);
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var sent: u64 = 0;
    while (sent < length) {
        try requests.check();
        const wanted: usize = @intCast(@min(length - sent, buffer.len));
        const count = try source.readPositionalAll(requests.io, buffer[0..wanted], sent);
        if (count != wanted) return error.RecordChangedDuringSend;
        try writeAllRequest(requests, fd, buffer[0..count], until);
        sent += count;
    }
}

fn closeSocket(io: std.Io, fd: std.posix.fd_t) void {
    // Match UnixAddress.connect's placeholder address; Unix sockets have no IP.
    const socket: std.Io.net.Socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } };
    socket.close(io);
}

fn connectRequest(requests: Requests, address: std.Io.net.UnixAddress, until: ?i128) !std.posix.fd_t {
    try requests.check();
    if (until != null or requests.cancellation != null) return connectUntil(requests, address.path, until);
    // Keep ordinary connection errors and std.Io acquisition semantics.
    const stream = try address.connect(requests.io);
    errdefer stream.close(requests.io);
    try addNonblocking(stream.socket.handle);
    return stream.socket.handle;
}

fn addNonblocking(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    const nonblocking: c_int = @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, flags | nonblocking) < 0) return error.UnixConnectFailed;
}

fn connectUntil(requests: Requests, path: []const u8, deadline: ?i128) !std.posix.fd_t {
    const io = requests.io;
    const fd = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(fd) != .SUCCESS) return error.UnixConnectFailed;
    const socket: std.posix.fd_t = @intCast(fd);
    errdefer _ = std.c.close(socket);
    if (std.c.fcntl(socket, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC)) < 0) return error.UnixConnectFailed;
    try addNonblocking(socket);
    var address: std.posix.sockaddr.un = .{ .path = undefined };
    @memcpy(address.path[0..path.len], path);
    // Like std.Io, a maximum-sized Unix path has no spare terminator byte.
    const terminated = path.len < address.path.len;
    if (terminated) address.path[path.len] = 0;
    const size: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + path.len + @intFromBool(terminated));
    if (@hasField(std.posix.sockaddr.un, "len")) address.len = @intCast(size);
    while (true) {
        try requests.check();
        if (deadline) |end| if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= end) return error.TransferInactive;
        const result_code = std.posix.errno(std.c.connect(socket, @ptrCast(&address), size));
        if (result_code != .SUCCESS) try requests.check();
        switch (result_code) {
            .SUCCESS => break,
            .INTR => continue,
            .INPROGRESS => {
                if (!try waitRequest(requests, socket, std.posix.POLL.OUT, deadline)) return error.TransferInactive;
                var result: c_int = 0;
                var result_len: std.posix.socklen_t = @sizeOf(c_int);
                if (std.c.getsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &result, &result_len) < 0 or result_len != @sizeOf(c_int) or result < 0) return error.UnixConnectFailed;
                if (result != 0) return connectFailure(@fromBackingInt(@intCast(result)));
                break;
            },
            .AGAIN => {
                // Linux AF_UNIX backlog AGAIN has not begun a connection.
                // Writable/HUP plus SO_ERROR=0 is not a successful connect.
                var ms: c_int = 100;
                if (deadline) |end| ms = @intCast(@min(ms, @divTrunc(end - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
                if (ms <= 0) return error.TransferInactive;
                var none: [0]std.c.pollfd = .{};
                const slept = std.c.poll(&none, 0, ms);
                try requests.check();
                switch (std.posix.errno(slept)) {
                    .SUCCESS, .INTR => {},
                    else => return error.PollFailed,
                }
            },
            else => |err| return connectFailure(err),
        }
    }
    try requests.check();
    return socket;
}

fn connectFailure(code: std.posix.E) error{ AccessDenied, PermissionDenied, FileNotFound, NotDir, SymLinkLoop, ReadOnlyFileSystem, UnixConnectFailed } {
    return switch (code) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .ROFS => error.ReadOnlyFileSystem,
        else => error.UnixConnectFailed,
    };
}

const ResponseKind = enum { command_json, result_text, content_bytes };

const ResponseHead = struct {
    status: u16,
    content_length: u64,
    kind: ResponseKind,
    total: ?u64 = null,
    next: ?u64 = null,
};

fn readResponseHead(fd: std.posix.fd_t) !ResponseHead {
    return readResponseHeadUntil(.{ .io = std.Io.Threaded.global_single_threaded.io() }, fd, ResponseTiming.transfer, null);
}

fn readResponseHeadWithInactivity(fd: std.posix.fd_t, inactivity_ms: i32) !ResponseHead {
    return readResponseHeadUntil(.{ .io = std.Io.Threaded.global_single_threaded.io() }, fd, .{ .inactivity_ms = inactivity_ms }, null);
}

fn readResponseHeadUntil(requests: Requests, fd: std.posix.fd_t, timing: ResponseTiming, until: ?i128) !ResponseHead {
    var header_buffer: [protocol.max_header_bytes]u8 = undefined;
    const first_deadline = timing.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, until, false);
    const first_count = try readRequest(requests, fd, header_buffer[0..1], first_deadline);
    if (first_count == 0) return error.TruncatedResponse;
    var used: usize = first_count;
    while (used < header_buffer.len) {
        if (used >= 4 and std.mem.eql(u8, header_buffer[used - 4 .. used], "\r\n\r\n")) break;
        const deadline = timing.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, until, true);
        const count = try readRequest(requests, fd, header_buffer[used .. used + 1], deadline);
        if (count == 0) return error.TruncatedResponse;
        used += count;
    } else return error.ResponseHeaderTooLarge;
    return parseResponseHead(header_buffer[0..used]);
}

// Rui uses Content-Length framing. Validate the entire bounded header before
// interpreting any field; an ignored extension cannot repair invalid syntax.
fn parseResponseHead(bytes: []const u8) !ResponseHead {
    if (!std.mem.endsWith(u8, bytes, "\r\n\r\n")) return error.InvalidResponse;
    var lines = std.mem.splitSequence(u8, bytes[0 .. bytes.len - 4], "\r\n");
    const status_line = lines.next() orelse return error.InvalidResponse;
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 ") or status_line.len < "HTTP/1.1 200 X".len or
        status_line[12] != ' ' or std.mem.trim(u8, status_line[13..], " \t").len == 0) return error.InvalidResponse;
    const code = status_line[9..12];
    for (code) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidResponse;
    for (status_line[13..]) |byte| if ((byte < ' ' and byte != '\t') or byte == 0x7f) return error.InvalidResponse;
    const status = try std.fmt.parseInt(u16, code, 10);
    var length: ?u64 = null;
    var wire_ok: ?bool = null;
    var kind: ?ResponseKind = null;
    var total: ?u64 = null;
    var next: ?u64 = null;
    while (lines.next()) |line| {
        if (line.len == 0) return error.InvalidResponse;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
        const name = line[0..colon];
        if (name.len == 0) return error.InvalidResponse;
        for (name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) == null)
                return error.InvalidResponse;
        }
        for (line[colon + 1 ..]) |byte| {
            if (byte != '\t' and (byte < ' ' or byte == 0x7f)) return error.InvalidResponse;
        }
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            if (length != null) return error.InvalidResponse;
            if (value.len == 0) return error.InvalidResponse;
            for (value) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidResponse;
            length = std.fmt.parseInt(u64, value, 10) catch return error.InvalidResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Wire-Version")) {
            if (wire_ok != null) return error.InvalidResponse;
            wire_ok = std.mem.eql(u8, value, protocol.wire_version);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Content-Bytes")) {
            if (total != null) return error.InvalidResponse;
            total = try std.fmt.parseInt(u64, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "X-Rui-Next-Offset")) {
            if (next != null) return error.InvalidResponse;
            next = try std.fmt.parseInt(u64, value, 10);
        } else if (std.ascii.eqlIgnoreCase(name, "Content-Type")) {
            if (kind != null) return error.InvalidResponse;
            kind = if (std.ascii.eqlIgnoreCase(value, "application/json"))
                .command_json
            else if (std.ascii.eqlIgnoreCase(value, "text/plain; charset=utf-8"))
                .result_text
            else if (std.ascii.eqlIgnoreCase(value, "application/octet-stream"))
                .content_bytes
            else
                return error.InvalidResponse;
        } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding") or
            std.ascii.eqlIgnoreCase(name, "Content-Encoding"))
        {
            return error.InvalidResponse;
        }
    }
    if (wire_ok != true) return error.WrongWireVersion;
    return .{
        .status = status,
        .content_length = length orelse return error.InvalidResponse,
        .kind = kind orelse return error.InvalidResponse,
        .total = total,
        .next = next,
    };
}

fn readCommandResponse(fd: std.posix.fd_t, reply_buffer: *ReplyBuffer) !protocol_reply.CommandReply {
    return readCommandResponseRequest(.{ .io = std.Io.Threaded.global_single_threaded.io() }, fd, reply_buffer, .{}, null);
}

fn readCommandResponseRequest(requests: Requests, fd: std.posix.fd_t, reply_buffer: *ReplyBuffer, timing: ResponseTiming, until: ?i128) !protocol_reply.CommandReply {
    reply_buffer.len = 0;
    const head = try readResponseHeadUntil(requests, fd, timing, until);
    if (head.kind != .command_json) return error.InvalidResponse;
    return readCommandBodyUntil(requests, fd, head, reply_buffer, timing, until);
}

fn readResultResponse(
    io: std.Io,
    fd: std.posix.fd_t,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ResultReply {
    return readResultResponseSink(.{ .io = io }, fd, destination, reply_buffer);
}

fn readResultResponseSink(
    requests: Requests,
    fd: std.posix.fd_t,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ResultReply {
    reply_buffer.len = 0;
    const head = try readResponseHeadUntil(requests, fd, .{}, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        return .{ .command = try readCommandBodyUntil(requests, fd, head, reply_buffer, .{}, null) };
    }
    if (head.kind != .result_text) return error.InvalidResponse;
    try readResponseBody(requests, fd, head.content_length, sink, .withhold_final_window);
    return .{ .answer = .{ .bytes = head.content_length } };
}

fn readReportResponse(
    requests: Requests,
    fd: std.posix.fd_t,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ReportReply {
    reply_buffer.len = 0;
    const head = try readResponseHeadUntil(requests, fd, .{}, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        return .{ .command = try readCommandBodyUntil(requests, fd, head, reply_buffer, .{}, null) };
    }
    if (head.kind != .command_json) return error.InvalidResponse;
    try readResponseBody(requests, fd, head.content_length, sink, .stream);
    return .{ .report = .{ .bytes = head.content_length } };
}

// One delivery policy for answer/report windows. The socket caller and sink
// keep custody through the last feed; completion has no retrospective stop.
// Answers withhold their final window until every advertised byte and EOF
// arrived, so a truncated answer never ends in complete-looking bytes.
fn readResponseBody(requests: Requests, fd: std.posix.fd_t, length: u64, sink: anytype, delivery: enum { stream, withhold_final_window }) !void {
    const io = requests.io;
    var remaining = length;
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    if (length == 0 and delivery == .withhold_final_window) try completeContentEOF(requests, fd, undefined, null);
    while (remaining != 0) {
        const wanted: usize = @intCast(@min(remaining, buffer.len));
        var filled: usize = 0;
        while (filled != wanted) {
            const count = try readRequest(requests, fd, buffer[filled..wanted], ResponseTiming.transfer.deadline(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, null, true));
            if (count == 0) return error.TruncatedResponse;
            filled += count;
            if (delivery == .stream) break;
        }
        remaining -= filled;
        if (remaining == 0 and delivery == .withhold_final_window) try completeContentEOF(requests, fd, undefined, null);
        if (@TypeOf(sink) == std.Io.File)
            try sink.writeStreamingAll(io, buffer[0..filled])
        else
            try sink.feed(buffer[0..filled]);
    }
}

fn readCommandBodyUntil(requests: Requests, fd: std.posix.fd_t, head: ResponseHead, reply_buffer: *ReplyBuffer, timing: ResponseTiming, until: ?i128) !protocol_reply.CommandReply {
    reply_buffer.len = 0;
    errdefer reply_buffer.len = 0;
    if (head.content_length > protocol.max_response_bytes) return error.ResponseTooLarge;
    const body_length: usize = @intCast(head.content_length);
    var offset: usize = 0;
    while (offset < body_length) {
        const deadline = timing.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, until, true);
        const count = try readRequest(requests, fd, reply_buffer.bytes[offset..body_length], deadline);
        if (count == 0) return error.TruncatedResponse;
        offset += count;
    }
    reply_buffer.len = body_length;
    return .{ .status = head.status, .body = reply_buffer.slice() };
}

// Stop wins when observed at a service point, before timeout/error. A quantum
// is not an end-to-end guarantee: caller-owned file/sink work can block.
fn waitRequest(requests: Requests, fd: std.posix.fd_t, events: i16, deadline: ?i128) !bool {
    while (true) {
        try requests.check();
        var milliseconds: c_int = if (requests.cancellation != null) 100 else -1;
        if (deadline) |end| {
            const left = end - std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds;
            if (left <= 0) return false;
            milliseconds = @intCast(@min(if (milliseconds < 0) std.math.maxInt(c_int) else milliseconds, @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        }
        var poll_fd = [_]std.c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        const result = std.c.poll(&poll_fd, poll_fd.len, milliseconds);
        try requests.check();
        switch (std.posix.errno(result)) {
            .SUCCESS => if (result != 0) {
                if (deadline) |end| if (std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds >= end) return false;
                return true;
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn readRequest(requests: Requests, fd: std.posix.fd_t, buffer: []u8, deadline: ?i128) !usize {
    while (true) {
        if (!try waitRequest(requests, fd, std.posix.POLL.IN, deadline)) return error.ResponseInactive;
        const count = std.c.read(fd, buffer.ptr, buffer.len);
        if (count == 0) try requests.check();
        if (count >= 0) return @intCast(count);
        try requests.check();
        switch (std.posix.errno(count)) {
            .AGAIN, .INTR => continue,
            .CANCELED => return error.Canceled,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketUnconnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BADF, .TIMEDOUT => return error.Unexpected,
            else => return std.posix.unexpectedErrno(std.posix.errno(count)),
        }
    }
}

fn writeAll(fd: std.posix.fd_t, value: []const u8) !void {
    return writeAllRequest(.{ .io = std.Io.Threaded.global_single_threaded.io() }, fd, value, null);
}

fn writeAllRequest(requests: Requests, fd: std.posix.fd_t, value: []const u8, until: ?i128) !void {
    const io = requests.io;
    var offset: usize = 0;
    var deadline = ResponseTiming.transfer.deadline(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, until, true).?;
    while (offset < value.len) {
        if (!try waitRequest(requests, fd, std.posix.POLL.OUT, deadline)) return error.TransferInactive;
        const count = std.c.write(fd, value[offset..].ptr, value.len - offset);
        if (count < 0) {
            try requests.check();
            if (std.posix.errno(count) == .AGAIN or std.posix.errno(count) == .INTR) continue;
            return error.WriteFailed;
        }
        if (count == 0) {
            try requests.check();
            return error.ConnectionClosed;
        }
        offset += @intCast(count);
        if (until == null) deadline = ResponseTiming.transfer.deadline(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds, null, true).?;
    }
}

const empty_test_response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 0\r\n" ++
    "Connection: close\r\n" ++
    "X-Rui-Wire-Version: 2\r\n\r\n";

fn socketPair() ![2]std.posix.fd_t {
    var sockets: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    return sockets;
}

test "Host processing wait starts inactivity only after the first response byte" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, struct {
        fn respond(fd: std.posix.fd_t) void {
            defer closeTestDescriptor(fd);
            std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch return;
            writeAll(fd, empty_test_response) catch {};
        }
    }.respond, .{sockets[1]});
    defer writer.join();
    const head = try readResponseHeadWithInactivity(sockets[0], 10);
    try std.testing.expectEqual(@as(u16, 200), head.status);
}

test "Host-info first byte is bounded independently of normal processing waits" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, struct {
        fn respond(fd: std.posix.fd_t) void {
            defer closeTestDescriptor(fd);
            std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch return;
            writeAll(fd, empty_test_response) catch {};
        }
    }.respond, .{sockets[1]});
    defer writer.join();
    var buffer: ReplyBuffer = .{};
    const until = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
    try std.testing.expectError(error.ResponseInactive, readCommandResponseRequest(.{ .io = std.testing.io }, sockets[0], &buffer, .{}, until));
}

test "response deadlines include partial header and body" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 2\r\n\r\nab";
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
    for ([_]bool{ false, true }) |mutation| {
        for ([_]usize{ 1, body_start + 1 }) |prefix_len| {
            const sockets = try socketPair();
            defer closeTestDescriptor(sockets[0]);
            try addNonblocking(sockets[0]);
            try writeAll(sockets[1], response[0..prefix_len]);
            const writer = try std.Thread.spawn(.{}, struct {
                fn respond(fd: std.posix.fd_t, rest: []const u8) void {
                    defer closeTestDescriptor(fd);
                    std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch return;
                    writeAll(fd, rest) catch {};
                }
            }.respond, .{ sockets[1], response[prefix_len..] });
            defer writer.join();
            var buffer: ReplyBuffer = .{};
            const until: ?i128 = if (mutation) null else std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
            const timing: ResponseTiming = if (mutation) .{ .inactivity_ms = 10, .wait_for_first_byte = false } else .{};
            try std.testing.expectError(error.ResponseInactive, readCommandResponseRequest(.{ .io = std.testing.io }, sockets[0], &buffer, timing, until));
            try std.testing.expectEqual(@as(usize, 0), buffer.len);
        }
    }
}

test "mutation response progress renews inactivity through header and body" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const Producer = struct {
        fn run(fd: std.posix.fd_t) void {
            defer closeTestDescriptor(fd);
            writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 2\r\n") catch return;
            std.Io.sleep(std.testing.io, .fromMilliseconds(4_500), .awake) catch return;
            writeAll(fd, "\r\n{") catch return;
            // Still exceeds five seconds overall, without a second long gap.
            std.Io.sleep(std.testing.io, .fromMilliseconds(1_000), .awake) catch return;
            writeAll(fd, "}") catch return;
        }
    };
    const writer = try std.Thread.spawn(.{}, Producer.run, .{sockets[1]});
    defer writer.join();
    var buffer: ReplyBuffer = .{};
    const reply = try readCommandResponseRequest(.{ .io = std.testing.io }, sockets[0], &buffer, ResponseTiming.mutation, null);
    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("{}", reply.body);
}

test "Host processing wait does not consume response transfer inactivity" {
    // The fast test above checks the same boundary; this opt-in witness checks
    // the production 60-second value with real elapsed time.
    if (!std.mem.eql(u8, std.process.Environ.getPosix(std.testing.environ, "RUI_TEST_EXACT_INACTIVITY") orelse "", "1"))
        return error.SkipZigTest;
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, struct {
        fn respond(fd: std.posix.fd_t) void {
            defer closeTestDescriptor(fd);
            std.Io.sleep(std.testing.io, .fromSeconds(61), .awake) catch return;
            writeAll(fd, empty_test_response) catch {};
        }
    }.respond, .{sockets[1]});
    defer writer.join();
    var buffer: ReplyBuffer = .{};
    const reply = try readCommandResponse(sockets[0], &buffer);
    try std.testing.expectEqual(@as(u16, 200), reply.status);
}

test "response transfer inactivity begins after the first byte" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, struct {
        fn respond(fd: std.posix.fd_t) void {
            defer closeTestDescriptor(fd);
            std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch return;
            writeAll(fd, empty_test_response[1..]) catch {};
        }
    }.respond, .{sockets[1]});
    defer writer.join();
    try writeAll(sockets[1], empty_test_response[0..1]);
    try std.testing.expectError(
        error.ResponseInactive,
        readResponseHeadWithInactivity(sockets[0], 10),
    );
}

test "response closure and truncation stay explicit" {
    {
        const sockets = try socketPair();
        defer closeTestDescriptor(sockets[0]);
        closeTestDescriptor(sockets[1]);
        try std.testing.expectError(error.TruncatedResponse, readResponseHead(sockets[0]));
    }
    {
        const sockets = try socketPair();
        defer closeTestDescriptor(sockets[0]);
        try writeAll(
            sockets[1],
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 2\r\n\r\nx",
        );
        closeTestDescriptor(sockets[1]);
        var buffer: ReplyBuffer = .{};
        try std.testing.expectError(error.TruncatedResponse, readCommandResponse(sockets[0], &buffer));
    }
}

test "response framing rejects ambiguous or malformed fields before interpreting body" {
    for ([_][]const u8{
        "Content-Length : 0\r\n",
        "Content-Length: +0\r\n",
        "Content-Length: 0_0\r\n",
        "Transfer-Encoding: chunked\r\nContent-Length: 0\r\n",
        "Content-Length: 0\r\nTransfer-Encoding: identity\r\n",
        "Bad Name: value\r\nContent-Length: 0\r\n",
        "X-Extra: valid\x01not\r\nContent-Length: 0\r\n",
        "X-Extra: valid\r\n folded\r\nContent-Length: 0\r\n",
    }) |fields| {
        const sockets = try socketPair();
        defer closeTestDescriptor(sockets[0]);
        defer closeTestDescriptor(sockets[1]);
        var response: [512]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 2\r\n{s}\r\n", .{fields});
        try writeAll(sockets[1], bytes);
        try std.testing.expectError(error.InvalidResponse, readResponseHead(sockets[0]));
    }
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    defer closeTestDescriptor(sockets[1]);
    try writeAll(sockets[1], "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 00\r\nX-Rui-Wire-Version: 2\r\nX-Extra: one\r\nx-extra: two\r\n\r\n");
    try std.testing.expectEqual(@as(u16, 200), (try readResponseHead(sockets[0])).status);
}

test "client activity peer boundary rejects noncanonical IDs and owns canonical labels" {
    for ([_][]const u8{ "k7m2qx", "09azvw", "", "short", "1234567", "K7m2qx", "k7m2qi", "k7m2ql", "k7m2qo", "k7m2qu", "k7\x00qx", "雪雪", "old/name", "01234567-89ab-4cde-8012-3456789abcde" }, 0..) |session, index| {
        var body: protocol.RequestBuffer = .{};
        try body.append("{\"version\":\"2\",\"type\":\"activity_page\",\"end\":\"1\",\"direction\":\"forward\",\"items\":[{\"position\":\"1\",\"ordinal\":\"0\",\"at\":\"1\",\"value\":{\"send_failed\":{\"key\":\"key\\u0000雪\",\"target\":{\"session\":");
        try body.appendJsonString(session);
        try body.append("},\"code\":\"invalid_sender_handle\"}}}],\"more\":false,\"call_activity\":{\"total\":\"0\",\"entries\":[]},\"work\":{\"state\":{\"kind\":\"idle\",\"since\":\"1\"},\"turn\":null,\"operation\":null,\"first_action\":null,\"revision\":\"1\",\"workspace\":\"/w\"}}");
        if (index < 2) {
            const page = try protocol_reply.ActivityPage.parse(body.slice(), .{});
            @memset(body.bytes[0..body.len], 'x');
            try std.testing.expectEqualStrings(session, page.facts.items[0].value.send_failed.target.session.slice());
            try std.testing.expectEqualStrings("key\x00雪", page.facts.items[0].value.send_failed.key.slice());
        } else try std.testing.expectError(error.InvalidResponse, protocol_reply.ActivityPage.parse(body.slice(), .{}));
    }
}

test "client read boundaries reject noncanonical Sessions before path or socket access" {
    const requests: Requests = .{ .io = std.testing.io };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "destination", .{ .read = true });
    defer file.close(std.testing.io);
    var reply: ReplyBuffer = .{};
    for ([_][]const u8{ "", "short", "1234567", "K7m2qx", "k7m2qi", "k7m2ql", "k7m2qo", "k7m2qu", "k7\x00qx", "雪雪", "old/name", "01234567-89ab-4cde-8012-3456789abcde" }) |session| {
        try std.testing.expectError(error.InvalidSession, protocol_reply.MessageAddress.init("/never-open", session, "key\x00雪"));
        try std.testing.expectError(error.InvalidSession, requests.inspectSession("/never-open", session, .current, file, &reply));
        try std.testing.expectError(error.InvalidSession, requests.exportFailedResponse("/never-open", session, .{ .operation = 1, .attempt = 1, .part = .metadata }, file, &reply));
        try std.testing.expectError(error.InvalidTarget, requests.readActionArguments("/never-open", session, 1, file, &reply));
        try std.testing.expectError(error.InvalidTarget, requests.readActionCallId("/never-open", session, 1, file, &reply));
        try std.testing.expectError(error.InvalidSession, requests.conversationPage("/never-open", session, .{ .end = 0 }));
        try std.testing.expectError(error.InvalidSession, requests.readConversationContent("/never-open", session, 1, 0, null, file));
        try std.testing.expectError(error.InvalidSession, requests.proposalPage("/never-open", session, .{}));
        try std.testing.expectError(error.InvalidSession, requests.readProposalField("/never-open", session, 1, .name, null, file));
        try std.testing.expectError(error.InvalidSession, requests.activityPage("/never-open", session, .{}));
        try std.testing.expectError(error.InvalidSession, requests.readActivityContent("/never-open", session, 1, 0, null, file));
    }
    try std.testing.expectEqual(@as(u64, 0), try file.length(std.testing.io));
}

test "client capture rejects noncanonical Session references before publication" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/invalid-record", .{root});
    const target: CaptureTarget = .{ .explicit = .{ .record = path, .key = "key\x00雪" } };
    for ([_][]const u8{ "", "short", "1234567", "K7m2qx", "k7m2qi", "k7m2ql", "k7m2qo", "k7m2qu", "k7\x00qx", "雪雪", "old/name", "01234567-89ab-4cde-8012-3456789abcde" }) |session| {
        inline for (comptime std.meta.tags(protocol.CommandKind)) |kind| {
            const result: anyerror!CapturedRecord = switch (kind) {
                .configure => captureConfigure(io, .{ .store = root, .session = .{ .named = session } }, target).get(),
                .message => captureMessage(io, .{ .store = root, .session = session, .text_path = "", .text = "input\x00雪" }, target).get(),
                .session_stop => captureSessionStop(io, .{ .store = root, .session = session }, target),
                .model_interruption => captureModelInterruption(io, .{ .store = root, .session = session, .turn_id = 1, .operation_id = 1 }, target),
                .permission_decision => capturePermissionDecision(io, .{ .store = root, .session = session, .action_id = 1 }, target),
            };
            if (result) |record| {
                var unexpected = record;
                unexpected.close(io);
                std.debug.print("accepted noncanonical {s} capture\n", .{@tagName(kind)});
                return error.AcceptedInvalidSession;
            } else |err| try std.testing.expectEqual(error.InvalidSession, err);
            try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "invalid-record", .{}));
        }
    }
}

test "client recovery rejects noncanonical Session references without retransmission" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const handle = "01234567-89ab-4cde-8012-3456789abcde";
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(root, handle, &path_buffer);
    for ([_][]const u8{ "", "short", "1234567", "K7m2qx", "k7m2qi", "k7m2ql", "k7m2qo", "k7m2qu", "k7\x00qx", "雪雪", "old/name", handle }) |session| {
        inline for (comptime std.meta.tags(protocol.CommandKind)) |kind| {
            // Empty Configure is creation intent, not an invalid reference.
            if (kind != .configure or session.len != 0) {
                var body: protocol.RequestBuffer = .{};
                try body.appendFmt("{{\"version\":\"2\",\"kind\":\"{s}\",\"store\":", .{@tagName(kind)});
                try body.appendJsonString(root);
                try body.append(",\"key\":\"" ++ handle ++ "\",");
                try body.append(if (kind == .model_interruption) "\"target\":{\"session\":" else "\"session\":");
                try body.appendJsonString(session);
                try body.append(switch (kind) {
                    .configure => ",\"configuration\":{}}",
                    .message => ",\"text\":{\"state\":\"value\",\"value\":\"input\\u0000雪\"}}",
                    .session_stop => "}",
                    .model_interruption => ",\"turn\":\"1\",\"operation\":\"1\"}}",
                    .permission_decision => ",\"action\":\"1\",\"decision\":\"deny\"}",
                });
                const file = try tmp.dir.createFile(io, handle ++ ".json", .{});
                try file.writeStreamingAll(io, body.slice());
                file.close(io);
                if (openCaptured(io, .{ .generated = .{ .directory = root, .handle = handle } })) |record| {
                    var unexpected = record;
                    unexpected.close(io);
                    std.debug.print("accepted noncanonical {s} recovery\n", .{@tagName(kind)});
                    return error.AcceptedInvalidSession;
                } else |err| try std.testing.expectEqual(error.InvalidRequestRecord, err);
                try std.testing.expectError(error.InvalidRequestRecord, inspectCaptured(io, root, handle));
                try std.testing.expectError(error.InvalidRequestRecord, testResend(io, .{ .explicit = .{ .store = root, .record = path, .kind = kind } }));
            }
        }
    }
}

test "capture configure requests a Store allocated Session and retains model admission" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_]struct { trigger: ?[]const u8, effort: OptionalPolicy }{
        .{ .trigger = "100000", .effort = .{ .present = true, .value = "high" } },
        .{ .trigger = null, .effort = .{ .present = true } },
        .{ .trigger = null, .effort = .{} },
    }) |case| {
        const trigger = case.trigger;
        var captured = try captureConfigure(io, .{
            .store = root,
            .session = .create,
            .require_model = true,
            .compaction_trigger = .{ .present = true, .value = trigger },
            .output_reservation = .{ .present = true, .value = if (trigger != null) "16384" else null },
            .reasoning_effort = case.effort,
        }, .{ .generated = root }).get();
        const saved = captured.identity().*;
        var bytes: [2048]u8 = undefined;
        const count = blk: {
            defer captured.close(io);
            break :blk try captured.file.readPositionalAll(io, &bytes, 0);
        };
        try std.testing.expect(validRequestHandle(saved.key.slice()));
        // Creation has no caller-selected identity. Recovery retransmits this
        // same intent; the Store returns the one ID saved with the command.
        try std.testing.expectEqualStrings("", saved.session.slice());
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..count], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(saved.key.slice(), parsed.value.object.get("key").?.string);
        try std.testing.expectEqualStrings("", parsed.value.object.get("session").?.string);
        try std.testing.expect(parsed.value.object.get("require_model").?.bool);
        const settings = parsed.value.object.get("configuration").?.object;
        try std.testing.expect(settings.contains("reasoning_effort"));
        const effort = settings.get("reasoning_effort").?.object;
        try std.testing.expectEqualStrings(if (!case.effort.present) "omitted" else if (case.effort.value == null) "null" else "value", effort.get("state").?.string);
        if (case.effort.value) |_| try std.testing.expectEqualStrings("high", effort.get("value").?.string);
        if (trigger != null) {
            try std.testing.expectEqualStrings("100000", settings.get("compaction_trigger").?.object.get("value").?.string);
            try std.testing.expectEqualStrings("16384", settings.get("output_reservation").?.object.get("value").?.string);
        } else {
            try std.testing.expectEqualStrings("null", settings.get("compaction_trigger").?.object.get("state").?.string);
            try std.testing.expectEqualStrings("null", settings.get("output_reservation").?.object.get("state").?.string);
        }
        var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = saved.key.slice() } });
        defer recovered.close(io);
        try std.testing.expectEqualStrings("", recovered.identity().session.slice());
        var recovered_bytes: [2048]u8 = undefined;
        const recovered_count = try recovered.file.readPositionalAll(io, &recovered_bytes, 0);
        try std.testing.expectEqualSlices(u8, bytes[0..count], recovered_bytes[0..recovered_count]);
    }
}

test "capture mutation binding streams complete escaped input and rejects late ambiguity" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var text: [3 * protocol.content_window_bytes + 7]u8 = undefined;
    @memset(&text, 'x');
    @memcpy(text[4093..][0..7], "\x00\n€µ");
    var captured = try captureMessage(io, .{ .store = root, .session = "k7m2qx", .text = &text, .text_path = "" }, .{ .generated = root }).get();
    const saved = captured.saved;
    const expected = protocol.contentDigest(&text);
    try std.testing.expectEqual(@as(u64, text.len), captured.target.message.bytes);
    try std.testing.expectEqualSlices(u8, &expected, &captured.target.message.digest);
    captured.close(io);
    var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = saved.key.slice() } });
    try std.testing.expectEqualSlices(u8, &expected, &recovered.target.message.digest);
    recovered.close(io);
    // Listing is an identity projection, not permission to transmit. It must
    // not traverse every historical payload to recover one local handle.
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, try requestPath(root, saved.key.slice(), &path), .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, " trailing", try file.length(io));
    try std.testing.expectEqualStrings("k7m2qx", (try inspectCaptured(io, root, saved.key.slice())).session.slice());
    try std.testing.expectError(error.InvalidRequestRecord, openCaptured(io, .{ .generated = .{ .directory = root, .handle = saved.key.slice() } }));
}

/// What `rui request recover` does with a saved record.
fn testResend(io: std.Io, saved: SavedRecord) !protocol_reply.MutationReply {
    var record = try openCaptured(io, saved);
    defer record.close(io);
    var reply: ReplyBuffer = .{};
    return (Requests{ .io = io }).sendCaptured(&record, &reply).get();
}

test "retry and generated recovery select captured mutations by kind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const paths = try platform.resolveClientPaths(io, root);
    const stop_key = "00000000-0000-4000-8000-000000000001";
    var stop_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const stop_record = try requestPath(root, stop_key, &stop_path);
    _ = paths;
    var stop = try captureSessionStop(io, .{ .store = root, .session = "k7m2qx" }, .{ .explicit = .{ .record = stop_record, .key = stop_key } });
    stop.close(io);
    var interruption = try captureModelInterruption(io, .{ .store = root, .session = "09azvw", .turn_id = 3, .operation_id = 5 }, .{ .generated = root });
    const interruption_key = interruption.saved.key;
    interruption.close(io);
    var message = try captureMessage(io, .{ .store = root, .session = "k7m2qx", .text = "m", .text_path = "" }, .{ .generated = root }).get();
    const message_key = message.saved.key;
    message.close(io);
    var message_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const message_record = try requestPath(root, message_key.slice(), &message_path);

    // Every captured mutation kind, including controls whose records hold only
    // bounded identities, reopens through its generated handle.
    var stop_recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = stop_key } });
    try std.testing.expect(stop_recovered.target == .session_stop);
    stop_recovered.close(io);
    const stop_saved = try inspectCaptured(io, root, stop_key);
    try std.testing.expectEqual(protocol.CommandKind.session_stop, stop_saved.kind);
    try std.testing.expectEqualStrings("k7m2qx", stop_saved.session.slice());
    var interruption_recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = interruption_key.slice() } });
    try std.testing.expectEqual(@as(u64, 5), interruption_recovered.target.model_interruption.operation);
    interruption_recovered.close(io);
    try std.testing.expectEqualStrings("09azvw", (try inspectCaptured(io, root, interruption_key.slice())).session.slice());
    var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = message_key.slice() } });
    recovered.close(io);
    try std.testing.expectEqual(protocol.CommandKind.message, (try inspectCaptured(io, root, message_key.slice())).kind);

    // Retry accepts only the record's own kind. A matching kind reaches
    // transmission, which fails without a Host.
    try std.testing.expectError(error.RequestBindingMismatch, testResend(io, .{ .explicit = .{ .store = root, .record = stop_record, .kind = .model_interruption } }));
    try std.testing.expectError(error.FileNotFound, testResend(io, .{ .explicit = .{ .store = root, .record = stop_record, .kind = .session_stop } }));
    try std.testing.expectError(error.RequestBindingMismatch, testResend(io, .{ .explicit = .{ .store = root, .record = message_record, .kind = .permission_decision } }));
    try std.testing.expectError(error.FileNotFound, testResend(io, .{ .explicit = .{ .store = root, .record = message_record, .kind = .message } }));
}

test "a peer capture preserves the full sender including self and leaves foreign Store admission to the Host" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const own: Address = .{ .store = root, .session = "k7m2qx" };
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record.json", .{root});
    const other: Address = .{ .store = "/elsewhere", .session = "09azvw" };
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
    var captured = try captureMessage(io, .{ .store = root, .session = "target", .text_path = "", .text = "x", .sender = own, .sender_handle = "0123456789abcdef0123456789abcdef" }, .{ .explicit = .{ .record = path, .key = "k" } }).get();
    defer captured.close(io);
    var expected_buffer: [1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"2\",\"kind\":\"message\",\"store\":\"{0s}\",\"key\":\"k\",\"session\":\"target\",\"sender\":{{\"store\":\"{0s}\",\"session\":\"k7m2qx\"}},\"sender_handle\":\"0123456789abcdef0123456789abcdef\",\"text\":{{\"state\":\"value\",\"value\":\"x\"}}}}", .{root});
    var bytes: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(expected, bytes[0..try captured.file.readPositionalAll(io, &bytes, 0)]);
    const remote_path = try std.fmt.bufPrint(&path_buffer, "{s}/remote.json", .{root});
    var remote = try captureMessage(io, .{ .store = root, .session = other.session, .text_path = "", .text = "x", .sender = other }, .{ .explicit = .{ .record = remote_path, .key = "remote" } }).get();
    defer remote.close(io);
    _ = try readCapturedBinding(io, &remote.file);
    const self_path = try std.fmt.bufPrint(&path_buffer, "{s}/self.json", .{root});
    var self = try captureMessage(io, .{ .store = root, .session = own.session, .text_path = "", .text = "x", .sender = own, .sender_handle = "0123456789abcdef0123456789abcdef" }, .{ .explicit = .{ .record = self_path, .key = "self" } }).get();
    defer self.close(io);
    try std.testing.expectEqualStrings(own.session, self.identity().session.slice());
}

test "capture returns original identity before send and preserves empty explicit keys" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const input: MessageInput = .{ .store = root, .session = "k7m2qx", .text_path = "", .text = "original\ntext" };
    var generated = try captureMessage(io, input, .{ .generated = root }).get();
    const saved = generated.identity().*;
    const target = generated.target;
    try std.testing.expectEqual(@as(u64, 13), generated.target.message.bytes);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("original\ntext"), &generated.target.message.digest);
    const descriptor = generated.file.handle;
    {
        defer generated.close(io);
        try std.testing.expect(validRequestHandle(saved.key.slice()));
        try std.testing.expectEqual(@as(u8, '4'), saved.key.slice()[14]);
        try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", saved.key.slice()[19]) != null);
        try std.testing.expectEqualStrings(root, saved.store.slice());
        try std.testing.expectEqualStrings("k7m2qx", saved.session.slice());
        try std.testing.expectEqual(protocol.CommandKind.message, saved.kind);
        var reply: ReplyBuffer = .{};
        try std.testing.expectError(error.FileNotFound, (Requests{ .io = io }).sendCaptured(&generated, &reply).get());
        try std.testing.expectEqualStrings(saved.key.slice(), generated.identity().key.slice());
        try std.testing.expectEqualStrings(root, generated.identity().store.slice());
    }
    try std.testing.expect(std.c.fcntl(descriptor, std.c.F.GETFD) < 0);
    var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = saved.key.slice() } });
    defer recovered.close(io);
    try std.testing.expectEqualStrings(saved.key.slice(), recovered.identity().key.slice());
    try std.testing.expectEqualDeep(target, recovered.target);
    var record: [2048]u8 = undefined;
    const n = try recovered.file.readPositionalAll(io, &record, 0);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, record[0..n], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("original\ntext", parsed.value.object.get("text").?.object.get("value").?.string);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/explicit", .{root});
    var explicit = try captureMessage(io, input, .{ .explicit = .{ .record = path, .key = "" } }).get();
    defer explicit.close(io);
    try std.testing.expectEqualStrings("", explicit.identity().key.slice());
    try std.testing.expectError(error.RecordAlreadyExists, captureMessage(io, input, .{ .explicit = .{ .record = path, .key = "different" } }).get());
    try std.testing.expectError(error.InvalidRequestHandle, openCaptured(io, .{ .generated = .{ .directory = root, .handle = "" } }));

    const escaped_path = try std.fmt.bufPrint(&path_buffer, "{s}/escaped-key", .{root});
    var escaped = try captureMessage(io, input, .{ .explicit = .{ .record = escaped_path, .key = "exact\x00雪" } }).get();
    defer escaped.close(io);
    const binding = try readCapturedBinding(io, &escaped.file);
    try std.testing.expectEqualStrings("exact\x00雪", binding.saved.key.slice());
    try std.testing.expectEqualStrings(input.session, binding.saved.session.slice());
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(input.text.?), &binding.target.message.digest);
    const escaped_count = try escaped.file.readPositionalAll(io, &record, 0);
    try std.testing.expect(std.mem.indexOf(u8, record[0..escaped_count], "\"key\":\"exact\\u0000雪\"") != null);
}

test "capture and send name the step a failure stopped in" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const absent = try std.fmt.bufPrint(&path_buffer, "{s}/absent", .{root});
    try tmp.dir.writeFile(io, .{ .sub_path = "invalid", .data = "bad\xff" });
    var invalid_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const invalid = try std.fmt.bufPrint(&invalid_buffer, "{s}/invalid", .{root});
    // Only the length of oversized inline text is read before it is refused.
    const many: [*]const u8 = "x";
    const oversized = many[0 .. protocol.max_sqlite_content_bytes + 1];
    const Case = struct { input: MessageInput, step: Step, err: anyerror };
    for ([_]Case{
        .{ .input = .{ .store = root, .session = "k7m2qx", .text_path = "", .text = oversized }, .step = .capture, .err = error.ContentTooLarge },
        .{ .input = .{ .store = absent, .session = "k7m2qx", .text_path = "", .text = "x" }, .step = .store, .err = error.FileNotFound },
        .{ .input = .{ .store = root, .session = "K7m2qx", .text_path = "", .text = "x" }, .step = .capture, .err = error.InvalidSession },
        .{ .input = .{ .store = root, .session = "k7m2qx", .text_path = absent }, .step = .input_file_read, .err = error.FileNotFound },
        .{ .input = .{ .store = root, .session = "k7m2qx", .text_path = invalid }, .step = .input_parse, .err = error.InvalidUtf8 },
    }) |case| {
        const failure = captureMessage(io, case.input, .{ .generated = root }).failed;
        try std.testing.expectEqual(@as(?Step, case.step), failure.step);
        try std.testing.expectEqual(case.err, failure.err);
    }
    // No Host serves this Store: nothing reaches one, so admission is known absent.
    var captured = try captureMessage(io, .{ .store = root, .session = "k7m2qx", .text_path = "", .text = "x" }, .{ .generated = root }).get();
    defer captured.close(io);
    var reply: ReplyBuffer = .{};
    const failure = (Requests{ .io = io }).sendCaptured(&captured, &reply).failed;
    try std.testing.expectEqual(@as(?Step, .connect), failure.step);
    try std.testing.expect(!failure.step.?.mayHaveReachedHost());
    // A cancellation before the send begins names no step.
    const stop: Cancellation = .{ .stopped = .init(true) };
    const cancelled = (Requests{ .io = io, .cancellation = &stop }).sendCaptured(&captured, &reply).failed;
    try std.testing.expectEqual(@as(?Step, null), cancelled.step);
    try std.testing.expectEqual(error.Cancelled, cancelled.err);
}

test "capture retransmits complete original bytes after a lost reply" {
    const Peer = struct {
        const Response = enum { closed, silent, reply };
        var client_fd: std.posix.fd_t = undefined;
        var failure: ?anyerror = null;
        fn connect(_: ?*anyopaque, _: *const std.Io.net.UnixAddress) std.Io.net.UnixAddress.ConnectError!std.Io.net.Socket.Handle {
            return client_fd;
        }
        fn serve(fd: std.posix.fd_t, expected: []const u8, response: Response) void {
            exchange(fd, expected, response) catch |err| {
                failure = err;
            };
        }
        fn exchange(fd: std.posix.fd_t, expected: []const u8, response: Response) !void {
            defer closeTestDescriptor(fd);
            var head: [512]u8 = undefined;
            var used: usize = 0;
            while (!std.mem.endsWith(u8, head[0..used], "\r\n\r\n")) {
                if (used == head.len) return error.TestRequestHeadTooLarge;
                const n = std.posix.system.read(fd, head[used..].ptr, 1);
                if (n != 1) return error.TestRequestTruncated;
                used += 1;
            }
            try std.testing.expect(std.mem.startsWith(u8, head[0..used], "POST /v1/message HTTP/1.1\r\n"));
            var length_buffer: [64]u8 = undefined;
            const length = try std.fmt.bufPrint(&length_buffer, "Content-Length: {d}\r\n", .{expected.len});
            try std.testing.expect(std.mem.indexOf(u8, head[0..used], length) != null);
            var bytes: [protocol.content_window_bytes]u8 = undefined;
            var offset: usize = 0;
            while (offset < expected.len) {
                const wanted = @min(bytes.len, expected.len - offset);
                const n = std.posix.system.read(fd, &bytes, wanted);
                if (n <= 0) return error.TestRequestTruncated;
                const count: usize = @intCast(n);
                try std.testing.expectEqualSlices(u8, expected[offset..][0..count], bytes[0..count]);
                offset += count;
            }
            switch (response) {
                .closed => {},
                .silent => {
                    try addNonblocking(fd);
                    const until = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 6 * std.time.ns_per_s;
                    var tail: [1]u8 = undefined;
                    try std.testing.expectEqual(@as(usize, 0), try readRequest(.{ .io = std.testing.io }, fd, &tail, until));
                },
                .reply => try writeAll(fd, empty_test_response),
            }
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/explicit", .{root});
    const text = @as([2 * protocol.content_window_bytes + 3]u8, @splat('q'));
    var captured = try captureMessage(io, .{ .store = root, .session = "k7m2qx", .text_path = "", .text = &text }, .{ .explicit = .{ .record = path, .key = "owned-key" } }).get();
    defer captured.close(io);
    var expected_buffer: [text.len + 1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"2\",\"kind\":\"message\",\"store\":\"{s}\",\"key\":\"owned-key\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"text\":{{\"state\":\"value\",\"value\":\"{s}\"}}}}", .{ root, text });
    var vtable = io.vtable.*;
    vtable.netConnectUnix = Peer.connect;
    const connected_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]Peer.Response{ .closed, .silent, .reply }) |response| {
        const sockets = try socketPair();
        Peer.client_fd = sockets[0]; // The production send owns and closes it.
        Peer.failure = null;
        const peer = try std.Thread.spawn(.{}, Peer.serve, .{ sockets[1], expected, response });
        var buffer: ReplyBuffer = .{};
        const sent = (Requests{ .io = connected_io }).sendCaptured(&captured, &buffer);
        const result = sent.get();
        peer.join();
        if (Peer.failure) |err| return err;
        if (response != .reply) try std.testing.expectEqual(@as(?Step, .admission_response), sent.failed.step);
        switch (response) {
            .closed => try std.testing.expectError(error.TruncatedResponse, result),
            .silent => try std.testing.expectError(error.ResponseInactive, result),
            .reply => {
                try std.testing.expectEqual(@as(u16, 200), (try result).status);
                try std.testing.expectError(error.InvalidResponse, (try result).answer);
            },
        }
        try std.testing.expectEqualStrings("owned-key", captured.identity().key.slice());
    }
}

test "capture publication transfers original inode across pathname replacement" {
    const Replacement = struct {
        fn rename(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8) std.Io.Dir.RenamePreserveError!void {
            try std.testing.io.vtable.dirRenamePreserve(userdata, old_dir, old_path, new_dir, new_path);
            // Simulate a second local process immediately after the production
            // rename, before sync/lock release and the captured-owner handoff.
            new_dir.rename(new_path, new_dir, "displaced-original", std.testing.io) catch return error.Unexpected;
            const file = new_dir.createFile(std.testing.io, new_path, .{}) catch return error.Unexpected;
            defer file.close(std.testing.io);
            file.writeStreamingAll(std.testing.io, "replacement bytes") catch return error.Unexpected;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root});
    var vtable = io.vtable.*;
    vtable.dirRenamePreserve = Replacement.rename;
    const replaced_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var captured = try captureMessage(replaced_io, .{ .store = root, .session = "k7m2qx", .text_path = "", .text = "original\ntext" }, .{ .explicit = .{ .record = path, .key = "original-key" } }).get();
    defer captured.close(io);
    var expected_buffer: [2048]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"2\",\"kind\":\"message\",\"store\":\"{s}\",\"key\":\"original-key\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"text\":{{\"state\":\"value\",\"value\":\"original\\ntext\"}}}}", .{root});
    var bytes: [2048]u8 = undefined;
    const count = try captured.file.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings(expected, bytes[0..count]);
    try std.testing.expectEqual(@as(u64, expected.len), captured.length);
}

test "capture closes pinned reader when publication or handoff fails" {
    const Failure = struct {
        var reader: std.posix.fd_t = undefined;
        var closed: usize = 0;
        fn open(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
            reader = file.handle;
            return file;
        }
        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            for (files) |file| if (file.handle == reader) {
                closed += 1;
            };
            std.testing.io.vtable.fileClose(userdata, files);
        }
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.NoSpaceLeft;
        }
        fn length(_: ?*anyopaque, _: std.Io.File) std.Io.File.LengthError!u64 {
            return error.AccessDenied;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root});
    for ([_]bool{ false, true }) |published| {
        var vtable = io.vtable.*;
        vtable.dirOpenFile = Failure.open;
        vtable.fileClose = Failure.close;
        if (published) vtable.fileLength = Failure.length else vtable.fileSync = Failure.sync;
        const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        Failure.closed = 0;
        try std.testing.expectError(if (published) error.AccessDenied else error.NoSpaceLeft, captureMessage(failing_io, .{ .store = root, .session = "k7m2qx", .text_path = "", .text = "original" }, .{ .explicit = .{ .record = path, .key = "original-key" } }).get());
        try std.testing.expectEqual(@as(usize, 1), Failure.closed);
        try std.testing.expect(std.c.fcntl(Failure.reader, std.c.F.GETFD) < 0);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".record.capture.tmp", .{}));
        if (published) {
            _ = try tmp.dir.statFile(io, "record", .{});
        } else try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
    }
}

test "capture recovery closes rejected records and retains only its reader lifetime" {
    const Probe = struct {
        var opened: usize = 0;
        var closed: usize = 0;
        fn open(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
            opened += 1;
            return file;
        }
        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            closed += files.len;
            std.testing.io.vtable.fileClose(userdata, files);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const handle = "01234567-89ab-4cde-8012-3456789abcde";
    const filename = handle ++ ".json";
    var vtable = io.vtable.*;
    vtable.dirOpenFile = Probe.open;
    vtable.fileClose = Probe.close;
    const observed_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    Probe.opened = 0;
    Probe.closed = 0;
    for ([_][]const u8{
        "not json",
        // Control records are recoverable, but never with another kind's payload.
        "{\"version\":\"2\",\"kind\":\"session_stop\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"text\":{}}",
        "{\"version\":\"2\",\"kind\":\"model_interruption\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"target\":{\"session\":\"k7m2qx\",\"turn\":\"x\",\"operation\":\"2\"}}",
        "{\"version\":\"2\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"other\",\"session\":\"k7m2qx\",\"text\":{}}",
        "{\"version\":\"2\",\"kind\":\"unknown\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"text\":{}}",
        "{\"version\":\"2\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"text\":{\"state\":\"value\",\"value\":\"a\",\"val\\u0075e\":\"b\"}}",
        "{\"version\":\"2\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"text\":{\"state\":\"value\",\"value\":[97]}}",
    }) |bytes| {
        const file = try tmp.dir.createFile(io, filename, .{});
        try file.writeStreamingAll(io, bytes);
        file.close(io);
        try std.testing.expectError(error.InvalidRequestRecord, openCaptured(observed_io, .{ .generated = .{ .directory = root, .handle = handle } }));
        try std.testing.expectEqual(Probe.opened, Probe.closed);
    }
    try tmp.dir.deleteFile(io, filename);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(root, handle, &path_buffer);
    var captured = try captureConfigure(io, .{ .store = root, .session = .{ .named = "k7m2qx" } }, .{ .explicit = .{ .record = path, .key = handle } }).get();
    captured.close(io);
    var recovered = try openCaptured(observed_io, .{ .generated = .{ .directory = root, .handle = handle } });
    const descriptor = recovered.file.handle;
    {
        defer recovered.close(observed_io);
        try std.testing.expectEqual(Probe.opened, Probe.closed + 1);
        try tmp.dir.rename(filename, tmp.dir, "original-record", io);
        const replacement = try tmp.dir.createFile(io, filename, .{});
        try replacement.writeStreamingAll(io, "replacement must not change the open original");
        replacement.close(io);
        var bytes: [2048]u8 = undefined;
        const n = try recovered.file.readPositionalAll(io, &bytes, 0);
        try std.testing.expect(std.mem.startsWith(u8, bytes[0..n], "{\"version\":\"2\",\"kind\":\"configure\""));
    }
    try std.testing.expectEqual(Probe.opened, Probe.closed);
    try std.testing.expect(std.c.fcntl(descriptor, std.c.F.GETFD) < 0);
}

test "capture batches escaped file output and flushes before publication" {
    const Probe = struct {
        var writes: usize = 0;
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) writes += 1;
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root);
    var source_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_path_buffer, "{s}/source", .{root[0..root_len]});
    var record_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const record_path = try std.fmt.bufPrint(&record_path_buffer, "{s}/record", .{root[0..root_len]});
    const source = try tmp.dir.createFile(std.testing.io, "source", .{});
    const chunk = @as([protocol.content_window_bytes]u8, @splat('x'));
    const chunks = 8192;
    for (0..chunks) |_| try source.writeStreamingAll(std.testing.io, &chunk);
    source.close(std.testing.io);
    var vtable = std.testing.io.vtable.*;
    vtable.operate = Probe.operate;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    Probe.writes = 0;
    var output: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, record_path, &output);
    errdefer capture.abort();
    try capture.writeJsonFile(source_path);
    try capture.commit();
    try std.testing.expect(Probe.writes <= chunks + 2);
    const record = try tmp.dir.openFile(std.testing.io, "record", .{});
    defer record.close(std.testing.io);
    var read_buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: usize = 0;
    while (true) {
        const n = record.readStreaming(std.testing.io, &.{&read_buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        for (read_buffer[0..n]) |byte| {
            const expected: u8 = if (offset == 0 or offset == chunks * chunk.len + 1) '"' else 'x';
            try std.testing.expectEqual(expected, byte);
            offset += 1;
        }
    }
    try std.testing.expectEqual(chunks * chunk.len + 2, offset);
}

test "capture validates split UTF8 and does not publish after final flush failure" {
    const FailWrite = struct {
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) return .{ .file_write_streaming = error.NoSpaceLeft };
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var source_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_path_buffer, "{s}/source", .{root[0..root_len]});
    var record_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const record_path = try std.fmt.bufPrint(&record_path_buffer, "{s}/record", .{root[0..root_len]});
    var input = @as([protocol.content_window_bytes + 1]u8, @splat('x'));
    input[input.len - 2] = 0xc3;
    input[input.len - 1] = 0xa9;
    for ([_]bool{ false, true }) |truncated| {
        const source = try tmp.dir.createFile(io, "source", .{});
        try source.writeStreamingAll(io, input[0 .. input.len - @intFromBool(truncated)]);
        source.close(io);
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var capture = try Capture.open(io, record_path, &buffer);
        defer capture.abort();
        if (truncated) {
            try std.testing.expectError(error.InvalidUtf8, capture.writeJsonFile(source_path));
            capture.abort();
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, capture.temporary_name.slice(), .{}));
        } else {
            try capture.writeJsonFile(source_path);
            try capture.commit();
            const file = try tmp.dir.openFile(io, "record", .{});
            defer file.close(io);
            var bytes: [input.len + 2]u8 = undefined;
            const n = try file.readStreaming(io, &.{&bytes});
            try std.testing.expectEqual(bytes.len, n);
            try std.testing.expectEqualStrings(&input, bytes[1 .. bytes.len - 1]);
            try tmp.dir.deleteFile(io, "record");
        }
    }
    var vtable = io.vtable.*;
    vtable.operate = FailWrite.operate;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(failing_io, record_path, &buffer);
    defer capture.abort();
    try capture.writeJsonString("buffered until commit");
    try std.testing.expectError(error.NoSpaceLeft, capture.commit());
    capture.abort();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, capture.temporary_name.slice(), .{}));
}

test "capture bounds decoded bytes and preserves record ownership" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root[0..n]});
    var source_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_buffer, "{s}/source", .{root[0..n]});
    const source = try tmp.dir.createFile(io, "source", .{});
    try source.writeStreamingAll(io, "\x00\n€");
    source.close(io);
    var buffer: [32]u8 = undefined;
    var other_buffer: [32]u8 = undefined;
    var capture = try Capture.open(io, path, &buffer);
    defer capture.abort();
    try std.testing.expectError(error.RecordCaptureBusy, Capture.open(io, path, &other_buffer));
    try std.testing.expectError(error.ContentTooLarge, capture.writeJsonFileBounded(source_path, 4, false));
    capture.abort();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
    capture = try Capture.open(io, path, &buffer);
    try capture.writeJsonFileBounded(source_path, 5, false);
    try capture.commit();
    try std.testing.expectError(error.RecordAlreadyExists, Capture.open(io, path, &other_buffer));
    const saved = try tmp.dir.openFile(io, "record", .{});
    defer saved.close(io);
    var bytes: [32]u8 = undefined;
    const count = try saved.readStreaming(io, &.{&bytes});
    try std.testing.expectEqualStrings("\"\\u0000\\n€\"", bytes[0..count]);
}

test "stdin capture uses the same decoded bound before publication" {
    const Stdin = struct {
        var sent: bool = false;
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_read_streaming and operation.file_read_streaming.file.handle == std.Io.File.stdin().handle) {
                if (sent) return .{ .file_read_streaming = error.EndOfStream };
                sent = true;
                @memcpy(operation.file_read_streaming.data[0][0..3], "a\nb");
                return .{ .file_read_streaming = 3 };
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root[0..n]});
    var vtable = io.vtable.*;
    vtable.operate = Stdin.operate;
    const input_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var buffer: [32]u8 = undefined;
    for ([_]u64{ 2, 3 }) |limit| {
        Stdin.sent = false;
        var capture = try Capture.open(input_io, path, &buffer);
        defer capture.abort();
        if (limit == 2) {
            try std.testing.expectError(error.ContentTooLarge, capture.writeJsonFileBounded("-", limit, false));
            capture.abort();
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
        } else {
            try capture.writeJsonFileBounded("-", limit, false);
            try capture.commit();
            const saved = try tmp.dir.openFile(io, "record", .{});
            defer saved.close(io);
            var bytes: [16]u8 = undefined;
            const count = try saved.readStreaming(io, &.{&bytes});
            try std.testing.expectEqualStrings("\"a\\nb\"", bytes[0..count]);
        }
    }
}
fn testPipe() ![2]std.posix.fd_t {
    var descriptors: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&descriptors) != 0) return error.TestPipeFailed;
    return descriptors;
}

fn closeTestDescriptor(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn writeTestResponse(fd: std.posix.fd_t, response: []const u8) !void {
    defer closeTestDescriptor(fd);
    try writeAll(fd, response);
}

test "command reply borrows the caller buffer" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    try writeTestResponse(
        descriptors[1],
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Rui-Wire-Version: 2\r\n\r\n{\"status\":\"error\"}",
    );
    var buffer: ReplyBuffer = .{};
    const reply = try readCommandResponse(descriptors[0], &buffer);
    try std.testing.expectEqual(@as(u16, 409), reply.status);
    try std.testing.expectEqualStrings("{\"status\":\"error\"}", reply.body);
    try std.testing.expectEqual(@intFromPtr(buffer.bytes[0..].ptr), @intFromPtr(reply.body.ptr));
}

test "bounded read requests retain escaped key capacities and canonical Session bounds" {
    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const session = "k7m2qx";
    const session_encoding_slack = 6 * protocol.max_session_bytes - session.len;
    const cases = .{
        .{ protocol.observe_command_request, .{ &escaped_store, &escaped_key }, protocol.max_observe_command_request_bytes },
        .{ protocol.read_result_request, .{ &escaped_store, &escaped_key }, protocol.max_read_result_request_bytes },
        .{ protocol.read_action_call_id_request, .{ &escaped_store, session, std.math.maxInt(u64) }, protocol.max_read_action_call_id_request_bytes - session_encoding_slack },
        .{ protocol.read_action_arguments_request, .{ &escaped_store, session, std.math.maxInt(u64) }, protocol.max_read_action_arguments_request_bytes - session_encoding_slack },
        .{ protocol.inspect_session_request.failed_response, .{ &escaped_store, session, protocol.FailedResponsePart.metadata, std.math.maxInt(u64), std.math.maxInt(u64) }, protocol.max_inspect_session_request_bytes - session_encoding_slack },
    };
    inline for (cases) |case| {
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(case[0], case[1]);
        try std.testing.expectEqual(@as(usize, case[2]), body.len);
    }
    var inspection: protocol.RequestBuffer = .{};
    try inspection.appendShape(protocol.inspect_session_request.full, .{ &escaped_store, session });
    try std.testing.expect(inspection.len <= protocol.max_inspect_session_request_bytes);
    var full: protocol.RequestBuffer = .{};
    full.len = full.bytes.len;
    try std.testing.expectError(error.BufferTooLarge, full.append("x"));
}

test "every request renders its exact worst-case bound from the shape it writes" {
    const store = @as([protocol.max_store_bytes]u8, @splat(1));
    const key = @as([protocol.max_key_bytes]u8, @splat(1));
    const session = @as([protocol.max_session_bytes]u8, @splat(1));
    const workspace = @as([protocol.max_workspace_bytes]u8, @splat(1));
    const token = @as([protocol.SinceToken.max_bytes]u8, @splat('9'));
    const reference = @as([protocol.session_id_bytes]u8, @splat(1));
    const id: u64 = std.math.maxInt(u64);
    const optional_id: ?u64 = std.math.maxInt(u64);
    const Direction = @FieldType(protocol.ActivityPage, "direction");
    const cases = .{
        .{ protocol.session_stop_request, .{ &store, &key, &session }, protocol.max_session_stop_request_bytes },
        .{ protocol.model_interruption_request, .{ &store, &key, &session, id, id }, protocol.max_model_interruption_request_bytes },
        .{ protocol.permission_decision_request, .{ &store, &key, &session, id, protocol.PermissionDecision.allow_once }, protocol.max_permission_decision_request_bytes },
        .{ protocol.observe_command_request, .{ &store, &key }, protocol.max_observe_command_request_bytes },
        .{ protocol.host_info_request, .{&store}, protocol.max_host_info_request_bytes },
        .{ protocol.host_stop_request, .{&store}, protocol.max_host_stop_request_bytes },
        .{ protocol.read_result_request, .{ &store, &key }, protocol.max_read_result_request_bytes },
        .{ protocol.inspect_session_request.failed_response, .{ &store, &session, protocol.FailedResponsePart.metadata, id, id }, protocol.max_inspect_session_request_bytes },
        .{ protocol.list_sessions_changed_request, .{ &store, @as(?[]const u8, &workspace), id, id, &token, id, &reference }, protocol.max_list_sessions_request_bytes },
        .{ protocol.read_action_arguments_request, .{ &store, &session, id }, protocol.max_read_action_arguments_request_bytes },
        .{ protocol.read_action_call_id_request, .{ &store, &session, id }, protocol.max_read_action_call_id_request_bytes },
        .{ protocol.conversation_content_request, .{ &store, &session, id, id }, protocol.max_conversation_content_request_bytes },
        .{ protocol.conversation_page_request, .{ &store, &session, id, id, id }, protocol.max_conversation_page_request_bytes },
        .{ protocol.proposal_page_request, .{ &store, &session, optional_id, id }, protocol.max_proposal_page_request_bytes },
        .{ protocol.proposal_field_request, .{ &store, &session, id, protocol.ProposalField.arguments }, protocol.max_proposal_field_request_bytes },
        .{ protocol.activity_page_request, .{ &store, &session, optional_id, id, optional_id, Direction.backward }, protocol.max_activity_page_request_bytes },
        .{ protocol.activity_content_request, .{ &store, &session, id, id }, protocol.max_activity_content_request_bytes },
    };
    var largest: usize = 0;
    inline for (cases, 0..) |case, index| {
        var body: protocol.FixedJsonBuffer(case[2]) = .{};
        try body.appendShape(case[0], case[1]);
        try std.testing.expectEqual(@as(usize, case[2]), body.len);
        try std.testing.expect(try std.json.validate(std.testing.allocator, body.slice()));
        // The first three are control requests, captured to a record file.
        if (index >= 3) largest = @max(largest, body.len);
    }
    try std.testing.expectEqual(protocol.max_client_request_bytes, largest);
    try std.testing.expectEqual(protocol.max_control_request_bytes, protocol.max_model_interruption_request_bytes);
}

test "Session list client renders each cursor's request exactly, within the bound" {
    const token: protocol.SinceToken = .{ .instance = @splat(0xab), .generation = 42 };
    const cases = .{
        .{ protocol_reply.SessionListCursor{}, "" },
        .{ protocol_reply.SessionListCursor{ .after = 8, .ceiling = 23 }, "" },
        .{ protocol_reply.SessionListCursor{ .since = token }, ",\"since\":\"abababababababababababababababab.42\"" },
        .{ protocol_reply.SessionListCursor{ .since = token, .changed = .{ .through = 48, .after_reference = "k7m2qx".* } }, ",\"since\":\"abababababababababababababababab.42\",\"through\":\"48\",\"after_reference\":\"k7m2qx\"" },
    };
    inline for (cases) |case| {
        var body: protocol.RequestBuffer = .{};
        try appendListSessions(&body, "/store", null, case[0]);
        var expected: [512]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"version\":\"2\",\"kind\":\"list_sessions\",\"store\":\"/store\",\"workspace\":null,\"after\":\"{d}\",\"ceiling\":\"{d}\"{s}}}", .{ case[0].after, case[0].ceiling, case[1] }), body.slice());
    }
    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const escaped_workspace = @as([protocol.max_workspace_bytes]u8, @splat(1));
    var maximum: protocol.RequestBuffer = .{};
    try appendListSessions(&maximum, &escaped_store, &escaped_workspace, .{ .since = .{ .instance = @splat(0xff), .generation = std.math.maxInt(u64) }, .changed = .{ .through = std.math.maxInt(u64), .after_reference = "zzzzzz".* } });
    try std.testing.expect(maximum.len <= protocol.max_list_sessions_request_bytes);
    try std.testing.expect(std.mem.endsWith(u8, maximum.slice(), "\"since\":\"ffffffffffffffffffffffffffffffff.18446744073709551615\",\"through\":\"18446744073709551615\",\"after_reference\":\"zzzzzz\"}"));
}

test "control captures attain escaped key and canonical Session request bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var records = try tmp.dir.createDirPathOpen(std.testing.io, "records", .{
        .permissions = .fromMode(0o700),
    });
    records.close(std.testing.io);

    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const session = "k7m2qx";
    const session_encoding_slack = 6 * protocol.max_session_bytes - session.len;
    var paths: platform.Paths = .{};
    try paths.store.set(&escaped_store);

    var stop_path_buffer: [protocol.max_store_bytes + "/records/stop-record".len]u8 = undefined;
    const stop_path = try std.fmt.bufPrint(
        &stop_path_buffer,
        "{s}/records/stop-record",
        .{root_buffer[0..root_length]},
    );
    var stop_capture = try writeSessionStopCapture(std.testing.io, &paths, .{
        .store = "unused",
        .session = session,
    }, .{ .record = stop_path, .key = &escaped_key, .replay = .{ .explicit = stop_path } });
    defer stop_capture.close(std.testing.io);
    const stop_file = try std.Io.Dir.cwd().openFile(std.testing.io, stop_path, .{});
    defer stop_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_session_stop_request_bytes - session_encoding_slack),
        try stop_file.length(std.testing.io),
    );

    var interruption_path_buffer: [protocol.max_store_bytes + "/records/interruption-record".len]u8 = undefined;
    const interruption_path = try std.fmt.bufPrint(
        &interruption_path_buffer,
        "{s}/records/interruption-record",
        .{root_buffer[0..root_length]},
    );
    var interruption_capture = try writeModelInterruptionCapture(std.testing.io, &paths, .{
        .store = "unused",
        .session = session,
        .turn_id = std.math.maxInt(u64),
        .operation_id = std.math.maxInt(u64),
    }, .{ .record = interruption_path, .key = &escaped_key, .replay = .{ .explicit = interruption_path } });
    defer interruption_capture.close(std.testing.io);
    const interruption_file = try std.Io.Dir.cwd().openFile(std.testing.io, interruption_path, .{});
    defer interruption_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_model_interruption_request_bytes - session_encoding_slack),
        try interruption_file.length(std.testing.io),
    );

    var permission_path_buffer: [protocol.max_store_bytes + "/records/permission-record".len]u8 = undefined;
    const permission_path = try std.fmt.bufPrint(
        &permission_path_buffer,
        "{s}/records/permission-record",
        .{root_buffer[0..root_length]},
    );
    var permission_buffer: [protocol.content_window_bytes]u8 = undefined;
    var permission_capture = try Capture.open(std.testing.io, permission_path, &permission_buffer);
    defer permission_capture.abort();
    try permission_capture.writePermissionDecision(paths.store.slice(), &escaped_key, .{
        .store = "unused",
        .session = session,
        .action_id = std.math.maxInt(u64),
        .decision = .allow_once,
    });
    try permission_capture.commit();
    const permission_file = try std.Io.Dir.cwd().openFile(std.testing.io, permission_path, .{});
    defer permission_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_permission_decision_request_bytes - session_encoding_slack),
        try permission_file.length(std.testing.io),
    );
}

test "response parsing rejects truncated head and command body" {
    {
        const descriptors = try testPipe();
        defer closeTestDescriptor(descriptors[0]);
        try writeTestResponse(descriptors[1], "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n");
        var buffer: ReplyBuffer = .{};
        try std.testing.expectError(error.TruncatedResponse, readCommandResponse(descriptors[0], &buffer));
    }
    {
        const descriptors = try testPipe();
        defer closeTestDescriptor(descriptors[0]);
        try writeTestResponse(
            descriptors[1],
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 2\r\n\r\n{}",
        );
        var buffer: ReplyBuffer = .{};
        try std.testing.expectError(error.TruncatedResponse, readCommandResponse(descriptors[0], &buffer));
        try std.testing.expectEqual(@as(usize, 0), buffer.len);
    }
}

const LargeResponseContext = struct {
    fd: std.posix.fd_t,
    length: u64,
    content_type: []const u8 = "text/plain; charset=utf-8",
    failure: ?anyerror = null,
};

fn testPattern(buffer: []u8, offset: u64) void {
    for (buffer, 0..) |*byte, index| byte.* = @intCast((offset + index) % 251);
}

fn writeLargeTestResponse(context: *LargeResponseContext) void {
    defer closeTestDescriptor(context.fd);
    var header_buffer: [256]u8 = undefined;
    const header = std.fmt.bufPrint(
        &header_buffer,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: 2\r\n\r\n",
        .{ context.content_type, context.length },
    ) catch |err| {
        context.failure = err;
        return;
    };
    writeAll(context.fd, header) catch |err| {
        context.failure = err;
        return;
    };
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < context.length) {
        const count: usize = @intCast(@min(context.length - offset, buffer.len));
        testPattern(buffer[0..count], offset);
        writeAll(context.fd, buffer[0..count]) catch |err| {
            context.failure = err;
            return;
        };
        offset += count;
    }
}

test "result response streams 100,000 bytes into an explicit file" {
    const result_bytes = 100_000;
    const descriptors = try testPipe();
    var context = LargeResponseContext{ .fd = descriptors[1], .length = result_bytes };
    const writer = try std.Thread.spawn(.{}, writeLargeTestResponse, .{&context});
    var writer_joined = false;
    defer {
        closeTestDescriptor(descriptors[0]);
        if (!writer_joined) writer.join();
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try tmp.dir.createFile(std.testing.io, "answer", .{ .read = true });
    defer destination.close(std.testing.io);
    var reply_buffer: ReplyBuffer = .{};
    const reply = try readResultResponse(std.testing.io, descriptors[0], destination, &reply_buffer);
    writer.join();
    writer_joined = true;
    switch (reply) {
        .answer => |answer| try std.testing.expectEqual(@as(u64, result_bytes), answer.bytes),
        .command => return error.ExpectedAnswer,
    }
    try std.testing.expectEqual(@as(usize, 0), reply_buffer.len);
    try std.testing.expectEqual(@as(u64, result_bytes), try destination.length(std.testing.io));

    var expected_hash = std.crypto.hash.sha2.Sha256.init(.{});
    var actual_hash = std.crypto.hash.sha2.Sha256.init(.{});
    var expected_buffer: [protocol.content_window_bytes]u8 = undefined;
    var actual_buffer: [protocol.content_window_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < result_bytes) {
        const count: usize = @intCast(@min(result_bytes - offset, expected_buffer.len));
        testPattern(expected_buffer[0..count], offset);
        expected_hash.update(expected_buffer[0..count]);
        const actual = try destination.readPositionalAll(std.testing.io, actual_buffer[0..count], offset);
        try std.testing.expectEqual(count, actual);
        actual_hash.update(actual_buffer[0..actual]);
        offset += count;
    }
    try std.testing.expectEqual(expected_hash.finalResult(), actual_hash.finalResult());
    try std.testing.expect(context.failure == null);
}

test "Session list client streams a page larger than the resident reply buffer" {
    const page_bytes = 100_000;
    const descriptors = try testPipe();
    var context = LargeResponseContext{ .fd = descriptors[1], .length = page_bytes, .content_type = "application/json" };
    const writer = try std.Thread.spawn(.{}, writeLargeTestResponse, .{&context});
    defer closeTestDescriptor(descriptors[0]);
    defer writer.join();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try tmp.dir.createFile(std.testing.io, "page", .{ .read = true });
    defer destination.close(std.testing.io);
    var reply_buffer: ReplyBuffer = .{};
    const reply = try readReportResponse(.{ .io = std.testing.io }, descriptors[0], destination, &reply_buffer);
    switch (reply) {
        .report => |report| try std.testing.expectEqual(@as(u64, page_bytes), report.bytes),
        .command => return error.ExpectedReport,
    }
    try std.testing.expectEqual(@as(u64, page_bytes), try destination.length(std.testing.io));
    try std.testing.expectEqual(@as(usize, 0), reply_buffer.len);
}

fn writeContentTestHead(fd: std.posix.fd_t, length: u64) !void {
    var buffer: [256]u8 = undefined;
    try writeAll(fd, try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 2\r\n\r\n", .{ length, length, length }));
}

test "a first-line read returns the text before the first line break, within the limit" {
    const letters = struct {
        fn of(comptime count: usize) [count]u8 {
            return @splat('a');
        }
    }.of;
    const cases = comptime [_]struct { content: []const u8, line: []const u8 }{
        .{ .content = "Fix the flaky resize test", .line = "Fix the flaky resize test" },
        .{ .content = "Fix the flaky resize test\nIt fails one run in ten.\n", .line = "Fix the flaky resize test" },
        .{ .content = "Fix the flaky resize test\r\nIt fails one run in ten.\r\n", .line = "Fix the flaky resize test" },
        .{ .content = " \t ", .line = " \t " },
        .{ .content = " \t \r\n\n ", .line = " \t " },
        .{ .content = "", .line = "" },
        .{ .content = &letters(5000), .line = &letters(4096) },
        .{ .content = letters(4094) ++ "中", .line = &letters(4094) },
        .{ .content = letters(4093) ++ "🙂z", .line = &letters(4093) },
        .{ .content = letters(4093) ++ "中z", .line = letters(4093) ++ "中" },
        .{ .content = letters(4095) ++ "\r\n", .line = &letters(4095) },
    };
    for (cases) |case| {
        const descriptors = try testPipe();
        defer closeTestDescriptor(descriptors[0]);
        {
            defer closeTestDescriptor(descriptors[1]);
            try writeContentTestHead(descriptors[1], case.content.len);
            try writeAll(descriptors[1], case.content);
        }
        var buffer: [4096]u8 = undefined;
        const reply = try readFirstLine(.{ .io = std.testing.io }, descriptors[0], &buffer);
        try std.testing.expectEqualStrings(case.line, reply.line);
    }
}

test "a first-line read of a 1 MiB Message returns after the first line, before the Host finishes sending" {
    const sockets = try socketPair();
    const capacity: c_int = 64 * 1024;
    try std.testing.expectEqual(@as(c_int, 0), std.c.setsockopt(sockets[1], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &capacity, @sizeOf(c_int)));
    const Host = struct {
        fd: std.posix.fd_t,
        sent: u64 = 0,
        failure: ?anyerror = null,

        fn send(self: *@This()) void {
            const length = 1024 * 1024;
            writeContentTestHead(self.fd, length) catch |err| {
                self.failure = err;
                return;
            };
            var window: [protocol.content_window_bytes]u8 = @splat('x');
            @memcpy(window[0..23], "Review the release plan");
            window[23] = '\n';
            while (self.sent < length) {
                writeAll(self.fd, &window) catch |err| {
                    self.failure = err;
                    return;
                };
                self.sent += window.len;
                window = @splat('x');
            }
        }
    };
    var host = Host{ .fd = sockets[1] };
    const thread = try std.Thread.spawn(.{}, Host.send, .{&host});
    defer closeTestDescriptor(sockets[1]);
    var buffer: [4096]u8 = undefined;
    const reply = readFirstLine(.{ .io = std.testing.io }, sockets[0], &buffer);
    closeTestDescriptor(sockets[0]);
    thread.join();
    try std.testing.expectEqualStrings("Review the release plan", (try reply).line);
    try std.testing.expect(host.failure != null);
    try std.testing.expect(host.sent < 1024 * 1024);
}

test "a first-line read returns the Host's refusal" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    var body: protocol.ResponseBuffer = .{};
    try body.appendShape(protocol.error_reply, .{ protocol.ErrorType.activity_unavailable, "ContentNotFound" });
    {
        defer closeTestDescriptor(descriptors[1]);
        var head: [256]u8 = undefined;
        try writeAll(descriptors[1], try std.fmt.bufPrint(&head, "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 2\r\n\r\n", .{body.len}));
        try writeAll(descriptors[1], body.slice());
    }
    var buffer: [4096]u8 = undefined;
    const reply = try readFirstLine(.{ .io = std.testing.io }, descriptors[0], &buffer);
    try std.testing.expectEqual(@as(u16, 409), reply.failure.status);
    try std.testing.expect(reply.failure.diagnostic.code.eql("ContentNotFound"));
}

test "read result returns bounded command errors without touching destination" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    try writeTestResponse(
        descriptors[1],
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Rui-Wire-Version: 2\r\n\r\n{\"status\":\"error\"}",
    );
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try tmp.dir.createFile(std.testing.io, "answer", .{ .read = true });
    defer destination.close(std.testing.io);
    var buffer: ReplyBuffer = .{};
    const reply = try readResultResponse(std.testing.io, descriptors[0], destination, &buffer);
    switch (reply) {
        .answer => return error.ExpectedCommandReply,
        .command => |command| {
            try std.testing.expectEqual(@as(u16, 409), command.status);
            try std.testing.expectEqualStrings("{\"status\":\"error\"}", command.body);
        },
    }
    try std.testing.expectEqual(@as(u64, 0), try destination.length(std.testing.io));
}

test "truncated result body leaves only an unsuccessful destination prefix" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    try writeTestResponse(
        descriptors[1],
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 2\r\n\r\nab",
    );
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const destination = try tmp.dir.createFile(std.testing.io, "answer", .{ .read = true });
    defer destination.close(std.testing.io);
    var buffer: ReplyBuffer = .{};
    try std.testing.expectError(
        error.TruncatedResponse,
        readResultResponse(std.testing.io, descriptors[0], destination, &buffer),
    );
    // The final window is withheld until every advertised byte arrives.
    try std.testing.expectEqual(@as(u64, 0), try destination.length(std.testing.io));
}

test "result body publishes nothing unless EOF follows the advertised bytes" {
    inline for (.{ "Content-Length: 2\r\nX-Rui-Wire-Version: 2\r\n\r\nabX", "Content-Length: 0\r\nX-Rui-Wire-Version: 2\r\n\r\nX" }) |tail| {
        const descriptors = try testPipe();
        defer closeTestDescriptor(descriptors[0]);
        try writeTestResponse(descriptors[1], "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" ++ tail);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const destination = try tmp.dir.createFile(std.testing.io, "answer", .{ .read = true });
        defer destination.close(std.testing.io);
        var buffer: ReplyBuffer = .{};
        try std.testing.expectError(error.InvalidResponse, readResultResponse(std.testing.io, descriptors[0], destination, &buffer));
        try std.testing.expectEqual(@as(u64, 0), try destination.length(std.testing.io));
    }
}

test "transport cancellation preserves caller capture and rejects before path access" {
    var token: Cancellation = .{};
    token.requestStop();
    const requests: Requests = .{ .io = std.testing.io, .cancellation = &token };
    var captured: CapturedRecord = .{ .file = .{ .handle = -1, .flags = .{ .nonblocking = false } }, .length = 0, .saved = .{ .kind = .configure }, .target = .configure, .replay = .generated };
    try captured.saved.store.set("/never-open");
    var buffer: ReplyBuffer = .{};
    try std.testing.expectError(error.Cancelled, requests.sendCaptured(&captured, &buffer).get());
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), captured.file.handle);
    const file = captured.file;
    const address = try protocol_reply.MessageAddress.init("/never-open", "k7m2qx", "k");
    try std.testing.expectError(error.Cancelled, requests.observeCommand("/never-open", "k", &buffer));
    try std.testing.expectError(error.Cancelled, requests.observeMessage(&address));
    try std.testing.expectError(error.Cancelled, requests.readResult("/never-open", "k", file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.readResultStream("/never-open", "k", file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.inspectSession("/never-open", "s", .current, file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.listSessions("/never-open", null, .{}, file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.readActionArguments("/never-open", "s", 1, file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.readActionCallId("/never-open", "s", 1, file, &buffer));
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
    std.debug.print("transport metadata: Requests={d} Cancellation={d}; existing window={d}; no transport heap/worker/queue\n", .{
        @sizeOf(Requests), @sizeOf(Cancellation), protocol.content_window_bytes,
    });
}

test "transport cancellation returns before silent peer release and retains pinned capture" {
    const Worker = struct {
        requests: Requests,
        captured: *CapturedRecord,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            var reply: ReplyBuffer = .{};
            _ = self.requests.sendCaptured(self.captured, &reply).get() catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var captured = try captureConfigure(io, .{ .store = root, .session = .{ .named = "k7m2qx" } }, .{ .explicit = .{ .record = try std.fmt.bufPrint(&record_buffer, "{s}/record", .{root}), .key = "original" } }).get();
    defer captured.close(io);
    var lease = try platform.StoreLease.acquire(io, root);
    defer lease.release();
    try lease.prepareForServing(false);
    const paths = lease.paths;
    var listener = try (try std.Io.net.UnixAddress.init(paths.socket.slice())).listen(io, .{});
    defer {
        listener.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, paths.socket.slice()) catch @panic("unable to remove fixture socket");
    }
    var token: Cancellation = .{};
    var worker: Worker = .{ .requests = .{ .io = io, .cancellation = &token }, .captured = &captured };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    const peer = try listener.accept(io);
    var open = true;
    var joined = false;
    defer {
        token.requestStop();
        if (open) peer.close(io);
        if (!joined) thread.join();
    }
    // The peer observes the complete actual request before withholding reply.
    var wire: [4096]u8 = undefined;
    var used: usize = 0;
    while (true) {
        used += try std.posix.read(peer.socket.handle, wire[used..]);
        if (std.mem.indexOf(u8, wire[0..used], "\r\n\r\n")) |end| {
            if (used == end + 4 + captured.length) break;
        }
    }
    token.requestStop();
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
    test_poll.waitUntil(io, .{ .raw = .fromNanoseconds(until), .clock = .awake }, &worker.done, test_poll.isSet) catch |err|
        if (err != error.Timeout) return err;
    const returned_before_release = worker.done.load(.acquire);
    if (returned_before_release) {
        try std.testing.expect(try waitRequest(.{ .io = io }, peer.socket.handle, std.posix.POLL.IN, until));
        try std.testing.expectEqual(@as(usize, 0), try std.posix.read(peer.socket.handle, wire[0..1]));
    }
    peer.close(io);
    open = false;
    thread.join();
    joined = true;
    // A disabled-stop implementation is finite but must fail this assertion.
    try std.testing.expect(returned_before_release);
    try std.testing.expectEqual(error.Cancelled, worker.failure.?);
    try std.testing.expect(std.c.fcntl(captured.file.handle, std.c.F.GETFD) >= 0);
    try std.testing.expectEqualStrings("original", captured.identity().key.slice());
}

test "transport cancellation stops a backpressured nonblocking write after real progress" {
    const Worker = struct {
        requests: Requests,
        fd: std.posix.fd_t,
        failure: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            var bytes: [1024 * 1024]u8 = undefined;
            @memset(&bytes, 'x');
            writeAllRequest(self.requests, self.fd, &bytes, null) catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
    };
    const io = std.testing.io;
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    try addNonblocking(sockets[0]);
    const small: c_int = 4096;
    try std.testing.expectEqual(@as(c_int, 0), std.c.setsockopt(sockets[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &small, @sizeOf(c_int)));
    var token: Cancellation = .{};
    var worker: Worker = .{ .requests = .{ .io = io, .cancellation = &token }, .fd = sockets[0] };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
    var joined = false;
    var open = true;
    defer {
        token.requestStop();
        if (open) closeTestDescriptor(sockets[1]);
        if (!joined) thread.join();
    }
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(sockets[1], &byte));
    try std.testing.expectEqualStrings("x", &byte);
    token.requestStop();
    test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(1)), &worker.done, test_poll.isSet) catch |err|
        if (err != error.Timeout) return err;
    const returned_before_release = worker.done.load(.acquire);
    closeTestDescriptor(sockets[1]);
    open = false;
    thread.join();
    joined = true;
    try std.testing.expect(returned_before_release);
    try std.testing.expectEqual(error.Cancelled, worker.failure.?);
}

test "transport cancellation retains synchronous sink loans and respects delivered completion and sink failure" {
    const Sink = struct {
        entered: std.atomic.Value(bool) = .init(false),
        released: std.atomic.Value(bool) = .init(false),
        fail: bool,
        fn feed(self: *@This(), bytes: []const u8) !void {
            self.entered.store(true, .release);
            try test_poll.waitUntil(std.testing.io, test_poll.after(std.testing.io, .fromSeconds(10)), &self.released, test_poll.isSet);
            try std.testing.expectEqualStrings("a", bytes);
            if (self.fail) return error.SinkFailed;
        }
    };
    const Kind = enum { inspect, list, result };
    const Worker = struct {
        requests: Requests,
        root: []const u8,
        kind: Kind,
        sink: Sink,
        failure: ?anyerror = null,
        bytes: u64 = 0,
        done: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            self.exchange() catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
        fn exchange(self: *@This()) !void {
            var buffer: ReplyBuffer = .{};
            switch (self.kind) {
                .inspect, .list => {
                    const reply = if (self.kind == .inspect)
                        try self.requests.inspectSession(self.root, "k7m2qx", .current, &self.sink, &buffer)
                    else
                        try self.requests.listSessions(self.root, null, .{}, &self.sink, &buffer);
                    self.bytes = switch (reply) {
                        .report => |report| report.bytes,
                        .command => return error.ExpectedReport,
                    };
                },
                .result => {
                    const reply = try self.requests.readResultStream(self.root, "k", &self.sink, &buffer);
                    self.bytes = switch (reply) {
                        .answer => |answer| answer.bytes,
                        .failure => return error.ExpectedAnswer,
                    };
                },
            }
        }
    };
    const io = std.testing.io;
    for ([_]Kind{ .inspect, .list, .result }) |kind| {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try tmp.dir.setPermissions(io, .fromMode(0o700));
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
        var lease = try platform.StoreLease.acquire(io, root);
        defer lease.release();
        try lease.prepareForServing(false);
        const paths = lease.paths;
        var listener = try (try std.Io.net.UnixAddress.init(paths.socket.slice())).listen(io, .{});
        defer {
            listener.deinit(io);
            std.Io.Dir.cwd().deleteFile(io, paths.socket.slice()) catch @panic("unable to remove fixture socket");
        }
        var token: Cancellation = .{};
        var worker: Worker = .{ .requests = .{ .io = io, .cancellation = &token }, .root = root, .kind = kind, .sink = .{ .fail = kind == .result } };
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        const peer = try listener.accept(io);
        var joined = false;
        defer {
            token.requestStop();
            worker.sink.released.store(true, .release);
            peer.close(io);
            if (!joined) thread.join();
        }
        var wire: [4096]u8 = undefined;
        var used: usize = 0;
        while (true) {
            used += try std.posix.read(peer.socket.handle, wire[used..]);
            if (std.mem.indexOf(u8, wire[0..used], "\r\n\r\n")) |end| {
                const start = std.mem.indexOf(u8, wire[0..end], "Content-Length: ").? + "Content-Length: ".len;
                const finish = std.mem.indexOf(u8, wire[start..end], "\r\n").? + start;
                if (used == end + 4 + try std.fmt.parseInt(usize, wire[start..finish], 10)) break;
            }
        }
        const route = switch (kind) {
            .inspect => "/v1/inspect-session",
            .list => "/v1/list-sessions",
            .result => "/v1/read-result",
        };
        var prefix: [64]u8 = undefined;
        try std.testing.expect(std.mem.startsWith(u8, wire[0..used], try std.fmt.bufPrint(&prefix, "POST {s} HTTP/1.1\r\n", .{route})));
        const length: u64 = if (kind == .list) 3 else 1;
        const content_type = if (kind == .result) "text/plain; charset=utf-8" else "application/json";
        var response: [256]u8 = undefined;
        try writeAll(peer.socket.handle, try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: 2\r\n\r\na", .{ content_type, length }));
        // An answer's final window is delivered only after its EOF.
        if (kind == .result) try std.testing.expectEqual(socket_os.Shutdown.done, socket_os.shutdown(peer.socket.handle, std.c.SHUT.WR));
        try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(1)), &worker.sink.entered, test_poll.isSet);
        token.requestStop();
        try std.testing.expect(!worker.done.load(.acquire)); // Loan still in feed.
        worker.sink.released.store(true, .release);
        thread.join();
        joined = true;
        switch (kind) {
            .inspect => {
                try std.testing.expectEqual(@as(?anyerror, null), worker.failure);
                try std.testing.expectEqual(@as(u64, 1), worker.bytes);
            },
            .list => try std.testing.expectEqual(error.Cancelled, worker.failure.?),
            .result => try std.testing.expectEqual(error.SinkFailed, worker.failure.?),
        }
    }
}

test "transport readiness cannot authorize reads or writes across a deadline" {
    const Clock = struct {
        var first: bool = true;
        var after_poll: i96 = undefined;
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const value = if (first) std.time.ns_per_s else after_poll;
            first = false;
            return .{ .nanoseconds = value };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const requests: Requests = .{ .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable } };
    const deadline = 10 * std.time.ns_per_s;
    for ([_]bool{ false, true }) |writing| {
        for ([_]i96{ -1, 0, 1 }) |offset| {
            const sockets = try socketPair();
            defer closeTestDescriptor(sockets[0]);
            defer closeTestDescriptor(sockets[1]);
            try addNonblocking(sockets[0]);
            try addNonblocking(sockets[1]);
            if (!writing) try writeAll(sockets[1], "x");
            Clock.first = true;
            Clock.after_poll = deadline + offset;
            var buffer: [1]u8 = undefined;
            if (writing) {
                if (offset >= 0) {
                    try std.testing.expectError(error.TransferInactive, writeAllRequest(requests, sockets[0], "x", deadline));
                    const count = std.c.read(sockets[1], &buffer, buffer.len);
                    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(count));
                } else {
                    try writeAllRequest(requests, sockets[0], "x", deadline);
                    try std.testing.expectEqual(@as(isize, 1), std.c.read(sockets[1], &buffer, buffer.len));
                    try std.testing.expectEqualStrings("x", &buffer);
                }
            } else {
                if (offset >= 0) {
                    try std.testing.expectError(error.ResponseInactive, readRequest(requests, sockets[0], &buffer, deadline));
                    // Expiry does not consume the byte; no-deadline waiting
                    // still accepts readiness at the same observed time.
                    try std.testing.expectEqual(@as(usize, 1), try readRequest(requests, sockets[0], &buffer, null));
                } else try std.testing.expectEqual(@as(usize, 1), try readRequest(requests, sockets[0], &buffer, deadline));
                try std.testing.expectEqualStrings("x", &buffer);
            }
        }
    }
}

test "transport cancellation quanta neither expire nor renew inactivity and observed stop wins" {
    const Stopper = struct {
        fn run(token: *Cancellation) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(700), .awake) catch unreachable;
            token.requestStop();
        }
    };
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    defer closeTestDescriptor(sockets[1]);
    var token: Cancellation = .{};
    const requests: Requests = .{ .io = std.testing.io, .cancellation = &token };
    const stopper = try std.Thread.spawn(.{}, Stopper.run, .{&token});
    defer stopper.join();
    const start = std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds;
    try std.testing.expect(!try waitRequest(requests, sockets[0], std.posix.POLL.IN, start + 250 * std.time.ns_per_ms));
    try std.testing.expect(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds - start >= 250 * std.time.ns_per_ms);
    token.requestStop();
    try std.testing.expectError(error.Cancelled, waitRequest(requests, sockets[0], std.posix.POLL.IN, start));
    try writeAll(sockets[1], "ready");
    try std.testing.expectError(error.Cancelled, waitRequest(requests, sockets[0], std.posix.POLL.IN, null));
}

test "transport cancellation saturated Unix backlog is not a connected writable socket" {
    // Darwin refuses a connect beyond the backlog at once; Linux leaves it
    // pending until the deadline or cancellation. Darwin reads a zero backlog
    // as its maximum, so request one and queue peers until one does not
    // connect.
    const blocks = @import("os/os.zig").full_backlog_blocks_connect;
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    var address_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const address = try tmp.address("socket", &address_buffer);
    var listener = try address.listen(io, .{ .kernel_backlog = 1 });
    defer listener.deinit(io);
    const queued = try address.connect(io);
    defer queued.close(io);
    var peers: [8]std.posix.fd_t = undefined;
    var count: usize = 0;
    defer for (peers[0..count]) |fd| closeTestDescriptor(fd);
    const blocked = while (count < peers.len) {
        const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
        peers[count] = connectRequest(.{ .io = io }, address, until) catch |err| break err;
        count += 1;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(if (blocks) error.TransferInactive else error.UnixConnectFailed, blocked);
    var token: Cancellation = .{};
    const Stopper = struct {
        fn run(stop: *Cancellation) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(150), .awake) catch unreachable;
            stop.requestStop();
        }
    };
    const stopper = try std.Thread.spawn(.{}, Stopper.run, .{&token});
    defer stopper.join();
    const stopped = connectRequest(.{ .io = io, .cancellation = &token }, address, std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s);
    if (stopped) |fd| closeTestDescriptor(fd) else |_| {}
    try std.testing.expectError(if (blocks) error.Cancelled else error.UnixConnectFailed, stopped);
}
