const std = @import("std");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const codex_model_catalog = @import("codex_model_catalog.zig");
const ResponseTiming = @import("ResponseTiming.zig");

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
    read_failure: ?*?ReadFailure = null,

    pub fn failRead(self: Requests, failure: ReadFailure) error{ CanonicalStoreFailure, HostInvocationFailed } {
        if (self.read_failure) |slot| if (slot.* == null) {
            slot.* = failure;
        };
        return failure.err();
    }

    pub fn captureReadFailure(self: Requests, reply: CommandReply) !ReadFailure {
        const failure = try decodeReadFailure(reply, false);
        if (self.read_failure) |slot| if (slot.* == null) {
            slot.* = failure;
        };
        return failure;
    }

    fn check(self: Requests) error{Cancelled}!void {
        if (self.cancellation) |token| if (token.stopped.load(.acquire)) return error.Cancelled;
    }

    pub fn sendCaptured(self: Requests, captured: *CapturedRecord, drop_reply: ?[]const u8, reply_buffer: *ReplyBuffer) !MutationReply {
        reply_buffer.len = 0;
        try self.check();
        const paths = try platform.resolveClientPaths(self.io, captured.saved.store.slice());
        const reply = try sendSource(self, &paths, captured.target.route(), ResponseTiming.mutation, captured.length, &captured.file, null, drop_reply, null, reply_buffer, null);
        var result = decodeMutationReply(reply, captured.saved.session.slice(), captured.target);
        result.context = captured.saved;
        return result;
    }

    pub fn observeCommand(self: Requests, store_path: []const u8, key: []const u8, reply_buffer: *ReplyBuffer) !ObservationReply {
        reply_buffer.len = 0;
        try self.check();
        if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, "observe_command", paths.store.slice(), "key", key, null, null);
        const reply = try sendSource(self, &paths, "/v1/observe-command", .{}, body.len, null, body.slice(), null, null, reply_buffer, null);
        if (reply.status != 200) return .{ .failure = try decodeReadFailure(reply, false) };
        return .{ .observation = try CommandObservation.parse(reply, key) };
    }

    /// Reads the Host's Codex model catalog. `refresh` asks for a new fetch
    /// without waiting; poll until `completed` reaches `refresh_target`.
    /// Rows borrow `arena` and `reply_buffer`.
    pub fn modelCatalog(self: Requests, store_path: []const u8, refresh: bool, reply_buffer: *ModelCatalogBuffer, arena: std.mem.Allocator) !ModelCatalogReply {
        reply_buffer.len = 0;
        try self.check();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try body.append("{\"version\":\"1\",\"kind\":\"model_catalog\",\"store\":");
        try body.appendJsonString(paths.store.slice());
        try body.append(if (refresh) ",\"refresh\":true}" else ",\"refresh\":false}");
        const reply = try sendSource(self, &paths, "/v1/model-catalog", .{}, body.len, null, body.slice(), null, null, reply_buffer, null);
        if (reply.status != 200) return .{ .failure = try decodeReadFailure(reply, false) };
        return .{ .listing = try ModelCatalogListing.parse(arena, reply.body) };
    }

    pub fn observeMessage(self: Requests, address: *const MessageAddress) !ObservationReply {
        var buffer: ReplyBuffer = .{};
        const reply = try self.observeCommand(address.store.slice(), address.key.slice(), &buffer);
        return switch (reply) {
            .observation => |observation| .{ .observation = try observation.forMessage(address) },
            .failure => reply,
        };
    }

    pub fn readResult(self: Requests, store_path: []const u8, key: []const u8, destination: std.Io.File, reply_buffer: *ReplyBuffer) !ResultReadReply {
        return readResultWithSink(self, store_path, key, destination, reply_buffer);
    }

    pub fn readResultStream(self: Requests, store_path: []const u8, key: []const u8, sink: anytype, reply_buffer: *ReplyBuffer) !ResultReadReply {
        return readResultWithSink(self, store_path, key, sink, reply_buffer);
    }

    /// File or synchronous feed([]const u8) sink; windows expire on feed return.
    /// Sink lifetime/close belongs to the caller. Sink work is not preemptible.
    pub fn inspectSession(self: Requests, store_path: []const u8, session: []const u8, profile: protocol.ReportProfile, sink: anytype, reply_buffer: *ReplyBuffer) !ReportReply {
        reply_buffer.len = 0;
        try self.check();
        if (session.len == 0 or session.len > protocol.max_session_bytes or
            !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, "inspect_session", paths.store.slice(), "session", session, null, profile);
        const fd = try openRead(self, &paths, "/v1/inspect-session", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    /// Same synchronous sink contract as inspectSession; no complete page copy.
    pub fn listSessions(self: Requests, store_path: []const u8, workspace: ?[]const u8, cursor: SessionListCursor, sink: anytype, reply_buffer: *ReplyBuffer) !ReportReply {
        reply_buffer.len = 0;
        try self.check();
        if (workspace) |value| {
            if (value.len == 0 or value.len > protocol.max_workspace_bytes or
                !std.unicode.utf8ValidateSlice(value)) return error.InvalidWorkspace;
        }
        try cursor.validate();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderSessionListRequest(&body, paths.store.slice(), workspace, cursor);
        const fd = try openRead(self, &paths, "/v1/list-sessions", body.slice());
        defer closeSocket(self.io, fd);
        return readReportResponse(self, fd, sink, reply_buffer);
    }

    pub fn readActionArguments(self: Requests, store_path: []const u8, session: []const u8, action_id: u64, destination: std.Io.File, reply_buffer: *ReplyBuffer) !ResultReply {
        return readActionContent(self, store_path, session, action_id, "read_action_arguments", "/v1/read-action-arguments", destination, reply_buffer);
    }

    pub fn readActionCallId(self: Requests, store_path: []const u8, session: []const u8, action_id: u64, destination: std.Io.File, reply_buffer: *ReplyBuffer) !ResultReply {
        return readActionContent(self, store_path, session, action_id, "read_action_call_id", "/v1/read-action-call-id", destination, reply_buffer);
    }

    pub fn conversationPage(self: Requests, store_path: []const u8, session: []const u8, cursor: ConversationCursor) !ConversationPageReply {
        try self.check();
        try validateIdentityInputs("", session);
        try cursor.validate();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, "conversation_page", paths.store.slice(), "session", session, null, null);
        body.len -= 1;
        try body.appendFmt(",\"end\":\"{d}\",\"before_position\":\"{d}\",\"before_ordinal\":\"{d}\"}}", .{ cursor.end, cursor.before_position, cursor.before_ordinal });
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
            .report => .{ .page = try ConversationPage.parse(sink.buffer.slice(), cursor) },
            .command => |value| .{ .failure = try decodeReadFailure(value, false) },
        };
    }

    /// Stream prefix bytes; bind length, digest and EOF before the final window.
    /// Null selects raw export, still requiring framing and physical EOF.
    pub fn readConversationContent(self: Requests, store_path: []const u8, session: []const u8, position: u64, ordinal: u64, expected: ?CommandObservation.ContentReference, sink: anytype) !?ReadFailure {
        try self.check();
        try validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64) or ordinal > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, "conversation_content", paths.store.slice(), "session", session, null, null);
        body.len -= 1;
        try body.appendFmt(",\"position\":\"{d}\",\"ordinal\":\"{d}\",\"start\":\"0\",\"stream\":true}}", .{ position, ordinal });
        const fd = try openRead(self, &paths, "/v1/conversation-content", body.slice());
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, expected, sink);
    }

    /// Returns owned metadata only; no scratch, payload or traversal escapes.
    pub fn proposalPage(self: Requests, store_path: []const u8, session: []const u8, cursor: ProposalCursor) !ProposalPageReply {
        try self.check();
        try validateIdentityInputs("", session);
        try (protocol.ProposalPage{ .end = cursor.end, .after = cursor.after }).validate();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, "proposal_page", paths.store.slice(), "session", session, null, null);
        body.len -= 1;
        try body.append(",\"end\":");
        if (cursor.end) |end| try body.appendFmt("\"{d}\"", .{end}) else try body.append("null");
        try body.appendFmt(",\"after\":\"{d}\"}}", .{cursor.after});
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
            .report => .{ .page = try ProposalPage.parse(sink.buffer.slice(), cursor) },
            .command => |reply| .{ .failure = try decodeReadFailure(reply, false) },
        };
    }

    /// Complete bytes once, through the ordinary synchronous sink contract.
    /// Failure may follow delivered prefix bytes; it never returns success then.
    pub fn readProposalField(self: Requests, store_path: []const u8, session: []const u8, position: u64, field: ProposalField, expected: ?CommandObservation.ContentReference, sink: anytype) !?ReadFailure {
        try self.check();
        try validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, "proposal_field", paths.store.slice(), "session", session, null, null);
        body.len -= 1;
        try body.appendFmt(",\"position\":\"{d}\",\"field\":\"{s}\"}}", .{ position, @tagName(field) });
        const fd = try openRead(self, &paths, "/v1/proposal-field", body.slice());
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, expected, sink);
    }

    pub fn activityPage(self: Requests, store_path: []const u8, session: []const u8, cursor: ActivityCursor) !ActivityPageReply {
        try self.check();
        try validateIdentityInputs("", session);
        try cursor.validate();
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, "activity_page", paths.store.slice(), "session", session, null, null);
        body.len -= 1;
        try body.append(",\"end\":");
        if (cursor.end) |end| try body.appendFmt("\"{d}\"", .{end}) else try body.append("null");
        try body.appendFmt(",\"position\":\"{d}\",\"ordinal\":", .{cursor.position});
        if (cursor.ordinal) |ordinal| try body.appendFmt("\"{d}\"", .{ordinal}) else try body.append("null");
        try body.appendFmt(",\"direction\":\"{s}\"}}", .{@tagName(cursor.direction)});
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
            .report => .{ .page = try ActivityPage.parse(sink.buffer.slice(), cursor) },
            .command => |reply| .{ .failure = try decodeReadFailure(reply, false) },
        };
    }

    /// Complete scoped bytes once; callers still use readProposalField for calls.
    pub fn readActivityContent(self: Requests, store_path: []const u8, session: []const u8, position: u64, ordinal: u64, expected: ?CommandObservation.ContentReference, sink: anytype) !?ReadFailure {
        try self.check();
        try validateIdentityInputs("", session);
        if (position == 0 or position > std.math.maxInt(i64) or ordinal > std.math.maxInt(i64)) return error.InvalidTarget;
        const paths = try platform.resolveClientPaths(self.io, store_path);
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, "activity_content", paths.store.slice(), "session", session, null, null);
        body.len -= 1;
        try body.appendFmt(",\"position\":\"{d}\",\"ordinal\":\"{d}\"}}", .{ position, ordinal });
        const fd = try openRead(self, &paths, "/v1/activity-content", body.slice());
        defer closeSocket(self.io, fd);
        return readPublicContentResponse(self, fd, expected, sink);
    }
};

fn readPublicContentResponse(requests: Requests, fd: std.posix.fd_t, expected: ?CommandObservation.ContentReference, sink: anytype) !?ReadFailure {
    const head = try readResponseHeadUntil(requests, fd, .{}, null);
    if (head.status != 200) {
        if (head.kind != .command_json) return error.InvalidResponse;
        var reply_buffer: ReplyBuffer = .{};
        return try decodeReadFailure(try readCommandBodyUntil(requests, fd, head, &reply_buffer, .{}, null), false);
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

fn completeContentEOF(requests: Requests, fd: std.posix.fd_t, actual: [32]u8, expected: ?CommandObservation.ContentReference) !void {
    if (expected) |reference| if (!std.mem.eql(u8, &actual, &reference.digest)) return error.ContentBindingMismatch;
    var tail: [1]u8 = undefined;
    if (try readRequest(requests, fd, &tail, ResponseTiming.transfer.deadline(std.Io.Clock.Timestamp.now(requests.io, .awake).raw.nanoseconds, null, true)) != 0) return error.InvalidResponse;
}

pub const ConversationCursor = struct {
    end: u64,
    before_position: u64 = 0,
    before_ordinal: u64 = 0,
    pub fn validate(self: ConversationCursor) !void {
        if (self.end > std.math.maxInt(i64) or self.before_position > self.end or self.before_ordinal > std.math.maxInt(i64) or
            (self.before_position == 0 and self.before_ordinal != 0)) return error.InvalidCursor;
    }
};
pub const ConversationPageReply = union(enum) { page: ConversationPage, failure: ReadFailure };
pub const ConversationPage = struct {
    pub const Item = struct {
        position: u64,
        ordinal: u64,
        kind: enum { user, assistant, tool_result },
        content: CommandObservation.ContentReference,
        presentation: ?protocol.ToolPresentation = null,
    };
    end: u64,
    items: [protocol.public_conversation_page_items]Item = undefined,
    count: usize = 0,
    more: bool,
    pub fn continuation(self: *const ConversationPage) ?ConversationCursor {
        if (!self.more) return null;
        const last = self.items[self.count - 1];
        return .{ .end = self.end, .before_position = last.position, .before_ordinal = last.ordinal };
    }
    pub fn parse(bytes: []const u8, cursor: ConversationCursor) !ConversationPage {
        try cursor.validate();
        const Row = struct {
            position: JsonString(20),
            ordinal: JsonString(20),
            kind: JsonEnum(@FieldType(Item, "kind")),
            content: struct { bytes: JsonString(20), sha256: JsonString(64), display: JsonString(16) },
            presentation: ?JsonToolPresentation = null,
        };
        const Rows = struct {
            values: [protocol.public_conversation_page_items]Row = undefined,
            count: usize = 0,
            pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var rows: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (rows.count == rows.values.len) return error.LengthMismatch;
                    rows.values[rows.count] = try std.json.innerParse(Row, a, source, options);
                    rows.count += 1;
                }
                _ = try source.next();
                return rows;
            }
        };
        const Wire = struct {
            version: JsonString(8),
            type: JsonString(32),
            direction: JsonString(16),
            end: JsonString(20),
            items: Rows,
            more: bool,
            before_position: ?JsonString(20) = null,
            before_ordinal: ?JsonString(20) = null,
        };
        var storage: [2 * protocol.max_conversation_page_response_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidConversationPage;
        if (!wire.version.eql("1") or !wire.type.eql("conversation_page") or !wire.direction.eql("newest_first")) return error.InvalidConversationPage;
        var page: ConversationPage = .{ .end = try mutationId(wire.end, true), .count = wire.items.count, .more = wire.more };
        if (page.end > std.math.maxInt(i64) or (cursor.end != 0 and page.end != cursor.end) or (page.more and page.count != page.items.len)) return error.InvalidConversationPage;
        var position = cursor.before_position;
        var ordinal = cursor.before_ordinal;
        for (wire.items.values[0..page.count], page.items[0..page.count]) |row, *item| {
            item.* = .{ .position = try mutationId(row.position, false), .ordinal = try mutationId(row.ordinal, true), .kind = row.kind.value, .content = .{ .bytes = try mutationId(row.content.bytes, true), .digest = undefined } };
            item.presentation = if (row.presentation) |p| p.value else null;
            if ((item.kind == .tool_result) != (item.presentation != null)) return error.InvalidConversationPage;
            if (item.presentation) |p| if (p.publication_position != item.position) return error.InvalidConversationPage;
            if (item.position > page.end or item.ordinal > std.math.maxInt(i64) or item.content.bytes > protocol.max_sqlite_content_bytes or
                ((item.kind == .tool_result) != (item.ordinal != 0)) or !row.content.display.eql("omitted") or row.content.sha256.slice().len != 64 or
                (position != 0 and (item.position > position or (item.position == position and item.ordinal >= ordinal)))) return error.InvalidConversationPage;
            _ = std.fmt.hexToBytes(&item.content.digest, row.content.sha256.slice()) catch return error.InvalidConversationPage;
            position = item.position;
            ordinal = item.ordinal;
        }
        if (page.more) {
            if (wire.before_position == null or wire.before_ordinal == null or
                try mutationId(wire.before_position.?, false) != position or try mutationId(wire.before_ordinal.?, true) != ordinal) return error.InvalidConversationPage;
        } else if (wire.before_position != null or wire.before_ordinal != null) return error.InvalidConversationPage;
        return page;
    }
};

pub const ProposalField = protocol.ProposalField;
pub const ProposalCursor = struct { end: ?u64 = null, after: u64 = 0 };
pub const ProposalPageReply = union(enum) { page: ProposalPage, failure: ReadFailure };
pub const ProposalPage = struct {
    end: u64,
    items: [protocol.proposal_page_items]protocol.ProposalMetadata = undefined,
    count: usize = 0,
    more: bool,

    pub fn continuation(self: *const ProposalPage) ?ProposalCursor {
        return if (self.more) .{ .end = self.end, .after = self.items[self.count - 1].position } else null;
    }

    pub fn parse(bytes: []const u8, cursor: ProposalCursor) !ProposalPage {
        if (bytes.len > protocol.max_proposal_page_response_bytes) return error.InvalidProposalPage;
        try (protocol.ProposalPage{ .end = cursor.end, .after = cursor.after }).validate();
        const Ref = struct { bytes: JsonString(20), sha256: JsonString(64) };
        const Item = struct {
            position: JsonString(20),
            operation: JsonString(20),
            turn: JsonString(20),
            call_ordinal: JsonString(20),
            action: ?JsonString(20),
            rejection: ?JsonEnum(protocol.ProposalRejection),
            fields: struct { item_id: Ref, name: Ref, call_id: Ref, arguments: Ref },
        };
        const Items = struct {
            values: [protocol.proposal_page_items]Item = undefined,
            count: usize = 0,
            pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.values.len) return error.LengthMismatch;
                    result.values[result.count] = try std.json.innerParse(Item, a, source, options);
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const Wire = struct { version: JsonString(8), type: JsonString(32), end: JsonString(20), items: Items, more: bool };
        // Fixed scanner storage; no payload tokens or history-sized allocation.
        var storage: [2 * protocol.max_proposal_page_response_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), bytes, .{}) catch return error.InvalidProposalPage;
        if (!wire.version.eql("1") or !wire.type.eql("proposal_page")) return error.InvalidProposalPage;
        var page: ProposalPage = .{ .end = try mutationId(wire.end, true), .count = wire.items.count, .more = wire.more };
        if (page.end > std.math.maxInt(i64) or (cursor.end != null and cursor.end.? != page.end) or
            page.end < cursor.after or (page.more and page.count != page.items.len)) return error.InvalidProposalPage;
        var previous = cursor.after;
        for (wire.items.values[0..wire.items.count], page.items[0..page.count]) |item, *result| {
            result.* = .{
                .position = try mutationId(item.position, false),
                .operation = try mutationId(item.operation, false),
                .turn = try mutationId(item.turn, false),
                .call_ordinal = try mutationId(item.call_ordinal, true),
                .action = if (item.action) |action| try mutationId(action, false) else null,
                .rejection = if (item.rejection) |code| code.value else null,
                .fields = undefined,
            };
            if (result.position <= previous or result.position > page.end or result.operation > std.math.maxInt(i64) or
                result.turn > std.math.maxInt(i64) or result.call_ordinal > std.math.maxInt(i64) or
                (result.action != null) == (result.rejection != null) or
                (result.action != null and result.action.? > std.math.maxInt(i64))) return error.InvalidProposalPage;
            inline for (comptime std.meta.tags(ProposalField), 0..) |field, index| {
                const reference = @field(item.fields, @tagName(field));
                if (reference.sha256.slice().len != 64) return error.InvalidProposalPage;
                result.fields[index].length = try mutationId(reference.bytes, true);
                if (result.fields[index].length > std.math.maxInt(i64)) return error.InvalidProposalPage;
                _ = std.fmt.hexToBytes(&result.fields[index].digest, reference.sha256.slice()) catch return error.InvalidProposalPage;
            }
            previous = result.position;
        }
        if (page.more and previous >= page.end) return error.InvalidProposalPage;
        return page;
    }
};

pub const ActivityCursor = struct {
    end: ?u64 = null,
    position: u64 = 0,
    ordinal: ?u64 = null,
    direction: @FieldType(protocol.ActivityPage, "direction") = .forward,
    pub fn validate(self: ActivityCursor) !void {
        try (protocol.ActivityPage{ .end = self.end, .position = self.position, .ordinal = self.ordinal, .direction = self.direction }).validate();
    }
};
pub const ActivityPageReply = union(enum) { page: ActivityPage, failure: ReadFailure };
pub const ActivityPage = struct {
    facts: protocol.ActivityFacts,

    pub fn continuation(self: *const ActivityPage) ?ActivityCursor {
        const facts = &self.facts;
        if (!facts.more) return null;
        const last = facts.items[facts.count - 1];
        return .{ .end = facts.end, .position = last.position, .ordinal = last.ordinal, .direction = facts.direction };
    }

    pub fn parse(bytes: []const u8, cursor: ActivityCursor) !ActivityPage {
        try cursor.validate();
        if (bytes.len > protocol.max_activity_page_response_bytes) return error.InvalidActivityPage;
        const Ref = struct { bytes: JsonString(20), sha256: JsonString(64) };
        const Fact = protocol.ActivityItem;
        const Message = struct { admission: JsonString(20), key: JsonString(protocol.max_key_bytes), turn: ?JsonString(20), state: JsonEnum(@FieldType(Fact.Message, "state")), content: Ref };
        const Call = struct { operation: JsonString(20), turn: JsonString(20), call_ordinal: JsonString(20), action: ?JsonString(20), rejection: ?JsonEnum(protocol.ProposalRejection), fields: [4]Ref };
        const Outcome = struct { turn: JsonString(20), operation: JsonString(20), code: JsonString(96), content: ?Ref };
        const Stop = struct { key: JsonString(protocol.max_key_bytes), turn: ?JsonString(20), cutoff: JsonString(20), completion: JsonEnum(@FieldType(Fact.Stop, "completion")) };
        const Item = struct { position: JsonString(20), ordinal: JsonString(20), value: union(enum) { admission: Message, user: Message, assistant: Ref, call: Call, tool_result: struct { content: Ref, presentation: JsonToolPresentation }, outcome: Outcome, stop: Stop } };
        const Items = struct {
            values: [16]Item = undefined,
            count: usize = 0,
            pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.values.len) return error.LengthMismatch;
                    result.values[result.count] = try std.json.innerParse(Item, a, source, options);
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const CallEntry = struct { operation: JsonString(20), ordinal: JsonString(20), presentation: JsonToolPresentation };
        const Calls = struct {
            values: [3]CallEntry = undefined,
            count: usize = 0,
            pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.values.len) return error.LengthMismatch;
                    result.values[result.count] = try std.json.innerParse(CallEntry, a, source, options);
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const Wire = struct { version: JsonString(8), type: JsonString(32), end: JsonString(20), direction: JsonEnum(@FieldType(ActivityCursor, "direction")), items: Items, more: bool, call_activity: struct { total: JsonString(20), entries: Calls } };
        var storage: [2 * protocol.max_activity_page_response_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const wire = std.json.parseFromSliceLeaky(Wire, fixed.allocator(), bytes, .{}) catch return error.InvalidActivityPage;
        var page: ActivityPage = .{ .facts = .{ .end = try id(wire.end, true), .direction = wire.direction.value, .more = wire.more, .count = wire.items.count } };
        if (!wire.version.eql("1") or !wire.type.eql("activity_page") or page.facts.direction != cursor.direction or
            (cursor.end != null and cursor.end.? != page.facts.end) or cursor.position > page.facts.end or
            (wire.more and wire.items.count != 16)) return error.InvalidActivityPage;
        var position = cursor.position;
        var ordinal = cursor.ordinal;
        for (wire.items.values[0..wire.items.count], page.facts.items[0..wire.items.count]) |item, *fact| {
            fact.* = .{ .position = try id(item.position, false), .ordinal = try id(item.ordinal, true), .value = undefined };
            const after = fact.position > position or (ordinal != null and fact.position == position and fact.ordinal > ordinal.?);
            const before = fact.position < position or (ordinal != null and fact.position == position and fact.ordinal < ordinal.?);
            if (fact.position > page.facts.end or (position != 0 and !(if (cursor.direction == .forward) after else before)) or
                ((item.value == .tool_result) != (fact.ordinal != 0))) return error.InvalidActivityPage;
            switch (item.value) {
                .admission, .user => |message| {
                    const value: Fact.Message = .{ .admission = try id(message.admission, false), .key = message.key.value, .turn = if (message.turn) |turn| try id(turn, false) else null, .state = message.state.value, .content = try content(message.content) };
                    if ((value.state == .applied) != (value.turn != null) or (item.value == .user and value.state != .applied)) return error.InvalidActivityPage;
                    fact.value = if (item.value == .user) .{ .user = value } else .{ .admission = value };
                },
                .assistant => |reference| fact.value = .{ .assistant = try content(reference) },
                .tool_result => |result| {
                    if (result.presentation.value.publication_position != fact.position) return error.InvalidActivityPage;
                    fact.value = .{ .tool_result = .{ .content = try content(result.content), .presentation = result.presentation.value } };
                },
                .call => |call| {
                    var value: Fact.Call = .{ .position = fact.position, .operation = try id(call.operation, false), .turn = try id(call.turn, false), .call_ordinal = try id(call.call_ordinal, true), .action = if (call.action) |action| try id(action, false) else null, .rejection = if (call.rejection) |code| code.value else null, .fields = undefined };
                    if ((value.action != null) == (value.rejection != null)) return error.InvalidActivityPage;
                    for (call.fields, &value.fields) |reference, *field| {
                        const decoded = try content(reference);
                        field.* = .{ .length = decoded.length, .digest = decoded.digest };
                    }
                    fact.value = .{ .call = value };
                },
                .outcome => |outcome| {
                    if (outcome.code.slice().len == 0 or (outcome.code.eql("completed") != (outcome.content != null))) return error.InvalidActivityPage;
                    fact.value = .{ .outcome = .{ .turn = try id(outcome.turn, false), .operation = try id(outcome.operation, false), .code = outcome.code.value, .content = if (outcome.content) |reference| try content(reference) else null } };
                },
                .stop => |stop| {
                    if (stop.turn == null and stop.completion.value == .pending) return error.InvalidActivityPage;
                    fact.value = .{ .stop = .{ .key = stop.key.value, .turn = if (stop.turn) |turn| try id(turn, false) else null, .cutoff = try id(stop.cutoff, true), .completion = stop.completion.value } };
                },
            }
            position = fact.position;
            ordinal = fact.ordinal;
        }
        page.facts.call_activity.total = try id(wire.call_activity.total, true);
        page.facts.call_activity.count = wire.call_activity.entries.count;
        if (page.facts.call_activity.count != @min(3, page.facts.call_activity.total)) return error.InvalidActivityPage;
        const last = if (page.facts.direction == .forward and page.facts.more) page.facts.items[page.facts.count - 1] else null;
        const boundary_position = if (last) |item| item.position else page.facts.end;
        const boundary_ordinal: ?u64 = if (last) |item| item.ordinal else null;
        var previous: ?protocol.CallActivity.Entry = null;
        for (wire.call_activity.entries.values[0..page.facts.call_activity.count], page.facts.call_activity.entries[0..page.facts.call_activity.count]) |entry, *fact| {
            fact.* = .{ .operation = try id(entry.operation, false), .ordinal = try id(entry.ordinal, true), .presentation = entry.presentation.value };
            if (fact.ordinal == std.math.maxInt(i64)) return error.InvalidActivityPage;
            if (previous) |prior| if (fact.operation < prior.operation or
                fact.operation == prior.operation and fact.ordinal <= prior.ordinal) return error.InvalidActivityPage;
            if (fact.presentation.publication_position) |p| if (p < boundary_position or
                p == boundary_position and (boundary_ordinal == null or fact.ordinal + 1 <= boundary_ordinal.?)) return error.InvalidActivityPage;
            previous = fact.*;
        }
        return page;
    }

    fn id(value: anytype, zero: bool) !u64 {
        const result = try mutationId(value, zero);
        if (result > std.math.maxInt(i64)) return error.InvalidActivityPage;
        return result;
    }
    fn content(value: anytype) !protocol.ActivityItem.Content {
        const reference = try CommandObservation.decodeReference(value);
        if (reference.bytes > protocol.max_sqlite_content_bytes) return error.InvalidActivityPage;
        return .{ .length = reference.bytes, .digest = reference.digest };
    }
};

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
        from_capture_key,
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
};

