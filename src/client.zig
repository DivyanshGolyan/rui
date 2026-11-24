const std = @import("std");
const utf8_validation = @import("utf8_validation.zig");
const socket_os = @import("os").socket;
const platform = @import("platform.zig");
const host_endpoint = @import("host_endpoint.zig");
const protocol = @import("protocol.zig");
const Bounded = @import("bounded.zig").Bounded;
const content_value = @import("content_value.zig");
pub const activity_reply = @import("activity_reply.zig");
const configure_input = @import("configure_input.zig");
const ConfigureInput = configure_input.ConfigureInput;
const OptionalPolicy = configure_input.OptionalPolicy;
const OptionalText = configure_input.OptionalText;
const OptionalFile = configure_input.OptionalFile;
const environment_rule = @import("environment.zig");
const TerminalText = @import("TerminalText.zig");
const ResponseTiming = @import("ResponseTiming.zig");
const test_poll = @import("test_poll");
pub const protocol_reply = @import("protocol_reply.zig");
const session_list = @import("session_list.zig");

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

pub fn Stepped(comptime E: type, comptime T: type) type {
    return union(enum) {
        done: T,
        failed: struct { step: ?Step, err: E },

        fn fail(step: ?Step, err: E) @This() {
            return .{ .failed = .{ .step = step, .err = err } };
        }

        pub fn get(self: @This()) E!T {
            return switch (self) {
                .done => |value| value,
                .failed => |failure| failure.err,
            };
        }
    };
}

pub const Cancellation = struct {
    stopped: std.atomic.Value(bool) = .init(false),

    pub fn requestStop(self: *Cancellation) void {
        self.stopped.store(true, .release);
    }
};

pub const FailureOrigin = enum { local, host_transport };

pub const ReadContext = struct {
    io: std.Io,
    origin: *FailureOrigin,
    cancellation: ?*const Cancellation = null,
    read_failure: ?*?protocol_reply.ReadFailure = null,

    pub fn requests(self: ReadContext) Requests {
        return .{ .io = self.io, .cancellation = self.cancellation, .read_failure = self.read_failure, .failure_origin = self.origin };
    }
};

pub const Requests = struct {
    io: std.Io,
    cancellation: ?*const Cancellation = null,
    read_failure: ?*?protocol_reply.ReadFailure = null,
    failure_origin: ?*FailureOrigin = null,
    drop_reply: ?[]const u8 = null,
    mutation_timing: ResponseTiming = .mutation,

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

    fn transportFailure(self: Requests, err: anytype) @TypeOf(err) {
        if (@as(anyerror, err) != error.Cancelled) if (self.failure_origin) |origin| {
            origin.* = .host_transport;
        };
        return err;
    }

    fn check(self: Requests) error{Cancelled}!void {
        if (self.cancellation) |token| if (token.stopped.load(.acquire)) return error.Cancelled;
    }

    pub fn sendCaptured(self: Requests, captured: *CapturedRecord, environment: Environment, reply_buffer: *ReplyBuffer) Stepped(MutationSendError, protocol_reply.MutationReply) {
        reply_buffer.len = 0;
        self.check() catch |err| return .fail(null, err);
        const carried: ?Environment = if (captured.target == .message) environment else null;
        if (carried) |value| if (value.bytes() > protocol.max_environment_bytes) return .fail(null, error.EnvironmentTooLarge);
        const paths = captured.resolvePaths(self.io) catch |err| return .fail(.store, err);
        captured.paths = paths; // retain the invocation's route for failure reporting
        const reply = switch (sendSource(self, &paths, std.meta.activeTag(captured.target).route(), self.mutation_timing, captured.length, &captured.file, null, null, carried, reply_buffer, null)) {
            .done => |reply| reply,
            .failed => |failure| return .fail(failure.step, failure.err),
        };
        var result = protocol_reply.decodeMutationReply(reply, captured.saved.session.slice(), captured.target);
        result.context.store = captured.saved.store;
        result.context.key = captured.saved.key;
        result.context.kind = captured.saved.kind;
        return .{ .done = result };
    }

    pub fn observeCommand(self: Requests, store_path: []const u8, key: []const u8, since: ?protocol_reply.SessionToken, reply_buffer: *ObservationBuffer) !protocol_reply.ObservationReply {
        return self.observeCommandUntil(store_path, key, since, reply_buffer, null);
    }

    fn observeCommandUntil(self: Requests, store_path: []const u8, key: []const u8, since: ?protocol_reply.SessionToken, reply_buffer: *ObservationBuffer, until: ?i128) !protocol_reply.ObservationReply {
        try self.check();
        if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
        const paths = try resolveClientPaths(self.io, store_path);
        return self.observeCommandAt(&paths, key, since, reply_buffer, until);
    }

    pub fn observeCommandAt(self: Requests, paths: *const platform.Paths, key: []const u8, since: ?protocol_reply.SessionToken, reply_buffer: *ObservationBuffer, until: ?i128) !protocol_reply.ObservationReply {
        reply_buffer.len = 0;
        try self.check();
        if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
        var body: protocol.RequestBuffer = .{};
        var token_buffer: [protocol_reply.SessionToken.max_bytes]u8 = undefined;
        try body.appendShape(protocol.observe_command_request.head, .{ paths.store_identity.slice(), key });
        if (since) |token| try body.appendShape(protocol.observe_command_request.since, .{@as(?[]const u8, token.format(&token_buffer))});
        try body.appendShape(protocol.observe_command_request.tail, .{});
        const reply = try sendSource(self, paths, "/v1/observe-command", .{}, body.len, null, body.slice(), null, null, reply_buffer, until).get();
        return protocol_reply.ObservationReply.parse(reply, key, since);
    }

    pub fn observeMessage(self: Requests, address: *const protocol_reply.MessageAddress) !protocol_reply.ObservationReply {
        var buffer: ObservationBuffer = .{};
        const reply = try self.observeCommand(address.store.slice(), address.key.slice(), null, &buffer);
        return switch (reply) {
            .observation => |observation| .{ .observation = .{ .facts = try observation.facts.forMessage(address), .since = observation.since } },
            .not_modified => error.InvalidObservation,
            .failure => reply,
        };
    }

    pub fn readResult(self: Requests, store_path: []const u8, key: []const u8, destination: std.Io.File, reply_buffer: *ReplyBuffer) !protocol_reply.ResultReadReply {
        return readResultWithSink(self, store_path, key, destination, reply_buffer);
    }

    pub fn readResultStream(self: Requests, store_path: []const u8, key: []const u8, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ResultReadReply {
        return readResultWithSink(self, store_path, key, sink, reply_buffer);
    }

    pub fn inspectSession(self: Requests, store_path: []const u8, session: []const u8, profile: protocol.ReportProfile, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        reply_buffer.len = 0;
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        switch (profile) {
            .current => try body.appendShape(protocol.inspect_session_request.head ++ protocol.inspect_session_request.tail, .{ paths.store_identity.slice(), session }),
            .full => try body.appendShape((protocol.inspect_session_request.head ++ protocol.inspect_session_request.profile ++ protocol.inspect_session_request.tail), .{ paths.store_identity.slice(), session }),
        }
        const fd = try openRead(self, &paths, "/v1/inspect-session", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    pub fn exportFailedResponse(self: Requests, store_path: []const u8, session: []const u8, selection: protocol.FailedResponseExport, destination: std.Io.File, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (selection.operation == 0 or selection.operation > std.math.maxInt(i64) or selection.attempt == 0 or selection.attempt > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape((protocol.inspect_session_request.head ++ protocol.inspect_session_request.failed_response ++ protocol.inspect_session_request.tail), .{ paths.store_identity.slice(), session, selection.part, selection.operation, selection.attempt });
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

    pub fn listSessions(self: Requests, store_path: []const u8, workspace: ?[]const u8, cursor: protocol_reply.SessionListCursor, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        return self.listSessionsFiltered(store_path, workspace, .active, cursor, sink, reply_buffer);
    }

    pub fn listSessionsFiltered(self: Requests, store_path: []const u8, workspace: ?[]const u8, archive: protocol.SessionArchiveFilter, cursor: protocol_reply.SessionListCursor, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        reply_buffer.len = 0;
        try self.check();
        if (workspace) |value| {
            if (value.len == 0 or value.len > protocol.max_workspace_bytes or
                !std.unicode.utf8ValidateSlice(value)) return error.InvalidWorkspace;
        }
        try cursor.validate();
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try appendListSessions(&body, paths.store_identity.slice(), workspace, archive, cursor);
        const fd = try openRead(self, &paths, "/v1/list-sessions", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    /// One Archived window page: `window` is `head`, `tail`, `below` or `above`, and the reply is read
    /// with `protocol_reply.ArchivedWindowPage.read`.
    pub fn listArchivedWindow(self: Requests, store_path: []const u8, window: session_list.ArchivedCursor, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        reply_buffer.len = 0;
        try self.check();
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        var text: [session_list.archived_cursor_text_bytes]u8 = undefined;
        try body.appendShape(protocol.list_sessions_request.head, .{ paths.store_identity.slice(), @as(?[]const u8, null) });
        try body.appendShape(protocol.list_sessions_request.archive, .{protocol.SessionArchiveFilter.archived});
        try body.appendShape(protocol.list_sessions_request.cursor, .{ @as(u64, 0), @as(u64, 0) });
        try body.appendShape(protocol.list_sessions_request.window, .{session_list.formatArchivedCursor(window, &text)});
        try body.appendShape(protocol.list_sessions_request.tail, .{});
        const fd = try openRead(self, &paths, "/v1/list-sessions", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    pub fn publishAction(self: Requests, store_path: []const u8, handle: []const u8, key: []const u8, text: []const u8, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        try self.check();
        if (key.len == 0 or key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
        if (handle.len > 32 or text.len > protocol.max_action_value_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidTarget;
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.FixedJsonBuffer(protocol.shapeBytes(protocol.action_publish_request)) = .{};
        try body.appendShape(protocol.action_publish_request, .{ paths.store_identity.slice(), handle, key, text });
        const fd = try openRead(self, &paths, "/v1/action-publish", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    pub fn readAction(self: Requests, store_path: []const u8, session: []const u8, action_id: u64, offset: u64, after: u64, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        reply_buffer.len = 0;
        try self.check();
        if (!protocol.validSessionId(session) or action_id == 0 or action_id > std.math.maxInt(i64) or offset > protocol.max_sqlite_content_bytes or after > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.read_action_request.all, .{ paths.store_identity.slice(), session, action_id, offset, after });
        const fd = try openRead(self, &paths, "/v1/read-action", body.slice());
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
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.conversation_page_request, .{ paths.store_identity.slice(), session, cursor.end, cursor.before_position, cursor.before_ordinal });
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

    pub fn readConversationContent(self: Requests, store_path: []const u8, session: []const u8, position: u64, ordinal: u64, expected: ?protocol_reply.CommandObservation.ContentReference, sink: anytype) !?protocol_reply.ReadFailure {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64) or ordinal > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.conversation_content_request.all, .{ paths.store_identity.slice(), session, position, ordinal });
        const fd = try openRead(self, &paths, "/v1/conversation-content", body.slice());
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, expected, sink);
    }

    pub fn activityPage(self: Requests, store_path: []const u8, session: []const u8, cursor: protocol_reply.ActivityCursor) !protocol_reply.ActivityPageReply {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        try cursor.validate();
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape((protocol.activity_page_request.head ++ protocol.activity_page_request.tail), .{ paths.store_identity.slice(), session, cursor.end, cursor.position, cursor.ordinal, cursor.direction, cursor.kinds, cursor.limit });
        const fd = try openRead(self, &paths, "/v1/activity-page", body.slice());
        defer closeSocket(self.io, fd);
        const Sink = struct {
            buffer: protocol.FixedJsonBuffer(activity_reply.max_page_bytes) = .{},
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

    /// Asks the Host to list `server` (or every configured server when null) again. The reply
    /// names each asked server and the generation it was given; `toolsStatus` reports when it lands.
    pub fn reloadTools(self: Requests, gpa: std.mem.Allocator, store_path: []const u8, server: ?[]const u8) !ToolsAsked {
        try self.check();
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        if (server) |name| {
            try body.appendShape(protocol.tools_reload_request.named, .{ paths.store_identity.slice(), name });
        } else {
            try body.appendShape(protocol.tools_reload_request.all, .{paths.store_identity.slice()});
        }
        const fd = try openRead(self, &paths, "/v1/control/tools-reload", body.slice());
        defer closeSocket(self.io, fd);
        const reply = try readReportBody(self, fd, gpa, toolsRefusal);
        defer gpa.free(reply);
        return parseToolsAsked(gpa, reply);
    }

    /// Reads every configured server's list status: its state, last outcome, finished generation and tool count.
    pub fn toolsStatus(self: Requests, gpa: std.mem.Allocator, store_path: []const u8) !ToolsStatus {
        try self.check();
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.tools_status_request, .{paths.store_identity.slice()});
        const fd = try openRead(self, &paths, "/v1/tools-status", body.slice());
        defer closeSocket(self.io, fd);
        const reply = try readReportBody(self, fd, gpa, toolsRefusal);
        defer gpa.free(reply);
        return parseToolsStatus(gpa, reply);
    }

    pub fn modelList(self: Requests, store_path: []const u8, gpa: std.mem.Allocator) ![]u8 {
        try self.check();
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.model_list_request, .{paths.store_identity.slice()});
        const fd = try openRead(self, &paths, "/v1/model-list", body.slice());
        defer closeSocket(self.io, fd);
        return readModelListResponse(self, fd, gpa);
    }

    pub fn skillSuggestions(self: Requests, gpa: std.mem.Allocator, store_path: []const u8, scope: @import("skill_suggestions.zig").Scope, prefix: []const u8) !@import("skill_suggestions.zig").Page {
        try self.check();
        if (prefix.len > 64 or !std.unicode.utf8ValidateSlice(prefix)) return error.InvalidPrefix;
        switch (scope) {
            .session => |session| try protocol_reply.validateIdentityInputs("", session),
            .workspace => |workspace| if (workspace.len == 0 or workspace.len > protocol.max_workspace_bytes or !std.unicode.utf8ValidateSlice(workspace)) return error.InvalidWorkspace,
        }
        const paths = try resolveClientPaths(self.io, store_path);
        const body = try gpa.create(protocol.RequestBuffer);
        defer gpa.destroy(body);
        body.len = 0;
        switch (scope) {
            .session => |session| {
                try body.appendShape(protocol.skill_suggestions_session_request, .{ paths.store_identity.slice(), session, prefix });
            },
            .workspace => |workspace| {
                try body.appendShape(protocol.skill_suggestions_workspace_request, .{ paths.store_identity.slice(), workspace, prefix });
            },
        }
        const fd = try openRead(self, &paths, "/v1/skill-suggestions", body.slice());
        defer closeSocket(self.io, fd);
        const Sink = struct {
            bytes: std.ArrayList(u8) = .empty,
            gpa: std.mem.Allocator,
            pub fn feed(s: *@This(), bytes: []const u8) !void {
                if (bytes.len > protocol.skill_suggestions_reply.max_bytes - s.bytes.items.len) return error.ResponseTooLarge;
                try s.bytes.appendSlice(s.gpa, bytes);
            }
        };
        var sink: Sink = .{ .gpa = gpa };
        defer sink.bytes.deinit(gpa);
        var buffer: ReplyBuffer = .{};
        switch (try readReportResponse(self, fd, &sink, &buffer)) {
            .report => {},
            .command => |reply| return self.failRead(try self.captureReadFailure(reply)),
        }
        var page = try protocol_reply.decodeSkillSuggestions(gpa, sink.bytes.items);
        errdefer page.deinit(gpa);
        for (page.entries) |entry| if (!std.mem.startsWith(u8, entry.name, prefix)) return error.InvalidResponse;
        return page;
    }

    /// The owner's whole certified part list, streamed into `sink` (a report scratch file);
    /// decode it with `protocol_reply.PublicPartsReply`.
    pub fn readPublicParts(self: Requests, store_path: []const u8, session: []const u8, owner: content_value.Owner, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ReportReply {
        reply_buffer.len = 0;
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (owner.id() == 0 or owner.id() > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.public_parts_request, .{ paths.store_identity.slice(), session, protocol.OwnerJson{ .owner = owner } });
        const fd = try openRead(self, &paths, "/v1/public-parts", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    /// One part's whole stream; its length and digest must match the certified `part`.
    pub fn readPublicPartContent(self: Requests, store_path: []const u8, session: []const u8, owner: content_value.Owner, part: content_value.Part, sink: anytype) !?protocol_reply.ReadFailure {
        const fd = try self.openPublicPart(store_path, session, owner, part);
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, .{ .bytes = part.reference.length, .digest = part.reference.digest }, sink);
    }

    /// The first line of one Text part; the stream's length must match the certified `part`.
    pub fn readPublicPartPrefix(self: Requests, store_path: []const u8, session: []const u8, owner: content_value.Owner, part: content_value.Part, buffer: []u8) !protocol_reply.ActivityPrefixReply {
        const fd = try self.openPublicPart(store_path, session, owner, part);
        defer closeSocket(self.io, fd);
        return readFirstLine(self, fd, part.reference.length, buffer);
    }

    fn openPublicPart(self: Requests, store_path: []const u8, session: []const u8, owner: content_value.Owner, part: content_value.Part) !std.posix.fd_t {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (owner.id() == 0 or owner.id() > std.math.maxInt(i64) or part.ordinal >= @import("input_parts.zig").max_parts) return error.InvalidTarget;
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.public_part_content_request.all, .{ paths.store_identity.slice(), session, protocol.OwnerJson{ .owner = owner }, part.ordinal, 0 });
        return openRead(self, &paths, "/v1/public-part-content", body.slice());
    }

    pub fn readActivityContent(self: Requests, store_path: []const u8, session: []const u8, position: u64, ordinal: u64, expected: ?protocol_reply.CommandObservation.ContentReference, sink: anytype) !?protocol_reply.ReadFailure {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64) or ordinal > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.activity_content_request, .{ paths.store_identity.slice(), session, position, ordinal });
        const fd = try openRead(self, &paths, "/v1/activity-content", body.slice());
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, expected, sink);
    }

    pub fn readActivityPrefix(self: Requests, store_path: []const u8, session: []const u8, position: u64, buffer: []u8) !protocol_reply.ActivityPrefixReply {
        try self.check();
        try protocol_reply.validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(protocol.activity_content_request, .{ paths.store_identity.slice(), session, position, 0 });
        const fd = try openRead(self, &paths, "/v1/activity-content", body.slice());
        defer closeSocket(self.io, fd);
        return readFirstLine(self, fd, null, buffer);
    }
};

fn readFirstLine(requests: Requests, fd: std.posix.fd_t, expected_length: ?u64, buffer: []u8) !protocol_reply.ActivityPrefixReply {
    const head = try readResponseHeadUntil(requests, fd, .{}, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        var reply_buffer: ReplyBuffer = .{};
        return .{ .failure = try protocol_reply.decodeReadFailure(try readCommandBodyUntil(requests, fd, head, &reply_buffer, .{}, null), false) };
    }
    if (head.kind != .content_bytes or head.total != head.content_length or head.next != head.content_length) return error.InvalidResponse;
    if (expected_length) |length| if (head.content_length != length) return error.ContentBindingMismatch;
    const wanted: usize = @intCast(@min(head.content_length, buffer.len));
    var filled: usize = 0;
    const line = while (filled != wanted) {
        const count = try readRequest(requests, fd, buffer[filled..wanted], ResponseTiming.transfer.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, null, true));
        if (count == 0) return requests.transportFailure(error.TruncatedResponse);
        if (std.mem.indexOfScalar(u8, buffer[filled..][0..count], '\n')) |index| break buffer[0 .. filled + index];
        filled += count;
    } else if (wanted < head.content_length) utf8_validation.completePrefix(buffer[0..wanted]) else buffer[0..wanted];
    const text = std.mem.trimEnd(u8, line, "\r");
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidResponse;
    return .{ .line = text };
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
            if (count == 0) return requests.transportFailure(error.TruncatedResponse);
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

pub const MessageOperand = union(enum) { text: []const u8, text_file: []const u8, image: []const u8 };

pub const MessageInput = struct {
    store: []const u8,
    session: []const u8,
    text_path: []const u8,
    text: ?[]const u8 = null,
    operands: []const MessageOperand = &.{},
    /// Borrowed stdin source for ordered operands; null selects process stdin.
    operand_stdin: ?std.Io.File = null,
    configuration: ?ConfigureInput = null,
    /// Refuse the Message unless the Session's provider is served (the Host checks it at admission).
    require_model: bool = false,
    sender: ?Address = null,
    sender_handle: ?[]const u8 = null,
};

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

pub const SessionPinInput = struct {
    store: []const u8,
    session: []const u8,
    pinned: bool,
};

pub const SessionArchiveInput = struct {
    store: []const u8,
    session: []const u8,
    archived: bool = true,
};

pub const ModelInterruptionInput = struct {
    store: []const u8,
    session: []const u8,
    turn_id: u64,
    operation_id: u64,
};

pub const ActionBackgroundInput = struct {
    store: []const u8,
    session: []const u8,
    action_id: u64,
};

pub const ActionStopInput = struct {
    store: []const u8,
    session: []const u8,
    action_id: u64,
};

pub const PermissionDecisionInput = struct {
    store: []const u8,
    session: []const u8,
    action_id: u64,
    decision: protocol.PermissionDecision = .deny,
};

pub const ReplyBuffer = protocol.ResponseBuffer;
pub const ObservationBuffer = protocol.CommandObservationBuffer;

pub const HostStopInput = struct {
    store: []const u8,
    instance: protocol.InstanceId,
    /// Asks for a draining pause of this many seconds (1..86400).
    drain_seconds: ?u32 = null,
    drop_reply: ?[]const u8 = null,
};

pub const HostStopResult = union(enum) {
    acknowledged,
    /// A draining pause is in force until this Unix time in milliseconds.
    draining: u64,
    instance_changed,
    unavailable,
};

pub fn stopHost(io: std.Io, input: HostStopInput, reply_buffer: *ReplyBuffer) !HostStopResult {
    reply_buffer.len = 0;
    const paths = try resolveClientPaths(io, input.store);
    var body: protocol.RequestBuffer = .{};
    if (input.drain_seconds) |seconds|
        try body.appendShape(protocol.host_drain_request, .{ paths.store_identity.slice(), seconds })
    else
        try body.appendShape(protocol.host_stop_request, .{paths.store_identity.slice()});
    const reply = sendSource(.{ .io = io, .drop_reply = input.drop_reply }, &paths, "/v1/control/host-stop", ResponseTiming.mutation, body.len, null, body.slice(), &input.instance, null, reply_buffer, null).get();
    const result = reply catch |err| return if (err == error.FileNotFound or err == error.ConnectionRefused)
        .unavailable
    else
        err;
    if (result.status == 200 and std.mem.eql(u8, result.body, protocol.host_stop_ack)) return .acknowledged;
    if (result.status == 200) if (drainUntil(result.body)) |until| return .{ .draining = until };
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

fn drainUntil(body: []const u8) ?u64 {
    const head = protocol.host_drain_reply[0];
    const tail = protocol.host_drain_reply[2];
    if (!std.mem.startsWith(u8, body, head) or !std.mem.endsWith(u8, body, tail) or body.len <= head.len + tail.len) return null;
    const digits = body[head.len .. body.len - tail.len];
    if (digits.len > 1 and digits[0] == '0') return null;
    for (digits) |byte| if (byte < '0' or byte > '9') return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

test "a draining stop reply carries its deadline, and nothing else parses as one" {
    var buffer: [256]u8 = undefined;
    const valid = try std.fmt.bufPrint(&buffer, "{s}{d}{s}", .{ protocol.host_drain_reply[0], 1795356312000, protocol.host_drain_reply[2] });
    try std.testing.expectEqual(@as(?u64, 1795356312000), drainUntil(valid));
    for ([_][]const u8{ protocol.host_stop_ack, protocol.host_drain_reply[0] ++ protocol.host_drain_reply[2], protocol.host_drain_reply[0] ++ "01" ++ protocol.host_drain_reply[2], protocol.host_drain_reply[0] ++ "1x" ++ protocol.host_drain_reply[2], protocol.host_drain_reply[0] ++ "99999999999999999999" ++ protocol.host_drain_reply[2] }) |body| {
        try std.testing.expectEqual(@as(?u64, null), drainUntil(body));
    }
}

pub fn hostStatus(io: std.Io, store_path: []const u8) protocol_reply.HostStatus {
    return hostStatusUntil(io, store_path, null);
}

/// Platform derives placement; only this wire client resolves MySQL identity.
/// Legacy opaque-id/runtime selections and saved-directory selections converge
/// on the same Paths value before any mutation is encoded.
pub fn resolveClientPaths(io: std.Io, supplied: []const u8) !platform.Paths {
    var paths = try platform.resolveClientPaths(io, supplied);
    if (paths.kind == .mysql and !@import("store_id.zig").valid(paths.store_identity.slice())) try resolveMysqlIdentity(io, &paths);
    return paths;
}

/// Startup callers can bound the entire readiness loop, including each probe.
pub fn hostStatusUntil(io: std.Io, store_path: []const u8, deadline: ?i128) protocol_reply.HostStatus {
    // Observation discovers identity in its one bounded Host-info exchange.
    // Mutation resolution would do an eager, separately timed exchange here.
    const paths = platform.resolveClientPaths(io, store_path) catch |err| return switch (err) {
        error.FileNotFound => .unavailable,
        else => .access_failure,
    };
    return hostStatusAt(io, &paths, deadline);
}

pub fn hostStatusAt(io: std.Io, paths: *const platform.Paths, deadline: ?i128) protocol_reply.HostStatus {
    if (paths.kind == .mysql) return readHostInfo(io, paths, deadline);
    return switch (lockState(io, paths)) {
        .free => .unavailable,
        .held => readHostInfo(io, paths, deadline),
        .failure => .access_failure,
    };
}

pub const ObservedHost = struct {
    ready: @FieldType(protocol_reply.HostStatus, "ready"),
    pid: c_int,
};

pub fn observeHostProcess(io: std.Io, store_path: []const u8, deadline: ?i128) !ObservedHost {
    return switch (try readHostControl(io, store_path, deadline, .strict)) {
        .compatible => |observed| .{ .ready = observed.info, .pid = observed.pid },
        .incompatible => error.WrongWireVersion,
    };
}

pub fn observeHostProcessAt(io: std.Io, paths: *const platform.Paths, deadline: ?i128) !ObservedHost {
    var identified = paths.*;
    if (identified.kind == .mysql and !@import("store_id.zig").valid(identified.store_identity.slice())) try resolveMysqlIdentity(io, &identified);
    return switch (try readHostControlAt(io, &identified, deadline, .strict)) {
        .compatible => |observed| .{ .ready = observed.info, .pid = observed.pid },
        .incompatible => error.WrongWireVersion,
    };
}

/// A wire mismatch is not readiness. Only Upgrade's pinned-process owner may
/// use its same-connection peer PID to replace an obsolete terminal client.
pub const HostProcessReading = union(enum) {
    ready: ObservedHost,
    incompatible: c_int,

    pub fn pid(self: HostProcessReading) c_int {
        return switch (self) {
            .ready => |observed| observed.pid,
            .incompatible => |peer| peer,
        };
    }
};

pub fn observeHostProcessForUpgrade(io: std.Io, store_path: []const u8, deadline: ?i128) !HostProcessReading {
    return switch (try readHostControl(io, store_path, deadline, .upgrade)) {
        .compatible => |observed| .{ .ready = .{ .ready = observed.info, .pid = observed.pid } },
        .incompatible => |peer| .{ .incompatible = peer.pid },
    };
}

/// What an upgrade reads of one running Host. `foreign` marks a Host on another
/// wire: its facts are the `host status` envelope its own executable prints, and
/// it is stopped by that executable's `host pause`. No per-wire decoder exists.
pub const HostControlObservation = struct {
    foreign: bool,
    facts: StatusFacts,
    pid: c_int,
    /// Local discovery routing, never wire Store identity. Most direct readers
    /// already hold DIR; socket discovery must retain it for restart-all.
    host_directory: @import("host_settings.zig").OsBytes(protocol.max_store_bytes) = .{},

    pub fn directory(self: *const HostControlObservation) []const u8 {
        return if (self.host_directory.len != 0) self.host_directory.slice() else self.facts.store.slice();
    }
};

/// The facts an upgrade decision reads from a Host, whichever wire it speaks.
pub const StatusFacts = struct {
    instance: protocol.InstanceId,
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    active_capacity: usize,
    settings_digest: ?@import("host_settings_handoff.zig").Digest = null,
};

pub fn observeHostForUpgrade(allocator: std.mem.Allocator, io: std.Io, store_path: []const u8, deadline: ?i128) !HostControlObservation {
    const paths = try resolveClientPaths(io, store_path);
    return observeHostForUpgradeAt(allocator, io, &paths, hostObservationDeadline(io, deadline), .{});
}

/// `until` is the shared discovery budget for the socket exchange and, after a
/// wrong-wire reply, for the foreign read.
fn observeHostForUpgradeAt(allocator: std.mem.Allocator, io: std.Io, paths: *const platform.Paths, until: i128, foreign: ForeignHostReader) !HostControlObservation {
    // One current-wire exchange either observes the Host or advertises the wire
    // it speaks. Another wire is read through its own executable, so every
    // supported Host costs one socket exchange inside the shared discovery budget (#1835).
    return switch (try readHostControlAt(io, paths, until, .upgrade)) {
        .compatible => |observed| .{ .foreign = false, .facts = statusOf(observed.info), .pid = observed.pid, .host_directory = observed.host_directory },
        .incompatible => |peer| foreign_observation: {
            // The DIR the caller holds addresses the Host's own `host status`.
            if (paths.host_directory.len == 0) return error.HostDirectoryUnavailable;
            const facts = try readForeignHost(allocator, io, peer.pid, paths.host_directory.slice(), until, foreign);
            break :foreign_observation .{ .foreign = true, .facts = facts, .pid = peer.pid, .host_directory = paths.host_directory };
        },
    };
}

/// The replaceable parts of a foreign read. Production reads the Host's own
/// `host status` and the pid's kernel generation; tests substitute either one.
pub const ForeignHostReader = struct {
    status: *const fn (allocator: std.mem.Allocator, io: std.Io, executable: []const u8, directory: []const u8, until: i128) anyerror!StatusFacts = readForeignHostStatus,
    generation: *const fn (pid: c_int) anyerror!u64 = @import("host_identity.zig").generation,
};

fn statusOf(info: protocol_reply.HostInfoFacts) StatusFacts {
    return .{ .instance = info.instance, .store = info.store, .active_capacity = info.active_capacity, .settings_digest = info.settings_digest };
}

/// Reads a Host on another wire through the executable that runs it. The
/// executable is the pid's own snapshot, and the pid must keep its generation.
fn readForeignHost(allocator: std.mem.Allocator, io: std.Io, pid: c_int, directory: []const u8, until: i128, reader: ForeignHostReader) !StatusFacts {
    const identity = @import("host_identity.zig");
    var wiping: @import("secret_value.zig").WipingAllocator = .{ .backing = allocator };
    var snapshot = try identity.snapshot(wiping.allocator(), pid);
    defer snapshot.deinit(wiping.allocator());
    const facts = try reader.status(allocator, io, snapshot.executable, directory, until);
    if ((reader.generation(pid) catch 0) != snapshot.started) return error.HostPeerPidMismatch;
    return facts;
}

/// The one reader of a foreign Host's facts: its executable's public `host
/// status --store DIR`, decoded by parseUpgradeStatus. The envelope's own
/// version is not checked; any failure leaves the Host unobserved, never stopped.
pub fn readForeignHostStatus(allocator: std.mem.Allocator, io: std.Io, executable: []const u8, directory: []const u8, until: i128) !StatusFacts {
    if (until <= std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds) return error.TransferInactive;
    const processes = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "host", "status", "--store", directory },
        .stdout_limit = .limited(foreign_status_limit),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = .{ .raw = .{ .nanoseconds = @intCast(until) }, .clock = .awake } },
    });
    defer allocator.free(processes.stdout);
    defer allocator.free(processes.stderr);
    if (!processes.term.success()) return error.ForeignHostStatusFailed;
    return (try parseUpgradeStatus(allocator, processes.stdout)) orelse error.InvalidForeignHostStatus;
}

const foreign_status_limit = 64 * 1024;

/// What one listed socket showed. `unanswered` is a refusal or missing socket
/// at connect, after the retry: nothing accepted, so the census looks at its
/// endpoint once more. Every failure after a connection is an error instead.
pub const SocketObservation = union(enum) { unanswered: anyerror, observed: HostControlObservation };

/// A refused connect is retried until `refused_until` (default: 200 ms from
/// now) for a Host that bound its socket but is not listening yet. A census
/// passes one shared window for every socket, so sockets that refuse cost one
/// window in total, not one each.
pub fn observeHostForUpgradeAtSocket(allocator: std.mem.Allocator, io: std.Io, socket_path: []const u8, deadline: ?i128, refused_until: ?i128) !SocketObservation {
    const until = hostObservationDeadline(io, deadline);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    // Retrying a refusal stops at the window; each attempt still has its own
    // bounded connect, so a closed window leaves exactly one attempt.
    const connect_until = @min(until, refused_until orelse refusedConnectWindow(io));
    const fd = connection: {
        while (true) {
            const connected = connectRequest(.{ .io = io }, address, @min(until, refusedConnectWindow(io))) catch |err| {
                if (err == error.ConnectionRefused) {
                    const remaining = connect_until - std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
                    if (remaining > 0) {
                        try std.Io.sleep(io, .fromNanoseconds(@intCast(@min(remaining, 25 * std.time.ns_per_ms))), .awake);
                        if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < connect_until) continue;
                    }
                }
                return switch (err) {
                    error.ConnectionRefused, error.FileNotFound => .{ .unanswered = err },
                    else => err,
                };
            };
            break :connection connected;
        }
    };
    defer closeSocket(io, fd);
    const identity = @import("host_identity.zig");
    const pid = try identity.peer(fd);
    var snapshot = try identity.snapshot(allocator, pid);
    defer snapshot.deinit(allocator);
    var wiping: @import("secret_value.zig").WipingAllocator = .{ .backing = allocator };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    defer arena.deinit();
    const sources = @import("serve_grammar.zig").runningSources(arena.allocator(), snapshot.argv) catch |err| {
        if (err == error.HostPeerNotServing) return error.HostPeerNotServing;
        return error.HostServeArgumentsUnreadable;
    };
    const supplied = sources.dir orelse return error.HostServeStoreMissing;
    // A relative argv path is not relative to this client. Without a verified
    // canonical identity, report it rather than probing a guessed Store.
    if (!std.fs.path.isAbsolute(supplied)) return error.HostServeStoreRelative;
    const paths = try resolveClientPaths(io, supplied);
    if (!std.mem.eql(u8, paths.socket.slice(), socket_path)) return error.HostSocketStoreMismatch;
    const observed = try observeHostForUpgradeAt(allocator, io, &paths, until, .{});
    if (observed.pid != pid or (identity.generation(pid) catch 0) != snapshot.started) return error.HostPeerPidMismatch;
    return .{ .observed = observed };
}

/// Authenticate the process at the saved DIR socket without decoding its wire
/// or resolving MySQL identity. The caller owns (and must wipe) the snapshot.
pub fn observeUpgradePeer(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, deadline: ?i128) !@import("host_identity.zig").Snapshot {
    const paths = try platform.resolveClientPaths(io, directory);
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(.{ .io = io }, address, hostObservationDeadline(io, deadline));
    defer closeSocket(io, fd);
    const identity = @import("host_identity.zig");
    return identity.snapshot(allocator, try identity.peer(fd));
}

/// The public status envelope, not a foreign Host wire decoder. Additive fields
/// are harmless; the envelope's version is a wire version, not a build identity.
pub fn parseUpgradeStatus(allocator: std.mem.Allocator, bytes: []const u8) !?StatusFacts {
    if (bytes.len > 64 * 1024) return null;
    const Envelope = struct {
        type: []const u8,
        status: []const u8,
        instance: ?[]const u8 = null,
        store: ?[]const u8 = null,
        active_capacity: ?[]const u8 = null,
        settings_digest: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(Envelope, allocator, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (!std.mem.eql(u8, value.type, "host_status") or !std.mem.eql(u8, value.status, "ready")) return null;
    var facts: StatusFacts = .{
        .instance = protocol.parseInstanceId(value.instance orelse return null) catch return null,
        .active_capacity = std.fmt.parseInt(usize, value.active_capacity orelse return null, 10) catch return null,
    };
    facts.store.set(value.store orelse return null) catch return null;
    if (value.settings_digest) |text| {
        // The spelling the Host's own status writes: 64 lowercase hex digits.
        if (text.len != 64) return null;
        for (text) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        var digest: @import("host_settings_handoff.zig").Digest = undefined;
        _ = std.fmt.hexToBytes(&digest, text) catch return null;
        facts.settings_digest = digest;
    }
    return facts;
}

/// Read-only census results. A process-table PID is only a hint; observations
/// below authenticate the resolved socket and confirm the hinted generation.
/// Paths are OS bytes and are owned independently of the temporary snapshots.
pub const UpgradeCandidate = struct {
    socket: ?[]const u8 = null,
    directory: ?[]const u8 = null,
    pid: ?c_int = null,
    generation: ?u64 = null,
    /// `unanswered` holds a socket that refused or vanished at connect until
    /// `settleUnansweredSockets` decides it. Callers never see `unanswered`.
    result: union(enum) { observed: HostControlObservation, failed: anyerror, unanswered: anyerror },

    pub fn deinit(self: UpgradeCandidate, allocator: std.mem.Allocator) void {
        if (self.socket) |path| allocator.free(path);
        if (self.directory) |path| allocator.free(path);
    }
};

fn knownUpgradeSocket(candidates: []const UpgradeCandidate, socket: []const u8) bool {
    for (candidates) |candidate| if (candidate.socket) |path| {
        if (std.mem.eql(u8, path, socket) and candidate.result == .observed) return true;
    };
    return false;
}

/// Takes ownership on success. Keep one result for a socket found by both
/// census routes, preferring authenticated facts over an earlier failed hint.
fn appendUpgradeCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList(UpgradeCandidate), candidate: UpgradeCandidate) !void {
    if (candidate.socket) |socket| {
        for (candidates.items) |*existing| {
            const other = existing.socket orelse continue;
            if (!std.mem.eql(u8, socket, other)) continue;
            if (existing.result == .observed) {
                candidate.deinit(allocator);
            } else {
                existing.deinit(allocator);
                existing.* = candidate;
            }
            return;
        }
    }
    try candidates.append(allocator, candidate);
}

/// Union the endpoint census (which removes every endpoint it proves dead)
/// with same-user process hints. A vanished or unreadable unrelated process is
/// not a Host failure. Once argv identifies a Host, unreadable required
/// sources are an explained per-Host failure instead.
pub fn discoverUpgradeHosts(allocator: std.mem.Allocator, io: std.Io, cancellation: ?*const Cancellation) ![]UpgradeCandidate {
    const requests: Requests = .{ .io = io, .cancellation = cancellation };
    try requests.check();
    var candidates: std.ArrayList(UpgradeCandidate) = .empty;
    errdefer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }
    const sockets = try host_endpoint.census(allocator, io);
    defer host_endpoint.freeSockets(allocator, sockets);
    // One window for the whole census: sockets that refuse cost 200 ms in
    // total, not 200 ms each, one after another, before any restart.
    const refused_until = refusedConnectWindow(io);
    for (sockets) |socket| {
        try requests.check();
        try candidates.ensureUnusedCapacity(allocator, 1);
        const observed = observeHostForUpgradeAtSocket(allocator, io, socket, null, refused_until);
        const result: @FieldType(UpgradeCandidate, "result") = if (observed) |seen| switch (seen) {
            .unanswered => |err| .{ .unanswered = err },
            .observed => |facts| .{ .observed = facts },
        } else |err| .{ .failed = err };
        const owned_socket = try allocator.dupe(u8, socket);
        errdefer allocator.free(owned_socket);
        const directory = if (result == .observed) try allocator.dupe(u8, result.observed.directory()) else null;
        candidates.appendAssumeCapacity(.{ .socket = owned_socket, .directory = directory, .generation = if (result == .observed) @import("host_identity.zig").generation(result.observed.pid) catch null else null, .result = result });
    }
    var uid: [32]u8 = undefined;
    const uid_text = try std.fmt.bufPrint(&uid, "{d}", .{std.c.geteuid()});
    const processes = std.process.run(allocator, io, .{
        .argv = &.{ "/bin/ps", "-u", uid_text, "-o", "pid=" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromSeconds(10), .clock = .awake }) },
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        settleUnansweredSockets(allocator, io, &candidates);
        try candidates.append(allocator, .{ .result = .{ .failed = err } });
        return candidates.toOwnedSlice(allocator);
    };
    defer allocator.free(processes.stdout);
    defer allocator.free(processes.stderr);
    if (!processes.term.success()) {
        settleUnansweredSockets(allocator, io, &candidates);
        try candidates.append(allocator, .{ .result = .{ .failed = error.HostProcessSnapshotUnavailable } });
        return candidates.toOwnedSlice(allocator);
    }
    var pids = std.mem.tokenizeAny(u8, processes.stdout, " \t\r\n");
    const identity = @import("host_identity.zig");
    while (pids.next()) |text| {
        try requests.check();
        const pid = std.fmt.parseInt(c_int, text, 10) catch continue;
        var snapshot = identity.snapshot(allocator, pid) catch continue;
        defer snapshot.deinit(allocator);
        if (snapshot.argv.len < 3 or !std.mem.eql(u8, snapshot.argv[1], "host") or !std.mem.eql(u8, snapshot.argv[2], "serve")) continue;
        // A socket census may have already authenticated this same Host.
        var known = false;
        for (candidates.items) |candidate| if (candidate.result == .observed and candidate.result.observed.pid == pid and candidate.generation == snapshot.started) {
            known = true;
            break;
        };
        if (known) continue;
        var wiping: @import("secret_value.zig").WipingAllocator = .{ .backing = allocator };
        var arena = std.heap.ArenaAllocator.init(wiping.allocator());
        defer arena.deinit();
        var candidate: UpgradeCandidate = .{ .pid = pid, .generation = snapshot.started, .result = .{ .failed = error.HostServeArgumentsUnreadable } };
        errdefer candidate.deinit(allocator);
        candidate.result = result: {
            const sources = @import("serve_grammar.zig").runningSources(arena.allocator(), snapshot.argv) catch |err| break :result .{ .failed = err };
            const directory = sources.dir orelse break :result .{ .failed = error.HostServeStoreMissing };
            candidate.directory = try allocator.dupe(u8, directory);
            if (!std.fs.path.isAbsolute(directory)) break :result .{ .failed = error.HostServeStoreRelative };
            const paths = platform.resolveClientPaths(io, directory) catch |err| break :result .{ .failed = err };
            const canonical_directory = try allocator.dupe(u8, paths.selector());
            allocator.free(candidate.directory.?);
            candidate.directory = canonical_directory;
            candidate.socket = try allocator.dupe(u8, paths.socket.slice());
            if (knownUpgradeSocket(candidates.items, paths.socket.slice())) break :result .{ .failed = error.HostPeerPidMismatch };
            var peer = observeUpgradePeer(allocator, io, directory, null) catch |err| {
                if (err != error.FileNotFound) break :result .{ .failed = err };
                // No endpoint where this build derives it: a Host of a release
                // that served elsewhere. Read it through its own executable,
                // as a Host on another wire is, rather than through a path.
                break :result if (readMovedHost(allocator, io, pid, paths.selector())) |observed| .{ .observed = observed } else |failure| .{ .failed = failure };
            };
            defer peer.deinit(allocator);
            if (peer.pid != pid or peer.started != snapshot.started) break :result .{ .failed = error.HostPeerPidMismatch };
            const observed = observeHostForUpgrade(allocator, io, directory, null) catch |err| break :result .{ .failed = err };
            if (observed.pid != pid or (identity.generation(pid) catch 0) != snapshot.started) break :result .{ .failed = error.HostPeerPidMismatch };
            break :result .{ .observed = observed };
        };
        try appendUpgradeCandidate(allocator, &candidates, candidate);
    }
    settleUnansweredSockets(allocator, io, &candidates);
    return candidates.toOwnedSlice(allocator);
}

fn readMovedHost(allocator: std.mem.Allocator, io: std.Io, pid: c_int, directory: []const u8) !HostControlObservation {
    var observed: HostControlObservation = .{ .foreign = true, .pid = pid, .facts = try readForeignHost(allocator, io, pid, directory, hostObservationDeadline(io, null), .{}) };
    try observed.host_directory.set(directory);
    return observed;
}

/// Looks once more at the endpoint of each socket still unanswered after the
/// process census, which a Host process resolving to it has replaced: one
/// proven dead since goes, as the census would have removed it; any other
/// stays a per-Host failure.
fn settleUnansweredSockets(allocator: std.mem.Allocator, io: std.Io, candidates: *std.ArrayList(UpgradeCandidate)) void {
    var index: usize = 0;
    while (index < candidates.items.len) {
        const candidate = &candidates.items[index];
        const sighting: ?host_endpoint.Sighting = if (candidate.result == .unanswered) sighting: {
            const interface = host_endpoint.Interface.init(std.fs.path.dirname(candidate.socket.?) orelse "") catch break :sighting .unprovable;
            break :sighting host_endpoint.inspect(io, &interface);
        } else null;
        if (sighting != null and settleUnanswered(candidate, sighting.?) == .drop) {
            candidate.deinit(allocator);
            _ = candidates.orderedRemove(index);
            continue;
        }
        index += 1;
    }
}

/// The one rule for an unanswered socket, given what a fresh look at its
/// endpoint found.
fn settleUnanswered(candidate: *UpgradeCandidate, sighting: host_endpoint.Sighting) enum { keep, drop } {
    const err = switch (candidate.result) {
        .unanswered => |err| err,
        else => return .keep,
    };
    switch (sighting) {
        .reclaimed, .vanished => return .drop,
        .busy, .unprovable => {
            candidate.result = .{ .failed = err };
            return .keep;
        },
    }
}

/// Process generation and retirement are independent of runtime/Store leases.
/// A successful same-user census (which includes ps itself) proves absence;
/// unknown, truncated or failed observations never do. Zombies have retired
/// even when a foreground caller has not yet reaped them.
pub fn upgradeGenerationRetired(allocator: std.mem.Allocator, io: std.Io, pid: c_int, started: u64, deadline: i128) !bool {
    const identity = @import("host_identity.zig");
    const before = identity.generation(pid) catch null;
    var uid: [32]u8 = undefined;
    const processes = try std.process.run(allocator, io, .{
        .argv = &.{ "/bin/ps", "-u", try std.fmt.bufPrint(&uid, "{d}", .{std.c.geteuid()}), "-o", "pid=,stat=" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .deadline = .{ .raw = .{ .nanoseconds = @intCast(deadline) }, .clock = .awake } },
    });
    defer allocator.free(processes.stdout);
    defer allocator.free(processes.stderr);
    if (!processes.term.success() or processes.stderr.len != 0) return error.HostProcessSnapshotUnavailable;
    const after = identity.generation(pid) catch null;
    return retirementReading(processes.stdout, pid, started, before, after);
}

fn retirementReading(bytes: []const u8, pid: c_int, started: u64, before: ?u64, after: ?u64) !bool {
    if ((before != null and before.? != started) or (after != null and after.? != started)) return true;
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    var populated = false;
    var state: ?[]const u8 = null;
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const actual = std.fmt.parseInt(c_int, fields.next() orelse return error.HostProcessSnapshotUnavailable, 10) catch return error.HostProcessSnapshotUnavailable;
        const status = fields.next() orelse return error.HostProcessSnapshotUnavailable;
        if (actual <= 0 or status.len == 0 or fields.next() != null) return error.HostProcessSnapshotUnavailable;
        populated = true;
        if (actual == pid) {
            if (state != null) return error.HostProcessSnapshotUnavailable;
            state = status;
        }
    }
    if (!populated) return error.HostProcessSnapshotUnavailable;
    if (state) |status| return status[0] == 'Z' and before == started and after == started;
    return before != started and after != started;
}

/// How long socket discovery retries a refused connect to a Store whose lease
/// is still held: a live Host's full backlog refuses until it accepts.
const refused_connect_retry_ns = 200 * std.time.ns_per_ms;

/// The end of one refused-connect retry window starting now.
pub fn refusedConnectWindow(io: std.Io) i128 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + refused_connect_retry_ns;
}

fn hostObservationDeadline(io: std.Io, deadline: ?i128) i128 {
    const probe_end = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
    return @min(probe_end, deadline orelse probe_end);
}

/// Current-wire Host information read through the socket of `store_path`.
fn readHostControl(io: std.Io, store_path: []const u8, deadline: ?i128, mode: HostObservationMode) !HostControlReading {
    const paths = try resolveClientPaths(io, store_path);
    return readHostControlAt(io, &paths, deadline, mode);
}

const CurrentReading = struct {
    info: protocol_reply.HostInfoFacts,
    pid: c_int,
    host_directory: @import("host_settings.zig").OsBytes(protocol.max_store_bytes) = .{},
};
const HostControlReading = union(enum) { compatible: CurrentReading, incompatible: struct { pid: c_int, wire: protocol.Bounded(8) } };
const HostObservationMode = enum { strict, upgrade };

fn readHostControlAt(io: std.Io, paths: *const platform.Paths, deadline: ?i128, mode: HostObservationMode) !HostControlReading {
    const until = hostObservationDeadline(io, deadline);
    const requests: Requests = .{ .io = io };
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(requests, address, until);
    defer closeSocket(io, fd);
    const pid = try @import("host_identity.zig").peer(fd);
    try uploadHostInfoRequest(requests, fd, paths.store_identity.slice(), until);
    var reply_buffer: ReplyBuffer = .{};
    const envelope = try readResponseEnvelopeUntil(requests, fd, .{}, until);
    if (!envelope.wire_matches and mode == .strict) return error.WrongWireVersion;
    const head = envelope.head;
    if (head.kind != .command_json) return error.InvalidResponse;
    if (!envelope.wire_matches and head.status != 200 and head.status != 400) return error.InvalidHostInfo;
    const reply = try readCommandBodyUntil(requests, fd, head, &reply_buffer, .{}, until);
    if (!envelope.wire_matches) {
        if (!hostProtocolMismatch(envelope, reply.body, paths.store_identity.slice())) return error.InvalidHostInfo;
        return .{ .incompatible = .{ .pid = pid, .wire = envelope.wire } };
    }
    if (reply.status != 200) return error.InvalidHostInfo;
    return .{ .compatible = .{
        .info = (try protocol_reply.parseHostInfo(reply.body, paths.store_identity.slice())).ready,
        .pid = pid,
        .host_directory = paths.host_directory,
    } };
}

fn hostProtocolMismatch(envelope: ResponseEnvelope, body: []const u8, store: []const u8) bool {
    if (envelope.wire.len == 0) return false;
    const Body = struct { version: []const u8, type: []const u8, store: ?[]const u8 = null, code: ?[]const u8 = null };
    var memory: [2 * protocol.max_store_bytes + 256]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    const decoded = std.json.parseFromSliceLeaky(Body, fixed.allocator(), body, .{
        .ignore_unknown_fields = true,
        .max_value_len = protocol.max_store_bytes,
    }) catch return false;
    if (!std.mem.eql(u8, decoded.version, envelope.wire.slice())) return false;
    return switch (envelope.head.status) {
        200 => std.mem.eql(u8, decoded.type, "host_info") and decoded.code == null and
            std.mem.eql(u8, decoded.store orelse return false, store),
        400 => std.mem.eql(u8, decoded.type, "invocation_error") and
            std.mem.eql(u8, decoded.code orelse return false, "WrongWireVersion"),
        else => false,
    };
}

fn uploadHostInfoRequest(requests: Requests, fd: std.posix.fd_t, store: []const u8, until: i128) !void {
    var body: protocol.RequestBuffer = .{};
    try body.appendShape(.{ "{\"version\":", protocol.Hole{ .string = 8 }, ",\"kind\":\"host_info\",\"store\":", protocol.Hole{ .string = protocol.max_store_bytes }, "}" }, .{ protocol.wire_version, store });
    var header_buffer: [protocol.max_header_bytes]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST /v1/host-info HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ protocol.wire_version, body.len });
    try writeAllRequest(requests, fd, header, until);
    try writeAllRequest(requests, fd, body.slice(), until);
}