pub const MessageInput = struct {
    store: []const u8,
    session: []const u8,
    text_path: []const u8,
    text: ?[]const u8 = null,
};

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
/// About 140 KiB; callers place it on the heap.
pub const ModelCatalogBuffer = protocol.FixedJsonBuffer(protocol.max_model_catalog_response_bytes);

pub const ModelCatalogReply = union(enum) {
    listing: ModelCatalogListing,
    failure: ReadFailure,
};

/// Validated facts from one `model_catalog` reply.
pub const ModelCatalogListing = struct {
    pub const Visibility = enum { list, hidden };
    pub const Row = struct { slug: []const u8, visibility: Visibility };

    applicable: bool,
    available: bool,
    age_seconds: ?u64,
    last_failure: ?codex_model_catalog.Reason,
    fetching: bool,
    completed: u64,
    refresh_target: ?u64,
    rows: []const Row,

    pub fn parse(arena: std.mem.Allocator, body: []const u8) !ModelCatalogListing {
        const Wire = struct {
            version: []const u8,
            type: []const u8,
            applicable: bool,
            available: bool,
            age_seconds: ?[]const u8,
            last_failure: ?[]const u8,
            fetching: bool,
            completed: []const u8,
            refresh_target: ?[]const u8,
            models: []const struct { slug: []const u8, visibility: []const u8 },
        };
        const wire = std.json.parseFromSliceLeaky(Wire, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.InvalidResponse;
        if (!std.mem.eql(u8, wire.version, "1") or !std.mem.eql(u8, wire.type, "model_catalog") or
            wire.available != (wire.age_seconds != null) or wire.models.len > codex_model_catalog.max_rows or
            (!wire.available and wire.models.len != 0) or (!wire.applicable and (wire.available or wire.last_failure != null))) return error.InvalidResponse;
        const rows = try arena.alloc(Row, wire.models.len);
        for (wire.models, rows) |model, *row| {
            if (model.slug.len == 0 or model.slug.len > protocol.max_model_bytes) return error.InvalidResponse;
            for (model.slug) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidResponse;
            row.* = .{ .slug = model.slug, .visibility = std.meta.stringToEnum(Visibility, model.visibility) orelse return error.InvalidResponse };
        }
        return .{
            .applicable = wire.applicable,
            .available = wire.available,
            .age_seconds = if (wire.age_seconds) |age| try decimal(age) else null,
            .last_failure = if (wire.last_failure) |reason| std.meta.stringToEnum(codex_model_catalog.Reason, reason) orelse return error.InvalidResponse else null,
            .fetching = wire.fetching,
            .completed = try decimal(wire.completed),
            .refresh_target = if (wire.refresh_target) |target| try decimal(target) else null,
            .rows = rows,
        };
    }

    fn decimal(text: []const u8) !u64 {
        if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidResponse;
        for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidResponse;
        return std.fmt.parseInt(u64, text, 10) catch error.InvalidResponse;
    }
};

pub const HostStatus = union(enum) {
    ready: struct {
        store: protocol.Bounded(protocol.max_store_bytes),
        instance: protocol.InstanceId,
        active_capacity: usize,
        intake_capacity: usize = 100,
        descriptor_limit: ?usize = null,
        capabilities: @FieldType(protocol.HostInfo, "capabilities"),
    },
    unavailable,
    owned_unavailable,
    incompatible,
    access_failure,
};

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
    try body.append("{\"version\":\"1\",\"kind\":\"host_stop\",\"store\":");
    try body.appendJsonString(paths.store.slice());
    try body.append("}");
    const reply = sendSource(.{ .io = io }, &paths, "/v1/control/host-stop", ResponseTiming.mutation, body.len, null, body.slice(), input.drop_reply, &input.instance, reply_buffer, null);
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
pub fn hostStatus(io: std.Io, store_path: []const u8) HostStatus {
    return hostStatusUntil(io, store_path, null);
}

/// Startup callers can bound the entire readiness loop, including each probe.
pub fn hostStatusUntil(io: std.Io, store_path: []const u8, deadline: ?i128) HostStatus {
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

fn readHostInfo(io: std.Io, paths: *const platform.Paths, deadline: ?i128) HostStatus {
    var body: protocol.RequestBuffer = .{};
    body.append("{\"version\":\"1\",\"kind\":\"host_info\",\"store\":") catch unreachable;
    body.appendJsonString(paths.store.slice()) catch unreachable;
    body.append("}") catch unreachable;
    var reply_buffer: ReplyBuffer = .{};
    const probe_end = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
    const until = @min(probe_end, deadline orelse probe_end);
    const reply = sendSource(.{ .io = io }, paths, "/v1/host-info", .{}, body.len, null, body.slice(), null, null, &reply_buffer, until) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied => .access_failure,
        error.WrongWireVersion, error.InvalidResponse, error.ResponseHeaderTooLarge, error.ResponseTooLarge, error.InvalidCharacter, error.Overflow => .incompatible,
        else => .owned_unavailable,
    };
    if (reply.status == 503) return if (validHostUnavailable(reply.body)) .owned_unavailable else .incompatible;
    if (reply.status != 200) return .incompatible;
    return parseHostInfo(reply.body, paths.store.slice()) catch .incompatible;
}

fn validHostUnavailable(body: []const u8) bool {
    if (body.len > protocol.max_control_error_response_bytes) return false;
    var parse_storage: [protocol.max_control_error_response_bytes * 2]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
    const reply = std.json.parseFromSliceLeaky(struct {
        version: []const u8,
        type: []const u8,
        code: []const u8,
    }, arena.allocator(), body, .{ .ignore_unknown_fields = false, .allocate = .alloc_if_needed }) catch return false;
    if (!std.mem.eql(u8, reply.version, protocol.wire_version)) return false;
    if (std.mem.eql(u8, reply.type, "host_unavailable")) return std.mem.eql(u8, reply.code, "dispatch_fenced");
    if (!std.mem.eql(u8, reply.type, "busy")) return false;
    return std.mem.eql(u8, reply.code, "connection_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "classification_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "ordinary_capacity_exhausted") or
        std.mem.eql(u8, reply.code, "discovery_capacity_exhausted");
}

fn parseHostInfo(body: []const u8, store: []const u8) !HostStatus {
    if (body.len > protocol.max_host_info_response_bytes) return error.InvalidHostInfo;
    var parse_storage: [protocol.max_host_info_response_bytes * 2]u8 = undefined;
    var arena = std.heap.FixedBufferAllocator.init(&parse_storage);
    const info = try std.json.parseFromSliceLeaky(protocol.HostInfo, arena.allocator(), body, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_if_needed,
    });
    if (!std.mem.eql(u8, info.version, protocol.wire_version) or
        !std.mem.eql(u8, info.type, "host_info") or
        !std.mem.eql(u8, info.store, store))
        return error.InvalidHostInfo;
    const finite_limit: ?[]const u8 = if (std.mem.eql(u8, info.descriptor_limit, "unlimited")) null else info.descriptor_limit;
    for ([_]?[]const u8{ info.active_capacity, info.intake_capacity, finite_limit }) |field| {
        const text = field orelse continue;
        if (text.len == 0 or text.len > 20 or (text.len > 1 and text[0] == '0')) return error.InvalidHostInfo;
        for (text) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidHostInfo;
    }
    const instance = protocol.parseInstanceId(info.instance) catch return error.InvalidHostInfo;
    const capacity = std.fmt.parseInt(usize, info.active_capacity, 10) catch return error.InvalidHostInfo;
    const intake_capacity = std.fmt.parseInt(usize, info.intake_capacity, 10) catch return error.InvalidHostInfo;
    if (intake_capacity < 10 or intake_capacity > 100) return error.InvalidHostInfo;
    const descriptor_limit = if (finite_limit) |text| std.fmt.parseInt(usize, text, 10) catch return error.InvalidHostInfo else null;
    var identity: protocol.Bounded(protocol.max_store_bytes) = .{};
    try identity.set(info.store);
    return .{ .ready = .{
        .store = identity,
        .instance = instance,
        .active_capacity = capacity,
        .intake_capacity = intake_capacity,
        .descriptor_limit = descriptor_limit,
        .capabilities = info.capabilities,
    } };
}

test "Host information is bounded and rejects ambiguous identities and capacity" {
    const golden = "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"17\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}";
    const result = try parseHostInfo(golden, "/one");
    try std.testing.expect(result.ready.store.eql("/one"));
    try std.testing.expectEqual(@as(usize, 17), result.ready.active_capacity);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, &result.ready.instance);
    try std.testing.expect(result.ready.capabilities.bash);
    try std.testing.expect(!result.ready.capabilities.model);
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(golden, "/other"));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0F\",\"active_capacity\":\"17\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
        "/one",
    ));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
        "/one",
    ));
    try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(
        "{\"version\":\"1\",\"type\":\"host_info\",\"store\":\"/one\",\"instance\":\"000102030405060708090a0b0c0d0e0f\",\"active_capacity\":\"01\",\"capabilities\":{\"bash\":true,\"model\":false,\"managed_authentication\":false}}",
        "/one",
    ));
    for ([_][]const u8{ "intake_capacity", "descriptor_limit" }) |field| {
        for ([_][]const u8{ "010", "+10", "1_0", "", "18446744073709551616" }) |value| {
            const extra = try std.fmt.allocPrint(std.testing.allocator, "\"{s}\":\"{s}\",\"capabilities\":", .{ field, value });
            defer std.testing.allocator.free(extra);
            const malformed = try std.mem.replaceOwned(u8, std.testing.allocator, golden, "\"capabilities\":", extra);
            defer std.testing.allocator.free(malformed);
            try std.testing.expectError(error.InvalidHostInfo, parseHostInfo(malformed, "/one"));
        }
    }
    const reduced = try std.mem.replaceOwned(u8, std.testing.allocator, golden, "\"capabilities\":", "\"intake_capacity\":\"10\",\"descriptor_limit\":\"0\",\"capabilities\":");
    defer std.testing.allocator.free(reduced);
    const reduced_info = try parseHostInfo(reduced, "/one");
    try std.testing.expectEqual(@as(usize, 10), reduced_info.ready.intake_capacity);
    try std.testing.expectEqual(@as(?usize, 0), reduced_info.ready.descriptor_limit);
    try std.testing.expectEqual(@as(usize, 100), result.ready.intake_capacity);
    try std.testing.expectEqual(@as(?usize, null), result.ready.descriptor_limit);
    for ([_]struct { needle: []const u8, replacement: []const u8 }{
        .{ .needle = "\"store\":\"/one\"", .replacement = "\"store\":\"/other\",\"store\":\"/one\"" },
        .{ .needle = "\"bash\":true", .replacement = "\"bash\":false,\"bash\":true" },
    }) |case| {
        const duplicated = try std.mem.replaceOwned(u8, std.testing.allocator, golden, case.needle, case.replacement);
        defer std.testing.allocator.free(duplicated);
        try std.testing.expectError(error.DuplicateField, parseHostInfo(duplicated, "/one"));
    }
}

test "Host unavailable replies require a known complete error" {
    for ([_][]const u8{
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"connection_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"classification_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"host_unavailable\",\"code\":\"dispatch_fenced\"}",
    }) |body| try std.testing.expect(validHostUnavailable(body));
    for ([_][]const u8{
        "{}",
        "{\"version\":\"2\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"dispatch_fenced\"}",
        "{\"version\":\"1\",\"type\":\"host_unavailable\",\"code\":\"unknown\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"code\":\"ordinary_capacity_exhausted\"}",
        "{\"version\":\"2\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"host_unavailable\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted_other\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"nested\":{\"code\":\"discovery_capacity_exhausted\"}}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\",\"code\":\"discovery_capacity_exhausted\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"discovery_capacity_exhausted\"",
    }) |body| try std.testing.expect(!validHostUnavailable(body));
}

pub const CommandReply = struct {
    status: u16,
    // Borrowed from the caller's ReplyBuffer until that buffer is reused.
    body: []const u8,
};

pub const ResultReply = union(enum) {
    answer: struct { bytes: u64 },
    command: CommandReply,
};

pub const ObservationReply = union(enum) {
    observation: CommandObservation,
    failure: ReadFailure,
};

pub const ResultReadReply = union(enum) {
    answer: struct { bytes: u64 },
    failure: ReadFailure,
};

/// Owned diagnostic; an unsuccessful read says nothing about prior admission.
pub const ReadFailure = struct {
    status: u16,
    diagnostic: InvocationDiagnostic,

    pub fn writeDiagnostic(self: ReadFailure, out: *std.Io.Writer) !void {
        const Text = @import("TerminalText.zig");
        try out.print("HTTP {d}; type: ", .{self.status});
        var text: Text = .{ .mode = .line };
        try text.feed(out, self.diagnostic.type.slice());
        try text.finish(out);
        try out.writeAll("; code: ");
        try text.feed(out, self.diagnostic.code.slice());
        try text.finish(out);
    }

    pub fn err(self: ReadFailure) error{ CanonicalStoreFailure, HostInvocationFailed } {
        return if (self.diagnostic.code.eql("canonical_store_failure")) error.CanonicalStoreFailure else error.HostInvocationFailed;
    }
};

pub const ReportReply = union(enum) {
    report: struct { bytes: u64 },
    command: CommandReply,
};

pub const CurrentReply = union(enum) {
    unconfigured,
    current: Current,
    failure: ReadFailure,

    /// The caller retains immutable, offset-zero scratch through any traversal.
    pub fn decode(io: std.Io, file: std.Io.File, session: []const u8, reply: ReportReply) !CurrentReply {
        return switch (reply) {
            .command => |command| .{ .failure = try decodeReadFailure(command, false) },
            .report => |report| Current.read(io, file, report.bytes, session, NoAttention{}) catch return error.InvalidObservation,
        };
    }

    pub fn writeJson(self: *const CurrentReply, io: std.Io, file: std.Io.File, writer: *std.Io.Writer) !void {
        return switch (self.*) {
            .unconfigured => writer.writeAll("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}"),
            .current => |*current| current.writeJson(io, file, writer),
            .failure => |failure| failure.err(),
        };
    }
};

/// Fixed owned facts; the variable attention population stays in borrowed scratch.
pub const Current = struct {
    pub const Id = ReportNumber(false);
    pub const Count = ReportNumber(true);
    pub const Reference = struct {
        bytes: Count,
        sha256: JsonString(64),
        type: OmittableJson(JsonEnum(enum { text })) = .{},

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Reference {
            const Wire = struct { bytes: Count, sha256: JsonString(64), type: @FieldType(Reference, "type") = .{} };
            const wire = try std.json.innerParse(Wire, allocator, source, options);
            var digest: [32]u8 = undefined;
            if (wire.sha256.slice().len != 64) return error.InvalidObservation;
            _ = std.fmt.hexToBytes(&digest, wire.sha256.slice()) catch return error.InvalidObservation;
            return .{ .bytes = wire.bytes, .sha256 = wire.sha256, .type = wire.type };
        }

        pub fn jsonStringify(self: Reference, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Settings = struct {
        reference: JsonString(protocol.max_session_bytes),
        workspace: JsonString(protocol.max_workspace_bytes),
        provider: JsonEnum(protocol.Provider),
        model: JsonString(protocol.max_model_bytes),
        revision: Id,
        tools: ReportTools,
        permission_mode: JsonEnum(enum { ask, bypass }),
        instructions: Reference,
        output_schema: ?Reference,
        compaction_trigger: ?PolicyNumber(false),
        output_reservation: PolicyNumber(true),
        compaction_trigger_override: ?PolicyNumber(false),
        output_reservation_override: ?PolicyNumber(true),
        // Omission is not evidence of provider default on older producers.
        reasoning_effort: OmittableJson(?JsonEnum(enum { none, low, medium, high, xhigh, max })) = .{},
        // Absent from Hosts that predate the catalog.
        model_catalog: OmittableJson(ModelCatalog) = .{},

        pub fn jsonStringify(self: Settings, jw: anytype) !void {
            try writeObject(self, jw);
        }

        /// The Host's verdict for this Session's model at report time.
        pub fn modelCatalog(self: *const Settings) ?codex_model_catalog.Observation {
            const value = self.model_catalog.value orelse return null;
            const age_ms: ?i64 = if (value.age_seconds) |age| @as(i64, std.fmt.parseInt(u63, age.slice(), 10) catch unreachable) *| 1000 else null;
            return .{ .age_ms = age_ms, .verdict = switch (value.verdict.value) {
                .listed => .listed,
                .hidden => .hidden,
                .absent => .absent,
                .unchecked => .{ .unchecked = value.reason.?.value },
            } };
        }
    };
    pub const ModelCatalog = struct {
        verdict: JsonEnum(std.meta.Tag(codex_model_catalog.Verdict)),
        reason: ?JsonEnum(codex_model_catalog.Reason),
        age_seconds: ?PolicyNumber(true),
    };
    pub const Work = struct {
        status: JsonEnum(enum { idle, runnable, in_flight, waiting_for_permission, completed, cancelled, failed }),
        turn: OmittableJson(Id) = .{},
        operation: OmittableJson(Id) = .{},
        latest_outcome: ?struct { code: JsonString(96), content: ?Reference },

        pub fn jsonStringify(self: Work, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Recent = struct { turn: Id, message: JsonString(protocol.max_key_bytes), outcome: JsonString(96) };
    pub const Execution = struct {
        status: JsonEnum(enum { partial, unavailable }),
        reason: OmittableJson(JsonEnum(enum { session_not_found })) = .{},
        dispatch_fenced: OmittableJson(bool) = .{},
        custody_occupied: OmittableJson(Count) = .{},
        scratch_used_bytes: OmittableJson(Count) = .{},
        unavailable: OmittableJson(struct {
            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.InvalidObservation;
                _ = try std.json.innerParse(JsonEnum(enum { structured_output }), allocator, source, options);
                if (try source.next() != .array_end) return error.InvalidObservation;
                return .{};
            }

            pub fn jsonStringify(_: @This(), jw: anytype) !void {
                try jw.write([_][]const u8{"structured_output"});
            }
        }) = .{},

        pub fn jsonStringify(self: Execution, jw: anytype) !void {
            try writeObject(self, jw);
        }
    };
    pub const Attention = union(enum) {
        unresolved: struct {
            presentation: JsonToolPresentation,
            action: Id,
            parent_operation: Id,
            call_ordinal: Count,
            tool: JsonEnum(enum { bash }),
            permission_revision: Id,
            authorization: JsonEnum(enum { pending, bypass, allow_once }),
            call_id: Reference,
            arguments: Reference,
        },
        resolved: struct {
            presentation: JsonToolPresentation,
            action: Id,
            parent_operation: Id,
            call_ordinal: Count,
            code: JsonString(32),
            acceptance_position: Id,
            result: Reference,
        },
        rejected: struct {
            presentation: JsonToolPresentation,
            parent_operation: Id,
            call_ordinal: Count,
            code: JsonString(32),
            acceptance_position: Id,
            result: Reference,
            item_id: Reference,
            name: Reference,
            call_id: Reference,
            arguments: Reference,
        },
        actionable: struct { action: Id, permission_revision: Id },
    };

    settings: Settings,
    pending_messages: u64,
    work: Work,
    selected_message: ?JsonString(protocol.max_key_bytes),
    recent: [10]Recent,
    recent_count: usize,
    action_total: u64,
    rejected_total: u64,
    actionable_count: u64,
    first_action: ?u64,
    indeterminate_count: u64,
    first_indeterminate: ?u64,
    execution: Execution,
    bytes: u64,

    fn writeObject(value: anytype, jw: anytype) !void {
        try jw.beginObject();
        inline for (comptime std.meta.fieldNames(@TypeOf(value))) |name| {
            const item = @field(value, name);
            const present = if (comptime std.meta.hasFn(@TypeOf(item), "isPresent")) item.isPresent() else true;
            if (present) {
                try jw.objectField(name);
                try jw.write(item);
            }
        }
        try jw.endObject();
    }

    /// Effectful traversal requires the same immutable offset-zero capture
    /// successfully decoded into these facts. Row slices expire at visit return.
    /// The caller owns the file through all synchronous callbacks and return.
    pub fn traverse(self: *const Current, io: std.Io, file: std.Io.File, sink: anytype) !void {
        _ = try read(io, file, self.bytes, self.settings.reference.slice(), sink);
    }

    pub fn writeJson(self: *const Current, io: std.Io, file: std.Io.File, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":");
        try std.json.Stringify.value(self.settings, .{}, writer);
        try writer.print(",\"pending_messages\":\"{d}\",\"work\":", .{self.pending_messages});
        try std.json.Stringify.value(self.work, .{}, writer);
        try writer.writeAll(",\"selected_message\":");
        try std.json.Stringify.value(self.selected_message, .{}, writer);
        try writer.writeAll(",\"recent_messages\":");
        try std.json.Stringify.value(self.recent[0..self.recent_count], .{}, writer);
        try writer.print(",\"actions\":{{\"count\":\"{d}\",\"unresolved\":", .{self.action_total});
        try self.writeArray(io, file, .unresolved, writer);
        try writer.writeAll(",\"resolved\":");
        try self.writeArray(io, file, .resolved, writer);
        try writer.print("}},\"rejected_calls\":{{\"count\":\"{d}\",\"items\":", .{self.rejected_total});
        try self.writeArray(io, file, .rejected, writer);
        try writer.writeAll("},\"actionable_permissions\":");
        try self.writeArray(io, file, .actionable, writer);
        try writer.writeAll(",\"execution\":");
        try std.json.Stringify.value(self.execution, .{}, writer);
        try writer.writeAll("}");
    }

    fn writeArray(self: *const Current, io: std.Io, file: std.Io.File, tag: std.meta.Tag(Attention), writer: *std.Io.Writer) !void {
        const Sink = struct {
            writer: *std.Io.Writer,
            tag: std.meta.Tag(Attention),
            first: bool = true,
            fn visit(sink: *@This(), item: Attention) !void {
                switch (item) {
                    inline else => |row, kind| if (kind == sink.tag) {
                        if (!sink.first) try sink.writer.writeAll(",");
                        try std.json.Stringify.value(row, .{}, sink.writer);
                        sink.first = false;
                    },
                }
            }
        };
        var sink: Sink = .{ .writer = writer, .tag = tag };
        try writer.writeAll("[");
        try self.traverse(io, file, &sink);
        try writer.writeAll("]");
    }

    fn read(io: std.Io, file: std.Io.File, bytes: u64, session: []const u8, sink: anytype) !CurrentReply {
        const RecentRows = struct {
            rows: [10]Recent = undefined,
            count: usize = 0,
            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.InvalidObservation;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.rows.len) return error.InvalidObservation;
                    const row = try std.json.innerParse(Recent, allocator, source, options);
                    if (row.outcome.slice().len == 0) return error.InvalidObservation;
                    for (result.rows[0..result.count]) |prior| if (prior.message.eql(row.message.slice())) return error.InvalidObservation;
                    result.rows[result.count] = row;
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const Wire = struct {
            version: JsonString(8),
            type: JsonEnum(enum { session_report }),
            profile: JsonEnum(enum { current }),
            session: ?Settings,
            pending_messages: Count,
            work: OmittableJson(Work) = .{},
            selected_message: OmittableJson(?JsonString(protocol.max_key_bytes)) = .{},
            recent_messages: OmittableJson(RecentRows) = .{},
            actions: OmittableJson(struct { count: Count, unresolved: AttentionRows(.unresolved), resolved: AttentionRows(.resolved) }) = .{},
            rejected_calls: OmittableJson(struct { count: Count, items: AttentionRows(.rejected) }) = .{},
            actionable_permissions: OmittableJson(AttentionRows(.actionable)) = .{},
            execution: Execution,
        };
        if (bytes == 0) return error.InvalidObservation;
        var input: [protocol.content_window_bytes]u8 = undefined;
        var file_reader = file.reader(io, &.{});
        var body = file_reader.interface.limited(.limited64(bytes), &input);
        // Nesting storage survives rows; leaf tokens are separately freed after
        // copying into owned fields, never underneath a live scanner stack.
        var scanner_storage: [protocol.content_window_bytes]u8 = undefined;
        var scanner_allocator = std.heap.FixedBufferAllocator.init(&scanner_storage);
        var token_storage: [2 * protocol.max_workspace_bytes]u8 = undefined;
        var token_allocator = std.heap.FixedBufferAllocator.init(&token_storage);
        var reader = std.json.Reader.init(scanner_allocator.allocator(), &body.interface);
        defer reader.deinit();
        var source: CurrentSource(@TypeOf(sink)) = .{ .reader = &reader, .sink = sink };
        const wire = try std.json.parseFromTokenSourceLeaky(Wire, token_allocator.allocator(), &source, .{ .ignore_unknown_fields = true });
        if (body.remaining != .nothing or !wire.version.eql("1")) return error.InvalidObservation;
        const execution = wire.execution;
        const settings = wire.session orelse {
            if (wire.pending_messages.value != 0 or execution.status.value != .unavailable or execution.reason.value == null or
                execution.dispatch_fenced.value != null or execution.custody_occupied.value != null or execution.scratch_used_bytes.value != null or execution.unavailable.value != null or
                wire.work.value != null or wire.selected_message.value != null or wire.recent_messages.value != null or wire.actions.value != null or
                wire.rejected_calls.value != null or wire.actionable_permissions.value != null) return error.InvalidObservation;
            return .unconfigured;
        };
        if (!settings.reference.eql(session) or !std.fs.path.isAbsolute(settings.workspace.slice()) or settings.model.slice().len == 0 or
            settings.instructions.type.value != null or (if (settings.output_schema) |schema| schema.type.value != null else false) or
            execution.status.value != .partial or execution.reason.value != null or execution.dispatch_fenced.value == null or
            execution.custody_occupied.value == null or execution.scratch_used_bytes.value == null or execution.unavailable.value == null) return error.InvalidObservation;
        if (settings.model_catalog.value) |catalog| {
            if ((catalog.verdict.value == .unchecked) != (catalog.reason != null) or
                (catalog.verdict.value != .unchecked and catalog.age_seconds == null)) return error.InvalidObservation;
        }
        const work = wire.work.value orelse return error.InvalidObservation;
        if ((work.turn.value == null) != (work.operation.value == null) or (work.latest_outcome != null and work.turn.value == null)) return error.InvalidObservation;
        if (work.latest_outcome) |outcome| {
            if (outcome.code.slice().len == 0 or (if (outcome.content) |content| content.type.value != null else false)) return error.InvalidObservation;
        }
        const recent = wire.recent_messages.value orelse return error.InvalidObservation;
        const actions = wire.actions.value orelse return error.InvalidObservation;
        const rejected = wire.rejected_calls.value orelse return error.InvalidObservation;
        const actionable = wire.actionable_permissions.value orelse return error.InvalidObservation;
        if (rejected.count.value != rejected.items.count or actions.count.value < actions.unresolved.count + actions.resolved.count or actionable.count > actions.unresolved.count) return error.InvalidObservation;
        return .{ .current = .{
            .settings = settings,
            .pending_messages = wire.pending_messages.value,
            .work = work,
            .selected_message = wire.selected_message.value orelse return error.InvalidObservation,
            .recent = recent.rows,
            .recent_count = recent.count,
            .action_total = actions.count.value,
            .rejected_total = rejected.count.value,
            .actionable_count = actionable.count,
            .first_action = actionable.first,
            .indeterminate_count = actions.resolved.indeterminate,
            .first_indeterminate = actions.resolved.first_indeterminate,
            .execution = execution,
            .bytes = bytes,
        } };
    }
};

const NoAttention = struct {
    fn visit(_: @This(), _: Current.Attention) !void {}
};

fn PolicyNumber(comptime allow_zero: bool) type {
    return struct {
        text: JsonString(20),
        pub fn slice(self: *const @This()) []const u8 {
            return self.text.slice();
        }
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const text = try JsonString(20).jsonParse(allocator, source, options);
            const value = try mutationId(text, allow_zero);
            if (value > std.math.maxInt(i64)) return error.InvalidObservation;
            return .{ .text = text };
        }
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.text);
        }
    };
}