test "upgrade Host observation validates exact foreign rejection envelopes" {
    var envelope: ResponseEnvelope = .{
        .head = .{ .status = 400, .content_length = 0, .kind = .command_json },
        .wire_matches = false,
    };
    const foreign_wire = "22";
    try envelope.wire.set(foreign_wire);
    const rejected = "{\"version\":\"" ++ foreign_wire ++ "\",\"type\":\"invocation_error\",\"code\":\"WrongWireVersion\"}";
    try std.testing.expect(hostProtocolMismatch(envelope, rejected, "/store"));
    for ([_][]const u8{
        "{",
        rejected ++ "trailing",
        "{\"version\":\"" ++ foreign_wire ++ "\",\"type\":\"invocation_error\"}",
        "{\"version\":\"" ++ foreign_wire ++ "\",\"type\":\"invocation_error\",\"code\":\"wrongwireversion\"}",
        "{\"version\":\"" ++ foreign_wire ++ "\",\"type\":\"invocation_error\",\"code\":\"SomeOtherFailure\"}",
        "{\"version\":\"" ++ foreign_wire ++ "\",\"type\":\"host_unavailable\",\"code\":\"WrongWireVersion\"}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"WrongWireVersion\"}",
        "{\"version\":\"" ++ foreign_wire ++ "\",\"type\":\"invocation_error\",\"code\":\"WrongWireVersion\",\"code\":\"SomeOtherFailure\"}",
    }) |body| try std.testing.expect(!hostProtocolMismatch(envelope, body, "/store"));
    for ([_]u16{ 409, 500, 503 }) |status| {
        envelope.head.status = status;
        try std.testing.expect(!hostProtocolMismatch(envelope, rejected, "/store"));
    }
    envelope.head.status = 200;
    const foreign = "{\"version\":\"" ++ foreign_wire ++ "\",\"type\":\"host_info\",\"store\":\"/store\"}";
    try std.testing.expect(hostProtocolMismatch(envelope, foreign, "/store"));
    try std.testing.expect(!hostProtocolMismatch(envelope, foreign, "/other"));
    try std.testing.expect(!hostProtocolMismatch(envelope, rejected, "/store"));
}

test "upgrade Host observation reads the current wire in one exchange and refuses bad envelopes" {
    // Another wire is observed through its own executable (`host status`), which an
    // in-process fixture cannot run: that path is covered by readForeignHostStatus tests
    // and by the previous-release upgrade gate. Here every case stops at the envelope.
    const released_wire = "22";
    const Mode = enum {
        current,
        strict,
        strict_503,
        body_mismatch,
        malformed_header,
        unavailable,
        activation_current,
        activation_200,
        activation_400,
        activation_bad_rejection,
        activation_500,
        activation_503,
        activation_malformed,
        activation_truncated,
        activation_bad_body,
        activation_body_version,
        activation_wrong_store,
        activation_oversize,
        wrong_wire,
        wrong_wire_refused,
        wrong_wire_pid_changed,
        wrong_wire_without_directory,
        wrong_wire_explicit_deadline,
    };
    const Phase = enum { temporary_store, store_permissions, store_path, lease, runtime, listener, peer_spawn, observation, verification, expired_current };
    const responseWire = struct {
        fn of(mode: Mode) []const u8 {
            return switch (mode) {
                .current, .unavailable, .activation_current => protocol.wire_version,
                else => released_wire,
            };
        }
    }.of;
    const Peer = struct {
        listener: *std.Io.net.Server,
        store: []const u8,
        mode: Mode,
        seen: usize = 0,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.serve() catch |err| {
                self.failure = err;
            };
        }

        fn serve(self: *@This()) !void {
            const io = std.testing.io;
            const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 2 * std.time.ns_per_s;
            if (!try waitRequest(.{ .io = io }, self.listener.socket.handle, std.posix.POLL.IN, until)) return error.TestPeerConnectionMissing;
            const connection = try self.listener.accept(io);
            defer connection.close(io);
            const fd = connection.socket.handle;
            var expected_buffer: [1024]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"{s}\",\"kind\":\"host_info\",\"store\":\"{s}\"}}", .{ protocol.wire_version, self.store });
            var request: [2048]u8 = undefined;
            var used: usize = 0;
            while (used < request.len) {
                if (used >= 4 and std.mem.endsWith(u8, request[0..used], "\r\n\r\n")) break;
                const n = try readRequest(.{ .io = io }, fd, request[used .. used + 1], until);
                if (n == 0) return error.TestPeerRequestTruncated;
                used += n;
            } else return error.TestPeerRequestTooLarge;
            try std.testing.expect(std.mem.startsWith(u8, request[0..used], "POST /v1/host-info HTTP/1.1\r\n"));
            var field_buffer: [128]u8 = undefined;
            const wire_field = try std.fmt.bufPrint(&field_buffer, "\r\nX-Rui-Wire-Version: {s}\r\n", .{protocol.wire_version});
            try std.testing.expect(std.mem.indexOf(u8, request[0..used], wire_field) != null);
            const length_field = try std.fmt.bufPrint(&field_buffer, "\r\nContent-Length: {d}\r\n", .{expected.len});
            try std.testing.expect(std.mem.indexOf(u8, request[0..used], length_field) != null);
            try std.testing.expect(std.mem.indexOf(u8, request[0..used], "X-Rui-Host-Instance") == null);
            var body_used: usize = 0;
            while (body_used < expected.len) {
                const n = try readRequest(.{ .io = io }, fd, request[body_used..expected.len], until);
                if (n == 0) return error.TestPeerRequestTruncated;
                body_used += n;
            }
            try std.testing.expectEqualStrings(expected, request[0..body_used]);
            self.seen += 1;
            const response_wire = responseWire(self.mode);
            const body_wire = if (self.mode == .body_mismatch or self.mode == .activation_body_version) protocol.wire_version else response_wire;
            var body_buffer: [1024]u8 = undefined;
            const host_body = try std.fmt.bufPrint(&body_buffer, "{{\"version\":\"{s}\",\"type\":\"host_info\",\"store\":\"{s}\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"17\",\"intake_capacity\":\"10\",\"descriptor_limit\":\"256\",\"started_at\":\"1792918800\",\"custody_occupied\":\"3\",\"paused\":true,\"capabilities\":{{\"bash\":true,\"providers\":{{\"codex\":\"endpoint\",\"openai\":\"unserved\",\"chatgpt\":\"unserved\"}}}}}}", .{ body_wire, if (self.mode == .activation_wrong_store) "/wrong-store" else self.store });
            var error_buffer: [256]u8 = undefined;
            const body: []const u8 = switch (self.mode) {
                .activation_400, .activation_bad_rejection, .activation_500, .activation_503, .strict_503 => try std.fmt.bufPrint(&error_buffer, "{{\"version\":\"{s}\",\"type\":\"invocation_error\",\"code\":\"{s}\"}}", .{ response_wire, if (self.mode == .activation_bad_rejection) "SomeOtherFailure" else "WrongWireVersion" }),
                .activation_bad_body => "{",
                else => host_body,
            };
            const status: []const u8 = switch (self.mode) {
                .activation_400, .activation_bad_rejection => "400 Bad Request",
                .activation_500 => "500 Failure",
                .unavailable, .activation_503, .strict_503 => "503 Unavailable",
                else => "200 OK",
            };
            const length = if (self.mode == .activation_oversize) protocol.max_response_bytes + 1 else body.len;
            const sent = if (self.mode == .activation_truncated) body[0 .. body.len - 1] else body;
            var response_buffer: [2048]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buffer, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: {s}\r\n{s}\r\n{s}", .{ status, length, response_wire, if (self.mode == .malformed_header or self.mode == .activation_malformed) "Content-Length: 0\r\n" else "", sent });
            try writeAllRequest(.{ .io = io }, fd, response, until);
        }
    };
    const Observed = union(enum) { current: HostControlObservation, incompatible: c_int };
    // The foreign reader a wrong-wire mode substitutes for the Host's own executable.
    const ForeignFake = struct {
        var mode: Mode = .current;
        var calls: usize = 0;
        var budget: i128 = 0;
        var cap: i128 = std.math.maxInt(i128);
        var until_seen: i128 = 0;
        var directory_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var directory_len: usize = 0;

        fn status(allocator: std.mem.Allocator, io: std.Io, executable: []const u8, directory: []const u8, until: i128) anyerror!StatusFacts {
            _ = allocator;
            _ = io;
            _ = executable;
            calls += 1;
            until_seen = until;
            @memcpy(directory_buffer[0..directory.len], directory);
            directory_len = directory.len;
            if (mode == .wrong_wire_refused) return error.ForeignHostStatusFailed;
            var facts = std.mem.zeroes(StatusFacts);
            facts.active_capacity = 17;
            facts.instance[15] = 15;
            return facts;
        }

        fn generation(pid: c_int) anyerror!u64 {
            if (mode == .wrong_wire_pid_changed) return std.math.maxInt(u64);
            return @import("host_identity.zig").generation(pid);
        }

        const reader: ForeignHostReader = .{ .status = status, .generation = generation };
    };
    const Run = struct {
        fn observe(io: std.Io, root: []const u8, mode: Mode) !Observed {
            switch (mode) {
                .wrong_wire,
                .wrong_wire_refused,
                .wrong_wire_pid_changed,
                .wrong_wire_without_directory,
                .wrong_wire_explicit_deadline,
                => {
                    var paths = try resolveClientPaths(io, root);
                    if (mode == .wrong_wire_without_directory) paths.host_directory.len = 0;
                    const explicit: ?i128 = if (mode == .wrong_wire_explicit_deadline) std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s / 2 else null;
                    ForeignFake.cap = explicit orelse std.math.maxInt(i128);
                    ForeignFake.mode = mode;
                    ForeignFake.calls = 0;
                    ForeignFake.budget = hostObservationDeadline(io, explicit);
                    return .{ .current = try observeHostForUpgradeAt(std.testing.allocator, io, &paths, ForeignFake.budget, ForeignFake.reader) };
                },
                .activation_current,
                .activation_200,
                .activation_400,
                .activation_bad_rejection,
                .activation_500,
                .activation_503,
                .activation_malformed,
                .activation_truncated,
                .activation_bad_body,
                .activation_body_version,
                .activation_wrong_store,
                .activation_oversize,
                => return switch (try observeHostProcessForUpgrade(io, root, null)) {
                    .ready => |observed| .{ .current = .{ .foreign = false, .facts = .{ .instance = observed.ready.instance, .store = observed.ready.store, .active_capacity = observed.ready.active_capacity, .settings_digest = observed.ready.settings_digest }, .pid = observed.pid } },
                    .incompatible => |pid| .{ .incompatible = pid },
                },
                .strict, .strict_503 => if (observeHostProcess(io, root, null)) |_| return error.TestUnexpectedResult else |err| return err,
                else => return .{ .current = try observeHostForUpgrade(std.testing.allocator, io, root, null) },
            }
        }

        fn execute(phase: *Phase, active_mode: *?Mode) !void {
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            phase.* = .store_permissions;
            try tmp.dir.setPermissions(io, .fromMode(0o700));
            var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            phase.* = .store_path;
            const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
            phase.* = .lease;
            var lease = try platform.StoreLease.acquire(io, root);
            defer lease.release();
            phase.* = .runtime;
            try lease.prepareForServing(false);
            const paths = lease.paths;
            for (std.enums.values(Mode)) |mode| {
                active_mode.* = mode;
                phase.* = .listener;
                var endpoint = try host_endpoint.claim(io, try .init(std.fs.path.dirname(paths.socket.slice()).?));
                defer endpoint.retire() catch @panic("unable to retire fixture endpoint");
                var listener = try endpoint.listen(.{});
                defer listener.deinit(io);
                var peer: Peer = .{ .listener = &listener, .store = paths.store_identity.slice(), .mode = mode };
                phase.* = .peer_spawn;
                const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});
                var joined = false;
                defer if (!joined) thread.join();
                phase.* = .observation;
                const result = observe(io, root, mode);
                thread.join();
                joined = true;
                phase.* = .verification;
                errdefer {
                    if (result) |reading| {
                        std.debug.print("upgrade observation failure phase={s} mode={s} result={s} peer.failure={any} seen={d}\n", .{ @tagName(phase.*), @tagName(mode), @tagName(reading), peer.failure, peer.seen });
                    } else |observation_error| {
                        std.debug.print("upgrade observation failure phase={s} mode={s} result.error={s} peer.failure={any} seen={d}\n", .{ @tagName(phase.*), @tagName(mode), @errorName(observation_error), peer.failure, peer.seen });
                    }
                }
                switch (mode) {
                    .strict, .strict_503 => try std.testing.expectError(error.WrongWireVersion, result),
                    .body_mismatch,
                    .unavailable,
                    .activation_bad_rejection,
                    .activation_500,
                    .activation_503,
                    .activation_bad_body,
                    .activation_body_version,
                    .activation_wrong_store,
                    => try std.testing.expectError(error.InvalidHostInfo, result),
                    .wrong_wire_without_directory => {
                        try std.testing.expectError(error.HostDirectoryUnavailable, result);
                        try std.testing.expectEqual(@as(usize, 0), ForeignFake.calls);
                    },
                    .wrong_wire_refused => {
                        try std.testing.expectError(error.ForeignHostStatusFailed, result);
                        try std.testing.expectEqual(@as(usize, 1), ForeignFake.calls);
                    },
                    .wrong_wire_pid_changed => {
                        try std.testing.expectError(error.HostPeerPidMismatch, result);
                        try std.testing.expectEqual(@as(usize, 1), ForeignFake.calls);
                    },
                    .wrong_wire, .wrong_wire_explicit_deadline => {
                        const reading = try result;
                        try std.testing.expect(reading.current.foreign);
                        try std.testing.expectEqual(std.c.getpid(), reading.current.pid);
                        try std.testing.expectEqual(@as(usize, 1), ForeignFake.calls);
                        // DIR, not the socket or Store identity, addresses the reader's `--store`.
                        try std.testing.expectEqualStrings(root, ForeignFake.directory_buffer[0..ForeignFake.directory_len]);
                        try std.testing.expectEqual(@as(usize, 17), reading.current.facts.active_capacity);
                        try std.testing.expectEqual(@as(u8, 15), reading.current.facts.instance[15]);
                        // The foreign read shares the discovery budget, which an explicit caller deadline bounds.
                        try std.testing.expectEqual(ForeignFake.budget, ForeignFake.until_seen);
                        try std.testing.expect(ForeignFake.until_seen <= ForeignFake.cap);
                    },
                    .malformed_header, .activation_malformed => try std.testing.expectError(error.InvalidResponse, result),
                    .activation_truncated => try std.testing.expectError(error.TruncatedResponse, result),
                    .activation_oversize => try std.testing.expectError(error.ResponseTooLarge, result),
                    .activation_200, .activation_400 => {
                        const reading = try result;
                        try std.testing.expect(reading == .incompatible);
                        try std.testing.expectEqual(std.c.getpid(), reading.incompatible);
                    },
                    .current, .activation_current => {
                        const reading = try result;
                        try std.testing.expect(reading == .current);
                        const observed = reading.current;
                        try std.testing.expect(!observed.foreign);
                        try std.testing.expectEqual(std.c.getpid(), observed.pid);
                        try std.testing.expect(observed.facts.store.eql(paths.store_identity.slice()));
                        try std.testing.expectEqual(@as(usize, 17), observed.facts.active_capacity);
                        try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &observed.facts.instance);
                    },
                }
                try std.testing.expectEqual(@as(?anyerror, null), peer.failure);
                try std.testing.expectEqual(@as(usize, 1), peer.seen);
            }
            active_mode.* = null;
            const expired = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - 1;
            phase.* = .expired_current;
            try std.testing.expectError(error.TransferInactive, observeHostForUpgrade(std.testing.allocator, io, root, expired));
        }
    };
    var phase: Phase = .temporary_store;
    var active_mode: ?Mode = null;
    Run.execute(&phase, &active_mode) catch |err| {
        std.debug.print("upgrade observation failure phase={s} mode={s} error={s}\n", .{ @tagName(phase), if (active_mode) |mode| @tagName(mode) else "none", @errorName(err) });
        return err;
    };
}