fn ReportNumber(comptime allow_zero: bool) type {
    return struct {
        value: u64,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const text = try JsonString(20).jsonParse(allocator, source, options);
            const value = try mutationId(text, allow_zero);
            if (value > std.math.maxInt(i64)) return error.InvalidObservation;
            return .{ .value = value };
        }

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            var bytes: [20]u8 = undefined;
            try jw.write(std.fmt.bufPrint(&bytes, "{d}", .{self.value}) catch unreachable);
        }
    };
}

const ReportTools = struct {
    bash: bool = false,
    edit: bool = false,
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !ReportTools {
        if (try source.next() != .array_begin) return error.InvalidObservation;
        var result: ReportTools = .{};
        while (try source.peekNextTokenType() != .array_end) {
            const tool = try std.json.innerParse(JsonEnum(enum { bash, edit }), allocator, source, options);
            switch (tool.value) {
                .bash => {
                    if (result.bash) return error.DuplicateField;
                    result.bash = true;
                },
                .edit => {
                    if (result.edit) return error.DuplicateField;
                    result.edit = true;
                },
            }
        }
        _ = try source.next();
        return result;
    }

    pub fn jsonStringify(self: ReportTools, jw: anytype) !void {
        try jw.beginArray();
        if (self.bash) try jw.write("bash");
        if (self.edit) try jw.write("edit");
        try jw.endArray();
    }
};

fn CurrentSource(comptime Sink: type) type {
    return struct {
        reader: *std.json.Reader,
        sink: Sink,
        pub const NextError = anyerror;
        pub const PeekError = anyerror;
        pub const AllocError = anyerror;
        pub fn next(self: *@This()) !std.json.Token {
            return self.reader.next();
        }
        pub fn peekNextTokenType(self: *@This()) !std.json.TokenType {
            return self.reader.peekNextTokenType();
        }
        pub fn nextAllocMax(self: *@This(), allocator: std.mem.Allocator, when: std.json.AllocWhen, limit: usize) !std.json.Token {
            return self.reader.nextAllocMax(allocator, when, limit);
        }
        pub fn skipValue(self: *@This()) !void {
            return self.reader.skipValue();
        }
    };
}

fn AttentionRows(comptime tag: std.meta.Tag(Current.Attention)) type {
    return struct {
        count: u64 = 0,
        first: ?u64 = null,
        indeterminate: u64 = 0,
        first_indeterminate: ?u64 = null,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            if (try source.next() != .array_begin) return error.InvalidObservation;
            var result: @This() = .{};
            while (try source.peekNextTokenType() != .array_end) {
                const row = try std.json.innerParse(@FieldType(Current.Attention, @tagName(tag)), allocator, source, options);
                inline for (comptime std.meta.fieldNames(@TypeOf(row))) |name| {
                    if (@FieldType(@TypeOf(row), name) == Current.Reference and @field(row, name).type.value == null) return error.InvalidObservation;
                }
                if ((tag == .resolved or tag == .rejected) and row.code.slice().len == 0) return error.InvalidObservation;
                if (tag == .unresolved) {
                    const p = row.presentation.value;
                    if (p.publication_position != null or p.code != (if (row.authorization.value == .pending) protocol.ToolPresentation.Code.pending_permission else .unresolved)) return error.InvalidObservation;
                }
                if (tag == .resolved or tag == .rejected) {
                    const p = row.presentation.value;
                    if (!std.mem.eql(u8, @tagName(p.code), row.code.slice())) return error.InvalidObservation;
                    if (p.publication_position) |position| if (position < row.acceptance_position.value) return error.InvalidObservation;
                }
                if (tag != .rejected) {
                    if (result.first == null) result.first = row.action.value;
                }
                if (tag == .resolved and row.code.eql("indeterminate")) {
                    result.indeterminate += 1;
                    if (result.first_indeterminate == null) result.first_indeterminate = row.action.value;
                }
                try source.sink.visit(@unionInit(Current.Attention, @tagName(tag), row));
                result.count += 1;
            }
            _ = try source.next();
            return result;
        }
    };
}

pub const SessionListCursor = struct {
    after: u64 = 0,
    ceiling: u64 = 0,

    fn validate(self: SessionListCursor) !void {
        if (self.after > std.math.maxInt(i64) or self.ceiling > std.math.maxInt(i64) or
            (self.after == 0 and self.ceiling != 0) or (self.after != 0 and self.after > self.ceiling)) return error.InvalidCursor;
    }
};

pub const SessionListReply = union(enum) {
    page: SessionListPage,
    failure: ReadFailure,

    /// Borrowed scratch/reply bytes are consumed here; returned facts own their
    /// strings. The report body must start at file offset zero; bytes beyond its
    /// advertised length are not part of this exchange. The file is not changed.
    pub fn decode(io: std.Io, file: std.Io.File, workspace: ?[]const u8, cursor: SessionListCursor, reply: ReportReply) !SessionListReply {
        return switch (reply) {
            .report => |report| .{ .page = try SessionListPage.read(io, file, report.bytes, workspace, cursor) },
            .command => |command| .{ .failure = try decodeReadFailure(command, false) },
        };
    }
};

/// Owned configured-Session summaries; string slices borrow this value, not
/// report scratch. Store remains the authority for ordering and configuration.
pub const SessionListPage = struct {
    pub const Row = struct {
        reference: protocol.Bounded(protocol.max_session_bytes),
        workspace: protocol.Bounded(protocol.max_workspace_bytes),
        provider: protocol.Provider,
        model: protocol.Bounded(protocol.max_model_bytes),
        tools: struct { bash: bool = false, edit: bool = false },
        permission_mode: enum { ask, bypass },

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Row {
            const Tools = struct {
                bash: bool = false,
                edit: bool = false,

                pub fn jsonParse(a: std.mem.Allocator, s: anytype, opts: std.json.ParseOptions) !@This() {
                    if (try s.next() != .array_begin) return error.UnexpectedToken;
                    var result: @This() = .{};
                    while (try s.peekNextTokenType() != .array_end) {
                        const tool = try std.json.innerParse(JsonEnum(enum { bash, edit }), a, s, opts);
                        switch (tool.value) {
                            .bash => {
                                if (result.bash) return error.DuplicateField;
                                result.bash = true;
                            },
                            .edit => {
                                if (result.edit) return error.DuplicateField;
                                result.edit = true;
                            },
                        }
                    }
                    _ = try s.next();
                    return result;
                }
            };
            const Wire = struct {
                reference: JsonString(protocol.max_session_bytes),
                workspace: JsonString(protocol.max_workspace_bytes),
                provider: JsonEnum(protocol.Provider),
                model: JsonString(protocol.max_model_bytes),
                tools: Tools,
                permission_mode: JsonEnum(@FieldType(Row, "permission_mode")),
            };
            const wire = try std.json.innerParse(Wire, allocator, source, options);
            if (wire.reference.value.len == 0 or wire.workspace.value.len == 0 or wire.model.value.len == 0) return error.InvalidCharacter;
            return .{
                .reference = wire.reference.value,
                .workspace = wire.workspace.value,
                .provider = wire.provider.value,
                .model = wire.model.value,
                .tools = .{ .bash = wire.tools.bash, .edit = wire.tools.edit },
                .permission_mode = wire.permission_mode.value,
            };
        }
    };

    rows: [protocol.session_list_page_size]Row = undefined,
    count: usize = 0,
    next: ?SessionListCursor = null,

    /// Reads exactly [0, bytes) from caller-owned scratch, not its physical EOF.
    /// No file/resource escapes; malformed input never yields a partial page.
    pub fn read(io: std.Io, file: std.Io.File, bytes: u64, workspace: ?[]const u8, cursor: SessionListCursor) !SessionListPage {
        if (bytes == 0) return error.InvalidSessionPage;
        cursor.validate() catch return error.InvalidSessionPage;
        const Rows = struct {
            rows: [protocol.session_list_page_size]Row = undefined,
            count: usize = 0,

            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                if (try source.next() != .array_begin) return error.UnexpectedToken;
                var result: @This() = .{};
                while (try source.peekNextTokenType() != .array_end) {
                    if (result.count == result.rows.len) return error.LengthMismatch;
                    result.rows[result.count] = try std.json.innerParse(Row, allocator, source, options);
                    result.count += 1;
                }
                _ = try source.next();
                return result;
            }
        };
        const Wire = struct {
            version: JsonString(8),
            type: JsonString(32),
            sessions: Rows,
            next: ?struct { after: JsonString(20), ceiling: JsonString(20) },
        };
        var input_buffer: [protocol.content_window_bytes]u8 = undefined;
        var file_reader = file.reader(io, &.{});
        var body = file_reader.interface.limited(.limited64(bytes), &input_buffer);
        // One decoded maximum Workspace token, field names and scanner stack;
        // rows are fixed values, not allocator-backed collections or a DOM.
        var storage: [2 * protocol.max_workspace_bytes + protocol.content_window_bytes]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var reader = std.json.Reader.init(fixed.allocator(), &body.interface);
        defer reader.deinit();
        const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &reader, .{ .ignore_unknown_fields = true }) catch return error.InvalidSessionPage;
        // Underlying physical EOF can precede the limit even after valid JSON.
        if (body.remaining != .nothing) return error.InvalidSessionPage;
        if (!wire.version.eql("1") or !wire.type.eql("session_list")) return error.InvalidSessionPage;
        var result: SessionListPage = .{ .rows = wire.sessions.rows, .count = wire.sessions.count };
        if (cursor.after != 0 and cursor.after == cursor.ceiling and result.count != 0) return error.InvalidSessionPage;
        for (result.rows[0..result.count], 0..) |*row, index| {
            if (workspace) |scope| if (!row.workspace.eql(scope)) return error.InvalidSessionPage;
            for (result.rows[0..index]) |*previous| if (previous.reference.eql(row.reference.slice())) return error.InvalidSessionPage;
        }
        if (wire.next) |next| {
            const after = mutationId(next.after, false) catch return error.InvalidSessionPage;
            const ceiling = mutationId(next.ceiling, false) catch return error.InvalidSessionPage;
            if (result.count != protocol.session_list_page_size or after <= cursor.after or after >= ceiling or
                ceiling > std.math.maxInt(i64) or (cursor.after != 0 and ceiling != cursor.ceiling)) return error.InvalidSessionPage;
            result.next = .{ .after = after, .ceiling = ceiling };
        }
        return result;
    }

    pub fn writeJson(self: *const SessionListPage, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[");
        try self.writeRowsJson(writer);
        if (self.next) |next| try writer.print("],\"next\":{{\"after\":\"{d}\",\"ceiling\":\"{d}\"}}}}", .{ next.after, next.ceiling }) else try writer.writeAll("],\"next\":null}");
    }

    /// Rows borrow this validated page. A caller may stream many bounded pages
    /// into one list without retaining the Session population or raw wire text.
    pub fn writeRowsJson(self: *const SessionListPage, writer: *std.Io.Writer) !void {
        for (self.rows[0..self.count], 0..) |*row, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.writeAll("{\"reference\":");
            try std.json.Stringify.value(row.reference.slice(), .{}, writer);
            try writer.writeAll(",\"workspace\":");
            try std.json.Stringify.value(row.workspace.slice(), .{}, writer);
            try writer.print(",\"provider\":\"{s}\",\"model\":", .{@tagName(row.provider)});
            try std.json.Stringify.value(row.model.slice(), .{}, writer);
            try writer.writeAll(",\"tools\":[");
            if (row.tools.bash) try writer.writeAll("\"bash\"");
            if (row.tools.edit) try writer.writeAll(if (row.tools.bash) ",\"edit\"" else "\"edit\"");
            try writer.print("],\"permission_mode\":\"{s}\"}}", .{@tagName(row.permission_mode)});
        }
    }
};

fn renderSessionListRequest(body: *protocol.RequestBuffer, store: []const u8, workspace: ?[]const u8, cursor: SessionListCursor) !void {
    try body.append("{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":");
    try body.appendJsonString(store);
    try body.append(",\"workspace\":");
    if (workspace) |value| try body.appendJsonString(value) else try body.append("null");
    try body.appendFmt(",\"after\":\"{d}\",\"ceiling\":\"{d}\"}}", .{ cursor.after, cursor.ceiling });
}

fn renderReadRequest(
    body: *protocol.RequestBuffer,
    kind: []const u8,
    store: []const u8,
    target_name: []const u8,
    target: []const u8,
    action_id: ?u64,
    report_profile: ?protocol.ReportProfile,
) !void {
    try body.append("{\"version\":\"1\",\"kind\":");
    try body.appendJsonString(kind);
    try body.append(",\"store\":");
    try body.appendJsonString(store);
    try body.append(",");
    try body.appendJsonString(target_name);
    try body.append(":");
    try body.appendJsonString(target);
    if (action_id) |id| try body.appendFmt(",\"action\":\"{d}\"", .{id});
    if (report_profile) |profile| {
        if (profile == .full) try body.append(",\"profile\":\"full\"");
    }
    try body.append("}");
}

pub fn captureSessionStop(io: std.Io, input: SessionStopInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try validateIdentityInputs(location.key, input.session);
    return writeSessionStopCapture(io, &paths, input, location);
}

pub fn captureModelInterruption(io: std.Io, input: ModelInterruptionInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try validateIdentityInputs(location.key, input.session);
    if (input.turn_id == 0 or input.operation_id == 0) return error.InvalidTarget;
    return writeModelInterruptionCapture(io, &paths, input, location);
}

pub fn retry(
    io: std.Io,
    store_path: []const u8,
    record: []const u8,
    kind: []const u8,
    reply_buffer: *ReplyBuffer,
) !MutationReply {
    reply_buffer.len = 0;
    const paths = try platform.resolveClientPaths(io, store_path);
    const selected = MutationKind.parseRetryName(kind) orelse return error.InvalidRetryKind;
    var file = try std.Io.Dir.cwd().openFile(io, record, .{});
    defer file.close(io);
    const binding = try readCapturedBinding(io, &file);
    if (!binding.saved.store.eql(paths.store.slice()) or binding.target != selected) return error.RequestBindingMismatch;
    const reply = try sendSource(.{ .io = io }, &paths, selected.route(), ResponseTiming.mutation, try file.length(io), &file, null, null, null, reply_buffer, null);
    var result = decodeMutationReply(reply, binding.saved.session.slice(), binding.target);
    result.context = binding.saved;
    return result;
}

pub fn observeCommand(
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    reply_buffer: *ReplyBuffer,
) !ObservationReply {
    return (Requests{ .io = io }).observeCommand(store_path, key, reply_buffer);
}

/// An owned selected address, independent of any local request capture.
pub const MessageAddress = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},

    pub fn init(store: []const u8, session: []const u8, key: []const u8) !MessageAddress {
        try validateIdentityInputs(key, session);
        var address: MessageAddress = .{};
        try address.store.set(store);
        try address.session.set(session);
        try address.key.set(key);
        return address;
    }
};

/// Owned scalar facts survive reply-buffer reuse. No DOM, payload or allocator
/// lifetime is retained. Admission status is distinct from the Message result.
pub const CommandObservation = struct {
    key: protocol.Bounded(protocol.max_key_bytes),
    status: enum { absent, accepted, rejected },
    kind: ?MutationKind = null,
    target: ?protocol.Bounded(protocol.max_session_bytes) = null,
    code: ?protocol.Bounded(96) = null,
    revision: ?u64 = null,
    created: ?bool = null,
    input: ?ContentReference = null,
    queue: ?struct { status: enum { queued, processing, excluded, completed, failed, cancelled }, admission: u64 } = null,
    processing: ?struct { turn: u64, operation: u64, attempt: u64 } = null,
    result: ?struct { status: enum { completed, failed, cancelled }, code: ?protocol.Bounded(96), text: ?ContentReference } = null,
    progress: ?Progress = null,
    selection: ?struct { turn: ?u64, admission_cutoff: u64 } = null,
    completion: ?enum { pending, completed } = null,
    interruption_target: ?struct { session: protocol.Bounded(protocol.max_session_bytes), turn: u64, operation: u64 } = null,
    permission_target: ?struct { action: u64, decision: protocol.PermissionDecision } = null,

    pub const ContentReference = struct { bytes: u64, digest: [32]u8 };

    pub const State = enum {
        queued,
        processing,
        rejected,
        completed,
        failed,
        cancelled,

        pub fn terminal(self: State) bool {
            return switch (self) {
                .rejected, .completed, .failed, .cancelled => true,
                else => false,
            };
        }
    };

    pub const Progress = struct {
        status: enum { runnable, in_flight, waiting_for_permission },
        action: ?u64,
    };

    pub fn state(self: *const CommandObservation) State {
        std.debug.assert(self.kind == .message and self.status != .absent);
        if (self.status == .rejected) return .rejected;
        // A terminal result wins over coarser queue/progress hints. Admission
        // remains accepted; a later failure is not a submission rejection.
        if (self.result) |result| return switch (result.status) {
            .completed => .completed,
            .failed => .failed,
            .cancelled => .cancelled,
        };
        return if (self.queue.?.status == .queued) .queued else .processing;
    }

    /// Borrowed from this owned value, not from the receive buffer.
    pub fn failureCode(self: *const CommandObservation) ?[]const u8 {
        if (self.code) |*code| return code.slice();
        if (self.result) |*result| if (result.code) |*code| return code.slice();
        return null;
    }

    pub fn forMessage(self: CommandObservation, address: *const MessageAddress) !CommandObservation {
        if (!self.key.eql(address.key.slice())) return error.RequestBindingMismatch;
        if (self.status == .absent) return error.RequestNotAdmitted;
        if (self.kind != .message or !self.target.?.eql(address.session.slice())) return error.RequestBindingMismatch;
        return self;
    }

    /// Semantic output of supported facts only, with decimal identity strings.
    pub fn writeJson(self: *const CommandObservation, writer: *std.Io.Writer) !void {
        try writer.print("{{\"status\":\"{s}\"", .{@tagName(self.status)});
        if (self.kind) |kind| try writer.print(",\"kind\":\"{s}\",\"target\":", .{@tagName(kind)});
        if (self.target) |*target| try std.json.Stringify.value(target.slice(), .{}, writer);
        if (self.code) |*code| {
            try writer.writeAll(",\"code\":");
            try std.json.Stringify.value(code.slice(), .{}, writer);
        }
        if (self.revision) |revision| try writer.print(",\"revision\":\"{d}\",\"created\":{}", .{ revision, self.created.? });
        if (self.input) |input| {
            try writer.writeAll(",\"input\":");
            try writeContentReference(writer, input);
        }
        if (self.queue) |queue| try writer.print(",\"queue\":{{\"status\":\"{s}\",\"admission\":\"{d}\"}}", .{ @tagName(queue.status), queue.admission });
        if (self.processing) |binding| try writer.print(",\"processing\":{{\"turn\":\"{d}\",\"operation\":\"{d}\",\"attempt\":\"{d}\"}}", .{ binding.turn, binding.operation, binding.attempt });
        if (self.result) |result| {
            try writer.print(",\"result\":{{\"status\":\"{s}\"", .{@tagName(result.status)});
            if (result.code) |*code| {
                try writer.writeAll(",\"code\":");
                try std.json.Stringify.value(code.slice(), .{}, writer);
            }
            if (result.text) |text| {
                try writer.writeAll(",\"text\":");
                try writeContentReference(writer, text);
            }
            try writer.writeByte('}');
        }
        if (self.progress) |progress| {
            try writer.print(",\"progress\":{{\"status\":\"{s}\",\"action\":", .{@tagName(progress.status)});
            if (progress.action) |action| try writer.print("\"{d}\"", .{action}) else try writer.writeAll("null");
            try writer.writeByte('}');
        }
        if (self.selection) |selection| {
            try writer.writeAll(",\"selection\":{\"turn\":");
            if (selection.turn) |turn| try writer.print("\"{d}\"", .{turn}) else try writer.writeAll("null");
            try writer.print(",\"admission_cutoff\":\"{d}\"}},\"completion\":{{\"status\":\"{s}\"}}", .{ selection.admission_cutoff, @tagName(self.completion.?) });
        }
        if (self.interruption_target) |*target| {
            try writer.writeAll(",\"interruption_target\":{\"session\":");
            try std.json.Stringify.value(target.session.slice(), .{}, writer);
            try writer.print(",\"turn\":\"{d}\",\"operation\":\"{d}\"}}", .{ target.turn, target.operation });
        }
        if (self.permission_target) |target| try writer.print(",\"permission_target\":{{\"action\":\"{d}\",\"decision\":\"{s}\"}}", .{ target.action, @tagName(target.decision) });
        try writer.writeByte('}');
    }

    fn writeContentReference(writer: *std.Io.Writer, reference: ContentReference) !void {
        try writer.print("{{\"type\":\"text\",\"bytes\":\"{d}\",\"sha256\":\"{s}\"}}", .{ reference.bytes, std.fmt.bytesToHex(reference.digest, .lower) });
    }

    pub fn parse(reply: CommandReply, key: []const u8) !CommandObservation {
        try checkCanonicalFailure(reply);
        if (reply.status != 200) return error.ObservationFailed;
        if (reply.body.len > protocol.max_response_bytes) return error.ResponseTooLarge;
        const Ref = struct { type: JsonEnum(enum { text }), bytes: JsonString(20), sha256: JsonString(64) };
        const Facts = struct {
            status: JsonEnum(@FieldType(CommandObservation, "status")),
            kind: OmittableJson(JsonEnum(MutationKind)) = .{},
            target: OmittableJson(JsonString(protocol.max_session_bytes)) = .{},
            code: OmittableJson(JsonString(96)) = .{},
            revision: OmittableJson(JsonString(20)) = .{},
            created: OmittableJson(bool) = .{},
            input: OmittableJson(Ref) = .{},
            queue: OmittableJson(struct { status: JsonEnum(@FieldType(@typeInfo(@FieldType(CommandObservation, "queue")).optional.child, "status")), admission: JsonString(20) }) = .{},
            processing: OmittableJson(struct { turn: JsonString(20), operation: JsonString(20), attempt: JsonString(20) }) = .{},
            result: OmittableJson(struct { status: JsonEnum(@FieldType(@typeInfo(@FieldType(CommandObservation, "result")).optional.child, "status")), code: OmittableJson(JsonString(96)) = .{}, text: OmittableJson(Ref) = .{} }) = .{},
            progress: OmittableJson(struct { status: JsonEnum(@FieldType(Progress, "status")), action: ?JsonString(20) }) = .{},
            selection: OmittableJson(struct { turn: ?JsonString(20), admission_cutoff: JsonString(20) }) = .{},
            completion: OmittableJson(struct { status: JsonEnum(@typeInfo(@FieldType(CommandObservation, "completion")).optional.child) }) = .{},
            interruption_target: OmittableJson(struct { session: JsonString(protocol.max_session_bytes), turn: JsonString(20), operation: JsonString(20) }) = .{},
            permission_target: OmittableJson(struct { action: JsonString(20), decision: JsonEnum(protocol.PermissionDecision) }) = .{},
        };
        const Wire = struct { version: JsonString(8), type: JsonString(32), key: JsonString(protocol.max_key_bytes), observation: Facts, code: OmittableJson(JsonString(96)) = .{}, answer: OmittableJson(struct {}) = .{} };
        const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
        var storage: [capacity]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), reply.body);
        defer scanner.deinit();
        scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
        const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &scanner, .{ .ignore_unknown_fields = true }) catch return error.InvalidObservation;
        if (!wire.version.eql(protocol.wire_version) or !wire.type.eql("command_observation") or wire.code.value != null or wire.answer.value != null) return error.InvalidObservation;
        if (!wire.key.eql(key)) return error.RequestBindingMismatch;
        const facts = wire.observation;
        var observed: CommandObservation = .{ .key = wire.key.value, .status = facts.status.value, .kind = if (facts.kind.value) |kind| kind.value else null, .created = facts.created.value };
        inline for (.{ "target", "code" }) |name| if (@field(facts, name).value) |value| {
            @field(observed, name) = value.value;
        };
        if (facts.revision.value) |value| observed.revision = try mutationId(value, false);
        if (facts.input.value) |value| observed.input = try decodeReference(value);
        if (facts.queue.value) |value| observed.queue = .{ .status = value.status.value, .admission = try mutationId(value.admission, false) };
        if (facts.processing.value) |value| observed.processing = .{ .turn = try mutationId(value.turn, false), .operation = try mutationId(value.operation, false), .attempt = try mutationId(value.attempt, true) };
        if (facts.result.value) |value| observed.result = .{ .status = value.status.value, .code = if (value.code.value) |code| code.value else null, .text = if (value.text.value) |text| try decodeReference(text) else null };
        if (facts.progress.value) |value| observed.progress = .{ .status = value.status.value, .action = if (value.action) |action| try mutationId(action, false) else null };
        if (facts.selection.value) |value| observed.selection = .{ .turn = if (value.turn) |turn| try mutationId(turn, false) else null, .admission_cutoff = try mutationId(value.admission_cutoff, true) };
        if (facts.completion.value) |value| observed.completion = value.status.value;
        if (facts.interruption_target.value) |value| observed.interruption_target = .{ .session = value.session.value, .turn = try mutationId(value.turn, true), .operation = try mutationId(value.operation, true) };
        if (facts.permission_target.value) |value| observed.permission_target = .{ .action = try mutationId(value.action, true), .decision = value.decision.value };
        try observed.validate();
        return observed;
    }

    fn decodeReference(value: anytype) !ContentReference {
        var result: ContentReference = .{ .bytes = try mutationId(value.bytes, true), .digest = undefined };
        if (value.sha256.slice().len != 64) return error.InvalidObservation;
        _ = std.fmt.hexToBytes(&result.digest, value.sha256.slice()) catch return error.InvalidObservation;
        return result;
    }

    fn validate(self: *const CommandObservation) !void {
        if (self.status == .absent) {
            inline for (.{ "kind", "target", "code", "revision", "created", "input", "queue", "processing", "result", "progress", "selection", "completion", "interruption_target", "permission_target" }) |name| if (@field(self, name) != null) return error.InvalidObservation;
            return;
        }
        const kind = self.kind orelse return error.InvalidObservation;
        if (self.target == null or self.target.?.len == 0) return error.InvalidObservation;
        if ((self.status == .rejected) != (self.code != null)) return error.InvalidObservation;
        if (self.code) |code| if (code.len == 0) return error.InvalidObservation;
        const accepted = self.status == .accepted;
        if ((self.revision != null) != (accepted and kind == .configure) or (self.created != null) != (accepted and kind == .configure)) return error.InvalidObservation;
        if ((self.selection != null) != (accepted and kind == .session_stop) or (self.completion != null) != (accepted and kind == .session_stop)) return error.InvalidObservation;
        if ((self.interruption_target != null) != (kind == .model_interruption) or (self.permission_target != null) != (kind == .permission_decision)) return error.InvalidObservation;
        if (self.interruption_target) |target| if (!target.session.eql(self.target.?.slice())) return error.RequestBindingMismatch;
        if (kind != .message or !accepted) {
            if (self.queue != null or self.processing != null or self.result != null or self.progress != null or (kind != .message and self.input != null)) return error.InvalidObservation;
            return;
        }
        if (self.input == null or self.queue == null) return error.InvalidObservation;
        const queue = self.queue.?;
        if (queue.status != .queued and queue.status != .excluded and self.processing == null) return error.InvalidObservation;
        if ((queue.status == .excluded or queue.status == .completed or queue.status == .failed or queue.status == .cancelled) and self.result == null) return error.InvalidObservation;
        if (queue.status == .excluded and self.processing != null) return error.InvalidObservation;
        if (self.result) |result| {
            if (queue.status == .excluded) {
                if (result.status != .cancelled) return error.InvalidObservation;
            } else if (self.processing == null) return error.InvalidObservation;
            if ((queue.status == .completed and result.status != .completed) or
                (queue.status == .failed and result.status != .failed) or
                (queue.status == .cancelled and result.status != .cancelled)) return error.InvalidObservation;
            if (result.status == .completed) {
                if (result.text == null or result.code != null or self.processing == null) return error.InvalidObservation;
            } else if (result.text != null or result.code == null or result.code.?.len == 0) return error.InvalidObservation;
        }
        if (self.progress) |progress| if (progress.status == .waiting_for_permission and progress.action == null) return error.InvalidObservation;
    }
};

pub fn observeMessage(io: std.Io, address: *const MessageAddress) !ObservationReply {
    return (Requests{ .io = io }).observeMessage(address);
}

pub fn readResult(
    io: std.Io,
    store_path: []const u8,
    key: []const u8,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReadReply {
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
) !ResultReadReply {
    return (Requests{ .io = io }).readResultStream(store_path, key, sink, reply_buffer);
}

fn readResultWithSink(
    requests: Requests,
    store_path: []const u8,
    key: []const u8,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !ResultReadReply {
    const io = requests.io;
    reply_buffer.len = 0;
    try requests.check();
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, "read_result", paths.store.slice(), "key", key, null, null);
    const fd = try openRead(requests, &paths, "/v1/read-result", body.slice());
    defer closeSocket(io, fd);
    return switch (try readResultResponseSink(requests, fd, sink, reply_buffer)) {
        .answer => |answer| .{ .answer = .{ .bytes = answer.bytes } },
        .command => |reply| .{ .failure = try decodeReadFailure(reply, true) },
    };
}

pub fn inspectSession(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    profile: protocol.ReportProfile,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ReportReply {
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
    cursor: SessionListCursor,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ReportReply {
    return (Requests{ .io = io }).listSessions(store_path, workspace, cursor, destination, reply_buffer);
}

pub fn readActionArguments(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return (Requests{ .io = io }).readActionArguments(store_path, session, action_id, destination, reply_buffer);
}

pub fn readActionCallId(
    io: std.Io,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    return (Requests{ .io = io }).readActionCallId(store_path, session, action_id, destination, reply_buffer);
}

fn readActionContent(
    requests: Requests,
    store_path: []const u8,
    session: []const u8,
    action_id: u64,
    comptime kind: []const u8,
    comptime route: []const u8,
    destination: std.Io.File,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
    const io = requests.io;
    reply_buffer.len = 0;
    try requests.check();
    if (session.len == 0 or session.len > protocol.max_session_bytes or action_id == 0) return error.InvalidTarget;
    const paths = try platform.resolveClientPaths(io, store_path);
    var body: protocol.RequestBuffer = .{};
    try renderReadRequest(&body, kind, paths.store.slice(), "session", session, action_id, null);
    const fd = try openRead(requests, &paths, route, body.slice());
    defer closeSocket(io, fd);
    return readResultResponseSink(requests, fd, destination, reply_buffer);
}

fn validateIdentityInputs(key: []const u8, session: []const u8) !void {
    if (key.len > protocol.max_key_bytes or !std.unicode.utf8ValidateSlice(key)) return error.InvalidKey;
    if (session.len == 0 or session.len > protocol.max_session_bytes or
        !std.unicode.utf8ValidateSlice(session)) return error.InvalidSession;
}

/// The five durable mutations. Tag names are the captured-record and
/// observation spelling; `rui request recover --kind` uses the hyphenated spelling.
pub const MutationKind = enum {
    configure,
    message,
    session_stop,
    model_interruption,
    permission_decision,

    fn route(self: MutationKind) []const u8 {
        return switch (self) {
            .configure => "/v1/configure",
            .message => "/v1/message",
            .session_stop => "/v1/control/session-stop",
            .model_interruption => "/v1/control/model-interruption",
            .permission_decision => "/v1/control/permission-decision",
        };
    }

    fn parseRetryName(name: []const u8) ?MutationKind {
        inline for (comptime std.enums.values(MutationKind)) |kind| {
            if (std.mem.eql(u8, name, comptime retryName(kind))) return kind;
        }
        return null;
    }

    fn retryName(comptime kind: MutationKind) []const u8 {
        comptime {
            var name = @tagName(kind)[0..@tagName(kind).len].*;
            std.mem.replaceScalar(u8, &name, '_', '-');
            const final = name;
            return &final;
        }
    }
};

pub const MutationTarget = union(MutationKind) {
    configure,
    message: struct { bytes: u64, digest: [32]u8 },
    session_stop,
    model_interruption: struct { turn: u64, operation: u64 },
    permission_decision: struct { action: u64, decision: protocol.PermissionDecision },

    fn route(self: MutationTarget) []const u8 {
        return std.meta.activeTag(self).route();
    }
};

pub const MutationAnswer = struct {
    result: union(enum) {
        accepted: union(enum) {
            configure: struct { revision: u64, created: bool },
            message: struct { admission: u64 },
            session_stop: struct { turn: ?u64, admission_cutoff: u64, completion: enum { pending, completed } },
            model_interruption,
            permission_decision,
        },
        rejected: protocol.Bounded(96),
        conflict,
    },
    replayed: bool,
    /// The Host's catalog verdict for an explicit configuration model,
    /// observed at reply time. Absent from Hosts that predate the catalog.
    model_catalog: ?codex_model_catalog.Observation = null,
};

/// An unsaved configuration rejection: the model is absent from the Host's
/// fresh catalog for this account. The key has no saved answer.
pub const CatalogRejection = struct {
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
    age_seconds: u64 = 0,
    available: [protocol.max_catalog_rejection_slugs]protocol.Bounded(protocol.max_model_bytes) = undefined,
    available_len: usize = 0,
    /// Total available models; `available` holds at most the first 16.
    available_count: u64 = 0,

    pub fn availableModels(self: *const CatalogRejection) []const protocol.Bounded(protocol.max_model_bytes) {
        return self.available[0..self.available_len];
    }
};

pub const InvocationDiagnostic = struct {
    type: protocol.Bounded(32),
    code: protocol.Bounded(96),
};

/// Owned facts and original request context survive buffer reuse and capture
/// closure. An answer error is unconfirmed, never rejection or noncommit.
pub const MutationReply = struct {
    status: u16,
    diagnostic: ?InvocationDiagnostic = null,
    catalog_rejection: ?CatalogRejection = null,
    context: CapturedIdentity = .{},
    target: MutationTarget,
    answer: error{ CanonicalStoreFailure, HostInvocationFailed, InvalidResponse, RequestBindingMismatch, ModelUnavailable }!MutationAnswer,

    pub fn isAccepted(self: MutationReply) bool {
        const answer = self.answer catch return false;
        return answer.result == .accepted;
    }
};

fn JsonString(comptime limit: usize) type {
    return struct {
        value: protocol.Bounded(limit) = .{},

        pub fn slice(self: *const @This()) []const u8 {
            return self.value.slice();
        }

        fn eql(self: *const @This(), value: []const u8) bool {
            return self.value.eql(value);
        }

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value.slice());
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, _: std.json.ParseOptions) !@This() {
            if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
            const token = try source.nextAllocMax(allocator, .alloc_if_needed, limit);
            defer if (token == .allocated_string) allocator.free(token.allocated_string);
            var result: @This() = .{};
            result.value.set(switch (token) {
                .string, .allocated_string => |value| value,
                else => unreachable,
            }) catch return error.InvalidCharacter;
            return result;
        }
    };
}

// The stdlib also accepts numeric enum tags. Host facts require named strings;
// their closed vocabulary derives the token bound, with JsonString's lifetime.
pub const JsonToolPresentation = struct {
    value: protocol.ToolPresentation,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        const Wire = struct { description: ?JsonString(protocol.max_tool_description_bytes), code: JsonEnum(protocol.ToolPresentation.Code), publication_position: ?JsonString(20) };
        const wire = try std.json.innerParse(Wire, allocator, source, options);
        const position = if (wire.publication_position) |p| mutationId(p, false) catch return error.InvalidCharacter else null;
        if (position) |p| if (p > std.math.maxInt(i64)) return error.InvalidCharacter;
        if (wire.description) |d| if (!@import("tools.zig").validDescription(d.slice())) return error.InvalidCharacter;
        if (wire.description == null) switch (wire.code.value) {
            .unknown_tool, .invalid_arguments, .tool_unavailable => {},
            else => return error.InvalidCharacter,
        };
        if (position != null and (wire.code.value == .unresolved or wire.code.value == .pending_permission)) return error.InvalidCharacter;
        return .{ .value = .{ .description = if (wire.description) |d| d.value else null, .code = wire.code.value, .publication_position = position } };
    }

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("description");
        if (self.value.description) |d| try jw.write(d.slice()) else try jw.write(null);
        try jw.objectField("code");
        try jw.write(@tagName(self.value.code));
        try jw.objectField("publication_position");
        if (self.value.publication_position) |p| {
            var buffer: [20]u8 = undefined;
            try jw.write(std.fmt.bufPrint(&buffer, "{d}", .{p}) catch unreachable);
        } else try jw.write(null);
        try jw.endObject();
    }
};

test "canonical presentation typed ingress owns escaped labels and closed facts" {
    const bytes = "{\"description\":\"Read \\u20ac files\",\"code\":\"denied\",\"publication_position\":null}";
    const parsed = try std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Read € files", parsed.value.value.description.?.slice());
    try std.testing.expectEqual(protocol.ToolPresentation.Code.denied, parsed.value.value.code);
    try std.testing.expect(parsed.value.value.publication_position == null);
    for ([_][]const u8{
        "{\"description\":null,\"code\":0,\"publication_position\":null}",
        "{\"description\":null,\"code\":\"invented\",\"publication_position\":null}",
        "{\"description\":null,\"code\":\"succeeded\",\"publication_position\":\"1\"}",
        "{\"description\":\"Read\\nfiles\",\"code\":\"succeeded\",\"publication_position\":\"1\"}",
        "{\"description\":\" \",\"code\":\"succeeded\",\"publication_position\":\"1\"}",
        "{\"description\":null,\"code\":\"succeeded\",\"publication_position\":1}",
        "{\"description\":null,\"code\":\"succeeded\",\"publication_position\":\"0\"}",
        "{\"description\":null,\"code\":\"succeeded\",\"publication_position\":\"9223372036854775808\"}",
        "{\"description\":null,\"code\":\"pending_permission\",\"publication_position\":\"1\"}",
        "{\"code\":\"succeeded\",\"publication_position\":null}",
        "{\"description\":null,\"code\":\"succeeded\",\"code\":\"failed\",\"publication_position\":null}",
        "{\"description\":\"" ++ @as([101]u8, @splat('x')) ++ "\",\"code\":\"succeeded\",\"publication_position\":null}",
    }) |invalid| {
        if (std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, invalid, .{})) |unexpected| {
            unexpected.deinit();
            return error.AcceptedInvalidPresentation;
        } else |_| {}
    }
    // Worst JSON escaping is six bytes per decoded byte, not the token bound.
    const escaped = "{\"description\":\"" ++ @as([100 * 6]u8, @bitCast(@as([100][6]u8, @splat("\\u0001".*)))) ++ "\",\"code\":\"succeeded\",\"publication_position\":\"9223372036854775807\"}";
    const maximum = try std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, escaped, .{});
    defer maximum.deinit();
    try std.testing.expectEqual(@as(usize, 100), maximum.value.value.description.?.slice().len);
    var buffer: [protocol.max_tool_presentation_json_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try maximum.value.value.writeJson(&writer);
    const roundtrip = try std.json.parseFromSlice(JsonToolPresentation, std.testing.allocator, writer.buffered(), .{});
    defer roundtrip.deinit();
    try std.testing.expectEqualDeep(maximum.value.value, roundtrip.value.value);
    var facts: protocol.ActivityFacts = .{ .end = 16, .count = 16 };
    for (&facts.items, 0..) |*item, index| item.* = .{
        .position = index + 1,
        .ordinal = 1,
        .value = .{ .tool_result = .{ .content = .{ .length = 0, .digest = protocol.contentDigest("") }, .presentation = .{ .description = maximum.value.value.description, .code = .succeeded, .publication_position = index + 1 } } },
    };
    facts.call_activity = .{ .total = std.math.maxInt(i64), .count = 3 };
    for (&facts.call_activity.entries, 0..) |*entry, index| entry.* = .{
        .operation = std.math.maxInt(i64) - 2 + index,
        .ordinal = std.math.maxInt(i64) - 1,
        .presentation = .{ .description = maximum.value.value.description, .code = .infrastructure_shutdown, .publication_position = std.math.maxInt(i64) },
    };
    var page_buffer: [protocol.max_activity_page_response_bytes]u8 = undefined;
    var page_writer = std.Io.Writer.fixed(&page_buffer);
    try facts.writeJson(&page_writer);
    const page = try ActivityPage.parse(page_writer.buffered(), .{});
    try std.testing.expectEqual(@as(usize, 16), page.facts.count);
    try std.testing.expectEqualDeep(facts.call_activity, page.facts.call_activity);
    for (page.facts.items) |item| {
        try std.testing.expectEqual(@as(usize, 100), item.value.tool_result.presentation.description.?.slice().len);
        try std.testing.expectEqual(item.position, item.value.tool_result.presentation.publication_position.?);
    }
}

test "canonical presentation releases allocations on acceptance and late rejection" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator, invalid: bool) !void {
            const bytes = "{\"description\":\"Read \\u20ac files\",\"code\":\"su\\u0063ceeded\",\"publication_position\":";
            const result: anyerror!JsonToolPresentation = decode: {
                var scanner = std.json.Scanner.initCompleteInput(allocator, if (invalid)
                    bytes ++ "\"9223372036854775808\"}"
                else
                    bytes ++ "\"9223372036854775807\"}");
                defer scanner.deinit();
                // No outer arena may hide leaked temporary decoded tokens.
                break :decode std.json.parseFromTokenSourceLeaky(JsonToolPresentation, allocator, &scanner, .{});
            };
            const value = (result catch |err| {
                if (err == error.OutOfMemory) return err;
                try std.testing.expect(invalid);
                try std.testing.expectEqual(error.InvalidCharacter, err);
                return;
            }).value;
            // Returned bounded facts must outlive the parser's allocations.
            try std.testing.expect(!invalid);
            try std.testing.expectEqualStrings("Read € files", value.description.?.slice());
            try std.testing.expectEqual(protocol.ToolPresentation.Code.succeeded, value.code);
            try std.testing.expectEqual(@as(?u64, 9223372036854775807), value.publication_position);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{true});
}

fn JsonEnum(comptime T: type) type {
    const limit = comptime blk: {
        var longest: usize = 0;
        for (@typeInfo(T).@"enum".field_names) |name| longest = @max(longest, name.len);
        break :blk longest;
    };
    return struct {
        value: T,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(@tagName(self.value));
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const string = try JsonString(limit).jsonParse(allocator, source, options);
            return .{ .value = std.meta.stringToEnum(T, string.slice()) orelse return error.InvalidEnumTag };
        }
    };
}

// The containing field's default represents omission. A present field must
// parse as T, not ?T: JSON null cannot stand in for an absent outcome/diagnostic.
fn OmittableJson(comptime T: type) type {
    return struct {
        value: ?T = null,

        pub fn isPresent(self: @This()) bool {
            return self.value != null;
        }
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value);
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            return .{ .value = try std.json.innerParse(T, allocator, source, options) };
        }
    };
}