pub const HostLockState = enum { free, held, failure };

pub fn hostLockState(io: std.Io, store_path: []const u8) HostLockState {
    const selected = platform.resolveClientSelection(store_path);
    if (selected == .mysql) return .failure;
    const paths = selected.paths(io) catch |err| return if (err == error.FileNotFound) .free else .failure;
    return hostLockStateAt(io, &paths);
}

pub fn hostLockStateAt(io: std.Io, paths: *const platform.Paths) HostLockState {
    if (paths.kind == .mysql) return .failure;
    return lockState(io, paths);
}

fn lockState(io: std.Io, paths: *const platform.Paths) HostLockState {
    var store_dir = std.Io.Dir.cwd().openDir(io, paths.store_identity.slice(), .{}) catch |err| return if (err == error.FileNotFound) .free else .failure;
    defer store_dir.close(io);
    const fd = std.posix.openat(store_dir.handle, "host.lock", .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| return switch (err) {
        error.FileNotFound => .free,
        else => .failure,
    };
    const lock_file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer lock_file.close(io);
    const stat = lock_file.stat(io) catch return .failure;
    if (stat.kind != .file) return .failure;
    return switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB))) {
        .SUCCESS => .free,
        .AGAIN => .held,
        else => .failure,
    };
}

test "MySQL Host status bypasses filesystem locks and lock ownership stays unknown" {
    const RuntimeHint = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    const io = std.testing.io;
    const previous = if (std.c.getenv("RUI_RUNTIME_DIR")) |value|
        try std.testing.allocator.dupeSentinel(u8, std.mem.span(value), 0)
    else
        null;
    defer if (previous) |value| std.testing.allocator.free(value);
    defer {
        const result = if (previous) |value|
            RuntimeHint.setenv("RUI_RUNTIME_DIR", value, 1)
        else
            RuntimeHint.unsetenv("RUI_RUNTIME_DIR");
        if (result != 0) @panic("runtime hint restoration failed");
    }
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    var runtime_buffer: [@import("socket_fixture.zig").max_path_bytes:0]u8 = undefined;
    const runtime = try std.fmt.bufPrintSentinel(&runtime_buffer, "{s}/runtime", .{tmp.root[0..tmp.root_len]}, 0);
    var socket_buffer: [platform.max_launch_socket_path_bytes]u8 = undefined;
    const socket = try std.fmt.bufPrint(&socket_buffer, "{s}/rui.sock", .{runtime});
    var endpoint = try host_endpoint.claim(io, try .init(runtime));
    var claimed = true;
    defer if (claimed) endpoint.retire() catch {};
    var lease: platform.StoreLease = undefined;
    try lease.acquireMysql(io, runtime, socket);
    var leased = true;
    defer if (leased) lease.release();
    try std.testing.expectEqual(@as(c_int, 0), RuntimeHint.setenv("RUI_RUNTIME_DIR", runtime, 1));
    const store_id = "0123456789abcdef0123456789abcdef";
    try std.testing.expectEqual(HostLockState.failure, hostLockState(io, store_id));
    try std.testing.expectEqual(std.meta.Tag(protocol_reply.HostStatus).owned_unavailable, std.meta.activeTag(hostStatusUntil(io, store_id, null)));
    try endpoint.retire();
    claimed = false;
    lease.release();
    leased = false;
    try tmp.dir.deleteTree(io, "runtime");
    try std.testing.expectEqual(HostLockState.failure, hostLockState(io, store_id));
}

test "SQLite Host lock evidence preserves free held and failed probes" {
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const root = tmp.root[0..tmp.root_len];
    try std.testing.expectEqual(HostLockState.free, hostLockState(io, root));
    try std.testing.expect(hostStatusUntil(io, root, null) == .unavailable);
    var lease = try platform.StoreLease.acquire(io, root);
    var leased = true;
    defer if (leased) lease.release();
    try std.testing.expectEqual(HostLockState.held, hostLockState(io, root));
    lease.release();
    leased = false;
    try std.testing.expectEqual(HostLockState.free, hostLockState(io, root));
    try tmp.dir.deleteFile(io, "host.lock");
    try tmp.dir.createDir(io, "host.lock", .fromMode(0o700));
    try std.testing.expectEqual(HostLockState.failure, hostLockState(io, root));
    try std.testing.expect(hostStatusUntil(io, root, null) == .access_failure);
}

fn readHostInfo(io: std.Io, paths: *const platform.Paths, deadline: ?i128) protocol_reply.HostStatus {
    var body: protocol.RequestBuffer = .{};
    const unknown = paths.kind == .mysql and !@import("store_id.zig").valid(paths.store_identity.slice());
    body.appendShape(protocol.host_info_request, .{if (unknown) "" else paths.store_identity.slice()}) catch unreachable;
    var reply_buffer: ReplyBuffer = .{};
    const until = hostObservationDeadline(io, deadline);
    const reply = sendSource(.{ .io = io }, paths, "/v1/host-info", .{}, body.len, null, body.slice(), null, null, &reply_buffer, until).get() catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_failure,
        error.WrongWireVersion, error.InvalidResponse, error.ResponseHeaderTooLarge, error.ResponseTooLarge, error.InvalidCharacter, error.Overflow => .incompatible,
        else => .owned_unavailable,
    };
    if (reply.status == 503) return if (protocol_reply.validHostUnavailable(reply.body)) .owned_unavailable else .incompatible;
    if (reply.status != 200) return .incompatible;
    if (paths.kind == .mysql and !@import("store_id.zig").valid(paths.store_identity.slice())) {
        // Empty-Store host-info already exists for MySQL discovery. Learn only
        // a shaped identity and validate the entire existing response grammar.
        var memory: [protocol.max_host_info_response_bytes * 2]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&memory);
        const hint = std.json.parseFromSliceLeaky(struct { store: []const u8 }, fixed.allocator(), reply.body, .{ .ignore_unknown_fields = true }) catch return .incompatible;
        if (!@import("store_id.zig").valid(hint.store)) return .incompatible;
        return protocol_reply.parseHostInfo(reply.body, hint.store) catch .incompatible;
    }
    return protocol_reply.parseHostInfo(reply.body, paths.store_identity.slice()) catch .incompatible;
}

/// Resolve an opaque identity through the existing private socket, never a login.
pub fn resolveMysqlIdentity(io: std.Io, paths: *platform.Paths) !void {
    switch (hostStatusAt(io, paths, null)) {
        .ready => |ready| paths.store_identity = ready.store,
        .unavailable, .owned_unavailable => return error.FileNotFound,
        .incompatible => return error.WrongWireVersion,
        .access_failure => return error.AccessDenied,
    }
}

pub fn captureSessionStop(io: std.Io, input: SessionStopInput, target: CaptureTarget) !CapturedRecord {
    const paths = try resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    return writeSessionStopCapture(io, &paths, input, location);
}

pub fn captureSessionArchive(io: std.Io, input: SessionArchiveInput, target: CaptureTarget) !CapturedRecord {
    const paths = try resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    return runCapture(io, &paths, &location, input.session, .session_archive, null, Capture.writeRequest, .{ protocol.session_archive_request.all, .{ paths.store_identity.slice(), location.key, input.session, input.archived } });
}

pub fn captureSessionPin(io: std.Io, input: SessionPinInput, target: CaptureTarget) !CapturedRecord {
    const paths = try resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    return runCapture(io, &paths, &location, input.session, .session_pin, null, Capture.writeRequest, .{ protocol.session_pin_request.all, .{ paths.store_identity.slice(), location.key, input.session, input.pinned } });
}

pub fn captureModelInterruption(io: std.Io, input: ModelInterruptionInput, target: CaptureTarget) !CapturedRecord {
    const paths = try resolveClientPaths(io, input.store);
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
    since: ?protocol_reply.SessionToken,
    reply_buffer: *ObservationBuffer,
) !protocol_reply.ObservationReply {
    return (Requests{ .io = io }).observeCommand(store_path, key, since, reply_buffer);
}

pub const WaitDisposition = @import("request_wait.zig").Disposition;

pub const WaitResult = union(enum) {
    observed: struct {
        disposition: WaitDisposition,
        observation: ?protocol_reply.CommandObservation,
    },
    failure: protocol_reply.ReadFailure,
};

pub fn waitCommand(
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    timeout_seconds: u32,
    cancellation: *const Cancellation,
) !WaitResult {
    const policy = @import("request_wait.zig");
    if (timeout_seconds == 0 or timeout_seconds > policy.max_timeout_seconds) return error.InvalidArguments;
    if (cancellation.stopped.load(.acquire)) return .{ .observed = .{ .disposition = .later, .observation = null } };
    const paths = try resolveClientPaths(io, store_path);
    return waitCommandAt(io, &paths, key, timeout_seconds, cancellation);
}

pub fn waitCommandAt(io: std.Io, paths: *const platform.Paths, key: []const u8, timeout_seconds: u32, cancellation: *const Cancellation) !WaitResult {
    const policy = @import("request_wait.zig");
    if (timeout_seconds == 0 or timeout_seconds > policy.max_timeout_seconds) return error.InvalidArguments;
    const requests: Requests = .{ .io = io, .cancellation = cancellation };
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + @as(i128, timeout_seconds) * std.time.ns_per_s;
    var buffer: ObservationBuffer = .{};
    var latest: ?protocol_reply.CommandObservation = null;
    var since: ?protocol_reply.SessionToken = null;
    var delay = policy.first_poll_ms;
    while (true) {
        if (cancellation.stopped.load(.acquire) or std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= until) {
            return .{ .observed = .{ .disposition = .later, .observation = latest } };
        }
        const reply = requests.observeCommandAt(paths, key, since, &buffer, until) catch |err| {
            if (err == error.Cancelled or
                ((err == error.TransferInactive or err == error.ResponseInactive) and
                    std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= until))
            {
                return .{ .observed = .{ .disposition = .later, .observation = latest } };
            }
            return err;
        };
        switch (reply) {
            .observation => |full| {
                latest = full.facts;
                since = full.since;
                if (policy.disposition(full.facts)) |disposition| {
                    return .{ .observed = .{ .disposition = disposition, .observation = latest } };
                }
            },
            .not_modified => |token| since = token,
            .failure => |failure| {
                if (failure.status != 503 or !protocol_reply.validHostUnavailable(buffer.slice()))
                    return .{ .failure = failure };
            },
        }
        try pauseWait(requests, @min(until, std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + @as(i128, delay) * std.time.ns_per_ms));
        delay = policy.nextPoll(delay);
    }
}

fn pauseWait(requests: Requests, until: i128) !void {
    while (true) {
        requests.check() catch return;
        const left = until - std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds;
        if (left <= 0) return;
        const milliseconds: c_int = @intCast(@min(100, @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        var none: [0]std.c.pollfd = .{};
        const result = std.c.poll(&none, 0, milliseconds);
        switch (std.posix.errno(result)) {
            .SUCCESS, .INTR => {},
            else => return error.PollFailed,
        }
    }
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
    try requests.check();
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    const paths = try resolveClientPaths(requests.io, store_path);
    return readResultAt(requests, &paths, key, sink, reply_buffer);
}

pub fn readResultAt(requests: Requests, paths: *const platform.Paths, key: []const u8, sink: anytype, reply_buffer: *ReplyBuffer) !protocol_reply.ResultReadReply {
    const io = requests.io;
    reply_buffer.len = 0;
    try requests.check();
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    var body: protocol.RequestBuffer = .{};
    try body.appendShape(protocol.read_result_request, .{ paths.store_identity.slice(), key });
    const fd = try openRead(requests, paths, "/v1/read-result", body.slice());
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

pub fn listSessionsFiltered(
    io: std.Io,
    store_path: []const u8,
    workspace: ?[]const u8,
    archive: protocol.SessionArchiveFilter,
    cursor: protocol_reply.SessionListCursor,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !protocol_reply.ReportReply {
    return (Requests{ .io = io }).listSessionsFiltered(store_path, workspace, archive, cursor, destination, reply_buffer);
}

fn appendListSessions(body: anytype, store: []const u8, workspace: ?[]const u8, archive: protocol.SessionArchiveFilter, cursor: protocol_reply.SessionListCursor) !void {
    try body.appendShape(protocol.list_sessions_request.head, .{ store, workspace });
    try body.appendShape(protocol.list_sessions_request.archive, .{archive});
    try body.appendShape(protocol.list_sessions_request.cursor, .{ cursor.after, cursor.ceiling });
    var token: [protocol.SinceToken.max_bytes]u8 = undefined;
    if (cursor.since) |since| {
        try body.appendShape(protocol.list_sessions_request.since, .{since.format(&token)});
        if (cursor.changed) |*changed| {
            try body.appendShape(protocol.list_sessions_request.through, .{changed.through});
            try body.appendShape(protocol.list_sessions_request.after_reference, .{@as([]const u8, &changed.after_reference)});
        }
    }
    try body.appendShape(protocol.list_sessions_request.tail, .{});
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
    const paths = try resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try body.appendShape(shape, .{ paths.store_identity.slice(), session, action_id });
    const fd = try openRead(requests, &paths, route, body.slice());
    defer closeSocket(io, fd);
    return readResultResponseSink(requests, fd, destination, reply_buffer);
}

pub const Binding = struct {
    store: ?[]const u8 = null,
    session: ?[]const u8 = null,
    key: ?[]const u8 = null,
    kind: ?protocol.CommandKind = null,
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
    generated: []const u8,
    explicit: struct { record: []const u8, key: []const u8 },
    reserved: Location,

    pub const Location = struct { record: []const u8, key: []const u8, replay: Replay };

    pub fn resolve(self: CaptureTarget, io: std.Io, path: []u8, key: *[36]u8) !Location {
        return switch (self) {
            .explicit => |value| .{ .record = value.record, .key = value.key, .replay = .{ .explicit = .{ .record = value.record } } },
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

pub const Replay = union(enum) {
    generated,
    explicit: struct {
        record: []const u8,
        host_directory: @import("host_settings.zig").OsBytes(protocol.max_store_bytes) = .{},
    },
};

// Local routing is deliberately outside the immutable wire request. Both
// generated and explicit captures publish this private companion first.
const CaptureRouting = struct {
    const Path = @import("host_settings.zig").OsBytes(protocol.max_store_bytes);
    const Runtime = @import("host_settings.zig").OsBytes(@import("host_settings.zig").max_runtime_dir_bytes);
    const format = 1;
    host_directory: Path = .{},
    runtime_hint: Runtime = .{},

    fn fromPaths(paths: *const platform.Paths) !CaptureRouting {
        var result: CaptureRouting = .{ .host_directory = paths.host_directory };
        if (result.host_directory.len == 0) {
            if (paths.runtimeHint()) |runtime| try result.runtime_hint.set(runtime);
        }
        return result;
    }

    fn resolve(self: *const CaptureRouting, io: std.Io, store_identity: []const u8) !platform.Paths {
        if (self.host_directory.len != 0) return resolveClientPaths(io, self.host_directory.slice());
        if (self.runtime_hint.len != 0) return platform.mysqlClientPaths(io, store_identity, self.runtime_hint.slice());
        return error.InvalidRequestRecord;
    }

    fn matchesPlacement(self: *const CaptureRouting, paths: *const platform.Paths) bool {
        if (self.host_directory.len != 0) return std.mem.eql(u8, self.host_directory.slice(), paths.host_directory.slice());
        return paths.kind == .mysql and paths.host_directory.len == 0 and std.mem.eql(u8, self.runtime_hint.slice(), paths.runtimeHint().?);
    }

    fn name(record_name: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}.routing", .{record_name});
    }

    fn read(io: std.Io, record_path: []const u8) !CaptureRouting {
        var parent = std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(record_path) orelse ".", .{ .iterate = true }) catch return error.InvalidRequestRecord;
        defer parent.close(io);
        var name_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const route_name = try name(std.fs.path.basename(record_path), &name_buffer);
        var bytes: [6 * (Path.max_bytes + Runtime.max_bytes) + 128]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const text = @import("private_file.zig").readAt(io, parent, route_name, &bytes) catch return error.InvalidRequestRecord;
        @import("private_file.zig").validateDirectory(io, parent) catch return error.InvalidRequestRecord;
        const Fields = struct { format: u8, host_directory: []const u8, runtime_hint: []const u8 };
        var storage: [2048]u8 = undefined;
        defer std.crypto.secureZero(u8, &storage);
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const value = std.json.parseFromSliceLeaky(Fields, fixed.allocator(), text, .{}) catch return error.InvalidRequestRecord;
        if (value.format != format or (value.host_directory.len == 0) == (value.runtime_hint.len == 0)) return error.InvalidRequestRecord;
        if (!std.fs.path.isAbsolute(if (value.host_directory.len != 0) value.host_directory else value.runtime_hint)) return error.InvalidRequestRecord;
        var result: CaptureRouting = .{};
        result.host_directory.set(value.host_directory) catch return error.InvalidRequestRecord;
        result.runtime_hint.set(value.runtime_hint) catch return error.InvalidRequestRecord;
        return result;
    }
};

pub const CapturedRecord = struct {
    file: std.Io.File,
    length: u64,
    saved: protocol_reply.MutationIdentity,
    target: protocol_reply.MutationTarget,
    replay: Replay,
    paths: ?platform.Paths = null,
    routing: CaptureRouting,

    pub fn resolvePaths(self: *const CapturedRecord, io: std.Io) !platform.Paths {
        return resolveCapturedPaths(io, self.saved.store.slice(), self.paths, self.routing);
    }

    pub fn selector(self: *const CapturedRecord) []const u8 {
        if (self.paths) |*paths| return paths.selector();
        if (self.routing.host_directory.len != 0) return self.routing.host_directory.slice();
        return self.saved.store.slice();
    }

    pub fn identity(self: *const CapturedRecord) *const protocol_reply.MutationIdentity {
        return &self.saved;
    }

    pub fn close(self: *CapturedRecord, io: std.Io) void {
        self.file.close(io);
        self.* = undefined;
    }
};

// Both retransmission and bounded read-only inspection use this route owner.
// Identity is a binding assertion, never a substitute for a present selector.
fn resolveCapturedPaths(io: std.Io, store_identity: []const u8, retained: ?platform.Paths, routing: CaptureRouting) !platform.Paths {
    const paths = retained orelse try routing.resolve(io, store_identity);
    if (!paths.store_identity.eql(store_identity)) return error.RequestBindingMismatch;
    return paths;
}

pub fn inspectCapturedRequest(io: std.Io, directory: []const u8, handle: []const u8) !struct { identity: protocol_reply.MutationIdentity, paths: platform.Paths } {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(directory, handle, &path_buffer);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const identity = try readCapturedIdentity(io, &file, handle);
    const routing = try CaptureRouting.read(io, path);
    return .{ .identity = identity, .paths = try resolveCapturedPaths(io, identity.store.slice(), null, routing) };
}

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

pub const SavedRecord = union(enum) {
    generated: struct { directory: []const u8, handle: []const u8 },
    explicit: struct { store: []const u8, record: []const u8, kind: protocol.CommandKind },
};

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
            expected.kind = explicit.kind;
            break :blk explicit.record;
        },
    };
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    const binding = try readCapturedBinding(io, &file);
    const routing = try CaptureRouting.read(io, path);
    if (saved == .explicit) {
        const supplied = saved.explicit.store;
        paths = if (routing.runtime_hint.len != 0 and @import("store_id.zig").valid(supplied))
            try platform.mysqlClientPaths(io, supplied, routing.runtime_hint.slice())
        else
            try resolveClientPaths(io, supplied);
        expected.store = paths.store_identity.slice();
    }
    if (!expected.matches(&binding.saved, binding.target)) return switch (saved) {
        .generated => error.InvalidRequestRecord,
        .explicit => error.RequestBindingMismatch,
    };
    const replay: Replay = switch (saved) {
        .generated => .generated,
        .explicit => |explicit| .{ .explicit = .{ .record = explicit.record, .host_directory = routing.host_directory } },
    };
    return .{ .file = file, .length = try file.length(io), .saved = binding.saved, .target = binding.target, .replay = replay, .paths = if (saved == .explicit and routing.matchesPlacement(&paths)) paths else null, .routing = routing };
}

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

// Validate and hash image bytes while parsing a saved request, without retaining
// the base64 text or reopening the caller's source file.
const CapturedImage = struct {
    bytes: u64,
    digest: [32]u8,
    media: @import("input_media.zig").Metadata,

    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !CapturedImage {
        const media = @import("input_media.zig");
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        var scanner = media.Scanner.init((media.Limits{}).max_bytes, null, .{}) catch return error.InvalidCharacter;
        var hash = protocol.contentHasher();
        var total: u64 = 0;
        var group: [4]u8 = undefined;
        var used: usize = 0;
        var ended = false;
        while (true) {
            const token = try source.next();
            const chars: []const u8 = switch (token) {
                .string, .partial_string => |bytes| bytes,
                .partial_string_escaped_1 => |*bytes| bytes,
                .partial_string_escaped_2 => |*bytes| bytes,
                .partial_string_escaped_3 => |*bytes| bytes,
                .partial_string_escaped_4 => |*bytes| bytes,
                else => return error.UnexpectedToken,
            };
            for (chars) |char| {
                if (ended) return error.InvalidCharacter;
                group[used] = char;
                used += 1;
                if (used == 4) {
                    const count = std.base64.standard.Decoder.calcSizeForSlice(&group) catch return error.InvalidCharacter;
                    var raw: [3]u8 = undefined;
                    std.base64.standard.Decoder.decode(raw[0..count], &group) catch return error.InvalidCharacter;
                    if (count < 3) ended = true;
                    if (count > (media.Limits{}).max_bytes - total) return error.ValueTooLong;
                    total += count;
                    var allowance = count;
                    _ = scanner.advance(raw[0..count], &allowance) catch return error.InvalidCharacter;
                    hash.update(raw[0..count]);
                    used = 0;
                }
            }
            if (token == .string) break;
        }
        if (used != 0) return error.InvalidCharacter;
        scanner.length = total;
        return .{ .bytes = total, .digest = hash.finalResult(), .media = scanner.finish() catch return error.InvalidCharacter };
    }
};

const CapturedParts = struct {
    reference: @import("input_parts.zig").Reference,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !CapturedParts {
        const parts = @import("input_parts.zig");
        const Fields = struct {
            type: protocol_reply.JsonString(8),
            text: ?CapturedText = null,
            mime: ?protocol_reply.JsonString(16) = null,
            data: ?CapturedImage = null,
        };
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var encoder: parts.Manifest.Encoder = .{};
        var image_bytes: u64 = 0;
        while (try source.peekNextTokenType() != .array_end) {
            const fields = try std.json.innerParse(Fields, allocator, source, options);
            const identity: parts.Identity = if (fields.type.eql("text")) blk: {
                if (fields.mime != null or fields.data != null) return error.UnexpectedToken;
                const text = fields.text orelse return error.UnexpectedToken;
                break :blk .{ .length = text.bytes, .digest = text.digest, .kind = .text };
            } else if (fields.type.eql("image")) blk: {
                if (fields.text != null) return error.UnexpectedToken;
                const image = fields.data orelse return error.UnexpectedToken;
                image_bytes = std.math.add(u64, image_bytes, image.bytes) catch return error.ValueTooLong;
                if (image_bytes > (@import("input_media.zig").Limits{}).max_bytes) return error.ValueTooLong;
                const mime = fields.mime orelse return error.UnexpectedToken;
                if (!mime.eql(image.media.format.mime())) return error.UnexpectedToken;
                break :blk .{ .length = image.bytes, .digest = image.digest, .kind = .{ .image = .{ .media = image.media } } };
            } else return error.UnexpectedToken;
            var encoded: [parts.Manifest.max_entry_bytes]u8 = undefined;
            _ = encoder.append(&identity, &encoded) catch return error.ValueTooLong;
        }
        _ = try source.next();
        return .{ .reference = encoder.finish() catch return error.UnexpectedToken };
    }
};

const CapturedConfiguration = struct {
    pub fn jsonParse(_: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !CapturedConfiguration {
        if (try source.peekNextTokenType() != .object_begin) return error.UnexpectedToken;
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
        preset: ?protocol_reply.JsonString(protocol.max_preset_name_bytes) = null,
        require_model: ?bool = null,
        archived: bool = true,
        pinned: ?bool = null,
        reload_skills: ?bool = null,
        sender: ?protocol_reply.JsonAddress = null,
        sender_handle: ?protocol_reply.JsonString(32) = null,
        text: ?struct { state: protocol_reply.JsonString(8), value: CapturedText } = null,
        parts: ?CapturedParts = null,
        action: ?protocol_reply.JsonString(20) = null,
        decision: ?protocol_reply.JsonString(16) = null,
        target: ?struct { session: protocol_reply.JsonString(protocol.max_session_bytes), turn: protocol_reply.JsonString(20), operation: protocol_reply.JsonString(20) } = null,
    };
    var input: [protocol.content_window_bytes]u8 = undefined;
    var file_reader = file.reader(io, &input);
    var storage: [2048]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var reader = std.json.Reader.init(fixed.allocator(), &file_reader.interface);
    defer reader.deinit();
    const fields = std.json.parseFromTokenSourceLeaky(Fields, fixed.allocator(), &reader, .{ .allocate = .alloc_if_needed, .max_value_len = protocol.max_store_bytes }) catch return file_reader.err orelse error.InvalidRequestRecord;
    if (!fields.version.eql(protocol.wire_version)) return error.SavedRequestWireVersionMismatch;
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
            if (fields.sender) |sender| _ = sender.address() catch return error.InvalidRequestRecord;
            if (fields.configuration != null and saved.session.len != 0) return error.InvalidRequestRecord;
            if (fields.text) |text| {
                if (fields.parts != null or !text.state.eql("value")) return error.InvalidRequestRecord;
                break :blk .{ .message = .{ .bytes = text.value.bytes, .digest = text.value.digest, .creates_session = fields.configuration != null } };
            }
            const reference = (fields.parts orelse return error.InvalidRequestRecord).reference;
            if (reference != .parts) return error.InvalidRequestRecord;
            break :blk .{ .message = .{ .bytes = reference.parts.length, .digest = reference.parts.digest, .form = .parts, .creates_session = fields.configuration != null } };
        },
        .session_stop => .session_stop,
        .session_archive => .{ .session_archive = .{ .archived = fields.archived } },
        .session_pin => .{ .session_pin = .{ .pinned = fields.pinned orelse return error.InvalidRequestRecord } },
        .model_interruption => .{ .model_interruption = .{
            .turn = protocol_reply.decimalId(fields.target.?.turn, true) catch return error.InvalidRequestRecord,
            .operation = protocol_reply.decimalId(fields.target.?.operation, true) catch return error.InvalidRequestRecord,
        } },
        .action_background => .{ .action_background = protocol_reply.decimalId(fields.action orelse return error.InvalidRequestRecord, false) catch return error.InvalidRequestRecord },
        .action_stop => .{ .action_stop = protocol_reply.decimalId(fields.action orelse return error.InvalidRequestRecord, false) catch return error.InvalidRequestRecord },
        .permission_decision => .{ .permission_decision = .{
            .action = protocol_reply.decimalId(fields.action orelse return error.InvalidRequestRecord, true) catch return error.InvalidRequestRecord,
            .decision = std.meta.stringToEnum(protocol.PermissionDecision, (fields.decision orelse return error.InvalidRequestRecord).slice()) orelse return error.InvalidRequestRecord,
        } },
    };
    if ((kind != .configure and kind != .message and fields.configuration != null) or
        (fields.require_model != null and kind != .configure and kind != .message) or
        (kind != .configure and (fields.reload_skills != null or fields.preset != null)) or
        (kind != .session_pin and fields.pinned != null) or
        (kind != .message and (fields.text != null or fields.parts != null or fields.sender != null or fields.sender_handle != null)) or (kind != .model_interruption and fields.target != null) or
        (kind != .permission_decision and fields.decision != null) or
        (kind != .permission_decision and kind != .action_background and kind != .action_stop and fields.action != null)) return error.InvalidRequestRecord;
    return .{ .saved = saved, .target = target };
}

fn readCapturedIdentity(io: std.Io, file: *std.Io.File, handle: []const u8) !protocol_reply.MutationIdentity {
    const header_bytes = 6 * (protocol.max_store_bytes + protocol.max_key_bytes + protocol.max_session_bytes) + 256;
    var buffer: [header_bytes]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    const prefix = buffer[0..count];
    const kind_marker = std.mem.indexOf(u8, prefix, ",\"configuration\"") orelse
        std.mem.indexOf(u8, prefix, ",\"text\"") orelse
        std.mem.indexOf(u8, prefix, ",\"decision\"") orelse
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

const ErrorOf = @import("error_set.zig").Of;

pub const CaptureError = ErrorOf(resolveClientPaths) || ErrorOf(writeConfigureCapture) || ErrorOf(writeMessageCapture);

pub fn captureConfigure(io: std.Io, input: ConfigureInput, target: CaptureTarget) Stepped(CaptureError, CapturedRecord) {
    return stepCapture(io, input, target, writeConfigureCapture);
}

fn stepCapture(io: std.Io, input: anytype, target: CaptureTarget, comptime write: anytype) Stepped(CaptureError, CapturedRecord) {
    const paths = resolveClientPaths(io, input.store) catch |err| return .fail(.store, err);
    var input_failure: ?Step = null;
    var record = write(io, &paths, input, target, &input_failure) catch |err| return .fail(input_failure orelse .capture, err);
    record.paths = paths;
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
    return runCapture(io, paths, &location, session, .configure, input_failure, writeConfigureRequest, .{ paths.store_identity.slice(), location.key, session, input });
}

fn writeConfigureRequest(capture: *Capture, store: []const u8, key: []const u8, session: []const u8, input: ConfigureInput) !void {
    try capture.writeRequest(protocol.configure_request.head, .{ store, key, session });
    try capture.writeConfiguration(input);
    if (input.reload_skills) try capture.writeRequest(protocol.configure_request.reload_skills, .{});
    if (input.require_model) try capture.writeRequest(protocol.configure_request.require_model, .{});
    if (input.preset.present) try capture.writeRequest(protocol.configure_request.preset, .{input.preset.value});
    try capture.writeRequest(protocol.configure_request.tail, .{});
}

fn runCapture(
    io: std.Io,
    paths: *const platform.Paths,
    location: *const CaptureTarget.Location,
    session: []const u8,
    kind: protocol.CommandKind,
    input_failure: ?*?Step,
    comptime write: anytype,
    args: anytype,
) !CapturedRecord {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    capture.input_failure = input_failure;
    errdefer capture.abort();
    try @call(.auto, write, .{&capture} ++ args);
    const routing = try capture.writeRouting(paths);
    var record = try finishCapture(io, &capture, location, routing, paths.store_identity.slice(), session, kind);
    record.paths = paths.*;
    if (record.replay == .explicit) record.replay.explicit.host_directory = paths.host_directory;
    return record;
}

pub fn validatePeer(store: []const u8, session: []const u8, handle: ?[]const u8) !void {
    if (handle) |bytes| if (bytes.len > protocol.max_sender_handle_bytes) return error.InvalidSenderHandle;
    var address: protocol.Address = .{};
    try address.store.set(store);
    try address.session.set(session);
    try address.validate();
}

pub fn captureMessage(io: std.Io, input: MessageInput, target: CaptureTarget) Stepped(CaptureError, CapturedRecord) {
    return stepCapture(io, input, target, writeMessageCapture);
}

fn writeMessageCapture(io: std.Io, paths: *const platform.Paths, input: MessageInput, target: CaptureTarget, input_failure: *?Step) !CapturedRecord {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    if (input.sender) |sender|
        try validatePeer(sender.store orelse return error.InvalidRuiAddress, sender.session, input.sender_handle)
    else if (input.sender_handle) |handle| if (handle.len > protocol.max_sender_handle_bytes) return error.InvalidSenderHandle;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    if (input.configuration != null) {
        if (input.session.len != 0 or location.key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(location.key)) return error.InvalidSession;
    } else try protocol_reply.validateIdentityInputs(location.key, input.session);
    return runCapture(io, paths, &location, input.session, .message, input_failure, writeMessageRequest, .{ paths.store_identity.slice(), location.key, input });
}

/// A creating Message's Configure condition and an addressed Message's own condition both name the same wire field.
fn messageRequireModel(input: MessageInput) bool {
    return input.require_model or if (input.configuration) |configuration| configuration.require_model else false;
}

fn writeMessageRequest(capture: *Capture, store: []const u8, key: []const u8, input: MessageInput) !void {
    try capture.writeRequest(protocol.message_request.head, .{ store, key, input.session });
    if (input.sender) |sender| {
        try capture.writeRequest(protocol.message_request.sender, .{ sender.store.?, sender.session });
    } else try capture.writeRequest(protocol.message_request.no_sender, .{});
    try capture.writeRequest(protocol.message_request.sender_handle, .{input.sender_handle});
    if (input.configuration) |configuration| {
        try capture.writeRequest(protocol.message_request.configuration, .{});
        try capture.writeConfiguration(configuration);
    }
    if (input.operands.len != 0) {
        try capture.writeMessageOperands(input.operands, input.operand_stdin);
        if (messageRequireModel(input))
            try capture.writeRequest(protocol.message_request.require_model, .{});
        try capture.writeRequest(protocol.message_request.tail, .{});
        return;
    }
    try capture.writeRequest(protocol.message_request.text, .{});
    if (input.text) |value| {
        if (value.len > protocol.max_sqlite_content_bytes) return error.ContentTooLarge;
        try capture.writeJsonString(value);
    } else if (std.mem.eql(u8, input.text_path, "-")) {
        try capture.writeJsonFileBounded(input.text_path, protocol.max_sqlite_content_bytes, true);
    } else try capture.writeJsonFile(input.text_path);
    try capture.writeRequest(protocol.message_request.text_tail, .{});
    if (messageRequireModel(input))
        try capture.writeRequest(protocol.message_request.require_model, .{});
    try capture.writeRequest(protocol.message_request.tail, .{});
}

fn writeSessionStopCapture(io: std.Io, paths: *const platform.Paths, input: SessionStopInput, location: CaptureTarget.Location) !CapturedRecord {
    return runCapture(io, paths, &location, input.session, .session_stop, null, Capture.writeRequest, .{ protocol.session_stop_request, .{ paths.store_identity.slice(), location.key, input.session } });
}

fn writeModelInterruptionCapture(
    io: std.Io,
    paths: *const platform.Paths,
    input: ModelInterruptionInput,
    location: CaptureTarget.Location,
) !CapturedRecord {
    return runCapture(io, paths, &location, input.session, .model_interruption, null, Capture.writeRequest, .{ protocol.model_interruption_request, .{ paths.store_identity.slice(), location.key, input.session, input.turn_id, input.operation_id } });
}

pub fn capturePermissionDecision(io: std.Io, input: PermissionDecisionInput, target: CaptureTarget) !CapturedRecord {
    const paths = try resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    if (input.action_id == 0) return error.InvalidTarget;
    return runCapture(io, &paths, &location, input.session, .permission_decision, null, Capture.writePermissionDecision, .{ paths.store_identity.slice(), location.key, input });
}

pub fn captureActionBackground(io: std.Io, input: ActionBackgroundInput, target: CaptureTarget) !CapturedRecord {
    const paths = try resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    if (input.action_id == 0 or input.action_id > std.math.maxInt(i64)) return error.InvalidTarget;
    return runCapture(io, &paths, &location, input.session, .action_background, null, Capture.writeRequest, .{ protocol.action_background_request, .{ paths.store_identity.slice(), location.key, input.session, input.action_id } });
}

pub fn captureActionStop(io: std.Io, input: ActionStopInput, target: CaptureTarget) !CapturedRecord {
    const paths = try resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try protocol_reply.validateIdentityInputs(location.key, input.session);
    if (input.action_id == 0 or input.action_id > std.math.maxInt(i64)) return error.InvalidTarget;
    return runCapture(io, &paths, &location, input.session, .action_stop, null, Capture.writeRequest, .{ protocol.action_stop_request, .{ paths.store_identity.slice(), location.key, input.session, input.action_id } });
}

fn finishCapture(io: std.Io, capture: *Capture, location: *const CaptureTarget.Location, routing: CaptureRouting, store: []const u8, session: []const u8, kind: protocol.CommandKind) !CapturedRecord {
    var file = try capture.parent.openFile(io, capture.temporary_name.slice(), .{});
    errdefer file.close(io);
    try capture.commit();
    const length = try file.length(io);
    const binding = try readCapturedBinding(io, &file);
    if (!(Binding{ .store = store, .key = location.key, .session = session, .kind = kind }).matches(&binding.saved, binding.target)) return error.InvalidRequestRecord;
    return .{ .file = file, .length = length, .saved = binding.saved, .target = binding.target, .replay = location.replay, .routing = routing };
}

const Capture = struct {
    io: std.Io,
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
    routing_published: bool = false,

    fn open(io: std.Io, record_path: []const u8, buffer: []u8) !Capture {
        const parent_path = std.fs.path.dirname(record_path) orelse ".";
        const final_name = std.fs.path.basename(record_path);
        if (final_name.len == 0 or final_name.len + ".routing.tmp".len + 1 > std.Io.Dir.max_name_bytes) return error.InvalidRecordPath;
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
            @import("stderr.zig").diagnostic("rui: retained caller capture after cleanup failure: {s}\n", .{@errorName(err)});
        };
        if (!self.published and self.routing_published) {
            var name_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
            const name = CaptureRouting.name(self.final_name.slice(), &name_buffer) catch unreachable;
            self.parent.deleteFile(self.io, name) catch |err| {
                @import("stderr.zig").diagnostic("rui: retained caller routing after cleanup failure: {s}\n", .{@errorName(err)});
            };
        }
        self.lock_file.close(self.io);
        self.parent.close(self.io);
        self.active = false;
    }

    fn writeRouting(self: *Capture, paths: *const platform.Paths) !CaptureRouting {
        const route = try CaptureRouting.fromPaths(paths);
        var name_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const name = try CaptureRouting.name(self.final_name.slice(), &name_buffer);
        var temporary_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        const temporary = try std.fmt.bufPrint(&temporary_buffer, ".{s}.routing.tmp", .{self.final_name.slice()});
        // The existing request lock is held and its final request is absent.
        // Only an orphan from an interrupted capture can be replaced here.
        for ([_][]const u8{ temporary, name }) |orphan| self.parent.deleteFile(self.io, orphan) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const file = try self.parent.createFile(self.io, temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer self.parent.deleteFile(self.io, temporary) catch |err| switch (err) {
            error.FileNotFound => {},
            else => @import("stderr.zig").diagnostic("rui: retained caller routing temporary after cleanup failure: {s}\n", .{@errorName(err)}),
        };
        {
            defer file.close(self.io);
            var buffer: [1024]u8 = undefined;
            var writer = file.writerStreaming(self.io, &buffer);
            try std.json.Stringify.value(.{ .format = CaptureRouting.format, .host_directory = route.host_directory.slice(), .runtime_hint = route.runtime_hint.slice() }, .{}, &writer.interface);
            try writer.flush();
            try file.sync(self.io);
        }
        try self.parent.renamePreserve(temporary, self.parent, name, self.io);
        self.routing_published = true;
        // Routing must be durable before the request marker can become visible.
        try self.syncParent();
        return route;
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
        try self.syncParent();
        self.lock_file.close(self.io);
        self.parent.close(self.io);
        self.active = false;
    }

    fn syncParent(self: *const Capture) !void {
        // Borrow the directory descriptor; File.sync is the same fsync syscall
        // through the invocation's I/O owner, without taking descriptor custody.
        const parent_file: std.Io.File = .{ .handle = self.parent.handle, .flags = .{ .nonblocking = false } };
        parent_file.sync(self.io) catch return error.RecordDirectorySyncFailed;
    }

    fn write(self: *Capture, bytes: []const u8) !void {
        self.writer.interface.writeAll(bytes) catch return self.writer.err orelse error.WriteFailed;
    }

    fn writeJsonString(self: *Capture, value: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        std.json.Stringify.encodeJsonString(value, .{}, &self.writer.interface) catch
            return self.writer.err orelse error.WriteFailed;
    }

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

    fn writeConfiguration(self: *Capture, input: ConfigureInput) !void {
        try self.write("{");
        var separator: []const u8 = "";
        inline for (@import("session_settings.zig").spec_entries) |entry| {
            // app_tools has no client input until its declaration step.
            if (comptime entry.kind == .app_tools) continue;
            const value = @field(input, entry.field);
            const present = switch (entry.kind) {
                .content => value.state != .omitted,
                .tools => value != null,
                else => value.present,
            };
            if (present) {
                try self.write(separator);
                try self.write("\"" ++ entry.spec ++ "\":");
                separator = ",";
                switch (entry.kind) {
                    .text, .choice => if (comptime entry.nullable) {
                        if (value.value) |text| try self.writeJsonString(text) else try self.write("null");
                    } else try self.writeJsonString(value.value),
                    .content => switch (value.state) {
                        .omitted => unreachable,
                        .explicit_null => {
                            if (!entry.nullable) return error.NullNotAllowed;
                            try self.write("null");
                        },
                        .value => if (entry.json_object) try self.writeInputFile(value.path, protocol.max_sqlite_content_bytes, false, true) else try self.writeJsonFile(value.path),
                    },
                    .tools => try self.writeTools(value.?),
                    .app_tools => unreachable,
                    .decimal_policy => if (value.value) |text| {
                        const tokens = try std.fmt.parseInt(u64, text, 10);
                        var digits: [20]u8 = undefined;
                        try self.write(try std.fmt.bufPrint(&digits, "{d}", .{tokens}));
                    } else try self.write("null"),
                }
            }
        }
        if (input.preferences.reasoning_effort != null or input.preferences.permission_mode != null) {
            try self.write(separator);
            try self.write("\"preferences\":{");
            var preference_separator: []const u8 = "";
            if (input.preferences.reasoning_effort) |effort| {
                try self.write("\"reasoning_effort\":");
                try self.writeJsonString(@tagName(effort));
                preference_separator = ",";
            }
            if (input.preferences.permission_mode) |mode| {
                try self.write(preference_separator);
                try self.write("\"permission_mode\":");
                try self.writeJsonString(@tagName(mode));
            }
            try self.write("}");
        }
        try self.write("}");
    }

    fn writeJsonFile(self: *Capture, path: []const u8) !void {
        return self.writeJsonFileBounded(path, protocol.max_sqlite_content_bytes, false);
    }

    fn writeJsonFileBounded(self: *Capture, path: []const u8, limit: u64, require_text: bool) !void {
        return self.writeInputFile(path, limit, require_text, false);
    }

    fn writeInputFile(self: *Capture, path: []const u8, limit: u64, require_text: bool, comptime schema: bool) !void {
        const stdin = std.mem.eql(u8, path, "-");
        const read: Step = if (stdin) .stdin_read else .input_file_read;
        var file = if (stdin)
            std.Io.File.stdin()
        else
            std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| return self.failInput(read, err);
        defer if (!stdin) file.close(self.io);
        if (!schema) self.write("\"") catch |err| return self.failInput(read, err);
        const SchemaEncoder = @import("schema_json.zig").Encoder;
        var encoder: SchemaEncoder = if (schema) .init(std.heap.page_allocator) else undefined;
        defer if (schema) encoder.deinit();
        const Sink = struct {
            capture: *Capture,
            pub fn write(sink: @This(), bytes: []const u8) !void {
                try sink.capture.write(bytes);
            }
        };
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
            if (schema) {
                for (buffer[0..count]) |byte| {
                    if (encoder.done) {
                        if (std.mem.indexOfScalar(u8, " \t\r\n", byte) == null)
                            return self.failInput(.input_parse, error.InvalidOutputSchema);
                    } else _ = encoder.feed(byte, Sink{ .capture = self }) catch |err| {
                        if (self.writer.err) |failure| return failure;
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                        return self.failInput(.input_parse, error.InvalidOutputSchema);
                    };
                }
            } else std.json.Stringify.encodeJsonStringChars(buffer[0..count], .{}, &self.writer.interface) catch
                return self.writer.err orelse error.WriteFailed;
        }
        if (!validator.complete()) return self.failInput(.input_parse, error.InvalidUtf8);
        if (schema and !encoder.done) return self.failInput(.input_parse, error.InvalidOutputSchema);
        if (require_text and decoded_bytes == 0) return self.failInput(.input_parse, error.EmptyMessageInput);
        if (!schema) try self.write("\"");
    }

    fn failInput(self: *Capture, step: Step, err: anytype) @TypeOf(err) {
        if (self.input_failure) |slot| slot.* = step;
        return err;
    }

    fn scratchFile(self: *Capture, suffix: []const u8) !std.Io.File {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.final_name.slice(), &digest, .{});
        var name_buffer: [128]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, ".input-{s}-{s}", .{ std.fmt.bytesToHex(digest, .lower), suffix });
        self.parent.deleteFile(self.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        const file = try self.parent.createFile(self.io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
        errdefer file.close(self.io);
        try self.parent.deleteFile(self.io, name);
        return file;
    }

    fn appendTextStream(self: *Capture, snapshot: *@import("InputCapture.zig"), file: std.Io.File, first: []const u8, omit_empty: bool) !void {
        var buffer: [@import("InputCapture.zig").window_bytes]u8 = undefined;
        var count = if (first.len == 0) file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        } else first.len;
        if (first.len != 0) @memcpy(buffer[0..first.len], first);
        if (omit_empty and count == 0) return;
        try snapshot.beginUnknownText();
        while (count != 0) {
            var allowance = count;
            _ = try snapshot.append(buffer[0..count], &allowance, false);
            count = file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
        }
        try snapshot.end();
    }

    fn writeMessageOperands(self: *Capture, operands: []const MessageOperand, input_stdin: ?std.Io.File) !void {
        const InputCapture = @import("InputCapture.zig");
        if (operands.len > @import("input_parts.zig").max_parts) return error.TooManyInputParts;
        var explicit_text = false;
        var selected_stdin = false;
        var has_image = false;
        for (operands) |operand| switch (operand) {
            .text => explicit_text = true,
            .text_file => |path| {
                explicit_text = true;
                if (std.mem.eql(u8, path, "-")) {
                    if (selected_stdin) return error.DuplicateStdin;
                    selected_stdin = true;
                }
            },
            .image => has_image = true,
        };
        const spool = try self.scratchFile("spool");
        const index = self.scratchFile("index") catch |err| {
            spool.close(self.io);
            return err;
        };
        var used: std.atomic.Value(u64) = .init(0);
        var snapshot: InputCapture = undefined;
        snapshot.init(self.io, spool, index, .{ .used = &used, .limit = @import("content_string.zig").max_bytes + (384 * 1024 * 1024) + 1024 * 1024 });
        defer snapshot.close();
        const stdin = input_stdin orelse std.Io.File.stdin();
        const is_terminal = stdin.isTty(self.io) catch false;
        if (!selected_stdin and !is_terminal) {
            var first: [1]u8 = undefined;
            const count = stdin.readStreaming(self.io, &.{&first}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (count != 0) {
                if (explicit_text) return error.UnselectedStdin;
                try self.appendTextStream(&snapshot, stdin, first[0..count], true);
            }
        }
        for (operands) |operand| switch (operand) {
            .text => |text| {
                try snapshot.begin(.text, text.len);
                var at: usize = 0;
                while (at < text.len) {
                    var allowance: usize = InputCapture.window_bytes;
                    at += try snapshot.append(text[at..], &allowance, false);
                }
                try snapshot.end();
            },
            .text_file => |path| {
                const standard = std.mem.eql(u8, path, "-");
                const file = if (standard) stdin else try std.Io.Dir.cwd().openFile(self.io, path, .{});
                defer if (!standard) file.close(self.io);
                try self.appendTextStream(&snapshot, file, "", false);
            },
            .image => |path| try self.captureImage(&snapshot, path),
        };
        if (!has_image and snapshot.length == 0) return error.EmptyMessageInput;
        if (!has_image and snapshot.length > protocol.max_sqlite_content_bytes) return error.ContentTooLarge;
        var cursor = (try snapshot.seal()).cursor();
        if (!has_image) {
            try self.writeRequest(protocol.message_request.text, .{});
            try self.write("\"");
            while (try cursor.next()) |part| try self.writePartText(part.range);
            try self.write("\"");
            try self.writeRequest(protocol.message_request.text_tail, .{});
            return;
        }
        try self.write(",\"parts\":[");
        var separator: []const u8 = "";
        while (try cursor.next()) |part| {
            try self.write(separator);
            separator = ",";
            switch (part.kind) {
                .text => {
                    try self.write("{\"type\":\"text\",\"text\":\"");
                    try self.writePartText(part.range);
                    try self.write("\"}");
                },
                .image => |image| {
                    try self.write("{\"type\":\"image\",\"mime\":");
                    try self.writeJsonString(image.media.format.mime());
                    try self.write(",\"data\":\"");
                    try self.writePartImage(part.range);
                    try self.write("\"}");
                },
            }
        }
        try self.write("]");
    }

    noinline fn captureImage(self: *Capture, snapshot: *@import("InputCapture.zig"), path: []const u8) !void {
        var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const cwd = if (std.fs.path.isAbsolute(path)) "" else cwd_buffer[0..try std.Io.Dir.cwd().realPath(self.io, &cwd_buffer)];
        const file = try @import("os/read_image_file.zig").open(self.io, cwd, path);
        defer file.close(self.io);
        var source: @import("image_file_source.zig").FileSource = .{ .io = self.io, .file = file, .length = (try file.stat(self.io)).size };
        var intake: @import("image_intake.zig").Intake = .{};
        switch (intake.begin(source.source(), .{})) {
            .ready => {},
            .failed => |failure| return switch (failure) {
                inline else => |err| err,
            },
            else => unreachable,
        }
        switch (intake.attach(snapshot)) {
            .pending => {},
            .failed => |failure| return switch (failure) {
                inline else => |err| err,
            },
            else => unreachable,
        }
        while (true) switch (intake.step()) {
            .pending => {},
            .kept => break,
            .failed => |failure| return switch (failure) {
                inline else => |err| err,
            },
            else => unreachable,
        };
    }

    noinline fn writePartImage(self: *Capture, range: @import("content_custody.zig").Range) !void {
        var offset: u64 = 0;
        var raw: [1536]u8 = undefined;
        var encoded: [2048]u8 = undefined;
        while (offset < range.length) {
            const count: usize = @intCast(@min(raw.len, range.length - offset));
            if (try range.file.readPositionalAll(self.io, raw[0..count], range.offset + offset) != count) return error.ContentChanged;
            try self.write(std.base64.standard.Encoder.encode(&encoded, raw[0..count]));
            offset += count;
        }
    }

    fn writePartText(self: *Capture, range: @import("content_custody.zig").Range) !void {
        var offset: u64 = 0;
        var buffer: [@import("InputCapture.zig").window_bytes]u8 = undefined;
        while (offset < range.length) {
            const count: usize = @intCast(@min(buffer.len, range.length - offset));
            if (try range.file.readPositionalAll(self.io, buffer[0..count], range.offset + offset) != count) return error.ContentChanged;
            std.json.Stringify.encodeJsonStringChars(buffer[0..count], .{}, &self.writer.interface) catch return self.writer.err orelse error.WriteFailed;
            offset += count;
        }
    }

    fn writeTools(self: *Capture, value: @import("configure_input.zig").ToolInput) !void {
        var chosen: [protocol.max_tools][]const u8 = undefined;
        var count: usize = 0;
        switch (value) {
            .cli => |text| if (!std.mem.eql(u8, text, "none")) {
                var names = std.mem.splitScalar(u8, text, ',');
                while (names.next()) |name| {
                    if (count == chosen.len) return error.TooManyTools;
                    chosen[count] = name;
                    count += 1;
                }
            },
            .names => |names| {
                if (names.len > chosen.len) return error.TooManyTools;
                @memcpy(chosen[0..names.len], names);
                count = names.len;
            },
        }
        for (chosen[0..count]) |name| if (!protocol.validToolName(name)) return error.InvalidToolName;
        std.mem.sortUnstable([]const u8, chosen[0..count], {}, struct {
            fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
        try self.write("[");
        for (chosen[0..count], 0..) |name, index| {
            if (index != 0) {
                if (std.mem.eql(u8, chosen[index - 1], name)) return error.DuplicateToolName;
                try self.write(",");
            }
            try self.writeJsonString(name);
        }
        try self.write("]");
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

fn openRead(requests: Requests, paths: *const platform.Paths, comptime route: []const u8, body: []const u8) !std.posix.fd_t {
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(requests, address, null);
    errdefer closeSocket(requests.io, fd);
    var header_buffer: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "POST " ++ route ++ " HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{body.len});
    try writeAllRequest(requests, fd, header, null);
    try writeAllRequest(requests, fd, body, null);
    return fd;
}

pub const SendError = ErrorOf(std.Io.net.UnixAddress.init) || ErrorOf(connectRequest) || ErrorOf(uploadRequest) || ErrorOf(readCommandResponse);
pub const MutationSendError = SendError || ErrorOf(CapturedRecord.resolvePaths) || error{ Cancelled, EnvironmentTooLarge, RequestBindingMismatch };

pub const Environment = struct {
    map: *const std.process.Environ.Map,

    pub const empty: Environment = .{ .map = &empty_map };
    const empty_map: std.process.Environ.Map = .{ .array_hash_map = .empty, .allocator = undefined };

    pub fn bytes(self: Environment) u64 {
        var total: u64 = 0;
        for (self.map.keys(), self.map.values()) |name, value| {
            if (environment_rule.forwards(name, value)) total += environment_rule.entryBytes(name, value);
        }
        return total;
    }

    pub fn largest(self: Environment) [3]?[]const u8 {
        var names: [3]?[]const u8 = @splat(null);
        var sizes: [3]usize = @splat(0);
        for (self.map.keys(), self.map.values()) |name, value| {
            if (!environment_rule.forwards(name, value)) continue;
            var size = environment_rule.entryBytes(name, value);
            var held: ?[]const u8 = name;
            for (&names, &sizes) |*slot_name, *slot_size| {
                if (held == null or size <= slot_size.*) continue;
                std.mem.swap(?[]const u8, slot_name, &held);
                std.mem.swap(usize, slot_size, &size);
            }
        }
        return names;
    }

    const shown_name_bytes = 32;
    const too_large_head = "this shell's environment is {d} bytes, over the {d} a Message carries for Bash; nothing was sent. Largest variables:";
    pub const too_large_bytes = too_large_head.len + 2 * 20 + 3 * (", ".len + TerminalText.max_bytes_per_byte * shown_name_bytes) + ".".len;

    pub fn describeTooLarge(self: Environment, writer: *std.Io.Writer) !void {
        try writer.print(too_large_head, .{ self.bytes(), protocol.max_environment_bytes });
        for (self.largest(), 0..) |name, index| if (name) |value| {
            try writer.writeAll(if (index == 0) " " else ", ");
            var text: TerminalText = .{ .mode = .line };
            try text.feed(writer, value[0..@min(value.len, shown_name_bytes)]);
            try text.finish(writer);
        };
        try writer.writeAll(".");
    }

    fn upload(self: Environment, requests: Requests, fd: std.posix.fd_t, buffer: []u8, until: ?i128) !void {
        var used: usize = 0;
        for (self.map.keys(), self.map.values()) |name, value| {
            if (!environment_rule.forwards(name, value)) continue;
            for ([_][]const u8{ name, "=", value, "\x00" }) |piece| {
                var rest = piece;
                while (rest.len != 0) {
                    const take = @min(rest.len, buffer.len - used);
                    @memcpy(buffer[used..][0..take], rest[0..take]);
                    used += take;
                    rest = rest[take..];
                    if (used == buffer.len) {
                        try writeAllRequest(requests, fd, buffer, until);
                        used = 0;
                    }
                }
            }
        }
        try writeAllRequest(requests, fd, buffer[0..used], until);
    }
};

fn sendSource(
    requests: Requests,
    paths: *const platform.Paths,
    route: []const u8,
    timing: ResponseTiming,
    length: u64,
    file: ?*std.Io.File,
    bytes: ?[]const u8,
    instance: ?*const protocol.InstanceId,
    environment: ?Environment,
    reply_buffer: anytype,
    until: ?i128,
) Stepped(SendError, protocol_reply.CommandReply) {
    const address = std.Io.net.UnixAddress.init(paths.socket.slice()) catch |err| return .fail(.endpoint, err);
    const fd = connectRequest(requests, address, until) catch |err| return .fail(.connect, err);
    defer closeSocket(requests.io, fd);
    uploadRequest(requests, fd, route, timing, length, file, bytes, instance, environment, until) catch |err| return .fail(.upload, err);
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
    environment: ?Environment,
    until: ?i128,
) !void {
    var header_buffer: [512]u8 = undefined;
    const environment_bytes = if (environment) |value| value.bytes() else 0;
    var used = (try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n", .{ route, environment_bytes + length })).len;
    if (environment != null) {
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Environment-Bytes: {d}\r\n", .{environment_bytes})).len;
    }
    if (instance) |id| {
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Host-Instance: {s}\r\n", .{std.fmt.bytesToHex(id.*, .lower)})).len;
    }
    if (requests.drop_reply) |drop| {
        std.debug.assert(std.meta.eql(timing, ResponseTiming.mutation));
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Test-Drop-Reply: {s}\r\n", .{drop})).len;
    }
    used += (try std.fmt.bufPrint(header_buffer[used..], "\r\n", .{})).len;
    try writeAllRequest(requests, fd, header_buffer[0..used], until);
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    if (environment) |value| try value.upload(requests, fd, &buffer, until);
    const source = file orelse return writeAllRequest(requests, fd, bytes.?, until);
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
    const socket: std.Io.net.Socket = .{ .handle = fd, .address = .{ .ip4 = .loopback(0) } };
    socket.close(io);
}

fn connectRequest(requests: Requests, address: std.Io.net.UnixAddress, until: ?i128) !std.posix.fd_t {
    return connectSocket(requests, address, until) catch |err| return requests.transportFailure(err);
}

fn connectSocket(requests: Requests, address: std.Io.net.UnixAddress, until: ?i128) !std.posix.fd_t {
    try requests.check();
    if (until != null or requests.cancellation != null) return connectUntil(requests, address.path, until);
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

pub fn hostUnreachable(err: anyerror) bool {
    return switch (err) {
        error.FileNotFound, error.ConnectionRefused, error.UnixConnectFailed, error.ConnectionResetByPeer, error.BrokenPipe, error.TruncatedResponse => true,
        else => false,
    };
}

fn connectFailure(code: std.posix.E) error{ AccessDenied, PermissionDenied, FileNotFound, NotDir, SymLinkLoop, ReadOnlyFileSystem, ConnectionRefused, UnixConnectFailed } {
    return switch (code) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .ROFS => error.ReadOnlyFileSystem,
        .CONNREFUSED => error.ConnectionRefused,
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
    const envelope = try readResponseEnvelopeUntil(requests, fd, timing, until);
    if (!envelope.wire_matches) return error.WrongWireVersion;
    return envelope.head;
}

const ResponseEnvelope = struct {
    head: ResponseHead,
    wire_matches: bool,
    wire: protocol.Bounded(8) = .{},
};

fn readResponseEnvelopeUntil(requests: Requests, fd: std.posix.fd_t, timing: ResponseTiming, until: ?i128) !ResponseEnvelope {
    var header_buffer: [protocol.max_header_bytes]u8 = undefined;
    const first_deadline = timing.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, until, false);
    const first_count = try readRequest(requests, fd, header_buffer[0..1], first_deadline);
    if (first_count == 0) return requests.transportFailure(error.TruncatedResponse);
    var used: usize = first_count;
    while (used < header_buffer.len) {
        if (used >= 4 and std.mem.eql(u8, header_buffer[used - 4 .. used], "\r\n\r\n")) break;
        const deadline = timing.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, until, true);
        const count = try readRequest(requests, fd, header_buffer[used .. used + 1], deadline);
        if (count == 0) return requests.transportFailure(error.TruncatedResponse);
        used += count;
    } else return error.ResponseHeaderTooLarge;
    return parseResponseEnvelope(header_buffer[0..used]);
}

fn parseResponseHead(bytes: []const u8) !ResponseHead {
    const envelope = try parseResponseEnvelope(bytes);
    if (!envelope.wire_matches) return error.WrongWireVersion;
    return envelope.head;
}

fn parseResponseEnvelope(bytes: []const u8) !ResponseEnvelope {
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
    var wire: protocol.Bounded(8) = .{};
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
            wire.set(value) catch {};
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
    const head: ResponseHead = .{
        .status = status,
        .content_length = length orelse return error.InvalidResponse,
        .kind = kind orelse return error.InvalidResponse,
        .total = total,
        .next = next,
    };
    return .{ .head = head, .wire_matches = wire_ok orelse return error.InvalidResponse, .wire = wire };
}

fn readCommandResponse(fd: std.posix.fd_t, reply_buffer: *ReplyBuffer) !protocol_reply.CommandReply {
    return readCommandResponseRequest(.{ .io = std.Io.Threaded.global_single_threaded.io() }, fd, reply_buffer, .{}, null);
}

fn readCommandResponseRequest(requests: Requests, fd: std.posix.fd_t, reply_buffer: anytype, timing: ResponseTiming, until: ?i128) !protocol_reply.CommandReply {
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

/// One server the reload asked, with the generation it was given.
pub const ToolsAsked = struct {
    pub const Ask = struct { server: Bounded(@import("tool_record.zig").max_server_bytes) = .{}, generation: u64 = 0 };
    /// The Host that took the ask. Its generations restart at 0 when a new Host starts.
    instance: protocol.InstanceId = @splat(0),
    len: usize = 0,
    items: [@import("host_settings.zig").max_mcp_servers]Ask = @splat(.{}),

    pub fn slice(self: *const ToolsAsked) []const Ask {
        return self.items[0..self.len];
    }
};

/// One configured server's list status, as `tools_status` reports it.
pub const ToolServerStatus = struct {
    server: Bounded(@import("tool_record.zig").max_server_bytes) = .{},
    state: @import("mcp/relist.zig").State = .idle,
    last: @import("mcp/relist.zig").Last = .never,
    finished: u64 = 0,
    tools: u64 = 0,
    left_out: u64 = 0,
};

pub const ToolsStatus = struct {
    /// The Host that replied.
    instance: protocol.InstanceId = @splat(0),
    len: usize = 0,
    items: [@import("host_settings.zig").max_mcp_servers]ToolServerStatus = @splat(.{}),

    pub fn slice(self: *const ToolsStatus) []const ToolServerStatus {
        return self.items[0..self.len];
    }
};

/// How an asked list ended, once it has landed.
pub const ToolOutcome = enum { listed, failed };

/// One asked server's latest outcome and tool count, in asked order.
pub const ToolsOutcomes = struct {
    pub const Row = struct { server: Bounded(@import("tool_record.zig").max_server_bytes) = .{}, outcome: ToolOutcome = .listed, tools: u64 = 0, left_out: u64 = 0 };
    len: usize = 0,
    items: [@import("host_settings.zig").max_mcp_servers]Row = @splat(.{}),

    pub fn slice(self: *const ToolsOutcomes) []const Row {
        return self.items[0..self.len];
    }
};

pub const ToolsProgress = enum { waiting, landed };

/// The one owner of whether asked lists have landed and what they reported. `status` is null until a status reply
/// has been read. An empty ask has landed at once, with no status read. Otherwise every asked server must have landed
/// (see `serverLanded`) before `outcomes` is filled with each server's latest outcome, in asked order.
pub fn toolsProgress(asked: *const ToolsAsked, status: ?*const ToolsStatus, outcomes: *ToolsOutcomes) error{InvalidResponse}!ToolsProgress {
    outcomes.len = 0;
    if (asked.len == 0) return .landed;
    const read = status orelse return .waiting;
    var waiting = false;
    for (asked.slice()) |ask| {
        if (!try serverLanded(asked, read, ask)) waiting = true;
    }
    if (waiting) return .waiting;
    for (asked.slice(), 0..) |ask, index| {
        const row = try statusRow(read, ask.server.slice());
        outcomes.items[index] = .{ .server = ask.server, .outcome = toolOutcome(row.last) orelse return error.InvalidResponse, .tools = row.tools, .left_out = row.left_out };
    }
    outcomes.len = asked.len;
    return .landed;
}

/// True once `ask` has landed in the Host that replied. The same Host landed it once its finished generation reaches
/// the ask's. A different Host (its instance differs) has restarted its generations, so its startup list counts once
/// any list has finished. A row with no server, or one that reports `never` once landed, is an invalid reply.
pub fn serverLanded(asked: *const ToolsAsked, status: *const ToolsStatus, ask: ToolsAsked.Ask) error{InvalidResponse}!bool {
    const row = try statusRow(status, ask.server.slice());
    const landed = if (std.mem.eql(u8, &asked.instance, &status.instance))
        row.finished >= ask.generation
    else
        row.finished >= 1;
    if (landed and row.last == .never) return error.InvalidResponse;
    return landed;
}

fn statusRow(status: *const ToolsStatus, name: []const u8) error{InvalidResponse}!ToolServerStatus {
    for (status.slice()) |row| if (std.mem.eql(u8, row.server.slice(), name)) return row;
    return error.InvalidResponse;
}

fn toolOutcome(last: @import("mcp/relist.zig").Last) ?ToolOutcome {
    return switch (last) {
        .never => null,
        .listed => .listed,
        .failed => .failed,
    };
}

fn parseToolsAsked(gpa: std.mem.Allocator, reply: []const u8) !ToolsAsked {
    const Wire = struct {
        version: []const u8,
        type: []const u8,
        instance: []const u8,
        asked: []const struct { server: []const u8, generation: []const u8 },
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const wire = std.json.parseFromSliceLeaky(Wire, arena.allocator(), reply, .{}) catch return error.InvalidResponse;
    if (!std.mem.eql(u8, wire.version, protocol.wire_version) or !std.mem.eql(u8, wire.type, "tools_reload_reply")) return error.InvalidResponse;
    if (wire.asked.len > @import("host_settings.zig").max_mcp_servers) return error.InvalidResponse;
    var out: ToolsAsked = .{ .instance = protocol.parseInstanceId(wire.instance) catch return error.InvalidResponse, .len = wire.asked.len };
    for (wire.asked, out.items[0..wire.asked.len]) |entry, *ask| {
        ask.server.set(entry.server) catch return error.InvalidResponse;
        ask.generation = std.fmt.parseInt(u64, entry.generation, 10) catch return error.InvalidResponse;
    }
    return out;
}

fn parseToolsStatus(gpa: std.mem.Allocator, reply: []const u8) !ToolsStatus {
    const relist = @import("mcp/relist.zig");
    const Wire = struct {
        version: []const u8,
        type: []const u8,
        instance: []const u8,
        servers: []const struct { server: []const u8, state: []const u8, last: []const u8, finished: []const u8, tools: []const u8, left_out: []const u8 },
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const wire = std.json.parseFromSliceLeaky(Wire, arena.allocator(), reply, .{}) catch return error.InvalidResponse;
    if (!std.mem.eql(u8, wire.version, protocol.wire_version) or !std.mem.eql(u8, wire.type, "tools_status")) return error.InvalidResponse;
    if (wire.servers.len > @import("host_settings.zig").max_mcp_servers) return error.InvalidResponse;
    var out: ToolsStatus = .{ .instance = protocol.parseInstanceId(wire.instance) catch return error.InvalidResponse, .len = wire.servers.len };
    for (wire.servers, out.items[0..wire.servers.len]) |entry, *row| {
        row.server.set(entry.server) catch return error.InvalidResponse;
        row.state = std.meta.stringToEnum(relist.State, entry.state) orelse return error.InvalidResponse;
        row.last = std.meta.stringToEnum(relist.Last, entry.last) orelse return error.InvalidResponse;
        row.finished = std.fmt.parseInt(u64, entry.finished, 10) catch return error.InvalidResponse;
        row.tools = std.fmt.parseInt(u64, entry.tools, 10) catch return error.InvalidResponse;
        row.left_out = std.fmt.parseInt(u64, entry.left_out, 10) catch return error.InvalidResponse;
    }
    return out;
}

/// The reply body of a report request. `refusal` maps a command reply (a refusal, not a report) to its typed error.
fn readReportBody(requests: Requests, fd: std.posix.fd_t, gpa: std.mem.Allocator, comptime refusal: anytype) ![]u8 {
    const Sink = struct {
        bytes: std.ArrayList(u8) = .empty,
        gpa: std.mem.Allocator,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.bytes.appendSlice(self.gpa, bytes);
        }
    };
    var sink: Sink = .{ .gpa = gpa };
    errdefer sink.bytes.deinit(gpa);
    var buffer: ReplyBuffer = .{};
    return switch (try readReportResponse(requests, fd, &sink, &buffer)) {
        .report => try sink.bytes.toOwnedSlice(gpa),
        .command => |reply| return refusal(reply),
    };
}

/// A tools refusal. A 503 that a control command reads as an unavailable Host (`hostStatus`, the same
/// `validHostUnavailable` test) is not a protocol error: a Host out of connection capacity is busy and worth
/// asking again, and a fenced Host is stopping.
fn toolsRefusal(reply: protocol_reply.CommandReply) error{ UnknownMcpServer, HostStopped, HostBusy, InvalidResponse } {
    const Refusal = struct { type: []const u8 = "", code: []const u8 = "" };
    var storage: [protocol.max_control_error_response_bytes * 2]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&storage);
    const refusal = std.json.parseFromSliceLeaky(Refusal, arena.allocator(), reply.body, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
    if (reply.status == 503 and protocol_reply.validHostUnavailable(reply.body))
        return if (std.mem.eql(u8, refusal.type, "busy")) error.HostBusy else error.HostStopped;
    if (std.mem.eql(u8, refusal.code, "unknown_mcp_server")) return error.UnknownMcpServer;
    return error.InvalidResponse;
}

/// A model-list refusal is always a protocol error.
fn modelListRefusal(reply: protocol_reply.CommandReply) error{InvalidResponse} {
    _ = reply;
    return error.InvalidResponse;
}

fn readModelListResponse(requests: Requests, fd: std.posix.fd_t, gpa: std.mem.Allocator) ![]u8 {
    return readReportBody(requests, fd, gpa, modelListRefusal);
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
            if (count == 0) return requests.transportFailure(error.TruncatedResponse);
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

fn readCommandBodyUntil(requests: Requests, fd: std.posix.fd_t, head: ResponseHead, reply_buffer: anytype, timing: ResponseTiming, until: ?i128) !protocol_reply.CommandReply {
    reply_buffer.len = 0;
    errdefer reply_buffer.len = 0;
    if (head.content_length > reply_buffer.bytes.len) return error.ResponseTooLarge;
    const body_length: usize = @intCast(head.content_length);
    var offset: usize = 0;
    while (offset < body_length) {
        const deadline = timing.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, until, true);
        const count = try readRequest(requests, fd, reply_buffer.bytes[offset..body_length], deadline);
        if (count == 0) return requests.transportFailure(error.TruncatedResponse);
        offset += count;
    }
    reply_buffer.len = body_length;
    return .{ .status = head.status, .body = reply_buffer.slice() };
}

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
    return readSocket(requests, fd, buffer, deadline) catch |err| return requests.transportFailure(err);
}

fn readSocket(requests: Requests, fd: std.posix.fd_t, buffer: []u8, deadline: ?i128) !usize {
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
    return writeSocket(requests, fd, value, until) catch |err| return requests.transportFailure(err);
}

fn writeSocket(requests: Requests, fd: std.posix.fd_t, value: []const u8, until: ?i128) !void {
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
    "X-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n";

test "upgrade Host observation encoder sends exactly the current read-only request" {
    const io = std.testing.io;
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    defer closeTestDescriptor(sockets[1]);
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
    try uploadHostInfoRequest(.{ .io = io }, sockets[0], "/one\"quoted", until);
    const wire = protocol.wire_version;
    var body_buffer: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buffer, "{{\"version\":\"{s}\",\"kind\":\"host_info\",\"store\":\"/one\\\"quoted\"}}", .{wire});
    var expected_buffer: [1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "POST /v1/host-info HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ wire, body.len, body });
    var actual_buffer: [1024]u8 = undefined;
    var used: usize = 0;
    while (used < expected.len) {
        const n = try readRequest(.{ .io = io }, sockets[1], actual_buffer[used..expected.len], until);
        if (n == 0) return error.TestUnexpectedResult;
        used += n;
    }
    try std.testing.expectEqualStrings(expected, actual_buffer[0..used]);
}

test "upgrade Host observation headers preserve strict framing and the current wire" {
    const released_field = "X-Rui-Wire-Version: " ++ "22";
    const old = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\n" ++ released_field ++ "\r\n\r\n";
    try std.testing.expectError(error.WrongWireVersion, parseResponseHead(old));
    _ = try parseResponseHead(empty_test_response);
    const long_wire = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nX-Rui-Wire-Version: unrecognized-long-wire-version\r\n\r\n";
    try std.testing.expectError(error.WrongWireVersion, parseResponseHead(long_wire));
    const wire_field = "X-Rui-Wire-Version: " ++ protocol.wire_version;
    const good = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\n" ++ wire_field ++ "\r\n\r\n";
    _ = try parseResponseHead(good);
    for ([_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "Content-Length: 0", .to = "Content-Length: 0\r\nContent-Length: 0" },
        .{ .from = "Content-Length: 0", .to = "Content-Length: +0" },
        .{ .from = "Content-Length: 0\r\n", .to = "" },
        .{ .from = "Content-Type: application/json\r\n", .to = "" },
        .{ .from = "Content-Type: application/json", .to = "Content-Type: application/json\r\nTransfer-Encoding: chunked" },
        .{ .from = "Content-Type: application/json", .to = "Content-Type: application/json\r\nContent-Encoding: gzip" },
        .{ .from = "Content-Type: application/json", .to = "Content-Type: application/json\r\nBad Name: x" },
        .{ .from = "Content-Type: application/json", .to = "Content-Type: application/json\r\nX-Extension: \x01" },
        .{ .from = "X-Rui-Wire-Version:", .to = released_field ++ "\r\nX-Rui-Wire-Version:" },
    }) |case| {
        const bad = try std.mem.replaceOwned(u8, std.testing.allocator, good, case.from, case.to);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(error.InvalidResponse, parseResponseHead(bad));
    }
    for ([_][]const u8{ "8", protocol.next_wire_version, "09", "unknown", "" }) |wire| {
        const field = try std.fmt.allocPrint(std.testing.allocator, "X-Rui-Wire-Version: {s}", .{wire});
        defer std.testing.allocator.free(field);
        const bad = try std.mem.replaceOwned(u8, std.testing.allocator, good, wire_field, field);
        defer std.testing.allocator.free(bad);
        try std.testing.expectError(error.WrongWireVersion, parseResponseHead(bad));
    }
    try std.testing.expectError(error.InvalidResponse, parseResponseHead("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" ++ released_field ++ "\r\n\r\n"));
    try std.testing.expectError(error.InvalidResponse, parseResponseHead("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n"));
}

test "WIR-5 foreign Host status decodes through its own executable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // The released envelope: its own version is not ours, fields we do not read are ignored.
    const released = "{\"version\":\"" ++ "22" ++ "\",\"type\":\"host_status\",\"status\":\"ready\",\"store\":\"/host\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"17\",\"intake_capacity\":\"10\",\"descriptor_limit\":null,\"started_at\":\"1792918800\",\"custody_occupied\":\"3\",\"paused\":true,\"settings_digest\":\"" ++ "abababababababababababababababababababababababababababababababab" ++ "\",\"capabilities\":{\"bash\":true},\"diagnostics\":\"/host/diagnostics\",\"future\":[1,2]}";
    const facts = (try parseUpgradeStatus(allocator, released)).?;
    try std.testing.expectEqualStrings("/host", facts.store.slice());
    try std.testing.expectEqual(@as(usize, 17), facts.active_capacity);
    try std.testing.expectEqual(@as(u8, 15), facts.instance[15]);
    try std.testing.expectEqual(@as(u8, 0xab), facts.settings_digest.?[31]);
    const unpublished = try std.mem.replaceOwned(u8, allocator, released, ",\"settings_digest\":\"" ++ "abababababababababababababababababababababababababababababababab" ++ "\"", "");
    defer allocator.free(unpublished);
    try std.testing.expect((try parseUpgradeStatus(allocator, unpublished)).?.settings_digest == null);
    for ([_][]const u8{
        "{}",
        "{\"type\":\"host_status\",\"status\":\"incompatible\"}",
        "{\"type\":\"host_info\",\"status\":\"ready\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"store\":\"/host\",\"active_capacity\":\"3\"}",
        "{\"type\":\"host_status\",\"status\":\"ready\",\"instance\":\"invalid\",\"store\":\"/host\",\"active_capacity\":\"3\"}",
        "{\"type\":\"host_status\",\"status\":\"ready\",\"store\":\"/host\",\"active_capacity\":\"3\"}",
        "{\"type\":\"host_status\",\"status\":\"ready\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"3\"}",
        "{\"type\":\"host_status\",\"status\":\"ready\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"store\":\"/host\",\"active_capacity\":\"overflow\"}",
        "{\"type\":\"host_status\",\"status\":\"ready\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"store\":\"/host\",\"active_capacity\":\"3\",\"settings_digest\":\"AB\"}",
        "{\"type\":\"host_status\",\"status\":\"ready\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"store\":\"/host\",\"active_capacity\":\"3\",\"settings_digest\":\"" ++ "ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB" ++ "\"}",
        "{\"type\":\"host_status\"",
    }) |invalid| try std.testing.expect(try parseUpgradeStatus(allocator, invalid) == null);

    // The executable is run as `<exe> host status --store DIR`; anything else is refused.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_s;
    const Script = struct {
        fn write(dir: std.Io.Dir, name: []const u8, body: []const u8) !void {
            const file = try dir.createFile(std.testing.io, name, .{ .permissions = .fromMode(0o700) });
            defer file.close(std.testing.io);
            try file.writeStreamingAll(std.testing.io, body);
        }
    };
    try Script.write(tmp.dir, "ready", "#!/bin/sh\nif [ \"$1\" != host ] || [ \"$2\" != status ] || [ \"$3\" != --store ] || [ \"$4\" != /host ]; then exit 3; fi\nprintf '%s\\n' '" ++ released ++ "'\n");
    try Script.write(tmp.dir, "refused", "#!/bin/sh\nexit 1\n");
    try Script.write(tmp.dir, "garbled", "#!/bin/sh\nprintf 'not json\\n'\n");
    const ready = try std.fmt.allocPrint(allocator, "{s}/ready", .{root});
    defer allocator.free(ready);
    const read = try readForeignHostStatus(allocator, io, ready, "/host", until);
    try std.testing.expectEqual(@as(usize, 17), read.active_capacity);
    try std.testing.expectEqualStrings("/host", read.store.slice());
    const refused = try std.fmt.allocPrint(allocator, "{s}/refused", .{root});
    defer allocator.free(refused);
    try std.testing.expectError(error.ForeignHostStatusFailed, readForeignHostStatus(allocator, io, refused, "/host", until));
    const garbled = try std.fmt.allocPrint(allocator, "{s}/garbled", .{root});
    defer allocator.free(garbled);
    try std.testing.expectError(error.InvalidForeignHostStatus, readForeignHostStatus(allocator, io, garbled, "/host", until));
    const missing = try std.fmt.allocPrint(allocator, "{s}/missing", .{root});
    defer allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, readForeignHostStatus(allocator, io, missing, "/host", until));
    try std.testing.expectError(error.TransferInactive, readForeignHostStatus(allocator, io, ready, "/host", std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - 1));
}

fn socketPair() ![2]std.posix.fd_t {
    var sockets: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    return sockets;
}

test "transport failure provenance excludes local sinks, valid physical EOF and cancellation" {
    const Sink = struct {
        fail: bool,
        bytes: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            if (self.fail) return error.FileNotFound;
            self.bytes += bytes.len;
        }
    };
    for (std.enums.values(enum { complete, truncated, local_sink, cancelled })) |mode| {
        const sockets = try socketPair();
        defer closeSocket(std.testing.io, sockets[0]);
        {
            defer closeSocket(std.testing.io, sockets[1]);
            try writeAll(sockets[1], "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 3\r\nX-Rui-Content-Bytes: 3\r\nX-Rui-Next-Offset: 3\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n");
            try writeAll(sockets[1], if (mode == .truncated) "a" else "abc");
        }
        var origin: FailureOrigin = .local;
        var cancellation: Cancellation = .{};
        if (mode == .cancelled) cancellation.requestStop();
        const requests: Requests = .{ .io = std.testing.io, .cancellation = &cancellation, .failure_origin = &origin };
        var sink: Sink = .{ .fail = mode == .local_sink };
        const result = readPublicContentResponse(requests, sockets[0], .{ .bytes = 3, .digest = protocol.contentDigest("abc") }, &sink);
        switch (mode) {
            .complete => try std.testing.expect(try result == null),
            .truncated => try std.testing.expectError(error.TruncatedResponse, result),
            .local_sink => try std.testing.expectError(error.FileNotFound, result),
            .cancelled => try std.testing.expectError(error.Cancelled, result),
        }
        try std.testing.expectEqual(if (mode == .truncated) FailureOrigin.host_transport else .local, origin);
        try std.testing.expectEqual(@as(usize, if (mode == .complete) 3 else 0), sink.bytes);
    }
}

test "observation transport enforces its own bound independently of ordinary replies" {
    try std.testing.expectEqual(@sizeOf(protocol.ResponseBuffer), @sizeOf(ReplyBuffer));
    try std.testing.expectEqual(@sizeOf(protocol.CommandObservationBuffer), @sizeOf(ObservationBuffer));
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    defer closeTestDescriptor(sockets[1]);
    const capacity: c_int = 1024;
    try std.testing.expectEqual(@as(c_int, 0), std.c.setsockopt(sockets[1], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &capacity, @sizeOf(c_int)));
    var body: [protocol.command_observation_reply.max_bytes]u8 = @splat(' ');
    body[0] = '{';
    body[1] = '}';
    var header: [256]u8 = undefined;
    try writeAll(sockets[1], try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{body.len}));
    const Writer = struct {
        fd: std.posix.fd_t,
        bytes: []const u8,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            writeAll(self.fd, self.bytes) catch |err| {
                self.failure = err;
            };
        }
    };
    var producer: Writer = .{ .fd = sockets[1], .bytes = &body };
    const writer = try std.Thread.spawn(.{}, Writer.run, .{&producer});
    var observation: ObservationBuffer = .{};
    const read = readCommandResponseRequest(.{ .io = std.testing.io }, sockets[0], &observation, .{}, null);
    // If reading failed, wake a writer that may be blocked on a full socket.
    _ = socket_os.shutdown(sockets[0], std.c.SHUT.RD);
    writer.join();
    if (producer.failure) |err| return err;
    try std.testing.expectEqual(@as(?anyerror, null), if (read) |_| @as(?anyerror, null) else |err| @as(?anyerror, err));
    const reply = try read;
    try std.testing.expectEqualStrings(&body, reply.body);
    var ordinary: ReplyBuffer = .{};
    const head: ResponseHead = .{ .status = 200, .kind = .command_json, .content_length = ordinary.bytes.len + 1, .total = null, .next = null };
    try std.testing.expectError(error.ResponseTooLarge, readCommandBodyUntil(.{ .io = std.testing.io }, sockets[0], head, &ordinary, .{}, null));
    var too_large = head;
    too_large.content_length = observation.bytes.len + 1;
    try std.testing.expectError(error.ResponseTooLarge, readCommandBodyUntil(.{ .io = std.testing.io }, sockets[0], too_large, &observation, .{}, null));
    try std.testing.expectEqual(@as(usize, 0), observation.len);
}

test "Host processing wait starts inactivity only after the first response byte" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, struct {
        fn respond(fd: std.posix.fd_t) void {
            defer closeTestDescriptor(fd);
            std.Io.sleep(std.testing.io, .fromMilliseconds(400), .awake) catch return;
            writeAll(fd, empty_test_response) catch {};
        }
    }.respond, .{sockets[1]});
    defer writer.join();
    const head = try readResponseHeadWithInactivity(sockets[0], 100);
    try std.testing.expectEqual(@as(u16, 200), head.status);
}