fn mutationId(value: JsonString(20), allow_zero: bool) !u64 {
    const bytes = value.slice();
    if (bytes.len == 0 or (bytes.len > 1 and bytes[0] == '0')) return error.InvalidResponse;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidResponse;
    const id = std.fmt.parseInt(u64, bytes, 10) catch return error.InvalidResponse;
    if (!allow_zero and id == 0) return error.InvalidResponse;
    return id;
}

fn decodeReadFailure(reply: CommandReply, result_read: bool) !ReadFailure {
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const Wire = struct {
        version: JsonString(8),
        type: JsonString(32),
        code: JsonString(96),
        observation: OmittableJson(struct {}) = .{},
        answer: OmittableJson(struct {}) = .{},
    };
    const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
    var storage: [capacity]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), reply.body);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
    const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &scanner, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
    if (wire.observation.value != null or wire.answer.value != null) return error.InvalidResponse;
    const failure: ReadFailure = .{ .status = reply.status, .diagnostic = .{ .type = wire.type.value, .code = wire.code.value } };
    try validateInvocationDiagnostic(reply.status, wire.version.slice(), failure.diagnostic);
    if (wire.type.eql("result_unavailable") and (!result_read or reply.status != 409 or
        (!wire.code.eql("result_not_found") and !wire.code.eql("result_not_ready") and !wire.code.eql("result_failed")))) return error.InvalidResponse;
    return failure;
}

/// One operation boundary for synchronous callers and a later worker. No
/// workflow, terminal, retry or certainty transition is made by this decoder.
pub fn decodeMutationReply(reply: CommandReply, session: []const u8, target: MutationTarget) MutationReply {
    var result: MutationReply = .{ .status = reply.status, .target = target, .answer = error.InvalidResponse };
    result.context.session.set(session) catch return result;
    result.answer = decodeMutationAnswer(reply, session, target, &result.diagnostic, &result.catalog_rejection);
    return result;
}

fn decodeModelCatalog(value: anytype) !codex_model_catalog.Observation {
    const verdict = std.meta.stringToEnum(std.meta.Tag(codex_model_catalog.Verdict), value.verdict.slice()) orelse return error.InvalidResponse;
    const age_ms: ?i64 = if (value.age_seconds) |age| std.math.mul(i64, std.math.cast(i64, try mutationId(age, true)) orelse return error.InvalidResponse, 1000) catch return error.InvalidResponse else null;
    if (verdict == .unchecked) {
        const reason = std.meta.stringToEnum(codex_model_catalog.Reason, (value.reason orelse return error.InvalidResponse).slice()) orelse return error.InvalidResponse;
        return .{ .verdict = .{ .unchecked = reason }, .age_ms = age_ms };
    }
    if (value.reason != null or age_ms == null) return error.InvalidResponse;
    return .{ .verdict = switch (verdict) {
        .listed => .listed,
        .hidden => .hidden,
        .absent => .absent,
        .unchecked => unreachable,
    }, .age_ms = age_ms };
}

fn decodeMutationAnswer(reply: CommandReply, session: []const u8, target: MutationTarget, diagnostic: *?InvocationDiagnostic, catalog_rejection: *?CatalogRejection) @FieldType(MutationReply, "answer") {
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const Wire = struct {
        version: JsonString(8),
        type: JsonString(32),
        code: OmittableJson(JsonString(96)) = .{},
        answer: OmittableJson(struct {
            status: JsonString(16),
            replayed: bool,
            session: OmittableJson(JsonString(protocol.max_session_bytes)) = .{},
            code: OmittableJson(JsonString(96)) = .{},
            revision: OmittableJson(JsonString(20)) = .{},
            created: OmittableJson(bool) = .{},
            admission: OmittableJson(JsonString(20)) = .{},
            action: OmittableJson(JsonString(20)) = .{},
            decision: OmittableJson(JsonString(16)) = .{},
            selection: OmittableJson(struct { turn: ?JsonString(20), admission_cutoff: JsonString(20) }) = .{},
            target: OmittableJson(struct { session: JsonString(protocol.max_session_bytes), turn: JsonString(20), operation: JsonString(20) }) = .{},
        }) = .{},
        input: OmittableJson(struct { type: JsonString(8), bytes: JsonString(20), sha256: JsonString(64) }) = .{},
        queue: OmittableJson(struct { status: JsonString(16), admission: JsonString(20) }) = .{},
        execution: OmittableJson(struct { status: JsonString(16), reason: OmittableJson(JsonString(64)) = .{} }) = .{},
        completion: OmittableJson(struct { status: JsonString(16) }) = .{},
        model_catalog: OmittableJson(struct { verdict: JsonString(16), reason: ?JsonString(32), age_seconds: ?JsonString(20) }) = .{},
        // Only in a model_catalog_rejection envelope.
        model: OmittableJson(JsonString(protocol.max_model_bytes)) = .{},
        age_seconds: OmittableJson(JsonString(20)) = .{},
        available_models: OmittableJson([]const JsonString(protocol.max_model_bytes)) = .{},
        available_count: OmittableJson(JsonString(20)) = .{},
    };
    // Strings are copied into bounded values and immediately freed. Reserve
    // scanner nesting first, as in the canonical classifier; no payload arena.
    const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
    var storage: [capacity]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), reply.body);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
    const wire = std.json.parseFromTokenSourceLeaky(Wire, fixed.allocator(), &scanner, .{ .ignore_unknown_fields = true }) catch return error.InvalidResponse;
    if (wire.code.value) |code| {
        if (wire.answer.value != null or wire.input.value != null or wire.queue.value != null or wire.execution.value != null or wire.completion.value != null) return error.InvalidResponse;
        const parsed = InvocationDiagnostic{ .type = wire.type.value, .code = code.value };
        try validateInvocationDiagnostic(reply.status, wire.version.slice(), parsed);
        diagnostic.* = parsed;
        if (parsed.code.eql("canonical_store_failure")) return error.CanonicalStoreFailure;
        if (target == .configure and reply.status == 422 and parsed.type.eql("model_catalog_rejection") and parsed.code.eql("model_unavailable")) {
            var rejection: CatalogRejection = .{};
            rejection.model.set((wire.model.value orelse return error.InvalidResponse).slice()) catch return error.InvalidResponse;
            if (rejection.model.len == 0) return error.InvalidResponse;
            rejection.age_seconds = try mutationId(wire.age_seconds.value orelse return error.InvalidResponse, true);
            const available = wire.available_models.value orelse return error.InvalidResponse;
            rejection.available_count = try mutationId(wire.available_count.value orelse return error.InvalidResponse, true);
            // The Host lists a prefix bounded by count and reply bytes.
            if (available.len > rejection.available.len or available.len > rejection.available_count) return error.InvalidResponse;
            for (available, 0..) |slug, index| {
                rejection.available[index] = .{};
                rejection.available[index].set(slug.slice()) catch return error.InvalidResponse;
            }
            rejection.available_len = available.len;
            catalog_rejection.* = rejection;
            return error.ModelUnavailable;
        }
        return error.HostInvocationFailed;
    }
    if (reply.status != 200 and reply.status != 409) return error.InvalidResponse;
    const expected_type = switch (target) {
        .configure => "configuration_reply",
        .message => "message_reply",
        .session_stop => "session_stop_reply",
        .model_interruption => "model_interruption_reply",
        .permission_decision => "permission_decision_reply",
    };
    if (!wire.version.eql("1") or !wire.type.eql(expected_type) or wire.code.value != null) return error.InvalidResponse;
    const answer = wire.answer.value orelse return error.InvalidResponse;
    if (target == .model_interruption) {
        const echoed = answer.target.value orelse return error.InvalidResponse;
        if (answer.session.value != null or !echoed.session.eql(session) or try mutationId(echoed.turn, true) != target.model_interruption.turn or
            try mutationId(echoed.operation, true) != target.model_interruption.operation) return error.RequestBindingMismatch;
    } else {
        if (answer.target.value != null or !(answer.session.value orelse return error.InvalidResponse).eql(session)) return error.RequestBindingMismatch;
    }
    if (target == .permission_decision) {
        if (try mutationId(answer.action.value orelse return error.InvalidResponse, true) != target.permission_decision.action or
            !(answer.decision.value orelse return error.InvalidResponse).eql(@tagName(target.permission_decision.decision))) return error.RequestBindingMismatch;
    } else if (answer.action.value != null or answer.decision.value != null) return error.InvalidResponse;
    const accepted = answer.status.eql("accepted");
    const conflict = answer.status.eql("conflict");
    if ((!accepted and !conflict and !answer.status.eql("rejected")) or (reply.status == 409) != conflict) return error.InvalidResponse;
    if (accepted) {
        if (answer.code.value != null) return error.InvalidResponse;
    } else {
        const code = answer.code.value orelse return error.InvalidResponse;
        if (code.slice().len == 0 or answer.revision.value != null or answer.created.value != null or answer.admission.value != null or answer.selection.value != null) return error.InvalidResponse;
        if (conflict and (!code.eql("idempotency_key_conflict") or answer.replayed)) return error.InvalidResponse;
    }
    var value: @FieldType(@FieldType(MutationAnswer, "result"), "accepted") = undefined;
    switch (target) {
        .configure => {
            const execution = wire.execution.value orelse return error.InvalidResponse;
            if (!execution.status.eql("unavailable") or !(execution.reason.value orelse return error.InvalidResponse).eql("direct_reply_does_not_wait_for_model_processing")) return error.InvalidResponse;
            if (accepted) value = .{ .configure = .{ .revision = try mutationId(answer.revision.value orelse return error.InvalidResponse, false), .created = answer.created.value orelse return error.InvalidResponse } };
        },
        .message => |expected| {
            if (!(wire.execution.value orelse return error.InvalidResponse).status.eql("queued")) return error.InvalidResponse;
            if (conflict) {
                if (wire.input.value != null or wire.queue.value != null) return error.InvalidResponse;
            } else {
                const input = wire.input.value orelse return error.InvalidResponse;
                var digest: [32]u8 = undefined;
                if (!input.type.eql("text") or input.sha256.slice().len != 64) return error.InvalidResponse;
                _ = std.fmt.hexToBytes(&digest, input.sha256.slice()) catch return error.InvalidResponse;
                if (try mutationId(input.bytes, true) != expected.bytes or !std.mem.eql(u8, &digest, &expected.digest)) return error.RequestBindingMismatch;
                if (accepted) {
                    const admission = try mutationId(answer.admission.value orelse return error.InvalidResponse, false);
                    const queue = wire.queue.value orelse return error.InvalidResponse;
                    if (!queue.status.eql("queued") or try mutationId(queue.admission, false) != admission) return error.InvalidResponse;
                    value = .{ .message = .{ .admission = admission } };
                } else if (wire.queue.value != null) return error.InvalidResponse;
            }
        },
        .session_stop => {
            const completion = wire.completion.value orelse return error.InvalidResponse;
            if (accepted) {
                const selection = answer.selection.value orelse return error.InvalidResponse;
                value = .{ .session_stop = .{
                    .turn = if (selection.turn) |turn| try mutationId(turn, false) else null,
                    .admission_cutoff = try mutationId(selection.admission_cutoff, true),
                    .completion = std.meta.stringToEnum(@FieldType(@FieldType(@TypeOf(value), "session_stop"), "completion"), completion.status.slice()) orelse return error.InvalidResponse,
                } };
            } else if (!completion.status.eql("unavailable")) return error.InvalidResponse;
        },
        .model_interruption => if (accepted) {
            value = .model_interruption;
        },
        .permission_decision => if (accepted) {
            value = .permission_decision;
        },
    }
    if ((target != .configure and (answer.revision.value != null or answer.created.value != null)) or
        (target != .message and (answer.admission.value != null or wire.input.value != null or wire.queue.value != null)) or
        (target != .session_stop and (answer.selection.value != null or wire.completion.value != null)) or
        ((target != .configure or conflict) and wire.model_catalog.value != null)) return error.InvalidResponse;
    return .{
        .replayed = answer.replayed,
        .result = if (accepted) .{ .accepted = value } else if (conflict) .conflict else .{ .rejected = answer.code.value.?.value },
        .model_catalog = if (wire.model_catalog.value) |observation| try decodeModelCatalog(observation) else null,
    };
}

test "mutation decoder checks binding queue ambiguity and fixed reply bounds" {
    const digest = protocol.contentDigest("a\nµ");
    const target: MutationTarget = .{ .message = .{ .bytes = 4, .digest = digest } };
    const prefix = "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"a/\\u00e9\",\"admission\":\"7\"}";
    var suffix_storage: [256]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_storage, ",\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"7\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{std.fmt.bytesToHex(digest, .lower)});
    var body: [protocol.max_response_bytes + 1]u8 = undefined;
    const valid = try std.fmt.bufPrint(&body, "{s}{s}", .{ prefix, suffix });
    const reply: CommandReply = .{ .status = 200, .body = valid };
    try std.testing.expectEqual(@as(u64, 7), (try decodeMutationReply(reply, "a/é", target).answer).result.accepted.message.admission);
    try std.testing.expectError(error.RequestBindingMismatch, decodeMutationReply(reply, "b/é", target).answer);
    var changed = target;
    changed.message.bytes = 5;
    try std.testing.expectError(error.RequestBindingMismatch, decodeMutationReply(reply, "a/é", changed).answer);
    changed = target;
    changed.message.digest[3] ^= 1;
    try std.testing.expectError(error.RequestBindingMismatch, decodeMutationReply(reply, "a/é", changed).answer);
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 409, .body = valid }, "a/é", target).answer);
    @memset(body[valid.len..protocol.max_response_bytes], ' ');
    _ = try decodeMutationReply(.{ .status = 200, .body = body[0..protocol.max_response_bytes] }, "a/é", target).answer;
    body[protocol.max_response_bytes] = ' ';
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = &body }, "a/é", target).answer);
    for ([_][]const u8{
        "{\"version\":1,\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"a/é\",\"admission\":\"7\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"sta\\u0074us\":\"rejected\",\"replayed\":false,\"session\":\"a/é\",\"admission\":\"7\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"accepted\",\"replayed\":false,\"session\":\"a/é\",\"admission\":\"07\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":false,\"session\":\"a/é\",\"code\":\"unknown_session\"}",
    }) |invalid_prefix| {
        const invalid = try std.fmt.bufPrint(&body, "{s}{s}", .{ invalid_prefix, suffix });
        try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = invalid }, "a/é", target).answer);
    }
    const conflicting_queue = try std.fmt.bufPrint(&body, "{s},\"input\":{{\"type\":\"text\",\"bytes\":\"4\",\"sha256\":\"{s}\"}},\"queue\":{{\"status\":\"queued\",\"admission\":\"8\"}},\"execution\":{{\"status\":\"queued\"}}}}", .{ prefix, std.fmt.bytesToHex(digest, .lower) });
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = conflicting_queue }, "a/é", target).answer);
    const malformed = try std.fmt.bufPrint(&body, "{s}{s} trailing", .{ prefix, suffix });
    try std.testing.expectError(error.InvalidResponse, decodeMutationReply(.{ .status = 200, .body = malformed }, "a/é", target).answer);
}

test "mutation decoder preserves invalid-target domain rejection not false fatal certainty" {
    const body = "{\"version\":\"1\",\"type\":\"model_interruption_reply\",\"answer\":{\"status\":\"rejected\",\"replayed\":true,\"target\":{\"session\":\"s\",\"turn\":\"0\",\"operation\":\"18446744073709551615\"},\"code\":\"invalid_target\"}}";
    const target: MutationTarget = .{ .model_interruption = .{ .turn = 0, .operation = std.math.maxInt(u64) } };
    const answer = try decodeMutationReply(.{ .status = 200, .body = body }, "s", target).answer;
    try std.testing.expectEqualStrings("invalid_target", answer.result.rejected.slice());
    try std.testing.expect(answer.replayed);
    for ([_][]const u8{
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"unavailable\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"infrastructure_failure\",\"code\":\"canonical_store_failure\"}}",
    }) |unknown| {
        const reply = decodeMutationReply(.{ .status = 500, .body = unknown }, "s", target);
        try std.testing.expectError(if (std.mem.indexOf(u8, unknown, "unavailable") != null) error.HostInvocationFailed else error.InvalidResponse, reply.answer);
        try std.testing.expect(!reply.isAccepted());
        if (std.mem.indexOf(u8, unknown, "unavailable") != null)
            try std.testing.expectEqualStrings("unavailable", reply.diagnostic.?.code.slice());
    }
}

test "mutation diagnostics own complete validated metadata without raw reply lifetime" {
    const body = "{\"version\":\"1\",\"type\":\"invocation_error\",\"co\\u0064e\":\"busy\\u002fµ\",\"extra\":[null,{}]}";
    var bytes: [body.len]u8 = body.*;
    const reply = decodeMutationReply(.{ .status = 409, .body = &bytes }, "original/session", .configure);
    @memset(&bytes, 'x');
    try std.testing.expectError(error.HostInvocationFailed, reply.answer);
    try std.testing.expect(reply.diagnostic != null);
    try std.testing.expectEqualStrings("busy/µ", reply.diagnostic.?.code.slice());
    try std.testing.expectEqualStrings("invocation_error", reply.diagnostic.?.type.slice());
    try std.testing.expectEqualStrings("original/session", reply.context.session.slice());
    for ([_][]const u8{
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"capacity_exhausted\"}",
    }, [_]u16{ 500, 503 }) |valid, status| {
        const value = decodeMutationReply(.{ .status = status, .body = valid }, "s", .configure);
        try std.testing.expectError(if (status == 500) error.CanonicalStoreFailure else error.HostInvocationFailed, value.answer);
        try std.testing.expect(value.diagnostic != null);
    }
    const prefix = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"busy\"";
    for ([_][]const u8{
        prefix ++ ",\"co\\u0064e\":\"other\"}",
        prefix ++ ",\"extra\":[}",
        prefix ++ "} trailing",
        prefix ++ ",\"answer\":{\"status\":\"accepted\",\"replayed\":false}}",
        "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":[98]}",
    }) |invalid| {
        const value = decodeMutationReply(.{ .status = 500, .body = invalid }, "s", .configure);
        try std.testing.expectError(error.InvalidResponse, value.answer);
        try std.testing.expect(value.diagnostic == null);
    }
}

pub const CapturedIdentity = struct {
    store: protocol.Bounded(protocol.max_store_bytes) = .{},
    key: protocol.Bounded(protocol.max_key_bytes) = .{},
    session: protocol.Bounded(protocol.max_session_bytes) = .{},
    kind: protocol.Bounded(32) = .{},

    pub fn isKind(self: *const CapturedIdentity, kind: MutationKind) bool {
        return self.kind.eql(@tagName(kind));
    }
};

pub const CaptureTarget = union(enum) {
    generated: []const u8, // Caller-selected private directory, not HOME policy.
    explicit: struct { record: []const u8, key: []const u8 },

    /// Reserve identity before asynchronous capture; returned slices borrow
    /// caller storage through capture return. This does not publish a record.
    pub fn resolve(self: CaptureTarget, io: std.Io, path: []u8, key: *[36]u8) !@FieldType(CaptureTarget, "explicit") {
        return switch (self) {
            .explicit => |value| value,
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
                break :blk .{ .record = try requestPath(directory, id, path), .key = id };
            },
        };
    }
};

// Owns one read-only descriptor, never the saved name's deletion. Identity
// borrows this value and remains available after any send failure. Do not copy
// the live owner; close once after the last send/identity consumer.
pub const CapturedRecord = struct {
    file: std.Io.File,
    length: u64,
    saved: CapturedIdentity,
    target: MutationTarget,

    pub fn identity(self: *const CapturedRecord) *const CapturedIdentity {
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

pub fn openCaptured(io: std.Io, directory: []const u8, handle: []const u8) !CapturedRecord {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(directory, handle, &path_buffer);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer file.close(io);
    const binding = try readCapturedBinding(io, &file);
    if (!binding.saved.key.eql(handle)) return error.InvalidRequestRecord;
    return .{ .file = file, .length = try file.length(io), .saved = binding.saved, .target = binding.target };
}

/// Metadata-only projection for listing/inspection; cannot authorize a send or
/// an admission. Historical payloads are not traversed by these callers.
pub fn inspectCaptured(io: std.Io, directory: []const u8, handle: []const u8) !CapturedIdentity {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, try requestPath(directory, handle, &path_buffer), .{});
    defer file.close(io);
    const saved = try readCapturedIdentity(io, &file, handle);
    _ = std.meta.stringToEnum(MutationKind, saved.kind.slice()) orelse return error.InvalidRequestRecord;
    return saved;
}

pub fn sendCaptured(io: std.Io, captured: *CapturedRecord, drop_reply: ?[]const u8, reply_buffer: *ReplyBuffer) !MutationReply {
    return (Requests{ .io = io }).sendCaptured(captured, drop_reply, reply_buffer);
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

fn readCapturedBinding(io: std.Io, file: *std.Io.File) !struct { saved: CapturedIdentity, target: MutationTarget } {
    const Fields = struct {
        version: JsonString(8),
        kind: JsonString(32),
        store: JsonString(protocol.max_store_bytes),
        key: JsonString(protocol.max_key_bytes),
        session: ?JsonString(protocol.max_session_bytes) = null,
        configuration: ?CapturedConfiguration = null,
        require_model: ?bool = null,
        text: ?struct { state: JsonString(8), value: CapturedText } = null,
        action: ?JsonString(20) = null,
        decision: ?JsonString(16) = null,
        target: ?struct { session: JsonString(protocol.max_session_bytes), turn: JsonString(20), operation: JsonString(20) } = null,
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
    if (!fields.version.eql("1")) return error.InvalidRequestRecord;
    const kind = std.meta.stringToEnum(MutationKind, fields.kind.slice()) orelse return error.InvalidRequestRecord;
    var saved: CapturedIdentity = .{ .store = fields.store.value, .key = fields.key.value, .kind = fields.kind.value };
    if (kind == .model_interruption) {
        if (fields.session != null) return error.InvalidRequestRecord;
        saved.session = (fields.target orelse return error.InvalidRequestRecord).session.value;
    } else saved.session = (fields.session orelse return error.InvalidRequestRecord).value;
    const target: MutationTarget = switch (kind) {
        .configure => blk: {
            if (fields.configuration == null) return error.InvalidRequestRecord;
            break :blk .configure;
        },
        .message => blk: {
            const text = fields.text orelse return error.InvalidRequestRecord;
            if (!text.state.eql("value")) return error.InvalidRequestRecord;
            break :blk .{ .message = .{ .bytes = text.value.bytes, .digest = text.value.digest } };
        },
        .session_stop => .session_stop,
        .model_interruption => .{ .model_interruption = .{
            .turn = mutationId(fields.target.?.turn, true) catch return error.InvalidRequestRecord,
            .operation = mutationId(fields.target.?.operation, true) catch return error.InvalidRequestRecord,
        } },
        .permission_decision => .{ .permission_decision = .{
            .action = mutationId(fields.action orelse return error.InvalidRequestRecord, true) catch return error.InvalidRequestRecord,
            .decision = std.meta.stringToEnum(protocol.PermissionDecision, (fields.decision orelse return error.InvalidRequestRecord).slice()) orelse return error.InvalidRequestRecord,
        } },
    };
    if ((kind != .configure and (fields.configuration != null or fields.require_model != null)) or
        (kind != .message and fields.text != null) or (kind != .model_interruption and fields.target != null) or
        (kind != .permission_decision and (fields.action != null or fields.decision != null))) return error.InvalidRequestRecord;
    return .{ .saved = saved, .target = target };
}

// Capture writes identity first, before variable content. Recover the bounded
// prefix without loading or copying the potentially large captured payload.
fn readCapturedIdentity(io: std.Io, file: *std.Io.File, handle: []const u8) !CapturedIdentity {
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
    if (!std.mem.eql(u8, parsed.value.version, "1") or !std.mem.eql(u8, parsed.value.key, handle)) return error.InvalidRequestRecord;
    var identity: CapturedIdentity = .{};
    try identity.store.set(parsed.value.store);
    try identity.key.set(parsed.value.key);
    const session = parsed.value.session orelse if (parsed.value.target) |target| target.session else return error.InvalidRequestRecord;
    try identity.session.set(session);
    try identity.kind.set(parsed.value.kind);
    return identity;
}

pub fn captureConfigure(io: std.Io, input: ConfigureInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    var session_buffer: ["rui/".len + protocol.max_key_bytes]u8 = undefined;
    const session = switch (input.session) {
        .named => |name| name,
        .from_capture_key => try std.fmt.bufPrint(&session_buffer, "rui/{s}", .{location.key}),
    };
    try validateIdentityInputs(location.key, session);
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writeHeader(.configure);
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(location.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(session);
    try capture.write(",\"configuration\":{\"workspace\":");
    try capture.writeOptionalText(input.workspace);
    try capture.write(",\"provider\":");
    try capture.writeOptionalText(input.provider);
    try capture.write(",\"model\":");
    try capture.writeOptionalText(input.model);
    try capture.write(",\"instructions\":");
    try capture.writeOptionalFile(input.instructions, false);
    try capture.write(",\"tools\":");
    try capture.writeTools(input.tools);
    try capture.write(",\"permission_mode\":");
    try capture.writeOptionalText(input.permission_mode);
    try capture.write(",\"output_schema\":");
    try capture.writeOptionalFile(input.output_schema, true);
    try capture.write(",\"compaction_trigger\":");
    try capture.writeOptionalPolicy(input.compaction_trigger);
    try capture.write(",\"output_reservation\":");
    try capture.writeOptionalPolicy(input.output_reservation);
    try capture.write(if (input.require_model) "},\"require_model\":true}" else "}}");
    return finishCapture(io, &capture, paths.store.slice(), location.key, session, .configure);
}

pub fn captureMessage(io: std.Io, input: MessageInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try validateIdentityInputs(location.key, input.session);
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writeHeader(.message);
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(location.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
    try capture.write(",\"text\":{\"state\":\"value\",\"value\":");
    if (input.text) |value| {
        if (value.len > protocol.max_sqlite_content_bytes) return error.ContentTooLarge;
        try capture.writeJsonString(value);
    } else try capture.writeJsonFile(input.text_path);
    try capture.write("}}");
    return finishCapture(io, &capture, paths.store.slice(), location.key, input.session, .message);
}

fn writeSessionStopCapture(io: std.Io, paths: *const platform.Paths, input: SessionStopInput, location: @FieldType(CaptureTarget, "explicit")) !CapturedRecord {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writeHeader(.session_stop);
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(location.key);
    try capture.write(",\"session\":");
    try capture.writeJsonString(input.session);
    try capture.write("}");
    return finishCapture(io, &capture, paths.store.slice(), location.key, input.session, .session_stop);
}

fn writeModelInterruptionCapture(
    io: std.Io,
    paths: *const platform.Paths,
    input: ModelInterruptionInput,
    location: @FieldType(CaptureTarget, "explicit"),
) !CapturedRecord {
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writeHeader(.model_interruption);
    try capture.writeJsonString(paths.store.slice());
    try capture.write(",\"key\":");
    try capture.writeJsonString(location.key);
    try capture.write(",\"target\":{\"session\":");
    try capture.writeJsonString(input.session);
    var ids: [96]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&ids, ",\"turn\":\"{d}\",\"operation\":\"{d}\"}}}}", .{
        input.turn_id,
        input.operation_id,
    });
    try capture.write(suffix);
    return finishCapture(io, &capture, paths.store.slice(), location.key, input.session, .model_interruption);
}

pub fn capturePermissionDecision(io: std.Io, input: PermissionDecisionInput, target: CaptureTarget) !CapturedRecord {
    const paths = try platform.resolveClientPaths(io, input.store);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var key_buffer: [36]u8 = undefined;
    const location = try target.resolve(io, &path_buffer, &key_buffer);
    try validateIdentityInputs(location.key, input.session);
    if (input.action_id == 0) return error.InvalidTarget;
    var output_buffer: [protocol.content_window_bytes]u8 = undefined;
    var capture = try Capture.open(io, location.record, &output_buffer);
    errdefer capture.abort();
    try capture.writePermissionDecision(paths.store.slice(), location.key, input);
    return finishCapture(io, &capture, paths.store.slice(), location.key, input.session, .permission_decision);
}

fn finishCapture(io: std.Io, capture: *Capture, store: []const u8, key: []const u8, session: []const u8, kind: MutationKind) !CapturedRecord {
    var saved: CapturedIdentity = .{};
    try saved.store.set(store);
    try saved.key.set(key);
    try saved.session.set(session);
    try saved.kind.set(@tagName(kind));
    // Pin the temporary inode under capture custody, before exposing its name.
    // This reader observes the final flush, not a later public-path replacement.
    var file = try capture.parent.openFile(io, capture.temporary_name.slice(), .{});
    errdefer file.close(io);
    // A post-publication directory-sync failure returns no transmissible owner,
    // but abort preserves the published name for later explicit recovery.
    try capture.commit();
    const length = try file.length(io);
    const binding = try readCapturedBinding(io, &file);
    if (!binding.saved.store.eql(store) or !binding.saved.key.eql(key) or !binding.saved.session.eql(session) or binding.target != kind) return error.InvalidRequestRecord;
    return .{ .file = file, .length = length, .saved = saved, .target = binding.target };
}

const Capture = struct {
    io: std.Io,
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

    fn writeHeader(self: *Capture, comptime kind: MutationKind) !void {
        try self.write("{\"version\":\"1\",\"kind\":\"" ++ @tagName(kind) ++ "\",\"store\":");
    }

    fn writePermissionDecision(self: *Capture, store: []const u8, key: []const u8, input: PermissionDecisionInput) !void {
        try self.writeHeader(.permission_decision);
        try self.writeJsonString(store);
        try self.write(",\"key\":");
        try self.writeJsonString(key);
        try self.write(",\"session\":");
        try self.writeJsonString(input.session);
        var suffix: [96]u8 = undefined;
        try self.write(try std.fmt.bufPrint(&suffix, ",\"action\":\"{d}\",\"decision\":\"{s}\"}}", .{
            input.action_id,
            @tagName(input.decision),
        }));
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

    fn writeJsonFile(self: *Capture, path: []const u8) !void {
        return self.writeJsonFileBounded(path, protocol.max_sqlite_content_bytes);
    }

    fn writeJsonFileBounded(self: *Capture, path: []const u8, limit: u64) !void {
        var file = if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdin()
        else
            try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer if (!std.mem.eql(u8, path, "-")) file.close(self.io);
        try self.write("\"");
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var validator = Utf8Validator{};
        var decoded_bytes: u64 = 0;
        while (true) {
            const count = file.readStreaming(self.io, &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (count == 0) break;
            const next = std.math.add(u64, decoded_bytes, count) catch return error.ContentTooLarge;
            if (next > limit) return error.ContentTooLarge;
            decoded_bytes = next;
            try validator.feed(buffer[0..count]);
            // Default encoding copies non-ASCII bytes unchanged, including a UTF-8
            // sequence split across reads; the streaming validator owns validity.
            std.json.Stringify.encodeJsonStringChars(buffer[0..count], .{}, &self.writer.interface) catch
                return self.writer.err orelse error.WriteFailed;
        }
        if (!validator.complete()) return error.InvalidUtf8;
        try self.write("\"");
    }

    fn writeTools(self: *Capture, tools: ?[]const u8) !void {
        const value = tools orelse return self.write("{\"state\":\"omitted\"}");
        try self.write("{\"state\":\"value\",\"value\":[");
        if (!std.mem.eql(u8, value, "none")) {
            var iterator = std.mem.splitScalar(u8, value, ',');
            var count: usize = 0;
            var seen_bash = false;
            var seen_edit = false;
            while (iterator.next()) |tool| {
                if (count != 0) try self.write(",");
                if (std.mem.eql(u8, tool, "bash")) {
                    if (seen_bash) return error.DuplicateTool;
                    seen_bash = true;
                } else if (std.mem.eql(u8, tool, "edit")) {
                    if (seen_edit) return error.DuplicateTool;
                    seen_edit = true;
                } else return error.UnknownTool;
                try self.writeJsonString(tool);
                count += 1;
                if (count > 2) return error.TooManyTools;
            }
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
    const header = try std.fmt.bufPrint(&header_buffer, "POST " ++ route ++ " HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n\r\n", .{body.len});
    try writeAllRequest(requests, fd, header, null);
    try writeAllRequest(requests, fd, body, null);
    return fd;
}

fn sendSource(
    requests: Requests,
    paths: *const platform.Paths,
    route: []const u8,
    timing: ResponseTiming,
    length: u64,
    file: ?*std.Io.File,
    bytes: ?[]const u8,
    drop_reply: ?[]const u8,
    instance: ?*const protocol.InstanceId,
    reply_buffer: anytype,
    until: ?i128,
) !CommandReply {
    const io = requests.io;
    const address = try std.Io.net.UnixAddress.init(paths.socket.slice());
    const fd = try connectRequest(requests, address, until);
    defer closeSocket(io, fd);
    var header_buffer: [512]u8 = undefined;
    var used = (try std.fmt.bufPrint(&header_buffer, "POST {s} HTTP/1.1\r\nHost: local\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\nX-Rui-Wire-Version: 1\r\n", .{ route, length })).len;
    if (instance) |id| {
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Host-Instance: {s}\r\n", .{std.fmt.bytesToHex(id.*, .lower)})).len;
    }
    if (drop_reply) |drop| {
        used += (try std.fmt.bufPrint(header_buffer[used..], "X-Rui-Test-Drop-Reply: {s}\r\n", .{drop})).len;
    }
    used += (try std.fmt.bufPrint(header_buffer[used..], "\r\n", .{})).len;
    try writeAllRequest(requests, fd, header_buffer[0..used], until);
    if (file) |source| {
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        var sent: u64 = 0;
        while (sent < length) {
            try requests.check();
            const wanted: usize = @intCast(@min(length - sent, buffer.len));
            const count = try source.readPositionalAll(io, buffer[0..wanted], sent);
            if (count != wanted) return error.RecordChangedDuringSend;
            try writeAllRequest(requests, fd, buffer[0..count], until);
            sent += count;
        }
    } else try writeAllRequest(requests, fd, bytes.?, until);
    return readCommandResponseRequest(requests, fd, reply_buffer, timing, until);
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

fn readCommandResponse(fd: std.posix.fd_t, reply_buffer: *ReplyBuffer) !CommandReply {
    return readCommandResponseRequest(.{ .io = std.Io.Threaded.global_single_threaded.io() }, fd, reply_buffer, .{}, null);
}

fn readCommandResponseRequest(requests: Requests, fd: std.posix.fd_t, reply_buffer: anytype, timing: ResponseTiming, until: ?i128) !CommandReply {
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
) !ResultReply {
    return readResultResponseSink(.{ .io = io }, fd, destination, reply_buffer);
}

fn readResultResponseSink(
    requests: Requests,
    fd: std.posix.fd_t,
    sink: anytype,
    reply_buffer: *ReplyBuffer,
) !ResultReply {
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
) !ReportReply {
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

fn readCommandBodyUntil(requests: Requests, fd: std.posix.fd_t, head: ResponseHead, reply_buffer: anytype, timing: ResponseTiming, until: ?i128) !CommandReply {
    reply_buffer.len = 0;
    errdefer reply_buffer.len = 0;
    if (head.content_length > reply_buffer.bytes.len) return error.ResponseTooLarge;
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

// Shared authority rule for operation replies and static read/error envelopes.
fn validateInvocationDiagnostic(status: u16, version: []const u8, diagnostic: InvocationDiagnostic) error{InvalidResponse}!void {
    if (status == 200 or !std.mem.eql(u8, version, "1") or diagnostic.type.len == 0 or diagnostic.code.len == 0) return error.InvalidResponse;
    if (diagnostic.code.eql("canonical_store_failure") and (status != 500 or !diagnostic.type.eql("invocation_error"))) return error.InvalidResponse;
}

// Remaining snapshot/report/Action callers check canonical failure here;
// mutation and keyed-read callers own diagnostics from their envelope parse.
pub fn checkCanonicalFailure(reply: CommandReply) !void {
    if (reply.status == 200) return;
    if (reply.body.len > protocol.max_response_bytes) return error.InvalidResponse;
    const Envelope = struct {
        const Field = enum {
            other,
            version_1,
            invocation_error,
            canonical,

            pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
                // A plain []const u8 field also accepts JSON byte arrays.
                if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
                const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                defer if (token == .allocated_string) allocator.free(token.allocated_string);
                const value = switch (token) {
                    .string, .allocated_string => |string| string,
                    else => unreachable,
                };
                if (std.mem.eql(u8, value, "1")) return .version_1;
                if (std.mem.eql(u8, value, "invocation_error")) return .invocation_error;
                return if (std.mem.eql(u8, value, "canonical_store_failure")) .canonical else .other;
            }
        };

        version: Field = .other,
        type: Field = .other,
        code: Field = .other,
    };
    // Reserve nesting first, including malformed N-opening-delimiter prefixes.
    // Names/fields decode one byte string at a time and free it before advancing.
    // With stack growth excluded, FBA grows/shrinks that last allocation in
    // place. Both byte arrays are bounded by stdlib's capacity growth formula.
    const capacity = comptime std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) +
        std.ArrayList(u8).growCapacity(protocol.max_response_bytes);
    var storage: [capacity]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = fixed.allocator();
    var scanner = std.json.Scanner.initCompleteInput(allocator, reply.body);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(protocol.max_response_bytes) catch unreachable;
    const envelope = std.json.parseFromTokenSourceLeaky(Envelope, allocator, &scanner, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => unreachable, // The bounded-storage proof above covers every input.
        else => return error.InvalidResponse,
    };
    // Unknown values receive full syntax validation but no duplicate-key policy;
    // version, type and code alone establish invocation-error authority.
    if (envelope.code == .canonical) {
        var diagnostic: InvocationDiagnostic = .{ .type = .{}, .code = .{} };
        diagnostic.code.set("canonical_store_failure") catch unreachable;
        if (envelope.type == .invocation_error) diagnostic.type.set("invocation_error") catch unreachable;
        try validateInvocationDiagnostic(reply.status, if (envelope.version == .version_1) "1" else "", diagnostic);
        return error.CanonicalStoreFailure;
    }
}

test "canonical failure classifier validates complete string-only error envelope" {
    const canonical = [_][]const u8{
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"vers\\u0069on\":\"1\",\"ty\\u0070e\":\"invocation_\\u0065rror\",\"co\\u0064e\":\"canonical_store_\\u0066ailure\",\"extra\":[1,{}]}",
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"extra\":{\"x\":1,\"x\":2},\"extra\":null}",
    };
    for (canonical) |body| try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body }));
    const prefix = "{\"version\":\"1\",\"type\":\"invocation_error\",";
    for ([_][]const u8{
        prefix ++ "\"code\":\"canonical_store_failure\",\"co\\u0064e\":\"other\"}",
        prefix ++ "\"code\":\"canonical_store_failure\",\"extra\":[}",
        prefix ++ "\"code\":\"canonical_store_failure\"} trailing",
        prefix ++ "\"code\":null}",
        prefix ++ "\"code\":[99,97,110,111,110,105,99,97,108,95,115,116,111,114,101,95,102,97,105,108,117,114,101]}",
        "[]",
    }) |body| try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body }));
    try checkCanonicalFailure(.{ .status = 503, .body = "{\"code\":\"unavailable\"}" });
    try checkCanonicalFailure(.{ .status = 500, .body = "{\"extra\":\"canonical_store_failure\"}" });
    try checkCanonicalFailure(.{ .status = 200, .body = "not an error envelope" });
}

test "canonical failure classifier uses only authoritative invocation envelope" {
    for ([_][]const u8{
        "{\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"2\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"vers\\u0069on\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"ty\\u0070e\":\"message_reply\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":null,\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}",
        "{\"version\":\"1\",\"type\":[105],\"code\":\"canonical_store_failure\"}",
        "{\"answer\":{\"code\":\"canonical_store_failure\",\"extra\":[}}",
    }) |body| try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body }));
    for ([_][]const u8{
        "{}",
        "{\"version\":\"1\",\"type\":\"message_reply\",\"answer\":{\"status\":\"infrastructure_failure\",\"code\":\"canonical_store_failure\"}}",
        "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"unavailable\",\"answer\":{\"code\":\"canonical_store_failure\"}}",
        "{\"answer\":{\"code\":\"unavailable\"}}",
        "{\"answer\":{\"extra\":{\"code\":\"canonical_store_failure\"}}}",
        "{\"extra\":{\"answer\":{\"code\":\"canonical_store_failure\"}}}",
    }) |body| try checkCanonicalFailure(.{ .status = 500, .body = body });
    const body = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}";
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 409, .body = body }));
}

test "canonical failure classifier bounds deep wide and escaped maximum replies" {
    const prefix = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"extra\":";
    var body: [protocol.max_response_bytes + 1]u8 = undefined;
    @memcpy(body[0..prefix.len], prefix);
    const depth = (protocol.max_response_bytes - prefix.len - 2) / 2;
    @memset(body[prefix.len..][0..depth], '[');
    var length = prefix.len + depth;
    body[length] = '0';
    length += 1;
    @memset(body[length..][0..depth], ']');
    length += depth;
    body[length] = '}';
    length += 1;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
    @memset(body[prefix.len..protocol.max_response_bytes], '[');
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));

    // A nearly maximum escaped field name must be released before code decode.
    const field_prefix = "{\"";
    const field_suffix = "\":0,\"version\":\"1\",\"type\":\"invocation_error\",\"co\\u0064e\":\"canonical_store_\\u0066ailure\"}";
    @memcpy(body[0..field_prefix.len], field_prefix);
    length = field_prefix.len;
    const escaped_end = protocol.max_response_bytes - field_suffix.len - 6;
    @memset(body[length..escaped_end], 'x');
    length = escaped_end;
    @memcpy(body[length..][0..6], "\\u0078");
    length += 6;
    @memcpy(body[length..][0..field_suffix.len], field_suffix);
    length += field_suffix.len;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));

    @memcpy(body[0..prefix.len], prefix);
    length = prefix.len;
    const wide = "{\"x\":0,\"x\":0}";
    // Discarded wide objects validate syntax, not irrelevant key uniqueness.
    body[length] = '[';
    length += 1;
    while (length + wide.len + 3 <= protocol.max_response_bytes) {
        @memcpy(body[length..][0..wide.len], wide);
        length += wide.len;
        body[length] = ',';
        length += 1;
    }
    length -= 1;
    @memcpy(body[length..][0..2], "]}");
    length += 2;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
    body[protocol.max_response_bytes] = ' ';
    try std.testing.expectError(error.InvalidResponse, checkCanonicalFailure(.{ .status = 500, .body = &body }));

    @memcpy(body[0..prefix.len], prefix);
    length = prefix.len;
    // Consecutive escaped names must not accumulate decoded allocations.
    const names = "\"ignored\",\"\\u0061\":0,";
    @memcpy(body[length..][0..names.len], names);
    length += names.len;
    const name = "\"\\u0061\":0,";
    while (length + name.len + 1 <= protocol.max_response_bytes) {
        @memcpy(body[length..][0..name.len], name);
        length += name.len;
    }
    length -= 1;
    body[length] = '}';
    length += 1;
    @memset(body[length..protocol.max_response_bytes], ' ');
    try std.testing.expectError(error.CanonicalStoreFailure, checkCanonicalFailure(.{ .status = 500, .body = body[0..protocol.max_response_bytes] }));
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
    "X-Rui-Wire-Version: 1\r\n\r\n";

fn socketPair() ![2]std.posix.fd_t {
    var sockets: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &sockets) != 0) {
        return error.SocketPairFailed;
    }
    return sockets;
}

fn delayedResponse(io: std.Io, fd: std.posix.fd_t, delay: std.Io.Duration, response: []const u8) void {
    defer closeTestDescriptor(fd);
    std.Io.sleep(io, delay, .awake) catch return;
    writeAll(fd, response) catch {};
}

test "Host processing wait starts inactivity only after the first response byte" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, delayedResponse, .{
        std.testing.io,
        sockets[1],
        std.Io.Duration.fromMilliseconds(50),
        empty_test_response,
    });
    defer writer.join();
    const head = try readResponseHeadWithInactivity(sockets[0], 10);
    try std.testing.expectEqual(@as(u16, 200), head.status);
}

test "Host-info first byte is bounded independently of normal processing waits" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, delayedResponse, .{
        std.testing.io,
        sockets[1],
        std.Io.Duration.fromMilliseconds(50),
        empty_test_response,
    });
    defer writer.join();
    var buffer: ReplyBuffer = .{};
    const until = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
    try std.testing.expectError(error.ResponseInactive, readCommandResponseRequest(.{ .io = std.testing.io }, sockets[0], &buffer, .{}, until));
}

test "response deadlines include partial header and body" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\nab";
    const body_start = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
    for ([_]bool{ false, true }) |mutation| {
        for ([_]usize{ 1, body_start + 1 }) |prefix_len| {
            const sockets = try socketPair();
            defer closeTestDescriptor(sockets[0]);
            try addNonblocking(sockets[0]);
            try writeAll(sockets[1], response[0..prefix_len]);
            const writer = try std.Thread.spawn(.{}, delayedResponse, .{
                std.testing.io,
                sockets[1],
                std.Io.Duration.fromMilliseconds(50),
                response[prefix_len..],
            });
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
            writeAll(fd, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n") catch return;
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
    const writer = try std.Thread.spawn(.{}, delayedResponse, .{
        std.testing.io,
        sockets[1],
        std.Io.Duration.fromSeconds(61),
        empty_test_response,
    });
    defer writer.join();
    var buffer: ReplyBuffer = .{};
    const reply = try readCommandResponse(sockets[0], &buffer);
    try std.testing.expectEqual(@as(u16, 200), reply.status);
}

test "response transfer inactivity begins after the first byte" {
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    const writer = try std.Thread.spawn(.{}, delayedResponse, .{
        std.testing.io,
        sockets[1],
        std.Io.Duration.fromMilliseconds(50),
        empty_test_response[1..],
    });
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
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\nx",
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
        const bytes = try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Rui-Wire-Version: 1\r\n{s}\r\n", .{fields});
        try writeAll(sockets[1], bytes);
        try std.testing.expectError(error.InvalidResponse, readResponseHead(sockets[0]));
    }
    const sockets = try socketPair();
    defer closeTestDescriptor(sockets[0]);
    defer closeTestDescriptor(sockets[1]);
    try writeAll(sockets[1], "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 00\r\nX-Rui-Wire-Version: 1\r\nX-Extra: one\r\nx-extra: two\r\n\r\n");
    try std.testing.expectEqual(@as(u16, 200), (try readResponseHead(sockets[0])).status);
}

test "capture configure derives Session from captured key and retains model admission" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    for ([_]?[]const u8{ "100000", null }) |trigger| {
        var captured = try captureConfigure(io, .{
            .store = root,
            .session = .from_capture_key,
            .require_model = true,
            .compaction_trigger = .{ .present = true, .value = trigger },
            .output_reservation = .{ .present = true, .value = if (trigger != null) "16384" else null },
        }, .{ .generated = root });
        const saved = captured.identity().*;
        var bytes: [2048]u8 = undefined;
        const count = blk: {
            defer captured.close(io);
            break :blk try captured.file.readPositionalAll(io, &bytes, 0);
        };
        try std.testing.expect(validRequestHandle(saved.key.slice()));
        var expected_buffer: ["rui/".len + 36]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buffer, "rui/{s}", .{saved.key.slice()});
        try std.testing.expectEqualStrings(expected, saved.session.slice());
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[0..count], .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(saved.key.slice(), parsed.value.object.get("key").?.string);
        try std.testing.expectEqualStrings(expected, parsed.value.object.get("session").?.string);
        try std.testing.expect(parsed.value.object.get("require_model").?.bool);
        const settings = parsed.value.object.get("configuration").?.object;
        if (trigger != null) {
            try std.testing.expectEqualStrings("100000", settings.get("compaction_trigger").?.object.get("value").?.string);
            try std.testing.expectEqualStrings("16384", settings.get("output_reservation").?.object.get("value").?.string);
        } else {
            try std.testing.expectEqualStrings("null", settings.get("compaction_trigger").?.object.get("state").?.string);
            try std.testing.expectEqualStrings("null", settings.get("output_reservation").?.object.get("state").?.string);
        }
        var recovered = try openCaptured(io, root, saved.key.slice());
        defer recovered.close(io);
        try std.testing.expectEqualStrings(expected, recovered.identity().session.slice());
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
    var captured = try captureMessage(io, .{ .store = root, .session = "s/µ", .text = &text, .text_path = "" }, .{ .generated = root });
    const saved = captured.saved;
    const expected = protocol.contentDigest(&text);
    try std.testing.expectEqual(@as(u64, text.len), captured.target.message.bytes);
    try std.testing.expectEqualSlices(u8, &expected, &captured.target.message.digest);
    captured.close(io);
    var recovered = try openCaptured(io, root, saved.key.slice());
    try std.testing.expectEqualSlices(u8, &expected, &recovered.target.message.digest);
    recovered.close(io);
    // Listing is an identity projection, not permission to transmit. It must
    // not traverse every historical payload to recover one local handle.
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, try requestPath(root, saved.key.slice(), &path), .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, " trailing", try file.length(io));
    try std.testing.expectEqualStrings("s/µ", (try inspectCaptured(io, root, saved.key.slice())).session.slice());
    try std.testing.expectError(error.InvalidRequestRecord, openCaptured(io, root, saved.key.slice()));
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
    var stop = try captureSessionStop(io, .{ .store = root, .session = "s" }, .{ .explicit = .{ .record = stop_record, .key = stop_key } });
    stop.close(io);
    var interruption = try captureModelInterruption(io, .{ .store = root, .session = "i/µ", .turn_id = 3, .operation_id = 5 }, .{ .generated = root });
    const interruption_key = interruption.saved.key;
    interruption.close(io);
    var message = try captureMessage(io, .{ .store = root, .session = "s", .text = "m", .text_path = "" }, .{ .generated = root });
    const message_key = message.saved.key;
    message.close(io);
    var message_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const message_record = try requestPath(root, message_key.slice(), &message_path);

    // Every captured mutation kind, including controls whose records hold only
    // bounded identities, reopens through its generated handle.
    var stop_recovered = try openCaptured(io, root, stop_key);
    try std.testing.expect(stop_recovered.target == .session_stop);
    stop_recovered.close(io);
    const stop_saved = try inspectCaptured(io, root, stop_key);
    try std.testing.expect(stop_saved.isKind(.session_stop));
    try std.testing.expectEqualStrings("s", stop_saved.session.slice());
    var interruption_recovered = try openCaptured(io, root, interruption_key.slice());
    try std.testing.expectEqual(@as(u64, 5), interruption_recovered.target.model_interruption.operation);
    interruption_recovered.close(io);
    try std.testing.expectEqualStrings("i/µ", (try inspectCaptured(io, root, interruption_key.slice())).session.slice());
    var recovered = try openCaptured(io, root, message_key.slice());
    recovered.close(io);
    try std.testing.expect((try inspectCaptured(io, root, message_key.slice())).isKind(.message));

    // Retry accepts only the hyphenated command spelling of the record's own
    // kind. A matching kind reaches transmission, which fails without a Host.
    var reply: ReplyBuffer = .{};
    try std.testing.expectError(error.InvalidRetryKind, retry(io, root, stop_record, "session_stop", &reply));
    try std.testing.expectError(error.RequestBindingMismatch, retry(io, root, stop_record, "model-interruption", &reply));
    try std.testing.expectError(error.FileNotFound, retry(io, root, stop_record, "session-stop", &reply));
    try std.testing.expectError(error.RequestBindingMismatch, retry(io, root, message_record, "permission-decision", &reply));
    try std.testing.expectError(error.FileNotFound, retry(io, root, message_record, "message", &reply));
}