/// A fake Host that sends `rest` only if the client is still reading two
/// seconds later. A working deadline returns long before that, so no thread
/// stall lets the rest arrive in time; a broken one reads the rest and fails
/// at once instead of waiting out a fallback inactivity (#1989).
const LateRest = struct {
    given_up: std.Io.Event = .unset,
    thread: std.Thread = undefined,

    fn start(self: *LateRest, fd: std.posix.fd_t, rest: []const u8) !void {
        self.* = .{};
        self.thread = try std.Thread.spawn(.{}, run, .{ self, fd, rest });
    }

    fn run(self: *LateRest, fd: std.posix.fd_t, rest: []const u8) void {
        self.given_up.waitTimeout(std.testing.io, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } }) catch writeAll(fd, rest) catch {};
    }

    fn finish(self: *LateRest) void {
        self.given_up.set(std.testing.io);
        self.thread.join();
    }
};

test "Host-info first byte is bounded independently of normal processing waits" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    defer closeTestDescriptor(sockets[1]);
    var late: LateRest = undefined;
    try late.start(sockets[1], empty_test_response);
    defer late.finish();
    var buffer: ReplyBuffer = .{};
    const until = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
    try std.testing.expectError(error.ResponseInactive, readCommandResponseRequest(.{ .io = std.testing.io }, sockets[0], &buffer, .{}, until));
}

test "response deadlines include partial header and body" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\nab";
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
    for ([_]bool{ false, true }) |mutation| {
        for ([_]usize{ 1, body_start + 1 }) |prefix_len| {
            const sockets = try socketPair();
            defer closeTestDescriptor(sockets[0]);
            defer closeTestDescriptor(sockets[1]);
            try addNonblocking(sockets[0]);
            try writeAll(sockets[1], response[0..prefix_len]);
            var late: LateRest = undefined;
            try late.start(sockets[1], response[prefix_len..]);
            defer late.finish();
            var buffer: ReplyBuffer = .{};
            const until: ?i128 = if (mutation) null else std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
            const timing: ResponseTiming = if (mutation) .{ .inactivity_ms = 10, .wait_for_first_byte = false } else .{};
            try std.testing.expectError(error.ResponseInactive, readCommandResponseRequest(.{ .io = std.testing.io }, sockets[0], &buffer, timing, until));
            try std.testing.expectEqual(@as(usize, 0), buffer.len);
        }
    }
}

test "mutation response progress renews inactivity through header and body" {
    // Each gap leaves 600 ms of the 1 s inactivity unused, so a stalled
    // producer or reader still lands inside it; the 1.2 s total exceeds one
    // window only if progress renews it (#1989).
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const Producer = struct {
        fn run(fd: std.posix.fd_t) void {
            defer closeTestDescriptor(fd);
            writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n") catch return;
            for ([_][]const u8{ "Content-Length: 2\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n", "\r\n{", "}" }) |piece| {
                std.Io.sleep(std.testing.io, .fromMilliseconds(400), .awake) catch return;
                writeAll(fd, piece) catch return;
            }
        }
    };
    const writer = try std.Thread.spawn(.{}, Producer.run, .{sockets[1]});
    defer writer.join();
    var buffer: ReplyBuffer = .{};
    const timing: ResponseTiming = .{ .inactivity_ms = 1_000, .wait_for_first_byte = ResponseTiming.mutation.wait_for_first_byte };
    const reply = try readCommandResponseRequest(.{ .io = std.testing.io }, sockets[0], &buffer, timing, null);
    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("{}", reply.body);
}

test "Host processing wait does not consume response transfer inactivity" {
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
    defer closeTestDescriptor(sockets[1]);
    try writeAll(sockets[1], empty_test_response[0..1]);
    var late: LateRest = undefined;
    try late.start(sockets[1], empty_test_response[1..]);
    defer late.finish();
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
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\nx",
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
        const bytes = try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n{s}\r\n", .{fields});
        try writeAll(sockets[1], bytes);
        try std.testing.expectError(error.InvalidResponse, readResponseHead(sockets[0]));
    }
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    defer closeTestDescriptor(sockets[1]);
    try writeAll(sockets[1], "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 00\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nX-Extra: one\r\nx-extra: two\r\n\r\n");
    try std.testing.expectEqual(@as(u16, 200), (try readResponseHead(sockets[0])).status);
}

test "client activity peer boundary rejects noncanonical IDs and owns canonical labels" {
    for ([_][]const u8{ "k7m2qx", "09azvw", "", "short", "1234567", "K7m2qx", "k7m2qi", "k7m2ql", "k7m2qo", "k7m2qu", "k7\x00qx", "雪雪", "old/name", "01234567-89ab-4cde-8012-3456789abcde" }, 0..) |session, index| {
        var body: protocol.RequestBuffer = .{};
        try body.append("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"full\",\"since\":null,\"end\":\"1\",\"direction\":\"forward\",\"items\":[{\"position\":\"1\",\"ordinal\":\"0\",\"at\":\"1\",\"value\":{\"send_failed\":{\"key\":\"key\\u0000雪\",\"target\":{\"session\":");
        try body.appendJsonString(session);
        try body.append("},\"code\":\"invalid_sender_handle\"}}}],\"more\":false,\"call_activity\":{\"total\":\"0\",\"entries\":[]},\"queued\":{\"count\":\"0\",\"oldest_position\":\"0\",\"newest_admission\":\"0\",\"newest_position\":\"0\",\"newest_content\":null},\"work\":{\"creator\":null,\"read_version\":\"00000000000000000000000000000000.0\",\"state\":{\"kind\":\"idle\",\"since\":\"1\"},\"turn\":null,\"operation\":null,\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null},\"revision\":\"1\",\"workspace\":\"/w\"}}");
        if (index < 2) {
            const page = try protocol_reply.ActivityPage.parse(body.slice(), .{});
            @memset(body.bytes[0..body.len], 'x');
            try std.testing.expectEqualStrings(session, page.facts.items[0].value.send_failed.target.?.session.slice());
            try std.testing.expectEqualStrings("key\x00雪", page.facts.items[0].value.send_failed.key.slice());
        } else try std.testing.expectError(error.InvalidResponse, protocol_reply.ActivityPage.parse(body.slice(), .{}));
    }
}

test "client failed-send target is required and nullable without relaxing peers" {
    const cases = [_]struct { field: []const u8, failure: ?anyerror }{
        .{ .field = "\"target\":null,", .failure = null },
        .{ .field = "\"target\":{\"session\":\"absent\",\"label\":\"Review\"},", .failure = null },
        .{ .field = "", .failure = error.InvalidActivityPage },
        .{ .field = "\"target\":\"\",", .failure = error.InvalidActivityPage },
        .{ .field = "\"target\":false,", .failure = error.InvalidActivityPage },
        .{ .field = "\"target\":{},", .failure = error.InvalidActivityPage },
        .{ .field = "\"target\":{\"session\":null},", .failure = error.InvalidActivityPage },
        .{ .field = "\"target\":{\"session\":\"\",\"label\":null},", .failure = error.InvalidResponse },
        .{ .field = "\"target\":{\"session\":\"absent\",\"label\":\"bad\\nlabel\"},", .failure = error.InvalidResponse },
    };
    for (cases, 0..) |case, index| {
        var body: protocol.RequestBuffer = .{};
        try body.append("{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\",\"delta\":\"full\",\"since\":null,\"end\":\"1\",\"direction\":\"forward\",\"items\":[{\"position\":\"1\",\"ordinal\":\"0\",\"at\":\"1\",\"value\":{\"send_failed\":{\"key\":\"refused\",");
        try body.append(case.field);
        try body.append("\"code\":\"unsupported_reasoning_effort\"}}}],\"more\":false,\"call_activity\":{\"total\":\"0\",\"entries\":[]},\"queued\":{\"count\":\"0\",\"oldest_position\":\"0\",\"newest_admission\":\"0\",\"newest_position\":\"0\",\"newest_content\":null},\"work\":{\"creator\":null,\"read_version\":\"00000000000000000000000000000000.0\",\"state\":{\"kind\":\"idle\",\"since\":\"1\"},\"turn\":null,\"operation\":null,\"first_action\":null,\"attention\":null,\"group\":\"done\",\"actions\":{\"stop\":false,\"interrupt\":null,\"decide\":null},\"revision\":\"1\",\"workspace\":\"/w\"}}");
        if (case.failure) |failure| {
            try std.testing.expectError(failure, protocol_reply.ActivityPage.parse(body.slice(), .{}));
            continue;
        }
        const page = try protocol_reply.ActivityPage.parse(body.slice(), .{});
        @memset(body.bytes[0..body.len], 'x');
        const failed = page.facts.items[0].value.send_failed;
        try std.testing.expectEqualStrings("refused", failed.key.slice());
        try std.testing.expectEqualStrings("unsupported_reasoning_effort", failed.code.slice());
        if (index == 0) {
            try std.testing.expect(failed.target == null);
        } else {
            try std.testing.expectEqualStrings("absent", failed.target.?.session.slice());
            try std.testing.expectEqualStrings("Review", failed.target.?.label.slice());
        }
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
        try std.testing.expectError(error.InvalidTarget, requests.readAction("/never-open", session, 1, 0, 0, file, &reply));
        try std.testing.expectError(error.InvalidTarget, requests.readActionArguments("/never-open", session, 1, file, &reply));
        try std.testing.expectError(error.InvalidTarget, requests.readActionCallId("/never-open", session, 1, file, &reply));
        try std.testing.expectError(error.InvalidSession, requests.conversationPage("/never-open", session, .{ .end = 0 }));
        try std.testing.expectError(error.InvalidSession, requests.readConversationContent("/never-open", session, 1, 0, null, file));
        try std.testing.expectError(error.InvalidSession, requests.activityPage("/never-open", session, .{}));
        try std.testing.expectError(error.InvalidSession, requests.readActivityContent("/never-open", session, 1, 0, null, file));
    }
    for ([_]u64{ 0, std.math.maxInt(u64) }) |action_id| {
        try std.testing.expectError(error.InvalidTarget, requests.readAction("/never-open", "k7m2qx", action_id, 0, 0, file, &reply));
    }
    try std.testing.expectError(error.InvalidTarget, requests.readAction("/never-open", "k7m2qx", 1, protocol.max_sqlite_content_bytes + 1, 0, file, &reply));
    try std.testing.expectEqual(@as(u64, 0), try file.length(std.testing.io));
}

test "a model list without a Host to answer it fails before any parse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const store = path[0..try tmp.dir.realPath(std.testing.io, &path)];
    const requests: Requests = .{ .io = std.testing.io };
    try std.testing.expect(if (requests.modelList(store, std.testing.allocator)) |_| false else |_| true);
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
                .session_archive => captureSessionArchive(io, .{ .store = root, .session = session }, target),
                .session_pin => captureSessionPin(io, .{ .store = root, .session = session, .pinned = true }, target),
                .model_interruption => captureModelInterruption(io, .{ .store = root, .session = session, .turn_id = 1, .operation_id = 1 }, target),
                .permission_decision => capturePermissionDecision(io, .{ .store = root, .session = session, .action_id = 1 }, target),
                .action_background => captureActionBackground(io, .{ .store = root, .session = session, .action_id = 1 }, target),
                .action_stop => captureActionStop(io, .{ .store = root, .session = session, .action_id = 1 }, target),
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
            if (kind != .configure or session.len != 0) {
                var body: protocol.RequestBuffer = .{};
                try body.appendFmt("{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"{s}\",\"store\":", .{@tagName(kind)});
                try body.appendJsonString(root);
                try body.append(",\"key\":\"" ++ handle ++ "\",");
                try body.append(if (kind == .model_interruption) "\"target\":{\"session\":" else "\"session\":");
                try body.appendJsonString(session);
                try body.append(switch (kind) {
                    .configure => ",\"configuration\":{}}",
                    .message => ",\"text\":{\"state\":\"value\",\"value\":\"input\\u0000雪\"}}",
                    .session_stop => "}",
                    .session_archive => ",\"archived\":true}",
                    .session_pin => ",\"pinned\":true}",
                    .model_interruption => ",\"turn\":\"1\",\"operation\":\"1\"}}",
                    .permission_decision => ",\"action\":\"1\",\"decision\":\"deny\"}",
                    .action_background, .action_stop => ",\"action\":\"1\"}",
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

fn checkCreatingMessageCapture() !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_]bool{ false, true }) |require_model| {
        var captured = try captureMessage(io, .{
            .store = root,
            .session = "",
            .text_path = "",
            .text = "hello",
            .configuration = .{
                .store = root,
                .session = .create,
                .model = .{ .present = true, .value = "custom" },
                .tools = .{ .cli = "none" },
                .permission_mode = .{ .present = true, .value = "ask" },
                .compaction_trigger = .{ .present = true, .value = "1000" },
                .reasoning_effort = .{ .present = true, .value = "low" },
                .require_model = require_model,
            },
        }, .{ .generated = root }).get();
        defer captured.close(io);
        _ = try readCapturedBinding(io, &captured.file);
        var bytes: [4096]u8 = undefined;
        const length = try captured.file.readPositionalAll(io, &bytes, 0);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..length], .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqualStrings("", object.get("session").?.string);
        try std.testing.expect(object.get("sender").? == .null);
        try std.testing.expectEqualStrings("custom", object.get("configuration").?.object.get("model").?.string);
        try std.testing.expectEqualStrings("hello", object.get("text").?.object.get("value").?.string);
        try std.testing.expectEqual(require_model, object.contains("require_model"));
        if (require_model) try std.testing.expect(object.get("require_model").?.bool);
    }
}

fn checkAddressedMessageCapture() !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_]bool{ false, true }) |require_model| {
        var captured = try captureMessage(io, .{
            .store = root,
            .session = "k7m2qx",
            .text_path = "",
            .text = "hello",
            .require_model = require_model,
        }, .{ .generated = root }).get();
        defer captured.close(io);
        const binding = try readCapturedBinding(io, &captured.file);
        try std.testing.expectEqualStrings("k7m2qx", binding.saved.session.slice());
        var bytes: [4096]u8 = undefined;
        const length = try captured.file.readPositionalAll(io, &bytes, 0);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..length], .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expect(!object.contains("configuration"));
        try std.testing.expectEqual(require_model, object.contains("require_model"));
        if (require_model) try std.testing.expect(object.get("require_model").?.bool);
    }
}