test "capture returns original identity before send and preserves empty explicit keys" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    const input: MessageInput = .{ .store = root, .session = "original/é", .text_path = "", .text = "original\ntext" };
    var generated = try captureMessage(io, input, .{ .generated = root });
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
        try std.testing.expectEqualStrings("original/é", saved.session.slice());
        try std.testing.expectEqualStrings("message", saved.kind.slice());
        var reply: ReplyBuffer = .{};
        try std.testing.expectError(error.FileNotFound, sendCaptured(io, &generated, null, &reply));
        try std.testing.expectEqualStrings(saved.key.slice(), generated.identity().key.slice());
        try std.testing.expectEqualStrings(root, generated.identity().store.slice());
    }
    try std.testing.expect(std.c.fcntl(descriptor, std.c.F.GETFD) < 0);
    var recovered = try openCaptured(io, root, saved.key.slice());
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
    var explicit = try captureMessage(io, input, .{ .explicit = .{ .record = path, .key = "" } });
    defer explicit.close(io);
    try std.testing.expectEqualStrings("", explicit.identity().key.slice());
    try std.testing.expectError(error.RecordAlreadyExists, captureMessage(io, input, .{ .explicit = .{ .record = path, .key = "different" } }));
    try std.testing.expectError(error.InvalidRequestHandle, openCaptured(io, root, ""));
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
    var captured = try captureMessage(io, .{ .store = root, .session = "original/session", .text_path = "", .text = &text }, .{ .explicit = .{ .record = path, .key = "owned-key" } });
    defer captured.close(io);
    var expected_buffer: [text.len + 1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"1\",\"kind\":\"message\",\"store\":\"{s}\",\"key\":\"owned-key\",\"session\":\"original/session\",\"text\":{{\"state\":\"value\",\"value\":\"{s}\"}}}}", .{ root, text });
    var vtable = io.vtable.*;
    vtable.netConnectUnix = Peer.connect;
    const connected_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    for ([_]Peer.Response{ .closed, .silent, .reply }) |response| {
        const sockets = try socketPair();
        Peer.client_fd = sockets[0]; // The production send owns and closes it.
        Peer.failure = null;
        const peer = try std.Thread.spawn(.{}, Peer.serve, .{ sockets[1], expected, response });
        var buffer: ReplyBuffer = .{};
        const result = sendCaptured(connected_io, &captured, null, &buffer);
        peer.join();
        if (Peer.failure) |err| return err;
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
    var captured = try captureMessage(replaced_io, .{ .store = root, .session = "original/session", .text_path = "", .text = "original\ntext" }, .{ .explicit = .{ .record = path, .key = "original-key" } });
    defer captured.close(io);
    var expected_buffer: [2048]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buffer, "{{\"version\":\"1\",\"kind\":\"message\",\"store\":\"{s}\",\"key\":\"original-key\",\"session\":\"original/session\",\"text\":{{\"state\":\"value\",\"value\":\"original\\ntext\"}}}}", .{root});
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
        try std.testing.expectError(if (published) error.AccessDenied else error.NoSpaceLeft, captureMessage(failing_io, .{ .store = root, .session = "original/session", .text_path = "", .text = "original" }, .{ .explicit = .{ .record = path, .key = "original-key" } }));
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
        "{\"version\":\"1\",\"kind\":\"session_stop\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"original\",\"text\":{}}",
        "{\"version\":\"1\",\"kind\":\"model_interruption\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"target\":{\"session\":\"original\",\"turn\":\"x\",\"operation\":\"2\"}}",
        "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"other\",\"session\":\"original\",\"text\":{}}",
        "{\"version\":\"1\",\"kind\":\"unknown\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"original\",\"text\":{}}",
        "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"original\",\"text\":{\"state\":\"value\",\"value\":\"a\",\"val\\u0075e\":\"b\"}}",
        "{\"version\":\"1\",\"kind\":\"message\",\"store\":\"unused\",\"key\":\"" ++ handle ++ "\",\"session\":\"original\",\"text\":{\"state\":\"value\",\"value\":[97]}}",
    }) |bytes| {
        const file = try tmp.dir.createFile(io, filename, .{});
        try file.writeStreamingAll(io, bytes);
        file.close(io);
        try std.testing.expectError(error.InvalidRequestRecord, openCaptured(observed_io, root, handle));
        try std.testing.expectEqual(Probe.opened, Probe.closed);
    }
    try tmp.dir.deleteFile(io, filename);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try requestPath(root, handle, &path_buffer);
    var captured = try captureConfigure(io, .{ .store = root, .session = .{ .named = "original" } }, .{ .explicit = .{ .record = path, .key = handle } });
    captured.close(io);
    var recovered = try openCaptured(observed_io, root, handle);
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
        try std.testing.expect(std.mem.startsWith(u8, bytes[0..n], "{\"version\":\"1\",\"kind\":\"configure\""));
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
    try std.testing.expectError(error.ContentTooLarge, capture.writeJsonFileBounded(source_path, 4));
    capture.abort();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
    capture = try Capture.open(io, path, &buffer);
    try capture.writeJsonFileBounded(source_path, 5);
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
            try std.testing.expectError(error.ContentTooLarge, capture.writeJsonFileBounded("-", limit));
            capture.abort();
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "record", .{}));
        } else {
            try capture.writeJsonFileBounded("-", limit);
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
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Rui-Wire-Version: 1\r\n\r\n{\"status\":\"error\"}",
    );
    var buffer: ReplyBuffer = .{};
    const reply = try readCommandResponse(descriptors[0], &buffer);
    try std.testing.expectEqual(@as(u16, 409), reply.status);
    try std.testing.expectEqualStrings("{\"status\":\"error\"}", reply.body);
    try std.testing.expectEqual(@intFromPtr(buffer.bytes[0..].ptr), @intFromPtr(reply.body.ptr));
}

test "bounded read requests attain their independent worst-case capacities" {
    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    const cases = .{
        .{ "observe_command", "key", &escaped_key, null, null, protocol.max_observe_command_request_bytes },
        .{ "read_result", "key", &escaped_key, null, null, protocol.max_read_result_request_bytes },
        .{ "inspect_session", "session", &escaped_session, null, protocol.ReportProfile.full, protocol.max_inspect_session_request_bytes },
        .{ "read_action_call_id", "session", &escaped_session, std.math.maxInt(u64), null, protocol.max_read_action_call_id_request_bytes },
        .{ "read_action_arguments", "session", &escaped_session, std.math.maxInt(u64), null, protocol.max_read_action_arguments_request_bytes },
    };
    inline for (cases) |case| {
        var body: protocol.RequestBuffer = .{};
        try renderReadRequest(&body, case[0], &escaped_store, case[1], case[2], case[3], case[4]);
        try std.testing.expectEqual(@as(usize, case[5]), body.len);
    }
    var full: protocol.RequestBuffer = .{};
    full.len = full.bytes.len;
    try std.testing.expectError(error.BufferTooLarge, full.append("x"));
}

test "Session list client renders exact cursor and maximum escaped workspace without truncation" {
    var empty: protocol.RequestBuffer = .{};
    try renderSessionListRequest(&empty, "/store", null, .{});
    try std.testing.expectEqualStrings(
        "{\"version\":\"1\",\"kind\":\"list_sessions\",\"store\":\"/store\",\"workspace\":null,\"after\":\"0\",\"ceiling\":\"0\"}",
        empty.slice(),
    );
    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const escaped_workspace = @as([protocol.max_workspace_bytes]u8, @splat(1));
    var maximum: protocol.RequestBuffer = .{};
    try renderSessionListRequest(&maximum, &escaped_store, &escaped_workspace, .{
        .after = std.math.maxInt(i64),
        .ceiling = std.math.maxInt(i64),
    });
    try std.testing.expectEqual(protocol.max_list_sessions_request_bytes - 1, maximum.len);
    try std.testing.expect(std.mem.endsWith(u8, maximum.slice(), "\"after\":\"9223372036854775807\",\"ceiling\":\"9223372036854775807\"}"));
}

test "Session list facts own complete rows and render semantic output after scratch reuse" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"s\\u002fµ\",\"workspace\":\"/w\\nµ\",\"provider\":\"codex\",\"model\":\"m\\\"\",\"tools\":[\"edit\",\"bash\"],\"permission_mode\":\"ask\",\"extra\":[null,{\"discard\":true}]}],\"next\":null,\"extra\":1}";
    try file.writePositionalAll(io, wire, 0);
    const decoded = try SessionListReply.decode(io, file, "/w\nµ", .{}, .{ .report = .{ .bytes = wire.len } });
    const page = &decoded.page;
    try file.writePositionalAll(io, &@as([wire.len]u8, @splat('x')), 0);
    try std.testing.expectEqual(@as(usize, 1), page.count);
    try std.testing.expectEqualStrings("s/µ", page.rows[0].reference.slice());
    try std.testing.expectEqualStrings("/w\nµ", page.rows[0].workspace.slice());
    var output: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try page.writeJson(&writer);
    try std.testing.expectEqualStrings("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"s/µ\",\"workspace\":\"/w\\nµ\",\"provider\":\"codex\",\"model\":\"m\\\"\",\"tools\":[\"bash\",\"edit\"],\"permission_mode\":\"ask\"}],\"next\":null}", writer.buffered());
    var exhausted = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, page.writeJson(&exhausted));
}

test "Session list reply owns read failure facts without asserting absence or admission" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "empty-report", .{ .read = true });
    defer file.close(io);
    var wire = "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"extension\":null}".*;
    const reply = try SessionListReply.decode(io, file, null, .{}, .{ .command = .{ .status = 503, .body = &wire } });
    @memset(&wire, 'x');
    try std.testing.expectEqual(@as(u16, 503), reply.failure.status);
    try std.testing.expectEqualStrings("busy", reply.failure.diagnostic.type.slice());
    try std.testing.expectEqualStrings("ordinary_capacity_exhausted", reply.failure.diagnostic.code.slice());
    try std.testing.expectEqual(error.HostInvocationFailed, reply.failure.err());
}

test "Session list byte range rejects zero instead of decoding an older page" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = 0 } }));
}

test "Session list byte range reads a shorter overwritten prefix without changing borrowed storage" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const old = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"old\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"}],\"next\":null}";
    const current = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, old, 0);
    try file.writePositionalAll(io, current, 0);
    const reply = try SessionListReply.decode(io, file, "/w", .{}, .{ .report = .{ .bytes = current.len } });
    try std.testing.expectEqual(@as(usize, 0), reply.page.count);
    try std.testing.expectEqual(@as(?SessionListCursor, null), reply.page.next);
    var bytes: [old.len]u8 = undefined;
    try std.testing.expectEqual(old.len, try file.length(io));
    try std.testing.expectEqual(old.len, try file.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings(current, bytes[0..current.len]);
    try std.testing.expectEqualStrings(old[current.len..], bytes[current.len..]);
    var writer = std.Io.Writer.fixed(&bytes);
    try reply.page.writeJson(&writer);
    try std.testing.expectEqualStrings(current, writer.buffered());
}

test "Session list byte range rejects physical EOF before promised completion" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 1 } }));
}

test "Session list byte range rejects a promise excluding the final delimiter" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, wire, 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len - 1 } }));
}

test "Session list byte range validates junk inside and ignores junk outside the promise" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "page", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, wire ++ "false", 0);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 5 } }));
    const reply = try SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len } });
    try std.testing.expectEqual(@as(usize, 0), reply.page.count);
    try file.writePositionalAll(io, wire ++ " \n\r", 0);
    const spaced = try SessionListReply.decode(io, file, null, .{}, .{ .report = .{ .bytes = wire.len + 3 } });
    try std.testing.expectEqual(@as(usize, 0), spaced.page.count);
}

test "Session list facts reject malformed metadata and consequential ambiguity" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const row = "{\"reference\":\"s\",\"workspace\":\"/other\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"}";
    inline for (.{
        "{\"version\":\"2\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}",
        "{\"version\":\"1\",\"type\":\"session_list\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}",
        "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[]}",
        "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}false",
        "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":{\"after\":\"7\",\"ceiling\":\"11\"}}",
        "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[" ++ row ++ "," ++ row ++ "],\"next\":null}",
    }, 0..) |wire, index| {
        const file = try tmp.dir.createFile(io, std.fmt.comptimePrint("page-{d}", .{index}), .{ .read = true });
        defer file.close(io);
        try file.writePositionalAll(io, wire, 0);
        try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, wire.len, null, .{}));
    }
    const prefix = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"s\",\"workspace\":\"/other\",\"provider\":\"codex\",\"model\":\"m\",";
    inline for (.{
        "\"tools\":[\"bash\",\"bash\"],\"permission_mode\":\"ask\"",
        "\"tools\":null,\"permission_mode\":\"ask\"",
        "\"tools\":[0],\"permission_mode\":\"ask\"",
        "\"tools\":[],\"permission_mode\":0",
        "\"tools\":[],\"permission_mode\":\"invented\"",
        "\"tools\":[]",
        "\"tools\":[],\"permission_mode\":\"ask\",\"reference\":\"s\"",
    }, 0..) |suffix, index| {
        const file = try tmp.dir.createFile(io, std.fmt.comptimePrint("row-{d}", .{index}), .{ .read = true });
        defer file.close(io);
        const wire = prefix ++ suffix ++ "}],\"next\":null}";
        try file.writePositionalAll(io, wire, 0);
        try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, wire.len, null, .{}));
    }
}

test "Session list terminal cursor accepts only empty rows without rejecting initial or continuing pages" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "terminal", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[{\"reference\":\"s\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"tools\":[],\"permission_mode\":\"ask\"}],\"next\":null}";
    try file.writePositionalAll(io, wire, 0);
    inline for (.{ SessionListCursor{}, SessionListCursor{ .after = 7, .ceiling = 8 } }) |cursor| {
        const reply = try SessionListReply.decode(io, file, null, cursor, .{ .report = .{ .bytes = wire.len } });
        try std.testing.expectEqual(@as(usize, 1), reply.page.count);
        try std.testing.expectEqual(@as(?SessionListCursor, null), reply.page.next);
    }
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, null, .{ .after = 7, .ceiling = 7 }, .{ .report = .{ .bytes = wire.len } }));
    const empty = "{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[],\"next\":null}";
    try file.writePositionalAll(io, empty, 0);
    const reply = try SessionListReply.decode(io, file, null, .{ .after = 7, .ceiling = 7 }, .{ .report = .{ .bytes = empty.len } });
    try std.testing.expectEqual(@as(usize, 0), reply.page.count);
    try std.testing.expectEqual(@as(?SessionListCursor, null), reply.page.next);
}

test "Session list facts attain eight maximum escaped rows and bind the continuation cohort" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "maximum", .{ .read = true });
    defer file.close(io);
    var workspace = @as([protocol.max_workspace_bytes]u8, @splat(1));
    workspace[0] = '/';
    const model = @as([protocol.max_model_bytes]u8, @splat(1));
    var bytes: [protocol.content_window_bytes]u8 = undefined;
    var output = file.writerStreaming(io, &bytes);
    const writer = &output.interface;
    try writer.writeAll("{\"version\":\"1\",\"type\":\"session_list\",\"sessions\":[");
    for (0..8) |index| {
        if (index != 0) try writer.writeAll(",");
        var reference = @as([protocol.max_session_bytes]u8, @splat(1));
        reference[0] = @intCast(index + 16);
        try writer.writeAll("{\"reference\":");
        try std.json.Stringify.value(&reference, .{}, writer);
        try writer.writeAll(",\"workspace\":");
        try std.json.Stringify.value(&workspace, .{}, writer);
        try writer.writeAll(",\"provider\":\"codex\",\"model\":");
        try std.json.Stringify.value(&model, .{}, writer);
        try writer.writeAll(",\"tools\":[\"edit\"],\"permission_mode\":\"bypass\"}");
    }
    try writer.writeAll("],\"next\":{\"after\":\"19\",\"ceiling\":\"23\"}}");
    try writer.flush();
    const length = try file.length(io);
    try std.testing.expect(length > protocol.content_window_bytes);
    const page = try SessionListPage.read(io, file, length, &workspace, .{ .after = 11, .ceiling = 23 });
    try std.testing.expectEqual(@as(usize, 8), page.count);
    try std.testing.expectEqual(@as(u64, 19), page.next.?.after);
    try std.testing.expectEqual(@as(u64, 23), page.next.?.ceiling);
    for (page.rows[0..8], 0..) |*row, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index + 16)), row.reference.bytes[0]);
        try std.testing.expectEqual(protocol.max_session_bytes, row.reference.len);
        try std.testing.expectEqualStrings(&workspace, row.workspace.slice());
        try std.testing.expectEqualStrings(&model, row.model.slice());
        try std.testing.expect(row.tools.edit and !row.tools.bash and row.permission_mode == .bypass);
    }
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, "/wrong", .{}));
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, null, .{ .after = 19, .ceiling = 23 }));
    try std.testing.expectError(error.InvalidSessionPage, SessionListPage.read(io, file, length, null, .{ .after = 11, .ceiling = 29 }));
    // A next cursor needs a ninth row strictly beyond the eighth row's after.
    const tail = "],\"next\":{\"after\":\"19\",\"ceiling\":\"23\"}}";
    const prefix_length = length - tail.len;
    try file.writePositionalAll(io, "],\"next\":{\"after\":\"23\",\"ceiling\":\"23\"}}", prefix_length);
    try std.testing.expectError(error.InvalidSessionPage, SessionListReply.decode(io, file, &workspace, .{}, .{ .report = .{ .bytes = length } }));
    // Eight rows with no ninth row are valid, as is a terminal request probe.
    const terminal = "],\"next\":null}";
    try file.writePositionalAll(io, terminal, prefix_length);
    const last = try SessionListReply.decode(io, file, &workspace, .{}, .{ .report = .{ .bytes = prefix_length + terminal.len } });
    try std.testing.expectEqual(@as(usize, 8), last.page.count);
    try std.testing.expectEqual(@as(?SessionListCursor, null), last.page.next);
    try (SessionListCursor{ .after = 23, .ceiling = 23 }).validate();
}

test "control captures attain their exact worst-case request bounds" {
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
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
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
        .session = &escaped_session,
    }, .{ .record = stop_path, .key = &escaped_key });
    defer stop_capture.close(std.testing.io);
    const stop_file = try std.Io.Dir.cwd().openFile(std.testing.io, stop_path, .{});
    defer stop_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_session_stop_request_bytes),
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
        .session = &escaped_session,
        .turn_id = std.math.maxInt(u64),
        .operation_id = std.math.maxInt(u64),
    }, .{ .record = interruption_path, .key = &escaped_key });
    defer interruption_capture.close(std.testing.io);
    const interruption_file = try std.Io.Dir.cwd().openFile(std.testing.io, interruption_path, .{});
    defer interruption_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_model_interruption_request_bytes),
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
        .session = &escaped_session,
        .action_id = std.math.maxInt(u64),
        .decision = .allow_once,
    });
    try permission_capture.commit();
    const permission_file = try std.Io.Dir.cwd().openFile(std.testing.io, permission_path, .{});
    defer permission_file.close(std.testing.io);
    try std.testing.expectEqual(
        @as(u64, protocol.max_permission_decision_request_bytes),
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
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 1\r\n\r\n{}",
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
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: 1\r\n\r\n",
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

test "read result returns bounded command errors without touching destination" {
    const descriptors = try testPipe();
    defer closeTestDescriptor(descriptors[0]);
    try writeTestResponse(
        descriptors[1],
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 18\r\nX-Rui-Wire-Version: 1\r\n\r\n{\"status\":\"error\"}",
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
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 4\r\nX-Rui-Wire-Version: 1\r\n\r\nab",
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
    inline for (.{ "Content-Length: 2\r\nX-Rui-Wire-Version: 1\r\n\r\nabX", "Content-Length: 0\r\nX-Rui-Wire-Version: 1\r\n\r\nX" }) |tail| {
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

test "keyed observation retains request acceptance independently of later work" {
    const address = try MessageAddress.init("/store", "s", "k");
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"kind\":\"message\",\"target\":\"s\",\"status\":\"accepted\",\"input\":{\"type\":\"text\",\"bytes\":\"11\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))) ++ "\"},\"queue\":{\"status\":\"processing\",\"admission\":\"23\"},\"processing\":{\"turn\":\"37\",\"operation\":\"41\",\"attempt\":\"0\"}";
    inline for (.{
        .{ "}}", CommandObservation.State.processing },
        .{ ",\"result\":{\"status\":\"completed\",\"text\":{\"type\":\"text\",\"bytes\":\"19\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("cd".*)))) ++ "\"}},\"progress\":{\"status\":\"waiting_for_permission\",\"action\":\"91\"}}}", CommandObservation.State.completed },
        .{ ",\"result\":{\"status\":\"failed\",\"code\":\"provider_http_422\"}}}", CommandObservation.State.failed },
        .{ ",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}}}", CommandObservation.State.cancelled },
    }) |case| {
        const observed = try (try CommandObservation.parse(.{ .status = 200, .body = prefix ++ case[0] }, "k")).forMessage(&address);
        try std.testing.expectEqual(.accepted, observed.status);
        try std.testing.expectEqual(case[1], observed.state());
        try std.testing.expectEqual(@as(u64, 37), observed.processing.?.turn);
        try std.testing.expectEqual(@as(u64, 41), observed.processing.?.operation);
        try std.testing.expectEqual(@as(u64, 0), observed.processing.?.attempt);
        try std.testing.expectEqual(@as(u64, 23), observed.queue.?.admission);
        if (observed.state() == .completed) try std.testing.expectEqual(@as(u64, 19), observed.result.?.text.?.bytes);
        var output: [protocol.max_response_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
        defer json.deinit();
        try std.testing.expectEqualStrings("accepted", json.value.object.get("status").?.string);
    }
}

test "keyed observation distinguishes named statuses and omitted fields from numeric tags and null" {
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"target\":\"s\",\"code\":\"unknown_session\",";
    inline for (.{ "\"status\":2,\"kind\":\"message\"}}", "\"status\":\"2\",\"kind\":\"message\"}}", "\"status\":\"rejected\",\"kind\":1}}" }) |fields|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ fields }, "k"));
    const absent = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"absent\"";
    inline for (.{ "kind", "target", "code", "revision", "created", "input", "queue", "processing", "result", "progress", "selection", "completion", "interruption_target", "permission_target" }) |field|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = absent ++ ",\"" ++ field ++ "\":null}}" }, "k"));
}