fn checkCreatingConfigureCapture() !void {
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
        try std.testing.expectEqualStrings("", saved.session.slice());
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..count], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(saved.key.slice(), parsed.value.object.get("key").?.string);
        try std.testing.expectEqualStrings("", parsed.value.object.get("session").?.string);
        try std.testing.expect(parsed.value.object.get("require_model").?.bool);
        const settings = parsed.value.object.get("configuration").?.object;
        try std.testing.expectEqual(case.effort.present, settings.contains("effort"));
        if (case.effort.present) {
            if (case.effort.value) |_| try std.testing.expectEqualStrings("high", settings.get("effort").?.string) else try std.testing.expect(settings.get("effort").? == .null);
        }
        if (trigger != null) {
            try std.testing.expectEqual(@as(i64, 100000), settings.get("compactAt").?.integer);
            try std.testing.expectEqual(@as(i64, 16384), settings.get("outputReservation").?.integer);
        } else {
            try std.testing.expect(settings.get("compactAt").? == .null);
            try std.testing.expect(settings.get("outputReservation").? == .null);
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
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, try requestPath(root, saved.key.slice(), &path), .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, " trailing", try file.length(io));
    try std.testing.expectEqualStrings("k7m2qx", (try inspectCaptured(io, root, saved.key.slice())).session.slice());
    try std.testing.expectError(error.InvalidRequestRecord, openCaptured(io, .{ .generated = .{ .directory = root, .handle = saved.key.slice() } }));
}

fn testResend(io: std.Io, saved: SavedRecord) !protocol_reply.MutationReply {
    var record = try openCaptured(io, saved);
    defer record.close(io);
    var reply: ReplyBuffer = .{};
    return (Requests{ .io = io }).sendCaptured(&record, .empty, &reply).get();
}

test "retry and generated recovery select captured mutations by kind" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const paths = try resolveClientPaths(io, root);
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

    try std.testing.expectError(error.RequestBindingMismatch, testResend(io, .{ .explicit = .{ .store = root, .record = stop_record, .kind = .model_interruption } }));
    try std.testing.expectError(error.FileNotFound, testResend(io, .{ .explicit = .{ .store = root, .record = stop_record, .kind = .session_stop } }));
    try std.testing.expectError(error.RequestBindingMismatch, testResend(io, .{ .explicit = .{ .store = root, .record = message_record, .kind = .permission_decision } }));
    try std.testing.expectError(error.FileNotFound, testResend(io, .{ .explicit = .{ .store = root, .record = message_record, .kind = .message } }));
}

test "peer Store address CLI validation accepts opaque ids and preserves SQLite paths" {
    const id = "0123456789abcdef0123456789abcdef";
    for ([_][]const u8{ id, "/", "/store", "/store with spaces/é" }) |store|
        try validatePeer(store, "k7m2qx", "handle");
    for ([_][]const u8{
        "",                "relative",                         "0123456789abcdef0123456789abcde",
        id ++ "0",         "0123456789ABCDEF0123456789abcdef", "g123456789abcdef0123456789abcdef",
        "/store/",         "/store//child",                    "/store/./child",
        "/store/../child", "/store\n",                         "/store\x7f",
    }) |store| try std.testing.expectError(error.InvalidRuiAddress, validatePeer(store, "k7m2qx", "handle"));
    try std.testing.expectError(error.InvalidUtf8, validatePeer("/store\xff", "k7m2qx", "handle"));
    try std.testing.expectError(error.InvalidRuiAddress, validatePeer(id, "INVALID", "handle"));
    try std.testing.expectError(error.InvalidSenderHandle, validatePeer(id, "k7m2qx", &@as([protocol.max_sender_handle_bytes + 1]u8, @splat('x'))));
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
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"{0s}\",\"key\":\"k\",\"session\":\"target\",\"sender\":{{\"store\":\"{0s}\",\"session\":\"k7m2qx\"}},\"sender_handle\":\"0123456789abcdef0123456789abcdef\",\"text\":{{\"state\":\"value\",\"value\":\"x\"}}}}", .{root});
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
        try std.testing.expectError(error.FileNotFound, (Requests{ .io = io }).sendCaptured(&generated, .empty, &reply).get());
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
    var captured = try captureMessage(io, .{ .store = root, .session = "k7m2qx", .text_path = "", .text = "x" }, .{ .generated = root }).get();
    defer captured.close(io);
    var reply: ReplyBuffer = .{};
    const failure = (Requests{ .io = io }).sendCaptured(&captured, .empty, &reply).failed;
    try std.testing.expectEqual(@as(?Step, .connect), failure.step);
    try std.testing.expect(!failure.step.?.mayHaveReachedHost());
    const stop: Cancellation = .{ .stopped = .init(true) };
    const cancelled = (Requests{ .io = io, .cancellation = &stop }).sendCaptured(&captured, .empty, &reply).failed;
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
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"{s}\",\"key\":\"owned-key\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"text\":{{\"state\":\"value\",\"value\":\"{s}\"}}}}", .{ root, text });
    var vtable = io.vtable.*;
    vtable.netConnectUnix = Peer.connect;
    const connected_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]Peer.Response{ .closed, .silent, .reply }) |response| {
        const sockets = try socketPair();
        Peer.client_fd = sockets[0];
        Peer.failure = null;
        const peer = try std.Thread.spawn(.{}, Peer.serve, .{ sockets[1], expected, response });
        var buffer: ReplyBuffer = .{};
        // Only the silent Host tests the wait; a short one elsewhere lets a
        // stalled close or reply read as silence (#1989).
        const timing: ResponseTiming = if (response == .silent) .{ .inactivity_ms = 200, .wait_for_first_byte = false } else .mutation;
        const sent = (Requests{ .io = connected_io, .mutation_timing = timing }).sendCaptured(&captured, .empty, &buffer);
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

test "a Message uploads its environment ahead of the unchanged record and other mutations carry none" {
    const Peer = struct {
        var client_fd: std.posix.fd_t = undefined;
        var connects: usize = 0;
        var head: [512]u8 = undefined;
        var head_len: usize = 0;
        var body: [8192]u8 = undefined;
        var body_len: usize = 0;
        var failure: ?anyerror = null;
        fn connect(_: ?*anyopaque, _: *const std.Io.net.UnixAddress) std.Io.net.UnixAddress.ConnectError!std.Io.net.Socket.Handle {
            connects += 1;
            return client_fd;
        }
        fn serve(fd: std.posix.fd_t) void {
            exchange(fd) catch |err| {
                failure = err;
            };
        }
        fn exchange(fd: std.posix.fd_t) !void {
            defer closeTestDescriptor(fd);
            head_len = 0;
            while (!std.mem.endsWith(u8, head[0..head_len], "\r\n\r\n")) {
                if (head_len == head.len) return error.TestRequestHeadTooLarge;
                if (std.posix.system.read(fd, head[head_len..].ptr, 1) != 1) return error.TestRequestTruncated;
                head_len += 1;
            }
            const marker = "Content-Length: ";
            const start = (std.mem.indexOf(u8, head[0..head_len], marker) orelse return error.TestMissingLength) + marker.len;
            const length = try std.fmt.parseInt(usize, head[start..std.mem.indexOfScalarPos(u8, head[0..head_len], start, '\r').?], 10);
            if (length > body.len) return error.TestRequestTooLarge;
            body_len = 0;
            while (body_len < length) {
                const n = std.posix.system.read(fd, body[body_len..length].ptr, length - body_len);
                if (n <= 0) return error.TestRequestTruncated;
                body_len += @intCast(n);
            }
            try writeAll(fd, empty_test_response);
        }
        fn send(io: std.Io, captured: *CapturedRecord, environment: Environment) !Stepped(MutationSendError, protocol_reply.MutationReply) {
            const sockets = try socketPair();
            client_fd = sockets[0];
            failure = null;
            const peer = try std.Thread.spawn(.{}, serve, .{sockets[1]});
            var buffer: ReplyBuffer = .{};
            const sent = (Requests{ .io = io }).sendCaptured(captured, environment, &buffer);
            peer.join();
            if (failure) |err| return err;
            return sent;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/message", .{root});
    var vtable = io.vtable.*;
    vtable.netConnectUnix = Peer.connect;
    const connected_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("CLIENT_MARK", "distinctive-7f3a\xe9");
    try map.put("RUI_STORE", "/elsewhere");
    try map.put("B", "x=y");
    const environment: Environment = .{ .map = &map };
    const entries = "CLIENT_MARK=distinctive-7f3a\xe9\x00B=x=y\x00";
    try std.testing.expectEqual(@as(u64, entries.len), environment.bytes());

    var captured = try captureMessage(io, .{ .store = root, .session = "k7m2qx", .text_path = "", .text = "run it" }, .{ .explicit = .{ .record = path, .key = "environment-key" } }).get();
    defer captured.close(io);
    const record = try tmp.dir.readFileAlloc(io, "message", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(record);
    _ = (try Peer.send(connected_io, &captured, environment)).get() catch {};
    var expected_head: [128]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, Peer.head[0..Peer.head_len], try std.fmt.bufPrint(&expected_head, "Content-Length: {d}\r\n", .{entries.len + record.len})) != null);
    try std.testing.expect(std.mem.indexOf(u8, Peer.head[0..Peer.head_len], try std.fmt.bufPrint(&expected_head, "X-Rui-Environment-Bytes: {d}\r\n", .{entries.len})) != null);
    try std.testing.expectEqualStrings(entries, Peer.body[0..entries.len]);
    try std.testing.expectEqualSlices(u8, record, Peer.body[entries.len..Peer.body_len]);
    const saved = try tmp.dir.readFileAlloc(io, "message", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualSlices(u8, record, saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "distinctive-7f3a") == null);

    const large = try std.testing.allocator.alloc(u8, protocol.max_environment_bytes);
    defer std.testing.allocator.free(large);
    @memset(large, 'v');
    try map.put("LARGE", large);
    try map.put("MIDDLE", large[0..300]);
    try map.put("SMALL", large[0..200]);
    const connects = Peer.connects;
    var buffer: ReplyBuffer = .{};
    const refused = (Requests{ .io = connected_io }).sendCaptured(&captured, environment, &buffer).failed;
    try std.testing.expectEqual(error.EnvironmentTooLarge, refused.err);
    try std.testing.expectEqual(@as(?Step, null), refused.step);
    try std.testing.expectEqual(connects, Peer.connects);
    const largest = environment.largest();
    try std.testing.expectEqualStrings("LARGE", largest[0].?);
    try std.testing.expectEqualStrings("MIDDLE", largest[1].?);
    try std.testing.expectEqualStrings("SMALL", largest[2].?);
    var described: [Environment.too_large_bytes]u8 = undefined;
    var described_writer = std.Io.Writer.fixed(&described);
    try environment.describeTooLarge(&described_writer);
    try std.testing.expect(std.mem.endsWith(u8, described_writer.buffered(), "Largest variables: LARGE, MIDDLE, SMALL."));
    try std.testing.expect(std.mem.indexOf(u8, described_writer.buffered(), "over the 65536 a Message carries") != null);

    var stop = try captureSessionStop(io, .{ .store = root, .session = "k7m2qx" }, .{ .generated = root });
    defer stop.close(io);
    _ = (try Peer.send(connected_io, &stop, environment)).get() catch {};
    try std.testing.expect(std.mem.startsWith(u8, Peer.head[0..Peer.head_len], "POST /v1/control/session-stop HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, Peer.head[0..Peer.head_len], "X-Rui-Environment") == null);
    try std.testing.expectEqual(@as(u64, Peer.body_len), stop.length);
}

test "capture publication transfers original inode across pathname replacement" {
    const Replacement = struct {
        fn rename(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8) std.Io.Dir.RenamePreserveError!void {
            try std.testing.io.vtable.dirRenamePreserve(userdata, old_dir, old_path, new_dir, new_path);
            if (!std.mem.eql(u8, new_path, "record")) return;
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
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"{s}\",\"key\":\"original-key\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"text\":{{\"state\":\"value\",\"value\":\"original\\ntext\"}}}}", .{root});
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
        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            if (reader == -1) return std.testing.io.vtable.fileSync(userdata, file);
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
        Failure.reader = -1;
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
        var readers: [16]std.posix.fd_t = @splat(-1);
        fn open(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const file = try std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
            const slot = for (&readers) |*entry| {
                if (entry.* == -1) break entry;
            } else return error.Unexpected;
            slot.* = file.handle;
            opened += 1;
            return file;
        }
        fn close(userdata: ?*anyopaque, files: []const std.Io.File) void {
            for (files) |file| for (&readers) |*entry| {
                if (entry.* == file.handle) {
                    closed += 1;
                    entry.* = -1;
                    break;
                }
            };
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
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"session_stop\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"text\":{}}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"model_interruption\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"target\":{\"session\":\"k7m2qx\",\"turn\":\"x\",\"operation\":\"2\"}}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"other\",\"session\":\"k7m2qx\",\"text\":{}}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"unknown\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"text\":{}}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"text\":{\"state\":\"value\",\"value\":\"a\",\"val\\u0075e\":\"b\"}}",
        "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"text\":{\"state\":\"value\",\"value\":[97]}}",
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
        try std.testing.expect(std.mem.startsWith(u8, bytes[0..n], "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"configure\""));
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
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n{\"status\":\"error\"}",
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
    const escaped_since = @as([protocol_reply.SessionToken.max_bytes]u8, @splat(1));
    const session = "k7m2qx";
    const session_encoding_slack = 6 * protocol.max_session_bytes - session.len;
    const cases = .{
        .{ protocol.observe_command_request.all, .{ &escaped_store, &escaped_key, @as(?[]const u8, &escaped_since) }, protocol.max_observe_command_request_bytes },
        .{ protocol.read_result_request, .{ &escaped_store, &escaped_key }, protocol.max_read_result_request_bytes },
        .{ protocol.read_action_call_id_request, .{ &escaped_store, session, std.math.maxInt(u64) }, protocol.max_read_action_call_id_request_bytes - session_encoding_slack },
        .{ protocol.read_action_arguments_request, .{ &escaped_store, session, std.math.maxInt(u64) }, protocol.max_read_action_arguments_request_bytes - session_encoding_slack },
        .{ (protocol.inspect_session_request.head ++ protocol.inspect_session_request.failed_response ++ protocol.inspect_session_request.tail), .{ &escaped_store, session, protocol.FailedResponsePart.metadata, std.math.maxInt(u64), std.math.maxInt(u64) }, protocol.shapeBytes((protocol.inspect_session_request.head ++ protocol.inspect_session_request.failed_response ++ protocol.inspect_session_request.tail)) - session_encoding_slack },
        .{ (protocol.inspect_session_request.head ++ protocol.inspect_session_request.since ++ protocol.inspect_session_request.tail), .{ &escaped_store, session, @as(?[]const u8, &escaped_since) }, protocol.max_inspect_session_request_bytes - session_encoding_slack },
    };
    inline for (cases) |case| {
        var body: protocol.RequestBuffer = .{};
        try body.appendShape(case[0], case[1]);
        try std.testing.expectEqual(@as(usize, case[2]), body.len);
    }
    var inspection: protocol.RequestBuffer = .{};
    try inspection.appendShape((protocol.inspect_session_request.head ++ protocol.inspect_session_request.profile ++ protocol.inspect_session_request.tail), .{ &escaped_store, session });
    try std.testing.expect(inspection.len <= protocol.max_inspect_session_request_bytes);
    var full: protocol.RequestBuffer = .{};
    full.len = full.bytes.len;
    try std.testing.expectError(error.BufferTooLarge, full.append("x"));
}

test "configure metadata bound covers every optional member together" {
    const store = @as([protocol.max_store_bytes]u8, @splat(1));
    const key = @as([protocol.max_key_bytes]u8, @splat(1));
    const session = @as([protocol.max_session_bytes]u8, @splat(1));
    const preset = @as([protocol.max_preset_name_bytes]u8, @splat(1));
    var body: protocol.FixedJsonBuffer(protocol.configure_request.max_metadata_bytes + "{}".len) = .{};
    try body.appendShape(protocol.configure_request.head, .{ &store, &key, &session });
    try body.append("{}");
    try body.appendShape(protocol.configure_request.reload_skills, .{});
    try body.appendShape(protocol.configure_request.require_model, .{});
    try body.appendShape(protocol.configure_request.preset, .{&preset});
    try body.appendShape(protocol.configure_request.tail, .{});
    try std.testing.expectEqual(protocol.configure_request.max_metadata_bytes + "{}".len, body.len);
    try std.testing.expect(try std.json.validate(std.testing.allocator, body.slice()));
}

test "every request renders its exact worst-case bound from the shape it writes" {
    const store = @as([protocol.max_store_bytes]u8, @splat(1));
    const key = @as([protocol.max_key_bytes]u8, @splat(1));
    const session = @as([protocol.max_session_bytes]u8, @splat(1));
    const workspace = @as([protocol.max_workspace_bytes]u8, @splat(1));
    const token = @as([protocol.SinceToken.max_bytes]u8, @splat('9'));
    const observation_token = @as([protocol_reply.SessionToken.max_bytes]u8, @splat(1));
    const reference = @as([protocol.session_id_bytes]u8, @splat(1));
    const skill_prefix = @as([64]u8, @splat(1));
    const search_query = @as([256]u8, @splat(1));
    const id: u64 = std.math.maxInt(u64);
    const optional_id: ?u64 = std.math.maxInt(u64);
    const Direction = @FieldType(protocol.ActivityPage, "direction");
    const cases = .{
        .{ protocol.session_stop_request, .{ &store, &key, &session }, protocol.max_session_stop_request_bytes },
        .{ protocol.session_archive_request.all, .{ &store, &key, &session, false }, protocol.max_session_archive_request_bytes },
        .{ protocol.session_pin_request.all, .{ &store, &key, &session, false }, protocol.max_session_pin_request_bytes },
        .{ protocol.model_interruption_request, .{ &store, &key, &session, id, id }, protocol.max_model_interruption_request_bytes },
        .{ protocol.permission_decision_request, .{ &store, &key, &session, id, protocol.PermissionDecision.allow_once }, protocol.max_permission_decision_request_bytes },
        .{ protocol.action_background_request, .{ &store, &key, &session, id }, protocol.max_action_background_request_bytes },
        .{ protocol.observe_command_request.all, .{ &store, &key, @as(?[]const u8, &observation_token) }, protocol.max_observe_command_request_bytes },
        .{ protocol.host_info_request, .{&store}, protocol.max_host_info_request_bytes },
        .{ protocol.host_stop_request, .{&store}, comptime protocol.shapeBytes(protocol.host_stop_request) },
        .{ protocol.host_drain_request, .{ &store, id }, protocol.max_host_stop_request_bytes },
        .{ protocol.read_result_request, .{ &store, &key }, protocol.max_read_result_request_bytes },
        .{ (protocol.inspect_session_request.head ++ protocol.inspect_session_request.failed_response ++ protocol.inspect_session_request.tail), .{ &store, &session, protocol.FailedResponsePart.metadata, id, id }, comptime protocol.shapeBytes((protocol.inspect_session_request.head ++ protocol.inspect_session_request.failed_response ++ protocol.inspect_session_request.tail)) },
        .{ (protocol.inspect_session_request.head ++ protocol.inspect_session_request.since ++ protocol.inspect_session_request.tail), .{ &store, &session, @as(?[]const u8, &observation_token) }, comptime protocol.shapeBytes((protocol.inspect_session_request.head ++ protocol.inspect_session_request.since ++ protocol.inspect_session_request.tail)) },
        .{ protocol.list_sessions_request.all, .{ &store, @as(?[]const u8, &workspace), protocol.SessionArchiveFilter.archived, id, id, &token, id, &reference }, protocol.max_list_sessions_request_bytes },
        .{ protocol.read_action_arguments_request, .{ &store, &session, id }, protocol.max_read_action_arguments_request_bytes },
        .{ protocol.read_action_call_id_request, .{ &store, &session, id }, protocol.max_read_action_call_id_request_bytes },
        .{ protocol.conversation_content_request.all, .{ &store, &session, id, id }, protocol.max_conversation_content_request_bytes },
        .{ protocol.conversation_page_request, .{ &store, &session, id, id, id }, protocol.max_conversation_page_request_bytes },
        .{ (protocol.activity_page_request.head ++ protocol.activity_page_request.tail), .{ &store, &session, optional_id, id, optional_id, Direction.backward, protocol.ActivityPage.Kinds.full, id }, comptime protocol.shapeBytes(protocol.activity_page_request.head ++ protocol.activity_page_request.tail) },
        .{ protocol.activity_page_request.all, .{ &store, &session, optional_id, id, optional_id, Direction.backward, protocol.ActivityPage.Kinds.full, id, @as(?[]const u8, &observation_token) }, protocol.max_activity_page_request_bytes },
        .{ protocol.activity_search_request.all, .{ &store, &session, &search_query, protocol.ActivityPage.Kinds.full, optional_id, optional_id, id }, protocol.max_activity_search_request_bytes },
        .{ protocol.activity_content_request, .{ &store, &session, id, id }, protocol.max_activity_content_request_bytes },
        .{ protocol.skill_suggestions_session_request, .{ &store, &session, &skill_prefix }, comptime protocol.shapeBytes(protocol.skill_suggestions_session_request) },
        .{ protocol.skill_suggestions_workspace_request, .{ &store, &workspace, &skill_prefix }, comptime protocol.shapeBytes(protocol.skill_suggestions_workspace_request) },
        .{ protocol.model_list_request, .{&store}, protocol.max_model_list_request_bytes },
    };
    var largest: usize = 0;
    inline for (cases, 0..) |case, index| {
        var body: protocol.FixedJsonBuffer(case[2]) = .{};
        try body.appendShape(case[0], case[1]);
        try std.testing.expectEqual(@as(usize, case[2]), body.len);
        try std.testing.expect(try std.json.validate(std.testing.allocator, body.slice()));
        if (index >= 6) largest = @max(largest, body.len);
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
    inline for (comptime std.meta.tags(protocol.SessionArchiveFilter)) |archive| inline for (cases) |case| {
        var body: protocol.RequestBuffer = .{};
        try appendListSessions(&body, "/store", null, archive, case[0]);
        var expected: [512]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"list_sessions\",\"store\":\"/store\",\"workspace\":null,\"archive\":\"{s}\",\"after\":\"{d}\",\"ceiling\":\"{d}\"{s}}}", .{ @tagName(archive), case[0].after, case[0].ceiling, case[1] }), body.slice());
    };
    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const escaped_workspace = @as([protocol.max_workspace_bytes]u8, @splat(1));
    var maximum: protocol.RequestBuffer = .{};
    try appendListSessions(&maximum, &escaped_store, &escaped_workspace, .active, .{ .since = .{ .instance = @splat(0xff), .generation = std.math.maxInt(u64) }, .changed = .{ .through = std.math.maxInt(u64), .after_reference = "zzzzzz".* } });
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
    try paths.store_identity.set(&escaped_store);

    var stop_path_buffer: [protocol.max_store_bytes + "/records/stop-record".len]u8 = undefined;
    const stop_path = try std.fmt.bufPrint(
        &stop_path_buffer,
        "{s}/records/stop-record",
        .{root_buffer[0..root_length]},
    );
    var stop_capture = try writeSessionStopCapture(std.testing.io, &paths, .{
        .store = "unused",
        .session = session,
    }, .{ .record = stop_path, .key = &escaped_key, .replay = .{ .explicit = .{ .record = stop_path } } });
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
    }, .{ .record = interruption_path, .key = &escaped_key, .replay = .{ .explicit = .{ .record = interruption_path } } });
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
    try permission_capture.writePermissionDecision(paths.store_identity.slice(), &escaped_key, .{
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
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n{}",
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
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n",
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

test "runtime catalog model list client accepts a reply larger than its shipped snapshot bound" {
    const allocator = std.testing.allocator;
    const count = protocol.model_list_reply.max_bytes / protocol.max_model_bytes + 1;
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    try body.writer.writeAll(protocol.model_list_reply.head);
    try body.writer.writeAll("[{\"provider\":\"codex\",\"source\":\"catalog\",\"models\":[");
    for (0..count) |index| {
        var digits_buffer: [20]u8 = undefined;
        const digits = try std.fmt.bufPrint(&digits_buffer, "{d}", .{index});
        try body.writer.print("{s}{{\"id\":\"", .{if (index == 0) "" else ","});
        try body.writer.splatByteAll('0', protocol.max_model_bytes - digits.len);
        try body.writer.print("{s}\",\"known\":true}}", .{digits});
    }
    try body.writer.writeAll("]}]");
    try body.writer.writeAll(protocol.model_list_reply.tail);
    try std.testing.expect(body.written().len > protocol.model_list_reply.max_bytes);
    const response = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n{s}",
        .{ body.written().len, body.written() },
    );
    defer allocator.free(response);
    const descriptors = try testPipe();
    const Peer = struct {
        fd: std.posix.fd_t,
        response: []const u8,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            writeTestResponse(self.fd, self.response) catch |err| {
                self.failure = err;
            };
        }
    };
    var peer: Peer = .{ .fd = descriptors[1], .response = response };
    const thread = try std.Thread.spawn(.{}, Peer.run, .{&peer});
    var joined = false;
    defer {
        closeTestDescriptor(descriptors[0]);
        if (!joined) thread.join();
    }
    const received = try readModelListResponse(.{ .io = std.testing.io }, descriptors[0], allocator);
    defer allocator.free(received);
    thread.join();
    joined = true;
    try std.testing.expect(peer.failure == null);
    try std.testing.expectEqualStrings(body.written(), received);
    var menu = try @import("model_picker.zig").read(allocator, try protocol_reply.modelListProviders(received));
    defer menu.deinit(allocator);
    try std.testing.expectEqual(count, menu.entries.len);
    for (menu.entries) |entry| try std.testing.expect(entry.known);
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
    try writeAll(fd, try std.fmt.bufPrint(&buffer, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nX-Rui-Content-Bytes: {d}\r\nX-Rui-Next-Offset: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{ length, length, length }));
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
        const reply = try readFirstLine(.{ .io = std.testing.io }, descriptors[0], null, &buffer);
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
    const reply = readFirstLine(.{ .io = std.testing.io }, sockets[0], null, &buffer);
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
        try writeAll(descriptors[1], try std.fmt.bufPrint(&head, "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n", .{body.len}));
        try writeAll(descriptors[1], body.slice());
    }
    var buffer: [4096]u8 = undefined;
    const reply = try readFirstLine(.{ .io = std.testing.io }, descriptors[0], null, &buffer);
    try std.testing.expectEqual(@as(u16, 409), reply.failure.status);
    try std.testing.expect(reply.failure.diagnostic.code.eql("ContentNotFound"));
}

test "read result returns bounded command errors without touching destination" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    try writeTestResponse(
        descriptors[1],
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\n{\"status\":\"error\"}",
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
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 4\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\nab",
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
    try std.testing.expectEqual(@as(u64, 0), try destination.length(std.testing.io));
}

test "result body publishes nothing unless EOF follows the advertised bytes" {
    inline for (.{ "Content-Length: 2\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\nabX", "Content-Length: 0\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\nX" }) |tail| {
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
    var captured: CapturedRecord = .{ .file = .{ .handle = -1, .flags = .{ .nonblocking = false } }, .length = 0, .saved = .{ .kind = .configure }, .target = .configure, .replay = .generated, .routing = .{} };
    try captured.saved.store.set("/never-open");
    var buffer: ReplyBuffer = .{};
    try std.testing.expectError(error.Cancelled, requests.sendCaptured(&captured, .empty, &buffer).get());
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), captured.file.handle);
    const file = captured.file;
    const address = try protocol_reply.MessageAddress.init("/never-open", "k7m2qx", "k");
    var observation_buffer: ObservationBuffer = .{};
    try std.testing.expectError(error.Cancelled, requests.observeCommand("/never-open", "k", null, &observation_buffer));
    try std.testing.expectError(error.Cancelled, requests.observeMessage(&address));
    try std.testing.expectError(error.Cancelled, requests.readResult("/never-open", "k", file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.readResultStream("/never-open", "k", file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.inspectSession("/never-open", "s", .current, file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.listSessions("/never-open", null, .{}, file, &buffer));
    try std.testing.expectError(error.Cancelled, requests.readAction("/never-open", "s", 1, 0, 0, file, &buffer));
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
            _ = self.requests.sendCaptured(self.captured, .empty, &reply).get() catch |err| {
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
    var endpoint = try host_endpoint.claim(io, try .init(std.fs.path.dirname(paths.socket.slice()).?));
    defer endpoint.retire() catch @panic("unable to retire fixture endpoint");
    var listener = try endpoint.listen(.{});
    defer listener.deinit(io);
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
        var endpoint = try host_endpoint.claim(io, try .init(std.fs.path.dirname(paths.socket.slice()).?));
        defer endpoint.retire() catch @panic("unable to retire fixture endpoint");
        var listener = try endpoint.listen(.{});
        defer listener.deinit(io);
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
        try writeAll(peer.socket.handle, try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\n\r\na", .{ content_type, length }));
        if (kind == .result) try std.testing.expectEqual(socket_os.Shutdown.done, socket_os.shutdown(peer.socket.handle, std.c.SHUT.WR));
        try test_poll.waitUntil(io, test_poll.after(io, .fromSeconds(1)), &worker.sink.entered, test_poll.isSet);
        token.requestStop();
        try std.testing.expect(!worker.done.load(.acquire));
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
    const blocks = @import("os").full_backlog_blocks_connect;
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
    try std.testing.expectEqual(if (blocks) error.TransferInactive else error.ConnectionRefused, blocked);
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
    try std.testing.expectError(if (blocks) error.Cancelled else error.ConnectionRefused, stopped);
}

test "a stopped Host's socket fails requests only in ways hostUnreachable names" {
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    var address_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const address = try tmp.address("socket", &address_buffer);
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
    for (0..2) |stale| {
        if (stale == 1) {
            var listener = try address.listen(io, .{});
            listener.deinit(io);
        }
        for ([_]?i128{ null, until }) |deadline| {
            const fd = connectRequest(.{ .io = io }, address, deadline) catch |err| {
                try std.testing.expect(hostUnreachable(err));
                continue;
            };
            closeTestDescriptor(fd);
            return error.TestUnexpectedResult;
        }
    }
    var sockets: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) return error.TestUnexpectedResult;
    defer closeTestDescriptor(sockets[0]);
    closeTestDescriptor(sockets[1]);
    const head = readResponseHeadUntil(.{ .io = io }, sockets[0], ResponseTiming.mutation, until);
    try std.testing.expect(hostUnreachable(if (head) |_| return error.TestUnexpectedResult else |err| err));
    try std.testing.expect(!hostUnreachable(error.AccessDenied));
}

test "a refused environment's reason fits its bound with the longest escaped names" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    const value = try std.testing.allocator.alloc(u8, protocol.max_environment_bytes);
    defer std.testing.allocator.free(value);
    @memset(value, 'v');
    const names = [_][]const u8{ &@as([40]u8, @splat(1)), &@as([40]u8, @splat(2)), &@as([40]u8, @splat(3)), "SMALLEST" };
    for (names, 0..) |name, index| try map.put(name, value[0 .. value.len - index]);
    const environment: Environment = .{ .map = &map };
    var buffer: [Environment.too_large_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try environment.describeTooLarge(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOfAny(u8, text, "\x01\x02\x03") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SMALLEST") == null);
    try std.testing.expect(std.mem.endsWith(u8, text, "\\x03."));
}

test "capture loaded tools uses the tools comma-list grammar" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_][]const u8{ "web_search,bash", "none" }) |names| {
        var captured = try captureConfigure(io, .{
            .store = root,
            .session = .create,
            .tools = .{ .cli = "bash,web_search" },
            .loaded_tools = .{ .cli = names },
        }, .{ .generated = root }).get();
        defer captured.close(io);
        var bytes: [2048]u8 = undefined;
        const length = try captured.file.readPositionalAll(io, &bytes, 0);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..length], .{});
        defer parsed.deinit();
        const chosen = parsed.value.object.get("configuration").?.object.get("loadedTools").?.array.items;
        if (std.mem.eql(u8, names, "none")) {
            try std.testing.expectEqual(@as(usize, 0), chosen.len);
        } else {
            try std.testing.expectEqual(@as(usize, 2), chosen.len);
            try std.testing.expectEqualStrings("bash", chosen[0].string);
            try std.testing.expectEqualStrings("web_search", chosen[1].string);
        }
    }
}

test "request wait maps actual protocol state and kind domains" {
    const policy = @import("request_wait.zig");
    for (std.enums.values(protocol.MessageRequestState)) |state| {
        const expected: ?WaitDisposition = switch (state) {
            .queued, .processing => null,
            .waiting_for_permission, .completed, .failed, .cancelled, .rejected => .done,
        };
        const observation: protocol_reply.CommandObservation = .{ .key = .{}, .status = .accepted, .kind = .message, .state = state };
        try std.testing.expectEqual(expected, policy.disposition(observation));
    }
    for (std.enums.values(protocol.CommandKind)) |kind| {
        const observation: protocol_reply.CommandObservation = .{ .key = .{}, .status = .accepted, .kind = kind, .state = .queued };
        try std.testing.expectEqual(@as(?WaitDisposition, if (kind == .message) null else .done), policy.disposition(observation));
    }
}

test "archive captures preserve archive and restore intent through generated and explicit recovery" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_]bool{ true, false }) |archived| {
        var captured = try captureSessionArchive(io, .{ .store = root, .session = "k7m2qx", .archived = archived }, .{ .generated = root });
        const identity = captured.saved;
        var original: [2048]u8 = undefined;
        const count = try captured.file.readPositionalAll(io, &original, 0);
        try std.testing.expectEqual(protocol.CommandKind.session_archive, identity.kind);
        try std.testing.expectEqual(archived, captured.target.session_archive.archived);
        captured.close(io);
        var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = identity.key.slice() } });
        try std.testing.expectEqual(archived, recovered.target.session_archive.archived);
        var replayed: [2048]u8 = undefined;
        const replayed_count = try recovered.file.readPositionalAll(io, &replayed, 0);
        try std.testing.expectEqualSlices(u8, original[0..count], replayed[0..replayed_count]);
        recovered.close(io);
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try requestPath(root, identity.key.slice(), &path_buffer);
        var explicit = try openCaptured(io, .{ .explicit = .{ .store = root, .record = path, .kind = .session_archive } });
        try std.testing.expectEqual(archived, explicit.target.session_archive.archived);
        explicit.close(io);
        try std.testing.expectEqual(protocol.CommandKind.session_archive, (try inspectCaptured(io, root, identity.key.slice())).kind);
        try std.testing.expectError(error.RequestBindingMismatch, openCaptured(io, .{ .explicit = .{ .store = root, .record = path, .kind = .session_stop } }));
    }
}

test "archive recovery preserves the protocol default and refuses ambiguous or malformed intent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const handle = "00000000-0000-4000-8000-000000000001";
    const cases = .{
        .{ "", @as(?bool, true) },
        .{ ",\"archived\":false", @as(?bool, false) },
        .{ ",\"archived\":null", @as(?bool, null) },
        .{ ",\"archived\":\"true\"", @as(?bool, null) },
        .{ ",\"archived\":true,\"archived\":false", @as(?bool, null) },
    };
    var route_buffer: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const route = try std.fmt.bufPrint(&route_buffer, "{{\"format\":1,\"host_directory\":\"{s}\",\"runtime_hint\":\"\"}}", .{root});
    try tmp.dir.writeFile(io, .{ .sub_path = handle ++ ".json.routing", .data = route, .flags = .{ .permissions = .fromMode(0o600) } });
    inline for (cases) |case| {
        var body: protocol.RequestBuffer = .{};
        try body.append("{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"session_archive\",\"store\":");
        try body.appendJsonString(root);
        try body.append(" ,\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\"");
        try body.append(case[0]);
        try body.append("}");
        const file = try tmp.dir.createFile(io, handle ++ ".json", .{});
        try file.writeStreamingAll(io, body.slice());
        file.close(io);
        if (case[1]) |expected| {
            var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = handle } });
            defer recovered.close(io);
            try std.testing.expectEqual(expected, recovered.target.session_archive.archived);
        } else try std.testing.expectError(error.InvalidRequestRecord, openCaptured(io, .{ .generated = .{ .directory = root, .handle = handle } }));
    }
}

test "skills typed captures preserve reload intent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var bytes: [4096]u8 = undefined;
    for ([_]bool{ false, true }) |reload_skills| {
        for ([_]bool{ false, true }) |require_model| {
            var captured = try captureConfigure(io, .{ .store = root, .session = .{ .named = "k7m2qx" }, .reload_skills = reload_skills, .require_model = require_model }, .{ .generated = root }).get();
            defer captured.close(io);
            _ = try readCapturedBinding(io, &captured.file);
            const length = try captured.file.readPositionalAll(io, &bytes, 0);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..length], .{});
            defer parsed.deinit();
            try std.testing.expectEqual(reload_skills, parsed.value.object.contains("reload_skills"));
            try std.testing.expectEqual(require_model, parsed.value.object.contains("require_model"));
            if (reload_skills) try std.testing.expect(parsed.value.object.get("reload_skills").?.bool);
            if (require_model) try std.testing.expect(parsed.value.object.get("require_model").?.bool);
        }
    }
}

test "inline skills native suggestion read rejects invalid scope before Store discovery" {
    const requests: Requests = .{ .io = std.testing.io };
    try std.testing.expectError(error.InvalidSession, requests.skillSuggestions(std.testing.allocator, "/never-open", .{ .session = "invalid" }, ""));
    try std.testing.expectError(error.InvalidWorkspace, requests.skillSuggestions(std.testing.allocator, "/never-open", .{ .workspace = "" }, ""));
    try std.testing.expectError(error.InvalidPrefix, requests.skillSuggestions(std.testing.allocator, "/never-open", .{ .session = "k7m2qx" }, &@as([65]u8, @splat('x'))));
}

test "inline skills Message records keep /name words as exact text and refuse a skills field" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const text = "/demo look at /tmp/etc 雪";
    var captured = try captureMessage(std.testing.io, .{ .store = root, .session = "k7m2qx", .text_path = "unused", .text = text }, .{ .generated = root }).get();
    defer captured.close(std.testing.io);
    const binding = try readCapturedBinding(std.testing.io, &captured.file);
    try std.testing.expectEqual(@as(u64, text.len), binding.target.message.bytes);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest(text), &binding.target.message.digest);
    const listed = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"message\",\"store\":\"/s\",\"key\":\"k\",\"session\":\"k7m2qx\",\"sender\":null,\"sender_handle\":null,\"skills\":[\"demo\"],\"text\":{\"state\":\"value\",\"value\":\"x\"}}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "listed.json", .data = listed });
    var file = try tmp.dir.openFile(std.testing.io, "listed.json", .{});
    defer file.close(std.testing.io);
    try std.testing.expectError(error.InvalidRequestRecord, readCapturedBinding(std.testing.io, &file));
}

test "Session settings client writes every setting and the Host parser preserves its value" {
    const session_settings = @import("session_settings.zig");
    const host_request = @import("wire_request.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    inline for (.{ .{ "instructions.txt", "Follow the test instructions." }, .{ "schema.json", "{}" } }) |input| {
        const file = try tmp.dir.createFile(io, input[0], .{});
        defer file.close(io);
        try file.writeStreamingAll(io, input[1]);
    }
    var instructions_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var schema_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var captured = try captureConfigure(io, .{
        .store = root,
        .session = .create,
        .workspace = .{ .present = true, .value = root },
        .provider = .{ .present = true, .value = "openai" },
        .model = .{ .present = true, .value = "gpt-5" },
        .instructions = .{ .state = .value, .path = try std.fmt.bufPrint(&instructions_path, "{s}/instructions.txt", .{root}) },
        .tools = .{ .cli = "bash,find_tools" },
        .loaded_tools = .{ .cli = "bash" },
        .permission_mode = .{ .present = true, .value = "ask" },
        .output_schema = .{ .state = .value, .path = try std.fmt.bufPrint(&schema_path, "{s}/schema.json", .{root}) },
        .compaction_trigger = .{ .present = true, .value = "1000" },
        .output_reservation = .{ .present = true, .value = "20" },
        .reasoning_effort = .{ .present = true, .value = "high" },
        .label = .{ .present = true, .value = "Every setting" },
    }, .{ .generated = root }).get();
    defer captured.close(io);
    var bytes: [8192]u8 = undefined;
    const length = try captured.file.readPositionalAll(io, &bytes, 0);
    const ingress = try std.testing.allocator.create(host_request.Ingress);
    defer std.testing.allocator.destroy(ingress);
    var retained: ?@import("named_scratch.zig").Owner = null;
    ingress.init(std.testing.allocator, .{ .io = io, .content_length = length, .scratch_path = root, .request_number = 1, .retained_scratch = &retained });
    defer ingress.deinit();
    try ingress.feed(bytes[0..length]);
    const request = try ingress.finish();
    defer request.removeTemporaryContent(io) catch unreachable;
    const configuration = &request.configure.configuration;
    var missing_buffer: [4096]u8 = undefined;
    var missing: std.Io.Writer = .fixed(&missing_buffer);
    inline for (session_settings.entries) |entry| {
        if (@field(configuration, entry.field).state != .value)
            try missing.print("{s}: ConfigureInput fixture / client.Capture.writeConfiguration / Host Parser\n", .{entry.field});
    }
    try std.testing.expectEqualStrings("", missing.buffered());
    try std.testing.expectEqualStrings(root, configuration.workspace.value.slice());
    try std.testing.expectEqualStrings("openai", configuration.provider.value.slice());
    try std.testing.expectEqualStrings("gpt-5", configuration.model.value.slice());
    try std.testing.expectEqualStrings("bash find_tools", configuration.tools.names.slice());
    try std.testing.expectEqualStrings("bash", configuration.loaded_tools.names.slice());
    try std.testing.expectEqualStrings("ask", configuration.permission_mode.value.slice());
    try std.testing.expectEqualStrings("1000", configuration.compaction_trigger.value.slice());
    try std.testing.expectEqualStrings("20", configuration.output_reservation.value.slice());
    try std.testing.expectEqualStrings("high", configuration.reasoning_effort.value.slice());
    try std.testing.expectEqualStrings("Every setting", configuration.label.value.slice());
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("Follow the test instructions."), &configuration.instructions.digest);
    try std.testing.expectEqualSlices(u8, &protocol.contentDigest("{}"), &configuration.output_schema.digest);
}

test "saved request wire mismatch refuses recovery before returning a captured owner" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const handle = "01234567-89ab-4cde-8012-3456789abcde";
    try tmp.dir.writeFile(io, .{ .sub_path = handle ++ ".json", .data = "{\"version\":\"" ++ protocol.previous_wire_version ++ "\",\"kind\":\"configure\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"k7m2qx\",\"configuration\":{}}" });
    try std.testing.expectError(error.SavedRequestWireVersionMismatch, openCaptured(io, .{ .generated = .{ .directory = root, .handle = handle } }));
}

test "schema file capture writes an object and refuses invalid input before publication" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const record = try std.fmt.bufPrint(&record_buffer, "{s}/record", .{root[0..root_len]});
    var source_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "{s}/source", .{root[0..root_len]});
    for ([_][]const u8{ "", "{invalid", "[]", "\"{}\"", "true", "{}false" }) |invalid| {
        try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = invalid });
        var buffer: [32]u8 = undefined;
        var capture = try Capture.open(io, record, &buffer);
        defer capture.abort();
        try std.testing.expectError(error.InvalidOutputSchema, capture.writeInputFile(source, protocol.max_sqlite_content_bytes, false, true));
        capture.abort();
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = " { \"type\" : \"object\" } \n" });
    var buffer: [32]u8 = undefined;
    var capture = try Capture.open(io, record, &buffer);
    defer capture.abort();
    try capture.writeInputFile(source, protocol.max_sqlite_content_bytes, false, true);
    try capture.commit();
    const saved = try tmp.dir.openFile(io, "record", .{});
    defer saved.close(io);
    var bytes: [64]u8 = undefined;
    const count = try saved.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", bytes[0..count]);
}

test "socket upgrade discovery never infers absence from missing stale backlog or unreadable peers" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    var buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const address = try tmp.address("discovery.sock", &buffer);
    try std.testing.expectEqual(error.FileNotFound, (try observeHostForUpgradeAtSocket(allocator, io, address.path, null, null)).unanswered);
    {
        var listener = try address.listen(io, .{ .kernel_backlog = 1 });
        defer listener.deinit(io);
        try std.testing.expectError(error.HostPeerNotServing, observeHostForUpgradeAtSocket(allocator, io, address.path, null, null));
        const unreadable = try listener.accept(io);
        unreadable.close(io);

        const blocks = @import("os").full_backlog_blocks_connect;
        var peers: [8]std.posix.fd_t = undefined;
        var count: usize = 0;
        defer for (peers[0..count]) |fd| closeTestDescriptor(fd);
        const blocked = while (count < peers.len) {
            const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
            peers[count] = connectRequest(.{ .io = io }, address, until) catch |err| break err;
            count += 1;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(if (blocks) error.TransferInactive else error.ConnectionRefused, blocked);
        if (blocks)
            try std.testing.expectError(error.TransferInactive, observeHostForUpgradeAtSocket(allocator, io, address.path, null, null))
        else
            try std.testing.expectEqual(error.ConnectionRefused, (try observeHostForUpgradeAtSocket(allocator, io, address.path, null, null)).unanswered);
    }
    const before = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    try std.testing.expectEqual(error.ConnectionRefused, (try observeHostForUpgradeAtSocket(allocator, io, address.path, null, null)).unanswered);
    try std.testing.expect(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - before >= 25 * std.time.ns_per_ms);
    try std.testing.expectError(error.TransferInactive, observeHostForUpgradeAtSocket(allocator, io, address.path, before - 1, null));
}

test "socket upgrade discovery shares one refusal window and settles an unanswered socket by its endpoint lock" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    var interface_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const interface = try std.fmt.bufPrint(&interface_buffer, "{s}/interface", .{tmp.root[0..tmp.root_len]});
    var endpoint = try host_endpoint.claim(io, try .init(interface));
    defer endpoint.retire() catch {};
    var socket_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const socket = try endpoint.socketPath(&socket_buffer);
    var listener = try endpoint.listen(.{});
    try std.testing.expectError(error.HostPeerNotServing, observeHostForUpgradeAtSocket(allocator, io, socket, null, null));
    listener.deinit(io);
    const refused_at = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    try std.testing.expectEqual(error.ConnectionRefused, (try observeHostForUpgradeAtSocket(allocator, io, socket, null, null)).unanswered);
    try std.testing.expect(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - refused_at >= refused_connect_retry_ns);
    // A census's shared window that has already closed buys no retry: a
    // refused socket answers at once, so such sockets cost one window.
    const shared_at = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    try std.testing.expectEqual(error.ConnectionRefused, (try observeHostForUpgradeAtSocket(allocator, io, socket, null, shared_at)).unanswered);
    try std.testing.expect(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - shared_at < 25 * std.time.ns_per_ms);

    var candidates: std.ArrayList(UpgradeCandidate) = .empty;
    defer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }
    // While its holder lives, an unanswered socket is a failure and stays.
    try candidates.append(allocator, .{ .socket = try allocator.dupe(u8, socket), .result = .{ .unanswered = error.ConnectionRefused } });
    settleUnansweredSockets(allocator, io, &candidates);
    try std.testing.expectEqual(error.ConnectionRefused, candidates.items[0].result.failed);
    _ = try std.Io.Dir.cwd().statFile(io, socket, .{ .follow_symlinks = false });
    // Once its holder is gone, the next look proves it dead and removes it.
    candidates.items[0].result = .{ .unanswered = error.ConnectionRefused };
    endpoint.held.?.lock.close(io);
    endpoint.held.?.dir.close(io);
    endpoint.held = null;
    settleUnansweredSockets(allocator, io, &candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.items.len);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, socket, .{ .follow_symlinks = false }));
}

test "pin captures preserve pin and unpin intent through generated and explicit recovery" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_]bool{ true, false }) |pinned| {
        var captured = try captureSessionPin(io, .{ .store = root, .session = "k7m2qx", .pinned = pinned }, .{ .generated = root });
        const identity = captured.saved;
        var original: [2048]u8 = undefined;
        const count = try captured.file.readPositionalAll(io, &original, 0);
        try std.testing.expectEqual(protocol.CommandKind.session_pin, identity.kind);
        try std.testing.expectEqual(pinned, captured.target.session_pin.pinned);
        captured.close(io);
        var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = identity.key.slice() } });
        try std.testing.expectEqual(pinned, recovered.target.session_pin.pinned);
        var replayed: [2048]u8 = undefined;
        const replayed_count = try recovered.file.readPositionalAll(io, &replayed, 0);
        try std.testing.expectEqualSlices(u8, original[0..count], replayed[0..replayed_count]);
        recovered.close(io);
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try requestPath(root, identity.key.slice(), &path_buffer);
        var explicit = try openCaptured(io, .{ .explicit = .{ .store = root, .record = path, .kind = .session_pin } });
        try std.testing.expectEqual(pinned, explicit.target.session_pin.pinned);
        explicit.close(io);
        try std.testing.expectEqual(protocol.CommandKind.session_pin, (try inspectCaptured(io, root, identity.key.slice())).kind);
        try std.testing.expectError(error.RequestBindingMismatch, openCaptured(io, .{ .explicit = .{ .store = root, .record = path, .kind = .session_stop } }));
    }
}

test "upgrade public status decodes readiness without assuming the target wire" {
    const allocator = std.testing.allocator;
    const bytes = "{\"version\":\"future\",\"type\":\"host_status\",\"status\":\"ready\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"store\":\"/host\",\"active_capacity\":\"3\",\"future_field\":true}";
    const facts = (try parseUpgradeStatus(allocator, bytes)).?;
    try std.testing.expectEqual(@as(usize, 3), facts.active_capacity);
    try std.testing.expectEqualStrings("/host", facts.store.slice());
    try std.testing.expectEqual(@as(u8, 15), facts.instance[15]);
    for ([_][]const u8{
        "{}",
        "{\"type\":\"host_status\",\"status\":\"incompatible\"}",
        "{\"type\":\"host_status\",\"status\":\"ready\",\"instance\":\"invalid\",\"store\":\"/host\",\"active_capacity\":\"3\"}",
        "{\"type\":\"host_status\",\"status\":\"ready\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"store\":\"/host\",\"active_capacity\":\"overflow\"}",
    }) |invalid| try std.testing.expect(try parseUpgradeStatus(allocator, invalid) == null);
}

test "upgrade census merges socket hints and retains pathless identified failures" {
    const allocator = std.testing.allocator;
    var candidates: std.ArrayList(UpgradeCandidate) = .empty;
    defer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }
    try appendUpgradeCandidate(allocator, &candidates, .{
        .socket = try allocator.dupe(u8, "/socket"),
        .result = .{ .failed = error.ConnectionRefused },
    });
    var observation: HostControlObservation = .{ .foreign = false, .facts = std.mem.zeroes(StatusFacts), .pid = 42 };
    try observation.host_directory.set("/host/\xff");
    try appendUpgradeCandidate(allocator, &candidates, .{
        .socket = try allocator.dupe(u8, "/socket"),
        .directory = try allocator.dupe(u8, "/host/\xff"),
        .pid = 42,
        .generation = 7,
        .result = .{ .observed = observation },
    });
    try appendUpgradeCandidate(allocator, &candidates, .{
        .socket = try allocator.dupe(u8, "/socket"),
        .result = .{ .failed = error.HostPeerPidMismatch },
    });
    try appendUpgradeCandidate(allocator, &candidates, .{ .pid = 43, .result = .{ .failed = error.HostServeStoreMissing } });
    try std.testing.expectEqual(@as(usize, 2), candidates.items.len);
    try std.testing.expectEqualStrings("/host/\xff", candidates.items[0].directory.?);
    try std.testing.expectEqual(@as(c_int, 42), candidates.items[0].result.observed.pid);
    try std.testing.expectEqual(@as(?c_int, 43), candidates.items[1].pid);
    try std.testing.expect(candidates.items[1].socket == null);
}

test "an unanswered socket goes only when a fresh look proves its endpoint dead, and any other result stays" {
    var observation: HostControlObservation = .{ .foreign = false, .facts = std.mem.zeroes(StatusFacts), .pid = 42 };
    try observation.host_directory.set("/host");
    const Settled = enum { dropped, failed, observed };
    const Row = struct { candidate: UpgradeCandidate, dead: Settled, alive: Settled };
    const rows = [_]Row{
        .{ .candidate = .{ .socket = "/refused/rui.sock", .result = .{ .unanswered = error.ConnectionRefused } }, .dead = .dropped, .alive = .failed },
        .{ .candidate = .{ .socket = "/vanished/rui.sock", .result = .{ .unanswered = error.FileNotFound } }, .dead = .dropped, .alive = .failed },
        // Same error names after a connection: a live Host whose Store vanished.
        .{ .candidate = .{ .socket = "/accepted/rui.sock", .result = .{ .failed = error.FileNotFound } }, .dead = .failed, .alive = .failed },
        .{ .candidate = .{ .socket = "/old-wire/rui.sock", .result = .{ .failed = error.WrongWireVersion } }, .dead = .failed, .alive = .failed },
        .{ .candidate = .{ .socket = "/silent/rui.sock", .result = .{ .failed = error.TransferInactive } }, .dead = .failed, .alive = .failed },
        .{ .candidate = .{ .socket = "/live/rui.sock", .directory = "/host", .pid = 42, .result = .{ .observed = observation } }, .dead = .observed, .alive = .observed },
        .{ .candidate = .{ .socket = "/owned/rui.sock", .pid = 43, .result = .{ .failed = error.HostPeerPidMismatch } }, .dead = .failed, .alive = .failed },
        .{ .candidate = .{ .pid = 44, .result = .{ .failed = error.HostServeStoreMissing } }, .dead = .failed, .alive = .failed },
    };
    for (rows) |row| for (std.enums.values(host_endpoint.Sighting)) |sighting| {
        var candidate = row.candidate;
        const decision = settleUnanswered(&candidate, sighting);
        const expected = switch (sighting) {
            .reclaimed, .vanished => row.dead,
            .busy, .unprovable => row.alive,
        };
        try std.testing.expectEqual(expected, if (decision == .drop) Settled.dropped else switch (candidate.result) {
            .failed => |err| failed: {
                if (row.candidate.result == .unanswered) try std.testing.expectEqual(row.candidate.result.unanswered, err);
                break :failed Settled.failed;
            },
            .observed => Settled.observed,
            .unanswered => unreachable,
        });
    };
}

test "upgrade process retirement covers macOS zombie generations and living cleanup tails" {
    const pid: c_int = 42;
    const generation: u64 = 100;
    const Case = struct {
        name: []const u8,
        census: []const u8,
        before: ?u64,
        after: ?u64,
        retired: bool,
    };
    // These injected observations run on every OS. Darwin's arg=0 query cannot
    // identify an unreaped zombie; arg=1 retains its start time like /proc does.
    // A census Z without that identity is deliberately NOT sufficient proof.
    for ([_]Case{
        .{ .name = "alive", .census = "42 S\n80 R\n", .before = generation, .after = generation, .retired = false },
        .{ .name = "living cleanup tail", .census = "42 Sl+\n80 R\n", .before = generation, .after = generation, .retired = false },
        .{ .name = "stopped but not exited", .census = "42 T\n80 R\n", .before = generation, .after = generation, .retired = false },
        .{ .name = "old macOS query excludes zombie", .census = "42 Z\n80 R\n", .before = null, .after = null, .retired = false },
        .{ .name = "macOS query includes exact zombie", .census = "42 Z+\n80 R\n", .before = generation, .after = generation, .retired = true },
        .{ .name = "zombie generation unavailable before", .census = "42 Z\n80 R\n", .before = null, .after = generation, .retired = false },
        .{ .name = "zombie generation unavailable after", .census = "42 Z\n80 R\n", .before = generation, .after = null, .retired = false },
        .{ .name = "PID reused before census", .census = "42 S\n80 R\n", .before = generation + 1, .after = generation + 1, .retired = true },
        .{ .name = "PID reused across census", .census = "42 S\n80 R\n", .before = generation, .after = generation + 1, .retired = true },
        .{ .name = "gone", .census = "80 R\n", .before = null, .after = null, .retired = true },
        .{ .name = "contradictory absence", .census = "80 R\n", .before = generation, .after = generation, .retired = false },
        .{ .name = "absence contradicts earlier generation", .census = "80 R\n", .before = generation, .after = null, .retired = false },
        .{ .name = "absence contradicts later generation", .census = "80 R\n", .before = null, .after = generation, .retired = false },
    }) |case| {
        errdefer std.debug.print("retirement case: {s}\n", .{case.name});
        try std.testing.expectEqual(case.retired, try retirementReading(case.census, pid, generation, case.before, case.after));
    }
    for ([_][]const u8{ "", "42\n", "not-a-pid Z\n", "42 Z extra\n", "42 Z\n42 S\n" }) |malformed| try std.testing.expectError(error.HostProcessSnapshotUnavailable, retirementReading(malformed, pid, generation, generation, generation));
}

test "client upgrade retirement observes a live tail then an unreaped exit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "printf R; read gate" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);
    var buffer: [64]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    try std.testing.expectEqual(@as(u8, 'R'), try reader.interface.takeByte());
    const pid = child.id.?;
    const started = try @import("host_identity.zig").generation(pid);
    const until = @import("test_poll").after(io, .fromSeconds(5));
    try std.testing.expect(!try upgradeGenerationRetired(gpa, io, pid, started, until.raw.nanoseconds));
    child.stdin.?.close(io);
    child.stdin = null;
    const Wait = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        pid: c_int,
        started: u64,
        until: i128,
        fn ready(self: *@This()) !bool {
            return upgradeGenerationRetired(self.gpa, self.io, self.pid, self.started, self.until);
        }
    };
    var wait: Wait = .{ .gpa = gpa, .io = io, .pid = pid, .started = started, .until = until.raw.nanoseconds };
    try @import("test_poll").waitUntil(io, until, &wait, Wait.ready);
    // Still unreaped: Darwin must retain the exact generation for a zombie,
    // not merely make the census-based decision table pass.
    try std.testing.expectEqual(started, try @import("host_identity.zig").generation(pid));
    _ = try child.wait(io);
    // PID absence uses the same complete-census proof, not kill(pid, 0).
    try std.testing.expect(try upgradeGenerationRetired(gpa, io, pid, started, @import("test_poll").after(io, .fromSeconds(5)).raw.nanoseconds));
}

test "capture routing round trips six placements without conflating selector and wire identity" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const Peer = struct {
        fn serve(listener: *std.Io.net.Server, expected_store: []const u8) anyerror!void {
            for (0..4) |index| {
                const connection = try listener.accept(std.testing.io);
                defer connection.close(std.testing.io);
                const deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 5 * std.time.ns_per_s;
                var request: [2048]u8 = undefined;
                var used: usize = 0;
                while (used < request.len) {
                    const count = try readRequest(.{ .io = std.testing.io }, connection.socket.handle, request[used .. used + 1], deadline);
                    if (count == 0) return error.TestUnexpectedResult;
                    used += count;
                    if (std.mem.endsWith(u8, request[0..used], "\r\n\r\n")) break;
                } else return error.TestUnexpectedResult;
                const expected = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"kind\":\"host_info\",\"store\":\"\"}";
                var body_used: usize = 0;
                while (body_used < expected.len) {
                    const count = try readRequest(.{ .io = std.testing.io }, connection.socket.handle, request[body_used..expected.len], deadline);
                    if (count == 0) return error.TestUnexpectedResult;
                    body_used += count;
                }
                try std.testing.expectEqualStrings(expected, request[0..body_used]);
                var body: protocol.ResponseBuffer = .{};
                const info: @import("host_reply.zig").HostInfo = .{ .store = if (index == 3) "fedcba9876543210fedcba9876543210" else expected_store, .instance = @splat(1), .active_capacity = 2, .intake_capacity = 100, .descriptor_soft_limit = 1024, .started_at = 1, .custody_occupied = 0, .paused = false, .routes = protocol.routesAll(.unserved), .doublewrite = null, .settings_digest = null };
                try body.render(@import("host_reply.zig").renderHostInfo, .{info});
                var head_buffer: [512]u8 = undefined;
                const head = try std.fmt.bufPrint(&head_buffer, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: " ++ protocol.wire_version ++ "\r\nConnection: close\r\n\r\n", .{body.len});
                try writeAllRequest(.{ .io = std.testing.io }, connection.socket.handle, head, deadline);
                try writeAllRequest(.{ .io = std.testing.io }, connection.socket.handle, body.slice(), deadline);
            }
        }
    };
    for ([_]enum { sqlite_default, sqlite_moved, mysql }{ .sqlite_default, .sqlite_moved, .mysql }) |kind| for ([_]bool{ false, true }) |explicit_interface| {
        var tmp = try @import("socket_fixture.zig").Directory.init();
        defer tmp.cleanup();
        const root = tmp.root[0..tmp.root_len];
        var host = try tmp.dir.createDirPathOpen(io, "host", .{ .permissions = .fromMode(0o700) });
        defer host.close(io);
        const directory = try std.fs.path.join(gpa, &.{ root, "host" });
        defer gpa.free(directory);
        const data = try std.fs.path.join(gpa, &.{ root, "data" });
        defer gpa.free(data);
        if (kind == .sqlite_moved) {
            var data_dir = try tmp.dir.createDirPathOpen(io, "data", .{ .permissions = .fromMode(0o700) });
            data_dir.close(io);
        }
        const runtime = try std.fs.path.join(gpa, &.{ root, "iface" });
        defer gpa.free(runtime);
        var document: std.Io.Writer.Allocating = .init(gpa);
        defer document.deinit();
        try document.writer.writeAll("{");
        switch (kind) {
            .sqlite_default => {},
            .sqlite_moved => {
                try document.writer.writeAll("\"store\":{\"sqlite\":{\"dir\":");
                try std.json.Stringify.value(data, .{}, &document.writer);
                try document.writer.writeAll("}},");
            },
            .mysql => try document.writer.writeAll("\"store\":{\"mysql\":{\"url\":{\"env\":\"RUI_ABSENT_CAPTURE_TEST_URL\"}}},"),
        }
        if (explicit_interface) {
            try document.writer.writeAll("\"interface\":{\"dir\":");
            try std.json.Stringify.value(runtime, .{}, &document.writer);
            try document.writer.writeAll("},");
        }
        try document.writer.writeAll("\"providers\":{}}");
        try host.writeFile(io, .{ .sub_path = "host.json", .data = document.written(), .flags = .{ .permissions = .fromMode(0o600) } });
        var paths = try platform.resolveClientPaths(io, directory);
        if (kind == .mysql) try paths.store_identity.set("0123456789abcdef0123456789abcdef");
        var endpoint: ?host_endpoint.Endpoint = null;
        var listener: ?std.Io.net.Server = null;
        var future: ?std.Io.Future(anyerror!void) = null;
        if (kind == .mysql) {
            endpoint = try host_endpoint.claim(io, try .init(std.fs.path.dirname(paths.socket.slice()).?));
            listener = try endpoint.?.listen(.{});
            future = try io.concurrent(Peer.serve, .{ &listener.?, paths.store_identity.slice() });
        }
        defer if (kind == .mysql) std.Io.Dir.cwd().deleteTree(io, std.fs.path.dirname(paths.socket.slice()).?) catch @panic("routing test runtime cleanup failed");
        defer if (endpoint) |*held| held.retire() catch @panic("unable to retire fixture endpoint");
        defer if (listener) |*server| server.deinit(io);
        defer if (future) |*pending| {
            _ = pending.cancel(io) catch {};
        };
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var key_buffer: [36]u8 = undefined;
        const location = try (CaptureTarget{ .generated = root }).resolve(io, &path_buffer, &key_buffer);
        var original = try writeSessionStopCapture(io, &paths, .{ .store = directory, .session = "k7m2qx" }, location);
        const saved = original.saved;
        const before = try tmp.dir.readFileAlloc(io, std.fs.path.basename(location.record), gpa, .limited(2048));
        defer gpa.free(before);
        original.close(io);
        var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = saved.key.slice() } });
        defer recovered.close(io);
        try std.testing.expect(recovered.paths == null);
        try std.testing.expectEqualStrings(directory, recovered.routing.host_directory.slice());
        const rediscovered = try recovered.resolvePaths(io);
        try std.testing.expectEqualStrings(directory, rediscovered.selector());
        try std.testing.expectEqualStrings(paths.socket.slice(), rediscovered.socket.slice());
        try std.testing.expectEqualStrings(saved.store.slice(), rediscovered.store_identity.slice());
        const inspection = try inspectCapturedRequest(io, root, saved.key.slice());
        try std.testing.expectEqualStrings(directory, inspection.paths.selector());
        try std.testing.expectEqualStrings(saved.store.slice(), inspection.identity.store.slice());
        var explicit = try openCaptured(io, .{ .explicit = .{ .store = directory, .record = location.record, .kind = .session_stop } });
        defer explicit.close(io);
        const explicit_paths = try explicit.resolvePaths(io);
        try std.testing.expectEqualStrings(rediscovered.socket.slice(), explicit_paths.socket.slice());
        var after: [2048]u8 = undefined;
        const count = try recovered.file.readPositionalAll(io, &after, 0);
        try std.testing.expectEqualStrings(before, after[0..count]);
        if (future) |*pending| {
            try std.testing.expectError(error.RequestBindingMismatch, recovered.resolvePaths(io));
            try pending.await(io);
            future = null;
        }
        // An operator edit that points DIR to another SQLite database must not
        // redirect the immutable request, even though placement can be resolved.
        if (kind != .mysql) {
            const changed = try std.fmt.allocPrint(gpa, "{{\"store\":{{\"sqlite\":{{\"dir\":\"{s}/different\"}}}}}}", .{root});
            defer gpa.free(changed);
            try host.writeFile(io, .{ .sub_path = "host.json", .data = changed, .flags = .{ .permissions = .fromMode(0o600) } });
            try std.testing.expectError(error.RequestBindingMismatch, recovered.resolvePaths(io));
        }
    };
}