test "keyed observation validates all five operation shapes and binding" {
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"target\":\"s\",";
    inline for (.{
        .{ "configure", ",\"revision\":\"31\",\"created\":true", "" },
        .{ "message", ",\"input\":{\"type\":\"text\",\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"queue\":{\"status\":\"queued\",\"admission\":\"13\"}", "" },
        .{ "session_stop", ",\"selection\":{\"turn\":null,\"admission_cutoff\":\"0\"},\"completion\":{\"status\":\"completed\"}", "" },
        .{ "model_interruption", ",\"interruption_target\":{\"session\":\"s\",\"turn\":\"3\",\"operation\":\"7\"}", ",\"interruption_target\":{\"session\":\"s\",\"turn\":\"0\",\"operation\":\"0\"}" },
        .{ "permission_decision", ",\"permission_target\":{\"action\":\"29\",\"decision\":\"allow_once\"}", ",\"permission_target\":{\"action\":\"0\",\"decision\":\"deny\"}" },
    }) |case| {
        const accepted = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"accepted\"" ++ case[1] ++ "}}";
        const observed = try CommandObservation.parse(.{ .status = 200, .body = accepted }, "k");
        try std.testing.expectEqualStrings(case[0], @tagName(observed.kind.?));
        try std.testing.expectEqual(.accepted, observed.status);
        var output: [protocol.max_response_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        try std.testing.expectEqualStrings("{\"status\":\"accepted\",\"kind\":\"" ++ case[0] ++ "\",\"target\":\"s\"" ++ case[1] ++ "}", writer.buffered());
        try std.testing.expectError(error.RequestBindingMismatch, CommandObservation.parse(.{ .status = 200, .body = accepted }, "other"));
        const rejected = try CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"rejected\",\"code\":\"unknown_session\"" ++ case[2] ++ "}}" }, "k");
        try std.testing.expectEqual(.rejected, rejected.status);
        try std.testing.expectEqualStrings("unknown_session", rejected.failureCode().?);
        writer = std.Io.Writer.fixed(&output);
        try rejected.writeJson(&writer);
        try std.testing.expectEqualStrings("{\"status\":\"rejected\",\"kind\":\"" ++ case[0] ++ "\",\"target\":\"s\",\"code\":\"unknown_session\"" ++ case[2] ++ "}", writer.buffered());
        // Missing operation-specific metadata must not turn into confirmation.
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"" ++ case[0] ++ "\",\"status\":\"accepted\"}}" }, "k"));
    }
    const absent = try CommandObservation.parse(.{ .status = 200, .body = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"absent\"}}" }, "k");
    const address = try MessageAddress.init("/store", "s", "k");
    try std.testing.expectError(error.RequestNotAdmitted, absent.forMessage(&address));
    const rejection = try CommandObservation.parse(.{ .status = 200, .body = prefix ++ "\"kind\":\"message\",\"status\":\"rejected\",\"code\":\"unknown_session\"}}" }, "k");
    const other = try MessageAddress.init("/store", "other", "k");
    try std.testing.expectError(error.RequestBindingMismatch, rejection.forMessage(&other));
}

test "keyed observation rejects malformed consequential fields before outcome interpretation" {
    const prefix = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"kind\":\"message\",\"target\":\"s\",\"status\":\"accepted\",\"input\":{\"type\":\"text\",\"bytes\":\"1\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))) ++ "\"},\"queue\":{\"status\":\"queued\",\"admission\":\"7\"}";
    inline for (.{
        ",\"processing\":null}}",                              ",\"processing\":{}}}",                                      ",\"processing\":{\"turn\":7}}}",
        ",\"result\":{\"status\":\"processing\"}}}",           ",\"result\":{\"status\":\"completed\"}}}",                  ",\"result\":{\"status\":\"failed\",\"code\":17}}}",
        ",\"result\":{\"status\":\"failed\",\"code\":null}}}", ",\"progress\":{\"status\":\"invented\",\"action\":null}}}", ",\"progress\":{\"status\":\"waiting_for_permission\",\"action\":null}}}",
        ",\"progress\":{\"status\":\"in_flight\"}}}",          ",\"progress\":{\"status\":\"in_flight\",\"action\":17}}}",  ",\"result\":{\"status\":\"failed\",\"code\":\"saved_failure\"},\"progress\":false}}",
        ",\"revision\":\"1\"}}",                               ",\"code\":null}}",                                          ",\"target\":null}}",
    }) |suffix| try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ suffix }, "k"));
    inline for (.{ "0", "+7", "07", "18446744073709551616" }) |id|
        try std.testing.expectError(error.InvalidResponse, CommandObservation.parse(.{ .status = 200, .body = prefix ++ ",\"progress\":{\"status\":\"in_flight\",\"action\":\"" ++ id ++ "\"}}}" }, "k"));
    inline for (.{ "{}", "[]", "{\"version\":\"2\"}", "{\"version\":\"1\",\"type\":\"wrong\"}" }) |body|
        try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = body }, "k"));
    try std.testing.expectError(error.InvalidObservation, CommandObservation.parse(.{ .status = 200, .body = prefix ++ ",\"queue\":{\"status\":\"queued\",\"admission\":\"9\"}}}" }, "k"));
    var oversized: [protocol.max_response_bytes + 1]u8 = undefined;
    try std.testing.expectError(error.ResponseTooLarge, CommandObservation.parse(.{ .status = 200, .body = &oversized }, "k"));
}

test "keyed observation owns supported strings without retaining unknown DOM across polls" {
    const observation = "{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"s/µ\",\"code\":\"line\\ncode\"}";
    const body = "{\"version\":\"1\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"s\\u002fµ\",\"code\":\"line\\ncode\",\"unknown\":{\"precise\":123456789012345678901234567890,\"items\":[true,null,\"discard\"]}}}";
    for (0..100) |_| {
        var storage = body.*;
        const observed = try CommandObservation.parse(.{ .status = 200, .body = &storage }, "k");
        @memset(&storage, 'x');
        try std.testing.expectEqualStrings("line\ncode", observed.failureCode().?);
        var output: [body.len]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try observed.writeJson(&writer);
        try std.testing.expectEqualStrings(observation, writer.buffered());
        var too_small = std.Io.Writer.fixed(&.{});
        try std.testing.expectError(error.WriteFailed, observed.writeJson(&too_small));
    }
}

test "keyed observation read diagnostics are owned without claiming admission" {
    const wire = "{\"version\":\"1\",\"type\":\"busy\",\"code\":\"ordinary_capacity_exhausted\",\"unknown\":[1,2,3]}";
    var storage = wire.*;
    const busy = try decodeReadFailure(.{ .status = 503, .body = &storage }, false);
    @memset(&storage, 'x');
    try std.testing.expectEqual(@as(u16, 503), busy.status);
    try std.testing.expectEqualStrings("ordinary_capacity_exhausted", busy.diagnostic.code.slice());
    try std.testing.expectEqual(error.HostInvocationFailed, busy.err());
    const fatal = try decodeReadFailure(.{ .status = 500, .body = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\"}" }, false);
    try std.testing.expectEqual(error.CanonicalStoreFailure, fatal.err());
    inline for (.{ "result_not_found", "result_not_ready", "result_failed" }) |code| {
        const reply: CommandReply = .{ .status = 409, .body = "{\"version\":\"1\",\"type\":\"result_unavailable\",\"code\":\"" ++ code ++ "\"}" };
        try std.testing.expectEqualStrings(code, (try decodeReadFailure(reply, true)).diagnostic.code.slice());
        try std.testing.expectError(error.InvalidResponse, decodeReadFailure(reply, false));
    }
    inline for (.{ "null", "{}" }) |value|
        try std.testing.expectError(error.InvalidResponse, decodeReadFailure(.{ .status = 500, .body = "{\"version\":\"1\",\"type\":\"invocation_error\",\"code\":\"canonical_store_failure\",\"observation\":" ++ value ++ "}" }, false));
    std.debug.print("keyed facts bytes={d}; reply bytes={d}; fixed parser scratch={d}; no retained allocator/DOM\n", .{
        @sizeOf(CommandObservation), @sizeOf(ReplyBuffer), std.ArrayList(u8).growCapacity((protocol.max_response_bytes + 7) / 8) + std.ArrayList(u8).growCapacity(protocol.max_response_bytes),
    });
}

test "Current facts preserve explicit unconfigured and promised range" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const wire = "{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}";
    try file.writePositionalAll(io, wire ++ "false", 0);
    try std.testing.expect((try CurrentReply.decode(io, file, "unknown", .{ .report = .{ .bytes = wire.len } })) == .unconfigured);
    inline for (.{ 0, wire.len - 1, wire.len + 1, wire.len + 6 }) |length|
        try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "unknown", .{ .report = .{ .bytes = length } }));
}

test "Current settings preserve decimal token heuristics in projections" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const wire = "{\"reference\":\"s\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"revision\":\"1\",\"tools\":[],\"permission_mode\":\"ask\",\"instructions\":{\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"output_schema\":null,\"compaction_trigger\":\"100000\",\"output_reservation\":\"16384\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}";
    const report = "{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":" ++ wire ++ ",\"pending_messages\":\"0\",\"work\":{\"status\":\"idle\",\"latest_outcome\":null},\"selected_message\":null,\"recent_messages\":[],\"actions\":{\"count\":\"0\",\"unresolved\":[],\"resolved\":[]},\"rejected_calls\":{\"count\":\"0\",\"items\":[]},\"actionable_permissions\":[],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"0\",\"scratch_used_bytes\":\"0\",\"unavailable\":[\"structured_output\"]}}";
    try file.writePositionalAll(io, report, 0);
    const reply = try CurrentReply.decode(io, file, "s", .{ .report = .{ .bytes = report.len } });
    try std.testing.expectEqualStrings("100000", reply.current.settings.compaction_trigger.?.slice());
    try std.testing.expectEqualStrings("16384", reply.current.settings.output_reservation.slice());
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try reply.current.writeJson(io, file, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"compaction_trigger\":\"100000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"output_reservation\":\"16384\"") != null);
    const prefix = wire[0..std.mem.indexOf(u8, wire, ",\"compaction_trigger\"").?];
    const cases = [_]struct { suffix: []const u8, valid: bool }{
        .{ .suffix = "}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":\"42\",\"output_reservation\":\"0\",\"compaction_trigger_override\":\"42\",\"output_reservation_override\":\"0\"}", .valid = true },
        .{ .suffix = ",\"compaction_trigger\":\"0\",\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":null,\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":\"0\",\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":\"-1\"}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":\"01\",\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
        .{ .suffix = ",\"compaction_trigger\":null,\"output_reservation\":1,\"compaction_trigger_override\":null,\"output_reservation_override\":null}", .valid = false },
    };
    for (cases) |case| {
        var settings_buffer: [4096]u8 = undefined;
        const session_start = std.mem.indexOf(u8, report, wire).?;
        const settings_json = try std.fmt.bufPrint(&settings_buffer, "{s}{s}{s}{s}", .{ report[0..session_start], prefix, case.suffix, report[session_start + wire.len ..] });
        try file.writePositionalAll(io, settings_json, 0);
        if (case.valid) {
            const parsed = try CurrentReply.decode(io, file, "s", .{ .report = .{ .bytes = settings_json.len } });
            var projection_buffer: [4096]u8 = undefined;
            var projection = std.Io.Writer.fixed(&projection_buffer);
            try parsed.current.writeJson(io, file, &projection);
            if (parsed.current.settings.compaction_trigger == null)
                try std.testing.expect(std.mem.indexOf(u8, projection.buffered(), "\"compaction_trigger\":null") != null);
        } else {
            try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "s", .{ .report = .{ .bytes = settings_json.len } }));
        }
    }
}

test "Current facts retain settings selected empty key and ten recent bindings" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var output = file.writerStreaming(io, &buffer);
    const writer = &output.interface;
    const reference = "{\"bytes\":\"7\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([4][16]u8, @splat("0123456789abcdef".*)))) ++ "\"}";
    try writer.writeAll("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":{\"reference\":\"s\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"exact\\u0001model\",\"revision\":\"17\",\"tools\":[\"edit\"],\"permission_mode\":\"ask\",\"instructions\":" ++ reference ++ ",\"output_schema\":null,\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null},\"pending_messages\":\"2\",\"work\":{\"status\":\"runnable\",\"turn\":\"37\",\"operation\":\"91\",\"latest_outcome\":{\"code\":\"failed_saved\",\"content\":null}},\"selected_message\":\"\",\"recent_messages\":[");
    for (0..10) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"turn\":\"{d}\",\"message\":\"key/{d}\",\"outcome\":\"completed\"}}", .{ 30 - i, i });
    }
    try writer.writeAll("],\"actions\":{\"count\":\"0\",\"unresolved\":[],\"resolved\":[]},\"rejected_calls\":{\"count\":\"0\",\"items\":[]},\"actionable_permissions\":[],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"3\",\"scratch_used_bytes\":\"123\",\"unavailable\":[\"structured_output\"]}}");
    try output.flush();
    const bytes = try file.length(io);
    const reply = try CurrentReply.decode(io, file, "s", .{ .report = .{ .bytes = bytes } });
    const facts = &reply.current;
    try std.testing.expectEqualStrings("exact\x01model", facts.settings.model.slice());
    try std.testing.expectEqual(@as(u64, 17), facts.settings.revision.value);
    try std.testing.expect(facts.settings.tools.edit and !facts.settings.tools.bash);
    try std.testing.expectEqual(@as(u64, 7), facts.settings.instructions.bytes.value);
    try std.testing.expect(facts.settings.reasoning_effort.value == null and facts.selected_message != null);
    try std.testing.expectEqualStrings("", facts.selected_message.?.slice());
    try std.testing.expectEqual(@as(u64, 91), facts.work.operation.value.?.value);
    try std.testing.expectEqual(@as(usize, 10), facts.recent_count);
    for (facts.recent[0..10], 0..) |row, i| try std.testing.expectEqual(@as(u64, 30 - i), row.turn.value);
    try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "other", .{ .report = .{ .bytes = bytes } }));
    var rendered: [4096]u8 = undefined;
    var json = std.Io.Writer.fixed(&rendered);
    try facts.writeJson(io, file, &json);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"revision\":\"17\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, json.buffered(), "\"selected_message\":\"\"") != null);
    try file.writePositionalAll(io, "x", 0);
    try std.testing.expectEqualStrings("exact\x01model", facts.settings.model.slice());
}

test "Current facts traverse every attention row and preserve metadata with fixed scratch" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "current", .{ .read = true });
    defer file.close(io);
    const rendered = try tmp.dir.createFile(io, "rendered", .{ .read = true });
    defer rendered.close(io);
    const reference = "{\"type\":\"text\",\"bytes\":\"13\",\"sha256\":\"" ++ @as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))) ++ "\"}";
    var buffer: [protocol.content_window_bytes]u8 = undefined;
    var output = file.writerStreaming(io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("{\"version\":\"1\",\"type\":\"session_report\",\"profile\":\"current\",\"session\":{\"reference\":\"s\",\"workspace\":\"/w\",\"provider\":\"codex\",\"model\":\"m\",\"revision\":\"17\",\"tools\":[\"bash\",\"edit\"],\"permission_mode\":\"ask\",\"instructions\":{\"bytes\":\"0\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"},\"output_schema\":null,\"reasoning_effort\":null,\"compaction_trigger\":null,\"output_reservation\":\"0\",\"compaction_trigger_override\":null,\"output_reservation_override\":null},\"pending_messages\":\"0\",\"work\":{\"status\":\"waiting_for_permission\",\"turn\":\"7\",\"operation\":\"19\",\"latest_outcome\":null},\"selected_message\":\"k\\n\",\"recent_messages\":[],\"actions\":{\"count\":\"515\",\"unresolved\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"parent_operation\":\"19\",\"call_ordinal\":\"{d}\",\"tool\":\"bash\",\"permission_revision\":\"23\",\"authorization\":\"pending\",\"call_id\":", .{ i + 31, i });
        try writer.writeAll(reference ++ ",\"arguments\":" ++ reference ++ ",\"presentation\":{\"description\":\"Run parser tests\",\"code\":\"pending_permission\",\"publication_position\":null}}");
    }
    try writer.writeAll("],\"resolved\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"parent_operation\":\"11\",\"call_ordinal\":\"{d}\",\"code\":\"indeterminate\",\"acceptance_position\":\"{d}\",\"result\":", .{ i + 1001, i, i + 71 });
        try writer.writeAll(reference ++ ",\"presentation\":{\"description\":\"Run parser tests\",\"code\":\"indeterminate\",\"publication_position\":null}}");
    }
    try writer.writeAll("]},\"rejected_calls\":{\"count\":\"257\",\"items\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"parent_operation\":\"11\",\"call_ordinal\":\"{d}\",\"code\":\"unknown_tool\",\"acceptance_position\":\"{d}\",\"result\":", .{ i + 1000, i + 5001 });
        try writer.writeAll(reference ++ ",\"item_id\":" ++ reference ++ ",\"name\":" ++ reference ++ ",\"call_id\":" ++ reference ++ ",\"arguments\":" ++ reference ++ ",\"presentation\":{\"description\":null,\"code\":\"unknown_tool\",\"publication_position\":null}}");
    }
    try writer.writeAll("]},\"actionable_permissions\":[");
    for (0..257) |i| {
        if (i != 0) try writer.writeAll(",");
        try writer.print("{{\"action\":\"{d}\",\"permission_revision\":\"23\"}}", .{i + 31});
    }
    try writer.writeAll("],\"execution\":{\"status\":\"partial\",\"dispatch_fenced\":false,\"custody_occupied\":\"3\",\"scratch_used_bytes\":\"987\",\"unavailable\":[\"structured_output\"]},\"extension\":\"");
    try writer.splatByteAll('x', 20000);
    try writer.writeAll("\"}");
    try output.flush();
    const bytes = try file.length(io);
    const reply = try CurrentReply.decode(io, file, "s", .{ .report = .{ .bytes = bytes } });
    const facts = &reply.current;
    try std.testing.expectEqual(@as(u64, 257), facts.actionable_count);
    try std.testing.expectEqual(@as(u64, 257), facts.indeterminate_count);
    try std.testing.expectEqual(@as(u64, 1001), facts.first_indeterminate.?);
    try std.testing.expect(facts.settings.reasoning_effort.value != null and facts.settings.reasoning_effort.value.? == null);
    const Sink = struct {
        counts: [4]usize = @splat(0),
        pub fn visit(self: *@This(), attention: Current.Attention) !void {
            const kind = @backingInt(attention);
            const i = self.counts[kind];
            switch (attention) {
                .unresolved => |row| {
                    try std.testing.expectEqual(@as(u64, 31 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 19), row.parent_operation.value);
                    try std.testing.expectEqual(@as(u64, i), row.call_ordinal.value);
                    try std.testing.expectEqual(@as(u64, 13), row.arguments.bytes.value);
                    try std.testing.expectEqualStrings(&@as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))), row.call_id.sha256.slice());
                    try std.testing.expectEqualStrings("Run parser tests", row.presentation.value.description.?.slice());
                    try std.testing.expectEqual(protocol.ToolPresentation.Code.pending_permission, row.presentation.value.code);
                },
                .resolved => |row| {
                    try std.testing.expectEqual(@as(u64, 1001 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 71 + i), row.acceptance_position.value);
                    try std.testing.expectEqualStrings("indeterminate", row.code.slice());
                    try std.testing.expect(row.presentation.value.publication_position == null);
                },
                .rejected => |row| {
                    try std.testing.expectEqual(@as(u64, 1000 + i), row.call_ordinal.value);
                    try std.testing.expectEqual(@as(u64, 5001 + i), row.acceptance_position.value);
                    try std.testing.expectEqualStrings("unknown_tool", row.code.slice());
                    try std.testing.expectEqual(@as(u64, 13), row.name.bytes.value);
                    try std.testing.expect(row.presentation.value.description == null);
                },
                .actionable => |row| {
                    try std.testing.expectEqual(@as(u64, 31 + i), row.action.value);
                    try std.testing.expectEqual(@as(u64, 23), row.permission_revision.value);
                },
            }
            self.counts[kind] += 1;
        }
    };
    var sink: Sink = .{};
    try facts.traverse(io, file, &sink);
    try std.testing.expectEqual([4]usize{ 257, 257, 257, 257 }, sink.counts);
    var json = rendered.writerStreaming(io, &buffer);
    try reply.writeJson(io, file, &json.interface);
    try json.flush();
    const roundtrip = try CurrentReply.decode(io, rendered, "s", .{ .report = .{ .bytes = try rendered.length(io) } });
    var again: Sink = .{};
    try roundtrip.current.traverse(io, rendered, &again);
    try std.testing.expectEqual(sink.counts, again.counts);
    const Failing = struct {
        pub fn visit(_: @This(), _: Current.Attention) !void {
            return error.SinkFailed;
        }
    };
    try std.testing.expectError(error.SinkFailed, facts.traverse(io, file, Failing{}));
    try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "s", .{ .report = .{ .bytes = bytes + 1 } }));
    var prefix: [2048]u8 = undefined;
    try std.testing.expectEqual(prefix.len, try file.readPositionalAll(io, &prefix, 0));
    inline for (.{
        .{ "\"version\":\"1\"", "\"version\":\"2\"" },
        .{ "\"tools\":[\"bash\",\"edit\"]", "\"tools\":[\"edit\",\"edit\"]" },
        .{ "\"turn\":\"7\"", "\"turn\":\"0\"" },
        .{ "\"operation\":\"19\"", "\"operation\":\"00\"" },
        .{ "\"selected_message\"", "\"ignored__message\"" },
        .{ "\"type\":\"text\"", "\"meta\":\"text\"" },
        .{ &@as([64]u8, @bitCast(@as([32][2]u8, @splat("ab".*)))), &@as([64]u8, @bitCast(@as([32][2]u8, @splat("xz".*)))) },
    }) |case| {
        const offset = std.mem.indexOf(u8, &prefix, case[0]).?;
        try file.writePositionalAll(io, case[1], offset);
        try std.testing.expectError(error.InvalidObservation, CurrentReply.decode(io, file, "s", .{ .report = .{ .bytes = bytes } }));
        try file.writePositionalAll(io, case[0], offset);
    }
    try std.testing.expectEqual(bytes, try file.length(io));
    std.debug.print("Current facts={d}B, fixed scanner/token/input=16384B, capture={d}B; 4x257 rows, no population allocation\n", .{ @sizeOf(Current), bytes });
}

test "transport cancellation preserves caller capture and rejects before path access" {
    var token: Cancellation = .{};
    token.requestStop();
    const requests: Requests = .{ .io = std.testing.io, .cancellation = &token };
    var captured: CapturedRecord = .{ .file = .{ .handle = -1, .flags = .{ .nonblocking = false } }, .length = 0, .saved = .{}, .target = .configure };
    try captured.saved.store.set("/never-open");
    var buffer: ReplyBuffer = .{};
    try std.testing.expectError(error.Cancelled, requests.sendCaptured(&captured, null, &buffer));
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), captured.file.handle);
    const file = captured.file;
    const address = try MessageAddress.init("/never-open", "s", "k");
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
            _ = self.requests.sendCaptured(self.captured, null, &reply) catch |err| {
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
    var captured = try captureConfigure(io, .{ .store = root, .session = .{ .named = "s" } }, .{ .explicit = .{ .record = try std.fmt.bufPrint(&record_buffer, "{s}/record", .{root}), .key = "original" } });
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
    while (!worker.done.load(.acquire) and std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < until)
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
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
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
    while (!worker.done.load(.acquire) and std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < until)
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
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
            while (!self.released.load(.acquire)) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
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
                        try self.requests.inspectSession(self.root, "s", .current, &self.sink, &buffer)
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
        try writeAll(peer.socket.handle, try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nX-Rui-Wire-Version: 1\r\n\r\na", .{ content_type, length }));
        // An answer's final window is delivered only after its EOF.
        if (kind == .result) try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(peer.socket.handle, std.c.SHUT.WR));
        const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;
        while (!worker.sink.entered.load(.acquire) and std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < until)
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        try std.testing.expect(worker.sink.entered.load(.acquire));
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
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = try @import("socket_fixture.zig").Directory.init();
    defer tmp.cleanup();
    var address_buffer: [@import("socket_fixture.zig").max_path_bytes]u8 = undefined;
    const address = try tmp.address("socket", &address_buffer);
    var listener = try address.listen(io, .{ .kernel_backlog = 0 });
    defer listener.deinit(io);
    const queued = try address.connect(io);
    defer queued.close(io);
    const until = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_ms;
    const blocked = connectRequest(.{ .io = io }, address, until);
    if (blocked) |fd| closeTestDescriptor(fd) else |_| {}
    try std.testing.expectError(error.TransferInactive, blocked);
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
    try std.testing.expectError(error.Cancelled, stopped);
}