test "capture routing metadata rejects invalid, missing and public companions" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const root = tmp.root[0..tmp.root_len];
    var captured = try captureSessionStop(io, .{ .store = root, .session = "k7m2qx" }, .{ .generated = root });
    const key = captured.saved.key;
    captured.close(io);
    const name = try std.fmt.allocPrint(gpa, "{s}.json.routing", .{key.slice()});
    defer gpa.free(name);
    for ([_][]const u8{
        "{",                                                                         "{}",                                                                   "{\"format\":2,\"host_directory\":\"/host\",\"runtime_hint\":\"\"}",
        "{\"format\":1,\"host_directory\":\"/host\",\"runtime_hint\":\"/runtime\"}", "{\"format\":1,\"host_directory\":\"relative\",\"runtime_hint\":\"\"}", "{\"format\":1,\"host_directory\":\"\",\"runtime_hint\":\"\"}",
        "{\"format\":1,\"host_directory\":\"/host\\u0000\",\"runtime_hint\":\"\"}",
    }) |text| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = text, .flags = .{ .permissions = .fromMode(0o600) } });
        try std.testing.expectError(error.InvalidRequestRecord, openCaptured(io, .{ .generated = .{ .directory = root, .handle = key.slice() } }));
    }
    try tmp.dir.setFilePermissions(io, name, .fromMode(0o644), .{});
    try std.testing.expectError(error.InvalidRequestRecord, openCaptured(io, .{ .generated = .{ .directory = root, .handle = key.slice() } }));
    try tmp.dir.deleteFile(io, name);
    try tmp.dir.symLink(io, "missing-route", name, .{});
    if (openCaptured(io, .{ .generated = .{ .directory = root, .handle = key.slice() } })) |value| {
        var unexpected = value;
        unexpected.close(io);
        return error.TestUnexpectedResult;
    } else |_| {}
    try tmp.dir.deleteFile(io, name);
    try std.testing.expectError(error.InvalidRequestRecord, openCaptured(io, .{ .generated = .{ .directory = root, .handle = key.slice() } }));
    try std.testing.expectError(error.InvalidRequestRecord, inspectCapturedRequest(io, root, key.slice()));
}

test "capture routing publication faults preserve request custody and never replace an existing pair" {
    const Fault = struct {
        const Stage = enum { route_create, route_write, route_sync, route_rename, route_directory_sync, request_sync, request_rename, request_directory_sync };
        var stage: Stage = undefined;
        var route_file: std.posix.fd_t = -1;
        var body_file: std.posix.fd_t = -1;
        var directory_syncs: usize = 0;
        var fired = false;
        fn create(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.CreateFileOptions) std.Io.File.OpenError!std.Io.File {
            const route = std.mem.endsWith(u8, path, ".routing.tmp");
            if (route and stage == .route_create) {
                fired = true;
                return error.NoSpaceLeft;
            }
            const file = try std.testing.io.vtable.dirCreateFile(userdata, dir, path, options);
            if (route) route_file = file.handle;
            if (std.mem.endsWith(u8, path, ".capture.tmp")) body_file = file.handle;
            return file;
        }
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming and operation.file_write_streaming.file.handle == route_file and stage == .route_write) {
                fired = true;
                return .{ .file_write_streaming = error.NoSpaceLeft };
            }
            return std.testing.io.vtable.operate(userdata, operation);
        }
        fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const directory = (file.stat(std.testing.io) catch return error.InputOutput).kind == .directory;
            if (directory) directory_syncs += 1;
            if ((stage == .route_sync and !directory and file.handle == route_file) or
                (stage == .request_sync and !directory and file.handle == body_file) or
                (stage == .route_directory_sync and directory and directory_syncs == 1) or
                (stage == .request_directory_sync and directory and directory_syncs == 2))
            {
                fired = true;
                return error.NoSpaceLeft;
            }
            return std.testing.io.vtable.fileSync(userdata, file);
        }
        fn rename(userdata: ?*anyopaque, old_dir: std.Io.Dir, old_path: []const u8, new_dir: std.Io.Dir, new_path: []const u8) std.Io.Dir.RenamePreserveError!void {
            if ((stage == .route_rename and std.mem.endsWith(u8, new_path, ".routing")) or
                (stage == .request_rename and std.mem.eql(u8, new_path, "request.json")))
            {
                fired = true;
                return error.NoSpaceLeft;
            }
            return std.testing.io.vtable.dirRenamePreserve(userdata, old_dir, old_path, new_dir, new_path);
        }
    };
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    for (std.enums.values(Fault.Stage)) |stage| {
        var tmp = try @import("socket_fixture.zig").Directory.init();
        defer tmp.cleanup();
        const root = tmp.root[0..tmp.root_len];
        const path = try std.fs.path.join(gpa, &.{ root, "request.json" });
        defer gpa.free(path);
        var vtable = io.vtable.*;
        vtable.dirCreateFile = Fault.create;
        vtable.operate = Fault.operate;
        vtable.fileSync = Fault.sync;
        vtable.dirRenamePreserve = Fault.rename;
        const failing: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        Fault.stage = stage;
        Fault.fired = false;
        Fault.route_file = -1;
        Fault.body_file = -1;
        Fault.directory_syncs = 0;
        try std.testing.expectError(if (stage == .route_directory_sync or stage == .request_directory_sync) error.RecordDirectorySyncFailed else error.NoSpaceLeft, captureSessionStop(failing, .{ .store = root, .session = "k7m2qx" }, .{ .explicit = .{ .record = path, .key = "stable" } }));
        try std.testing.expect(Fault.fired);
        if (stage == .request_directory_sync) {
            var recovered = try openCaptured(io, .{ .explicit = .{ .store = root, .record = path, .kind = .session_stop } });
            defer recovered.close(io);
            try std.testing.expectEqualStrings(root, (try recovered.resolvePaths(io)).selector());
        } else {
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "request.json", .{}));
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "request.json.routing", .{}));
            // A crashed pre-request publisher can leave an orphan companion.
            try tmp.dir.writeFile(io, .{ .sub_path = "request.json.routing", .data = "orphan", .flags = .{ .permissions = .fromMode(0o600) } });
            var retried = try captureSessionStop(io, .{ .store = root, .session = "k7m2qx" }, .{ .explicit = .{ .record = path, .key = "stable" } });
            retried.close(io);
        }
        const before = try tmp.dir.readFileAlloc(io, "request.json.routing", gpa, .limited(4096));
        defer gpa.free(before);
        try std.testing.expectError(error.RecordAlreadyExists, captureSessionStop(io, .{ .store = root, .session = "09azvw" }, .{ .explicit = .{ .record = path, .key = "different" } }));
        const after = try tmp.dir.readFileAlloc(io, "request.json.routing", gpa, .limited(4096));
        defer gpa.free(after);
        try std.testing.expectEqualStrings(before, after);
    }
}

test "capture routing retains OS bytes and legacy opaque runtime without storing a socket" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const root = tmp.root[0..tmp.root_len];
    const directory = try std.fs.path.join(gpa, &.{ root, "host-\xff" });
    defer gpa.free(directory);
    // This tests the local codec, not SQLite's UTF-8 wire identity rule.
    var initial = try platform.resolveClientPaths(io, root);
    try initial.host_directory.set(directory);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try (CaptureTarget{ .generated = root }).resolve(io, &path_buffer, &key_buffer);
    var captured = try writeSessionStopCapture(io, &initial, .{ .store = root, .session = "k7m2qx" }, location);
    const key = captured.saved.key;
    captured.close(io);
    var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = key.slice() } });
    defer recovered.close(io);
    try std.testing.expectEqualStrings(directory, recovered.routing.host_directory.slice());
    const legacy = try platform.mysqlClientPaths(io, "0123456789abcdef0123456789abcdef", root);
    const route = try CaptureRouting.fromPaths(&legacy);
    try std.testing.expectEqual(@as(usize, 0), route.host_directory.len);
    try std.testing.expectEqualStrings(root, route.runtime_hint.slice());
    const restored = try route.resolve(io, legacy.store_identity.slice());
    try std.testing.expectEqualStrings(legacy.socket.slice(), restored.socket.slice());
    try std.testing.expectEqualStrings(legacy.store_identity.slice(), restored.store_identity.slice());
    try std.testing.expectError(error.InvalidStorePath, route.resolve(io, "/not-an-opaque-identity"));
    const legacy_location = try (CaptureTarget{ .generated = root }).resolve(io, &path_buffer, &key_buffer);
    var saved_legacy = try writeSessionStopCapture(io, &legacy, .{ .store = legacy.store_identity.slice(), .session = "k7m2qx" }, legacy_location);
    const legacy_key = saved_legacy.saved.key;
    saved_legacy.close(io);
    var generated = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = legacy_key.slice() } });
    defer generated.close(io);
    try std.testing.expectEqualStrings(root, generated.routing.runtime_hint.slice());
    try std.testing.expectEqualStrings(legacy.socket.slice(), (try generated.resolvePaths(io)).socket.slice());
    var explicit = try openCaptured(io, .{ .explicit = .{ .store = legacy.store_identity.slice(), .record = legacy_location.record, .kind = .session_stop } });
    defer explicit.close(io);
    try std.testing.expectEqualStrings(legacy.socket.slice(), (try explicit.resolvePaths(io)).socket.slice());
}

test "capture routing writer and readers share private parent aliases" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const root = tmp.root[0..tmp.root_len];
    var actual = try tmp.dir.createDirPathOpen(io, "actual", .{ .permissions = .fromMode(0o700) });
    actual.close(io);
    try tmp.dir.symLink(io, "actual", "alias", .{ .is_directory = true });
    const alias = try std.fs.path.join(gpa, &.{ root, "alias" });
    defer gpa.free(alias);
    for ([_]bool{ false, true }) |explicit| {
        const path = try std.fs.path.join(gpa, &.{ alias, "explicit.json" });
        defer gpa.free(path);
        const target: CaptureTarget = if (explicit) .{ .explicit = .{ .record = path, .key = "explicit-key" } } else .{ .generated = alias };
        var captured = try captureSessionStop(io, .{ .store = root, .session = "k7m2qx" }, target);
        const saved = captured.saved;
        captured.close(io);
        var recovered = try openCaptured(io, if (explicit) .{ .explicit = .{ .store = root, .record = path, .kind = .session_stop } } else .{ .generated = .{ .directory = alias, .handle = saved.key.slice() } });
        defer recovered.close(io);
        try std.testing.expectEqualStrings(root, (try recovered.resolvePaths(io)).selector());
        if (!explicit) {
            const inspected = try inspectCapturedRequest(io, alias, saved.key.slice());
            try std.testing.expectEqualStrings(root, inspected.paths.selector());
        }
    }
}

test "read-only capture routing does not eagerly validate a replay body" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    const root = tmp.root[0..tmp.root_len];
    var captured = try captureConfigure(io, .{ .store = root, .session = .{ .named = "k7m2qx" } }, .{ .generated = root }).get();
    const key = captured.saved.key;
    captured.close(io);
    const filename = try std.fmt.allocPrint(gpa, "{s}.json", .{key.slice()});
    defer gpa.free(filename);
    const file = try tmp.dir.openFile(io, filename, .{ .mode = .write_only });
    {
        defer file.close(io);
        try file.writePositionalAll(io, "not another immutable request", try file.length(io));
    }
    try std.testing.expectError(error.InvalidRequestRecord, openCaptured(io, .{ .generated = .{ .directory = root, .handle = key.slice() } }));
    const observed = try inspectCapturedRequest(io, root, key.slice());
    try std.testing.expectEqualStrings(root, observed.paths.selector());
    try std.testing.expectEqualStrings(key.slice(), observed.identity.key.slice());
}

fn checkSemanticToolsCapture() !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const ToolInput = @import("configure_input.zig").ToolInput;
    const cases = [_]struct { input: ToolInput, want: []const []const u8 }{
        .{ .input = .{ .cli = "none" }, .want = &.{} },
        .{ .input = .{ .names = &.{} }, .want = &.{} },
        .{ .input = .{ .names = &.{"none"} }, .want = &.{"none"} },
        .{ .input = .{ .names = &.{ "none", "lookup", "bash" } }, .want = &.{ "bash", "lookup", "none" } },
        .{ .input = .{ .cli = "none,bash" }, .want = &.{ "bash", "none" } },
    };
    for (cases) |case| {
        var captured = try captureConfigure(io, .{
            .store = root,
            .session = .{ .named = "k7m2qx" },
            .tools = case.input,
            .loaded_tools = case.input,
        }, .{ .generated = root }).get();
        defer captured.close(io);
        var bytes: [4096]u8 = undefined;
        const count = try captured.file.readPositionalAll(io, &bytes, 0);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..count], .{});
        defer parsed.deinit();
        const spec = parsed.value.object.get("configuration").?.object;
        for ([_][]const u8{ "tools", "loadedTools" }) |field| {
            const names = spec.get(field).?.array.items;
            try std.testing.expectEqual(case.want.len, names.len);
            for (case.want, names) |expected, actual| try std.testing.expectEqualStrings(expected, actual.string);
        }
    }
    for ([_]ToolInput{ .{ .cli = "bash,bash" }, .{ .names = &.{ "bash", "bash" } } }) |input| {
        try std.testing.expectError(error.DuplicateToolName, captureConfigure(io, .{ .store = root, .session = .create, .tools = input }, .{ .generated = root }).get());
    }
    for ([_]ToolInput{ .{ .cli = "" }, .{ .names = &.{""} }, .{ .names = &.{"invalid,name"} } }) |input| {
        try std.testing.expectError(error.InvalidToolName, captureConfigure(io, .{ .store = root, .session = .create, .loaded_tools = input }, .{ .generated = root }).get());
    }
}

fn checkParentCapture() !void {
    const host_request = @import("wire_request.zig");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_]bool{ false, true }) |creating_message| {
        for ([_]bool{ false, true }) |explicit_overrides| {
            const input: ConfigureInput = .{
                .store = root,
                .session = .create,
                .parent = .{ .present = true, .value = "k7m2qx" },
                .provider = if (explicit_overrides) .{ .present = true, .value = "codex" } else .{},
                .workspace = if (explicit_overrides) .{ .present = true, .value = root } else .{},
                .model = .{ .present = true, .value = "unlisted-model" },
                .tools = .{ .cli = "bash,find_tools" },
                .loaded_tools = .{ .cli = "bash" },
                .permission_mode = .{ .present = true, .value = "ask" },
                .compaction_trigger = .{ .present = true, .value = "1000" },
                .reasoning_effort = .{ .present = true, .value = "low" },
            };
            var captured = try (if (creating_message)
                captureMessage(io, .{ .store = root, .session = "", .text_path = "", .text = "task\x00\n", .configuration = input }, .{ .generated = root })
            else
                captureConfigure(io, input, .{ .generated = root })).get();
            defer captured.close(io);
            try std.testing.expectEqual(if (creating_message) protocol.CommandKind.message else .configure, captured.identity().kind);
            try std.testing.expectEqualStrings("", captured.identity().session.slice());
            var bytes: [8192]u8 = undefined;
            const length = try captured.file.readPositionalAll(io, &bytes, 0);
            const ingress = try std.testing.allocator.create(host_request.Ingress);
            defer std.testing.allocator.destroy(ingress);
            var retained: ?@import("named_scratch.zig").Owner = null;
            ingress.init(std.testing.allocator, .{ .io = io, .content_length = length, .scratch_path = root, .request_number = 1, .retained_scratch = &retained });
            defer ingress.deinit();
            try ingress.feed(bytes[0..length]);
            const request = try ingress.finish();
            defer request.removeTemporaryContent(io) catch unreachable;
            const configuration = if (creating_message) &request.message.configuration.? else &request.configure.configuration;
            try std.testing.expectEqualStrings("k7m2qx", configuration.parent.value.slice());
            try std.testing.expectEqualStrings("unlisted-model", configuration.model.value.slice());
            try std.testing.expectEqualStrings("bash find_tools", configuration.tools.names.slice());
            try std.testing.expectEqualStrings("bash", configuration.loaded_tools.names.slice());
            try std.testing.expectEqualStrings("ask", configuration.permission_mode.value.slice());
            try std.testing.expectEqualStrings("1000", configuration.compaction_trigger.value.slice());
            try std.testing.expectEqualStrings("low", configuration.reasoning_effort.value.slice());
            if (explicit_overrides) {
                try std.testing.expectEqualStrings("codex", configuration.provider.value.slice());
                try std.testing.expectEqualStrings(root, configuration.workspace.value.slice());
            } else {
                try std.testing.expect(configuration.provider.state == .omitted);
                try std.testing.expect(configuration.workspace.state == .omitted);
            }
        }
    }
}

fn checkPresetCapture() !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const input: ConfigureInput = .{ .store = root, .session = .create, .preset = .{ .present = true, .value = "restricted" }, .tools = .{ .cli = "none" }, .reasoning_effort = .{ .present = true, .value = null } };
    var captured = try captureConfigure(io, input, .{ .generated = root }).get();
    defer captured.close(io);
    var reopened = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = captured.identity().key.slice() } });
    defer reopened.close(io);
    var bytes: [8192]u8 = undefined;
    const length = try reopened.file.readPositionalAll(io, &bytes, 0);
    const ingress = try std.testing.allocator.create(@import("wire_request.zig").Ingress);
    defer std.testing.allocator.destroy(ingress);
    var retained: ?@import("named_scratch.zig").Owner = null;
    ingress.init(std.testing.allocator, .{ .io = io, .content_length = length, .scratch_path = root, .request_number = 1, .retained_scratch = &retained });
    defer ingress.deinit();
    try ingress.feed(bytes[0..length]);
    const request = try ingress.finish();
    defer request.removeTemporaryContent(io) catch unreachable;
    try std.testing.expectEqualStrings("restricted", request.configure.preset.?.slice());
    try std.testing.expect(request.configure.configuration.workspace.state == .omitted);
    try std.testing.expect(request.configure.configuration.tools.state == .value);
    try std.testing.expectEqualStrings("", request.configure.configuration.tools.names.slice());
    try std.testing.expect(request.configure.configuration.reasoning_effort.state == .explicit_null);
}

test "Action stop captures preserve target and bytes through generated and explicit recovery" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_]u64{ 1, 9007199254740993, std.math.maxInt(i64) }) |action_id| {
        var captured = try captureActionStop(io, .{ .store = root, .session = "k7m2qx", .action_id = action_id }, .{ .generated = root });
        const identity = captured.saved;
        var original: [2048]u8 = undefined;
        const count = try captured.file.readPositionalAll(io, &original, 0);
        try std.testing.expectEqual(protocol.CommandKind.action_stop, identity.kind);
        try std.testing.expectEqual(action_id, captured.target.action_stop);
        captured.close(io);
        var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = identity.key.slice() } });
        try std.testing.expectEqual(action_id, recovered.target.action_stop);
        try std.testing.expectEqualStrings(identity.key.slice(), recovered.saved.key.slice());
        try std.testing.expectEqualStrings("k7m2qx", recovered.saved.session.slice());
        var replayed: [2048]u8 = undefined;
        const replayed_count = try recovered.file.readPositionalAll(io, &replayed, 0);
        try std.testing.expectEqualSlices(u8, original[0..count], replayed[0..replayed_count]);
        recovered.close(io);
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try requestPath(root, identity.key.slice(), &path_buffer);
        var explicit = try openCaptured(io, .{ .explicit = .{ .store = root, .record = path, .kind = .action_stop } });
        try std.testing.expectEqual(action_id, explicit.target.action_stop);
        explicit.close(io);
        try std.testing.expectEqual(protocol.CommandKind.action_stop, (try inspectCaptured(io, root, identity.key.slice())).kind);
        try std.testing.expectError(error.RequestBindingMismatch, openCaptured(io, .{ .explicit = .{ .store = root, .record = path, .kind = .action_background } }));
    }
    for ([_]u64{ 0, std.math.maxInt(u64) }) |action_id| {
        try std.testing.expectError(error.InvalidTarget, captureActionStop(io, .{ .store = root, .session = "k7m2qx", .action_id = action_id }, .{ .generated = root }));
    }
}

fn checkPreferencesCapture() !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var captured = try captureConfigure(io, .{
        .store = root,
        .session = .create,
        .reasoning_effort = .{ .present = true, .value = "low" },
        .preferences = .{ .reasoning_effort = .high, .permission_mode = .ask },
    }, .{ .generated = root }).get();
    defer captured.close(io);
    var bytes: [8192]u8 = undefined;
    const length = try captured.file.readPositionalAll(io, &bytes, 0);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..length], .{});
    defer parsed.deinit();
    const configuration = parsed.value.object.get("configuration").?.object;
    try std.testing.expectEqualStrings("low", configuration.get("effort").?.string);
    try std.testing.expect(!configuration.contains("model"));
    const prefs = configuration.get("preferences").?.object;
    try std.testing.expectEqualStrings("high", prefs.get("reasoning_effort").?.string);
    try std.testing.expectEqualStrings("ask", prefs.get("permission_mode").?.string);
}

test "CLI-4 configuration_intent" {
    try checkCreatingMessageCapture();
    try checkAddressedMessageCapture();
    try checkCreatingConfigureCapture();
    try checkSemanticToolsCapture();
    try checkParentCapture();
    try checkPresetCapture();
    try checkPreferencesCapture();
}

test "ADM-24 frozen multipart request recovers canonical identity" {
    const parts = @import("input_parts.zig");
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    const encoder = std.base64.standard.Encoder;
    var encoded: [encoder.calcSize(png.len)]u8 = undefined;
    const image = encoder.encode(&encoded, png);
    var body: [4096]u8 = undefined;
    const json = try std.fmt.bufPrint(&body, "[{{\"type\":\"text\",\"text\":\"before\"}},{{\"type\":\"image\",\"mime\":\"image/png\",\"data\":\"{s}\"}},{{\"type\":\"text\",\"text\":\"after\"}}]", .{image});
    const parsed = try std.json.parseFromSlice(CapturedParts, std.testing.allocator, json, .{});
    defer parsed.deinit();
    var scanner = try @import("input_media.zig").Scanner.init(png.len, null, .{});
    var allowance: usize = png.len;
    _ = try scanner.advance(png, &allowance);
    var manifest: parts.Manifest.Encoder = .{};
    var entry: [parts.Manifest.max_entry_bytes]u8 = undefined;
    const identities = [_]parts.Identity{
        .{ .length = 6, .digest = protocol.contentDigest("before"), .kind = .text },
        .{ .length = png.len, .digest = protocol.contentDigest(png), .kind = .{ .image = .{ .media = try scanner.finish() } } },
        .{ .length = 5, .digest = protocol.contentDigest("after"), .kind = .text },
    };
    for (&identities) |*identity| _ = try manifest.append(identity, &entry);
    const expected = (try manifest.finish()).parts;
    try std.testing.expectEqual(expected.length, parsed.value.reference.parts.length);
    try std.testing.expectEqualSlices(u8, &expected.digest, &parsed.value.reference.parts.digest);
    const bad = try std.fmt.bufPrint(&body, "[{{\"type\":\"image\",\"mime\":\"image/jpeg\",\"data\":\"{s}\"}}]", .{image});
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(CapturedParts, std.testing.allocator, bad, .{}));
    try std.testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(CapturedParts, std.testing.allocator, "[{\"type\":\"image\",\"mime\":\"image/png\",\"data\":\"!\"}]", .{}));
}

test "ADM-25 image capture survives source replacement and reopen" {
    const io = std.testing.io;
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const empty_stdin = try tmp.dir.createFile(io, "stdin", .{ .read = true });
    defer empty_stdin.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = png });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var image_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const image_path = try std.fmt.bufPrint(&image_buffer, "{s}/image.png", .{root});
    const operands = [_]MessageOperand{ .{ .text = "before" }, .{ .image = image_path }, .{ .text = "after" } };
    var captured = try captureMessage(io, .{ .store = root, .session = "k7m2qx", .text_path = "", .operands = &operands, .operand_stdin = empty_stdin }, .{ .generated = root }).get();
    const saved = captured.identity().*;
    const target = captured.target;
    var before: [8192]u8 = undefined;
    const count = try captured.file.readPositionalAll(io, &before, 0);
    try std.testing.expect(count != 0 and count < before.len);
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = "changed" });
    try tmp.dir.deleteFile(io, "image.png");
    var again: [8192]u8 = undefined;
    try std.testing.expectEqual(count, try captured.file.readPositionalAll(io, &again, 0));
    try std.testing.expectEqualSlices(u8, before[0..count], again[0..count]);
    captured.close(io);
    var recovered = try openCaptured(io, .{ .generated = .{ .directory = root, .handle = saved.key.slice() } });
    defer recovered.close(io);
    try std.testing.expectEqualDeep(target, recovered.target);
    try std.testing.expectEqualStrings(saved.key.slice(), recovered.identity().key.slice());
    try std.testing.expectEqual(count, try recovered.file.readPositionalAll(io, &again, 0));
    try std.testing.expectEqualSlices(u8, before[0..count], again[0..count]);
}

test "ADM-26 image capture write failures do not publish a request" {
    const Fault = struct {
        fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
            return error.NoSpaceLeft;
        }
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.NoSpaceLeft;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const empty_stdin = try tmp.dir.createFile(io, "stdin", .{ .read = true });
    defer empty_stdin.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "image.png", .data = @embedFile("codecs/fixtures/image-input/pixel.png") });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var image_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const image = try std.fmt.bufPrint(&image_buffer, "{s}/image.png", .{root});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/record", .{root});
    const operands = [_]MessageOperand{.{ .image = image }};
    for ([_]bool{ false, true }) |publication| {
        var vtable = io.vtable.*;
        if (publication) vtable.fileSync = Fault.sync else vtable.fileWritePositional = Fault.write;
        const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        try std.testing.expectError(error.NoSpaceLeft, captureMessage(failing_io, .{ .store = root, .session = "k7m2qx", .text_path = "", .operands = &operands, .operand_stdin = empty_stdin }, .{ .explicit = .{ .record = path, .key = "key" } }).get());
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".record.capture.tmp", .{}));
    }
}

test "tools reload and status replies parse into typed rows with the Host instance" {
    const allocator = std.testing.allocator;
    const relist_state = struct {
        const idle = @import("mcp/relist.zig").State.idle;
        const waiting = @import("mcp/relist.zig").State.waiting;
        const failed = @import("mcp/relist.zig").Last.failed;
    };
    const instance = "7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e7e";
    const asked = try parseToolsAsked(allocator, "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"" ++ instance ++ "\",\"asked\":[{\"server\":\"docs\",\"generation\":\"3\"},{\"server\":\"wiki\",\"generation\":\"1\"}]}");
    try std.testing.expectEqual(@as(usize, 2), asked.slice().len);
    try std.testing.expectEqual(@as(u8, 0x7e), asked.instance[0]);
    try std.testing.expectEqualStrings("docs", asked.slice()[0].server.slice());
    try std.testing.expectEqual(@as(u64, 3), asked.slice()[0].generation);
    try std.testing.expectEqualStrings("wiki", asked.slice()[1].server.slice());
    const none = try parseToolsAsked(allocator, "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"" ++ instance ++ "\",\"asked\":[]}");
    try std.testing.expectEqual(@as(usize, 0), none.slice().len);
    try std.testing.expectError(error.InvalidResponse, parseToolsAsked(allocator, "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_reload_reply\",\"instance\":\"xyz\",\"asked\":[]}"));

    const status = try parseToolsStatus(allocator, "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_status\",\"instance\":\"" ++ instance ++ "\",\"servers\":[{\"server\":\"docs\",\"state\":\"waiting\",\"last\":\"failed\",\"finished\":\"3\",\"tools\":\"12\",\"left_out\":\"2\"}]}");
    try std.testing.expectEqual(@as(u8, 0x7e), status.instance[15]);
    try std.testing.expectEqual(relist_state.waiting, status.slice()[0].state);
    try std.testing.expectEqual(relist_state.failed, status.slice()[0].last);
    try std.testing.expectEqual(@as(u64, 3), status.slice()[0].finished);
    try std.testing.expectEqual(@as(u64, 12), status.slice()[0].tools);
    try std.testing.expectEqual(@as(u64, 2), status.slice()[0].left_out);
    try std.testing.expectError(error.InvalidResponse, parseToolsStatus(allocator, "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"tools_status\",\"instance\":\"" ++ instance ++ "\",\"servers\":[{\"server\":\"docs\",\"state\":\"paused\",\"last\":\"failed\",\"finished\":\"3\",\"tools\":\"12\",\"left_out\":\"2\"}]}"));
}

test "tools refusals map an unknown server, a fenced Host and a busy Host to their own errors, and any other refusal to a protocol error" {
    try std.testing.expectEqual(error.UnknownMcpServer, toolsRefusal(.{ .status = 400, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"unknown_mcp_server\"}" }));
    // The same 503 a control command reads as unavailable is not a protocol error: fenced is stopping, capacity is busy.
    try std.testing.expectEqual(error.HostStopped, toolsRefusal(.{ .status = 503, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"host_unavailable\",\"code\":\"dispatch_fenced\"}" }));
    try std.testing.expectEqual(error.HostBusy, toolsRefusal(.{ .status = 503, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}" }));
    try std.testing.expectEqual(error.InvalidResponse, toolsRefusal(.{ .status = 400, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"dispatch_fenced\"}" }));
    try std.testing.expectEqual(error.InvalidResponse, toolsRefusal(.{ .status = 503, .body = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"invocation_error\",\"code\":\"WrongWireVersion\"}" }));
}

test "MCP tool list landing: empty, pending, landed, missing, never and restarted asks reach one outcome each" {
    const same: protocol.InstanceId = @splat(1);
    const restarted: protocol.InstanceId = @splat(2);
    const Expected = struct { server: []const u8, outcome: ToolOutcome, tools: u64 };
    const Result = union(enum) { waiting, invalid, landed: []const Expected };
    const Row = struct { name: []const u8, last: @import("mcp/relist.zig").Last, finished: u64, tools: u64 = 0 };
    const Ask = struct { name: []const u8, generation: u64 };
    const Case = struct {
        name: []const u8,
        asked_instance: protocol.InstanceId,
        asks: []const Ask,
        status_instance: ?protocol.InstanceId,
        rows: []const Row,
        expect: Result,
    };
    const docs_then_notes = [_]Ask{ .{ .name = "docs", .generation = 2 }, .{ .name = "notes", .generation = 2 } };
    const cases = [_]Case{
        .{ .name = "empty ask lands at once with no status read", .asked_instance = same, .asks = &.{}, .status_instance = null, .rows = &.{}, .expect = .{ .landed = &.{} } },
        .{ .name = "one server pending", .asked_instance = same, .asks = &docs_then_notes, .status_instance = same, .rows = &.{ .{ .name = "docs", .last = .listed, .finished = 2, .tools = 12 }, .{ .name = "notes", .last = .listed, .finished = 1, .tools = 1 } }, .expect = .waiting },
        .{ .name = "landed listed and failed", .asked_instance = same, .asks = &docs_then_notes, .status_instance = same, .rows = &.{ .{ .name = "docs", .last = .listed, .finished = 2, .tools = 12 }, .{ .name = "notes", .last = .failed, .finished = 3, .tools = 0 } }, .expect = .{ .landed = &.{ .{ .server = "docs", .outcome = .listed, .tools = 12 }, .{ .server = "notes", .outcome = .failed, .tools = 0 } } } },
        .{ .name = "missing row", .asked_instance = same, .asks = &docs_then_notes, .status_instance = same, .rows = &.{.{ .name = "docs", .last = .listed, .finished = 2, .tools = 12 }}, .expect = .invalid },
        .{ .name = "never once finished reaches the generation", .asked_instance = same, .asks = &.{.{ .name = "docs", .generation = 2 }}, .status_instance = same, .rows = &.{.{ .name = "docs", .last = .never, .finished = 2 }}, .expect = .invalid },
        .{ .name = "restarted Host with finished 0 is still waiting", .asked_instance = same, .asks = &docs_then_notes, .status_instance = restarted, .rows = &.{ .{ .name = "docs", .last = .never, .finished = 0 }, .{ .name = "notes", .last = .listed, .finished = 0 } }, .expect = .waiting },
        .{ .name = "restarted Host with finished 1 has landed", .asked_instance = same, .asks = &docs_then_notes, .status_instance = restarted, .rows = &.{ .{ .name = "docs", .last = .listed, .finished = 1, .tools = 3 }, .{ .name = "notes", .last = .failed, .finished = 1 } }, .expect = .{ .landed = &.{ .{ .server = "docs", .outcome = .listed, .tools = 3 }, .{ .server = "notes", .outcome = .failed, .tools = 0 } } } },
        .{ .name = "restarted Host reporting never once landed is invalid", .asked_instance = same, .asks = &.{.{ .name = "docs", .generation = 2 }}, .status_instance = restarted, .rows = &.{.{ .name = "docs", .last = .never, .finished = 1 }}, .expect = .invalid },
    };
    for (cases) |case| {
        var asked: ToolsAsked = .{ .instance = case.asked_instance, .len = case.asks.len };
        for (case.asks, asked.items[0..case.asks.len]) |ask, *slot| {
            try slot.server.set(ask.name);
            slot.generation = ask.generation;
        }
        var status: ToolsStatus = .{ .instance = case.status_instance orelse same, .len = case.rows.len };
        for (case.rows, status.items[0..case.rows.len]) |row, *slot| {
            try slot.server.set(row.name);
            slot.last = row.last;
            slot.finished = row.finished;
            slot.tools = row.tools;
        }
        var outcomes: ToolsOutcomes = .{};
        const read: ?*const ToolsStatus = if (case.status_instance == null) null else &status;
        const result = toolsProgress(&asked, read, &outcomes);
        switch (case.expect) {
            .waiting => {
                try std.testing.expectEqual(ToolsProgress.waiting, try result);
                try std.testing.expectEqual(@as(usize, 0), outcomes.slice().len);
            },
            .invalid => try std.testing.expectError(error.InvalidResponse, result),
            .landed => |expected| {
                try std.testing.expectEqual(ToolsProgress.landed, try result);
                try std.testing.expectEqual(expected.len, outcomes.slice().len);
                for (expected, outcomes.slice()) |want, got| {
                    try std.testing.expectEqualStrings(want.server, got.server.slice());
                    try std.testing.expectEqual(want.outcome, got.outcome);
                    try std.testing.expectEqual(want.tools, got.tools);
                }
            },
        }
    }
}
